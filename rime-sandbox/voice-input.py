# -*- coding: utf-8 -*-
"""语音输入（命令行版）：麦克风录音 -> Qwen3-ASR -> 粘贴到目标窗口。

用法（建议通过 语音输入.bat 启动）：
  1. 双击 语音输入.bat。
  2. 对着麦克风说话，说完按回车结束录音（最长 60 秒自动停）。
  3. 识别结果自动进入剪贴板，倒计时 2 秒内点一下目标窗口，随后自动 Ctrl+V 粘贴，
     并把剪贴板恢复成原来的内容。

识别后端（与悬浮球 voice-overlay.py 同一套约定）：
  1. 首选 Qwen3-ASR：自动拉起本机 llama-server（127.0.0.1:3966，模型随包分发），
     走 HTTP /v1/audio/transcriptions 转写；
  2. llama-server / 模型缺失，或 HTTP 失败时降级 vosk（pip install vosk +
     vosk 模型目录，见 MODEL_DIR 解析）；两者都不可用则报错退出。

依赖：pip install sounddevice（Qwen 后端只需要它）；vosk 为可选降级。
路径解析：Rime 用户目录 = 环境变量 RIME_DIR -> 注册表 -> %APPDATA%\\Rime ->
旧开发目录；模型与 llama.cpp 优先取本脚本/EXE 同目录。
"""
import ctypes
import ctypes.wintypes as wt
import io
import json
import os
import subprocess
import sys
import threading
import time
import wave

import sounddevice as sd
try:                                  # vosk 只是降级后端，没装也能用 Qwen
    import vosk
    VOSK_OK = True
except Exception:                     # pragma: no cover - 环境相关
    vosk = None
    VOSK_OK = False

# ---- 路径解析（与 voice-overlay.py 保持同一契约） ----
if getattr(sys, "frozen", False):
    APP_DIR = os.path.dirname(sys.executable)
else:
    APP_DIR = os.path.dirname(os.path.abspath(__file__))


def resolve_rime_dir():
    """Rime 用户目录：环境变量 -> 注册表 -> %APPDATA%\\Rime -> 旧开发目录。"""
    env = os.environ.get("RIME_DIR")
    if env and os.path.isdir(env):
        return env
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                            r"Software\Rime\Weasel") as k:
            v, _ = winreg.QueryValueEx(k, "RimeUserDir")
            if v and os.path.isdir(v):
                return v
    except OSError:
        pass
    appdata = os.path.join(os.environ.get("APPDATA", ""), "Rime")
    if os.path.isdir(appdata):
        return appdata
    legacy = r"D:\rime-sandbox"
    return legacy if os.path.isdir(legacy) else appdata


def _find_dir(cands):
    for c in cands:
        if c and os.path.isdir(c):
            return c
    return ""


def _find_file(name, dirs):
    for d in dirs:
        if d and os.path.isfile(os.path.join(d, name)):
            return os.path.join(d, name)
    return os.path.join(dirs[0] or APP_DIR, name)


RIME_DIR = resolve_rime_dir()
VOICE_SET_PATH = os.path.join(RIME_DIR, "voice-settings.txt")
MODEL_DIR = _find_dir([
    os.environ.get("RIME_VOSK_MODEL"),
    os.path.join(APP_DIR, "vosk-model-cn"),
    r"D:\vosk-model-cn",
])                                     # vosk C++ API 不支持非 ASCII 路径


def _find_llama_dir():
    for c in (os.environ.get("RIME_LLAMA_DIR"),
              os.path.join(APP_DIR, "llama.cpp"),
              r"D:\王修翊\llama.cpp"):
        if c and os.path.isfile(os.path.join(c, "llama-server.exe")):
            return c
    return ""


LLAMA_DIR = _find_llama_dir()
LLAMA_SERVER = os.path.join(LLAMA_DIR, "llama-server.exe") if LLAMA_DIR else ""
ASR_MODEL = _find_file("Qwen3-ASR-0.6B-Q8_0.gguf",
                       [os.environ.get("RIME_VOICE_DIR"), APP_DIR, r"D:\VibeCoding\输入法"])
