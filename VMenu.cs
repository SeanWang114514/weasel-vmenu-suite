// VMenu.exe —— v 功能的后台入口 / 守护（**没有控制台窗口**）
//
// 为什么需要它
//   「开机自启」「打开设置」以前全靠 .bat + powershell.exe：控制台子系统进程
//   一定会被创建 → 即使带 -WindowStyle Hidden 也会闪一下黑框，任务栏里偶尔还会
//   留下一个最小化的 powershell 窗口。本程序是 **GUI 子系统**（/target:winexe）
//   的 native 宿主：自身不带控制台，并且用 CreateNoWindow=true 启动所有子进程，
//   所以从这条链路出去的进程（设置窗口 / 剪贴板同步 / 守护）都不会有黑框。
//
// 模式
//   (无参数) / open   让常驻设置窗口显示出来（写 open-settings.flag）；没在跑就
//                     先把守护拉起来。桌面快捷方式、托盘「输入法设置」用这个。
//   watch             守护常驻设置窗口：没在跑就拉起来。常驻、无窗口。
//                     持有互斥体 RimeVMenuWatcher。
//   gui               只启动设置窗口 VMenuSettings.exe（隐藏窗口，无控制台）；
//                     已在跑就写标记让它显示。**整条链路不再依赖 PowerShell。**
//   sync              剪贴板同步循环（原来靠 clipboard-sync.ps1，现在内嵌在本
//                     exe 里直接跑；`start` 会拉起一个子进程跑这个模式）。
//   start             开机自启：watch + sync + gui 一把拉起。
//   stop              关掉设置窗口、守护、剪贴板同步（含旧版 PowerShell 进程）。
//   status            把「谁在跑」写到文件（--out 指定，默认 %TEMP%\vmenu-status.txt）。
//
// 选项
//   --rime <dir>      Rime 用户目录（默认 D:\rime-sandbox）
//   --show            启动设置窗口时立刻显示
//   --tab <n>         启动设置窗口时直接切到第 n 个标签页
//
// 编译（改完本文件后必须重新编译，见 部署.bat 或文档）
//   csc.exe /nologo /target:winexe /optimize+ /out:VMenu.exe VMenu.cs
// 注意：本文件必须保存为 UTF-8 带 BOM，否则 csc 按 GBK 读源码，中文提示会乱码。

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Management;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;   // 内嵌剪贴板同步：读剪贴板文本

internal static class VMenu
{
    private const string LegacyRimeDir = @"D:\rime-sandbox";
    private const string MutexWatcher = "RimeVMenuWatcher";
    private const string MutexGui = "RimeVMenuSettingsGui";
    private const string MutexSync = "RimeClipboardSync";

    private static string exeDir = ".";
    private static string rimeDir = null;

