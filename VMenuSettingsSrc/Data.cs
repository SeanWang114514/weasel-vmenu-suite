// Data.cs —— 全部文件读写 + 设置状态 + 输入法配置写入
//
// 与原 PowerShell 版（vmenu-settings-gui.ps1）逐字段对应；所有写出文件都是
// UTF-8 无 BOM（带 BOM 会让剪贴板首条内容多出不可见字符）。
// 两个「按键类」设置（右/左Shift、CapsLock、英文候选）见文末：
//   按键  → default.custom.yaml + build\default.yaml + 重启 WeaselServer
//   英文候选 → candidate-settings.txt（lua/en_gate.lua 每秒至多读一次）

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using Microsoft.Win32;

internal class FavEntry
{
    public string Word;
    public string Key;
}

internal class DictEntry
{
    public string Word;
    public string Pinyin;
    public long Weight;
}

internal static class Data
{
    // ---- 目录与路径 ----
    public static string RimeDir = @"D:\rime-sandbox";
    public static string ClipPath;
    public static string FavPath;
    public static string MydictPath;
    public static string CharmapPath;
    public static string SetPath;
    public static string FlagPath;
    public static string VoiceSetPath;
    public static string FuzzySetPath;
    public static string CandSetPath;
    public static string SmartPunctSetPath;
    public static string DefaultCustomPath;
    public static string BuildDefaultPath;

    public const int MaxClip = 50;
    public const int MinPage = 20;
    public const int MaxPage = 50;
    public const int Step = 10;
    public const int MiDefault = 30;
    public const int MiMin = 10;
    public const int MiMax = 200;
    public const long DefaultWeight = 100000;

    private static readonly Encoding U8 = new UTF8Encoding(false);

    // ---- 设置状态 ----
    public static int PageSize = MinPage;
    public static bool MiEnabled = true;
    public static int MiInterval = MiDefault;
    public static bool PunctSpace = true;
    public static bool FzMaster = true;
    public static bool FzAnAng = true;
    public static bool FzEnEng = true;
    public static bool FzInIng = true;
    public static bool FzIanIang = true;
    public static bool FzUanUang = true;
    public static bool EnCandidates = true;
    public static bool SmartPunct = true;      // 网址/路径智能标点（smart_punct.lua）
    public static bool ShiftL = true;
    public static bool ShiftR = true;
    public static string CapsBehavior = "clear";   // clear | commit_code | noop

    public static void Init(string rimeDir)
    {
        RimeDir = rimeDir;
        ClipPath = Path.Combine(RimeDir, "clipboard-cache.txt");
        FavPath = Path.Combine(RimeDir, "cn_dicts", "favorites.dict.yaml");
        MydictPath = Path.Combine(RimeDir, "cn_dicts", "mydict.dict.yaml");
        CharmapPath = Path.Combine(RimeDir, "cn_dicts", "8105.dict.yaml");
        SetPath = Path.Combine(RimeDir, "vmenu-settings.txt");
        FlagPath = Path.Combine(RimeDir, "open-settings.flag");
        VoiceSetPath = Path.Combine(RimeDir, "voice-settings.txt");
        FuzzySetPath = Path.Combine(RimeDir, "fuzzy-settings.txt");
        CandSetPath = Path.Combine(RimeDir, "candidate-settings.txt");
        SmartPunctSetPath = Path.Combine(RimeDir, "smart-punct-settings.txt");
        DefaultCustomPath = Path.Combine(RimeDir, "default.custom.yaml");
        BuildDefaultPath = Path.Combine(RimeDir, "build", "default.yaml");
    }