ASR_MMPROJ = _find_file("mmproj-Qwen3-ASR-0.6B-Q8_0.gguf",
                        [os.environ.get("RIME_VOICE_DIR"), APP_DIR, r"D:\VibeCoding\输入法"])
ASR_HOST, ASR_PORT = "127.0.0.1", 3966
ASR_HEALTH_URL = "http://%s:%d/health" % (ASR_HOST, ASR_PORT)
ASR_TRANSCRIBE_URL = "http://%s:%d/v1/audio/transcriptions" % (ASR_HOST, ASR_PORT)

SAMPLE_RATE = 16000
BLOCK_SIZE = 4000          # 0.25 秒一块
MAX_SECONDS = 60

user32 = ctypes.windll.user32
kernel32 = ctypes.windll.kernel32   # GlobalAlloc/GlobalLock 在 kernel32

# 64 位下句柄/指针必须是 64 位宽，否则会被 ctypes 默认的 c_int 截断
kernel32.GlobalAlloc.restype = ctypes.c_void_p
kernel32.GlobalAlloc.argtypes = [ctypes.c_uint, ctypes.c_size_t]
kernel32.GlobalLock.restype = ctypes.c_void_p
kernel32.GlobalLock.argtypes = [ctypes.c_void_p]
kernel32.GlobalUnlock.restype = ctypes.c_int
kernel32.GlobalUnlock.argtypes = [ctypes.c_void_p]
user32.GetClipboardData.restype = ctypes.c_void_p
user32.SetClipboardData.restype = ctypes.c_void_p
user32.SetClipboardData.argtypes = [ctypes.c_uint, ctypes.c_void_p]
VK_CONTROL, VK_V = 0x11, 0x56
CF_UNICODETEXT = 13
GMEM_MOVEABLE = 0x0002

title_buf = wt.WCHAR * 256


def console_print(msg):
    try:
        sys.stdout.buffer.write((msg + "\n").encode("utf-8", "replace"))
        sys.stdout.buffer.flush()
    except Exception:
        print(msg)


# ---- 标点转空格开关（与悬浮球同一个 voice-settings.txt） ----
def punct_space_enabled():
    try:
        with open(VOICE_SET_PATH, encoding="utf-8") as f:
            for line in f:
                if line.strip().startswith("punct_to_space"):
                    val = line.split("=", 1)[1].strip().lower()
                    return val in ("1", "true", "on", "yes")
    except OSError:
        pass
    return True


def punct_to_space(text):
    """标点换空格、合并连续空格、去首尾；数字里的 . , 保留（与悬浮球一致）。"""
    if not text:
        return text
    out = []
    for i, ch in enumerate(text):
        if unicodedata_category(ch).startswith("P"):
            if (ch in ".," and i > 0 and i + 1 < len(text)
                    and text[i - 1].isdigit() and text[i + 1].isdigit()):
                out.append(ch)
                continue
            out.append(" ")
        else:
            out.append(ch)
    s = "".join(out)
    while "  " in s:
        s = s.replace("  ", " ")
    return s.strip()


def unicodedata_category(ch):
    import unicodedata
    return unicodedata.category(ch)


# ---- Qwen3-ASR（llama-server HTTP，同 voice-overlay.py 的约定） ----
def asr_alive(timeout=1.0):
    import urllib.request
    import urllib.error
    try:
        with urllib.request.urlopen(ASR_HEALTH_URL, timeout=timeout):
            return True
    except (urllib.error.URLError, OSError):
        return False


def asr_start(wait=90):
    """确保 llama-server 常驻（已存活直接复用）；返回是否就绪。"""
    if asr_alive(1.0):
        return True
    if not (os.path.isfile(LLAMA_SERVER) and os.path.isfile(ASR_MODEL)
            and os.path.isfile(ASR_MMPROJ)):
        return False
    try:
        subprocess.Popen(
            [LLAMA_SERVER,
             "-m", ASR_MODEL,
             "--mmproj", ASR_MMPROJ,
             "--host", ASR_HOST, "--port", str(ASR_PORT),
             "--ctx-size", "4096", "-np", "1",
             "--no-webui", "--no-warmup"],
            cwd=LLAMA_DIR,
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=subprocess.CREATE_NO_WINDOW)
    except Exception:
        return False
    t0 = time.time()
    while time.time() - t0 < wait:
        if asr_alive(2.0):
            console_print("llama-server 就绪，用时 %.1f 秒" % (time.time() - t0))
            return True
        time.sleep(0.5)
    return False


