// MainForm.cs —— 主窗体：壳（标签栏/状态栏）、生命周期（常驻/标记文件/保活）、
// 全部页面的布局重排。页面控件与事件在 Pages*.cs（同一个 partial class）里。

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

internal partial class MainForm : Form
{
    // ---- 壳（2026-09-26 重写：原生 TabControl 换成自绘双缓冲标签栏）----
    private AppleTabBar tabBar;
    private Panel pageHost;
    private ApplePage tabClip, tabFav, tabDict, tabSet, tabVoice, tabMi;
    private ApplePage[] pageArr;
    private int curPage;
    private StatusStrip status;
    private ToolStripStatusLabel statusLabel;

    // ---- 布局 ----
    private bool layoutDirty;
    private bool layoutReady;
    private string[] pageSig = new string[6];   // 每页一份尺寸签名（仅布局可见页）
    private Action[] pageLayout;
    private System.Windows.Forms.Timer layoutTimer;

    // ---- 常驻 ----
    private int tickN;
    private bool allowClose;
    private bool positioned;
    private string clipStamp = "";
    private DateTime wdLastSync = DateTime.MinValue;
    private DateTime wdLastWatch = DateTime.MinValue;

    // ---- 数据状态 ----
    private List<string> clip = new List<string>();
    private List<FavEntry> favs = new List<FavEntry>();
    private List<DictEntry> mydict = new List<DictEntry>();
    private string dictSearchText = "";
    private bool annotating;
    private System.Windows.Forms.Timer dictTimer;

    // ---- 控件赋值时的「别触发保存」守卫 ----
    private bool fzLoading;
    private bool voiceLoading;
    private bool miLoading;
    private bool keysLoading;
    private bool candLoading;
    private bool pageLoading;

    private const int InfoH = 48;

    public MainForm()
    {
        BuildShell();
        BuildPagesClipFav();
        BuildPagesDict();
        BuildPagesSetVoiceMi();
        FixControlOrder();
        FinishInit();
    }

    // 控件层级修正：WinForms「先加的控件在上层」，卡片里的说明文字会盖住同区域
    // 的按钮/输入框（默认条数卡的「保存」、防误触卡的「保存」都被盖过）。
    // 与 PowerShell 版同款兜底：把可交互控件统一提到最前。
    // 注意不碰 ListView：词库页「还没有加过词」的提示是故意压在列表上的。
    private void FixControlOrder()
    {
        Control[] pages = new Control[] { tabClip, tabFav, tabDict, tabSet, tabVoice, tabMi };
        foreach (Control pg in pages)
        {
            foreach (Control card in pg.Controls)
            {
                Panel p = card as Panel;   // AppleCard 派生自 Panel
                if (p == null) continue;
                foreach (Control c in p.Controls)
                {
                    if (c is Button || c is TextBox || c is ComboBox || c is TrackBar ||
                        c is CheckBox || c is Panel)
                        c.BringToFront();
                }
            }
        }
    }

    // ------------------------------------------------------------------ 壳
    private void BuildShell()
    {
        Text = "小狼毫 v 功能 · 可视化设置";
        AutoScaleMode = AutoScaleMode.None;
        ClientSize = new Size(960, 620);
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(820, 520);
        Font = Theme.Ui;
        BackColor = Theme.Bg;
        Theme.DoubleBuffer(this);

        // 顶栏：自绘双缓冲标签栏（2026-09-26 重写）。
        // 原来是原生 TabControl + OwnerDrawFixed：原生控件每次选中要走
        // 「擦除 → 逐格重绘」多帧，实测抓到过「整条栏空一帧」「白胶囊无文字」
        // 的中间帧 —— 就是用户看到的顶栏跳动/闪；且 DoubleBuffered 对原生
        // HWND 无效。现在整条栏一次成帧，槽位宽度恒定，邻居永不位移。
        tabBar = new AppleTabBar(new string[] {
            "剪贴板历史", "常用语", "词库管理", "设置与缓存", "语音输入", "防误触" });
        tabBar.Dock = DockStyle.None;    // 位置由 OnLayout 手算（不依赖停靠顺序）
        tabBar.TabChanged += delegate(int i) { SelectPage(i); };

        // 页面容器：六页常驻、只显示选中页（与 TabPage 时代语义一致）
        pageHost = new Panel();
        pageHost.Dock = DockStyle.None;
        pageHost.BackColor = Theme.Bg;
        Theme.DoubleBuffer(pageHost);

        tabClip = new ApplePage();
        tabFav = new ApplePage();
        tabDict = new ApplePage();
        tabSet = new ApplePage();
        tabVoice = new ApplePage();
        tabMi = new ApplePage();
        pageArr = new ApplePage[] { tabClip, tabFav, tabDict, tabSet, tabVoice, tabMi };
        for (int i = 0; i < pageArr.Length; i++)
        {
            pageArr[i].Visible = (i == 0);
            pageArr[i].Resize += Page_Resize;  // 拖窗口去抖：只打标记，90ms 后重排一次
            pageHost.Controls.Add(pageArr[i]);
        }
        pageHost.Resize += Host_Resize;

        status = new StatusStrip();
        status.Dock = DockStyle.None;         // 同上：手算位置
        status.BackColor = Theme.White;
        status.SizingGrip = false;
        Theme.DoubleBuffer(status);
        statusLabel = new ToolStripStatusLabel();
        statusLabel.Text = "就绪";
        statusLabel.Spring = true;
        statusLabel.TextAlign = ContentAlignment.MiddleLeft;
        statusLabel.ForeColor = Theme.Sub;
        statusLabel.Font = Theme.Hint;
        status.Items.Add(statusLabel);
        status.Paint += Status_Paint;

        Controls.Add(pageHost);
        Controls.Add(tabBar);
        Controls.Add(status);
    }

