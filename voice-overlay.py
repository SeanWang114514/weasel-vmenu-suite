# -*- coding: utf-8 -*-
"""语音输入悬浮球 —— 长按 Ctrl+Win 说话，松开即上屏。

交互（长按式 push-to-talk）：
- **按住** Ctrl+Win ≥150ms -> 底部中央浮出胶囊，开始录音；
- **松开**（任意一个修饰键）  -> 停止录音 -> 本地识别 -> 文字自动注入当前
  光标所在的输入框；
- 按住期间出现第三个键（Ctrl+Win+D 这类系统组合）-> 立即中止，不上屏；
- 短于 150ms 的误触不响应；录音上限 60 秒。

焦点不在输入框时（桌面 / 资源管理器列表 / 任务栏 / 终端 / 视频播放器…）：
识别出的文字**无处可去**，这时不注入，改为**兜底复制到剪贴板**，并在悬浮球里
弹一条「已复制」的胶囊提示（`TOAST_TEXT` / `TOAST_MS`）。判定规则表在
`voice_overlay_focus.py`（纯函数，`--selftest` 与 `tmp/test-focus-target.py`
跑的是同一份；实测依据见 `tmp/probe-focus.py`）。判不出来时按老行为注入 ——
宁可偶尔打空，也不凭空把用户的输入改成复制。

设计要点（安全第一）：
- 完全独立的 pythonw 进程。输入法（WeaselServer / Lua / YAML）零改动，
  本进程哪怕立刻崩溃也不影响输入法的任何功能。
- 热键用 GetAsyncKeyState **20ms 轮询**实现，**不安装任何系统键盘钩子**
  ——本进程哪怕卡死也不影响全局打字/切输入法/Win 键。
  历史教训：初版用 WH_KEYBOARD_LL 钩子，ctypes 未声明 argtypes 导致 64 位
  lParam 被截断传回 CallNextHookEx，损坏下游钩子链、全系统无法输入。
- 录音 sounddevice 16k 单声道；识别优先走 **Qwen3-ASR**（本机 llama-server 常驻
  HTTP，`/v1/audio/transcriptions`），失败自动降级 vosk（D:\\vosk-model-cn，
  vosk C++ API 不支持非 ASCII 路径）；上屏用 SendInput(KEYEVENTF_UNICODE)
  直接向目标窗口注入字符，**正常路径完全不碰剪贴板**（只有「焦点不在输入框」
  和「注入没落地」这两个兜底分支才写剪贴板）；上屏前会先等 Ctrl/Win 全部
  松开，避免把修饰键状态带进目标程序。
- 胶囊窗口 WS_EX_NOACTIVATE：显示期间不抢焦点，光标始终留在你的输入框。

用法：
  后台常驻        : pythonw voice-overlay.py
  热键状态机自检  : python  voice-overlay.py --selftest
  完整模拟一轮    : python  voice-overlay.py --simulate  （不真正上屏）
  看焦点判定      : python  voice-overlay.py --probe-focus  （前台窗口算不算输入框）
  看「已复制」提示: python  voice-overlay.py --toast        （弹出提示，2.6s 后退出）
  验剪贴板通路    : python  voice-overlay.py --copy-text "测试"（写入并读回校验）
"""
import collections
import ctypes
import ctypes.wintypes as wt
import io
import json
import os
import queue
import re
import subprocess
import sys
import threading
import time
import unicodedata
import wave

import numpy as np
import sounddevice as sd
try:                                  # vosk 只是降级后端；没装也能跑（Qwen 主后端）
    import vosk
    VOSK_OK = True
except Exception:                     # pragma: no cover - 环境相关
    vosk = None
    VOSK_OK = False
import tkinter as tk
import tkinter.font as tkfont

try:                                  # 抗锯齿渲染要靠 Pillow；缺失则退回 Tk 画布
    from PIL import Image, ImageDraw, ImageFilter
    PIL_OK = True
except Exception:                     # pragma: no cover - 环境相关
    PIL_OK = False

try:                                  # 焦点判定规则表（纯逻辑，单独成文件好回归）
    from voice_overlay_focus import (judge_focus_target, make_guithreadinfo,
                                     wants_copy, FOCUS_EDIT, FOCUS_NONEDIT,
                                     FOCUS_UNKNOWN)
    FOCUS_OK = True
except Exception:                     # pragma: no cover - 环境相关
    judge_focus_target = make_guithreadinfo = None
    wants_copy = None
    FOCUS_EDIT, FOCUS_NONEDIT, FOCUS_UNKNOWN = "edit", "nonedit", "unknown"
    FOCUS_OK = False

try:                                  # UIA：直接问系统「焦点元素能不能收文字」
    import voice_overlay_uia as _uia
    UIA_OK = True
except Exception:                     # pragma: no cover - 环境相关
    _uia = None
    UIA_OK = False

# 打包成 exe（PyInstaller）后 __file__ 指向解包临时目录，用 exe 所在目录
if getattr(sys, "frozen", False):
    APP_DIR = os.path.dirname(sys.executable)
else:
    APP_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_PATH = os.path.join(APP_DIR, "voice-overlay.log")


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
    """返回第一个存在的目录；全部不存在则返回空串。"""
    for c in cands:
        if c and os.path.isdir(c):
            return c
    return ""


def _find_file(name, dirs):
    """返回 dirs 里第一个存在的 <dir>\\name；都不存在则指向首选位置（报错可见）。"""
    for d in dirs:
        if d and os.path.isfile(os.path.join(d, name)):
            return os.path.join(d, name)
    return os.path.join(dirs[0] or APP_DIR, name)


RIME_DIR = resolve_rime_dir()
# vosk 的 C++ API 不支持非 ASCII 路径；模型没装时为空（Qwen 主后端不受影响）
MODEL_DIR = _find_dir([
    os.environ.get("RIME_VOSK_MODEL"),
    os.path.join(APP_DIR, "vosk-model-cn"),
    r"D:\vosk-model-cn",
])
SAMPLE_RATE = 16000
BLOCK = 4000                              # 0.25s 一块
MAX_SECONDS = 60
ARM_DELAY = 0.15                          # 长按多久算“有意图”（秒）
TAP_MIN = 0.25                            # 录音短于此秒数视为误触，丢弃
MOD_RELEASE_WAIT = 120.0                 # 上屏前等修饰键松开的上限（秒）

# ---- 流式输出（边说边上屏）----
# 节奏调优：首字从「1.0s 音频 + 0.6s 间隔」提前到 0.6s + 0.4s，长音频降频
# 更平缓且封顶 1s（旧参数 8s 的话后半段每 1.3s 才刷一次，体感滞后）。
STREAM_INTERVAL = 0.4                    # 流式识别最小间隔（秒）
STREAM_MIN_AUDIO = 0.6                   # 累计音频达到这么多秒才开始流式
STREAM_MIN_DELTA = 1                     # 增量至少这么多字符才值得上屏
STREAM_TAIL_RATIO = 0.08                 # 长音频降频：间隔 = max(0.4, 0.08*时长)
STREAM_INTERVAL_MAX = 1.0                # 降频后的间隔上限（秒）
ABORT_RETRACT_WAIT = 10.0                # abort 撤回时等修饰键松开的上限（秒）

# ---- 退格投递节奏（实测出来的硬参数，别随手调小）----
# 实测（真实双进程：独立注入进程 -> 独立目标进程，目标自己跑消息循环；
# 12 次退格 / 每次重复 3 轮，统计目标**实际收到的退格次数**）：
#   SendInput 一次投 n 组 down/up（旧实现）      -> 收到 5~7 / 12
#   SendInput 逐个 + scan code + 12ms 间隔        -> 收到 7~8 / 12
#   keybd_event 无间隔                            -> 收到 5~7 / 12
#   keybd_event 按住 12ms、释放后再等 12ms        -> 收到 12 / 12（24 次也是 24/24）
# 结论：**只有 keybd_event + 每键 24ms 才能收全**。少一半的退格会静默丢失，
# 屏幕上就是「流式预览的前半句没被删掉、最终结果只能接在后面」——这正是
# 用户报的「第一个标点前那句一直保留」。退格丢不起，所以这里宁可慢。
BACKSPACE_HOLD = 0.012                   # 每个退格按住多久（秒）
BACKSPACE_GAP = 0.012                    # 释放后到下个退格之间的间隔（秒）
VK_BACK = 0x08                           # 退格键的虚拟键码

# ---- 「替换预览」时长：整段退格 + 补发正文，固定在这个时间内跑完（秒）----
# 需求（0.2.38）：「增加语音识别出结果后替换预览的速度，要求恒定速度，默认 1s」。
# 需求（0.2.39，本轮）：「我要的是调快替换的时间，我不是要取消部分的替换」
#   —— 也就是：该删的一个字都不能少，但这段墙钟必须真的能调快。
# 恒定 = 不随句子长短变：短句不再一闪而过、长句不再拖到一两秒。
#
# 两条投递通道（本轮新增快通道，慢通道降级为兜底）：
#
#   快通道 post_backspaces()：把 WM_KEYDOWN/WM_KEYUP(VK_BACK) **直接投给目标的
#     焦点窗口**。消息进的是目标线程的**消息队列**（FIFO），不过 RIT 的按键状态机，
#     所以没有「down/up 挤在同一瞬间被合并掉」的丢键问题 —— 实测 46 格
#     1~10ms、收全 46/46（Tk 目标 / 记事本 RichEditD2DPT / Chrome 顶层自绘窗口
#     三种真机都过，见 tmp/bs-bulk-delete-experiment.py、tmp/bs-fast-live.py）。
#     关键：它**没有每格下限**，所以秒数调多快就真的多快；0 秒 = 一口气投完（≈几毫秒）。
#
#   慢通道 send_backspaces_slow()：真实键盘注入（keybd_event）。全系统通用，
#     但每格至少 BACKSPACE_FLOOR = 24ms（RIT 会合并 down/up，实测低于 24ms 静默
#     丢键，屏幕上直接残留错字）。只有在拿不到焦点窗口、目标类名在黑名单里
#     （UWP / XAML 岛这类输入走 CoreWindow 输入源、不吃投递键消息的），
#     或用户在 voice-settings.txt 里关掉 fast_delete 时才走它。
#
# 上限 RECONCILE_SECS_MAX 不是拍脑袋：60 个字以内都能在 1s 内退完，
# 再长就该「快点做完」而不是继续变慢。
#
# 默认值 = 0.0（立刻替换）：快通道没有每格下限，一口气投完（实测 1~3ms）且
# **一格都不丢**（WinForms Edit / Chrome 两种真机逐字一致，见 tmp/bs-fast-e2e.py、
# tmp/bs-chrome-e2e.py），所以「最快」和「最完整」在同一边 —— 不用二选一。
# 这正是 0.2.39 的落点：默认就快，一个字都不会少删；想让人看清这段节奏的
# 再往上调（0.1~3.0 秒铺开），调大只影响快慢，不影响删多少。
RECONCILE_SECS_DEFAULT = 0.0             # voice-settings.txt 里的 reconcile_secs=
RECONCILE_SECS_MIN = 0.0                 # 0 = 不铺时长，一口气投完（快通道没有下限）
RECONCILE_SECS_MAX = 3.0


def _backspace_scan():
    """退格键的真实 scan code（0x0E）。

    wScan=0 时目标程序可能认不出这是退格键（Tk 这类按 scan code 解键名的
    框架会直接丢掉按键），所以必须带上。取不到时退回 PS/2 标准的 0x0E。
    """
    try:
        u = ctypes.windll.user32
        u.MapVirtualKeyW.argtypes = [ctypes.c_uint, ctypes.c_uint]
        u.MapVirtualKeyW.restype = ctypes.c_uint
        sc = u.MapVirtualKeyW(VK_BACK, 0)     # MAPVK_VK_TO_VSC
        return sc or 0x0E
    except Exception:
        return 0x0E


BACKSPACE_SCAN = _backspace_scan()
BACKSPACE_FLOOR = BACKSPACE_HOLD + BACKSPACE_GAP     # 每格可靠投递下限（秒）
# 每格的**固定开销**（与 sleep 无关的那部分）。实测：keybd_event 一轮退格的墙钟
# 总是比 hold+gap 多约 9ms/格，且 SendInput 也一样（standalone 调 SendInput 只要
# 0.01ms，所以这不是 API 的开销）—— 是注入要交给前台线程的 RIT 去派发，
# 目标越忙这一格就越贵（我们的测试目标是最慢的 Tk Text，属保守口径）。
# 算节奏时必须把它减掉，否则「预算 1s」实际会跑成 1.1s。
BACKSPACE_OVERHEAD = 0.009


def backspace_pace(n, budget=RECONCILE_SECS_DEFAULT):
    """把 n 个退格**匀速铺满** budget 秒，返回 `(hold, gap)`（单位秒）。

    纯函数：selftest 与回归测试测的就是实机用的这一份。

    规则：
      - n<=0 -> (0, 0)，调用方不该发任何键；
      - 每格可用时间 = `budget/n - BACKSPACE_OVERHEAD`（扣掉固定开销，
        这样**墙钟总时长**才真的落在 budget 上，而不是 budget 再多个零头）；
      - 但每格 sleep 不得低于可靠投递下限 `BACKSPACE_FLOOR`（24ms）——
        低于它就会静默丢退格，屏幕上残留错字（这个用户可见性远大于快慢）；
      - 拖到下限就按下限走：n 大时总时长被下限顶长（46 格 ≈1.5s），
        但**永远不再随句子变长而无限变慢**，这就是「恒定速度」。

    举例（默认 1s，含 9ms 开销）：12 格 -> 每格 74ms、墙钟 ≈1.0s；
                                 24 格 -> 每格 33ms、墙钟 ≈1.0s；
                                 46 格 -> 每格 24ms（下限）、墙钟 ≈1.5s。
    """
    if n <= 0:
        return (0.0, 0.0)
    try:
        budget = float(budget)
    except (TypeError, ValueError):
        budget = RECONCILE_SECS_DEFAULT
    per = budget / n - BACKSPACE_OVERHEAD
    if per < BACKSPACE_FLOOR:
        per = BACKSPACE_FLOOR
    # 按住 : 间隔 保持与实测可靠的那组同比例（12ms : 12ms）
    hold = per * (BACKSPACE_HOLD / BACKSPACE_FLOOR)
    return (hold, per - hold)


def parse_reconcile_secs(raw):
    """`reconcile_secs=` 的原始值 -> 秒数（**纯函数**）。

    只认 0.0 ~ 3.0：**0 表示「不铺时长，一口气投完」**（快通道没有每格下限，
    见 post_backspaces）；越界/非数字一律退回默认（默认就是 0 = 立刻）——
    配置文件被人手改坏，不能把节奏搞崩。
    """
    if raw is None:
        return RECONCILE_SECS_DEFAULT
    try:
        v = float(raw)
    except (TypeError, ValueError):
        return RECONCILE_SECS_DEFAULT
    if RECONCILE_SECS_MIN <= v <= RECONCILE_SECS_MAX:
        return v
    return RECONCILE_SECS_DEFAULT


def reconcile_secs():
    """读 voice-settings.txt 的 reconcile_secs=；缺失/非法/越界退回默认 1s。

    要求：0.0 ~ 3.0 秒（0 = 立刻投完，见 RECONCILE_SECS_MIN/MAX 的说明）。
    **每次替换前都读一次**，所以设置窗口改完下一次识别即生效，不用重启悬浮球。
    """
    return parse_reconcile_secs(_voice_setting("reconcile_secs"))


# ---- 快通道：把退格**直接投给目标的焦点窗口**（原理见上面 159 行起的说明）----
FAST_DELETE_DEFAULT = True               # voice-settings.txt 里的 fast_delete=
WM_KEYDOWN, WM_KEYUP, WM_NULL = 0x0100, 0x0101, 0x0000
SMTO_ABORTIFHUNG = 0x0002
# 已知**不吃**「投递键消息」的窗口类：UWP / XAML 岛的键盘输入走 CoreWindow 输入源，
# 不是消息循环里的 WM_KEYDOWN。这些目标一律退回慢通道 —— 宁可慢，不许留错字。
FAST_DELETE_BLOCK_CLASSES = (
    "windows.ui.core.corewindow", "corewindow",
    "xamlislandwindow", "xamlislandwindowclass", "applicationframehost",
    "microsoft.ui.content.desktopchildsitebridge",
    "winuidesktopwin32windowclass",
    "windows.ui.composition.desktopwindowcontentbridge",
)
# 运行期学到的黑名单：某个窗口类**整段一个键都没投出去**（PostMessage 返回 FALSE，
# 典型是 UIPI 拦了：目标进程比我们权限高）就记在这里，本次会话内不再白试。
# 只记「一个都没投出去」——投出去一半的那种不能算，那说明通道本身是通的。
_FAST_BAD_CLASSES = set()


def fast_delete_enabled():
    """读 fast_delete 开关；缺失/非法默认开（快通道是本次需求的默认行为）。"""
    val = _voice_setting("fast_delete")
    if val is None:
        return FAST_DELETE_DEFAULT
    return val.strip().lower() in ("1", "true", "on", "yes")


def fast_delete_class_ok(cls):
    """这个焦点窗口类能不能走快通道（**纯函数**）。"""
    return (cls or "").strip().lower() not in FAST_DELETE_BLOCK_CLASSES


def fast_delete_pace(n, budget=RECONCILE_SECS_DEFAULT):
    """快通道每格铺多少秒（**纯函数**）。

    和慢通道的 `backspace_pace()` 最大的区别：**没有下限**。投递走的是目标线程的
    消息队列（FIFO、不丢），不需要给 RIT 留「把 up 处理完」的时间，所以 0 也行：
    0 = 一口气投完（实测 46 格 1ms），1s = 每格 1/n 秒、总时长仍落在预算上。
    """
    if n <= 0:
        return 0.0
    try:
        b = float(budget)
    except (TypeError, ValueError):
        b = RECONCILE_SECS_DEFAULT
    if b < 0:
        b = 0.0
    return b / n


def fast_delete_lparam(scan, up=False):
    """WM_KEYDOWN/WM_KEYUP 的 lParam（**纯函数**）。

    位段：0-15 重复次数=1、16-23 scan code、24 扩展键、29 上下文、
    30 前次按键状态、31 转换状态（1 = 松开）。必须带真 scan code —— 按 scan code
    认键名的框架（Tk 这类）拿不到会把按键直接丢掉。
    """
    lp = 1 | (scan << 16)
    if up:
        lp |= (1 << 30) | (1 << 31)
    return lp


# ---- 标点转空格开关（设置窗口「设置与缓存」页可切换，改完下一次识别即生效）----
# 独立于 vmenu-settings.txt：输入法端 lua 会整文件重写 vmenu-settings.txt，
# 放一起会被冲掉。
VOICE_SET_PATH = os.path.join(RIME_DIR, "voice-settings.txt")