def _wav_bytes(frames):
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(b"".join(frames))
    return buf.getvalue()


def asr_recognize(frames, timeout=90):
    """Qwen3-ASR HTTP 转写；失败返回 None（上层降级 vosk）。"""
    import urllib.request
    boundary = "----dshasr%x" % int(time.time() * 1000)
    wav = _wav_bytes(frames)

    def part(name, value, filename=None, ctype=None):
        head = '--%s\r\nContent-Disposition: form-data; name="%s"' % (
            boundary, name)
        if filename:
            head += '; filename="%s"' % filename
        head += "\r\n"
        if ctype:
            head += "Content-Type: %s\r\n" % ctype
        head += "\r\n"
        return head.encode("utf-8") + value + b"\r\n"

    body = (part("file", wav, "speech.wav", "audio/wav")
            + part("model", b"qwen3-asr")
            + part("language", b"zh")
            + ("--%s--\r\n" % boundary).encode("utf-8"))
    req = urllib.request.Request(ASR_TRANSCRIBE_URL, data=body, method="POST")
    req.add_header("Content-Type",
                   "multipart/form-data; boundary=%s" % boundary)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read().decode("utf-8", "replace"))
        return (data.get("text") or "").strip()
    except Exception as e:
        console_print("Qwen3-ASR 转写失败: %r" % (e,))
        return None


def clip_get():
    """读取当前剪贴板文本（失败返回 None）。"""
    try:
        if not user32.OpenClipboard(None):
            return None
        h = user32.GetClipboardData(CF_UNICODETEXT)
        if not h:
            return None
        p = ctypes.cast(h, ctypes.c_wchar_p)
        return p.value
    except Exception:
        return None
    finally:
        try:
            user32.CloseClipboard()
        except Exception:
            pass


def clip_set(text):
    """写入剪贴板文本（返回是否成功）。"""
    if not user32.OpenClipboard(None):
        return False
    try:
        user32.EmptyClipboard()
        data = text.encode("utf-16-le") + b"\x00\x00"
        hglobal = kernel32.GlobalAlloc(GMEM_MOVEABLE, len(data))
        if not hglobal:
            return False
        ptr = kernel32.GlobalLock(hglobal)
        ctypes.memmove(ptr, data, len(data))
        kernel32.GlobalUnlock(hglobal)
        user32.SetClipboardData(CF_UNICODETEXT, hglobal)
        return True
    finally:
        user32.CloseClipboard()


def paste():
    """向当前前台窗口发送 Ctrl+V。"""
    user32.keybd_event(VK_CONTROL, 0, 0, 0)
    user32.keybd_event(ord("V"), 0, 0, 0)
    user32.keybd_event(ord("V"), 0, 2, 0)   # KEYEVENTF_KEYUP
    user32.keybd_event(VK_CONTROL, 0, 2, 0)