    // Resolve the Rime user dir when --rime is not given:
    // env override -> registry RimeUserDir -> %APPDATA%\Rime -> legacy dev dir.
    private static string ResolveRimeDir()
    {
        try
        {
            string env = Environment.GetEnvironmentVariable("RIME_DIR");
            if (!string.IsNullOrEmpty(env) && Directory.Exists(env)) return env;
            using (Microsoft.Win32.RegistryKey k =
                Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Rime\Weasel"))
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
            if (Directory.Exists(LegacyRimeDir)) return LegacyRimeDir;
        }
        catch { }
        return LegacyRimeDir;
    }

    [STAThread]
    private static int Main(string[] args)
    {
        string asm = Assembly.GetExecutingAssembly().Location;
        string d = Path.GetDirectoryName(asm);
        if (!string.IsNullOrEmpty(d)) exeDir = d;

        string mode = "open";
        bool showNow = false;
        int tab = -1;
        string outFile = null;

        for (int i = 0; i < args.Length; i++)
        {
            string a = args[i].ToLowerInvariant();
            switch (a)
            {
                case "--rime":
                    if (i + 1 < args.Length) rimeDir = args[++i];
                    break;
                case "--show":
                    showNow = true;
                    break;
                case "--tab":
                    if (i + 1 < args.Length) { int t; if (int.TryParse(args[++i], out t)) tab = t; }
                    break;
                case "--out":
                    if (i + 1 < args.Length) outFile = args[++i];
                    break;
                case "-h":
                case "--help":
                case "/?":
                    return 0;
                default:
                    if (a.Length > 0 && a[0] != '-') mode = a;
                    break;
            }
        }

        if (rimeDir == null) rimeDir = ResolveRimeDir();

        try
        {
            switch (mode)
            {
                case "open": return Open();
                case "watch": return Watch();
                case "gui": return StartGui(showNow, tab);
                case "sync": return ClipboardSyncLoop();
                case "start":
                    EnsureWatcher();
                    RunHidden(Assembly.GetExecutingAssembly().Location,
                        "sync --rime \"" + rimeDir + "\"");   // 子进程跑内嵌同步循环
                    StartGui(false, -1);
                    return 0;
                case "stop": return StopAll();
                case "status": return Status(outFile);
                default: return Open();
            }
        }
        catch
        {
            return 1;
        }
    }

    // ---------------------------------------------------------------- 基础

    private static string FlagPath
    {
        get { return Path.Combine(rimeDir, "open-settings.flag"); }
    }

    private static void WriteFlag(string text)
    {
        try
        {
            // 和 Lua 侧 / 设置窗口一致：UTF-8 不带 BOM
            File.WriteAllText(FlagPath, text, new UTF8Encoding(false));
        }
        catch { }
    }

    // 互斥体探测：0.1ms。以前用 Get-CimInstance Win32_Process 查命令行要 176ms，
    // 而且是跑在设置窗口的 UI 线程上 —— 用户感受到的「每 2 秒卡一下」就是它。
    private static bool Alive(string name)
    {
        Mutex m = null;
        try
        {
            if (Mutex.TryOpenExisting(name, out m)) return true;
            return false;
        }
        catch { return false; }
        finally { if (m != null) { try { m.Dispose(); } catch { } } }
    }

    // 所有子进程都用它启动：CreateNoWindow + Hidden = 连控制台都不创建
    private static Process RunHidden(string fileName, string arguments)
    {
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo(fileName, arguments);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WindowStyle = ProcessWindowStyle.Hidden;
            psi.WorkingDirectory = exeDir;
            return Process.Start(psi);
        }
        catch { return null; }
    }

    private static string ScriptPath(string name)
    {
        return Path.Combine(exeDir, name);
    }

    // ---------------------------------------------------------------- 各模式

    private static int Open()
    {
        // 先写标记：守护此刻不在也没关系 —— 它起来时会看到标记并直接显示窗口
        WriteFlag("open");
        EnsureWatcher();
        return 0;
    }

    private static void EnsureWatcher()
    {
        if (Alive(MutexWatcher)) return;
        RunHidden(Assembly.GetExecutingAssembly().Location, "watch --rime \"" + rimeDir + "\"");
        // 等它把互斥体拿起来，避免连点几次就拉起好几个守护
        for (int i = 0; i < 40; i++)
        {
            Thread.Sleep(50);
            if (Alive(MutexWatcher)) break;
        }
    }

    private static int Watch()
    {
        bool created;
        using (Mutex mtx = new Mutex(true, MutexWatcher, out created))
        {
            if (!created) return 0;   // 已经有一个守护在跑
            while (true)
            {
                try
                {
                    if (!Alive(MutexGui))
                    {
                        // 有标记就先显示（用户就是在等这个窗口）
                        StartGui(File.Exists(FlagPath), -1);
                        Thread.Sleep(3000);
                    }
                }
                catch { }
                Thread.Sleep(1000);
            }
        }
    }

    private static int StartGui(bool showNow, int tab)
    {
        // 设置窗口 = VMenuSettings.exe（WinForms 原生 GUI 子系统 exe，零 PowerShell）
        string exe = ScriptPath("VMenuSettings.exe");
        if (!File.Exists(exe)) return 1;
        if (Alive(MutexGui))
        {
            // 已经在跑：只有当调用方要求「显示出来」时才写标记，让常驻实例自己
            // 亮出来（比再开一个进程快得多）。showNow 为假时绝不能写 —— 否则
            // 「开机自启」这种「只要它跑着、别冒出来」的场景会自己把窗口弹出来；
            // 而且 start 与守护会同时调用本函数，输的那个正好走这条分支。
            if (showNow) WriteFlag("open");
            return 0;
        }
        StringBuilder sb = new StringBuilder();
        sb.Append("--rime \"").Append(rimeDir).Append("\"");
        if (showNow || File.Exists(FlagPath)) sb.Append(" --show");
        if (tab >= 0) sb.Append(" --tab ").Append(tab);
        return RunHidden(exe, sb.ToString()) == null ? 1 : 0;
    }