    // 壳三件套全部手算位置：顶栏=40px，状态条=底原高，中间全是页面容器。
    // 刻意不用 Dock —— 停靠处理顺序是 WinForms 的老坑，手算幂等且可读。
    protected override void OnLayout(LayoutEventArgs levent)
    {
        int barH = tabBar != null ? tabBar.Height : 40;
        int stH = status != null ? status.Height : 24;
        int w = ClientSize.Width;
        int h = ClientSize.Height;
        if (tabBar != null) tabBar.SetBounds(0, 0, w, barH);
        if (status != null) status.SetBounds(0, h - stH, w, stH);
        if (pageHost != null)
        {
            pageHost.SetBounds(0, barH, w, Math.Max(0, h - barH - stH));
            Host_Resize(null, EventArgs.Empty);
        }
        base.OnLayout(levent);
    }

    protected override void OnMouseWheel(MouseEventArgs e)
    {
        base.OnMouseWheel(e);
        // 焦点在窗体上时（点了不可获焦的卡片区域 / 切页后焦点落到窗体），
        // WinForms 不会把滚轮递给鼠标下的页面 —— 手动转发给当前页，滚轮翻页才不哑。
        if (pageArr != null && curPage >= 0 && curPage < pageArr.Length)
            pageArr[curPage].ScrollByWheel(e.Delta);
    }

    private void Host_Resize(object sender, EventArgs e)
    {
        if (pageArr == null) return;
        int w = pageHost.ClientSize.Width;
        int h = pageHost.ClientSize.Height;
        foreach (ApplePage p in pageArr) p.SetBounds(0, 0, w, h);
    }

    private void SelectPage(int i)
    {
        if (pageArr == null || i < 0 || i >= pageArr.Length) return;
        if (curPage == i && pageArr[i].Visible) return;
        curPage = i;
        pageHost.SuspendLayout();
        try
        {
            for (int k = 0; k < pageArr.Length; k++)
                pageArr[k].Visible = (k == i);
        }
        finally { pageHost.ResumeLayout(false); }
        if (layoutReady) LayoutTabs();   // 每页单独签名：只有当前页尺寸变了才重排这一份
    }

    private void Page_Resize(object sender, EventArgs e)
    {
        layoutDirty = true;
        if (layoutTimer != null && !layoutTimer.Enabled) layoutTimer.Start();
    }

    private void Status_Paint(object sender, PaintEventArgs e)
    {
        try { e.Graphics.DrawLine(Theme.PenStroke, 0, 0, status.ClientSize.Width, 0); }
        catch { }
    }

    // ------------------------------------------------------------ 初始化
    private void FinishInit()
    {
        Data.LoadSettings();
        Data.LoadVoiceSettings();
        Data.LoadFuzzySettings();
        Data.LoadCandSettings();
        Data.LoadSmartPunctSettings();
        Data.LoadKeys();

        pageLoading = true;
        try
        {
            cmbPage.SelectedItem = Data.PageSize.ToString();
            if (cmbPage.SelectedItem == null) cmbPage.SelectedIndex = 0;
        }
        finally { pageLoading = false; }

        UpdateMiControls();
        UpdateVoiceControls();
        UpdateFuzzyControls();
        UpdateKeysControls();

        dictTimer = new System.Windows.Forms.Timer();
        dictTimer.Interval = 200;
        dictTimer.Tick += DictTimer_Tick;

        layoutTimer = new System.Windows.Forms.Timer();
        layoutTimer.Interval = 90;
        layoutTimer.Tick += delegate
        {
            layoutTimer.Stop();
            if (layoutDirty && Visible) SyncLayout();
        };

        layoutReady = true;
        LayoutTabs();
        RefreshClipboard();
        RefreshFavorites();
        RefreshMyDictList();
    }