    // 目录解析顺序：调用方传入的目录 -> 环境变量 RIME_DIR -> 注册表登记的
    // RimeUserDir -> %APPDATA%\Rime -> 旧开发目录（都不可用时原样返回）。
    public static string ResolveRimeDir(string requested)
    {
        try
        {
            if (!string.IsNullOrEmpty(requested) && Directory.Exists(requested)) return requested;
            string env = Environment.GetEnvironmentVariable("RIME_DIR");
            if (!string.IsNullOrEmpty(env) && Directory.Exists(env)) return env;
            using (RegistryKey k = Registry.CurrentUser.OpenSubKey(@"Software\Rime\Weasel"))
            {
                if (k != null)
                {
                    object v = k.GetValue("RimeUserDir");
                    if (v != null)
                    {
                        string s = v.ToString();
                        if (s.Length > 0 && Directory.Exists(s)) return s;
                    }
                }
            }
            string appdata = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Rime");
            if (Directory.Exists(appdata)) return appdata;
            if (Directory.Exists(@"D:\rime-sandbox")) return @"D:\rime-sandbox";
        }
        catch { }
        return requested;
    }

    // ---- 基础读写 ----
    public static string[] ReadAllLines(string path)
    {
        try
        {
            if (!File.Exists(path)) return new string[0];
            return File.ReadAllLines(path, Encoding.UTF8);
        }
        catch { return new string[0]; }
    }

    public static string ReadText(string path)
    {
        try
        {
            if (!File.Exists(path)) return null;
            return File.ReadAllText(path, Encoding.UTF8);
        }
        catch { return null; }
    }

