// Program.cs —— VMenuSettings.exe 入口
//
// 「单独的 exe」改造（2026-09-25）：整个设置窗口不再依赖 PowerShell ——
// WinForms 原生 C# 编译（.NET Framework 4.x 自带 csc，无需安装任何运行时）。
// 打开速度：进程常驻 + 窗口预建在屏幕外；v→1 只是把已建好的窗口 Show 出来。
//
//   VMenuSettings.exe [--rime <dir>] [--show] [--tab N] [--dialogtest] [--hotkeytest]
//
// 协议与旧版 PowerShell 完全一致：
//   互斥体 RimeVMenuSettingsGui（单实例）
//   标记文件 <RimeDir>\open-settings.flag：open / hide / quit / tab:N

using System;
using System.IO;
using System.Threading;
using System.Windows.Forms;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        string rimeDir = @"D:\rime-sandbox";
        bool showNow = false;
        int tab = -1;
        bool dialogTest = false;
        bool hotkeyTest = false;

        for (int i = 0; i < args.Length; i++)
        {
            string lower = args[i].ToLowerInvariant();
            if (lower == "--rime" && i + 1 < args.Length)
            {
                rimeDir = args[++i];
            }
            else if (lower == "--show" || lower == "-shownow" || lower == "-show")
            {
                showNow = true;
            }
            else if (lower == "--tab" && i + 1 < args.Length)
            {
                int t;
                if (int.TryParse(args[++i], out t)) tab = t;
            }
            else if (lower == "--dialogtest" || lower == "-dialogtest")
            {
                dialogTest = true;
            }
            else if (lower == "--hotkeytest" || lower == "-hotkeytest")
            {
                hotkeyTest = true;
            }
            else if (lower == "-h" || lower == "--help" || lower == "/?")
            {
                return 0;
            }
        }

        // 自检模式（--hotkeytest）是秒进秒出的无窗口跑法，**不参与单实例互斥**
        // （对应 PowerShell 版的 -HotkeyTest；那边的入口继续可用，互不影响）。
        if (hotkeyTest) return HotkeyKit.RunSelfTest();

        // 默认目录不可用时退回注册表里登记的 RimeUserDir
        rimeDir = Data.ResolveRimeDir(rimeDir);

        // ---- 单实例 ----
        // 已有常驻实例：只有本次启动本来就要求显示（托盘/快捷方式带 --show、
        // 或调用方自己写了标记）才写标记文件，否则开机自启时窗口会被弹出来。
        Mutex mutex = new Mutex(false, "RimeVMenuSettingsGui");
        bool isFirst;
        try { isFirst = mutex.WaitOne(0); }
        catch (AbandonedMutexException) { isFirst = true; }
        catch { isFirst = false; }

        if (!isFirst)
        {
            if (showNow)
            {
                try
                {
                    File.WriteAllText(Path.Combine(rimeDir, "open-settings.flag"), "open");
                }
                catch { }
            }
            try { mutex.Dispose(); } catch { }
            return 0;
        }

        if (!Directory.Exists(rimeDir))
        {
            MessageBox.Show("找不到 Rime 用户目录：\n\n" + rimeDir, "无法打开设置");
            try { mutex.ReleaseMutex(); } catch { }
            try { mutex.Dispose(); } catch { }
            return 1;
        }

        Data.Init(rimeDir);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        MainForm form = new MainForm();
        form.Prebuild();                       // 屏幕外预建，把「第一次显示」的成本提前付掉
        if (tab >= 0) form.SelectTab(tab);
        if (showNow) form.ShowSettingsWindow();
        if (dialogTest) form.TestDialog();

        form.StartLoop();                      // 阻塞：60ms 标记轮询 + 无参消息循环

        try { form.Dispose(); } catch { }
        try { if (isFirst) mutex.ReleaseMutex(); } catch { }
        try { mutex.Dispose(); } catch { }
        return 0;
    }
}