    public void SelectTab(int index)
    {
        if (index < 0 || pageArr == null || index >= pageArr.Length) return;
        tabBar.Select(index);   // 选中变化会经 TabChanged -> SelectPage
        if (!pageArr[index].Visible) SelectPage(index);
    }

    public void TestDialog()
    {
        // 注意 AppleDialog.Show 的 multiFirst 语义：只有**第一个字段**会渲染成多行大框，
        // 演示字段顺序必须和真实渲染一致（曾把标签写成「单行/多行」与实际相反）。
        List<DialogField> f = new List<DialogField>();
        f.Add(new DialogField("多行输入框（第 1 个字段 · multiFirst=true）", "第一行\n第二行"));
        f.Add(new DialogField("单行输入框", "示例内容"));
        AppleDialog.Show(this, "样式自检 · 对话框",
            "这是 Apple 样式对话框的自检：圆角输入框、胶囊按钮、主色/危险色。",
            f, "确定", "取消", false, "Primary", true, true, 470);
    }

    public bool Confirm(string message, string title)
    {
        return AppleDialog.Show(this, title, message, null, "确定", "取消",
            false, "Danger", false, false, 470).OK;
    }

    public void Info(string message, string title)
    {
        AppleDialog.Show(this, title, message, null, "知道了", "取消",
            true, "Primary", false, false, 470);
    }

    // 状态条文案带语义色（2026-09-26 颜色可视化）：
    //   失败/阻塞类 → 红；成功类（含「已…」）→ 绿；其余说明 → 灰。
    // 只改 ForeColor，不改布局：Spring 标签永远占满整行，零位移。
    private void Status(string text)
    {
        statusLabel.Text = text;
        Color c = Theme.Sub;
        if (text != null)
        {
            if (text.Contains("失败") || text.Contains("请先") || text.Contains("没保存") ||
                text.Contains("不能") || text.Contains("错误") || text.Contains("占用"))
                c = Theme.Danger;
            else if (text.Contains("已"))
                c = Theme.OkText;
        }
        statusLabel.ForeColor = c;
    }

    // ------------------------------------------------------- 显示 / 隐藏
    public void Prebuild()
    {
        // 屏幕外真 Show 一次再 Hide：把「第一次显示」的布局/句柄工作提前做掉
        StartPosition = FormStartPosition.Manual;
        Location = new Point(-32000, -32000);
        Show();
        Hide();
    }

    private void CenterWindow()
    {
        try
        {
            Rectangle wa = Screen.PrimaryScreen.WorkingArea;
            StartPosition = FormStartPosition.Manual;
            int x = wa.Left + (wa.Width - Width) / 2;
            int y = wa.Top + (wa.Height - Height) / 2;
            // 钳进工作区：曾出现过「居中算出的坐标把窗口下半截留在屏幕外」
            // （实测 1103,654 → 底边 1643 > 屏高 1440），这里兜底保证整窗可见。
            if (x + Width > wa.Right) x = wa.Right - Width;
            if (y + Height > wa.Bottom) y = wa.Bottom - Height;
            if (x < wa.Left) x = wa.Left;
            if (y < wa.Top) y = wa.Top;
            Location = new Point(x, y);
        }
        catch { }
    }

    public void HideSettingsWindow()
    {
        Hide();
        Status("已隐藏 · 后台常驻，v→1 秒开");
    }

    public void ShowSettingsWindow()
    {
        if (!Visible)
        {
            Data.LoadSettings();
            Data.LoadVoiceSettings();
            Data.LoadFuzzySettings();
            Data.LoadCandSettings();
            Data.LoadKeys();
            pageLoading = true;
            try
            {
                cmbPage.SelectedItem = Data.PageSize.ToString();
                if (cmbPage.SelectedItem == null) cmbPage.SelectedIndex = 0;
            }
            finally { pageLoading = false; }
            UpdateMiControls();
            UpdateVoiceControls();
            UpdateFuzzyControls();
            UpdateKeysControls();
            RefreshClipboard();
            RefreshFavorites();
            RefreshMyDictList();
            LayoutTabs();
        }
        if (!positioned)
        {
            CenterWindow();
            positioned = true;
        }
        else if (Left < -5000 || Top < -5000)
        {
            CenterWindow();
        }
        Show();
        if (layoutReady)
        {
            LayoutTabs();
            layoutDirty = false;
        }
        if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
        try { Activate(); } catch { }
        try { BringToFront(); } catch { }
        try { TopMost = true; TopMost = false; } catch { }   // 前台窗口锁
        Status("已打开 · " + DateTime.Now.ToString("HH:mm:ss"));
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        // 录制中被关掉/隐藏：先把 hotkey_recorder_pid 清掉再走，
        // 不然悬浮球会一直以为在录制、快捷键整段时间都不工作。
        if (hotState != "") StopHotkeyRecord("窗口已关闭");
        // allowClose 只在 quit 标记（VMenu.exe stop）时为真：那时真的退出进程。
        // 其余（点 X / Alt+F4）一律只隐藏 —— 常驻才能秒开。
        if (!allowClose && e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            HideSettingsWindow();
        }
        base.OnFormClosing(e);
    }