    // 写出：临时文件 + 原子替换（与 PS 的 tmp + Move-Item -Force 等价）
    public static void WriteTextFile(string path, string text)
    {
        try
        {
            string dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir))
                Directory.CreateDirectory(dir);
            string tmp = path + ".tmp";
            File.WriteAllText(tmp, text, U8);
            if (File.Exists(path))
            {
                try { File.Replace(tmp, path, null); }
                catch { File.Delete(path); File.Move(tmp, path); }
            }
            else
            {
                File.Move(tmp, path);
            }
        }
        catch { }
    }

    private static bool FlagOn(string v)
    {
        return v != null && Regex.IsMatch(v, "^(1|true|on|yes)$");
    }

    // ---- vmenu-settings.txt（剪贴板页数 + 防误触）----
    public static void LoadSettings()
    {
        PageSize = MinPage;
        MiEnabled = true;
        MiInterval = MiDefault;
        foreach (string line in ReadAllLines(SetPath))
        {
            Match m = Regex.Match(line, @"^\s*clip_page\s*=\s*(\d+)");
            if (m.Success)
            {
                int n;
                if (int.TryParse(m.Groups[1].Value, out n) && n >= MinPage && n <= MaxPage)
                    PageSize = n;
            }
            m = Regex.Match(line, @"^\s*misinput_interval\s*=\s*(\d+)");
            if (m.Success)
            {
                int n;
                if (int.TryParse(m.Groups[1].Value, out n) && n >= MiMin && n <= MiMax)
                    MiInterval = n;
            }
            m = Regex.Match(line, @"^\s*misinput_protect\s*=\s*(\w+)");
            if (m.Success) MiEnabled = (m.Groups[1].Value == "true");
        }
    }

    public static void SaveAllSettings()
    {
        string miOn = MiEnabled ? "true" : "false";
        WriteTextFile(SetPath,
            "# v 功能菜单设置\n" +
            "clip_page=" + PageSize + "\n" +
            "misinput_protect=" + miOn + "\n" +
            "misinput_interval=" + MiInterval + "\n");
    }

    // ---- voice-settings.txt（语音输入）----
    // hotkey / hotkey_recorder_pid 是并发会话的「按住说话」快捷键协议：
    // 录制期间写 hotkey_recorder_pid=<本进程 pid>，悬浮球查到进程活着就暂停检测。
    public static string Hotkey = HotkeyKit.Default;
    public static int HotkeyRecPid;

    public static void LoadVoiceSettings()
    {
        PunctSpace = true;
        Hotkey = HotkeyKit.Default;
        foreach (string line in ReadAllLines(VoiceSetPath))
        {
            Match m = Regex.Match(line, @"^\s*punct_to_space\s*=\s*(\S+)");
            if (m.Success) PunctSpace = FlagOn(m.Groups[1].Value);
            m = Regex.Match(line, @"^\s*hotkey\s*=\s*(\S+)");
            if (m.Success)
            {
                // 只认合法值：文件被人手改坏就退回默认，别把坏值显示出来又传给悬浮球
                List<string> toks = HotkeyKit.Split(m.Groups[1].Value);
                if (HotkeyKit.Test(toks) == null) Hotkey = m.Groups[1].Value;
            }
        }
        HotkeyRecPid = 0;   // 启动时上一轮录制必然已经死了，pid 不认旧值
    }

    public static void SaveVoiceSettings()
    {
        string txt = "# 语音输入设置（voice-overlay.py 读取）\n" +
            "punct_to_space=" + (PunctSpace ? "true" : "false") + "\n" +
            "hotkey=" + Hotkey + "\n";
        if (HotkeyRecPid > 0)
        {
            // 录制中：让悬浮球暂停热键检测（它会查这个 pid 是否还活着）
            txt += "hotkey_recorder_pid=" + HotkeyRecPid + "\n";
        }
        WriteTextFile(VoiceSetPath, txt);
    }

    // ---- fuzzy-settings.txt（前后鼻音：总开关 + 5 对逐对开关）----
    private static bool FzVal(string text, string key, bool fallback)
    {
        Match m = Regex.Match(text, @"(?m)^\s*" + Regex.Escape(key) + @"\s*=\s*(\S+)");
        if (!m.Success) return fallback;
        return !Regex.IsMatch(m.Groups[1].Value, "^(0|false|off|no)$");
    }

    public static void LoadFuzzySettings()
    {
        string text = ReadText(FuzzySetPath);
        if (text == null) text = "";
        FzMaster = FzVal(text, "nasal", true);
        FzAnAng = FzVal(text, "nasal_an_ang", true);
        FzEnEng = FzVal(text, "nasal_en_eng", true);
        FzInIng = FzVal(text, "nasal_in_ing", true);
        FzIanIang = FzVal(text, "nasal_ian_iang", true);
        FzUanUang = FzVal(text, "nasal_uan_uang", true);
    }

    public static void SaveFuzzySettings()
    {
        StringBuilder sb = new StringBuilder();
        sb.Append("# 前后鼻音模糊输入（fuzzy_filter.lua 读取）\n");
        sb.Append("nasal=").Append(FzMaster ? "true" : "false").Append("\n");
        sb.Append("nasal_an_ang=").Append(FzAnAng ? "true" : "false").Append("\n");
        sb.Append("nasal_en_eng=").Append(FzEnEng ? "true" : "false").Append("\n");
        sb.Append("nasal_in_ing=").Append(FzInIng ? "true" : "false").Append("\n");
        sb.Append("nasal_ian_iang=").Append(FzIanIang ? "true" : "false").Append("\n");
        sb.Append("nasal_uan_uang=").Append(FzUanUang ? "true" : "false").Append("\n");
        WriteTextFile(FuzzySetPath, sb.ToString());
    }

    // ---- candidate-settings.txt（中文模式英文候选，en_gate.lua 读取）----
    public static void LoadCandSettings()
    {
        string text = ReadText(CandSetPath);
        if (text == null) { EnCandidates = true; return; }
        EnCandidates = FzVal(text, "en_candidates", true);
    }

    public static void SaveCandSettings()
    {
        WriteTextFile(CandSetPath,
            "# 中文模式下的英文候选（en_gate.lua 读取）\n" +
            "en_candidates=" + (EnCandidates ? "true" : "false") + "\n");
    }

    // ---- smart-punct-settings.txt（网址/路径智能标点，smart_punct.lua 读取）----
    public static void LoadSmartPunctSettings()
    {
        string text = ReadText(SmartPunctSetPath);
        if (text == null) { SmartPunct = true; return; }
        SmartPunct = FzVal(text, "smart_punct", true);
    }

    public static void SaveSmartPunctSettings()
    {
        // 保留文件里的其它键（smart_punct_log 调试开关等），只重写 smart_punct 行
        StringBuilder sb = new StringBuilder();
        sb.Append("# 网址/路径智能标点（smart_punct.lua 读取）\n");
        sb.Append("smart_punct=").Append(SmartPunct ? "true" : "false").Append("\n");
        string text = ReadText(SmartPunctSetPath);
        if (text != null)
        {
            foreach (string line in text.Split('\n'))
            {
                string t = line.Trim();
                if (t.StartsWith("smart_punct_log")) { sb.Append(t).Append("\n"); break; }
            }
        }
        WriteTextFile(SmartPunctSetPath, sb.ToString());
    }

    // ---- 剪贴板历史 ----
    public static string ClipStamp()
    {
        try
        {
            FileInfo fi = new FileInfo(ClipPath);
            if (!fi.Exists) return "missing";
            return fi.LastWriteTimeUtc.Ticks + ":" + fi.Length;
        }
        catch { return "missing"; }
    }

    public static List<string> LoadClipboard()
    {
        List<string> list = new List<string>();
        foreach (string line in ReadAllLines(ClipPath))
        {
            string t = line == null ? "" : line.Trim();
            if (t.Length > 0)
            {
                list.Add(t);
                if (list.Count >= MaxClip) break;
            }
        }
        return list;
    }

    public static void SaveClipboard(List<string> items)
    {
        StringBuilder sb = new StringBuilder();
        if (items.Count > 0)
        {
            for (int i = 0; i < items.Count; i++)
            {
                if (i > 0) sb.Append("\n");
                sb.Append(items[i]);
            }
            sb.Append("\n");
        }
        WriteTextFile(ClipPath, sb.ToString());
    }

    // ---- 常用语 ----
    private const string FavHeader =
        "# Rime dictionary\n# encoding: utf-8\n---\nname: favorites\n" +
        "version: \"2026-09-11\"\nsort: by_weight\n...\n";

    public static List<FavEntry> LoadFavorites()
    {
        List<FavEntry> list = new List<FavEntry>();
        bool body = false;
        foreach (string line in ReadAllLines(FavPath))
        {
            if (!body)
            {
                if (Regex.IsMatch(line, @"^\.\.\.")) body = true;
                continue;
            }
            string[] parts = Regex.Split(line, "\t");
            if (parts.Length >= 2)
            {
                string w = parts[0].Trim();
                string k = parts[1].Trim();
                if (w.Length > 0 && k.Length > 0)
                {
                    FavEntry e = new FavEntry();
                    e.Word = w;
                    e.Key = k;
                    list.Add(e);
                }
            }
        }
        return list;
    }

    public static void SaveFavorites(List<FavEntry> favs)
    {
        StringBuilder sb = new StringBuilder();
        sb.Append(FavHeader);
        foreach (FavEntry f in favs)
            sb.Append(f.Word).Append("\t").Append(f.Key).Append("\t100000\n");
        WriteTextFile(FavPath, sb.ToString());
    }

    // ---- 个人词库（mydict）----
    private static readonly string[] MyDictHeader = new string[]
    {
        "# Rime dictionary",
        "# encoding: utf-8",
        "#",
        "# 个人词库（自己加词用，不会被雾凇更新覆盖）",
        "# 格式：词语<Tab>拼音（空格分隔）<Tab>权重（可选，越大越靠前）",
        "# 示例：",
        "# 雾凇\twu song\t100000",
        "# 打工人\tda gong ren\t10000",
        "#",
        "---",
        "name: mydict",
        "version: \"2026-09-06\"",
        "sort: by_weight",
        "...",
        "",
        "# 下面开始写你的词，一行一个"
    };

    public static List<DictEntry> ReadMyDict()
    {
        List<DictEntry> entries = new List<DictEntry>();
        if (!File.Exists(MydictPath)) return entries;
        foreach (string line in File.ReadAllLines(MydictPath, Encoding.UTF8))
        {
            Match m = Regex.Match(line, @"^(.+?)\t([A-Za-züv' ]+?)(?:\t(\d+))?\s*$");
            if (!m.Success) continue;
            string w = m.Groups[1].Value;
            if (w.StartsWith("#") || w.StartsWith("-")) continue;
            long wt = DefaultWeight;
            if (m.Groups[3].Success) long.TryParse(m.Groups[3].Value, out wt);
            DictEntry e = new DictEntry();
            e.Word = w;
            e.Pinyin = m.Groups[2].Value.Trim();
            e.Weight = wt;
            entries.Add(e);
        }
        return entries;
    }

    public static void SaveMyDict(List<DictEntry> entries)
    {
        List<string> header = new List<string>();
        bool foundMarker = false;
        if (File.Exists(MydictPath))
        {
            foreach (string line in File.ReadAllLines(MydictPath, Encoding.UTF8))
            {
                if (!foundMarker)
                {
                    header.Add(line);
                    if (line == "# 下面开始写你的词，一行一个") foundMarker = true;
                }
            }
        }
        if (!foundMarker) header = new List<string>(MyDictHeader);

        // 稳定排序：权重降序、同权重保持原顺序（LINQ OrderBy 是稳定排序）
        List<DictEntry> sorted = new List<DictEntry>(entries);
        List<int> idx = new List<int>();
        for (int i = 0; i < entries.Count; i++) idx.Add(i);
        Dictionary<DictEntry, int> order = new Dictionary<DictEntry, int>();
        for (int i = 0; i < entries.Count; i++)
            if (!order.ContainsKey(entries[i])) order[entries[i]] = i;
        sorted.Sort(delegate(DictEntry a, DictEntry b)
        {
            if (a.Weight != b.Weight) return b.Weight.CompareTo(a.Weight);
            return order[a].CompareTo(order[b]);
        });

        List<string> lines = new List<string>(header);
        foreach (DictEntry e in sorted)
            lines.Add(e.Word + "\t" + e.Pinyin + "\t" + e.Weight);
        // 与 PS 的 WriteAllLines 一致：CRLF、UTF-8 无 BOM
        File.WriteAllLines(MydictPath, lines, U8);
    }

    // ---- 单字拼音表（8105 字表，自动注音）----
    private static Dictionary<string, List<string[]>> charMap;   // char -> { {py, w}, ... }

    public static void ImportCharMap()
    {
        if (charMap != null) return;
        charMap = new Dictionary<string, List<string[]>>();
        if (!File.Exists(CharmapPath)) return;
        foreach (string line in File.ReadAllLines(CharmapPath, Encoding.UTF8))
        {
            Match m = Regex.Match(line, @"^([^\t]+?)\t([a-züv ]+?)(?:\t(\d+))?\s*$");
            if (!m.Success) continue;
            string ch = m.Groups[1].Value;
            string py = m.Groups[2].Value.Trim();
            if (ch.Length != 1 || py.Length == 0) continue;
            long w = 1;
            if (m.Groups[3].Success) long.TryParse(m.Groups[3].Value, out w);
            if (!charMap.ContainsKey(ch)) charMap[ch] = new List<string[]>();
            charMap[ch].Add(new string[] { py, w.ToString() });
        }
    }

    // 返回 { pinyin, unknown[] }
    public static object[] AutoPinyin(string word)
    {
        ImportCharMap();
        List<string> parts = new List<string>();
        List<string> unknown = new List<string>();
        foreach (char c in word.ToCharArray())
        {
            string s = c.ToString();
            if (Regex.IsMatch(s, "^[A-Za-z0-9]$")) { parts.Add(s.ToLower()); continue; }
            List<string[]> cands;
            if (charMap.TryGetValue(s, out cands) && cands.Count > 0)
            {
                string bestPy = null;
                long bestW = long.MinValue;
                foreach (string[] t in cands)
                {
                    long w = long.Parse(t[1]);
                    if (w > bestW) { bestW = w; bestPy = t[0]; }
                }
                parts.Add(bestPy);
            }
            else
            {
                unknown.Add(s);
                parts.Add("?");
            }
        }
        return new object[] { string.Join(" ", parts.ToArray()), unknown };
    }

    // =========================================================================
    // 按键设置：ascii_composer（右/左Shift、CapsLock）
    //   读：build\default.yaml（运行时真正加载的合并产物）
    //   写：default.custom.yaml（源头）+ build\default.yaml（立即生效）+ 重启
    // =========================================================================
    private static void ParseSwitchKey(string text, out bool sl, out bool sr, out string caps)
    {
        sl = true; sr = true; caps = "clear";
        if (text == null) return;
        string[] lines = text.Split('\n');
        int state = 0;                 // 0 找 ascii_composer 1 找 switch_key 2 读键
        int keyIndent = -1;
        for (int i = 0; i < lines.Length; i++)
        {
            string raw = lines[i].TrimEnd('\r');
            string t = raw.Trim();
            int ind = raw.Length - raw.TrimStart().Length;
            if (state == 0)
            {
                if (t == "ascii_composer:") state = 1;
            }
            else if (state == 1)
            {
                if (t == "switch_key:") { state = 2; keyIndent = ind; }
                else if (t.Length > 0 && ind == 0) state = 0;   // 出了 ascii_composer 块
            }
            else
            {
                if (t.Length == 0) continue;
                if (ind <= keyIndent) break;
                Match m = Regex.Match(t, @"^(Shift_L|Shift_R|Caps_Lock)\s*:\s*(\S+)");
                if (m.Success)
                {
                    string v = m.Groups[2].Value;
                    if (m.Groups[1].Value == "Shift_L") sl = (v != "noop");
                    else if (m.Groups[1].Value == "Shift_R") sr = (v != "noop");
                    else caps = v;
                }
            }
        }
    }

    public static void LoadKeys()
    {
        string text = ReadText(BuildDefaultPath);
        if (text == null) text = ReadText(DefaultCustomPath);
        bool sl, sr;
        string caps;
        if (text == null) { sl = true; sr = true; caps = "clear"; }
        else ParseSwitchKey(text, out sl, out sr, out caps);
        ShiftL = sl;
        ShiftR = sr;
        CapsBehavior = caps;
    }

    private static string DetectNewline(string text)
    {
        return text != null && text.Contains("\r\n") ? "\r\n" : "\n";
    }

    // 在 default.custom.yaml 的 patch: 块里插入/替换一个 "a/b/c: value" 形式的键
    private static string UpsertPatchKey(string text, string key, string value)
    {
        if (text == null || text.Length == 0) text = "patch:\n";
        string nl = DetectNewline(text);
        string[] lines = text.Split('\n');
        bool found = false;
        Regex rx = new Regex(@"^(\s*)" + Regex.Escape(key) + @"\s*:\s*\S+");
        for (int i = 0; i < lines.Length; i++)
        {
            string raw = lines[i].TrimEnd('\r');
            Match m = rx.Match(raw);
            if (m.Success)
            {
                lines[i] = m.Groups[1].Value + key + ": " + value;
                found = true;
            }
        }
        List<string> outLines = new List<string>(lines);
        while (outLines.Count > 0 && outLines[outLines.Count - 1].Trim().Length == 0)
            outLines.RemoveAt(outLines.Count - 1);
        if (!found) outLines.Add("  " + key + ": " + value);
        return string.Join(nl, outLines.ToArray()) + nl;
    }

    // 在 build\default.yaml 的 ascii_composer/switch_key 块里插入/替换键
    private static string UpsertSwitchKey(string text, string key, string value)
    {
        string nl = DetectNewline(text);
        string[] lines = text.Split('\n');
        List<string> outLines = new List<string>();
        foreach (string l in lines) outLines.Add(l.TrimEnd('\r'));

        int ai = -1;
        for (int i = 0; i < outLines.Count; i++)
            if (outLines[i].Trim() == "ascii_composer:") { ai = i; break; }
        if (ai < 0)
        {
            // 没有这个块：文件末尾补一块
            while (outLines.Count > 0 && outLines[outLines.Count - 1].Trim().Length == 0)
                outLines.RemoveAt(outLines.Count - 1);
            outLines.Add("ascii_composer:");
            outLines.Add("  good_old_caps_lock: true");
            outLines.Add("  switch_key:");
            outLines.Add("    " + key + ": " + value);
            return string.Join(nl, outLines.ToArray()) + nl;
        }
        int si = -1;
        int sIndent = -1;
        for (int i = ai + 1; i < outLines.Count; i++)
        {
            string t = outLines[i].Trim();
            int ind = outLines[i].Length - outLines[i].TrimStart().Length;
            if (t == "switch_key:") { si = i; sIndent = ind; break; }
            if (t.Length > 0 && ind == 0) break;
        }
        if (si < 0)
        {
            // ascii_composer 在、switch_key 不在：插在 ascii_composer 下一行
            outLines.Insert(ai + 1, "  switch_key:");
            outLines.Insert(ai + 2, "    " + key + ": " + value);
            return string.Join(nl, outLines.ToArray()) + nl;
        }
        Regex rx = new Regex(@"^(\s*)" + Regex.Escape(key) + @"\s*:\s*\S+");
        bool found = false;
        int insertAt = -1;
        for (int i = si + 1; i < outLines.Count; i++)
        {
            string raw = outLines[i];
            string t = raw.Trim();
            if (t.Length == 0) { insertAt = i; continue; }
            int ind = raw.Length - raw.TrimStart().Length;
            if (ind <= sIndent) break;
            Match m = rx.Match(raw);
            if (m.Success)
            {
                outLines[i] = m.Groups[1].Value + key + ": " + value;
                found = true;
                break;
            }
            insertAt = i;
        }
        if (!found)
        {
            int at = insertAt >= 0 ? insertAt + 1 : si + 1;
            outLines.Insert(at, new string(' ', sIndent + 2) + key + ": " + value);
        }
        return string.Join(nl, outLines.ToArray()) + nl;
    }

    public static string KeysValue(bool on) { return on ? "commit_code" : "noop"; }

    // 把当前 ShiftL / ShiftR / CapsBehavior 落盘（不含重启）
    public static void WriteKeysFiles()
    {
        string sr = KeysValue(ShiftR);
        string sl = KeysValue(ShiftL);
        string caps = CapsBehavior;
        if (caps != "clear" && caps != "commit_code" && caps != "noop") caps = "clear";

        // 1) 源头 default.custom.yaml
        string custom = ReadText(DefaultCustomPath);
        if (custom == null) custom = "patch:\n";
        custom = UpsertPatchKey(custom, "ascii_composer/switch_key/Shift_R", sr);
        custom = UpsertPatchKey(custom, "ascii_composer/switch_key/Shift_L", sl);
        custom = UpsertPatchKey(custom, "ascii_composer/switch_key/Caps_Lock", caps);
        WriteTextFile(DefaultCustomPath, custom);

        // 2) 运行时加载的 build\default.yaml（先写 custom 再写 build，
        //    build 的 mtime 更新 → 服务启动时不会反过来重建覆盖）
        string build = ReadText(BuildDefaultPath);
        if (build != null)
        {
            build = UpsertSwitchKey(build, "Shift_R", sr);
            build = UpsertSwitchKey(build, "Shift_L", sl);
            build = UpsertSwitchKey(build, "Caps_Lock", caps);
            WriteTextFile(BuildDefaultPath, build);
        }
    }

    // 快速连点的合并点：写两个 yaml + 重启服务串行执行
    private static readonly object keysLock = new object();

    public static void ApplyKeysAndRestart()
    {
        lock (keysLock)
        {
            WriteKeysFiles();
            RestartWeasel();
        }
    }

    // 重启 WeaselServer 让 ascii_composer 的新配置生效（约 2 秒）。
    // 必须在后台线程调用，别卡 UI。
    public static void RestartWeasel()
    {
        string exe = null;
        try
        {
            foreach (Process p in Process.GetProcessesByName("WeaselServer"))
            {
                try { exe = p.MainModule.FileName; } catch { }
                try { p.Kill(); p.WaitForExit(3000); } catch { }
            }
        }
        catch { }
        if (exe == null || !File.Exists(exe))
            exe = @"C:\Program Files\Rime\weasel-0.17.4\WeaselServer.exe";
        if (File.Exists(exe))
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(exe);
                psi.UseShellExecute = false;
                psi.WorkingDirectory = Path.GetDirectoryName(exe);
                Process.Start(psi);
                Thread.Sleep(1200);   // 等服务起来再交还，避免连点两次起两份
            }
            catch { }
        }
    }
}