    private static int StartSync()
    {
        // 拉起一个子进程跑 ClipboardSyncLoop（`VMenu.exe sync` 直接进循环本体）
        if (Alive(MutexSync)) return 0;
        return RunHidden(Assembly.GetExecutingAssembly().Location,
            "sync --rime \"" + rimeDir + "\"") == null ? 1 : 0;
    }

    // ------------------------------------------------- 剪贴板同步（内嵌）
    // 从 clipboard-sync.ps1 1:1 移植：文件是唯一事实来源（外部清空/编辑要认）、
    // GetClipboardSequenceNumber 检测新复制（连「原样再复制一次」也算）、
    // 去重 + 上限 50 条 + 多行压平 + 2000 字截断、1 秒一轮。
    [DllImport("user32.dll")]
    private static extern uint GetClipboardSequenceNumber();

    private static string SyncStamp(string cache)
    {
        try
        {
            FileInfo fi = new FileInfo(cache);
            if (!fi.Exists) return "missing";
            return fi.LastWriteTimeUtc.Ticks + ":" + fi.Length;
        }
        catch { return "missing"; }
    }

    private static List<string> SyncRead(string cache)
    {
        List<string> items = new List<string>();
        try
        {
            if (File.Exists(cache))
            {
                foreach (string line in File.ReadAllLines(cache, Encoding.UTF8))
                    if (line != null && line.Trim().Length > 0) items.Add(line);
            }
        }
        catch { }
        return items;
    }

    private static void SyncWrite(string cache, List<string> items)
    {
        try
        {
            StringBuilder sb = new StringBuilder();
            foreach (string i in items)
                if (i != null && i.Trim().Length > 0) sb.Append(i.Trim()).Append('\n');
            string tmp = cache + ".tmp";
            File.WriteAllText(tmp, sb.ToString(), new UTF8Encoding(false));
            if (File.Exists(cache)) File.Replace(tmp, cache, null);
            else File.Move(tmp, cache);
        }
        catch { }
    }

    private static string SyncClipText()
    {
        try
        {
            if (!Clipboard.ContainsText()) return null;
            string t = Clipboard.GetText(TextDataFormat.UnicodeText);
            if (t == null) return null;
            // 压平换行：缓存格式是一行一条
            t = t.Replace("\r\n", " ").Replace("\r", " ").Replace("\n", " ").Trim();
            if (t.Length == 0) return null;
            if (t.Length > 2000) t = t.Substring(0, 2000);
            return t;
        }
        catch { return null; }
    }