    // ---------------------------------------------------------- 标记文件
    public static string TakeFlag()
    {
        try
        {
            if (File.Exists(Data.FlagPath))
            {
                string txt = File.ReadAllText(Data.FlagPath).Trim();
                try { File.Delete(Data.FlagPath); } catch { }
                return txt;
            }
        }
        catch { }
        return null;
    }

    private void InvokeFlagCheck()
    {
        string text = TakeFlag();
        if (text == null) return;
        if (text == "quit")
        {
            allowClose = true;
            Close();
            Application.ExitThread();   // 无参 Run()：关窗体不会停消息循环，要显式退
            return;
        }
        if (text == "hide")
        {
            HideSettingsWindow();
            return;
        }
        Match m = Regex.Match(text, @"^tab:\s*(\d+)$");
        if (m.Success)
        {
            int ti;
            if (int.TryParse(m.Groups[1].Value, out ti)) SelectTab(ti);
        }
        ShowSettingsWindow();
    }

    // ------------------------------------------------------------ 保活
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

    private void StartHelper(string mode)
    {
        // 拉活助手：VMenu.exe 自己就是无窗口 exe（剪贴板同步 / 守护都是它的模式）
        try
        {
            string exe = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "VMenu.exe");
            if (!File.Exists(exe)) return;
            ProcessStartInfo psi = new ProcessStartInfo(exe, mode + " --rime \"" + Data.RimeDir + "\"");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WindowStyle = ProcessWindowStyle.Hidden;
            Process.Start(psi);
        }
        catch { }
    }

    private void MainTick()
    {
        // 1.5 秒一次：剪贴板变化重载 + 保活兜底（标记文件的快检查在 60ms 定时器里）
        if (IsDisposed) return;
        if (Visible)
        {
            string st = Data.ClipStamp();
            if (st != clipStamp) RefreshClipboard();
        }
        try
        {
            DateTime now = DateTime.Now;
            if (!Alive("RimeClipboardSync") &&
                (now - wdLastSync).TotalSeconds >= 10)
            {
                wdLastSync = now;
                StartHelper("sync");
            }
            if (!Alive("RimeVMenuWatcher") &&
                (now - wdLastWatch).TotalSeconds >= 10)
            {
                wdLastWatch = now;
                StartHelper("watch");
            }
        }
        catch { }
    }

    public void StartLoop()
    {
        System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
        timer.Interval = 60;
        timer.Tick += delegate
        {
            if (File.Exists(Data.FlagPath)) InvokeFlagCheck();
            tickN++;
            if (tickN >= 25)
            {
                tickN = 0;
                MainTick();
            }
        };
        timer.Start();
        // 无参 Application.Run()：只开消息循环，绝不能带窗体（带了会强制显示它）
        Application.Run();
        timer.Stop();
        timer.Dispose();
        if (layoutTimer != null) layoutTimer.Dispose();
        if (dictTimer != null) dictTimer.Dispose();
    }

    // ------------------------------------------------------------ 布局
    private void SyncLayout()
    {
        layoutDirty = false;
        if (!layoutReady) return;
        LayoutTabs();
    }

    private void LayoutTabs()
    {
        // 仅布局可见页：每页单独签名，切页/改窗口尺寸只重排当前页这一份。
        // 隐藏页的 ClientSize 由 Host_Resize 六页一起 SetBounds 同步更新，
        // 轮到它可见时签名对不上会自动补排，永远不过期；没变就是纯比较、零 SetBounds。
        if (pageLayout == null)
            pageLayout = new Action[] { LayoutClip, LayoutFav, LayoutDict, LayoutSet, LayoutVoice, LayoutMi };
        if (pageArr == null || curPage < 0 || curPage >= pageArr.Length) return;
        ApplePage p = pageArr[curPage];
        string sig = p.ClientSize.Width + "x" + p.ClientSize.Height;
        if (sig == pageSig[curPage]) return;
        pageSig[curPage] = sig;
        pageLayout[curPage]();
        // 兜底：内容放得下时清掉残留 AutoScroll 偏移（曾观察到缩放→切页后整页位移 (−17,+12)）；
        // 真会溢出的页（如设置页长内容）保持用户滚动位置不动。
        Size disp = p.DisplayRectangle.Size;
        if (disp.Width <= p.ClientSize.Width && disp.Height <= p.ClientSize.Height)
            p.AutoScrollPosition = new Point(0, 0);
    }
}