# 物理核数（不是逻辑核数）：llama.cpp 开线程超过物理核只会空转自旋，
# 白白烧 CPU 还更慢，所以线程数上限按物理核算。
try:
    PHYS_CORES = os.cpu_count() or 4
    try:                                  # Windows 上 os.cpu_count() 含超线程
        import psutil                     # 有 psutil 就取真实物理核
        PHYS_CORES = psutil.cpu_count(logical=False) or PHYS_CORES
    except Exception:
        PHYS_CORES = max(1, PHYS_CORES // 2)   # 没有 psutil：按一半估
except Exception:                         # pragma: no cover - 环境相关
    PHYS_CORES = 4


def punct_space_enabled():
    """读 punct_to_space 开关；文件缺失/字段缺失时默认开（本次需求的默认行为）。"""
    try:
        with open(VOICE_SET_PATH, encoding="utf-8") as f:
            for line in f:
                if line.strip().startswith("punct_to_space"):
                    val = line.split("=", 1)[1].strip().lower()
                    return val in ("1", "true", "on", "yes")
    except OSError:
        pass
    return True


# ---- ASR 线程数（CPU 占用闸门）----
# 教训：llama.cpp 默认 `-t -1` 会按**逻辑核数**开线程（本机 i7-13620H = 16），
# 多核空转自旋同步，实测一次 3s 音频吃 946% 单核 ≈ 59% 整机、瞬时打满，
# 用户侧就是「一说话任务管理器就爆红」。
# 实测同机同音频（3s wav，整机 16 逻辑核口径）：
#    默认16线程 -> 总CPU 1.40s / 59.1% 整机
#     -t 6      -> 总CPU 0.82s / 36.3% 整机
#     -t 4      -> 总CPU 0.64s / 24.4% 整机   <-- 默认值，压到 30% 以下
#     -t 2      -> 总CPU 0.45s / 11.6% 整机（更省但尾延迟约 +0.1s）
# 关键：限制线程**同时降低总 CPU 消耗**（1.40s -> 0.64s，省 54%），
# 因为省掉了超订线程的空转自旋；墙钟只从 0.148s 增到 0.163s，体感无差别。
# 识别率完全不受影响：同一个模型、同一份权重，只是并行度不同。
ASR_THREADS_DEFAULT = 4


# ---- 识别设备：CPU / GPU（NVIDIA CUDA）----
# GPU 走 llama.cpp 的 CUDA 后端，把模型整层丢进显存。实测本机 i7-13620H +
# RTX 5060 Laptop（8GB）识别同一段 6.2s 中文语音：
#     CPU 调优(-t 4) -> 0.430s，整机 CPU 26%
#     GPU(-ngl 99)   -> 0.188s，整机 CPU 10.9%   （快 2.3x，CPU 再降一半）
# 识别结果逐字一致（同一份权重，只是算力位置不同）。
# 取值：auto（默认，自动探测）/ cpu / gpu。auto 探不到 N 卡就静默回落 CPU，
# 绝不因为设备问题让语音输入罢工。
ASR_DEVICE_DEFAULT = "auto"
_GPU_CACHE = [None]                     # 探测结果缓存（0=无 / 1=有），启动只探一次


def _find_cuda_dll():
    """当前 llama.cpp 目录里是否齐了 CUDA 后端需要的 dll。

    llama.cpp 的 CUDA 后端强依赖 cuBLAS：缺 ggml-cuda.dll 或任一 cublas 就
    整个后端不可用（不是降级，是启动失败）。所以要逐个查，不能只看一个。
    """
    need = ("ggml-cuda.dll", "cublas64_13.dll", "cublasLt64_13.dll",
            "cudart64_13.dll")
    for n in need:
        if not os.path.isfile(os.path.join(LLAMA_DIR, n)):
            return False
    return True


def gpu_available():
    """本机是否真的能用 GPU 跑：有 N 卡 + 驱动在 + CUDA 运行时齐全。

    三重检查缺一不可：
      1) WMI 里能看到 NVIDIA 显卡（拿到名字，顺便给设置窗口显示）；
      2) nvcuda.dll 在系统目录（装了 NVIDIA 驱动）；
      3) llama.cpp 目录里有完整 CUDA 运行时（CPU 版包就没这个）。
    任何一步失败都返回 (False, 原因)，调用方静默回落 CPU。
    """
    if _GPU_CACHE[0] is not None:
        return _GPU_CACHE[0]
    ok, name = False, ""
    try:
        # 只认 NVIDIA：AMD/Intel 的 llama.cpp 后端（vulkan/hip）未随包分发
        ps = ("Get-CimInstance Win32_VideoController | "
              "Where-Object { $_.Name -match 'NVIDIA' } | "
              "Select-Object -First 1 -ExpandProperty Name")
        r = subprocess.run(
            ["powershell", "-NoProfile", "-NonInteractive", "-Command", ps],
            capture_output=True, text=True, timeout=15,
            creationflags=subprocess.CREATE_NO_WINDOW)
        name = (r.stdout or "").strip()
        if name:
            nvcuda = os.path.join(os.environ.get("WINDIR", r"C:\Windows"),
                                  "System32", "nvcuda.dll")
            ok = os.path.isfile(nvcuda) and _find_cuda_dll()
    except Exception as e:
        out("gpu probe error: %r" % (e,))
        ok, name = False, ""
    _GPU_CACHE[0] = (ok, name)
    out("gpu probe: available=%s name=%r cuda_dlls=%s"
        % (ok, name, _find_cuda_dll()))
    return _GPU_CACHE[0]


def asr_device():
    """读 voice-settings.txt 的 asr_device=，解析成实际要用的 'cpu' / 'gpu'。

    auto（默认）：探到可用 GPU 就用 GPU，否则 CPU —— 用户什么都不用管。
    gpu：用户显式锁定，但若本机其实没有可用 GPU，仍然回落 CPU 并在日志里
         说明（宁可慢一点，也不能因为设备不可用导致语音功能直接失效）。
    """
    val = ASR_DEVICE_DEFAULT
    try:
        with open(VOICE_SET_PATH, encoding="utf-8") as f:
            for line in f:
                if line.strip().startswith("asr_device"):
                    val = line.split("=", 1)[1].strip().lower()
                    break
    except OSError:
        pass
    if val not in ("auto", "cpu", "gpu"):
        val = ASR_DEVICE_DEFAULT
    if val == "cpu":
        return "cpu"
    ok, _name = gpu_available()
    if val == "gpu" and not ok:
        out("asr_device=gpu requested but no usable GPU -> falling back to CPU")
        return "cpu"
    return "gpu" if ok else "cpu"


def asr_threads():
    """读 voice-settings.txt 的 asr_threads=；缺失/非法/越界一律退回默认。

    要求：>=1 且 <= 物理核数，否则忽略（防止误写成 0 或 999 把机器打死）。
    """
    val = None
    try:
        with open(VOICE_SET_PATH, encoding="utf-8") as f:
            for line in f:
                if line.strip().startswith("asr_threads"):
                    val = line.split("=", 1)[1].strip()
                    break
    except OSError:
        pass
    if val is not None:
        try:
            n = int(val)
            if 1 <= n <= PHYS_CORES:
                return n
        except (TypeError, ValueError):
            pass
    return ASR_THREADS_DEFAULT


# ---- 音频输入设备（麦克风）----
# 需求：「给语音输入增加切换音频输入设备的功能」。
# 值 = sounddevice 的设备索引字符串（"3"），或 "default"（系统默认，老行为）。
# **必须按名字解析而不是死认索引**：设备索引会随插拔 USB 麦 / 开关蓝牙耳机
# 而变化，写死索引下次开机就指到别的设备上了。写入时存「索引|名字」的完整
# 形式，读取时先按名字在当前设备表里找，找不到才退回索引、再退回默认。
ASR_INPUT_DEVICE_DEFAULT = "default"


def _voice_setting(key):
    """读 voice-settings.txt 里某一行的原始值；没有/读不到返回 None。"""
    try:
        with open(VOICE_SET_PATH, encoding="utf-8") as f:
            for line in f:
                if line.strip().startswith(key):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return None


def input_device_names():
    """当前所有**能用**的输入设备的 (索引, 名字) 列表；失败返回空表。

    两道过滤，缺一不可（本机实测 23 个输入设备里只有 10 个真能用）：

    1) `max_input_channels > 0` —— 输出设备（扬声器）混在 sd.query_devices() 里，
       让用户选到扬声器只会得到「打不开麦克风」。

    2) **只保留 MME / DirectSound 两个 hostapi**。同一只实体麦克风在 4 个 hostapi
       下各出现一次，本机全量实测（16k 单声道，正是我们录音的参数）：
         MME(0) 5/5 能开、DirectSound(1) 5/5 能开、
         WASAPI(2) 0/4 能开、WDM-KS(3) 0/9 能开。
       WASAPI 在 16kHz 直接报 Invalid sample rate，WDM-KS 报 Unanticipated host
       error。把打不开的设备列给用户 = 他选完还是没声音，只会以为功能坏了。
       所以宁可只列确定能开的，也不列一堆看着有、点了不响的。

    名字统一压平空白：设备名里可能带换行（蓝牙免手操作的驱动名就带 \r\n），
    而这个名字要当成一行的值写进配置文件、还要在下次启动时按名字匹配回来，
    两边必须同口径。
    """
    try:
        devices = sd.query_devices()
        apis = sd.query_hostapis()
        usable = set()
        for i, a in enumerate(apis):
            # 名字匹配比写死下标稳：不同 PortAudio 构建的 hostapi 顺序可能不同
            nm = str(a.get("name", ""))
            if nm in ("MME", "Windows DirectSound"):
                usable.add(i)
        if not usable:                     # 极端情况：一个都没有 -> 不限制，别把列表清空
            usable = set(range(len(apis)))
        return [(i, " ".join(str(d["name"]).split()))
                for i, d in enumerate(devices)
                if d["max_input_channels"] > 0 and d["hostapi"] in usable]
    except Exception as e:
        out("query_devices failed: %r" % (e,))
        return []


def resolve_input_device(raw):
    """把配置值解析成能直接喂给 sd.InputStream 的 device 参数。

    返回 (device, 说明)：device 为 None = 用 sounddevice 默认设备。
    """
    if not raw or raw.lower() == "default":
        return None, "system default"
    want = raw.split("|", 1)
    idx = None
    try:
        idx = int(want[0])
    except (TypeError, ValueError):
        return None, "bad value %r -> default" % (raw,)
    name = want[1] if len(want) > 1 else ""
    devs = input_device_names()
    # 索引和名字都对得上 -> 直接用（最常见：没插拔过设备）。
    # 必须先做这一步：同一只实体麦克风在 MME 和 DirectSound 下**同名**出现两次，
    # 只按名字找会永远命中第一条，用户在设置窗口选了 DirectSound 那条也会被
    # 悄悄换成 MME 那条（都是能用的设备，不会出错，但和界面显示的不一致）。
    if name:
        key = " ".join(name.split())
        for i, n in devs:
            if i == idx and n == key:
                return i, "%d %s" % (i, n)
        # 索引漂了（插拔过）-> 按名字找。同名多条时取第一条，
        # 反正它们指向同一只麦克风、都能开。
        for i, n in devs:
            if n == key:
                return i, "%d %s (by name)" % (i, n)
    for i, n in devs:                      # 名字也对不上 -> 只剩索引可试
        if i == idx:
            return i, "%d %s (by index)" % (i, n)
    return None, "device %r not found -> default" % (raw,)


def asr_input_device():
    """读 voice-settings.txt 的 asr_input_device= 并解析（每次录音前都读一次）。

    热切换的关键：不缓存 —— 设置窗口改完写盘，下一次按住说话就换设备。
    """
    return resolve_input_device(_voice_setting("asr_input_device"))


# 设备清单落盘，给 C# 设置窗口读。
# 为什么不直接在设置窗口里枚举：设置窗口是纯 .NET，拿不到 sounddevice 的设备表；
# 而有 sounddevice 的只有悬浮球这个 Python 进程。悬浮球本来就在跑，让它把清单
# 写成一个文件是最省事也最可靠的做法（不用给设置窗口硬塞一个 Python 依赖）。
# 设置窗口「刷新设备」时再写一个请求文件，悬浮球看到就重写清单 —— 这样插拔
# USB 麦之后不用重启悬浮球也能刷出来。
MIC_LIST_PATH = os.path.join(RIME_DIR, "mic-devices.txt")
MIC_LIST_REQUEST = os.path.join(RIME_DIR, "mic-devices.refresh")


def write_mic_list():
    """把当前输入设备清单写成 UTF-8 文本（设置窗口读）。

    格式每行 `索引|名字`，第一行固定是 `default|系统默认设备`。

    ★ 绝不要在这里调 sd._terminate() / sd._initialize()：
      这是 0.4s 一次的心跳回调（见 make_hotkey_reloader）调用的，
      而 PortAudio 是**进程级**的 —— _terminate() 会把正在录音的 InputStream
      一起干掉。实测症状：日志 `query_devices failed: PortAudioError('PortAudio
      not initialized')` + `mic open failed: Error querying device -1`，
      也就是「按住说话时正好赶上刷新，这一轮录音直接失效」。
      query_devices() 自己会按需初始化 PortAudio，不需要我们插手。
    """
    lines = ["default|系统默认设备（跟随 Windows）"]
    for i, n in input_device_names():
        # "|" 是分隔符，名字里也出现就把分隔符换成 "/"，否则解析会错位
        #（input_device_names 已经把换行等空白压平了）
        lines.append("%d|%s" % (i, n.replace("|", "/")))
    try:
        with open(MIC_LIST_PATH, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
        out("mic list written: %d devices" % (len(lines) - 1))
    except OSError as e:
        out("mic list write failed: %r" % (e,))


def punct_to_space(text):
    """把识别结果里的标点符号全部换成空格（连续空格合并、首尾去掉）。

    例外：数字中间的小数点/千分位（3.14、1,000）保留，不会被拆开。
    注意：流式的 partial 与最终结果必须走同一个变换，否则对账会错。
    """
    if not text:
        return text
    out = []
    for i, ch in enumerate(text):
        if unicodedata.category(ch).startswith("P"):
            if (ch in ".," and i > 0 and i + 1 < len(text)
                    and text[i - 1].isdigit() and text[i + 1].isdigit()):
                out.append(ch)            # 3.14 / 1,000 里的点和逗号
                continue
            out.append(" ")
        else:
            out.append(ch)
    s = "".join(out)
    s = re.sub(r" {2,}", " ", s)          # 连续空格（多个标点连排）合并成一个
    return s.strip()

# ---- 识别后端：Qwen3-ASR（llama-server 常驻 HTTP），失败自动降级 vosk ----
ASR_HOST = "127.0.0.1"
ASR_PORT = 3966                          # 与 convert_server(5198) 等错开
ASR_HEALTH_URL = "http://%s:%d/health" % (ASR_HOST, ASR_PORT)
ASR_TRANSCRIBE_URL = "http://%s:%d/v1/audio/transcriptions" % (ASR_HOST, ASR_PORT)
# llama-server：环境变量 -> 随包 llama.cpp\ -> 旧开发机路径；找不到则 Qwen 后端不可用
def _find_llama_dir():
    for c in (os.environ.get("RIME_LLAMA_DIR"),
              os.path.join(APP_DIR, "llama.cpp"),
              r"D:\王修翊\llama.cpp"):
        if c and os.path.isfile(os.path.join(c, "llama-server.exe")):
            return c
    return ""


LLAMA_DIR = _find_llama_dir()
LLAMA_SERVER = os.path.join(LLAMA_DIR, "llama-server.exe") if LLAMA_DIR else ""
ASR_MODEL = _find_file("Qwen3-ASR-0.6B-Q8_0.gguf",          # 767MB 主模型
                       [os.environ.get("RIME_VOICE_DIR"), APP_DIR, r"D:\VibeCoding\输入法"])
ASR_MMPROJ = _find_file("mmproj-Qwen3-ASR-0.6B-Q8_0.gguf",   # 音频编码器
                        [os.environ.get("RIME_VOICE_DIR"), APP_DIR, r"D:\VibeCoding\输入法"])
ASR_TIMEOUT = 90                         # 单次转写 HTTP 超时（60s 音频也够）
ASR_BOOT_TIMEOUT = 90                    # 等 server 就绪上限（含模型加载）

TRANS = "#010203"                         # 透明色（胶囊外的区域）
CAP_FILL = "#FFFFFF"                      # 胶囊填充（Apple 系统白）
CAP_EDGE = "#D1D1D6"                      # 胶囊细描边（Apple separator）
CAP_HAIR = "#ECECF1"                      # 外圈柔边（模拟 vibrancy 投影）
ACCENT = "#007AFF"                        # systemBlue（徽章）
GREEN = "#34C759"                         # systemGreen（✓ 已上屏）
WARN = "#FF9500"                          # systemOrange（出错/没识别到）
BAR = "#0A84FF"                           # 声波条外侧（systemBlue 亮调）
BAR_IN = "#5AC8FA"                        # 声波条内侧（systemTeal）
TXT = "#FFFFFF"                           # 徽章内图形（始终白色）
HINT = "#8E8E93"                          # Apple secondary label（备用）
INK = "#1C1C1E"                           # Apple label（提示文字颜色）

# ---- 「已复制」提示（焦点不在输入框时的兜底反馈）----
# 提示用**同一个胶囊**显示：徽章换成剪贴板图形，右侧声波条的位置改成文字，
# 所以不需要另一个窗口、也不会让悬浮球跳位。文字区域就是声波条那块（逻辑
# 像素 x=46..94，宽 48），「已复制」按 15px 中文正好 45px，放得下。
TOAST_TEXT = "已复制"                      # 提示文字（--toast 可覆盖）
TOAST_MS = 1600                           # 提示最短停留（毫秒）
TOAST_MS_MAX = 5000                       # 复制兜底的上限：字没上屏，必须留够阅读时间
TOAST_MS_OK_MAX = 2500                    # 保留给兼容调用；输入框成功路径使用 TOAST_MS
TOAST_FONT_SIZES = (15, 14, 13, 12, 11)   # 依次试到放得下为止（逻辑像素）

# ---- 固定提示的文字布局 ----
# 识别结果不再绘制到悬浮球：输入框成功时只显示绿色对勾，非输入框时只显示
# 「已复制」。保留这套布局供 `--toast` 手工验收固定提示时使用。
TEXT_MAX_W = 560.0                        # 固定提示胶囊的最大宽度（逻辑像素）
TEXT_PAD_R = 8                            # 文字右侧留白（和 _text 里保持一致）


def fit_text(text, max_w, measure):
    """在 max_w 宽度内放下 text，返回 `(字号, 实际要画的文字)`。

    **纯函数**：宽度由调用方注入的 `measure(size, text) -> 像素宽` 提供，
    所以单测可以塞一个假的测量函数，不需要真字体、也不需要窗口。

    策略：从最大字号往下试，第一个放得下整段话的字号就赢（字号优先，宁可小
    一点也不截断）；所有字号都放不下时才用最小字号 + 省略号截断，用二分找出
    最多能显示几个字。
    """
    if not text:
        return TOAST_FONT_SIZES[0], ""
    for size in TOAST_FONT_SIZES:
        if measure(size, text) <= max_w:
            return size, text
    size = TOAST_FONT_SIZES[-1]               # 最小字号仍放不下 -> 截断
    if measure(size, text) <= max_w:
        return size, text
    ell = "…"
    w_ell = measure(size, ell)
    if w_ell > max_w:
        return size, ""
    lo, hi = 0, len(text)
    while lo < hi:                            # 二分找最多能放几个字
        mid = (lo + hi + 1) // 2
        if measure(size, text[:mid]) + w_ell <= max_w:
            lo = mid
        else:
            hi = mid - 1
    return size, (text[:lo] + ell if lo < len(text) else text)


def toast_ms(n, cap=TOAST_MS_MAX):
    """提示停留时长：按字数放宽（长句子要留够阅读时间），TOAST_MS ~ cap。

    纯函数，单测直接钉住上下界。「已复制」3 个字 -> 还是原来的 1.6s。
    `cap` 区分两种提示：复制兜底要久（字没上屏，球是唯一的展示），
    固定提示只显示很短的状态文字；输入框成功路径不绘制识别全文。
    """
    return int(max(TOAST_MS, min(TOAST_MS + (n - 3) * 90, cap)))

# ---- 剪贴板（只在「焦点不在输入框 / 注入没落地」两条兜底路径上用）----
CF_UNICODETEXT = 13
GMEM_MOVEABLE = 0x0002
CLIP_RETRY = 5                            # 剪贴板被别人占着时的退避重试次数


_LOG_LOCK = threading.Lock()


def out(msg):
    line = "%s %s" % (time.strftime("%H:%M:%S"), msg)
    try:
        with _LOG_LOCK:              # 多线程并发写同一文件会交错，必须串行
            with open(LOG_PATH, "a", encoding="utf-8") as f:
                f.write(line + "\n")
    except Exception:
        pass
    if sys.stdout is not None:
        print(line, flush=True)


def _blend(c1, c2, t):
    """两种 #RRGGBB 按 t 线性混合（用于脉冲环渐隐）。"""
    t = 0.0 if t < 0 else (1.0 if t > 1 else t)
    a = [int(c1[i:i + 2], 16) for i in (1, 3, 5)]
    b = [int(c2[i:i + 2], 16) for i in (1, 3, 5)]
    return "#%02X%02X%02X" % tuple(
        int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


# ------------------------------------------------------- Qwen3-ASR（llama-server）
def asr_alive(timeout=1.0):
    """探测本机 llama-server 是否就绪（GET /health）。"""
    import urllib.request
    import urllib.error
    try:
        with urllib.request.urlopen(ASR_HEALTH_URL, timeout=timeout):
            return True
    except (urllib.error.URLError, OSError):
        return False


def asr_start(wait=ASR_BOOT_TIMEOUT):
    """确保 llama-server 常驻；已存活则直接返回 True。等待就绪（含模型加载）。"""
    if asr_alive(1.0):
        return True
    if not (os.path.isfile(LLAMA_SERVER) and os.path.isfile(ASR_MODEL)
            and os.path.isfile(ASR_MMPROJ)):
        out("asr skip: missing files")
        return False
    device = asr_device()
    # GPU：-ngl 99 = 把所有层都放进显存（模型只有 0.6B，8GB 显存绰绰有余）。
    # 显存不够时 llama.cpp 自己会把放不下的层留在内存，不会启动失败。
    args = [LLAMA_SERVER,
            "-m", ASR_MODEL,
            "--mmproj", ASR_MMPROJ,
            "--host", ASR_HOST, "--port", str(ASR_PORT),
            "--ctx-size", "4096", "-np", "1"]
    if device == "gpu":
        # GPU 推理时 CPU 只做前后处理，线程数开小一点更省（也不再用 -tb 调批处理）
        args += ["-ngl", "99", "-t", str(min(4, PHYS_CORES))]
    else:
        args += ["-t", str(asr_threads()), "-tb", str(asr_threads())]
    args += ["--no-webui", "--no-warmup"]
    out("asr device=%s" % device)
    try:
        subprocess.Popen(
            args,
            cwd=LLAMA_DIR,
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=subprocess.CREATE_NO_WINDOW)
    except Exception as e:
        out("asr spawn failed: %r" % (e,))
        return False
    t0 = time.time()
    while time.time() - t0 < wait:
        if asr_alive(2.0):
            out("asr server ready in %.1fs" % (time.time() - t0))
            return True
        time.sleep(0.5)
    out("asr server not ready after %ds" % wait)
    return False


def _wav_bytes(frames):
    """int16 块列表 -> 16k 单声道 wav 字节。"""
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(b"".join(frames))
    return buf.getvalue()


def asr_recognize(frames):
    """Qwen3-ASR HTTP 转写；任何失败返回 None（上层降级 vosk）。"""
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
            + ("--%s--\r\n" % boundary).encode("ascii"))
    req = urllib.request.Request(
        ASR_TRANSCRIBE_URL, data=body, method="POST",
        headers={"Content-Type": "multipart/form-data; boundary=%s"
                 % boundary})
    try:
        with urllib.request.urlopen(req, timeout=ASR_TIMEOUT) as r:
            raw = r.read().decode("utf-8", "replace")
    except Exception as e:
        out("asr http error: %r" % (e,))
        return None
    try:
        text = json.loads(raw).get("text", "") or ""
    except Exception:
        out("asr bad response: %s" % raw[:200])
        return None
    # 回包形如 'language Chinese<asr_text>今天天气真好。'——剥掉前导提示词
    if "<asr_text>" in text:
        text = text.split("<asr_text>", 1)[1]
    text = text.replace("</asr_text>", "").strip()
    # 提示词回声过滤：音频里没有清晰语音时，模型可能把 server 的 ASR
    # 提示词原样吐出来（实测 'Transcribe audio to text (language: zh).'），
    # 绝不能把这段英文打进输入框。
    low = text.lower()
    for echo in ("transcribe audio to text", "perform asr",
                 "transcribe audio", "audio to text"):
        if echo in low:
            out("asr prompt echo filtered: %r" % text[:60])
            return ""
    # 标点转空格开关：流式的 partial 和最终结果都从这里出去，保证变换一致
    if punct_space_enabled():
        text = punct_to_space(text)
    return text


# ------------------------------------------------------------- 热键（可配置）
# 快捷键写在 <RimeDir>\voice-settings.txt 的 hotkey= 字段（设置窗口「语音输入」
# 页的录制按钮写入），voice-overlay 每 0.4s 看一次 mtime 热更新：改完**立即生效，
# 不用重启悬浮球**。格式：键名用 + 连接，如 ctrl+win、ctrl+alt+space。
# 录制新快捷键时设置窗口会写 hotkey_recorder_pid=<它的 pid>，本进程查到那个进程
# 还活着就暂停检测（免得「录制」本身被当成一次触发），进程一没就自动恢复。
HOTKEY_DEFAULT = ("ctrl", "win")

VK_LCONTROL, VK_RCONTROL = 0xA2, 0xA3
VK_LWIN, VK_RWIN = 0x5B, 0x5C
VK_LMENU, VK_RMENU = 0xA4, 0xA5
VK_LSHIFT, VK_RSHIFT = 0xA0, 0xA1
CTRL_VKS = (VK_LCONTROL, VK_RCONTROL)
WIN_VKS = (VK_LWIN, VK_RWIN)
ALT_VKS = (VK_LMENU, VK_RMENU)
SHIFT_VKS = (VK_LSHIFT, VK_RSHIFT)
# 修饰键组：左右两侧合并成一组（按任意一侧都算数）。
MOD_GROUPS = (("ctrl", CTRL_VKS), ("alt", ALT_VKS),
              ("shift", SHIFT_VKS), ("win", WIN_VKS))
MOD_TOKENS = frozenset(name for name, _ in MOD_GROUPS)
# 必须至少有一个「不会和正常打字撞车」的修饰键：Ctrl/Alt/Win。
# （只有 Shift 的话 Shift+字母就是普通打字，一按就开录，绝对不能收。）
HOTKEY_SAFE_MODS = frozenset(("ctrl", "alt", "win"))

# 非修饰键的可读名（VK -> token）。没列到的键也能用，写成 vk:0xNN。
VK_NAMES = {
    0x08: "backspace", 0x09: "tab", 0x0D: "enter", 0x1B: "esc",
    0x20: "space", 0x21: "pageup", 0x22: "pagedown", 0x23: "end", 0x24: "home",
    0x25: "left", 0x26: "up", 0x27: "right", 0x28: "down",
    0x2C: "printscreen", 0x2D: "insert", 0x2E: "delete",
}
VK_NAMES.update({0x30 + i: str(i) for i in range(10)})
VK_NAMES.update({0x41 + i: chr(ord("a") + i) for i in range(26)})
VK_NAMES.update({0x70 + i: "f%d" % (i + 1) for i in range(24)})
VK_NAMES.update({0xBA: "semicolon", 0xBB: "equals", 0xBC: "comma",
                 0xBD: "minus", 0xBE: "period", 0xBF: "slash",
                 0xC0: "backquote", 0xDB: "lbracket", 0xDC: "backslash",
                 0xDD: "rbracket", 0xDE: "quote"})
_NAME2VK = {name: vk for vk, name in VK_NAMES.items()}


def token_to_vk(token):
    """token -> VK；不认识返回 None。"""
    t = str(token).strip().lower()
    if t in _NAME2VK:
        return _NAME2VK[t]
    m = re.fullmatch(r"vk:0x([0-9a-f]{1,2})", t)
    if m:
        return int(m.group(1), 16)
    return None


def vk_to_token(vk):
    return VK_NAMES.get(vk, "vk:0x%02X" % vk)


def parse_hotkey(text):
    """'ctrl+alt+space' -> ([tokens], err)；err 为空表示合法，token 顺序已规范化。"""
    parts = [p.strip().lower() for p in str(text or "").split("+")]
    toks = [p for p in parts if p]
    if not toks:
        return [], "快捷键是空的"
    if len(toks) > 4:
        return [], "最多 4 个键"
    seen = set()
    for t in toks:
        if t in seen:
            return [], "按键重复：%s" % t
        seen.add(t)
        if t not in MOD_TOKENS and token_to_vk(t) is None:
            return [], "不认识这个按键：%s" % t
    if not (seen & HOTKEY_SAFE_MODS):
        return [], "至少要包含 Ctrl / Alt / Win 之一（只有 Shift 会和正常打字冲突）"
    if seen == {"win"}:
        return [], "单独按 Win 会弹出开始菜单，换一个组合"
    # 规范化顺序：修饰键按 ctrl/alt/shift/win，其余按 VK 升序
    mods = [n for n, _ in MOD_GROUPS if n in seen]
    rest = sorted(seen - set(mods), key=lambda t: token_to_vk(t))
    return mods + rest, ""


def format_hotkey(tokens):
    """['ctrl','win'] -> 'Ctrl + Win'；['f9'] -> 'F9'（写日志用）。"""
    disp = {"ctrl": "Ctrl", "alt": "Alt", "shift": "Shift", "win": "Win",
            "space": "Space", "enter": "Enter", "esc": "Esc", "tab": "Tab"}

    def one(t):
        if t in disp:
            return disp[t]
        if len(t) == 1 or re.fullmatch(r"f\d{1,2}", t):   # 'a'->'A'、'f9'->'F9'
            return t.upper()
        return t

    return " + ".join(one(t) for t in tokens)


def read_hotkey(path=VOICE_SET_PATH):
    """读 hotkey= 字段；文件缺失/字段缺失/不合法一律退回默认（绝不因为配置崩）。"""
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                m = re.match(r"\s*hotkey\s*=\s*(.+?)\s*$", line)
                if not m:
                    continue          # hotkey_recorder_pid 不会被这条匹配到
                toks, err = parse_hotkey(m.group(1))
                if err:
                    out("hotkey config invalid (%s), use default" % err)
                    return list(HOTKEY_DEFAULT)
                return toks
    except OSError:
        pass
    return list(HOTKEY_DEFAULT)


def _pid_alive(pid):
    """OpenProcess 探活（不 kill、不等待）；查不到就当它没了。"""
    k32 = ctypes.windll.kernel32
    k32.OpenProcess.argtypes = [wt.DWORD, wt.BOOL, wt.DWORD]
    k32.OpenProcess.restype = wt.HANDLE
    k32.CloseHandle.argtypes = [wt.HANDLE]
    k32.CloseHandle.restype = wt.BOOL
    h = k32.OpenProcess(0x1000, False, int(pid))   # PROCESS_QUERY_LIMITED_INFORMATION
    if not h:
        return False
    k32.CloseHandle(h)
    return True


def hotkey_recording_active():
    """设置窗口正在录制新快捷键时返回 True（暂停检测，免得把录制当触发）。"""
    try:
        with open(VOICE_SET_PATH, encoding="utf-8") as f:
            for line in f:
                m = re.match(r"\s*hotkey_recorder_pid\s*=\s*(\d+)", line)
                if m and _pid_alive(int(m.group(1))):
                    return True
    except OSError:
        pass
    return False


def make_hotkey_reloader(detector):
    """返回一个每 0.4s 调一次的回调：配置变了就换检测器的键，返回 True 表示换了。

    顺带服务「设置窗口要设备清单」的请求文件（见 write_mic_list）：放在这里是因为
    这个回调本来就是 0.4s 一次的心跳，不用额外开线程。
    """
    try:
        stamp = [os.path.getmtime(VOICE_SET_PATH)]
    except OSError:
        stamp = [0.0]

    def reload_if_changed():
        # 设置窗口点「刷新设备」会写这个请求文件 -> 重写清单并删掉请求
        if os.path.isfile(MIC_LIST_REQUEST):
            try:
                os.remove(MIC_LIST_REQUEST)
            except OSError:
                pass
            write_mic_list()
        try:
            m = os.path.getmtime(VOICE_SET_PATH)
        except OSError:
            return False
        if m == stamp[0]:
            return False
        stamp[0] = m
        tokens = read_hotkey()
        if list(tokens) == list(detector.keys):
            return False
        detector.set_keys(tokens)
        out("hotkey reloaded -> %s" % format_hotkey(tokens))
        return True

    return reload_if_changed


# ------------------------------------------------------------- 热键状态机（长按）


class ChordDetector:
    """长按式组合键检测（观察式，只收事件，不拦截任何按键）。

    快捷键可配置：`keys` 是 token 列表，默认 ctrl+win，也可来自设置窗口
    （如 ["ctrl","alt","space"]）。语义不变：
      start —— **所有**键同按持续 arm 秒（长按意图确认）；
      stop  —— 按住期间任意一个键松开（说话结束）；
      abort —— 按住期间出现第三个键（系统组合），立即作废。

    规则：
    - 短于 arm 的点按什么都不发（防误触）；
    - abort 后必须**所有键全部松开**才重新武装，避免半途中途重触发；
    - stop 后同样要求全部松开再武装（松开一个按回另一个不会连发）。
    """

    def __init__(self, emit, arm=ARM_DELAY, keys=None):
        self.emit = emit
        self.arm = arm
        self._lock = threading.Lock()
        self._timer = None
        self.active = False      # 已发出 start，等待 stop/abort
        self.cancelled = False   # 第三键作废，等全松开
        self.keys = ()           # token 列表（配置）
        self.groups = ()         # 每个 token 对应的 VK 组（左右键合成一组）
        self._down = {}          # VK -> 是否按下（本轮）
        self._idx = {}           # VK -> 组序号
        self.set_keys(keys if keys is not None else list(HOTKEY_DEFAULT))

    # ---- 配置 ----
    def set_keys(self, keys):
        """换快捷键（配置热更新时由轮询线程调用；若正在录音会先发 stop 收尾）。"""
        keys = [str(t).lower() for t in keys]
        groups = []
        keep = []
        for name in keys:
            if name in MOD_TOKENS:
                for gname, vks in MOD_GROUPS:
                    if gname == name:
                        groups.append(tuple(vks))
                        keep.append(name)
                        break
            else:
                vk = token_to_vk(name)
                if vk is not None:
                    groups.append((vk,))
                    keep.append(name)
        if not groups:            # 配置被写坏了 -> 退回默认，绝不罢工
            keys, groups = list(HOTKEY_DEFAULT), [CTRL_VKS, WIN_VKS]
            keep = list(HOTKEY_DEFAULT)
        with self._lock:
            was_active = self.active
            self.active = False
            self.cancelled = False
            self._cancel_timer()
            self.keys = tuple(keep)
            self.groups = tuple(groups)
            self._down = {vk: False for g in groups for vk in g}
            self._idx = {vk: i for i, g in enumerate(groups) for vk in g}
        if was_active:
            self._emit("stop")     # 换键时正在说话 -> 立刻收尾，别拖到超时
        return self.keys

    def poll_keys(self):
        """轮询线程每轮要读的 VK 列表。"""
        return tuple(self._down)

    def scan_skip(self):
        """第三键扫描要跳过的 VK：通用修饰码 + 快捷键自己的键 + VK_PACKET。"""
        return SCAN_SKIP | set(self._down)

    def _all_down(self):
        """所有组都处于按下（同组任一两侧即可）。"""
        for g in self.groups:
            if not any(self._down.get(vk) for vk in g):
                return False
        return bool(self.groups)

    def any_down(self):
        return any(self._down.values())

    def _cancel_timer(self):
        if self._timer is not None:
            try:
                self._timer.cancel()
            except Exception:
                pass
            self._timer = None

    def _emit(self, kind):
        try:
            self.emit(kind)
        except Exception as e:          # 回调再炸也不能弄死轮询线程
            out("chord callback error: %r" % (e,))

    def on_key(self, vk, down):
        with self._lock:
            if vk in self._idx:
                self._down[vk] = down
            else:
                # 第三个键：长按期间出现 -> 立即中止；否则记作废
                if down and self._all_down() and not self.cancelled:
                    self.cancelled = True
                    # 只在“刚翻转成作废”时打一行，方便查“为什么刚按就断”
                    out("chord aborted by third key: vk=0x%02X (%s)"
                        % (vk, vk_to_token(vk)))
                    self._cancel_timer()
                    if self.active:
                        self.active = False
                        self._emit("abort")
                return

            all_down = self._all_down()
            if self.active:
                if not all_down:              # 松开任意一个 -> 结束说话
                    self.active = False
                    self._cancel_timer()
                    self._emit("stop")
            elif all_down and not self.cancelled:
                # 长按确认：arm 秒后所有键仍是按下才发 start
                self._cancel_timer()
                t = threading.Timer(self.arm, self._arm_fire)
                t.daemon = True
                self._timer = t
                t.start()
            elif not all_down and self._timer is not None:
                # arm 内松开了 -> 只是误触，安静取消
                self._cancel_timer()

            if not self.any_down():
                self.cancelled = False      # 全松开 -> 重新武装

    def _arm_fire(self):
        with self._lock:
            if self._all_down() and not self.cancelled and not self.active:
                self._timer = None
                self.active = True
                self._emit("start")

    def needs_scan(self):
        """轮询线程仅在所有键按下时才扫描第三个键（平时零开销）。"""
        with self._lock:
            return self._all_down()


# ------------------------------------------------------- 按键轮询（无钩子）
POLL_MS = 20
CFG_POLL_S = 0.4                       # 配置热更新 / 录制暂停的检查间隔（秒）
# 第三键扫描必须跳过的 VK（固定部分；**快捷键自己的键**由 detector.scan_skip()
# 再补上，这样换成 ctrl+space 之类时，Ctrl/Win 才不会被误当成“自己的键”漏检）：
# 0x10/0x11/0x12 是 Shift/Ctrl/Alt 的“通用码”——按住任意一侧 Ctrl 时
# GetAsyncKeyState(0x11) 也返回按下，若不排除会把我们自己按的 Ctrl
# 误判成第三键、每次长按都立刻 abort。具体左右键由 detector 那边跳过。
# 0xE7=VK_PACKET：SendInput(KEYEVENTF_UNICODE) 注入字符时系统短暂把该键
# 置为按下——流式上屏发生在“按住期间”，不排除会把我们自己注入的文字
# 误判成第三键、边说边自我 abort（实测 POLLER_SEEN=[231]）。
SCAN_SKIP = {0x10, 0x11, 0x12, 0xE7}


def _phys_all_down(cache, groups, extra=()):
    """按轮询缓存判断「每组都有键真的按着」（组内任一两侧即可）。

    extra：被 WinKeyGate 钩子吞掉的 VK —— 它们轮询永远读不到（键没进系统
    队列），但钩子只在真按下时才喂事件，所以这里直接当成按下。
    """
    for g in groups:
        if not any(cache.get(vk, False) or (vk in extra) for vk in g):
            return False
    return bool(groups)


def poll_main(detector, stop_evt, on_reload=None):
    """热键检测：轮询 GetAsyncKeyState，**不安装任何系统键盘钩子**。

    教训：早先版本用 WH_KEYBOARD_LL 观察式钩子，但 ctypes 不声明 argtypes
    时会把 64 位 lParam 截断成 32 位再传给 CallNextHookEx，污染下游钩子链
    （现象：全系统无法输入、无法切换输入法、Win 键无反应）。轮询方式对
    系统输入零风险：本进程哪怕立刻卡死，键盘也完全不受影响。

    每轮还要顺带做两件便宜事（都在 0.4s 一次的慢节拍里）：
      1. on_reload()：设置窗口改了 hotkey= 就热更新检测器（不用重启）；
      2. hotkey_recording_active()：设置窗口正在录制新快捷键时暂停检测，
         免得「录制」这个动作本身被当成一次长按触发。
    """
    user32 = ctypes.windll.user32
    user32.GetAsyncKeyState.argtypes = [ctypes.c_int]
    user32.GetAsyncKeyState.restype = ctypes.c_short

    def down(vk):
        return bool(user32.GetAsyncKeyState(vk) & 0x8000)

    out("keyboard poller started (%dms, no hook) hotkey=%s"
        % (POLL_MS, format_hotkey(detector.keys)))
    last = {}                     # 上一轮各 VK 的按下状态
    next_cfg = time.time() + CFG_POLL_S
    suspended = False             # 设置窗口正在录制新快捷键时暂停检测
    try:
        while not stop_evt.is_set():
            now = time.time()
            if now >= next_cfg:              # 0.4s 一次的慢节拍：配置 + 录制暂停
                next_cfg = now + CFG_POLL_S
                if on_reload and on_reload():
                    last.clear()   # 换键了，重新采样当前物理状态
                rec = hotkey_recording_active()
                if rec != suspended:
                    suspended = rec
                    out("hotkey poller %s (settings window recording)"
                        % ("paused" if rec else "resumed"))
            if suspended:
                # 录制中：把检测器里的按下状态全部清掉（送 stop/abort 收尾）
                for vk, was in last.items():
                    if was:
                        detector.on_key(vk, False)
                        last[vk] = False
                stop_evt.wait(POLL_MS / 1000.0)
                continue

            # 被 WinKeyGate 吞掉的键（Win 系）轮询读不到，事件由钩子直接喂，
            # 这里必须跳过，否则会立刻用 d=False 把刚按下的状态覆盖掉。
            owned = hook_owned_vks()
            for vk in detector.poll_keys():
                if vk in owned:
                    continue
                d = down(vk)
                if last.get(vk, False) != d:
                    detector.on_key(vk, d)
                    last[vk] = d
            # 第三键扫描只在「快捷键的键**物理上**确实都按着」时跑：--simulate
            # 是用合成状态驱动的，此时真实按键不能算第三键（否则测试期间用户
            # 敲的字会把录音打断）。线上两种状态本来永远一致，这里是零开销。
            if detector.needs_scan() and _phys_all_down(
                    last, detector.groups, owned):
                skip = detector.scan_skip() | owned
                for vk in range(8, 256):
                    if vk in skip:
                        continue
                    if down(vk):
                        detector.on_key(vk, True)
                        break
            stop_evt.wait(POLL_MS / 1000.0)
    except Exception as e:
        out("poller error: %r" % (e,))
    out("keyboard poller stopped")


# ------------------------------------------- Win 键抢占（防微信输入法吞掉热键）
# 微信输入法 3.0（wetype_update.exe）用 WH_KEYBOARD_LL 把 **Ctrl+Win** 整段吞掉
# 去开它自己的「语音输入」面板：键进不了系统队列，GetAsyncKeyState 也看不到，
# 本程序的 20ms 轮询于是完全失效（现象：按住没反应，弹的是微信的语音面板）。
# 修法：用同层钩子把 Win 键抢回来 —— 只在「快捷键需要 Win + 其余修饰键此刻
# 都按着」时拦下 Win 的按下/抬起，并直接喂给 ChordDetector；其余按键原样放行。
#
# 三条纪律（都是踩过的坑，改这里之前先读一遍）：
#   1. 钩子必须跑在**自带消息循环**的线程上：WH_KEYBOARD_LL 不泵消息就永不回调，
#      还会把整机输入卡到 LowLevelHooksTimeout（现象：全系统无法输入）。
#   2. ctypes 必须显式声明 argtypes/restype：x64 下 CallNextHookEx 的 lParam 若被
#      截成 32 位，会污染下游钩子链（早先版本就是这样把 Win 键弄死的）。
#   3. 钩子回调里绝不做 IO、不拿锁、不打日志：只读缓存 + GetAsyncKeyState。
WH_KEYBOARD_LL = 13
WM_KEYDOWN, WM_KEYUP = 0x0100, 0x0101
WM_SYSKEYDOWN, WM_SYSKEYUP = 0x0104, 0x0105
WM_QUIT = 0x0012
QS_ALLINPUT = 0x04FF
PM_REMOVE = 0x0001
# 重装周期：Windows 的低级键盘钩子链是「后装的先被调用」，重装一次就排到链首，
# 才能先于微信输入法的钩子看到 Win 键。微信输入法自己也会重装（切窗口、关面板
# 时都会），1.5s 太慢 —— 实测真实按键时会漏，两个语音面板同时弹出来。0.25s
# 的重装成本可以忽略（SetWindowsHookEx 是微秒级，且重装不产生空窗期）。
REARM_S = 0.25
BEAT_S = 300.0                   # 诊断心跳：把钩子计数写进日志（seen/fed）
WIN_VK_SET = frozenset(WIN_VKS)


class KBDLLHOOKSTRUCT(ctypes.Structure):
    _fields_ = [("vkCode", wt.DWORD), ("scanCode", wt.DWORD),
                ("flags", wt.DWORD), ("time", wt.DWORD),
                ("dwExtraInfo", ctypes.c_size_t)]


class _MSG(ctypes.Structure):
    _fields_ = [("hwnd", wt.HWND), ("message", wt.UINT),
                ("wParam", ctypes.c_size_t), ("lParam", ctypes.c_ssize_t),
                ("time", wt.DWORD), ("pt", wt.POINT)]


_HOOK_GATE = None                # 全局单例；poll_main 读它判断哪些 VK 归钩子管


def hook_owned_vks():
    """钩子自己消化的 VK（被吞掉的键轮询看不到，必须跳过）。"""
    return _HOOK_GATE.owned() if _HOOK_GATE is not None else frozenset()


class WinKeyGate:
    """把 Win 键从微信输入法的低级键盘钩子手里抢回来。

    只在两种条件下拦键，别的一律放行：
      * 快捷键里含 win（本机就是 ctrl+win）；
      * 其余每一组修饰键此刻都按着（ctrl 按着才拦 Win）。
    拦下的 Win 事件直接喂给 ChordDetector —— 因为被吞掉的键轮询永远看不到，
    所以这两件事必须在钩子里一起做。副作用：按住 Ctrl 时 Win 组合键
    （Win+Ctrl+D / Win+Ctrl+←）会失效，这正是「Ctrl+Win 归语音输入」的代价。
    """

    def __init__(self, detector, stop_evt, log=out):
        self.detector = detector
        self.stop_evt = stop_evt
        self.log = log
        self.hook = None
        self.hooks = []              # 历史句柄：换钩子时先装新的、再卸旧的，不留空窗
        self.thread = None
        self.tid = 0
        self.swallowed = set()
        self._track = {}             # VK -> 吞下时刻（只在钩子里写，释放时打一行时长）
        self.seq = collections.deque(maxlen=64)   # 钩子看到的事件序列（诊断）
        self.seen = 0                # 钩子收到的 Win 事件数（诊断用，只加计数不做 IO）
        self.fed = 0                 # 其中真正喂给检测器的数量
        self.paused = False          # 设置窗口正在录制新快捷键
        self._proc_ref = None
        self._logged_ok = False
        self._logged_fail = False
        self._user32 = ctypes.windll.user32
        self._k32 = ctypes.windll.kernel32
        self._k32.GetModuleHandleW.argtypes = [wt.LPCWSTR]
        self._k32.GetModuleHandleW.restype = ctypes.c_void_p

    # ---- 判断 ----
    def wanted(self):
        return any(k == "win" for k in self.detector.keys)

    def owned(self):
        return WIN_VK_SET if self.hook else frozenset()

    def _others_down(self):
        """除 Win 那组之外，其余每组是否都有键按着（ctrl / alt ...）。"""
        groups = [g for g in self.detector.groups
                  if not any(vk in WIN_VK_SET for vk in g)]
        if not groups:
            return False
        gsk = self._user32.GetAsyncKeyState
        for g in groups:
            if not any(gsk(vk) & 0x8000 for vk in g):
                return False
        return True

    # ---- 钩子回调（必须极快）----
    def _proc(self, ncode, wparam, lparam):
        try:
            if ncode == 0 and not self.paused:
                kb = ctypes.cast(lparam, ctypes.POINTER(KBDLLHOOKSTRUCT)).contents
                vk = int(kb.vkCode)
                if vk in WIN_VK_SET:
                    self.seen += 1
                    self.seq.append(("W", vk, int(wparam), round(time.time() % 1000, 2)))
                    if wparam in (WM_KEYDOWN, WM_SYSKEYDOWN):
                        # 一律喂给检测器（保持原行为：先按 Win 再按 Ctrl 也算长按，
                        # 此时 Win 已经放行给系统、开始菜单照旧会弹）。
                        self.fed += 1
                        self.detector.on_key(vk, True)
                        if self._others_down():
                            # 其余修饰键都按着 -> 这是「Ctrl+Win 语音键」，
                            # 吞掉，别让 Win 键跑去开开始菜单。
                            self.swallowed.add(vk)
                            self._track[vk] = time.time()
                            return 1
                    elif wparam in (WM_KEYUP, WM_SYSKEYUP):
                        self.detector.on_key(vk, False)
                        if vk in self.swallowed:
                            self.swallowed.discard(vk)
                            t = self._track.pop(vk, None)
                            if t:
                                self.log("gate held Win %.2fs before release"
                                         % (time.time() - t))
                            return 1
        except Exception:
            pass                         # 钩子里绝不抛：抛了就是整机输入停摆
        return self._user32.CallNextHookEx(None, ncode, wparam, lparam)

    # ---- 安装 / 卸载（只在钩子线程里调）----
    def _install(self):
        u = self._user32
        u.SetWindowsHookExW.argtypes = [ctypes.c_int, ctypes.c_void_p,
                                        ctypes.c_void_p, wt.DWORD]
        u.SetWindowsHookExW.restype = ctypes.c_void_p
        u.CallNextHookEx.argtypes = [ctypes.c_void_p, ctypes.c_int,
                                     ctypes.c_ssize_t, ctypes.c_ssize_t]
        u.CallNextHookEx.restype = ctypes.c_ssize_t
        u.UnhookWindowsHookEx.argtypes = [ctypes.c_void_p]
        u.UnhookWindowsHookEx.restype = wt.BOOL
        if self._proc_ref is None:
            self._proc_ref = ctypes.WINFUNCTYPE(
                ctypes.c_ssize_t, ctypes.c_int, ctypes.c_size_t,
                ctypes.c_ssize_t)(self._proc)
        # hMod 必须给真实模块句柄：全局 WH_KEYBOARD_LL 传 NULL 时
        # SetWindowsHookExW 会「成功返回句柄」但回调永不触发（seen 恒 0）。
        hmod = self._k32.GetModuleHandleW(None)   # 在 kernel32，不在 user32
        new = u.SetWindowsHookExW(WH_KEYBOARD_LL, self._proc_ref, hmod, 0)
        if new:
            old = self.hook
            self.hook = new
            self.hooks.append(new)
            # 先装后卸：新的已经在链首了，再把旧的摘掉。反过来的话（先卸再装）
            # 从摘掉到装上的那一小段里，钩子链上没有我们 —— 正好按键落在那里，
            # 微信输入法就把 Win 键拿走开了自己的语音面板。
            if old:
                try:
                    u.UnhookWindowsHookEx(old)
                except Exception:
                    pass
                if old in self.hooks:
                    self.hooks.remove(old)
            if not self._logged_ok:
                self._logged_ok = True
                self.log("win-key gate installed (preempts WeChat IME voice hotkey)")
        elif not self._logged_fail:
            self._logged_fail = True
            self.log("win-key gate install FAILED err=%d -> poll only"
                     % ctypes.get_last_error())

    def _uninstall(self):
        for h in self.hooks:
            try:
                self._user32.UnhookWindowsHookEx(h)
            except Exception:
                pass
        self.hooks = []
        self.hook = None
        self.swallowed.clear()

    def _rearm(self):
        if self.paused and self.swallowed:
            # 进了「设置窗口录制中」：把还按着的 Win 事件补一个抬起，否则检测器
            # 会一直以为自己还在长按（录制期间没人会替它送 stop）。
            for vk in list(self.swallowed):
                self.swallowed.discard(vk)
                try:
                    self.detector.on_key(vk, False)
                except Exception:
                    pass
        want = self.wanted()
        if want:
            self._install()              # 重装一次 = 排到钩子链首，压住微信输入法
        elif self.hooks:
            self._uninstall()

    # ---- 线程：自带消息循环 ----
    def _run(self):
        u = self._user32
        u.PeekMessageW.argtypes = [ctypes.POINTER(_MSG), ctypes.c_void_p,
                                   ctypes.c_uint, ctypes.c_uint, ctypes.c_uint]
        u.PeekMessageW.restype = wt.BOOL
        u.TranslateMessage.argtypes = [ctypes.POINTER(_MSG)]
        u.DispatchMessageW.argtypes = [ctypes.POINTER(_MSG)]
        u.DispatchMessageW.restype = ctypes.c_ssize_t
        u.MsgWaitForMultipleObjects.argtypes = [wt.DWORD, ctypes.c_void_p,
                                                wt.BOOL, wt.DWORD, wt.DWORD]
        u.MsgWaitForMultipleObjects.restype = wt.DWORD
        self.tid = self._k32.GetCurrentThreadId()
        msg = _MSG()
        next_rearm = 0.0
        next_beat = 0.0
        try:
            while not self.stop_evt.is_set():
                now = time.time()
                if now >= next_beat:
                    next_beat = now + BEAT_S
                    self.log("win-key gate alive hook=%s seen=%d fed=%d "
                             "swallowed=%s paused=%s"
                             % (bool(self.hook), self.seen, self.fed,
                                sorted(self.swallowed), self.paused))

                if now >= next_rearm:
                    next_rearm = now + REARM_S
                    try:
                        self.paused = hotkey_recording_active()
                    except Exception:
                        self.paused = False
                    self._rearm()
                while u.PeekMessageW(ctypes.byref(msg), None, 0, 0, PM_REMOVE):
                    if msg.message == WM_QUIT:
                        self._uninstall()
                        return
                    u.TranslateMessage(ctypes.byref(msg))
                    u.DispatchMessageW(ctypes.byref(msg))
                u.MsgWaitForMultipleObjects(0, None, False, 50, QS_ALLINPUT)
        except Exception as e:
            self.log("win-key gate error: %r" % (e,))
        finally:
            self._uninstall()

    def start(self):
        global _HOOK_GATE
        _HOOK_GATE = self
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()
        return self


# ------------------------------------------- 微信输入法语音面板：结果侧兜底抑制
# 为什么光有 WinKeyGate 不够：它抢的是「钩子链首」这个**位置**，而微信输入法自己
# 也会重装钩子（切输入法、关面板、心跳都会），这个位置是抢来的、不是稳的。真实
# 按键时偶尔它先拿到 Win 键 —— 于是它的「语音输入」面板和我们的胶囊一起弹出来。
# 这一层不看键，只看**结果**：本程序这次语音开始之后，屏幕上只要冒出微信输入法的
# 语音面板就把它按下去。持续清理仅匹配的语音面板窗口，不碰设置页或输入法状态。
WETYPE_MUTE_WINDOW_S = 12.0      # 保留旧配置兼容
SW_HIDE = 0
WM_CLOSE = 0x0010
_VOICE_ACTIVE_UNTIL = 0.0


def mark_voice_active(seconds=WETYPE_MUTE_WINDOW_S):
    """保留兼容接口；WeType 语音面板现在由精确窗口匹配持续清理。"""
    global _VOICE_ACTIVE_UNTIL
    _VOICE_ACTIVE_UNTIL = time.time() + seconds


def voice_recently_active():
    return time.time() < _VOICE_ACTIVE_UNTIL


class WeTypeVoiceMute:
    """持续隐藏并请求关闭微信输入法专用的语音面板窗口。

    仅匹配 wetype.flutter.setting + 精确标题「语音输入」；不触碰输入法列表、候选窗、
    设置页、语音摘要窗或任何文字输入窗口。窗口管理器会保留已隐藏的 Flutter 窗口，
    因此持续检查是必要的。
    """

    def __init__(self, stop_evt, interval=0.08, log=out):
        self.stop_evt = stop_evt
        self.interval = interval
        self.log = log
        self.thread = None
        self.hits = 0
        self.found = []
        self._seen = set()
        self._u = ctypes.windll.user32
        self._prep()

    def _prep(self):
        u = self._u
        u.EnumWindows.argtypes = [ctypes.c_void_p, ctypes.c_ssize_t]
        u.EnumWindows.restype = wt.BOOL
        u.GetClassNameW.argtypes = [wt.HWND, wt.LPWSTR, ctypes.c_int]
        u.GetClassNameW.restype = ctypes.c_int
        u.GetWindowTextW.argtypes = [wt.HWND, wt.LPWSTR, ctypes.c_int]
        u.GetWindowTextW.restype = ctypes.c_int
        u.ShowWindow.argtypes = [wt.HWND, ctypes.c_int]
        u.ShowWindow.restype = wt.BOOL
        u.PostMessageW.argtypes = [wt.HWND, wt.UINT, ctypes.c_size_t,
                                   ctypes.c_ssize_t]
        u.PostMessageW.restype = wt.BOOL
        self._cb = ctypes.WINFUNCTYPE(ctypes.c_int, wt.HWND,
                                      ctypes.c_ssize_t)(self._enum)

    def _text(self, hwnd, fn, n=256):
        buf = ctypes.create_unicode_buffer(n)
        fn(wt.HWND(hwnd), buf, n)
        return buf.value

    def _enum(self, hwnd, lparam):
        try:
            cls = self._text(hwnd, self._u.GetClassNameW)
            if cls.lower() != "wetype.flutter.setting":
                return True
            title = self._text(hwnd, self._u.GetWindowTextW)
            # Hidden Flutter windows are retained by WeType and can be reused.
            # Match only the actual voice panel; leave settings and text input alone.
            if title != "语音输入":
                return True
            self.found.append((int(hwnd), cls, title))
        except Exception:
            pass
        return True

    def _scan(self):
        self.found = []
        try:
            self._u.EnumWindows(self._cb, 0)
        except Exception:
            pass
        return self.found

    def _run(self):
        while not self.stop_evt.is_set():
            try:
                for hwnd, cls, title in self._scan():
                    self.hits += 1
                    if hwnd not in self._seen:
                        self._seen.add(hwnd)
                        self.log("wetype voice panel suppressed hwnd=%d "
                                 "cls=%s title=%s" % (hwnd, cls, title))
                    self._u.ShowWindow(wt.HWND(hwnd), SW_HIDE)
                    self._u.PostMessageW(wt.HWND(hwnd), WM_CLOSE, 0, 0)
            except Exception as e:
                self.log("wetype mute error: %r" % (e,))
            self.stop_evt.wait(self.interval)

    def start(self):
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()
        return self



# ----------------------------------------------------------- SendInput 上屏
INPUT_KEYBOARD = 1
KEYEVENTF_KEYUP = 0x0002
KEYEVENTF_UNICODE = 0x0004


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", wt.WORD), ("wScan", wt.WORD),
                ("dwFlags", wt.DWORD), ("time", wt.DWORD),
                ("dwExtraInfo", ctypes.c_size_t)]


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", wt.LONG), ("dy", wt.LONG), ("mouseData", wt.DWORD),
                ("dwFlags", wt.DWORD), ("time", wt.DWORD),
                ("dwExtraInfo", ctypes.c_size_t)]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [("uMsg", wt.DWORD), ("wParamL", wt.WORD),
                ("wParamH", wt.WORD)]