    private static int ClipboardSyncLoop()
    {
        // 单实例：互斥体在循环整个生命周期里握着（设置窗口用 0.1ms 的
        // Mutex::OpenExisting 探活，代替 176ms 的 Win32_Process 查询）
        Mutex syncMutex = new Mutex(false, MutexSync);
        bool first;
        try { first = syncMutex.WaitOne(0); }
        catch (AbandonedMutexException) { first = true; }
        catch { first = false; }
        if (!first)
        {
            try { syncMutex.Dispose(); } catch { }
            return 0;
        }

        const int max = 50;
        const int intervalMs = 1000;
        string cache = Path.Combine(rimeDir, "clipboard-cache.txt");
        try { Directory.CreateDirectory(rimeDir); } catch { }

        List<string> history = SyncRead(cache);
        if (history.Count > max) history.RemoveRange(max, history.Count - max);
        if (!File.Exists(cache)) SyncWrite(cache, history);
        string stamp = SyncStamp(cache);
        uint seq = GetClipboardSequenceNumber();

        while (true)
        {
            try
            {
                // (1) 别人改过文件吗（清空 / 编辑 / 删除）？文件是唯一事实来源
                string now = SyncStamp(cache);
                if (now != stamp)
                {
                    history = SyncRead(cache);
                    if (history.Count > max) history.RemoveRange(max, history.Count - max);
                    if (now == "missing")
                    {
                        SyncWrite(cache, history);
                        now = SyncStamp(cache);
                    }
                    stamp = now;
                    // 剪贴板上此刻的内容不算「新复制」：清空历史不能立刻又把
                    // 正在剪贴板上的那条塞回来
                    seq = GetClipboardSequenceNumber();
                }

                // (2) 有新复制吗（序号变了就算，包括原样再复制）？
                uint s = GetClipboardSequenceNumber();
                if (s != seq)
                {
                    seq = s;
                    string text = SyncClipText();
                    if (text != null)
                    {
                        List<string> fresh = new List<string>();
                        fresh.Add(text);
                        foreach (string old in history)
                            if (old != text) fresh.Add(old);
                        if (fresh.Count > max) fresh.RemoveRange(max, fresh.Count - max);
                        history = fresh;
                        SyncWrite(cache, history);
                        stamp = SyncStamp(cache);
                    }
                }
            }
            catch { }
            Thread.Sleep(intervalMs);
        }
    }

    private static int StopAll()
    {
        // 让设置窗口自己退（它认得 quit：不再只是隐藏，而是真的关闭退出）
        WriteFlag("quit");
        Thread.Sleep(800);
        try { File.Delete(FlagPath); } catch { }

        KillProcesses("VMenu.exe", "watch");                  // 守护（就是本程序的 watch 模式）
        KillProcesses("VMenuSettings.exe", "");               // 新版设置窗口（兜底）
        KillProcesses("VMenu.exe", "sync");                   // 内嵌剪贴板同步子进程（兜底）
        KillProcesses("powershell.exe", "clipboard-sync.ps1");        // 旧版（迁移期）
        KillProcesses("powershell.exe", "vmenu-settings-gui.ps1");    // 旧版（迁移期）
        KillProcesses("powershell.exe", "vmenu-watcher.ps1");         // 旧版（迁移期）
        return 0;
    }

    private static void KillProcesses(string imageName, string cmdMarker)
    {
        try
        {
            string q = "SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name='" + imageName + "'";
            using (ManagementObjectSearcher s = new ManagementObjectSearcher(q))
            {
                foreach (ManagementBaseObject o in s.Get())
                {
                    string cmd = o["CommandLine"] as string;
                    if (cmd == null || cmd.IndexOf(cmdMarker, StringComparison.OrdinalIgnoreCase) < 0) continue;
                    int pid = Convert.ToInt32(o["ProcessId"]);
                    if (pid == Process.GetCurrentProcess().Id) continue;
                    try { Process.GetProcessById(pid).Kill(); } catch { }
                }
            }
        }
        catch { }
    }

    private static int Status(string outFile)
    {
        StringBuilder sb = new StringBuilder();
        sb.AppendLine("VMenu.exe 状态  " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
        sb.AppendLine("exe      : " + Assembly.GetExecutingAssembly().Location);
        sb.AppendLine("rime dir : " + rimeDir);
        sb.AppendLine("设置窗口 : " + (Alive(MutexGui) ? "在跑" : "没在跑") + "   (互斥体 " + MutexGui + ")");
        sb.AppendLine("守护     : " + (Alive(MutexWatcher) ? "在跑" : "没在跑") + "   (互斥体 " + MutexWatcher + ")");
        sb.AppendLine("剪贴板同步: " + (Alive(MutexSync) ? "在跑" : "没在跑") + "   (互斥体 " + MutexSync + ")");
        sb.AppendLine("标记文件 : " + (File.Exists(FlagPath) ? "存在（等待被消费）" : "不存在（正常）"));
        if (outFile == null) outFile = Path.Combine(Path.GetTempPath(), "vmenu-status.txt");
        try { File.WriteAllText(outFile, sb.ToString(), new UTF8Encoding(true)); } catch { }
        return 0;
    }
}
