# -*- coding: utf-8 -*-
"""音质无关的「标点转空格」回归测试：用 voice-overlay.py 自己的代码路径跑一个 wav。

为什么需要它：`--selftest` 只断言 punct_to_space 这个纯函数，
而这个脚本跑的是**真正的识别链路**（asr_recognize 里的变换点）+ **真正的流式状态机**
（stream_step），用来防止「变换只加在最终结果、忘了流式增量」这类只在实机上才暴露的
不一致（那会让边说边打的字在松开瞬间被退格重排）。

用法：
    python voice-punct-test.py                      # 默认用 shots\\tts-punct.wav，两态各跑一次
    python voice-punct-test.py <wav> --stream       # 按真实流式节奏走一遍，检查是否需要退格

控制台是 GBK 时会显示乱码，加 `$env:PYTHONIOENCODING='utf-8'` 即可。
需要本地 asr server 已在 127.0.0.1:3966 上跑（voice-overlay.py 会自动拉起）。
"""
import importlib.util
import os
import sys
import wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
OV = os.path.join(HERE, "voice-overlay.py")
SET = None                              # main() 里从 voice-overlay 模块解析（Rime 用户目录）
DEFAULT_WAV = os.path.join(HERE, "shots", "tts-punct.wav")


def load_module():
    spec = importlib.util.spec_from_file_location("vo", OV)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def frames_16k(path, rate=16000):
    """任意采样率 16-bit PCM wav -> 16k 单声道 int16 块列表。"""
    with wave.open(path, "rb") as w:
        assert w.getsampwidth() == 2, "只支持 16-bit PCM wav"
        ch, sr = w.getnchannels(), w.getframerate()
        raw = w.readframes(w.getnframes())
    x = np.frombuffer(raw, dtype="<i2").astype(np.float32)
    if ch > 1:
        x = x.reshape(-1, ch).mean(axis=1)
    if sr != rate:
        n = int(round(len(x) * rate / sr))
        x = np.interp(np.linspace(0, len(x) - 1, n),
                      np.arange(len(x)), x).astype(np.float32)
    b = x.astype("<i2").tobytes()
    step = 8000 * 2          # 0.5s 一块，贴近真实录音分块
    return [b[i:i + step] for i in range(0, len(b), step)]


def set_switch(on):
    with open(SET, "w", encoding="utf-8") as f:
        f.write("# 语音输入设置（voice-overlay.py 读取）\npunct_to_space=%s\n"
                % ("true" if on else "false"))


def test_both_states(m, wav):
    fr = frames_16k(wav)
    for on in (True, False):
        set_switch(on)
        assert m.punct_space_enabled() is on, "开关读回不一致"
        print("switch=%-5s -> %r" % (on, m.asr_recognize(fr)))
    set_switch(True)


def test_stream(m, wav):
    """复刻 _stream_loop + stream_recover + _reconcile，喂真实模型输出。

    用一块**虚拟屏幕**（screen）记下真实会留在输入框里的内容：
      流式增量 -> screen += delta（SendInput 注入）
      最终对账 -> 前缀一致只补尾巴；否则退格 len(emitted) 再重发 final
    不变量：跑完之后 screen 必须**恰好等于**最终识别结果，
    且退格数必须**恰好等于**已注入字数（多退一格就会吃掉用户原有文字，
    少退则留下流式的错位垃圾）。
    """
    set_switch(True)
    fr = frames_16k(wav)
    total_s = len(fr) * 0.5
    print("audio %.1fs, %d chunks" % (total_s, len(fr)))

    prev, emitted, screen = None, "", ""
    backspaces = 0
    t, last = 0.0, 0.0
    while t < total_s:
        t += 0.5
        n = int(t / 0.5)
        # 与 _stream_loop 完全一致的节奏判定（含长音频降频与 1s 封顶）
        if t < m.STREAM_MIN_AUDIO:
            continue
        interval = min(m.STREAM_INTERVAL_MAX,
                       max(m.STREAM_INTERVAL, t * m.STREAM_TAIL_RATIO))
        if (t - last) < interval:
            continue
        last = t
        cur = m.asr_recognize(fr[:n])
        if not cur:
            continue
        delta, mode = m.stream_round(prev, cur, emitted)
        prev = cur
        if delta is None:
            print("  t=%4.1fs  REVISE deferred  emitted=%r cur=%r"
                  % (t, emitted, cur))
            continue
        note = "  (改写->前向续发)" if mode == "forward" else ""
        if len(delta) < m.STREAM_MIN_DELTA:
            continue
        emitted += delta
        screen += delta
        print("  t=%4.1fs  delta=%r  emitted=%r%s" % (t, delta, emitted, note))

    final = m.asr_recognize(fr) or ""
    print("最终: %r" % final)
    mode, tail = m.reconcile_plan(final, emitted)
    if mode == "none":
        screen += tail
        print("对账: 没流式过 -> 整段发送")
        print("RESULT: 上屏最终 = %r" % screen)
        print("needs_backspace = False  invariant_ok = %s" % (screen == final))
    elif mode == "keep_all":
        # 最终为空但流式已有字 -> 保留已上屏（宁可留字不瞎删）
        print("对账: 最终为空 -> 保留流式文字 %r" % screen)
        print("RESULT: 上屏最终 = %r" % screen)
        print("needs_backspace = False  invariant_ok = %s" % (screen == emitted))
        return screen == emitted
    elif mode == "keep":
        screen += tail
        print("对账: 前缀一致 -> 只补尾巴 %r（零退格）" % tail)
        print("RESULT: 上屏最终 = %r" % screen)
        print("needs_backspace = False  invariant_ok = %s" % (screen == final))
    else:
        backspaces = len(emitted)
        screen = screen[:len(screen) - backspaces] if backspaces else screen
        screen += final
        print("对账: 退格 %d 个字再重发最终版" % backspaces)
        print("RESULT: 上屏最终 = %r" % screen)
        print("needs_backspace = True  invariant_ok = %s" % (screen == final))
    return screen == final


def main():
    args = list(sys.argv[1:])
    stream = "--stream" in args
    args = [a for a in args if a != "--stream"]
    wav = args[0] if args else DEFAULT_WAV
    if not os.path.exists(wav):
        print("找不到 wav：%s" % wav)
        return 2
    m = load_module()
    global SET
    SET = m.VOICE_SET_PATH
    print("settings file exists:", os.path.exists(SET))
    ok = True
    if stream:
        ok = test_stream(m, wav)
    else:
        test_both_states(m, wav)
    print("switch restored:",
          open(SET, encoding="utf-8").read().strip().splitlines()[-1])
    if not ok:
        print("FAIL: 流式 + 对账后屏幕内容 != 最终识别结果")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