def main():
    hwnd = user32.GetForegroundWindow()
    name = title_buf()
    user32.GetWindowTextW(hwnd, name, 256)
    console_print("当前前台窗口: %s" % name.value)

    # ---- 选择识别后端：Qwen3-ASR 优先，vosk 兜底 ----
    use_qwen = False
    rec = None
    try:
        if os.path.isfile(LLAMA_SERVER) and os.path.isfile(ASR_MODEL):
            console_print("正在连接 Qwen3-ASR（首次会自动启动 llama-server，稍候）...")
            use_qwen = asr_start(wait=90)
    except Exception as e:
        console_print("Qwen3-ASR 启动异常: %r" % (e,))
        use_qwen = False

    if not use_qwen:
        if not VOSK_OK:
            console_print("Qwen3-ASR 不可用，且未安装 vosk（pip install vosk）。")
            return 4
        if not MODEL_DIR:
            console_print("Qwen3-ASR 不可用，且找不到 vosk 模型目录。")
            return 4
        console_print("正在加载 vosk 语音模型（首次约几秒）...")
        t0 = time.time()
        try:
            model = vosk.Model(MODEL_DIR)
        except Exception as e:
            console_print("vosk 模型加载失败: %r" % (e,))
            return 4
        console_print("模型加载完成，用时 %.1f 秒" % (time.time() - t0))
        rec = vosk.KaldiRecognizer(model, SAMPLE_RATE)
        rec.SetWords(True)

    raw = []
    stop_flag = threading.Event()

    def audio_callback(indata, frames, time_info, status):
        if stop_flag.is_set():
            raise sd.CallbackStop()
        raw.append(bytes(indata))

    def wait_enter():
        try:
            input()
        except EOFError:
            pass
        stop_flag.set()

    backend = "qwen3-asr" if use_qwen else "vosk"
    console_print("录音中（后端 %s）……说完按回车结束（最长 %d 秒）。"
                  % (backend, MAX_SECONDS))
    threading.Thread(target=wait_enter, daemon=True).start()

    try:
        with sd.InputStream(
            samplerate=SAMPLE_RATE,
            blocksize=BLOCK_SIZE,
            dtype="int16",
            channels=1,
            callback=audio_callback,
        ):
            deadline = time.time() + MAX_SECONDS
            while not stop_flag.is_set() and time.time() < deadline:
                time.sleep(0.1)
            stop_flag.set()
            time.sleep(0.3)   # 等回调收尾
    except sd.PortAudioError as e:
        console_print("打不开麦克风: %s" % e)
        return 2

    if not raw:
        console_print("没有录到音频。")
        return 1

    # ---- 识别 ----
    text = ""
    if use_qwen:
        text = asr_recognize(raw)
        if text is None:
            text = ""
            if rec is None and VOSK_OK and MODEL_DIR:   # 降级路径：补建 vosk 识别器
                try:
                    rec = vosk.KaldiRecognizer(vosk.Model(MODEL_DIR), SAMPLE_RATE)
                except Exception:
                    rec = None
    if not text and rec is not None:
        step = BLOCK_SIZE * 4
        for i in range(0, len(raw), step):
            rec.AcceptWaveform(b"".join(raw[i: i + step]))
        try:
            text = json.loads(rec.FinalResult()).get("text", "")
        except Exception:
            text = ""
        text = text.replace(" ", "")    # vosk 中文候选间有空格，上屏前去掉

    text = text.strip()
    if punct_space_enabled():
        text = punct_to_space(text)
    else:
        text = text.replace(" ", "")    # 关掉标点转空格时也压掉 Qwen 的词间空格

    if not text:
        console_print("没有识别到文字。")
        return 1

    console_print("识别结果: " + text)

    old_clip = clip_get()
    if not clip_set(text):
        console_print("写剪贴板失败。")
        return 3

    console_print("2 秒后粘贴到那时的前台窗口，请先点一下目标窗口……")
    time.sleep(2)
    paste()
    time.sleep(0.3)

    if old_clip is not None:
        clip_set(old_clip)

    console_print("完成。")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        # 自检：只打印路径/后端解析结果，不碰麦克风与剪贴板
        console_print("APP_DIR=%s" % APP_DIR)
        console_print("RIME_DIR=%s" % RIME_DIR)
        console_print("VOICE_SET=%s exists=%s" % (VOICE_SET_PATH, os.path.exists(VOICE_SET_PATH)))
        console_print("LLAMA_SERVER=%s" % (LLAMA_SERVER or "(missing)"))
        console_print("ASR_MODEL=%s" % ASR_MODEL)
        console_print("ASR_MMPROJ=%s" % ASR_MMPROJ)
        console_print("vosk_ok=%s MODEL_DIR=%s" % (VOSK_OK, MODEL_DIR or "(missing)"))
        sys.exit(0)
    sys.exit(main())