class _INPUTUNION(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT),
                ("hi", HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _anonymous_ = ("u",)
    _fields_ = [("type", wt.DWORD), ("u", _INPUTUNION)]


def _key_down(vk):
    u = ctypes.windll.user32
    u.GetAsyncKeyState.argtypes = [ctypes.c_int]
    u.GetAsyncKeyState.restype = ctypes.c_short
    return bool(u.GetAsyncKeyState(vk) & 0x8000)


def wait_modifiers_up(timeout=MOD_RELEASE_WAIT):
    """上屏前等 Ctrl/Win 全部松开（最多 timeout 秒）。

    松开的瞬间识别往往已经完成，多数情况下立刻返回；若用户还按着修饰键
    （比如想接着 Ctrl+C），等到超时也宁可放弃注入，绝不把 Ctrl 状态带进
    目标窗口变成快捷键。
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not any(_key_down(vk) for vk in CTRL_VKS + WIN_VKS):
            return True
        time.sleep(0.05)
    return False


def send_text(text):
    """向当前前台窗口逐字符注入 Unicode 文本（不经过剪贴板、不经过输入法）。"""
    if not text:
        return True
    user32 = ctypes.windll.user32
    # ctypes 必须显式声明签名，否则 x64 下参数/返回值按 32 位截断
    user32.SendInput.argtypes = [ctypes.c_uint, ctypes.POINTER(INPUT),
                                 ctypes.c_int]
    user32.SendInput.restype = ctypes.c_uint
    units = text.encode("utf-16-le")
    n = len(units) // 2
    arr = (INPUT * (n * 2))()
    for i in range(n):
        wscan = units[2 * i] | (units[2 * i + 1] << 8)
        arr[2 * i].type = INPUT_KEYBOARD
        arr[2 * i].ki.wScan = wscan
        arr[2 * i].ki.dwFlags = KEYEVENTF_UNICODE
        arr[2 * i + 1].type = INPUT_KEYBOARD
        arr[2 * i + 1].ki.wScan = wscan
        arr[2 * i + 1].ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP
    sent = user32.SendInput(n * 2, arr, ctypes.sizeof(INPUT))
    if sent != n * 2:
        out("SendInput partial: %d/%d" % (sent, n * 2))
        return False
    return True


def fast_delete_hwnd():
    """快通道的目标窗口：前台窗口所属线程的**焦点控件**（拿不到/不可信返回 0）。

    为什么用焦点子窗口而不是前台窗口本身：记事本这类顶层窗口只说明「这是个
    记事本」，真正处理按键的是里面的 RichEditD2DPT 子窗口。浏览器 / Electron 把
    编辑区放在渲染进程里，GetGUIThreadInfo 拿回来的就是顶层窗口本身 —— 两种都
    实测过能收到投递的 WM_KEYDOWN（Chrome 顶层自绘窗口 46/46）。
    """
    if not FOCUS_OK:
        return 0
    try:
        f = focus_facts()
    except Exception as e:                # pragma: no cover - 环境相关
        out("fast delete: focus probe failed: %r" % (e,))
        return 0
    hwnd = f.get("focus") or f.get("fg") or 0
    cls = (f.get("focus_cls") or f.get("fg_cls") or "").strip().lower()
    if not hwnd:
        return 0
    if not fast_delete_class_ok(cls):
        out("fast delete: %r 不吃投递键消息 -> 退回慢通道" % cls)
        return 0
    if cls and cls in _FAST_BAD_CLASSES:
        out("fast delete: %r 本次会话已判定投不出去 -> 退回慢通道" % cls)
        return 0
    return hwnd


def _probe_target_alive(hwnd, timeout_ms=2000):
    """探活：同步发一条 WM_NULL（不改变目标状态），目标没卡死返回 True。

    ⚠ 它**不是**队列栅栏 —— 跨线程 SendMessage 走的是「已发送消息」优先级，
    比已投递消息还高，所以它返回时目标**可能还没消费**我们刚投的退格。
    顺序由系统本身保证：消息优先级是 已发送 > 已投递 > 硬件输入，我们用
    PostMessage 投退格（已投递）、用 SendInput 补正文（硬件输入），所以退格
    一定先被消费完。见 tmp/bs-fast-e2e.py 的端到端断言。
    这里只用来在目标无响应时及时收手（SendMessageTimeout + ABORTIFHUNG）。
    """
    u = ctypes.windll.user32
    u.SendMessageTimeoutW.argtypes = [
        wt.HWND, ctypes.c_uint, ctypes.c_size_t, ctypes.c_size_t,
        ctypes.c_uint, ctypes.c_uint, ctypes.POINTER(ctypes.c_size_t)]
    u.SendMessageTimeoutW.restype = ctypes.c_void_p
    res = ctypes.c_size_t()
    ok = u.SendMessageTimeoutW(wt.HWND(hwnd), WM_NULL, 0, 0,
                               SMTO_ABORTIFHUNG, timeout_ms, ctypes.byref(res))
    return bool(ok)


def post_backspaces(hwnd, n, budget):
    """快通道：把 n 组 VK_BACK 直接 Post 给目标窗口；返回**真正投出去**的键数。

    为什么是「Post 一对 WM_KEYDOWN+WM_KEYUP」而不是别的形态：这才是**和真实按键
    完全一样的消息序列** —— 目标的消息循环照旧 TranslateMessage 把它翻成
    WM_CHAR(8)，编辑控件照旧按 WM_CHAR 删字。所以它对「按 WM_CHAR 删字的
    标准 Edit/RichEdit」和「自己处理 WM_KEYDOWN 的 Chromium/Electron/Tk」
    两类目标**同时**有效。实测：
      * 只 Post WM_CHAR(8)  -> 浏览器/Electron 一类不认（它们只看 WM_KEYDOWN）；
      * 只 SendMessage(WM_KEYDOWN) -> 标准 Edit/RichEdit 不认（它们靠
        TranslateMessage 生成的 WM_CHAR 删字，同步投递根本不经过消息循环）。
    区别只在于**谁在等**：真实按键要排队等 RIT 派发，投递直接进目标队列，
    所以没有「down/up 挤在一起被合并掉」的丢键问题，也就没有 24ms 的每格下限。

    返回值语义（调用方据此决定怎么补）：
      * `n`     全部投出；
      * `0`     一个都没投出去（被 UIPI 拦了 / 窗口已销毁）-> 调用方整段退回慢通道；
      * `0<k<n` 投到第 k 个被拒（队列配额耗尽之类）-> 调用方用慢通道补 `n-k` 个，
                总数不变。**绝不能拿 n 去补** —— 已经投出去的那 k 个照样会生效，
                再补 n 个就多删 k 个字，吃掉用户自己的文字。
    """
    u = ctypes.windll.user32
    u.PostMessageW.argtypes = [wt.HWND, ctypes.c_uint, ctypes.c_size_t,
                               ctypes.c_size_t]
    u.PostMessageW.restype = ctypes.c_bool
    per = fast_delete_pace(n, budget)
    t0 = time.time()
    posted = 0
    for i in range(n):
        if not u.PostMessageW(wt.HWND(hwnd), WM_KEYDOWN, VK_BACK,
                              fast_delete_lparam(BACKSPACE_SCAN)):
            out("fast delete: PostMessage(WM_KEYDOWN) rejected at %d/%d" % (i, n))
            break
        if not u.PostMessageW(wt.HWND(hwnd), WM_KEYUP, VK_BACK,
                              fast_delete_lparam(BACKSPACE_SCAN, True)):
            out("fast delete: PostMessage(WM_KEYUP) rejected at %d/%d" % (i, n))
            break
        posted += 1
        if per and i < n - 1:
            time.sleep(per)
    dt = (time.time() - t0) * 1000
    if posted:
        alive = _probe_target_alive(hwnd)
        out("fast delete: %d/%d chars -> %s in %.0fms (%.2fms/键, budget %.1fs)%s"
            % (n, posted, window_class(hwnd) or hex(int(hwnd)), dt,
               dt / max(1, posted), budget,
               "" if alive else " [target unresponsive]"))
    else:
        # 整段投不出去：把这个窗口类记下来，本次会话内不再白试一遍
        cls = (window_class(hwnd) or "").strip().lower()
        if cls:
            _FAST_BAD_CLASSES.add(cls)
        out("fast delete: 一个都没投出去 (%s) -> 退回慢通道"
            % (window_class(hwnd) or hex(int(hwnd))))
    return posted


def send_backspaces(n, budget=None):
    """退格 n 次（撤回/校正流式已上屏的文字）；全部投出返回 True。

    两条通道，优先快通道（原理与实测见上面 173 行起的说明）：
      * 快通道 `post_backspaces()`：把键消息**直接投给目标的焦点窗口**，没有每格
        下限 —— 「调多快就真的多快」，0 秒 = 一口气投完（46 格实测 1~10ms、
        收全 46/46，Tk / 记事本 / Chrome 三种真机都验过）；
      * 慢通道 `send_backspaces_slow()`：真实键盘注入，全系统通用，但每格 >= 24ms。
        只在拿不到焦点窗口 / 目标类名在黑名单 / 用户关掉 fast_delete 时用。

    budget 为 None 时现读配置（改完设置下一次识别即生效）。
    安全护栏：Ctrl/Win 还按着时绝不退格——Ctrl+Backspace 在多数编辑器里是
    「删一个词」，会删掉比我们输入的更多的内容。宁可放弃校正。
    """
    if n <= 0:
        return True
    if any(_key_down(vk) for vk in CTRL_VKS + WIN_VKS):
        out("backspace skipped: modifiers still held (n=%d)" % n)
        return False
    budget = reconcile_secs() if budget is None else budget
    if fast_delete_enabled():
        hwnd = fast_delete_hwnd()
        if hwnd:
            posted = post_backspaces(hwnd, n, budget)
            if posted >= n:
                return True
            if posted > 0:
                # 投了一半：剩下的用慢通道补齐，**总数还是 n**（多补会吃掉用户文字）
                return send_backspaces_slow(n - posted, 0.0)
            # 一个都没投出去 -> 整段退回慢通道
    return send_backspaces_slow(n, budget)


def send_backspaces_slow(n, budget=RECONCILE_SECS_DEFAULT):
    """慢通道（兜底）：真实键盘注入 keybd_event，每格 >= 24ms。

    ⚠ 为什么不用 SendInput：实测过，**会静默丢一半**。
    退格必须真的落到位，否则屏幕上会残留流式预览的前半句（最终结果只能
    接在它后面），表现就是「第一个标点前那句话一直保留、没被覆盖」。
    实测（独立注入进程 -> 独立目标进程，12 次退格 × 3 轮）：
        SendInput 一次投 n 组 down/up（旧实现） -> 目标只收到 5~7 / 12
        SendInput 逐个 + scan code + 12ms 间隔   -> 7~8 / 12
        keybd_event 无间隔                       -> 5~7 / 12
        keybd_event 按住 12ms + 释放后 12ms      -> 12 / 12（n=24 也 24/24）
    所以这里走 keybd_event，并**带真实 scan code**（wScan=0 时目标可能认不出
    这是退格键）。慢是慢，但退格丢一格就是用户看得见的错字。
    性能注记：keybd_event 每次调用本身约 9ms（一轮退格 2 次调用 ≈ 18ms 固定
    开销），所以每格的实际墙钟比 hold+gap 略长；真正的优化仍然是**少退格**——
    见 reconcile_plan 的公共前缀裁剪。
    """
    hold, gap = backspace_pace(n, budget)
    user32 = ctypes.windll.user32
    user32.keybd_event.argtypes = [ctypes.c_ubyte, ctypes.c_ubyte,
                                   ctypes.c_uint, ctypes.c_void_p]
    user32.keybd_event.restype = None
    t0 = time.time()
    for _ in range(n):
        user32.keybd_event(VK_BACK, BACKSPACE_SCAN, 0, None)
        if hold:
            time.sleep(hold)
        user32.keybd_event(VK_BACK, BACKSPACE_SCAN, KEYEVENTF_KEYUP, None)
        if gap:
            time.sleep(gap)
    dt = (time.time() - t0) * 1000
    out("slow delete: %d chars in %.0fms (%.0fms/键, budget %.1fs)"
        % (n, dt, dt / max(1, n), budget))
    return True


def stream_step(prev, cur, emitted):
    """流式一步：只发送「连续两轮识别一致」的稳定前缀。

    返回本轮该追加的 delta：
    - 首轮（prev 为空）-> 返回 ""，只播种不下发（1.0s 处的首轮识别
      最容易被后续改写，直接发会导致后续全部冻结）；
    - 之后取两轮公共前缀 stable；stable 是 emitted 的延伸 -> 返回增量；
    - stable 短于 emitted（模型改写了已上屏的部分）-> 返回 None，
      本轮跳过，等松开后最终识别统一退格校正。
    """
    if not prev:
        return ""
    stable = ""
    for a, b in zip(prev, cur):
        if a != b:
            break
        stable += a
    if stable.startswith(emitted):
        return stable[len(emitted):]
    return None


def stream_recover(partial, emitted):
    """模型回头改写已上屏文字时的前向续发（按住期间无法退格的补偿）。

    旧逻辑：`stream_step` 返回 None -> 本轮跳过 -> 改写没被推翻前**一直冻结**
    （实测日志 revise deferred 连刷 5 秒、后半句全压到松开才上屏）。但按住
    期间修饰键被占、退格有护栏根本不能用，冻结并不能修正，只会让流式停摆。

    这里改为：保持位置对齐，把 partial 超出已上屏长度的尾巴**继续追加上屏**
    （错位的那几个字留在原位），错掉的中段等松开后由最终 `_reconcile`
    统一退格重发。护栏按**重叠区间内实际错位的字符数**算——续发只追加
    partial 自己的字符，错位数不随流式变长而增长，判定始终稳定；
    错位超过 max(4, 已上屏/3) 字视为大幅改写（续发会打得很乱），
    仍冻结等最终对账。partial 不比已上屏长则无可追加，同样返回 None。

    返回要追加的增量字符串；不满足条件返回 None。
    """
    if not emitted or not partial or len(partial) <= len(emitted):
        return None
    overlap = min(len(emitted), len(partial))
    bad = sum(1 for a, b in zip(emitted[:overlap], partial[:overlap])
              if a != b)
    if bad > max(4, len(emitted) // 3):
        return None                      # 大幅改写：续发会很乱，冻结等最终
    return partial[len(emitted):]


def stream_round(prev, partial, emitted):
    """一轮流式的**纯决策**：`_stream_loop` 与回归测试共用同一份判定。

    返回 `(增量, 模式)`：模式 `stable`（两轮稳定前缀）/ `forward`（改写前向
    续发）/ `deferred`（冻结，此时增量为 None）。抽成纯函数是为了让
    selftest 与 voice-punct-test.py 测的就是实机跑的那套逻辑本身，
    而不是各自复刻一份、改一处忘一处。
    """
    delta = stream_step(prev, partial, emitted)
    if delta is not None:
        return delta, "stable"
    delta = stream_recover(partial, emitted)
    if delta is None:
        return None, "deferred"
    return delta, "forward"


def reconcile_plan(text, emitted):
    """最终对账的**纯决策**：返回 `(模式, 要补发的文本)`。

    - `none`     没流式过 -> 原样整段发送
    - `keep`     前缀一致 -> 只补尾巴（零退格，最常见）
    - `trim`     前缀一致但后面被改写 -> 只删改掉的那截尾巴，再补新尾巴
    - `rewrite`  从头就不一致 -> 调用方先退格 len(emitted) 再发 text
    - `keep_all` 最终为空但流式有字 -> 保留已上屏，一个字都不删

    `trim` 为什么重要：退格数直接等于「删除预览」那段的长度，而每个退格
    都必须按可靠投递的节奏发（见 backspace_pace）。旧逻辑只要有一处不一致
    就整段重打，长句子会明显卡；改成公共前缀裁剪后，只需删掉**真正变了的
    那几个字**，删除耗时不再随整句长度增长——这正是「删除时间不随长度变化」
    的落点。事件数 (n-p)+(m-p) 恒 <= n+m，所以 trim 永远不比重写慢，
    且结果完全等价。

    安全性依据：退格数必须**恰好**等于「已上屏里要抹掉的那一截」——
    每一步流入的字都记在 emitted 里，多退一格会吃掉用户原有文字，
    少退则留下错位垃圾。
    """
    if not emitted:
        return ("none", text)
    if not text:
        return ("keep_all", "")
    if text.startswith(emitted):
        return ("keep", text[len(emitted):])
    # 公共前缀 p：前面这 p 个字文档里已经有了，一个字都不用动
    p = 0
    for a, b in zip(emitted, text):
        if a != b:
            break
        p += 1
    trim = len(emitted) - p
    if trim <= 0:                        # 理论上到不了（已被 startswith 拦下）
        return ("rewrite", text)
    return ("trim", (trim, text[p:]))


def get_foreground_hwnd():
    u = ctypes.windll.user32
    u.GetForegroundWindow.argtypes = []
    u.GetForegroundWindow.restype = ctypes.c_void_p
    return u.GetForegroundWindow()


# --------------------------------------------- 焦点目标：在不在一个「输入框」里
# 需求：识别出结果后，如果焦点**不在可输入的控件里**（桌面、资源管理器列表、
# 任务栏、终端、播放器…），注入的字哪儿都去不了，等于白说一遍。这时改为把文字
# 复制进剪贴板，并在悬浮球里弹一条「已复制」。
#
# 判定只做「有没有正向证据」这一件事：规则表在 voice_overlay_focus.py（纯函数，
# 有实机实测依据与回归用例），这里只负责把 Win32 的现场取出来喂给它。
def window_class(hwnd):
    """窗口类名；取不到返回 ""（空串表示「不知道」，不参与负判）。"""
    if not hwnd:
        return ""
    u = ctypes.windll.user32
    u.GetClassNameW.argtypes = [wt.HWND, wt.LPWSTR, ctypes.c_int]
    u.GetClassNameW.restype = ctypes.c_int
    buf = ctypes.create_unicode_buffer(256)
    if not u.GetClassNameW(wt.HWND(hwnd), buf, 256):
        return ""
    return buf.value


def focus_facts():
    """取一次焦点现场：前台窗口类名 + 焦点控件类名 + caret（caret 只进日志）。

    为什么不用 GetForegroundWindow 的类名就够：记事本这类顶层窗口只说明「这是个
    记事本」，真正能接收文字的是它里面的 Edit/RichEdit 子窗口，所以必须走
    GetGUIThreadInfo 拿前台线程的**焦点控件**。
    """
    fg = int(get_foreground_hwnd() or 0)
    f = {"fg": fg, "fg_cls": window_class(fg), "focus": 0, "focus_cls": "",
         "caret": 0}
    if not fg or not FOCUS_OK:
        return f
    u = ctypes.windll.user32
    u.GetWindowThreadProcessId.argtypes = [wt.HWND, ctypes.POINTER(wt.DWORD)]
    u.GetWindowThreadProcessId.restype = wt.DWORD
    tid = u.GetWindowThreadProcessId(wt.HWND(fg), None)
    if not tid:
        return f
    gti = make_guithreadinfo()
    gti.cbSize = ctypes.sizeof(gti)
    u.GetGUIThreadInfo.argtypes = [wt.DWORD, ctypes.POINTER(type(gti))]
    u.GetGUIThreadInfo.restype = ctypes.c_bool
    if not u.GetGUIThreadInfo(tid, ctypes.byref(gti)):
        return f
    f["focus"] = int(gti.hwndFocus or 0)
    f["focus_cls"] = window_class(f["focus"])
    f["caret"] = int(gti.hwndCaret or 0)
    return f


def focus_target_state():
    """返回 `(state, 现场 dict)`；state ∈ edit / nonedit / unknown。

    现场 dict 里额外带三样东西：
      * `uia`     —— UI Automation 的判定（edit/nonedit/unknown），没有就是 "off"；
      * `uia_ok`  —— UIA 这一轮到底有没有正常工作（决定 unknown 要不要复制）；
      * `copy`    —— **最终要不要走复制兜底**，由 `wants_copy()` 定。

    为什么要 UIA：类名表对「浏览器页面里没有聚焦任何输入框」完全无能为力
    —— 前台类名 `Chrome_WidgetWin_1` 在正判白名单里，旧逻辑一律判 edit，
    字就打进空气里了。UIA 直接问系统「拿着焦点的元素是什么控件」，实测能分开
    「记事本编辑区（可写 Document）」和「Chrome 空白页（只读 Document）」。
    """
    f = focus_facts()
    f["uia"], f["uia_ok"] = "off", False
    if not FOCUS_OK or not f["fg"]:
        f["copy"] = False
        return FOCUS_UNKNOWN, f

    uia_state = None
    if UIA_OK:
        try:
            uia_state, uia_facts = _uia.focused_verdict()
            f["uia"] = uia_state
            f["uia_ok"] = True
            f["uia_ct"] = uia_facts.get("ct")
            f["uia_cls"] = uia_facts.get("cls") or ""
            f["uia_name"] = (uia_facts.get("name") or "")[:40]
            if "err" in uia_facts:
                f["uia_err"] = uia_facts["err"]
        except Exception as e:
            f["uia_err"] = repr(e)

    state = judge_focus_target(f["fg_cls"], f["focus_cls"], f["focus"],
                               bool(f["fg_cls"]), uia_state)
    # 「所有非输入框都复制」的策略在这里落地（含判不准的情形）
    f["copy"] = bool(wants_copy(state, f["uia_ok"])) if wants_copy else \
        (state == FOCUS_NONEDIT)
    return state, f


# ---------------------------------------------------------------- 剪贴板兜底
def set_clipboard_text(text):
    """把文本写进剪贴板（CF_UNICODETEXT）；成功返回 True。

    为什么不用 Tk 的 `clipboard_append`：Tk 的剪贴板是**按需服务**的 —— 数据
    留在本进程里，等别的程序来取时才由本进程喂过去，本进程一退出内容就没了。
    这里走 Win32：GlobalAlloc 一块 GMEM_MOVEABLE 内存、填好 UTF-16 文本、
    SetClipboardData 把**所有权交给系统**，进程退出后内容依然在。
    剪贴板可能被别的程序占着（OpenClipboard 会失败），退避重试几次。
    """
    if not text:
        return False
    k32, u = ctypes.windll.kernel32, ctypes.windll.user32
    k32.GlobalAlloc.argtypes = [ctypes.c_uint, ctypes.c_size_t]
    k32.GlobalAlloc.restype = wt.HGLOBAL
    k32.GlobalLock.argtypes = [wt.HGLOBAL]
    k32.GlobalLock.restype = ctypes.c_void_p
    k32.GlobalUnlock.argtypes = [wt.HGLOBAL]
    k32.GlobalUnlock.restype = ctypes.c_bool
    k32.GlobalFree.argtypes = [wt.HGLOBAL]
    k32.GlobalFree.restype = wt.HGLOBAL
    u.OpenClipboard.argtypes = [wt.HWND]
    u.OpenClipboard.restype = ctypes.c_bool
    u.EmptyClipboard.argtypes = []
    u.EmptyClipboard.restype = ctypes.c_bool
    u.SetClipboardData.argtypes = [ctypes.c_uint, wt.HANDLE]
    u.SetClipboardData.restype = wt.HANDLE
    u.CloseClipboard.argtypes = []
    u.CloseClipboard.restype = ctypes.c_bool

    for attempt in range(CLIP_RETRY):
        if u.OpenClipboard(None):
            break
        time.sleep(0.03 * (attempt + 1))
    else:
        out("clipboard: OpenClipboard busy, copy skipped")
        return False
    try:
        if not u.EmptyClipboard():
            out("clipboard: EmptyClipboard failed")
            return False
        data = text.encode("utf-16-le") + b"\x00\x00"
        h = k32.GlobalAlloc(GMEM_MOVEABLE, len(data))
        if not h:
            out("clipboard: GlobalAlloc failed")
            return False
        p = k32.GlobalLock(h)
        if not p:
            out("clipboard: GlobalLock failed")
            k32.GlobalFree(h)
            return False
        ctypes.memmove(p, data, len(data))
        k32.GlobalUnlock(h)
        if not u.SetClipboardData(CF_UNICODETEXT, h):
            out("clipboard: SetClipboardData failed")
            k32.GlobalFree(h)         # 没交出去，自己回收，否则内存泄漏
            return False
        return True                   # 成功：内存已归系统管，绝不能 GlobalFree
    finally:
        u.CloseClipboard()


def get_clipboard_text():
    """读回剪贴板文本（只给 `--copy-text` 校验与自检用）。"""
    u, k32 = ctypes.windll.user32, ctypes.windll.kernel32
    u.OpenClipboard.argtypes = [wt.HWND]
    u.OpenClipboard.restype = ctypes.c_bool
    u.GetClipboardData.argtypes = [ctypes.c_uint]
    u.GetClipboardData.restype = wt.HANDLE
    u.CloseClipboard.argtypes = []
    u.CloseClipboard.restype = ctypes.c_bool
    k32.GlobalLock.argtypes = [wt.HGLOBAL]
    k32.GlobalLock.restype = ctypes.c_void_p
    k32.GlobalUnlock.argtypes = [wt.HGLOBAL]
    k32.GlobalUnlock.restype = ctypes.c_bool
    for attempt in range(CLIP_RETRY):
        if u.OpenClipboard(None):
            break
        time.sleep(0.03 * (attempt + 1))
    else:
        return None
    try:
        h = u.GetClipboardData(CF_UNICODETEXT)
        if not h:
            return None
        p = k32.GlobalLock(h)
        if not p:
            return None
        try:
            return ctypes.wstring_at(p)
        finally:
            k32.GlobalUnlock(h)
    finally:
        u.CloseClipboard()


# ------------------------------------------------------- DPI 感知（原生分辨率）
def enable_dpi_awareness():
    """把本进程设为 DPI 感知 —— **必须在创建 Tk 窗口之前调用**。

    DPI-unaware 时 Windows 会把整个窗口先按 96dpi 画好、再位图放大 1.5 倍
    上屏，胶囊描边/声波条/麦克风图形全部发虚（这就是「UI 分辨率低」的根源）。
    设为感知后坐标即物理像素，配合 ScaledCanvas 按实测 DPI 放大绘制，
    得到 1:1 原生渲染。全失败返回 ""（此时缩放系数会算成 1.0，退化为旧的
    拉伸显示，功能不受影响）。
    """
    # 1) Per-Monitor V2（Win10 1703+），DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4
    try:
        u = ctypes.windll.user32
        u.SetProcessDpiAwarenessContext.argtypes = [ctypes.c_void_p]
        u.SetProcessDpiAwarenessContext.restype = ctypes.c_bool
        if u.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4)):
            return "pmv2"
    except (AttributeError, OSError, ValueError):
        pass
    # 2) shcore per-monitor（Win8.1+）；E_ACCESSDENIED = 已经设置过，也算成功
    try:
        sc = ctypes.windll.shcore
        sc.SetProcessDpiAwareness.argtypes = [ctypes.c_int]
        sc.SetProcessDpiAwareness.restype = ctypes.c_int
        if sc.SetProcessDpiAwareness(2) in (0, -2147024891):
            return "pm"
    except (AttributeError, OSError, ValueError):
        pass
    # 3) system aware（Vista+）
    try:
        u = ctypes.windll.user32
        u.SetProcessDPIAware.argtypes = []
        u.SetProcessDPIAware.restype = ctypes.c_bool
        if u.SetProcessDPIAware():
            return "system"
    except (AttributeError, OSError):
        pass
    return ""


def system_dpi():
    """系统 DPI（150% 屏 -> 144）。进程已 DPI 感知时返回真实值，否则 96。"""
    try:
        u = ctypes.windll.user32
        u.GetDpiForSystem.argtypes = []
        u.GetDpiForSystem.restype = ctypes.c_uint
        d = u.GetDpiForSystem()
        if d:
            return int(d)
    except (AttributeError, OSError):
        pass
    try:                                  # 老系统兜底：GetDeviceCaps(LOGPIXELSX)
        u = ctypes.windll.user32
        u.GetDC.argtypes = [ctypes.c_void_p]
        u.GetDC.restype = ctypes.c_void_p
        g = ctypes.windll.gdi32
        g.GetDeviceCaps.argtypes = [ctypes.c_void_p, ctypes.c_int]
        g.GetDeviceCaps.restype = ctypes.c_int
        u.ReleaseDC.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        u.ReleaseDC.restype = ctypes.c_int
        hdc = u.GetDC(0)
        dpi = g.GetDeviceCaps(hdc, 88) if hdc else 0      # LOGPIXELSX
        if hdc:
            u.ReleaseDC(0, hdc)
        if dpi:
            return int(dpi)
    except (AttributeError, OSError):
        pass
    return 96


class ScaledCanvas:
    """按 DPI 缩放转发坐标/线宽的 Canvas 代理。

    绘制代码全部按 96dpi 的逻辑像素写（100x46 设计稿不变），代理把坐标和
    线宽乘上系统缩放后再落到真实 Canvas —— 进程已设为 DPI 感知，最终以
    物理像素 1:1 原生渲染，不再被 Windows 位图拉伸（发虚的根源）。
    """

    def __init__(self, cv, k):
        self._cv = cv
        self._k = float(k)

    def __getattr__(self, name):              # bind/pack/itemconfig... 直通
        return getattr(self._cv, name)

    def _xy(self, vals):
        k = self._k
        return [v * k for v in vals]

    def _kw(self, kw):
        if isinstance(kw.get("width"), (int, float)):
            kw["width"] = kw["width"] * self._k
        return kw

    def create_polygon(self, pts, **kw):
        return self._cv.create_polygon(self._xy(pts), **self._kw(kw))

    def create_oval(self, x0, y0, x1, y1, **kw):
        return self._cv.create_oval(*self._xy((x0, y0, x1, y1)), **self._kw(kw))

    def create_rectangle(self, x0, y0, x1, y1, **kw):
        return self._cv.create_rectangle(*self._xy((x0, y0, x1, y1)),
                                         **self._kw(kw))

    def create_line(self, *coords, **kw):
        return self._cv.create_line(*self._xy(coords), **self._kw(kw))

    def create_arc(self, x0, y0, x1, y1, **kw):
        return self._cv.create_arc(*self._xy((x0, y0, x1, y1)), **self._kw(kw))

    def create_text(self, x, y, **kw):
        # 字号由调用方按 DPI 算好（负值 = 像素，Tk 的约定），这里只缩放坐标
        return self._cv.create_text(*self._xy((x, y)), **kw)

    def coords(self, item, *vals):
        if not vals:                          # 读回坐标：原样返回（物理值）
            return self._cv.coords(item)
        return self._cv.coords(item, *self._xy(vals))

    def itemconfig(self, item, **kw):
        return self._cv.itemconfig(item, **self._kw(kw))


# ------------------------------------------------------------------- 悬浮球
def work_area():
    r = wt.RECT()
    if not ctypes.windll.user32.SystemParametersInfoW(
            0x0030, ctypes.sizeof(r), ctypes.byref(r), 0):  # SPI_GETWORKAREA
        r.left, r.top, r.right, r.bottom = 0, 0, 1920, 1040
    return r


def foreground_window():
    u = ctypes.windll.user32
    u.GetForegroundWindow.argtypes = []
    u.GetForegroundWindow.restype = wt.HWND
    return int(u.GetForegroundWindow() or 0)


def restore_foreground(hwnd, tries=2):
    """把前台还给启动前的那个窗口（Tk 建窗会短暂抢走，隐藏后 Windows 未必还回去）。

    只在启动时调用一次；失败无所谓（前台窗口可能已经关了、或系统不让切）。
    """
    if not hwnd or hwnd == foreground_window():
        return
    u = ctypes.windll.user32
    u.IsWindow.argtypes = [wt.HWND]
    u.IsWindow.restype = ctypes.c_bool
    u.SetForegroundWindow.argtypes = [wt.HWND]
    u.SetForegroundWindow.restype = ctypes.c_bool
    for i in range(tries):
        if not u.IsWindow(hwnd):
            out("restore focus: 原前台窗口已关闭，跳过")
            return
        if u.SetForegroundWindow(hwnd):
            out("restore focus -> hwnd=%d ok" % hwnd)
            return
        time.sleep(0.15 * (i + 1))
    out("restore focus: 还原失败（不影响录音，用户点一下窗口即恢复）")


def round_rect(canvas, x0, y0, x1, y1, r=None, **kw):
    if r is None:
        r = min(y1 - y0, x1 - x0) / 2.0
    pts = [x0 + r, y0, x1 - r, y0, x1, y0, x1, y0 + r,
           x1, y1 - r, x1, y1, x1 - r, y1, x0 + r, y1,
           x0, y1, x0, y1 - r, x0, y0 + r, x0, y0]
    return canvas.create_polygon(pts, smooth=True, **kw)


# ====================== 悬浮球外观：逐像素 alpha 抗锯齿渲染 ======================
# 为什么要换掉 Tk 画布：Tk 画布**没有抗锯齿**，圆角/圆形/声波条全是硬边像素；
# `-transparentcolor` 又只支持 1-bit 色键透明，边缘抗锯齿像素会和色键混出
# 彩色镶边。所以「再高的 DPI」也只能得到「锐利但毛糙」的边缘。这里改成：
#   Pillow 以 SS 倍超采样绘制 -> Lanczos 缩到物理像素  => 真正平滑的边缘
#   Win32 分层窗口 + UpdateLayeredWindow（逐像素 alpha）=> 与桌面真实混合，
#   因此还能画出悬浮投影、玻璃质感渐变，而不是靠色键硬抠。
# 设计稿仍是 100x46 逻辑像素，只是外面多留 DPAD 一圈给投影。
DW, DH = 100, 46                 # 胶囊本体（逻辑像素）
DPAD = 12                        # 投影留白：窗口比胶囊大一圈
DCX, DCY = 24, 23                # 徽章中心（胶囊内坐标）
DBADGE_R = 12
DBAR_X0, DBAR_PITCH, DBAR_W = 46, 8, 4
DNBAR = 6
SS = 4                           # 超采样倍数（4x4=16 个样本/像素）
_WIN_W, _WIN_H = DW + 2 * DPAD, DH + 2 * DPAD
_CAP_DY = 2.5                    # 投影下移量（光源在上）
_CAP_BLUR = 4.0                  # 投影模糊半径（逻辑像素）


def _rgba(hex_color, alpha=255):
    h = hex_color.lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), int(alpha))


def _lerp_rgba(c0, c1, t):
    t = 0.0 if t < 0 else (1.0 if t > 1 else t)
    return tuple(int(round(a + (b - a) * t)) for a, b in zip(c0, c1))


# ---- 中文提示文字要用的字体（「已复制」这类短提示）----
# 优先微软雅黑（系统 UI 字体，和胶囊的 Apple 风最搭），再退黑体/宋体。
# 一个都找不到时返回 None：调用方**不要画文字**，宁可只有徽章图形也不能报错。
CJK_FONT_FILES = ("msyh.ttc", "msyh.ttf", "msyhl.ttc", "simhei.ttf",
                  "simsun.ttc", "Deng.ttf")
_FONT_CACHE = {}


def _cjk_font(size_px):
    """按像素大小拿一个中文字体对象；没装中文字体返回 None（结果有缓存）。"""
    if not PIL_OK or size_px <= 0:
        return None
    got = _FONT_CACHE.get(size_px)
    if got is not None:
        return got if got != "none" else None
    font_dir = os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Fonts")
    from PIL import ImageFont
    for name in CJK_FONT_FILES:
        path = os.path.join(font_dir, name)
        if not os.path.isfile(path):
            continue
        try:
            f = ImageFont.truetype(path, size_px)
        except Exception as e:                  # 字体损坏/被占用 -> 换下一个
            out("font %s load failed: %r" % (name, e))
            continue
        _FONT_CACHE[size_px] = f
        return f
    out("no CJK font found in %s, toast text disabled" % font_dir)
    _FONT_CACHE[size_px] = "none"
    return None


class _BLENDFUNCTION(ctypes.Structure):
    _fields_ = [("BlendOp", ctypes.c_byte), ("BlendFlags", ctypes.c_byte),
                ("SourceConstantAlpha", ctypes.c_byte),
                ("AlphaFormat", ctypes.c_byte)]


class _BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [("biSize", wt.DWORD), ("biWidth", ctypes.c_long),
                ("biHeight", ctypes.c_long), ("biPlanes", wt.WORD),
                ("biBitCount", wt.WORD), ("biCompression", wt.DWORD),
                ("biSizeImage", wt.DWORD), ("biXPelsPerMeter", ctypes.c_long),
                ("biYPelsPerMeter", ctypes.c_long), ("biClrUsed", wt.DWORD),
                ("biClrImportant", wt.DWORD)]


class _BITMAPINFO(ctypes.Structure):
    _fields_ = [("bmiHeader", _BITMAPINFOHEADER), ("bmiColors", wt.DWORD * 3)]


_WNDPROC = ctypes.WINFUNCTYPE(ctypes.c_ssize_t, wt.HWND, wt.UINT,
                              ctypes.c_size_t, ctypes.c_ssize_t)


class _WNDCLASSEXW(ctypes.Structure):
    _fields_ = [("cbSize", wt.UINT), ("style", wt.UINT),
                ("lpfnWndProc", _WNDPROC), ("cbClsExtra", ctypes.c_int),
                ("cbWndExtra", ctypes.c_int), ("hInstance", wt.HINSTANCE),
                ("hIcon", wt.HICON), ("hCursor", wt.HANDLE),
                ("hbrBackground", wt.HBRUSH), ("lpszMenuName", wt.LPCWSTR),
                ("lpszClassName", wt.LPCWSTR), ("hIconSm", wt.HICON)]


class PillRenderer:
    """把 100x46 的逻辑设计稿渲染成带投影的 RGBA 位图。

    静态部分（投影/胶囊/徽章/图形）按 (图形, 徽章色) 缓存，每帧只重画声波条
    与呼吸环，再把超采样图缩到物理像素 —— 一次约 2~5ms，60ms 的动画节拍
    完全够用。
    """

    def __init__(self, k, opaque=False):
        self.k = float(k)
        self.opaque = opaque
        self.s = self.k * SS                       # 逻辑 -> 超采样像素
        self.dw = float(DW)                        # 胶囊本体宽度（可加宽）
        self._cache = {}
        self._tfont = None                         # 提示态：选好的字体
        self._tshown = ""                          # 提示态：实际要画的（可能截断过）
        self._resize()

    def _resize(self):
        """按当前 dw 重算窗口/超采样尺寸。加宽提示态时会被再调一次。"""
        self.w = int(round((self.dw + 2 * DPAD) * self.k))   # 窗口物理像素
        self.h = int(round(_WIN_H * self.k))
        self.SW = int(round((self.dw + 2 * DPAD) * self.s))
        self.SH = int(round(_WIN_H * self.s))
        self._cache = {}

    def set_width(self, dw):
        """设定胶囊本体宽度（逻辑像素）；变了才重算，返回是否变了。"""
        dw = max(float(DW), min(float(dw), TEXT_MAX_W))
        if abs(dw - self.dw) < 0.5:
            return False
        self.dw = dw
        self._resize()
        return True

    def _body(self, dy=0.0):
        s = self.s
        return [(DPAD + 2) * s, (DPAD + 2 + dy) * s,
                (DPAD + self.dw - 2) * s, (DPAD + DH - 2 + dy) * s]

    def _radius(self):
        return (DH - 4) / 2.0 * self.s             # 正圆头（高 42 -> r21）

    def frame(self, glyph, badge, bars, ring, phase, text=None):
        """渲染一帧：返回物理像素尺寸的 RGBA 图。

        `text` 非空时走**提示态**：不画声波条，改在原来声波条的位置画一行固定提示
        （当前产品路径只使用「已复制」；输入框成功路径不传文字）。文字画在静态
        缓存层里，所以每帧的开销和平时一样。
        """
        if text:
            self._tfont, self._tshown, dw = self.text_layout(text)
            self.set_width(dw)                    # 只在宽度真变了时才清缓存
        else:
            self._tfont, self._tshown = None, ""
            self.set_width(DW)
        img = self._base(glyph, badge, text or None).copy()
        s = self.s
        d = ImageDraw.Draw(img)
        mid = (DPAD + DCY) * s
        if not text:                              # 提示态没有声波条（那位置给文字）
            for j, h in enumerate(bars):
                h = max(DBAR_W, float(h)) * s
                x0 = (DPAD + DBAR_X0 + j * DBAR_PITCH) * s
                col = _lerp_rgba(_rgba(BAR), _rgba(BAR_IN), j / float(DNBAR - 1))
                d.rounded_rectangle([x0, mid - h / 2.0, x0 + DBAR_W * s,
                                     mid + h / 2.0],
                                    radius=DBAR_W * s / 2.0, fill=col)
        if ring:
            cx = (DPAD + DCX) * s
            rr = (DBADGE_R + 2 + 4 * phase) * s
            a = int(round(190 * (1.0 - phase)))
            if a > 4:
                d.ellipse([cx - rr, mid - rr, cx + rr, mid + rr],
                          outline=_rgba(ACCENT, a),
                          width=max(1, int(round(2 * s))))
        return img.resize((self.w, self.h), Image.LANCZOS)

    def text_layout(self, text):
        """算提示文字该用哪个字号、要不要截断、胶囊要加宽到多少。

        返回 `(font, 实际要画的文字, 胶囊本体宽度)`；一个中文字体都找不到时返回
        `(None, "", DW)`，那时只画图形不画字（和以前的行为一致）。
        """
        s = self.s
        max_text_w = (TEXT_MAX_W - DBAR_X0 - TEXT_PAD_R) * s
        fonts = {}

        def measure(size, t):
            f = fonts.get(size, 0)
            if f == 0:
                f = _cjk_font(int(round(size * s)))
                fonts[size] = f
            return f.getlength(t) if f else 1e18      # 没字体 -> 永远「放不下」

        size, shown = fit_text(text, max_text_w, measure)
        font = fonts.get(size)
        if font is None:
            return None, "", DW
        w = font.getlength(shown)
        return font, shown, max(DW, DBAR_X0 + TEXT_PAD_R + w / s)

    def _text(self, d, text):
        """在声波条那块（逻辑像素 x=46 起）画提示文字（已按宽度截断/选好字号）。"""
        font = getattr(self, "_tfont", None)
        if font is None:
            return                                    # 没中文字体：只有图形，不画字
        s = self.s
        d.text(((DPAD + DBAR_X0) * s, (DPAD + DCY) * s), self._tshown or text,
               font=font, fill=_rgba(INK), anchor="lm")

    def _base(self, glyph, badge, text=None):
        key = (glyph, badge, text)
        got = self._cache.get(key)
        if got is None:
            got = self._build(glyph, badge, text)
            self._cache[key] = got
        return got

    def _build(self, glyph, badge, text=None):
        s = self.s
        W, H = self.SW, self.SH
        img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        if self.opaque:
            # --debug-opaque：洋红底，方便看清窗口实际边界
            img.paste(Image.new("RGBA", (W, H), (255, 0, 255, 255)), (0, 0))
        else:
            sh = Image.new("RGBA", (W, H), (0, 0, 0, 0))
            ImageDraw.Draw(sh).rounded_rectangle(
                self._body(dy=_CAP_DY), radius=self._radius(),
                fill=(15, 20, 40, 78))
            sh = sh.filter(ImageFilter.GaussianBlur(_CAP_BLUR * s))
            img = Image.alpha_composite(img, sh)
        # 胶囊本体：竖直渐变（上亮下略暗），像一块玻璃而不是纯色块
        body = self._body()
        grad = Image.new("RGBA", (1, H))
        px = grad.load()
        top, bot = _rgba(CAP_FILL), _rgba("#F2F3F7")
        for y in range(H):
            px[0, y] = _lerp_rgba(top, bot, y / float(H - 1))
        grad = grad.resize((W, H), Image.BILINEAR)
        mask = Image.new("L", (W, H), 0)
        ImageDraw.Draw(mask).rounded_rectangle(body, radius=self._radius(),
                                               fill=255)
        img.paste(grad, (0, 0), mask)
        d = ImageDraw.Draw(img)
        # 1px 细描边（Apple separator）：超采样下不会糊成灰边
        d.rounded_rectangle(body, radius=self._radius(),
                            outline=(0, 0, 0, 30),
                            width=max(1, int(round(0.7 * s))))
        # 徽章 + 白色扁平图形
        cx, cy = (DPAD + DCX) * s, (DPAD + DCY) * s
        r = DBADGE_R * s
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=_rgba(badge))
        self._glyph(d, glyph, cx, cy, s)
        if text:                                  # 提示文字：静态，进缓存层
            self._text(d, text)
        return img

    def _glyph(self, d, kind, cx, cy, s):
        """徽章内图形（mic/check/bang/copy），几何沿用原设计稿，只是变成抗锯齿的。"""
        col = _rgba(TXT)
        w = 2.4 * s
        if kind == "copy":
            # 两张叠起来的纸（Apple「拷贝」图标）：后面那张只描边，前面那张实心，
            # 实心那张正好把重叠处盖掉 —— 一眼就能读成「复制」。
            # 只描边+加个顶部小夹子的画法在 24px 徽章里会被看成电池，别改回去。
            d.rounded_rectangle([cx - 2.5 * s, cy - 7.5 * s, cx + 7.5 * s,
                                 cy + 3.5 * s], radius=1.8 * s, outline=col,
                                width=max(1, int(round(1.9 * s))))
            d.rounded_rectangle([cx - 7.5 * s, cy - 3.5 * s, cx + 2.5 * s,
                                 cy + 7.5 * s], radius=1.8 * s, fill=col)
            return
        if kind == "check":
            pts = [(cx - 5 * s, cy), (cx - 1.5 * s, cy + 4 * s),
                   (cx + 5.5 * s, cy - 5 * s)]
            d.line(pts, fill=col, width=int(round(w)), joint="curve")
            for px_, py_ in (pts[0], pts[-1]):          # 圆头
                d.ellipse([px_ - w / 2, py_ - w / 2, px_ + w / 2, py_ + w / 2],
                          fill=col)
            return
        if kind == "bang":
            y0, y1 = cy - 6 * s, cy + 1 * s
            d.line([(cx, y0), (cx, y1)], fill=col, width=int(round(w)))
            for py_ in (y0, y1):
                d.ellipse([cx - w / 2, py_ - w / 2, cx + w / 2, py_ + w / 2],
                          fill=col)
            d.ellipse([cx - 1.3 * s, cy + 3.5 * s, cx + 1.3 * s, cy + 6.1 * s],
                      fill=col)
            return
        # mic：胶囊头 + 半圆支架 + 立柱 + 底座
        d.rounded_rectangle([cx - 4 * s, cy - 8 * s, cx + 4 * s, cy + 2 * s],
                            radius=4 * s, fill=col)
        w2 = max(1, int(round(2 * s)))
        d.arc([cx - 7 * s, cy - 5 * s, cx + 7 * s, cy + 8 * s], start=0,
              end=180, fill=col, width=w2)
        d.line([(cx, cy + 8 * s), (cx, cy + 10 * s)], fill=col, width=w2)
        d.line([(cx - 4 * s, cy + 11 * s), (cx + 4 * s, cy + 11 * s)], fill=col,
               width=w2)
        for px_ in (cx - 4 * s, cx + 4 * s):            # 底座两端圆头
            d.ellipse([px_ - w2 / 2.0, cy + 11 * s - w2 / 2.0,
                       px_ + w2 / 2.0, cy + 11 * s + w2 / 2.0], fill=col)


class LayeredWindow:
    """WS_EX_LAYERED 悬浮窗：用 UpdateLayeredWindow 推 32 位预乘 BGRA 位图。

    不占任务栏、不抢焦点（WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE）；窗口消息由 Tk
    主循环在同一个线程里派发（已实测），所以点击仍能回到 Overlay 的事件队列。
    """

    _seq = 0

    def __init__(self, w, h, on_click=None):
        self.w, self.h = int(w), int(h)
        self.on_click = on_click
        self.hwnd = self._hdc = self._hbm = self._bits = self._old = None
        self._create()

    def _create(self):
        u, g, k32 = (ctypes.windll.user32, ctypes.windll.gdi32,
                     ctypes.windll.kernel32)
        LayeredWindow._seq += 1
        cls = "VoicePillWnd%d" % LayeredWindow._seq
        self._proc = _WNDPROC(self._on_msg)     # 必须留引用，否则回调被 GC
        k32.GetModuleHandleW.argtypes = [wt.LPCWSTR]
        k32.GetModuleHandleW.restype = wt.HMODULE
        hinst = k32.GetModuleHandleW(None)
        wc = _WNDCLASSEXW()
        wc.cbSize = ctypes.sizeof(_WNDCLASSEXW)
        wc.lpfnWndProc = self._proc
        wc.hInstance = hinst
        wc.lpszClassName = cls
        u.RegisterClassExW.argtypes = [ctypes.POINTER(_WNDCLASSEXW)]
        u.RegisterClassExW.restype = wt.ATOM
        u.RegisterClassExW(ctypes.byref(wc))
        u.CreateWindowExW.argtypes = [
            wt.DWORD, wt.LPCWSTR, wt.LPCWSTR, wt.DWORD, ctypes.c_int,
            ctypes.c_int, ctypes.c_int, ctypes.c_int, wt.HWND, wt.HMENU,
            wt.HINSTANCE, wt.LPVOID]
        u.CreateWindowExW.restype = wt.HWND
        self.hwnd = u.CreateWindowExW(
            0x00080000 | 0x00000080 | 0x08000000,   # LAYERED|TOOLWINDOW|NOACTIVATE
            cls, "voice-pill", 0x80000000,          # WS_POPUP
            0, 0, self.w, self.h, None, None, hinst, None)
        if not self.hwnd:
            raise OSError("CreateWindowExW failed: %d" % k32.GetLastError())
        u.GetDC.argtypes = [wt.HWND]
        u.GetDC.restype = wt.HDC
        u.ReleaseDC.argtypes = [wt.HWND, wt.HDC]
        u.ReleaseDC.restype = ctypes.c_int
        g.CreateCompatibleDC.argtypes = [wt.HDC]
        g.CreateCompatibleDC.restype = wt.HDC
        g.CreateDIBSection.argtypes = [
            wt.HDC, ctypes.POINTER(_BITMAPINFO), wt.UINT,
            ctypes.POINTER(ctypes.c_void_p), wt.HANDLE, wt.DWORD]
        g.CreateDIBSection.restype = wt.HBITMAP
        g.SelectObject.argtypes = [wt.HDC, wt.HGDIOBJ]
        g.SelectObject.restype = wt.HGDIOBJ
        hdc = u.GetDC(None)
        self._hdc = g.CreateCompatibleDC(hdc)
        bmi = _BITMAPINFO()
        bmi.bmiHeader.biSize = ctypes.sizeof(_BITMAPINFOHEADER)
        bmi.bmiHeader.biWidth = self.w
        bmi.bmiHeader.biHeight = -self.h        # 负数 = top-down
        bmi.bmiHeader.biPlanes = 1
        bmi.bmiHeader.biBitCount = 32
        bmi.bmiHeader.biCompression = 0
        self._bits = ctypes.c_void_p()
        self._hbm = g.CreateDIBSection(hdc, ctypes.byref(bmi), 0,
                                       ctypes.byref(self._bits), None, 0)
        self._old = g.SelectObject(self._hdc, self._hbm)
        u.ReleaseDC(None, hdc)

    def resize(self, w, h):
        """改窗口/DIB 尺寸（提示态把胶囊加宽时要重建那块 DIB）。"""
        w, h = int(w), int(h)
        if (w, h) == (self.w, self.h):
            return
        u, g = ctypes.windll.user32, ctypes.windll.gdi32
        if self._hdc and self._old:
            g.SelectObject.argtypes = [wt.HDC, wt.HGDIOBJ]
            g.SelectObject.restype = wt.HGDIOBJ
            g.SelectObject(self._hdc, self._old)      # 先把旧位图摘下来才能删
        if self._hbm:
            g.DeleteObject.argtypes = [wt.HGDIOBJ]
            g.DeleteObject.restype = ctypes.c_bool
            g.DeleteObject(self._hbm)
            self._hbm = None
        self.w, self.h = w, h
        bmi = _BITMAPINFO()
        bmi.bmiHeader.biSize = ctypes.sizeof(_BITMAPINFOHEADER)
        bmi.bmiHeader.biWidth = self.w
        bmi.bmiHeader.biHeight = -self.h              # 负数 = top-down
        bmi.bmiHeader.biPlanes = 1
        bmi.bmiHeader.biBitCount = 32
        bmi.bmiHeader.biCompression = 0
        g.CreateDIBSection.argtypes = [
            wt.HDC, ctypes.POINTER(_BITMAPINFO), wt.UINT,
            ctypes.POINTER(ctypes.c_void_p), wt.HANDLE, wt.DWORD]
        g.CreateDIBSection.restype = wt.HBITMAP
        hdc = u.GetDC(None)
        self._bits = ctypes.c_void_p()
        self._hbm = g.CreateDIBSection(hdc, ctypes.byref(bmi), 0,
                                       ctypes.byref(self._bits), None, 0)
        g.SelectObject(self._hdc, self._hbm)
        u.ReleaseDC(None, hdc)

    def _on_msg(self, hwnd, msg, wparam, lparam):
        if msg == 0x0201:                       # WM_LBUTTONDOWN：点胶囊=开始/结束
            if self.on_click:
                try:
                    self.on_click()
                except Exception as e:
                    out("pill click handler error: %r" % (e,))
            return 0
        if msg in (0x0002, 0x0010):             # WM_DESTROY / WM_CLOSE
            return 0
        u = ctypes.windll.user32
        u.DefWindowProcW.argtypes = [wt.HWND, wt.UINT, ctypes.c_size_t,
                                     ctypes.c_ssize_t]
        u.DefWindowProcW.restype = ctypes.c_ssize_t
        return u.DefWindowProcW(hwnd, msg, wparam, lparam)

    def present(self, img, x, y):
        """把 RGBA 图推到窗口并定位（同时完成显示）。"""
        u = ctypes.windll.user32
        if img.size != (self.w, self.h):
            img = img.resize((self.w, self.h), Image.LANCZOS)
        r, g, b, a = img.split()        # PIL 的顺序就是 R,G,B,A（别按名字想当然）
        # 32 位 BI_RGB DIB 在内存里的字节序是 B,G,R,A，所以要真的换一次序：
        # 按 (b,g,r,a) 重组之后内存字节才正好是 B,G,R,A。少了这一步整块色相
        # 都会 R/B 互换（蓝徽章渲染成橙色）。
        arr = np.asarray(Image.merge("RGBA", (b, g, r, a)), dtype=np.uint16)
        arr[:, :, :3] = (arr[:, :, :3] * arr[:, :, 3:4]) // 255   # alpha 预乘
        ctypes.memmove(self._bits, arr.astype(np.uint8).tobytes(),
                       self.w * self.h * 4)
        pt_dst, size, pt_src = wt.POINT(x, y), wt.SIZE(self.w, self.h), wt.POINT(0, 0)
        blend = _BLENDFUNCTION(0, 0, 255, 1)    # AC_SRC_OVER / AC_SRC_ALPHA
        u.UpdateLayeredWindow.argtypes = [
            wt.HWND, wt.HDC, ctypes.POINTER(wt.POINT), ctypes.POINTER(wt.SIZE),
            wt.HDC, ctypes.POINTER(wt.POINT), wt.DWORD,
            ctypes.POINTER(_BLENDFUNCTION), wt.DWORD]
        u.UpdateLayeredWindow.restype = ctypes.c_bool
        u.SetWindowPos.argtypes = [wt.HWND, wt.HWND, ctypes.c_int, ctypes.c_int,
                                   ctypes.c_int, ctypes.c_int, wt.UINT]
        u.SetWindowPos.restype = ctypes.c_bool
        u.ShowWindow.argtypes = [wt.HWND, ctypes.c_int]
        u.ShowWindow.restype = ctypes.c_bool
        # 先置顶+显示（SWP_SHOWWINDOW 少了窗口就永远不出现），再推位图
        u.SetWindowPos(self.hwnd, wt.HWND(-1), x, y, self.w, self.h,
                       0x0010 | 0x0040)         # SWP_NOACTIVATE|SWP_SHOWWINDOW
        u.ShowWindow(self.hwnd, 4)              # SW_SHOWNOACTIVATE
        ok = u.UpdateLayeredWindow(self.hwnd, None, ctypes.byref(pt_dst),
                                   ctypes.byref(size), self._hdc,
                                   ctypes.byref(pt_src), 0,
                                   ctypes.byref(blend), 0x00000002)  # ULW_ALPHA
        if not ok:
            out("UpdateLayeredWindow failed: %d" % ctypes.windll.kernel32.GetLastError())
        return bool(ok)

    def hide(self):
        ctypes.windll.user32.ShowWindow.argtypes = [wt.HWND, ctypes.c_int]
        ctypes.windll.user32.ShowWindow.restype = ctypes.c_bool
        ctypes.windll.user32.ShowWindow(self.hwnd, 0)      # SW_HIDE

    def destroy(self):
        try:
            ctypes.windll.user32.DestroyWindow.argtypes = [wt.HWND]
            ctypes.windll.user32.DestroyWindow.restype = ctypes.c_bool
            ctypes.windll.user32.DestroyWindow(self.hwnd)
            if self._hbm:
                ctypes.windll.gdi32.DeleteObject.argtypes = [wt.HGDIOBJ]
                ctypes.windll.gdi32.DeleteObject.restype = ctypes.c_bool
                ctypes.windll.gdi32.DeleteObject(self._hbm)
            if self._hdc:
                ctypes.windll.gdi32.DeleteDC.argtypes = [wt.HDC]
                ctypes.windll.gdi32.DeleteDC.restype = ctypes.c_bool
                ctypes.windll.gdi32.DeleteDC(self._hdc)
        except Exception as e:
            out("pill destroy error: %r" % (e,))


class LayeredView:
    """分层窗口视图（首选）：自己按 60ms 节拍渲染，且只在可见/有变化时重画。"""

    name = "layered"

    def __init__(self, ov):
        self.ov = ov
        self.r = PillRenderer(ov.k, ov.opaque)
        self.win = LayeredWindow(self.r.w, self.r.h, on_click=ov.request_toggle)
        self.glyph, self.badge = "mic", ACCENT
        self.bars = [7.0] * DNBAR
        self.ring, self.phase = False, 0.0
        self.text = None
        self.visible = False
        self._dirty = True
        self._frames = 0
        self._x = self._y = 0
        ov.root.after(30, self._loop)

    # ---- 对外接口（Overlay 只认这几个）----
    def set_glyph(self, kind, badge):
        self.glyph, self.badge = kind, badge
        self._dirty = True

    def set_text(self, text):
        """提示文字（None/空 = 回到声波条形态）。

        文字长的时候胶囊要**横向撑开**，所以这里先算一遍宽度、连窗口一起改掉；
        胶囊始终在底部居中，加宽后必须重算 x，否则会往右偏出去。
        """
        self.text = text or None
        dw = self.r.text_layout(self.text)[2] if self.text else DW
        if self.r.set_width(dw):
            self.win.resize(self.r.w, self.r.h)
            if self.visible:
                self._place()
        self._dirty = True

    def set_bars(self, heights):
        self.bars = list(heights)
        self._dirty = True

    def set_ring(self, visible, now):
        self.ring = bool(visible)
        self.phase = (now * 1.4) % 1.0 if visible else 0.0
        self._dirty = True

    def _place(self):
        """按当前窗口尺寸把胶囊摆到底部居中，返回工作区。"""
        wa = work_area()
        k = self.ov.k
        self._x = wa.left + max(0, (wa.right - wa.left - self.r.w) // 2)
        # 胶囊底边距工作区底 16 逻辑像素（窗口底还含 DPAD 的投影留白）
        self._y = wa.bottom - int(round(16 * k)) - int(round((DPAD + DH) * k))
        return wa

    def show(self):
        wa = self._place()
        self.visible = True
        self._dirty = True
        out("show wa=(%d,%d,%d,%d) geom=%dx%d+%d+%d view=layered"
            % (wa.left, wa.top, wa.right, wa.bottom, self.r.w, self.r.h,
               self._x, self._y))
        self._loop(force=True)
        out("show hwnd=%d state-ok" % self.win.hwnd)

    def hide(self):
        self.visible = False
        self.win.hide()

    def destroy(self):
        self.win.destroy()

    # ---- 渲染节拍 ----
    def _loop(self, force=False):
        try:
            if self.visible and (self._dirty or force):
                t0 = time.time()
                img = self.r.frame(self.glyph, self.badge, self.bars,
                                   self.ring, self.phase, self.text)
                self.win.present(img, self._x, self._y)
                self._dirty = False
                ms = (time.time() - t0) * 1000.0
                self._frames += 1
                if self._frames <= 2 or ms > 25:
                    out("pill frame %d: render+present %.1fms" %
                        (self._frames, ms))
        except Exception as e:
            out("pill render error: %r" % (e,))
        finally:
            self.ov.root.after(60, self._loop)


class CanvasView:
    """Tk 画布视图（回退路径：Pillow 或分层窗口不可用时仍能显示悬浮球）。"""

    name = "canvas"

    def __init__(self, ov):
        self.ov = ov
        k, opaque = ov.k, ov.opaque
        self.root = ov.root
        self.cv = ScaledCanvas(
            tk.Canvas(self.root, width=int(round(DW * k)),
                      height=int(round(DH * k)),
                      bg=(CAP_FILL if opaque else TRANS),
                      highlightthickness=0, bd=0), k)
        self.cv.pack()
        self.cap_outer = round_rect(self.cv, 1, 1, DW - 1, DH - 1, r=22,
                                    fill=(CAP_HAIR if not opaque else "#FF00FF"),
                                    outline="")
        self.cap_inner = round_rect(self.cv, 3, 3, DW - 3, DH - 3, r=20,
                                    fill=(CAP_FILL if not opaque else "#FF00FF"),
                                    outline=CAP_EDGE, width=1)
        self.dw = float(DW)
        self.visible = False
        self._font = tkfont.Font(family="Microsoft YaHei UI",
                                 size=-int(round(14 * k)))
        cx, cy = DCX, DCY
        self.rings = [self.cv.create_oval(cx - 16, cy - 16, cx + 16, cy + 16,
                                          outline="", width=2, state="hidden")]
        self.badge = self.cv.create_oval(cx - DBADGE_R, cy - DBADGE_R,
                                         cx + DBADGE_R, cy + DBADGE_R,
                                         fill=ACCENT, outline="")
        mic = [round_rect(self.cv, cx - 4, cy - 8, cx + 4, cy + 2, r=4,
                          fill=TXT, outline=""),
               self.cv.create_arc(cx - 7, cy - 5, cx + 7, cy + 8, start=180,
                                  extent=180, style="arc", outline=TXT, width=2),
               self.cv.create_line(cx, cy + 8, cx, cy + 10, fill=TXT, width=2),
               self.cv.create_line(cx - 4, cy + 11, cx + 4, cy + 11, fill=TXT,
                                   width=2)]
        check = self.cv.create_line(cx - 5, cy, cx - 1.5, cy + 4, cx + 5.5,
                                    cy - 5, fill=TXT, width=2.4,
                                    capstyle="round", joinstyle="round",
                                    state="hidden")
        bang = [self.cv.create_line(cx, cy - 6, cx, cy + 1, fill=TXT, width=2.4,
                                    capstyle="round", state="hidden"),
                self.cv.create_oval(cx - 1.3, cy + 3.5, cx + 1.3, cy + 6.1,
                                    fill=TXT, outline="", state="hidden")]
        copy = [round_rect(self.cv, cx - 2.5, cy - 7.5, cx + 7.5, cy + 3.5,
                           r=1.8, outline=TXT, width=2, state="hidden"),
                round_rect(self.cv, cx - 7.5, cy - 3.5, cx + 2.5, cy + 7.5,
                           r=1.8, fill=TXT, outline="", state="hidden")]
        self.glyphs = {"mic": mic, "check": check, "bang": bang, "copy": copy}
        self.bars, self.caps, self.bar_w = [], [], DBAR_W
        for j in range(DNBAR):
            col = _blend(BAR, BAR_IN, j / float(DNBAR - 1))
            x = DBAR_X0 + j * DBAR_PITCH
            self.bars.append(self.cv.create_rectangle(
                x, DCY - 7, x + DBAR_W, DCY + 7, fill=col, outline=""))
            self.caps.append((self.cv.create_oval(
                x, DCY - 7, x + DBAR_W, DCY + 7 - DBAR_W, fill=col, outline=""),
                self.cv.create_oval(x, DCY + 7 - DBAR_W, x + DBAR_W, DCY + 7,
                                    fill=col, outline="")))
        # 提示文字（「已复制」）：位置就是声波条那块，提示时把声波条藏起来
        self.toast = self.cv.create_text(
            DBAR_X0, DCY, text="", anchor="w", fill=INK, state="hidden",
            font=("Microsoft YaHei UI", -int(round(14 * k))))
        self.cv.bind("<Button-1>", lambda e: ov.request_toggle())
        self._exstyle_done = False

    def set_glyph(self, kind, badge):
        for name, items in self.glyphs.items():
            st = "normal" if name == kind else "hidden"
            for it in (items if isinstance(items, list) else [items]):
                self.cv.itemconfig(it, state=st)
        self.cv.itemconfig(self.badge, fill=badge)

    def _set_width(self, dw):
        """回退路径也要能把胶囊撑开：重画那两层圆角矩形，并降到底层。"""
        dw = max(float(DW), min(float(dw), TEXT_MAX_W))
        if abs(dw - self.dw) < 0.5:
            return False
        self.dw = dw
        opaque = self.ov.opaque
        self.cv.config(width=int(round(dw * self.ov.k)))
        self.cv.delete(self.cap_outer)
        self.cv.delete(self.cap_inner)
        self.cap_outer = round_rect(self.cv, 1, 1, dw - 1, DH - 1, r=22,
                                    fill=(CAP_HAIR if not opaque else "#FF00FF"),
                                    outline="")
        self.cap_inner = round_rect(self.cv, 3, 3, dw - 3, DH - 3, r=20,
                                    fill=(CAP_FILL if not opaque else "#FF00FF"),
                                    outline=CAP_EDGE, width=1)
        # 新画的图形在最上层，要压回胶囊底色去（先内后外，外层的才在最底）
        self.cv.tag_lower(self.cap_inner)
        self.cv.tag_lower(self.cap_outer)
        return True

    def set_text(self, text):
        """提示文字：显示时藏起声波条（和分层窗口那边同一个视觉约定）。

        文字长的时候同样把胶囊撑开。回退路径做得简单些：字号固定，只做「放得下
        就整段显示、放不下就省略号截断」，不像分层窗口那边还逐个字号试。
        """
        text = text or None
        self._tshown = ""
        if text:
            def meas(_size, t):
                return self._font.measure(t)
            _size, self._tshown = fit_text(
                text, (TEXT_MAX_W - DBAR_X0 - TEXT_PAD_R) * self.ov.k, meas)
            need = DBAR_X0 + TEXT_PAD_R + \
                self._font.measure(self._tshown) / float(self.ov.k)
            if self._set_width(need) and self.visible:
                self._place()
        else:
            self._set_width(DW)
        self.cv.itemconfig(self.toast, text=self._tshown,
                           state=("normal" if text else "hidden"))
        for it in self.bars:
            self.cv.itemconfig(it, state=("hidden" if text else "normal"))
        for pair in self.caps:
            for it in pair:
                self.cv.itemconfig(it, state=("hidden" if text else "normal"))

    def set_bars(self, heights):
        ends = []
        for j, h in enumerate(heights):
            h = max(self.bar_w, float(h))
            y0, y1 = DCY - h / 2.0, DCY + h / 2.0
            x0 = DBAR_X0 + j * DBAR_PITCH
            self.cv.coords(self.bars[j], x0, y0, x0 + self.bar_w, y1)
            ends.append((y0, y1))
        for j, (top, bot) in enumerate(self.caps):
            x0 = DBAR_X0 + j * DBAR_PITCH
            y0, y1 = ends[j]
            self.cv.coords(top, x0, y0, x0 + self.bar_w, y0 + self.bar_w)
            self.cv.coords(bot, x0, y1 - self.bar_w, x0 + self.bar_w, y1)

    def set_ring(self, visible, now):
        rid = self.rings[0]
        if not visible:
            self.cv.itemconfig(rid, state="hidden")
            return
        phase = (now * 1.4) % 1.0
        rr = DBADGE_R + 2 + 4 * phase
        self.cv.coords(rid, DCX - rr, DCY - rr, DCX + rr, DCY + rr)
        self.cv.itemconfig(rid, state="normal",
                           outline=_blend(ACCENT, CAP_FILL, phase))

    def _place(self):
        """按当前胶囊宽度把窗口摆到底部居中，返回工作区。"""
        wa = work_area()
        k = self.ov.k
        w, h = int(round(self.dw * k)), int(round(DH * k))
        self._geom = (w, h, wa.left + max(0, (wa.right - wa.left - w) // 2),
                      wa.bottom - h - int(round(16 * k)))
        return wa

    def show(self):
        wa = self._place()
        k = self.ov.k
        w, h, x, y = self._geom
        out("show wa=(%d,%d,%d,%d) geom=%dx%d+%d+%d view=canvas"
            % (wa.left, wa.top, wa.right, wa.bottom, w, h, x, y))
        self.root.geometry("%dx%d+%d+%d" % (w, h, x, y))
        self.root.deiconify()
        self.root.lift()
        self.root.attributes("-topmost", True)
        self.visible = True
        if not self._exstyle_done:
            self.root.update_idletasks()
            u = ctypes.windll.user32
            u.GetWindowLongW.argtypes = [wt.HWND, ctypes.c_int]
            u.GetWindowLongW.restype = ctypes.c_long
            u.SetWindowLongW.argtypes = [wt.HWND, ctypes.c_int, ctypes.c_long]
            u.SetWindowLongW.restype = ctypes.c_long
            hwnd = self.root.winfo_id()
            st = u.GetWindowLongW(hwnd, -20)            # GWL_EXSTYLE
            # 不占任务栏、不抢焦点（保证上屏仍在你原来的窗口）
            u.SetWindowLongW(hwnd, -20, st | 0x80 | 0x08000000)
            self._exstyle_done = True
        self.root.update()
        out("show hwnd=%d state-ok" % self.root.winfo_id())

    def hide(self):
        self.visible = False
        self.root.withdraw()

    def destroy(self):
        pass


def make_view(ov):
    """优先分层窗口（抗锯齿+投影）；任何一步失败都退回 Tk 画布，绝不罢工。"""
    if PIL_OK and not ov.force_canvas:
        try:
            v = LayeredView(ov)
            out("view=layered win=%dx%d ss=%dx supersample"
                % (v.r.w, v.r.h, SS))
            return v
        except Exception as e:
            out("layered view failed (%r) -> fallback to tk canvas" % (e,))
    else:
        out("view=canvas (pillow=%s force_canvas=%s)"
            % (PIL_OK, ov.force_canvas))
    return CanvasView(ov)


class Overlay:
    """底部中央悬浮胶囊（长按说话时出现，松开后消失）—— Apple 风格。

    布局（逻辑像素设计稿，窗口 100x46，另外留 DPAD 一圈给投影）：
      胶囊本体 圆头白胶囊 + 1px 细描边 + 上方渐变（玻璃质感）+ 桌面投影
      徽章    中心 (24,23) r=12，systemBlue 圆形，白色扁平麦克风图形
      图形三态 麦克风（聆听/识别中）→ ✓ 绿（已上屏）→ ！橙（出错），无文字
      声波条  徽章右侧 6 根（x=46..90），居中振幅、圆头，Blue→Teal 渐变
      呼吸环  录音时徽章外一圈淡入淡出的 systemBlue 光环

    渲染：默认走分层窗口（Pillow 4x 超采样 + 逐像素 alpha），
    `--canvas` 可强制退回 Tk 画布（无抗锯齿）做对比。
    """
    W, H = DW, DH
    HIDDEN, REC, PROC, DONE = "hidden", "rec", "proc", "done"
    CX, CY = DCX, DCY            # 徽章中心
    BADGE_R = DBADGE_R
    BAR_MID = DCY                # 声波条垂直中心（居中式）
    BAR_X0, BAR_PITCH = DBAR_X0, DBAR_PITCH
    NBAR = DNBAR

    def __init__(self, no_send=False, opaque=False, force_canvas=False):
        self.state = self.HIDDEN
        self.no_send = no_send           # --simulate 时不真正上屏
        self.opaque = opaque             # --debug-opaque：关透明做对照
        self.force_canvas = force_canvas  # --canvas：强制用 Tk 画布对比渲染
        self.frames = []
        self.level = 0.0
        self.stream = None
        self.rec_start = 0.0
        self.model = None
        self.model_evt = threading.Event()
        self.q = queue.Queue()
        self.pending_start = False       # 识别中/展示中又长按了 -> 排队补开
        # 流式输出状态（边说边上屏）
        self._emit_lock = threading.Lock()
        self.emitted = ""                # 本轮已经打进目标框的文字
        self.stream_halt = True          # 流式发送闸门（录音结束/中止即关）
        self.rec_gen = 0                 # 录音轮次，旧线程靠它退出
        self._kept_streamed = False      # 最终为空但保住了流式文字
        self._kept_len = 0               # 保住的字符数（用于日志/展示）
        self.target_hwnd = None          # 本轮文字要落进的窗口
        self.copy_only = False           # 焦点不在输入框 -> 本轮只复制、不注入

        # ---- UI 分辨率：进程先设为 DPI 感知（必须在建 Tk 窗口前），再按实测
        # DPI 把 100x46 逻辑设计稿放大到物理像素原生渲染，消除位图拉伸发虚。
        self.dpi_mode = enable_dpi_awareness()
        self.k = k = (system_dpi() / 96.0) if self.dpi_mode else 1.0
        out("dpi mode=%s scale=%.2f" % (self.dpi_mode or "unaware", k))

        # Tk 建根窗口时会 map 一次：即使紧接着 withdraw()，Windows 也可能把
        # "前台"留在那个已经隐藏的 Tk 窗口上，表现为「悬浮球刚启动那会儿打字
        # 没反应」（开机自启时尤其容易撞上）。先记下启动前的前台窗口，等窗口
        # 都建完再还回去。
        prev_fg = foreground_window()
        self.root = tk.Tk()
        self.root.title("voice-overlay")
        self.root.overrideredirect(True)
        self.root.attributes("-topmost", True)
        if not opaque:
            self.root.attributes("-transparentcolor", TRANS)
        self.root.withdraw()

        # ---- 外观：优先分层窗口（4x 超采样抗锯齿 + 逐像素 alpha 投影），
        # 失败则退回 Tk 画布（无抗锯齿，但一定能显示，绝不罢工）。
        self.view = make_view(self)

        self.root.update_idletasks()
        restore_foreground(prev_fg)

        threading.Thread(target=self._load_model, daemon=True).start()
        threading.Thread(target=self._warm_asr, daemon=True).start()

    def _warm_asr(self):
        """启动即确保 llama-server 常驻（约 2s），首轮说话零等待。"""
        try:
            if asr_alive(0.5):
                out("asr server already running")
            else:
                asr_start()
        except Exception as e:
            out("asr warmup error: %r" % (e,))

    # ---- 模型 ----
    def _load_model(self):
        try:
            if not VOSK_OK:
                raise RuntimeError("vosk module not installed")
            if not MODEL_DIR:
                raise RuntimeError("vosk model dir not found")
            t0 = time.time()
            self.model = vosk.Model(MODEL_DIR)
            self.model_evt.set()
            out("model loaded in %.2fs" % (time.time() - t0))
        except Exception as e:
            out("model load FAILED: %r" % (e,))
            self.model_evt.set()

    # ---- 显示（全部交给视图层：分层窗口 或 Tk 画布回退）----
    def _show(self):
        self.view.show()

    def _hide(self):
        self.view.set_text(None)          # 提示文字不能带到下一次显示
        self.view.hide()

    # ---- 提示（「已复制」或绿色对勾）----
    def _toast(self, text, glyph="copy", badge=None, cap=TOAST_MS_MAX):
        """悬浮球里弹一条提示，到时自动收起。"""
        self.state = self.DONE
        self._set_glyph(glyph, badge or ACCENT)
        self.view.set_text(text)
        self._show()
        out("toast: %s" % text)
        self.root.after(toast_ms(len(text), cap), self._finish_done)

    def _check_feedback(self):
        """输入框成功上屏只显示绿色对勾，不把识别全文画到悬浮球。"""
        self.state = self.DONE
        self._set_glyph("check", GREEN)
        self.view.set_text(None)
        self._show()
        out("toast: check")
        self.root.after(TOAST_MS, self._finish_done)

    # ---- 录音 ----
    def _audio_cb(self, indata, frames, time_info, status):
        self.frames.append(bytes(indata))
        v = float(np.abs(indata).mean()) / 32768.0
        self.level = self.level * 0.7 + v * 0.3

    def start_rec(self):
        self.frames = []
        self.level = 0.0
        self.rec_start = time.time()
        self.view.set_text(None)         # 清掉上一轮的提示文字（回到声波条形态）
        # 流式状态复位：清空已上屏文本、开发送闸门、轮次 +1 让旧线程退出
        with self._emit_lock:
            self.emitted = ""
            self.stream_halt = False
            self.rec_gen += 1
            gen = self.rec_gen
        self.target_hwnd = get_foreground_hwnd()   # 文字要落进的那个窗口
        # 焦点在不在一个「输入框」里？不在（桌面/列表/任务栏/终端/浏览器页面空白处…）
        # 就整轮不注入，识别完把文字复制进剪贴板 + 弹「已复制」提示。
        # 策略是**所有非输入框都复制**（含 UIA 正常但判不准的情形）。
        state, facts = focus_target_state()
        self.copy_only = bool(facts.get("copy"))
        out("focus target=%s fg=%s focus=%s caret=%s uia=%s ct=%s name=%r -> %s"
            % (state, facts.get("fg_cls") or "?", facts.get("focus_cls") or "-",
               facts.get("caret") or 0, facts.get("uia") or "off",
               facts.get("uia_ct") or "-", facts.get("uia_name") or "",
               "copy only" if self.copy_only else "inject"))
        # 麦克风每次录音前重读配置 -> 在设置窗口改完设备，下一次按住说话就生效，
        # 不用重启悬浮球（llama-server 那些进程级参数才需要重启）。
        dev, dev_desc = asr_input_device()
        try:
            self.stream = sd.InputStream(samplerate=SAMPLE_RATE,
                                         blocksize=BLOCK, dtype="int16",
                                         channels=1, device=dev,
                                         callback=self._audio_cb)
            self.stream.start()
        except Exception as e:
            out("mic open failed: %r" % (e,))
            # 配置的设备被拔了/被独占（另一软件占着）时，退回系统默认再试一次 ——
            # 宁可换个麦继续录，也不能让语音输入直接罢工。
            if dev is not None:
                out("mic fallback: %s -> system default (%s)" % (dev_desc, e))
                try:
                    self.stream = sd.InputStream(samplerate=SAMPLE_RATE,
                                                 blocksize=BLOCK, dtype="int16",
                                                 channels=1, callback=self._audio_cb)
                    self.stream.start()
                    dev_desc = "system default (fallback from %s)" % (dev_desc,)
                except Exception as e2:
                    out("mic default open failed too: %r" % (e2,))
                    self._mic_failed()
                    return
            else:
                self._mic_failed()
                return
        self.state = self.REC
        self._set_glyph("mic", ACCENT)
        self._show()
        out("record start (mic=%s)" % (dev_desc,))
        threading.Thread(target=self._stream_loop, args=(gen,),
                         daemon=True).start()

    def _mic_failed(self):
        """打不开麦克风时的统一收尾：橙色 ！ + 1.5 秒后收起。"""
        with self._emit_lock:
            self.stream_halt = True
        self._set_glyph("bang", WARN)
        self.state = self.DONE
        self._show()
        self.root.after(1500, self._finish_done)

    # ---- 流式识别：边说边把增量打进目标框 ----
    def _stream_loop(self, gen):
        if self.copy_only:
            # 目标根本收不了字：不做流式（也就没有「已上屏」要对账），
            # 松开后一次性复制整段结果。
            out("stream disabled: focus is not an edit box")
            return
        last_bytes, last_run = 0, 0.0
        prev = ""                          # 上一轮的识别文本（做双轮稳定）
        while True:
            time.sleep(0.05)
            with self._emit_lock:
                if self.stream_halt or gen != self.rec_gen:
                    return                # 录音结束/中止/新一轮 -> 本线程退出
            if not asr_alive(0.3):
                continue                  # server 还没起来，等它
            snapshot = list(self.frames)  # 录音线程在追加，先快照
            if not snapshot:
                continue
            raw = b"".join(snapshot)
            if len(raw) == last_bytes:
                continue                  # 没有新音频，不重复识别
            audio_len = len(raw) / (SAMPLE_RATE * 2.0)
            if audio_len < STREAM_MIN_AUDIO:
                continue                  # 太短，等累计够再开始
            now = time.time()
            interval = min(STREAM_INTERVAL_MAX,
                           max(STREAM_INTERVAL, audio_len * STREAM_TAIL_RATIO))
            if now - last_run < interval:
                continue
            last_run, last_bytes = now, len(raw)
            partial = asr_recognize(snapshot)
            with self._emit_lock:
                if self.stream_halt or gen != self.rec_gen:
                    return                # 识别期间用户松开了，交给最终识别
            if partial is None:
                out("stream: asr failed, streaming stops")
                return                    # server 挂了 -> 降级 vosk（只做最终）
            delta, mode = stream_round(prev, partial, self.emitted)
            prev = partial
            if delta is None:
                # 模型回头改写了已上屏的部分 -> 前向续发尾巴（按住期间不能
                # 退格，冻结只会停摆）；大幅改写才继续冻结等最终对账
                out("stream revise deferred (emitted=%d, partial=%d)"
                    % (len(self.emitted), len(partial)))
                continue
            if mode == "forward":
                out("stream revise forward +%d chars (mid part fixed at release)"
                    % len(delta))
            if len(delta) < STREAM_MIN_DELTA:
                continue
            if get_foreground_hwnd() != self.target_hwnd:
                out("stream stop: focus changed")
                with self._emit_lock:
                    self.stream_halt = True
                return                    # 焦点跑了，别把字打进别的窗口
            if not self.no_send:
                send_text(delta)          # 按住期间直接注入（已实测可落字）
            self.emitted = full = self.emitted + delta
            out("stream +%d chars (total %d)" % (len(delta), len(full)))

    def _retract_streamed(self, emitted):
        """abort 后撤回已流式上屏的文字：等修饰键松开 + 焦点没变才退格。"""
        if not wait_modifiers_up(ABORT_RETRACT_WAIT):
            out("retract skipped: modifiers still held")
            return
        if not self._focus_ok():
            out("retract skipped: focus changed (text left in place)")
            return
        if send_backspaces(len(emitted)):
            out("retracted %d streamed chars" % len(emitted))

    def stop_rec(self):
        dur = time.time() - self.rec_start
        with self._emit_lock:            # 关流式闸门（线程看到即退出）
            self.stream_halt = True
        if self.stream is not None:
            try:
                self.stream.stop()
                self.stream.close()
            except Exception as e:
                out("mic close error: %r" % (e,))
            self.stream = None
        if dur < TAP_MIN:
            # 长按确认后又秒松 -> 没说完话，静默丢弃
            out("record discarded (too short: %.2fs)" % dur)
            self.frames = []
            self.state = self.HIDDEN
            self._hide()
            return
        self.state = self.PROC
        self._set_glyph("mic", ACCENT)
        out("record stop, %.2fs, %d chunks" % (dur, len(self.frames)))
        threading.Thread(target=self._recognize, daemon=True).start()

    def abort_rec(self, why=""):
        """按住期间出现第三键 / 系统组合 -> 立即作废，不上屏。"""
        with self._emit_lock:            # 关闸并取出已流式上屏的文字
            self.stream_halt = True
            emitted = self.emitted
            self.emitted = ""
        if self.stream is not None:
            try:
                self.stream.stop()
                self.stream.close()
            except Exception as e:
                out("mic close error: %r" % (e,))
            self.stream = None
        self.frames = []
        out("record aborted %s" % why)
        if emitted and not self.no_send:
            # 流式已经把字打进去了 -> 异步撤回（等修饰键松开、焦点没变才退格）
            threading.Thread(target=self._retract_streamed,
                             args=(emitted,), daemon=True).start()
        if self.state == self.REC:
            self.state = self.HIDDEN
            self._hide()

    # ---- 识别与上屏 ----
    def _focus_ok(self):
        """前台窗口是否还是本轮的目标窗口。

        退格是**破坏性**且不可撤销的操作：用户松开后若已切走窗口，再按 VK_BACK
        就会删掉新窗口里他自己的内容。所以退格前必须确认焦点没变；没记录到
        目标窗口时（启动瞬间前台为空）无从比对，按原样放行。
        """
        if not self.target_hwnd:
            return True
        return get_foreground_hwnd() == self.target_hwnd

    def _reconcile(self, text):
        """最终结果与流式已上屏文字对账，返回本轮还需要补发的文本。

        - 前缀一致 -> 只补尾巴（常见情况，零退格）；
        - 前缀一致但尾巴被改写 -> 只删那截改掉的尾巴（trim，退格数=真正变了
          的字数，不随整句长度增长）；
        - 从头就不一致 -> 退格删掉已上屏的，再发完整最终结果；
        - 最终为空但流式有字 -> 保留已上屏的（宁可留字不瞎删）。

        决策本身是纯函数 `reconcile_plan`（selftest 与回归测试共用同一份）。
        """
        with self._emit_lock:
            emitted = self.emitted
            self.emitted = ""
        mode, payload = reconcile_plan(text, emitted)
        if mode == "none":
            return payload               # 没流式过，原样整段发送
        if mode == "keep":
            out("reconcile: keep %d, tail +%d" % (len(emitted), len(payload)))
            return payload
        if mode == "keep_all":
            return ""                    # 保留已上屏，一个字都不删

        if mode == "trim":
            trim, insert = payload
            out("reconcile: trim (emitted=%d, final=%d, del=%d, ins=%d)"
                % (len(emitted), len(text), trim, len(insert)))
        else:
            trim, insert = len(emitted), text
            out("reconcile: rewrite (emitted=%d, final=%d)"
                % (len(emitted), len(text)))

        if self.no_send:
            return text                  # simulate：什么都没真发过，不退格
        if not wait_modifiers_up():
            out("reconcile timeout: keep streamed text, append nothing")
            return ""
        if not self._focus_ok():
            # 焦点变了：宁可留下错位的流式文字，也绝不去别的窗口按退格
            out("reconcile retract skipped: focus changed (text left in place)")
            return ""
        secs = reconcile_secs()
        t0 = time.time()
        if not send_backspaces(trim, secs):
            out("reconcile retract failed: append nothing")
            return ""
        out("reconcile: removed %d chars in %.0fms (budget %.1fs)"
            % (trim, (time.time() - t0) * 1000, secs))
        return insert

    def _recognize(self):
        text = None
        data = b"".join(self.frames)
        backend = ""
        # 1) 优先 Qwen3-ASR（llama-server 常驻，热请求 ~0.2s）
        try:
            if asr_alive(0.5):
                text = asr_recognize(self.frames)
                if text is not None:
                    backend = "qwen3-asr"
        except Exception as e:
            out("asr recognize error: %r" % (e,))
            text = None
        # 2) 降级 vosk（server 没起来 / HTTP 失败）
        if text is None:
            text = ""
            try:
                if not self.model_evt.wait(10) or self.model is None:
                    out("model not ready")
                else:
                    rec = vosk.KaldiRecognizer(self.model, SAMPLE_RATE)
                    for i in range(0, len(data), 32000):
                        rec.AcceptWaveform(data[i:i + 32000])
                    text = json.loads(rec.FinalResult()).get("text", "")
                    text = text.replace(" ", "").strip()
                    backend = "vosk"
                    if punct_space_enabled():
                        text = punct_to_space(text)
            except Exception as e:
                out("recognize error: %r" % (e,))
        if backend:
            out("backend=%s chars=%d" % (backend, len(text)))
        if self.copy_only:
            # 焦点不在输入框：一个字都不注入，整段复制进剪贴板，UI 线程弹「已复制」。
            # （copy_only 时流式是关的，emitted 必为空，所以没有对账要跑。）
            copied = bool(text) and (not self.no_send) and set_clipboard_text(text)
            out("clipboard fallback: %s chars, copied=%s"
                % (len(text or ""), copied))
            self.q.put(("result", {"display": text or "", "send": "",
                                   "kept": 0, "copy": copied}))
            return
        # 3) 与流式已上屏的部分对账，得出真正需要补发的增量
        with self._emit_lock:
            had_streamed = bool(self.emitted)
        if not text and had_streamed:
            # 最终识别为空，流式文字原样保留 -> 算成功
            with self._emit_lock:
                self._kept_len = len(self.emitted)
            self.q.put(("result", {"display": "", "send": "",
                                   "kept": self._kept_len}))
            return
        send_part = self._reconcile(text) if (text or had_streamed) else text
        if send_part and not self.no_send:
            # 等 Ctrl/Win 全松开再注入，避免修饰键状态影响目标窗口
            if not wait_modifiers_up():
                out("modifiers still held after %.1fs, send anyway"
                    % MOD_RELEASE_WAIT)
        # display=完整最终结果（日志/展示用）；send=真正要注入的增量
        # （流式前缀一致时 send 为空但依然算成功，不能判成空结果）
        self.q.put(("result", {"display": text or "",
                               "send": send_part,
                               "kept": 0}))

    def _on_result(self, payload):
        if isinstance(payload, str):        # 兼容旧载荷
            payload = {"display": payload, "send": payload, "kept": 0}
        display = payload.get("display", "")
        send_part = payload.get("send", "")
        kept = payload.get("kept", 0)
        copied = bool(payload.get("copy"))
        if kept:
            out("result: (empty final, %d streamed chars kept)" % kept)
            ok = True
        elif display:
            out("result: %s" % display)
            ok = True
        else:
            out("result: (empty)")
            ok = False
        if send_part and not self.no_send:
            if not send_text(send_part):
                # SendInput 没落地（目标其实收不了字，比如自绘界面里没聚焦输入框）
                # -> 同样兜底复制，别让用户白说一遍
                copied = bool(display) and set_clipboard_text(display)
                out("send failed -> clipboard fallback: copied=%s" % copied)
        if self.state == self.REC:
            return                       # 用户已开了新一轮，别打断它
        # 复制兜底：球上**只**给「已复制」这四个字，不把识别内容一起画出来。
        # 用户明确要求「只要复制提示，具体内容不要显示」—— 内容已经在剪贴板里，
        # 他随手 Ctrl+V 就能看到；球上再复述一遍只是占地方。
        # （正常注入那条路只显示绿色对勾，识别全文已经完整落进输入框。）
        if copied:
            self._toast(TOAST_TEXT)
            return
        if ok:
            self._check_feedback()
            return
        self._set_glyph("bang", WARN)
        self.state = self.DONE
        self.root.after(900, self._finish_done)

    def _finish_done(self):
        if self.state == self.DONE:
            self.state = self.HIDDEN
            self._hide()
            if self.pending_start:
                self.pending_start = False
                self.root.after(150, self.start_rec)   # 识别中又长按 -> 补开

    # ---- 长按事件入口（轮询线程投递，主线程消费） ----
    def on_chord(self, kind):
        # 记一笔「本程序正在做语音输入」：微信输入法语音面板抑制器据此决定动手
        # （只在我们的会话期间动手，别的时候不碰人家的窗口）。
        mark_voice_active()
        self.q.put((kind, None))

    def _on_chord(self, kind):
        if kind == "start":
            if self.state in (self.HIDDEN, self.DONE):
                # DONE = 上一条识别结果的提示还挂在屏幕上。这时用户又开口了，
                # 必须**立刻**开录：提示是给人看的，不是闸门。排队等提示自己
                # 收掉的话，一段长结果能让下一次说话干等好几秒。
                if self.state == self.DONE:
                    out("toast dismissed by new recording")
                self.state = self.HIDDEN
                self._hide()
                self.start_rec()
            elif self.state == self.PROC:
                self.pending_start = True
                out("chord start queued (busy)")
            # REC：已在录，忽略重复
        elif kind == "stop":
            if self.state == self.REC:
                self.stop_rec()
        elif kind == "abort":
            if self.state == self.REC:
                self.abort_rec("(third key)")

    # ---- 点击胶囊也能手动结束 ----
    def request_toggle(self):
        self.q.put(("toggle", None))

    def _on_toggle(self):
        if self.state in (self.HIDDEN, self.DONE):
            if self.state == self.DONE:      # 同上：点一下就开始，别等提示收掉
                self.state = self.HIDDEN
                self._hide()
            self.start_rec()
        elif self.state == self.REC:
            self.stop_rec()
        # 识别中：忽略，避免打断

    def _set_glyph(self, kind, badge_color):
        """切换徽章内图形（mic/check/bang/copy）与徽章底色 —— Apple 式无文字状态。"""
        self.view.set_glyph(kind, badge_color)

    # ---- 动画（数值都是逻辑像素，由视图层自己换算到物理像素）----
    def _set_bars(self, heights):
        """heights: 6 个值（徽章右侧 6 根，居中振幅）。"""
        self.view.set_bars(heights)

    def _set_rings(self, visible, now):
        self.view.set_ring(visible, now)

    def tick(self):
        try:
            while True:
                kind, payload = self.q.get_nowait()
                if kind == "toggle":
                    self._on_toggle()
                elif kind == "result":
                    self._on_result(payload)
                else:
                    self._on_chord(kind)
        except queue.Empty:
            pass

        now = time.time()
        if self.state == self.REC:
            if now - self.rec_start > MAX_SECONDS:
                self.stop_rec()
            else:
                lvl = min(self.level * 600.0, 40.0)
                hs = []
                for j in range(self.NBAR):
                    h = (7
                         + lvl * (0.30 + 0.55 * abs(
                             np.sin(now * 8.0 - j * 0.8)))
                         + 5 * (0.5 + 0.5 * np.sin(now * 3.5 + j * 0.9)))
                    hs.append(min(h, 26.0))
                self._set_bars(hs)
                self._set_rings(True, now)
        elif self.state == self.PROC:
            self._set_bars(
                [7 + 14 * (0.5 + 0.5 * np.sin(now * 7.0 - j * 0.7))
                 for j in range(self.NBAR)])
            self._set_rings(False, now)
        else:
            self._set_rings(False, now)
        self.root.after(60, self.tick)

    def run(self):
        self.root.after(50, self.tick)
        self.root.mainloop()


# --------------------------------------------------------------------- 入口
def single_instance():
    k32 = ctypes.windll.kernel32
    k32.CreateMutexW.restype = ctypes.c_void_p
    k32.CreateMutexW.argtypes = [ctypes.c_void_p, ctypes.c_int,
                                 ctypes.c_wchar_p]
    k32.GetLastError.restype = ctypes.c_ulong
    h = k32.CreateMutexW(None, 0, "RimeVoiceOverlaySingleton")
    already = bool(h) and k32.GetLastError() == 183  # ERROR_ALREADY_EXISTS
    return not already


def selftest():
    ev = []
    d = ChordDetector(lambda k: ev.append(k), arm=0.12)

    def kd(vk):
        d.on_key(vk, True)

    def ku(vk):
        d.on_key(vk, False)

    # 1) 短于 arm 的点按：什么都不发（误触防护）
    kd(VK_LCONTROL); kd(VK_LWIN)
    time.sleep(0.05)
    ku(VK_LWIN); ku(VK_LCONTROL)
    time.sleep(0.20)
    assert ev == [], "tap must be silent, got %r" % ev

    # 2) 长按 -> start；松开一个 -> stop；全松开后重新武装
    kd(VK_LCONTROL); kd(VK_LWIN)
    time.sleep(0.25)
    assert ev == ["start"], "hold expected start, got %r" % ev
    ku(VK_LCONTROL)
    assert ev == ["start", "stop"], "release-one expected stop, got %r" % ev
    ku(VK_LWIN)
    time.sleep(0.05)
    assert ev == ["start", "stop"], "must not double-fire"

    # 3) 反序（先 Win 后 Ctrl）同样工作
    kd(VK_LWIN); kd(VK_LCONTROL)
    time.sleep(0.25)
    assert ev == ["start", "stop", "start"], "win-first start, got %r" % ev
    ku(VK_LCONTROL); ku(VK_LWIN)
    time.sleep(0.05)
    assert ev == ["start", "stop", "start", "stop"], "win-first stop"

    # 4) 长按期间第三键 -> abort，且全松开前不重触发
    kd(VK_LCONTROL); kd(VK_LWIN)
    time.sleep(0.25)
    assert ev[-1] == "start"
    kd(0x44)                                    # Ctrl+Win+D
    assert ev[-1] == "abort", "third key must abort, got %r" % ev[-1]
    ku(0x44)
    ku(VK_LWIN); ku(VK_LCONTROL)
    time.sleep(0.10)
    n = len(ev)
    assert n == 6, "expected 6 events, got %d %r" % (n, ev)

    # 5) abort 前的短按（arm 内出现第三键）也应静默作废
    kd(VK_LCONTROL); kd(VK_LWIN); kd(0x41)
    ku(0x41); ku(VK_LWIN); ku(VK_LCONTROL)
    time.sleep(0.20)
    assert len(ev) == 6, "cancelled arm must stay silent, got %r" % ev

    # 6) 只按 Ctrl / 只按 Win 不触发
    kd(VK_LCONTROL); time.sleep(0.25); ku(VK_LCONTROL)
    kd(VK_LWIN); time.sleep(0.25); ku(VK_LWIN)
    time.sleep(0.15)
    assert len(ev) == 6, "single modifier must not fire, got %r" % ev

    # 7) needs_scan 只在双键按下时为真
    assert not d.needs_scan()
    kd(VK_LCONTROL)
    assert not d.needs_scan()
    kd(VK_LWIN)
    assert d.needs_scan()
    ku(VK_LWIN); ku(VK_LCONTROL)

    # 8) SendInput 结构体大小（x64 应为 40）
    assert ctypes.sizeof(INPUT) == 40, \
        "INPUT size %d != 40" % ctypes.sizeof(INPUT)

    # 9) 工作区读取正常
    wa = work_area()
    assert wa.bottom - wa.top > 200 and wa.right - wa.left > 200, \
        "work area broken: %r" % ((wa.left, wa.top, wa.right, wa.bottom),)

    # 10) 颜色混合函数边界
    assert _blend("#000000", "#FFFFFF", 0.5) == "#808080"
    assert _blend("#FF0000", "#FF0000", 3.0) == "#FF0000"

    # 11) 流式双轮稳定前缀：首轮播种 / 追加 / 稳定不变 / 模型改写
    assert stream_step("", "今天天气", "") == ""          # 首轮只播种
    assert stream_step("今天天", "今天天气真好", "") == "今天天"
    assert stream_step("今天天气真好", "今天天气真好", "今天天") == "气真好"
    assert stream_step("今天天气真好", "今天天气真好", "今天天气真好") == ""
    assert stream_step("今天天气", "明天天气", "今天天气") is None  # 改写
    assert stream_step("今天天气真好", "今天天", "今天天气真好") is None

    # 11b) 改写冻结时的前向续发：小改写追加尾巴，大幅改写/无新增仍冻结
    assert stream_recover("今天天气", "今天天气真好") is None   # partial 不比已上屏长
    assert stream_recover("今天天气真好", "今天天气真好") is None  # 无新增可发
    # 改写点：已上屏「今天天气真好」6 字，模型改成「今天天气真的好啊」——
    # 错位 1 字（<= max(4, 6//3)=4），超出已上屏长度的尾巴 = partial[6:] 续发
    assert stream_recover("今天天气真的好啊", "今天天气真好") == "好啊"
    # 大幅改写（已上屏 9 字错位 9 > max(4, 3)）-> 冻结等最终对账
    assert stream_recover("完全换了另一句话在说别的内容", "今天天气真好还行吧") is None

    # 15) 流式一轮决策（纯函数，实机与测试共用）+ 最终对账决策
    assert stream_round("今天天", "今天天气真好", "") == ("今天天", "stable")
    assert stream_round("今天天气真好", "今天天气真好", "今天天气真好") \
        == ("", "stable")
    assert stream_round("今天天气", "明天天气", "今天天气") \
        == (None, "deferred")                         # 大幅改写 -> 冻结
    assert stream_round("今天天气真好", "今天天气真的好啊", "今天天气真好") \
        == ("好啊", "forward")                        # 小改写 -> 前向续发

    assert reconcile_plan("随便什么", "") == ("none", "随便什么")
    assert reconcile_plan("今天天气真好 我们去吧", "今天天气真好") \
        == ("keep", " 我们去吧")
    assert reconcile_plan("今天天气真好", "今天天气不错") == ("trim", (2, "真好"))
    assert reconcile_plan("", "今天天气真好") == ("keep_all", "")

    # 15c) 公共前缀裁剪：只删「真正变了」的那一截，退格数不随整句长度增长。
    #      这是「删除耗时固定」的落点——退格数直接等于要删的字数。整段重打是
    #      2n 个事件，trim 恒 <= 2n，永远不会更慢。
    #      注意签名为 reconcile_plan(text=最终, emitted=已上屏)
    assert reconcile_plan("今天天气真好啊", "今天天气真不错") == ("trim", (2, "好啊"))
    # 尾巴变短：删多补少（删 2 补 0）
    assert reconcile_plan("今天天气", "今天天气真好") == ("trim", (2, ""))
    # 从头就不一致：退化成整段重打（退格数 = 已上屏全部）
    assert reconcile_plan("你好世界", "今天天气真好") == ("trim", (6, "你好世界"))
    # 已上屏是最终结果的前缀 -> 走 keep，零退格
    assert reconcile_plan("今天天气真好我们去公园", "今天天气真好") == ("keep", "我们去公园")
    for old, new in (("今天天气不错", "今天天气真好"),
                     ("今天天气真不错", "今天天气真好啊"),
                     ("我们明天去公园散步吧", "我们明天去公园跑步吧")):
        mode, (trim, insert) = reconcile_plan(new, old)
        assert mode == "trim", "%r -> %r 应为 trim，实为 %s" % (old, new, mode)
        # 不变量：抹掉尾巴 trim 个 + 补上 insert，必须恰好还原成最终结果
        assert old[:len(old) - trim] + insert == new, \
            "trim 还原失败: %r %r -> %r" % (old, new, old[:len(old) - trim] + insert)
        # 不变量：trim 的事件数 <= 整段重打的事件数
        assert trim + len(insert) <= len(old) + len(new), "trim 比重写还多"
    # 退格数不随整句长度增长：不管句子多长，只在结尾改 3 个字就只删 3 个
    for n in (10, 40, 82, 126, 200):
        old = "甲" * n
        new = "甲" * (n - 3) + "乙丙丁"
        _, (trim, insert) = reconcile_plan(new, old)
        assert trim == 3, "n=%d 只该删 3 个字，实得 %d" % (n, trim)
        assert trim + len(insert) == 6, \
            "n=%d 事件数应为 6，实得 %d" % (n, trim + len(insert))

    # 15d) 替换预览的节奏。两条通道各有各的节奏函数：
    #      * 慢通道 backspace_pace（真实键盘注入，兜底）：每格不得低于可靠投递下限
    #        （低于下限会静默丢退格，屏幕上就是残留错字——比慢严重得多）；
    #      * 快通道 fast_delete_pace（直接投键消息）：**没有下限**，「调多快就真的
    #        多快」，0 秒 = 一口气投完 —— 这正是本轮需求「调快替换时间，但一个字
    #        都不许少删」的落点。
    #      两条都保持「恒定」：预算装得下时总时长 == 预算，不随句子长短变。
    for n in (1, 3, 12, 24, 30):
        h, g = backspace_pace(n, 1.0)
        # 墙钟总时长 = 每格 sleep + 每格固定开销，必须恰好落在预算上
        assert abs(n * (h + g + BACKSPACE_OVERHEAD) - 1.0) < 1e-9, \
            "n=%d 墙钟不是 1s: %.4fs" % (n, n * (h + g + BACKSPACE_OVERHEAD))
        assert h > 0 and g > 0, "n=%d 不能退化成 0 间隔" % n
    # 慢通道下限：约 31 格以上每格 sleep 就是 24ms，总时长被下限顶长，
    # 但这才是可靠投递的门槛（低于它直接丢退格、屏幕上留错字）
    for n in (31, 42, 46, 100):
        h, g = backspace_pace(n, 1.0)
        assert abs((h + g) - BACKSPACE_FLOOR) < 1e-9, \
            "n=%d 应压到下限 %.3f，实得 %.3f" % (n, BACKSPACE_FLOOR, h + g)
    # 「恒定」的含义：预算装得下时总时长都恰好是预算，不随句长变化
    for n in (5, 10, 20, 30):
        h, g = backspace_pace(n, 1.0)
        assert abs(n * (h + g + BACKSPACE_OVERHEAD) - 1.0) < 1e-9, \
            "n=%d 总时长不是 1s" % n
    # 无论 n 多大，慢通道每格 sleep 都不会低于下限（恒定 ≠ 靠丢键换速度）
    for n in (1, 5, 12, 31, 46, 200, 1000):
        h, g = backspace_pace(n, 1.0)
        assert h + g >= BACKSPACE_FLOOR - 1e-12, "n=%d 低于可靠下限" % n
        assert h >= BACKSPACE_HOLD - 1e-12, "n=%d 按住时间低于实测门槛" % n
    # 预算可调：2s 预算 -> 墙钟 2s；n=0 一个键都不发
    h, g = backspace_pace(20, 2.0)
    assert abs(20 * (h + g + BACKSPACE_OVERHEAD) - 2.0) < 1e-9
    assert backspace_pace(0) == (0.0, 0.0)
    # 非法预算退回默认（配置文件被人手改坏不能把节奏搞崩）
    assert backspace_pace(10, "abc") == backspace_pace(10, RECONCILE_SECS_DEFAULT)
    assert backspace_pace(10, None) == backspace_pace(10, RECONCILE_SECS_DEFAULT)

    # 15e) 快通道：**没有每格下限**（本轮需求的核心：调多快就真的多快）
    assert fast_delete_pace(46, 0.0) == 0.0, "0 秒必须是一口气投完"
    assert abs(fast_delete_pace(10, 1.0) - 0.1) < 1e-12
    assert fast_delete_pace(100, 3.0) == 0.03
    assert fast_delete_pace(0, 1.0) == 0.0
    assert fast_delete_pace(10, None) == 0.0        # 非法预算退回默认（0 = 立刻）
    assert fast_delete_pace(10, -5) == 0.0          # 负数当 0：只许更快，不许负 sleep
    for n in (1, 12, 46, 1000):                     # 任意 n 都不撞下限
        assert fast_delete_pace(n, 0.1) <= 0.1 + 1e-12, "n=%d 撞下限" % n
    # 键消息 lParam 的位段：scan code 在 16-23 位，松开位 30/31
    assert fast_delete_lparam(0x0E) == 0x000E0001
    assert fast_delete_lparam(0x0E, True) == 0xC00E0001
    assert fast_delete_lparam(BACKSPACE_SCAN) == (1 | (BACKSPACE_SCAN << 16))
    # 黑名单：UWP / XAML 岛退回慢通道，普通窗口照走快通道
    assert not fast_delete_class_ok("Windows.UI.Core.CoreWindow")
    assert not fast_delete_class_ok("XamlIslandWindow")
    assert fast_delete_class_ok("RichEditD2DPT")
    assert fast_delete_class_ok("Chrome_WidgetWin_1")
    assert fast_delete_class_ok("TkChild")
    assert fast_delete_class_ok("")                 # 类名读不到不当作黑名单

    # 15f) reconcile_secs 的解析：0.0 是合法值（= 立刻），越界/坏值退回默认
    assert parse_reconcile_secs("0") == 0.0
    assert parse_reconcile_secs("0.0") == 0.0
    assert parse_reconcile_secs("0.4") == 0.4
    assert parse_reconcile_secs("3.0") == RECONCILE_SECS_MAX
    assert parse_reconcile_secs("3.1") == RECONCILE_SECS_DEFAULT
    assert parse_reconcile_secs("-1") == RECONCILE_SECS_DEFAULT
    assert parse_reconcile_secs("abc") == RECONCILE_SECS_DEFAULT
    assert parse_reconcile_secs(None) == RECONCILE_SECS_DEFAULT
    assert parse_reconcile_secs("") == RECONCILE_SECS_DEFAULT
    assert isinstance(reconcile_secs(), float)
    # 0.2.39：默认必须是「立刻替换」。默认慢一档 = 每次识别结束都白等一秒，
    # 而这正是用户报的「时长太长」；快通道已经证明 0 秒既最快又一格不丢，
    # 所以「默认快」和「删干净」不冲突（不要把它改回 1.0）。
    assert RECONCILE_SECS_DEFAULT == 0.0, \
        "默认必须是「立刻替换」，实得 %r" % (RECONCILE_SECS_DEFAULT,)
    assert fast_delete_pace(46, RECONCILE_SECS_DEFAULT) == 0.0, \
        "默认预算下快通道必须一口气投完（不铺时长）"

    # 15b) 端到端不变量：把「流式续发 + 最终对账」跑在一块虚拟屏幕上，
    #      跑完屏幕内容必须恰好等于最终结果，退格数必须恰好等于已注入字数
    #      （多退一格会吃掉用户原有文字，少退会留下错位垃圾）。
    def _run_stream(partials, final, expect, tag):
        emitted, screen, backspaces = "", "", 0
        prev = None
        for cur in partials:
            delta, mode = stream_round(prev, cur, emitted)
            prev = cur
            if delta is None or len(delta) < STREAM_MIN_DELTA:
                continue
            emitted += delta
            screen += delta
        mode, payload = reconcile_plan(final, emitted)
        if mode == "rewrite":
            backspaces = len(emitted)
            screen = screen[:-backspaces] if backspaces else screen
            screen += final
        elif mode == "trim":
            # trim：只抹掉「真正变了」的那截尾巴，再补新尾巴
            backspaces, insert = payload
            screen = screen[:-backspaces] if backspaces else screen
            screen += insert
        elif mode != "keep_all":         # keep_all：刻意保留流式文字，不补不发
            screen += payload
        assert screen == expect, \
            "%s: screen=%r != expect=%r" % (tag, screen, expect)
        assert 0 <= backspaces <= len(emitted), \
            "%s: backspaces=%d out of range (emitted=%d)" % (
                tag, backspaces, len(emitted))
        return backspaces, mode

    # 模型把「真好」改成「真的好啊」，尾巴继续上屏，松手退格重发 —— 屏幕归位
    # （第 2 条重复 partial 是必要的：首轮只播种不下发，得先有两轮一致的前缀
    #   真正落屏，改写才会命中「已上屏部分被改写」的分支）
    b1, _ = _run_stream(["今天天气真好", "今天天气真好", "今天天气真的好啊",
                         "今天天气真的好啊我们去散步"],
                        "今天天气真的好啊我们去散步吧",
                        "今天天气真的好啊我们去散步吧", "forward+rewrite")
    assert b1 > 0, "forward recovery 场景最终必须走退格重发"
    # 一路稳定追加：零退格
    b2, m2 = _run_stream(["今天天气", "今天天气真好", "今天天气真好 我们去吧"],
                         "今天天气真好 我们去吧", "今天天气真好 我们去吧",
                         "stable-prefix")
    assert b2 == 0 and m2 == "keep", "稳定前缀场景应是零退格 keep"
    # 最终为空但流式已有字：保留已上屏、一个字都不删
    # （只有两条 partial 时，第二轮能确认的稳定前缀就是「今天天气」——
    #   「真好」要等第三轮一致才够格上屏，这正是双轮稳定的作用）
    b3, m3 = _run_stream(["今天天气", "今天天气真好"], "",
                         "今天天气", "keep-streamed")
    assert b3 == 0 and m3 == "keep_all", "最终为空时必须保留流式文字且零退格"

    # 15c) 焦点护栏：退格前必须确认前台窗口没变（退格不可撤销，删错窗口
    #      的用户内容是最严重的事故）；没记到目标窗口时无从比对，放行
    Stub = type("Stub", (), {})
    st = Stub()
    st.target_hwnd = 0
    assert Overlay._focus_ok(st) is True, "没记到目标窗口应放行"
    fg = get_foreground_hwnd() or 0
    st.target_hwnd = fg
    assert Overlay._focus_ok(st) == (get_foreground_hwnd() == fg)
    st.target_hwnd = fg ^ 1
    assert Overlay._focus_ok(st) == (get_foreground_hwnd() == (fg ^ 1))

    # 14) DPI 感知与缩放：设置成功时缩放必须反映真实系统 DPI，失败则 1.0
    mode = enable_dpi_awareness()
    k = (system_dpi() / 96.0) if mode else 1.0
    assert 1.0 <= k <= 4.0, "dpi scale out of range: %r" % k
    cv = ScaledCanvas.__new__(ScaledCanvas)
    ScaledCanvas.__init__(cv, None, k)
    assert cv._xy((2, 4)) == [2 * k, 4 * k]
    assert cv._kw({"width": 2, "fill": "#fff"})["width"] == 2 * k
    out("dpi selftest: mode=%s scale=%.2f" % (mode or "unaware", k))

    # 12) VK_PACKET 必须在第三键黑名单里（流式注入会置位它）
    assert 0xE7 in SCAN_SKIP, "VK_PACKET must be skipped in third-key scan"

    # 13) 标点转空格（数字里的小数点/千分位例外）
    assert punct_to_space("今天天气真好，我们去吧！") == "今天天气真好 我们去吧"
    assert punct_to_space("圆周率是3.14159") == "圆周率是3.14159"
    assert punct_to_space("价格是1,000元。") == "价格是1,000元"
    assert punct_to_space("") == ""
    assert punct_to_space("没标点") == "没标点"
    # 幂等：结果里已无标点，再跑一遍必须不变（流式 partial 反复过同一函数）
    s1 = punct_to_space("他说：“走吧。”真的？嗯！")
    assert s1 == punct_to_space(s1), "punct_to_space must be idempotent"

    # 16) 快捷键配置：解析 / 校验 / 显示
    assert parse_hotkey("ctrl+win") == (["ctrl", "win"], ""), parse_hotkey("ctrl+win")
    toks, err = parse_hotkey("Ctrl+Alt+Space")
    assert not err and toks == ["ctrl", "alt", "space"], (toks, err)
    toks, err = parse_hotkey("Space+Ctrl")          # 顺序要规范化（修饰键在前）
    assert not err and toks == ["ctrl", "space"], (toks, err)
    assert parse_hotkey(""), "空快捷键必须报错"
    assert parse_hotkey("shift+a")[1], "只有 Shift 会撞正常打字，必须拒绝"
    assert parse_hotkey("win")[1], "单独 Win 会弹开始菜单，必须拒绝"
    assert parse_hotkey("ctrl+nope")[1], "未知按键必须报错"
    assert parse_hotkey("ctrl+a+a")[1], "重复按键必须报错"
    assert parse_hotkey("ctrl+" + "+".join("f%d" % i for i in range(5)))[1], \
        "超过 4 键必须报错"
    assert parse_hotkey("f8")[1], "没有任何修饰键必须拒绝（会和正常打字冲突）"
    assert format_hotkey(["ctrl", "win"]) == "Ctrl + Win", format_hotkey(["ctrl", "win"])
    assert format_hotkey(["alt", "space"]) == "Alt + Space"
    assert format_hotkey(["alt", "f9"]) == "Alt + F9", format_hotkey(["alt", "f9"])
    assert format_hotkey(["ctrl", "a"]) == "Ctrl + A", format_hotkey(["ctrl", "a"])
    assert token_to_vk("space") == 0x20 and vk_to_token(0x20) == "space"
    assert token_to_vk("vk:0x74") == 0x74 and vk_to_token(0x74) == "f5"
    assert token_to_vk("nope") is None

    # 16b) 配置文件往返：正常 / 非法值退回默认 / pid 字段不被当成 hotkey
    tmp_cfg = os.path.join(APP_DIR, "_tmp-hotkey-selftest.txt")
    try:
        with open(tmp_cfg, "w", encoding="utf-8") as f:
            f.write("# x\npunct_to_space=true\nhotkey=ctrl+alt+space\n")
        assert read_hotkey(tmp_cfg) == ["ctrl", "alt", "space"], read_hotkey(tmp_cfg)
        with open(tmp_cfg, "w", encoding="utf-8") as f:
            f.write("hotkey=shift+a\n")             # 非法 -> 默认
        assert read_hotkey(tmp_cfg) == list(HOTKEY_DEFAULT), read_hotkey(tmp_cfg)
        with open(tmp_cfg, "w", encoding="utf-8") as f:
            f.write("hotkey_recorder_pid=1234\n")   # 不是 hotkey 字段
        assert read_hotkey(tmp_cfg) == list(HOTKEY_DEFAULT), read_hotkey(tmp_cfg)
        assert read_hotkey(os.path.join(APP_DIR, "_no_such_file.txt")) == \
            list(HOTKEY_DEFAULT), "文件不存在要退回默认"
    finally:
        try:
            os.remove(tmp_cfg)
        except OSError:
            pass

    # 16c) 自定义快捷键的状态机：ctrl+space
    ev2 = []
    d2 = ChordDetector(lambda k: ev2.append(k), arm=0.12, keys=["ctrl", "space"])
    assert d2.keys == ("ctrl", "space"), d2.keys
    d2.on_key(VK_LCONTROL, True)
    time.sleep(0.20)
    assert ev2 == [], "只按一个键不该触发（要全部按住）"
    d2.on_key(0x20, True)
    time.sleep(0.25)
    assert ev2 == ["start"], ev2
    assert d2.needs_scan() is True and 0x20 in d2.scan_skip()
    d2.on_key(0x41, True)                       # 第三键 -> abort
    assert ev2[-1] == "abort", ev2
    d2.on_key(0x41, False); d2.on_key(0x20, False); d2.on_key(VK_LCONTROL, False)
    time.sleep(0.12)
    d2.on_key(VK_LCONTROL, True); d2.on_key(0x20, True)
    time.sleep(0.25)
    assert ev2 == ["start", "abort", "start"], ev2
    d2.on_key(0x20, False)                      # 松开一个 -> stop
    assert ev2[-1] == "stop", ev2
    d2.on_key(VK_LCONTROL, False)

    # 16d) 换键：正在说话时 set_keys 要先 stop 收尾；黑名单跟着换；写坏退回默认
    ev3 = []
    d3 = ChordDetector(lambda k: ev3.append(k), arm=0.12, keys=["ctrl", "win"])
    d3.on_key(VK_LCONTROL, True); d3.on_key(VK_LWIN, True)
    time.sleep(0.25)
    assert ev3 == ["start"], ev3
    d3.set_keys(["ctrl", "space"])
    assert ev3 == ["start", "stop"], ev3        # 换键时先收尾，别拖到 60s 超时
    assert d3.keys == ("ctrl", "space")
    assert 0x5B not in d3.scan_skip() and 0x20 in d3.scan_skip(), \
        "黑名单要按当前快捷键算（Win 不再是自己的键）"
    assert d3.poll_keys() == (VK_LCONTROL, VK_RCONTROL, 0x20), d3.poll_keys()
    d3.on_key(VK_LCONTROL, False)
    d3.set_keys(["nope"])                       # 写坏的配置 -> 退回默认
    assert d3.keys == HOTKEY_DEFAULT, d3.keys
    assert d3.groups == (CTRL_VKS, WIN_VKS), d3.groups

    # 16e) 录制暂停字段：hotkey= 不会匹配到 hotkey_recorder_pid=（否则配置会
    #      被 pid 值污染），录制探测只会返回布尔值
    assert re.match(r"\s*hotkey\s*=", "hotkey_recorder_pid=1") is None, \
        "pid 字段不能被当成 hotkey 读走"
    assert re.match(r"\s*hotkey\s*=", "hotkey=ctrl+win") is not None
    assert re.match(r"\s*hotkey_recorder_pid\s*=\s*(\d+)",
                    "hotkey_recorder_pid=1234").group(1) == "1234"
    assert isinstance(hotkey_recording_active(), bool)

    # 17) 焦点判定：识别出的文字该不该注入（规则表在 voice_overlay_focus.py，
    #     完整回归在 tmp/test-focus-target.py；这里跑几条**实机实测过**的代表场景，
    #     保证悬浮球真的接上了那份规则表）
    assert FOCUS_OK, "voice_overlay_focus 没导入成功，兜底复制功能会失效"
    cases = [
        # (顶层窗口类, 焦点控件类, 期望)
        ("Notepad", "RichEditD2DPT", FOCUS_EDIT),          # 记事本：能打字
        ("Chrome_WidgetWin_1", "Chrome_WidgetWin_1", FOCUS_EDIT),   # 浏览器/Electron
        ("OpusApp", "_WwG", FOCUS_EDIT),                   # Word 文档区
        ("#32770", "Button", FOCUS_NONEDIT),               # 对话框的「确定」
        ("CabinetWClass", "DirectUIHWND", FOCUS_NONEDIT),  # 资源管理器文件列表
        ("Shell_TrayWnd", "Edit", FOCUS_NONEDIT),          # 任务栏（带陈旧焦点）
        ("CASCADIA_HOSTING_WINDOW_CLASS", "Edit", FOCUS_NONEDIT),  # Windows 终端
        ("Progman", "Edit", FOCUS_NONEDIT),                # 桌面（带陈旧焦点）
        ("#32769", "Edit", FOCUS_NONEDIT),                 # GetDesktopWindow()
        ("TkTopLevel", "TkChild", FOCUS_UNKNOWN),          # Tk：Entry/按钮同名，判不了
        ("SomeCustomFrame", "SomeCustomFrame", FOCUS_UNKNOWN),     # 判不了 -> 注入
    ]
    for fg_cls, focus_cls, want in cases:
        got = judge_focus_target(fg_cls, focus_cls, 0x100)
        assert got == want, "焦点判定 %s/%s 应为 %s，实际 %s" % (
            fg_cls, focus_cls, want, got)
    assert judge_focus_target("Notepad", "Edit", 0) == FOCUS_UNKNOWN, \
        "拿不到焦点控件时不能凭空判成「不在输入框」"

    # 17b) UIA 的信号要能压过类名表（这才是修好「浏览器页面里没聚焦输入框」的关键）
    assert judge_focus_target("Chrome_WidgetWin_1", "Chrome_WidgetWin_1", 0x100,
                              True, FOCUS_NONEDIT) == FOCUS_NONEDIT, \
        "UIA 说焦点是只读 Document/死物时必须判 nonedit"
    assert judge_focus_target("SomeUnknownApp", "X", 0x100, True,
                              FOCUS_EDIT) == FOCUS_EDIT, \
        "UIA 说是可写 Document/Edit 时必须判 edit（记事本的编辑区就是 Document）"
    assert judge_focus_target("Progman", "Edit", 0x100, True,
                              FOCUS_EDIT) == FOCUS_NONEDIT, \
        "桌面永远优先判 nonedit，不能被 UIA 翻过来"

    # 17c) 复制策略：**所有非输入框都复制**（含 UIA 正常但判不准的情形）；
    #      但 UIA 整个挂掉时不敢一律复制，否则所有软件里打字都变成静默复制
    assert wants_copy(FOCUS_NONEDIT, False) is True
    assert wants_copy(FOCUS_UNKNOWN, True) is True
    assert wants_copy(FOCUS_UNKNOWN, False) is False
    assert wants_copy(FOCUS_EDIT, True) is False
    assert UIA_OK, "voice_overlay_uia 没导入成功，浏览器空白页面会照旧打空"
    assert _uia.decide(50030, False) == FOCUS_EDIT      # 记事本：可写 Document
    assert _uia.decide(50030, True) == FOCUS_NONEDIT    # 浏览器页面正文
    assert _uia.decide(50004, None) == FOCUS_EDIT       # 地址栏 / <input>

    # 17d) 球上文字的自适应：放得下就整段、放不下才截断（纯函数，假测量）
    def _meas(size, t):                       # 假字体：每个字符固定 size 宽
        return len(t) * size
    assert fit_text("已复制", 100, _meas) == (15, "已复制")
    assert fit_text("x" * 200, 100, _meas)[1].endswith("…")
    assert len(fit_text("x" * 200, 100, _meas)[1]) < 200
    assert fit_text("", 100, _meas) == (15, "")
    assert toast_ms(3) == TOAST_MS            # 「已复制」维持原来的 1.6s
    assert TOAST_MS < toast_ms(40) <= TOAST_MS_MAX
    assert toast_ms(10 ** 6) == TOAST_MS_MAX
    assert toast_ms(10 ** 6, TOAST_MS_OK_MAX) == TOAST_MS_OK_MAX
    assert toast_ms(3, TOAST_MS_OK_MAX) == TOAST_MS       # 短结果也不低于下限

    facts = focus_facts()
    out("focus selftest: fg=%s focus=%s state=%s"
        % (facts.get("fg_cls") or "?", facts.get("focus_cls") or "-",
           focus_target_state()[0]))

    out("selftest OK (%d chord events)" % len(ev))
    return 0


def probe_focus():
    """`--probe-focus`：打印当前前台窗口的焦点判定（排查「为什么这次没打字」）。"""
    try:
        sys.stdout.reconfigure(encoding="utf-8")     # 控制台是 GBK 时中文别乱码
    except Exception:
        pass
    state, f = focus_target_state()
    print("前台窗口类名 : %s" % (f.get("fg_cls") or "?"))
    print("焦点控件类名 : %s" % (f.get("focus_cls") or "-"))
    print("焦点控件句柄 : %s" % (f.get("focus") or 0))
    print("caret 句柄   : %s（只用于日志，不参与判定）" % (f.get("caret") or 0))
    print("UIA 判定     : %s%s" % (
        f.get("uia") or "off",
        "" if f.get("uia_ok") else "（UIA 没工作：%s）" % (f.get("uia_err") or "未启用")))
    if f.get("uia_ct"):
        print("UIA 焦点元素 : ControlType=%s(%s) class=%r name=%r"
              % (f["uia_ct"],
                 _uia.CT_NAMES.get(f["uia_ct"], "?") if _uia else "?",
                 f.get("uia_cls") or "", f.get("uia_name") or ""))
    print("判定         : %s" % state)
    print("本轮行为     : %s" % (
        "复制完整识别内容到剪贴板 + 悬浮球只显示「%s」" % TOAST_TEXT
        if f.get("copy") else
        "完整注入到焦点控件 + 悬浮球只显示绿色对勾"))
    return 0


def copy_text_probe(text):
    """`--copy-text`：写剪贴板并读回校验（验兜底复制的通路，不涉及录音）。"""
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    ok = set_clipboard_text(text)
    back = get_clipboard_text() if ok else None
    print("set_clipboard_text -> %s" % ok)
    print("读回            -> %r" % back)
    good = ok and back == text
    print("结论            -> %s" % ("OK（剪贴板通路正常）" if good else "FAILED"))
    return 0 if good else 1


def main():
    args = sys.argv[1:]
    if args and args[0] == "--selftest":
        return selftest()
    if args and args[0] == "--probe-focus":
        return probe_focus()
    if args and args[0] == "--copy-text":
        return copy_text_probe(args[1] if len(args) > 1 else "语音输入测试")

    simulate = bool(args and args[0] == "--simulate")
    opaque = bool(args and args[0] == "--debug-opaque")
    canvas = "--canvas" in args           # 强制 Tk 画布（做渲染对比用）
    # --toast 是「只弹一条提示」的短命进程，同样豁免单实例锁
    toast = None
    if "--toast" in args:
        i = args.index("--toast")
        toast = args[i + 1] if len(args) > i + 1 and not args[i + 1].startswith(
            "-") else TOAST_TEXT
    # simulate/opaque/toast 是 no_send 短命进程，豁免单实例锁，可与常驻实例并存测试
    if not simulate and not opaque and toast is None and not single_instance():
        out("another instance running, exit")
        return 0

    ov = Overlay(no_send=simulate or opaque or toast is not None, opaque=opaque,
                 force_canvas=canvas)
    # 打包成 exe 后，规则表是靠 PyInstaller 一起塞进单文件的；万一没塞进去，
    # FOCUS_OK 会是 False（功能静默退化成「永远注入」）。启动就写一行日志，
    # 免得以后对着 exe 排查半天。
    out("focus module: %s" % ("ok" if FOCUS_OK else
                              "MISSING -> 兜底复制不可用（打包漏了 voice_overlay_focus）"))
    out("uia module: %s" % ("ok" if UIA_OK else
                            "MISSING -> 浏览器空白页面仍会被判成输入框（打包漏了 voice_overlay_uia）"))
    stop_evt = threading.Event()
    det = ChordDetector(ov.on_chord, arm=ARM_DELAY, keys=read_hotkey())
    out("hotkey=%s" % format_hotkey(det.keys))
    # 启动即写一份设备清单给设置窗口；顺手清掉上次残留的刷新请求
    # （不清的话这次启动写一份、下一轮心跳又写一份，白做一次）。
    try:
        os.remove(MIC_LIST_REQUEST)
    except OSError:
        pass
    threading.Thread(target=write_mic_list, daemon=True).start()
    threading.Thread(target=poll_main, args=(det, stop_evt,
                                             make_hotkey_reloader(det)),
                     daemon=True).start()
    # 快捷键里含 Win 时，把 Win 键从微信输入法的低级键盘钩子手里抢回来
    # （否则它先吞掉 Ctrl+Win 去开自己的语音面板，本程序连键都看不到）。
    # 不含 Win 的快捷键不需要，WinKeyGate 自己会判断要不要装。
    gate = WinKeyGate(det, stop_evt).start()
    # 结果侧兜底：钩子链首的位置是抢来的、不是稳的，微信输入法偶尔仍会先拿到
    # Win 键并弹自己的语音面板。这里在本程序语音期间把它一露头就收掉。
    mute = WeTypeVoiceMute(stop_evt).start()

    if simulate:
        # 自动化测试：模拟长按「配置里的键」-> 松开，完整走一轮（不上屏）
        pressed = [g[0] for g in det.groups]   # 每组取一个 VK（修饰键取左侧）

        def kd_all():
            for vk in pressed:
                det.on_key(vk, True)

        def ku_all():
            for vk in reversed(pressed):
                det.on_key(vk, False)

        ov.root.after(400, kd_all)
        ov.root.after(5400, ku_all)
        ov.root.after(9500, ov.root.destroy)
    elif opaque:
        ov.root.after(300, ov.request_toggle)   # 只开录音态，保持显示
        ov.root.after(8000, ov.root.destroy)
    elif toast is not None:
        # 只弹一次提示：用来肉眼验收提示的样子（不录音、不碰剪贴板）。
        # 传多长的文字就撑多宽、停多久，和真机上那条路径完全一致。
        ov.root.after(300, lambda: ov._toast(toast))
        ov.root.after(300 + toast_ms(len(toast)) + 1000, ov.root.destroy)

    def on_destroy(event):
        if str(event.widget) == ".":
            stop_evt.set()

    ov.root.bind("<Destroy>", on_destroy)
    out("overlay started%s" % (" (simulate)" if simulate else
                               (" (toast)" if toast is not None else "")))
    ov.run()
    stop_evt.set()
    ov.view.destroy()                 # 释放分层窗口（DIB/DC 一并回收）
    return 0


if __name__ == "__main__":
    sys.exit(main())
