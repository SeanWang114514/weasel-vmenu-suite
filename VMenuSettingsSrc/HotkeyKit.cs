// HotkeyKit.cs —— 语音快捷键（按住说话）：解析 / 校验 / 显示 / 风险提示 / 键态读取
//
// 从并发会话的 vmenu-settings-gui.ps1（Get-*/Test-*/ConvertTo-* 系列 + HotkeyTest
// 自检）1:1 移植。规则必须与 voice-overlay.py 的 parse_hotkey 完全一致 ——
// 两边都认：修饰键（ctrl/alt/shift/win，左右合并）+ 最多 4 键 + 必含 ctrl/alt/win。

using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;

internal static class HotkeyKit
{
    public const string Default = "ctrl+win";   // HOTKEY_DEFAULT

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);

    [DllImport("kernel32.dll")]
    private static extern bool AttachConsole(int dwProcessId);

    // 轮询读键（和 voice-overlay 同一套思路：不装任何键盘钩子，对系统输入零风险）
    public static bool KeyDown(int vk)
    {
        return (GetAsyncKeyState(vk) & 0x8000) != 0;
    }

    // 修饰键：左右两侧合并成一组（按任意一侧都算），顺序即显示顺序
    private static readonly string[] ModOrder = { "ctrl", "alt", "shift", "win" };
    private static readonly int[][] ModVks = new int[][] {
        new int[] { 0xA2, 0xA3 },   // ctrl  L/R
        new int[] { 0xA4, 0xA5 },   // alt   L/R
        new int[] { 0xA0, 0xA1 },   // shift L/R
        new int[] { 0x5B, 0x5C }    // win   L/R
    };

    private static readonly Dictionary<string, int> KEY_VK = new Dictionary<string, int>();
    private static readonly Dictionary<int, string> VK_KEY = new Dictionary<int, string>();
    private static readonly Dictionary<string, string> KEY_DISPLAY = new Dictionary<string, string>();

    static HotkeyKit()
    {
        AddKeyMap(0x08, "backspace");
        AddKeyMap(0x09, "tab");
        AddKeyMap(0x0D, "enter");
        AddKeyMap(0x1B, "esc");
        AddKeyMap(0x20, "space");
        AddKeyMap(0x21, "pageup");
        AddKeyMap(0x22, "pagedown");
        AddKeyMap(0x23, "end");
        AddKeyMap(0x24, "home");
        AddKeyMap(0x25, "left");
        AddKeyMap(0x26, "up");
        AddKeyMap(0x27, "right");
        AddKeyMap(0x28, "down");
        AddKeyMap(0x2C, "printscreen");
        AddKeyMap(0x2D, "insert");
        AddKeyMap(0x2E, "delete");
        for (int i = 0; i < 10; i++) AddKeyMap(0x30 + i, i.ToString());
        for (int i = 0; i < 26; i++) AddKeyMap(0x41 + i, ((char)('a' + i)).ToString());
        for (int i = 1; i <= 24; i++) AddKeyMap(0x6F + i, "f" + i);   // 0x70 = F1
        AddKeyMap(0xBA, "semicolon");
        AddKeyMap(0xBB, "equals");
        AddKeyMap(0xBC, "comma");
        AddKeyMap(0xBD, "minus");
        AddKeyMap(0xBE, "period");
        AddKeyMap(0xBF, "slash");
        AddKeyMap(0xC0, "backquote");
        AddKeyMap(0xDB, "lbracket");
        AddKeyMap(0xDC, "backslash");
        AddKeyMap(0xDD, "rbracket");
        AddKeyMap(0xDE, "quote");
        // 校验时要认识修饰键（用各自左键的 vk 占位）
        for (int i = 0; i < ModOrder.Length; i++) KEY_VK[ModOrder[i]] = ModVks[i][0];

        KEY_DISPLAY["ctrl"] = "Ctrl";
        KEY_DISPLAY["alt"] = "Alt";
        KEY_DISPLAY["shift"] = "Shift";
        KEY_DISPLAY["win"] = "Win";
        KEY_DISPLAY["space"] = "空格";
        KEY_DISPLAY["enter"] = "回车";
        KEY_DISPLAY["esc"] = "Esc";
        KEY_DISPLAY["tab"] = "Tab";
        KEY_DISPLAY["backspace"] = "退格";
        KEY_DISPLAY["delete"] = "Del";
        KEY_DISPLAY["insert"] = "Ins";
        KEY_DISPLAY["home"] = "Home";
        KEY_DISPLAY["end"] = "End";
        KEY_DISPLAY["pageup"] = "PgUp";
        KEY_DISPLAY["pagedown"] = "PgDn";
        KEY_DISPLAY["left"] = "←";
        KEY_DISPLAY["up"] = "↑";
        KEY_DISPLAY["right"] = "→";
        KEY_DISPLAY["down"] = "↓";
        KEY_DISPLAY["printscreen"] = "PrtSc";
        KEY_DISPLAY["semicolon"] = ";";
        KEY_DISPLAY["equals"] = "=";
        KEY_DISPLAY["comma"] = ",";
        KEY_DISPLAY["minus"] = "-";
        KEY_DISPLAY["period"] = ".";
        KEY_DISPLAY["slash"] = "/";
        KEY_DISPLAY["backquote"] = "`";
        KEY_DISPLAY["lbracket"] = "[";
        KEY_DISPLAY["backslash"] = "\\";
        KEY_DISPLAY["rbracket"] = "]";
        KEY_DISPLAY["quote"] = "'";
    }

    private static void AddKeyMap(int vk, string token)
    {
        KEY_VK[token] = vk;
        VK_KEY[vk] = token;
    }

    // 当前按下的键。跳过通用修饰码（0x10/0x11/0x12，左右键会重复计一次）
    // 和 VK_PACKET（0xE7，注入字符时系统会短暂置位）。1..7 是鼠标，不参与。
    public static List<int> DownVks()
    {
        List<int> got = new List<int>();
        for (int vk = 8; vk < 256; vk++)
        {
            if (vk == 0x10 || vk == 0x11 || vk == 0x12 || vk == 0xE7) continue;
            if (KeyDown(vk)) got.Add(vk);
        }
        return got;
    }

    private static bool IsModVk(int vk)
    {
        for (int i = 0; i < ModVks.Length; i++)
            if (ModVks[i][0] == vk || ModVks[i][1] == vk) return true;
        return false;
    }

    // vk 集合 -> token 列表（修饰键在前，其余按 vk 升序）—— 与 voice-overlay 一致
    public static List<string> ToTokens(List<int> vks)
    {
        List<string> tokens = new List<string>();
        for (int i = 0; i < ModOrder.Length; i++)
        {
            foreach (int vk in vks)
            {
                if (vk == ModVks[i][0] || vk == ModVks[i][1]) { tokens.Add(ModOrder[i]); break; }
            }
        }
        List<int> rest = new List<int>();
        foreach (int vk in vks) { if (!IsModVk(vk)) rest.Add(vk); }
        rest.Sort();
        foreach (int vk in rest)
        {
            string t;
            if (VK_KEY.TryGetValue(vk, out t)) tokens.Add(t);
            else tokens.Add("vk:0x" + vk.ToString("X2"));   // 没名字的键也能存（悬浮球认）
        }
        return tokens;
    }

    // 合法返回 null，否则返回中文错误提示（规则与 voice-overlay.parse_hotkey 一致）
    public static string Test(List<string> tokens)
    {
        if (tokens == null || tokens.Count == 0) return "快捷键是空的";
        if (tokens.Count > 4) return "最多 4 个键";
        if (new HashSet<string>(tokens).Count != tokens.Count) return "按键重复";
        foreach (string t in tokens)
            if (!KEY_VK.ContainsKey(t)) return "不认识这个按键：" + t;
        bool safe = tokens.Contains("ctrl") || tokens.Contains("alt") || tokens.Contains("win");
        if (!safe) return "至少要包含 Ctrl / Alt / Win 之一（只有 Shift 会和正常打字冲突）";
        if (tokens.Count == 1 && tokens[0] == "win") return "单独按 Win 会弹出开始菜单，换一个组合";
        return null;
    }

    public static string Display(List<string> tokens)
    {
        List<string> parts = new List<string>();
        foreach (string t in tokens)
        {
            string d;
            if (KEY_DISPLAY.TryGetValue(t, out d)) parts.Add(d);
            else if (t.Length == 1) parts.Add(t.ToUpper());                 // a -> A
            else if (Regex.IsMatch(t, "^f\\d{1,2}$")) parts.Add(t.ToUpper()); // f9 -> F9
            else parts.Add(t);
        }
        return string.Join(" + ", parts.ToArray());
    }

    // 提醒但不拦截：按住期间目标软件同样会收到这些按键（可能真执行复制/粘贴）
    public static string Risk(List<string> tokens)
    {
        bool hasMod = tokens.Contains("ctrl") || tokens.Contains("alt");
        if (!hasMod) return null;
        List<string> keys = new List<string>();
        foreach (string t in tokens)
            if (Array.IndexOf(ModOrder, t) < 0) keys.Add(t);
        if (tokens.Contains("ctrl") && keys.Contains("space"))
            return "Ctrl+空格 会和小狼毫的中英切换冲突，建议换一个组合";
        foreach (string k in keys)
        {
            if (Regex.IsMatch(k, "^[a-z0-9]$"))
                return "按住期间目标软件也会收到这些按键，可能触发它自己的快捷键（复制/粘贴等）；更稳妥可选 F1~F12";
        }
        return null;
    }

    public static List<string> Split(string config)
    {
        List<string> outp = new List<string>();
        if (config == null) return outp;
        foreach (string p in config.Split('+')) if (p.Length > 0) outp.Add(p);
        return outp;
    }

    // 'ctrl+win' -> token 列表（非法 -> 默认）
    public static List<string> FromConfig(string config)
    {
        List<string> toks = Split(config);
        if (Test(toks) != null) return Split(Default);
        return toks;
    }

    // ---- 自检（VMenuSettings.exe --hotkeytest，对应 PS 的 -HotkeyTest）----
    private static List<string> T(params string[] items)
    {
        return new List<string>(items);
    }

    public static List<string> SelfTest()
    {
        List<string> fails = new List<string>();
        Action<bool, string> ok = delegate(bool cond, string msg)
        {
            if (!cond) fails.Add(msg);
        };

        ok(Test(T("ctrl", "win")) == null, "ctrl+win 应合法");
        ok(Test(T("ctrl", "alt", "space")) == null, "ctrl+alt+space 应合法");
        ok(Test(new List<string>()) != null, "空快捷键必须拒绝");
        ok(Test(T("shift", "a")) != null, "只有 Shift 必须拒绝（会撞正常打字）");
        ok(Test(T("win")) != null, "单独 Win 必须拒绝（弹开始菜单）");
        ok(Test(T("ctrl", "nope")) != null, "未知按键必须拒绝");
        ok(Test(T("ctrl", "a", "a")) != null, "重复按键必须拒绝");
        ok(Test(T("ctrl", "f1", "f2", "f3", "f4", "f5")) != null, "超过 4 键必须拒绝");

        // 显示断言区分大小写（f9 必须渲染成 F9）
        ok(Display(T("ctrl", "win")) == "Ctrl + Win", "显示 Ctrl + Win");
        ok(Display(T("alt", "space")) == "Alt + 空格", "显示 Alt + 空格");
        ok(Display(T("f9")) == "F9", "显示 F9（不能是 f9）");
        ok(Display(T("ctrl", "alt", "f9")) == "Ctrl + Alt + F9", "显示 Ctrl + Alt + F9");

        ok(string.Join(",", FromConfig("ctrl+alt+space").ToArray()) == "ctrl,alt,space",
            "配置串读取 ctrl+alt+space");
        ok(string.Join(",", FromConfig("shift+a").ToArray()) == "ctrl,win",
            "非法配置要退回默认");

        ok(string.Join(",", ToTokens(new List<int>(new int[] { 0xA2, 0x20 })).ToArray())
            == "ctrl,space", "vk 集合 -> ctrl+space");
        ok(string.Join(",", ToTokens(new List<int>(new int[] { 0xA3, 0x41 })).ToArray())
            == "ctrl,a", "右侧 Ctrl 也算 ctrl");
        ok(string.Join(",", ToTokens(new List<int>(new int[] { 0xA0, 0x74 })).ToArray())
            == "shift,f5", "vk 集合 -> shift+f5");
        ok(string.Join(",", FromConfig(
            string.Join("+", ToTokens(new List<int>(new int[] { 0xA2, 0x5B })).ToArray()))
            .ToArray()) == "ctrl,win", "往返 ctrl+win");

        ok(Risk(T("ctrl", "c")) != null, "Ctrl+C 要给风险提醒");
        ok(Risk(T("ctrl", "f9")) == null, "Ctrl+F9 不需要提醒");

        return fails;
    }

    public static int RunSelfTest()
    {
        bool attached = AttachConsole(-1);   // ATTACH_PARENT_PROCESS
        try { Console.OutputEncoding = Encoding.UTF8; } catch { }
        List<string> fails = SelfTest();
        foreach (string f in fails) Console.WriteLine("FAIL: " + f);
        if (fails.Count == 0)
        {
            Console.WriteLine("hotkey selftest OK");
            return 0;
        }
        if (!attached)
        {
            // 从资源管理器双击跑的：没有控制台可写，弹个框别让人以为没反应
            MessageBox.Show("快捷键自检失败：\n\n" + string.Join("\n", fails.ToArray()),
                "VMenuSettings");
        }
        return 1;
    }
}
