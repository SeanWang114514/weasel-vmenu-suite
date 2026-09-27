// PagesSetVoiceMi.cs —— 设置与缓存页（含新增的「逐对模糊」与「按键/英文候选自定义」
// 卡片）、语音输入页、防误触页

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Threading;
using System.Windows.Forms;

internal partial class MainForm : Form
{
    // ---- 设置与缓存页 ----
    private AppleCard cardFuzzy, cardKeys, cardPage, cardClear, cardFiles, cardNative;
    private CheckBox chkFuzzy;
    private Label lblFuzzyState, lblFuzzyHint, lblFuzzyPairTitle;
    private CheckBox[] chkFzPair = new CheckBox[5];
    private CheckBox chkShiftR, chkShiftL, chkEnCand, chkSmartPunct;
    private Label lblKeysCaps, lblKeysHint, lblEnState;
    private AppleField fieldKeysCaps;
    private Label lblPage, lblPageHint, lblClear, lblNative;
    private AppleField cmbPageP;
    private AppleButton btnPageSave, btnClearClip, btnClearFav, btnNative;
    private AppleField tbFilesP;

    // ---- 语音输入页 ----
    private AppleCard cardPunct;
    private CheckBox chkPunct;
    private Label lblPunctState, lblPunctHint;

    // ---- 语音输入快捷键卡片（并发会话功能，随 exe 一并移植）----
    private AppleCard cardHotkey;
    private Label lblHotCur, lblHotState, lblHotHint;
    private AppleButton btnHotkey, btnHotReset;
    private System.Windows.Forms.Timer hotTimer;
    private string hotState = "";            // "" | lead | up | press | collect
    private List<int> hotGot = new List<int>();
    private DateTime hotLeadUntil = DateTime.MinValue;
    private DateTime hotEndAt = DateTime.MinValue;

    // ---- 防误触页 ----
    private AppleCard cardMi;
    private CheckBox chkMiEnable;
    private Label lblMiInterval, lblMiRange, lblMiRec, lblMiState;
    private AppleField txtMiP;
    private AppleButton btnMiReset, btnMiSave;
    private TrackBar trkMi;

    private ComboBox cmbPage { get { return cmbPageP.Combo; } }
    private TextBox tbFiles { get { return tbFilesP.TextBox; } }
    private TextBox txtMi { get { return txtMiP.TextBox; } }

    private static readonly string[] FzPairKeys = new string[]
        { "an_ang", "en_eng", "in_ing", "ian_iang", "uan_uang" };
    private static readonly string[] FzPairTexts = new string[]
        { "an / ang", "en / eng", "in / ing", "ian / iang", "uan / uang" };

    private void BuildPagesSetVoiceMi()
    {
        BuildFuzzyCard();
        BuildKeysCard();
        BuildSetCards();
        BuildVoiceCard();
        BuildMiCard();
    }

    // ================================================================ 模糊音
    private void BuildFuzzyCard()
    {
        cardFuzzy = new AppleCard(
            "前后鼻音模糊输入（总开关 + 逐对：an/ang、en/eng、in/ing、ian/iang、uan/uang）",
            Theme.Bg, 12);

        chkFuzzy = new CheckBox();
        chkFuzzy.Text = "允许模糊输入（前鼻音当后鼻音打也能出词）";
        chkFuzzy.ForeColor = Theme.Text;
        chkFuzzy.AutoSize = true;

        lblFuzzyState = new Label();
        lblFuzzyState.AutoSize = false;

        lblFuzzyPairTitle = new Label();
        lblFuzzyPairTitle.Text = "逐对开关（关掉后这一对不再互相猜，其它对不受影响）：";
        lblFuzzyPairTitle.ForeColor = Theme.Sub;
        lblFuzzyPairTitle.Font = Theme.Hint;
        lblFuzzyPairTitle.AutoSize = true;

        for (int i = 0; i < 5; i++)
        {
            CheckBox c = new CheckBox();
            c.Text = FzPairTexts[i];
            c.ForeColor = Theme.Text;
            c.AutoSize = true;
            int idx = i;
            c.CheckedChanged += delegate
            {
                if (fzLoading) return;
                SetFzPair(idx, c.Checked);
                Data.SaveFuzzySettings();
                Status("「" + FzPairTexts[idx].Replace(" / ", "-") + "」模糊已保存：" +
                    (c.Checked ? "开" : "关") + "（下一次按键生效）");
            };
            chkFzPair[i] = c;
        }

        lblFuzzyHint = new Label();
        lblFuzzyHint.ForeColor = Theme.Sub;
        lblFuzzyHint.Font = Theme.Hint;
        lblFuzzyHint.Text =
            "开启时：只差前后鼻音的词照样上候选，排在精确匹配之后（例：输 yinda 先出「瘾大 因打」，再出「应 ying 答」）。\n" +
            "关闭时：只显示与输入完全一致的词（输 yinda 不再出应答）。\n" +
            "逐对开关单独控制对应的韵母对（总开关关闭时全部停用）；改动即时保存，下一次按键即生效，无需重启输入法。";

        cardFuzzy.Controls.Add(chkFuzzy);
        cardFuzzy.Controls.Add(lblFuzzyState);
        cardFuzzy.Controls.Add(lblFuzzyPairTitle);
        for (int i = 0; i < 5; i++) cardFuzzy.Controls.Add(chkFzPair[i]);
        cardFuzzy.Controls.Add(lblFuzzyHint);
        tabSet.Controls.Add(cardFuzzy);

        chkFuzzy.CheckedChanged += delegate
        {
            if (fzLoading) return;
            Data.FzMaster = chkFuzzy.Checked;
            Data.SaveFuzzySettings();
            UpdateFuzzyControls();
            Status("前后鼻音模糊已保存：" + (Data.FzMaster ? "开启" : "关闭") + "（下一次按键生效）");
        };
    }

    private void SetFzPair(int i, bool v)
    {
        switch (i)
        {
            case 0: Data.FzAnAng = v; break;
            case 1: Data.FzEnEng = v; break;
            case 2: Data.FzInIng = v; break;
            case 3: Data.FzIanIang = v; break;
            case 4: Data.FzUanUang = v; break;
        }
    }

    private bool GetFzPair(int i)
    {
        switch (i)
        {
            case 0: return Data.FzAnAng;
            case 1: return Data.FzEnEng;
            case 2: return Data.FzInIng;
            case 3: return Data.FzIanIang;
            default: return Data.FzUanUang;
        }
    }

    private void UpdateFuzzyControls()
    {
        if (chkFuzzy == null) return;
        fzLoading = true;
        try
        {
            chkFuzzy.Checked = Data.FzMaster;
            for (int i = 0; i < 5; i++)
            {
                chkFzPair[i].Checked = GetFzPair(i);
                chkFzPair[i].Enabled = Data.FzMaster;   // 总开关关掉时逐对灰掉
            }
            if (Data.FzMaster)
            {
                lblFuzzyState.Text = "当前：开启（模糊词保留并显示真实拼音）";
                lblFuzzyState.ForeColor = Theme.Green;
            }
            else
            {
                lblFuzzyState.Text = "当前：关闭（只显示与输入完全一致的词）";
                lblFuzzyState.ForeColor = Theme.Tert;
            }
        }
        finally { fzLoading = false; }
    }

    // ==================================================== 按键 / 英文候选
    private void BuildKeysCard()
    {
        cardKeys = new AppleCard("中英切换按键与英文候选（自定义）", Theme.Bg, 12);

        chkShiftR = new CheckBox();
        chkShiftR.Text = "右Shift 切换中英文（打到一半也能直接切过去）";
        chkShiftR.ForeColor = Theme.Text;
        chkShiftR.AutoSize = true;

        chkShiftL = new CheckBox();
        chkShiftL.Text = "左Shift 切换中英文";
        chkShiftL.ForeColor = Theme.Text;
        chkShiftL.AutoSize = true;

        lblKeysCaps = new Label();
        lblKeysCaps.Text = "CapsLock 按下时：";
        lblKeysCaps.ForeColor = Theme.Text;
        lblKeysCaps.AutoSize = true;

        fieldKeysCaps = new AppleField(160, 88, 150, 30, "", false, false, true);
        fieldKeysCaps.Combo.Items.AddRange(new object[] { "清空输入", "切换中英文", "屏蔽" });

        chkEnCand = new CheckBox();
        chkEnCand.Text = "中文模式显示英文候选（打英文时候选里可直接选英文词）";
        chkEnCand.ForeColor = Theme.Text;
        chkEnCand.AutoSize = true;

        chkSmartPunct = new CheckBox();
        chkSmartPunct.Text = "网址/路径智能标点（。→. 、→\\ 打网址和 D:\\路径不用切英文）";
        chkSmartPunct.ForeColor = Theme.Text;
        chkSmartPunct.AutoSize = true;

        lblEnState = new Label();
        lblEnState.AutoSize = false;

        lblKeysHint = new Label();
        lblKeysHint.ForeColor = Theme.Sub;
        lblKeysHint.Font = Theme.Hint;
        lblKeysHint.Text =
            "前三项按键改动会在保存时自动重启输入法服务（约 2 秒，正在打字请先停手）。\n" +
            "英文候选开关即时生效：关闭后 hello / OK 这类纯英文词条不再出现在候选里，含中文的词条不受影响；输入法 v 菜单、剪贴板列表也不会被它误伤。\n" +
            "智能标点即时生效：网址（www.a.com）里的 。 自动出 .、路径（D:\\软件）里自动出 : 和 \\，关掉即恢复原生标点。";

        cardKeys.Controls.Add(chkShiftR);
        cardKeys.Controls.Add(chkShiftL);
        cardKeys.Controls.Add(lblKeysCaps);
        cardKeys.Controls.Add(fieldKeysCaps);
        cardKeys.Controls.Add(chkEnCand);
        cardKeys.Controls.Add(chkSmartPunct);
        cardKeys.Controls.Add(lblEnState);
        cardKeys.Controls.Add(lblKeysHint);
        tabSet.Controls.Add(cardKeys);

        chkShiftR.CheckedChanged += delegate
        {
            if (keysLoading) return;
            Data.ShiftR = chkShiftR.Checked;
            ApplyKeys("右Shift 切换中英文");
        };
        chkShiftL.CheckedChanged += delegate
        {
            if (keysLoading) return;
            Data.ShiftL = chkShiftL.Checked;
            ApplyKeys("左Shift 切换中英文");
        };
        fieldKeysCaps.Combo.SelectedIndexChanged += delegate
        {
            if (keysLoading) return;
            int i = fieldKeysCaps.Combo.SelectedIndex;
            Data.CapsBehavior = i == 1 ? "commit_code" : (i == 2 ? "noop" : "clear");
            ApplyKeys("CapsLock 行为");
        };
        chkEnCand.CheckedChanged += delegate
        {
            if (candLoading) return;
            Data.EnCandidates = chkEnCand.Checked;
            Data.SaveCandSettings();
            UpdateEnState();
            Status("英文候选已保存：" + (Data.EnCandidates ? "显示" : "隐藏") + "（下一次按键生效）");
        };
        chkSmartPunct.CheckedChanged += delegate
        {
            if (candLoading) return;
            Data.SmartPunct = chkSmartPunct.Checked;
            Data.SaveSmartPunctSettings();
            Status("智能标点已保存：" + (Data.SmartPunct ? "开" : "关") + "（1 秒内生效，不用重启）");
        };
    }

    private void UpdateEnState()
    {
        if (Data.EnCandidates)
        {
            lblEnState.Text = "当前：显示英文候选";
            lblEnState.ForeColor = Theme.Green;
        }
        else
        {
            lblEnState.Text = "当前：隐藏英文候选";
            lblEnState.ForeColor = Theme.Tert;
        }
    }

    private void UpdateKeysControls()
    {
        if (chkShiftR == null) return;
        keysLoading = true;
        candLoading = true;
        try
        {
            chkShiftR.Checked = Data.ShiftR;
            chkShiftL.Checked = Data.ShiftL;
            fieldKeysCaps.Combo.SelectedIndex =
                Data.CapsBehavior == "commit_code" ? 1 : (Data.CapsBehavior == "noop" ? 2 : 0);
            chkEnCand.Checked = Data.EnCandidates;
            chkSmartPunct.Checked = Data.SmartPunct;
            UpdateEnState();
        }
        finally { keysLoading = false; candLoading = false; }
    }

    private void ApplyKeys(string what)
    {
        Status(what + " 已保存，正在重启输入法服务（约 2 秒）…");
        Thread t = new Thread(delegate()
        {
            Data.ApplyKeysAndRestart();
            try
            {
                BeginInvoke(new MethodInvoker(delegate
                {
                    Status(what + " 已生效（输入法服务已重启）");
                }));
            }
            catch { }
        });
        t.IsBackground = true;
        t.Start();
    }

    // ================================================ 设置与缓存页其它卡片
    private void BuildSetCards()
    {
        // --- 默认显示条数 ---
        cardPage = new AppleCard("剪贴板列表默认显示条数", Theme.Bg, 12);
        lblPage = new Label();
        lblPage.Text = "默认显示：";
        lblPage.ForeColor = Theme.Text;
        lblPage.AutoSize = true;
        cmbPageP = new AppleField(90, 30, 92, 30, "", false, false, true);
        cmbPage.Items.AddRange(new object[] { "20", "30", "40", "50" });
        btnPageSave = AppleButton.Make("保存", "Primary", 88, 30);
        lblPageHint = new Label();
        lblPageHint.ForeColor = Theme.Sub;
        lblPageHint.Font = Theme.Hint;
        lblPageHint.Text =
            "20 条是下限、50 条是上限（超出部分自动丢弃最旧的）。\n" +
            "在输入法剪贴板列表里按 m 键（或 + 键）每次多看 10 条，翻页用 - / = 或鼠标滚轮。";
        cardPage.Controls.AddRange(new Control[] { lblPage, cmbPageP, btnPageSave, lblPageHint });

        // --- 缓存清理（破坏性卡片：标题红、按钮实心红）---
        cardClear = new AppleCard("缓存清理（二次确认）", Theme.Bg, 12);
        cardClear.TitleColor = Theme.Danger;
        lblClear = new Label();
        lblClear.ForeColor = Theme.Sub;
        lblClear.Text = "清空剪贴板历史缓存：删除 clipboard-cache.txt 里的全部内容，不可恢复。";
        btnClearClip = AppleButton.Make("清理剪贴板缓存", "Danger", 170, 32);
        btnClearFav = AppleButton.Make("清空全部常用语", "Danger", 170, 32);
        cardClear.Controls.AddRange(new Control[] { lblClear, btnClearClip, btnClearFav });

        // --- 文件位置 ---
        cardFiles = new AppleCard("文件位置（改动即时写入）", Theme.Bg, 12);
        tbFilesP = new AppleField(18, 32, 860, 134, "", true, true, false);
        tbFiles.Text =
            "剪贴板历史：" + Data.ClipPath + "\r\n" +
            "常用语：" + Data.FavPath + "\r\n" +
            "个人词库：" + Data.MydictPath + "\r\n" +
            "设置：" + Data.SetPath + "\r\n" +
            "语音设置：" + Data.VoiceSetPath + "\r\n" +
            "模糊音设置：" + Data.FuzzySetPath + "\r\n" +
            "英文候选设置：" + Data.CandSetPath + "\r\n" +
            "中英切换按键：" + Data.DefaultCustomPath + "\r\n" +
            "\r\n" +
            "提示：改完这里的内容后无需重启输入法；输入法每次打开 v 菜单都会重新读取。\r\n" +
            "若在输入法里改了内容想在这里看到，点「重新载入」即可。";
        cardFiles.Controls.Add(tbFilesP);

        // --- 小狼毫原生设置 ---
        cardNative = new AppleCard("小狼毫原生设置", Theme.Bg, 12);
        lblNative = new Label();
        lblNative.ForeColor = Theme.Sub;
        lblNative.Text =
            "托盘图标右键菜单里的「输入法设置 (S)」打开的就是本窗口。\n" +
            "小狼毫自带的设置对话框（配色 / 字体 / 候选窗口样式）用下面的按钮打开。";
        btnNative = AppleButton.Make("打开小狼毫原生设置", "Primary", 200, 32);
        cardNative.Controls.AddRange(new Control[] { lblNative, btnNative });

        tabSet.Controls.Add(cardPage);
        tabSet.Controls.Add(cardClear);
        tabSet.Controls.Add(cardFiles);
        tabSet.Controls.Add(cardNative);

        btnPageSave.Click += delegate
        {
            if (cmbPage.SelectedItem == null) return;
            int v;
            if (!int.TryParse(cmbPage.SelectedItem.ToString(), out v)) return;
            if (v < Data.MinPage) v = Data.MinPage;
            if (v > Data.MaxPage) v = Data.MaxPage;
            Data.PageSize = v;
            Data.SaveAllSettings();
            RefreshClipboard();
            Status("默认显示条数已保存为 " + v + " 条");
        };

        btnClearClip.Click += delegate
        {
            if (!Confirm("确定清理剪贴板历史缓存？\n\n这会删除 clipboard-cache.txt 的全部内容，不可恢复。",
                "清理缓存 · 二次确认")) return;
            clip.Clear();
            Data.SaveClipboard(clip);
            RefreshClipboard();
            Status("剪贴板缓存已清理");
        };

        btnClearFav.Click += delegate
        {
            if (!Confirm("确定清空全部常用语？\n\n这会删除 favorites.dict.yaml 里的全部词条，不可恢复。",
                "清空常用语 · 二次确认")) return;
            favs.Clear();
            Data.SaveFavorites(favs);
            RefreshFavorites();
            Status("常用语已清空");
        };

        btnNative.Click += delegate
        {
            string dir = @"C:\Program Files\Rime\weasel-0.17.4";
            string real = Path.Combine(dir, "WeaselDeployer.real.exe");
            if (!File.Exists(real)) real = Path.Combine(dir, "WeaselDeployer.exe");
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(real);
                psi.UseShellExecute = true;
                Process.Start(psi);
                Status("已打开小狼毫原生设置");
            }
            catch
            {
                Info("打不开：\r\n" + real, "vmenu");
            }
        };
    }

    // ================================================================ 语音
    private void BuildVoiceCard()
    {
        cardPunct = new AppleCard("识别结果里的标点符号", Theme.Bg, 12);
        chkPunct = new CheckBox();
        chkPunct.Text = "把标点符号转换成空格（，。！？、；：… → 空格）";
        chkPunct.ForeColor = Theme.Text;
        chkPunct.AutoSize = true;

        lblPunctState = new Label();
        lblPunctState.ForeColor = Theme.Green;
        lblPunctState.AutoSize = false;

        lblPunctHint = new Label();
        lblPunctHint.ForeColor = Theme.Sub;
        lblPunctHint.Font = Theme.Hint;
        lblPunctHint.Text =
            "勾选后：识别出的「今天天气真好，我们去散步吧。」→「今天天气真好 我们去散步吧」。\n" +
            "数字里的小数点 / 千分位（3.14、1,000）不会被拆开。\n" +
            "改动即时保存，下一次语音识别即生效（流式增量与最终结果同步生效），无需重启悬浮球。";

        cardPunct.Controls.Add(chkPunct);
        cardPunct.Controls.Add(lblPunctState);
        cardPunct.Controls.Add(lblPunctHint);
        tabVoice.Controls.Add(cardPunct);

        chkPunct.CheckedChanged += delegate
        {
            if (voiceLoading) return;
            Data.PunctSpace = chkPunct.Checked;
            Data.SaveVoiceSettings();
            UpdatePunctState();
            Status("语音设置已保存：" +
                (Data.PunctSpace ? "标点转空格（下一次识别生效）" : "保留标点（下一次识别生效）"));
        };

        // ===== 语音输入快捷键卡片 =====
        // 点「点击录制」-> 直接在键盘上按想要的组合 -> 松开即录入并保存。
        // 录制用 20ms 轮询 GetAsyncKeyState（不装任何键盘钩子），焦点在哪都录得到；
        // 录制期间悬浮球会暂停热键检测（pid 字段），录完自动恢复。
        cardHotkey = new AppleCard("语音输入快捷键（按住说话）", Theme.Bg, 12);

        lblHotCur = new Label();
        lblHotCur.Text = "当前快捷键：";
        lblHotCur.ForeColor = Theme.Text;
        lblHotCur.AutoSize = true;

        btnHotkey = AppleButton.Make("点击录制", "Primary", 330, 40);
        btnHotkey.Font = new Font("Microsoft YaHei UI", 10.5f, FontStyle.Bold);

        btnHotReset = AppleButton.Make("↺ 恢复默认", "Plain", 140, 34);
        btnHotReset.Font = new Font("Segoe UI Symbol", 10f);

        lblHotState = new Label();
        lblHotState.ForeColor = Theme.Green;
        lblHotState.AutoSize = true;

        lblHotHint = new Label();
        lblHotHint.ForeColor = Theme.Sub;
        lblHotHint.Font = Theme.Hint;
        lblHotHint.Text =
            "点「点击录制」后，直接在键盘上按下想要的组合（例如 Ctrl + Alt + 空格），松开即录入；" +
            "按 Esc 或再点一次按钮取消。\n" +
            "必须包含 Ctrl / Alt / Win 之一。按住期间目标软件也会收到这些按键，别选复制/粘贴这类会真执行的组合。\n" +
            "改完立即保存并生效（悬浮球每 0.4 秒看一次配置，无需重启）；录制期间悬浮球会自动暂停检测。";

        hotTimer = new System.Windows.Forms.Timer();
        hotTimer.Interval = 20;
        hotTimer.Tick += HotTimer_Tick;

        cardHotkey.Controls.AddRange(new Control[]
        {
            lblHotCur, btnHotkey, btnHotReset, lblHotState, lblHotHint
        });
        tabVoice.Controls.Add(cardHotkey);

        btnHotkey.Click += delegate { StartHotkeyRecord(); };
        btnHotReset.Click += delegate
        {
            if (hotState != "") StopHotkeyRecord("已取消录制");
            Data.Hotkey = HotkeyKit.Default;
            Data.SaveVoiceSettings();
            string disp = HotkeyKit.Display(HotkeyKit.FromConfig(Data.Hotkey));
            btnHotkey.Text = disp;
            lblHotState.Text = "已恢复默认：" + disp + "（按住说话）";
            lblHotState.ForeColor = Theme.Green;
            Status("语音快捷键已恢复默认：" + disp);
        };
    }

    // 录制收尾：停表、清状态，**最重要的是把 hotkey_recorder_pid 清掉并写回文件**，
    // 否则悬浮球会一直以为在录制、快捷键就废了。
    private void StopHotkeyRecord(string reason)
    {
        if (hotTimer != null) hotTimer.Stop();
        hotState = "";
        Data.HotkeyRecPid = 0;
        Data.SaveVoiceSettings();
        string disp = HotkeyKit.Display(HotkeyKit.FromConfig(Data.Hotkey));
        btnHotkey.Text = disp;
        if (reason != null && reason.Length > 0)
        {
            lblHotState.Text = reason + " · 当前仍为 " + disp;
            lblHotState.ForeColor = Theme.Tert;
            Status("语音快捷键：" + reason);
        }
    }

    private void StartHotkeyRecord()
    {
        if (hotState != "") { StopHotkeyRecord("已取消录制"); return; }   // 再点一次 = 取消
        Data.HotkeyRecPid = System.Diagnostics.Process.GetCurrentProcess().Id;
        Data.SaveVoiceSettings();                       // 让悬浮球开始暂停检测
        hotState = "lead";
        hotGot = new List<int>();
        hotLeadUntil = DateTime.Now.AddMilliseconds(650);   // 给悬浮球 0.4s 检查窗口
        hotEndAt = DateTime.Now.AddSeconds(20);
        btnHotkey.Text = "准备中…";
        lblHotState.Text = "正在暂停悬浮球的快捷键检测…";
        lblHotState.ForeColor = Theme.Tert;
        ActiveControl = null;                           // 别让空格/回车顺手触发按钮自身
        hotTimer.Start();
    }

    private void HotTimer_Tick(object sender, EventArgs e)
    {
        if (hotState == "") { hotTimer.Stop(); return; }
        if (DateTime.Now > hotEndAt) { StopHotkeyRecord("录制超时"); return; }
        List<int> down = HotkeyKit.DownVks();
        if (down.Contains(0x1B)) { StopHotkeyRecord("已取消（按了 Esc）"); return; }

        if (hotState == "lead")
        {
            if (DateTime.Now >= hotLeadUntil)
            {
                hotState = "up";
                btnHotkey.Text = "请先松开所有键…";
                lblHotState.Text = "松开所有键之后，按下你想要的快捷键（例如 Ctrl + Alt + 空格）";
                lblHotState.ForeColor = Theme.Text;
            }
        }
        else if (hotState == "up")
        {
            if (down.Count == 0)
            {
                hotState = "press";
                btnHotkey.Text = "请按下新的快捷键…";
                lblHotState.Text = "按住不放，可以继续加键；全部松开即录入";
                lblHotState.ForeColor = Theme.Text;
            }
        }
        else if (hotState == "press")
        {
            if (down.Count > 0)
            {
                hotGot = new List<int>(down);
                hotState = "collect";
                btnHotkey.Text = HotkeyKit.Display(HotkeyKit.ToTokens(down)) + "  +…";
                lblHotState.Text = "可以继续加键，全部松开即完成";
                lblHotState.ForeColor = Theme.Text;
            }
        }
        else if (hotState == "collect")
        {
            foreach (int vk in down) { if (!hotGot.Contains(vk)) hotGot.Add(vk); }
            if (down.Count == 0)
            {
                hotTimer.Stop();
                List<string> tokens = HotkeyKit.ToTokens(hotGot);
                string err = HotkeyKit.Test(tokens);
                string disp = HotkeyKit.Display(tokens);
                hotState = "";
                Data.HotkeyRecPid = 0;
                if (err != null)
                {
                    Data.SaveVoiceSettings();      // 存回旧值，同时清掉 pid 字段
                    string cur = HotkeyKit.Display(HotkeyKit.FromConfig(Data.Hotkey));
                    btnHotkey.Text = cur;
                    lblHotState.Text = "没保存：" + err + "（当前仍是 " + cur + "）";
                    lblHotState.ForeColor = Theme.Danger;
                    Status("语音快捷键没保存：" + err);
                }
                else
                {
                    Data.Hotkey = string.Join("+", tokens.ToArray());
                    Data.SaveVoiceSettings();      // 新值 + 清 pid，一次写完
                    btnHotkey.Text = disp;
                    string risk = HotkeyKit.Risk(tokens);
                    if (risk != null)
                    {
                        lblHotState.Text = "已保存：" + disp + " ｜ " + risk;
                        lblHotState.ForeColor = Color.FromArgb(255, 149, 0);  // systemOrange
                    }
                    else
                    {
                        lblHotState.Text = "已保存：" + disp + "（按住说话，下一次按键生效）";
                        lblHotState.ForeColor = Theme.Green;
                    }
                    Status("语音快捷键已保存：" + disp);
                }
                return;
            }
        }
    }

    private void UpdatePunctState()
    {
        lblPunctState.Text = "当前：" + (Data.PunctSpace ? "标点 → 空格" : "保留标点");
        lblPunctState.ForeColor = Data.PunctSpace ? Theme.Green : Theme.Tert;
    }

    private void UpdateVoiceControls()
    {
        if (chkPunct == null) return;
        voiceLoading = true;
        try
        {
            chkPunct.Checked = Data.PunctSpace;
            UpdatePunctState();
        }
        finally { voiceLoading = false; }
        // 快捷键显示（正在录制时别把进行中的提示刷掉）
        if (btnHotkey == null) return;
        if (hotState != "") return;
        string disp = HotkeyKit.Display(HotkeyKit.FromConfig(Data.Hotkey));
        btnHotkey.Text = disp;
        lblHotState.Text = "当前：" + disp + "（长按说话，松开结束）";
        lblHotState.ForeColor = Theme.Green;
    }

    // ================================================================ 防误触
    private void BuildMiCard()
    {
        cardMi = new AppleCard("防误触（间隔太短的连续按键自动吞掉）", Theme.Bg, 12);

        chkMiEnable = new CheckBox();
        chkMiEnable.Text = "启用防误触";
        chkMiEnable.ForeColor = Theme.Text;
        chkMiEnable.AutoSize = true;

        lblMiInterval = new Label();
        lblMiInterval.Text = "最小间隔（毫秒）：";
        lblMiInterval.ForeColor = Theme.Text;
        lblMiInterval.AutoSize = true;

        txtMiP = new AppleField(152, 66, 74, 30, "", false, false, false);
        txtMi.TextAlign = HorizontalAlignment.Center;

        lblMiRange = new Label();
        lblMiRange.Text = "（范围 " + Data.MiMin + " ~ " + Data.MiMax + " ms，推荐 " +
            Data.MiDefault + " ms）";
        lblMiRange.ForeColor = Theme.Sub;
        lblMiRange.AutoSize = true;

        // 恢复推荐值：↺（逆时针圆环箭头）
        btnMiReset = AppleButton.Make("↺ 恢复推荐", "Plain", 130, 30);
        btnMiReset.Font = Theme.Sym;

        trkMi = new TrackBar();
        trkMi.Minimum = Data.MiMin;
        trkMi.Maximum = Data.MiMax;
        trkMi.TickFrequency = 10;
        trkMi.SmallChange = 5;
        trkMi.LargeChange = 10;
        trkMi.BackColor = Theme.White;

        lblMiRec = new Label();
        lblMiRec.ForeColor = Theme.RecBlue;
        lblMiRec.Text = "推荐 " + Data.MiDefault + " ms：人类最快打字约 300 ms/键、反应时间约 150 ms， 30 ms\n" +
            "远在人类极限之下，只拦键盘抖动与手滑连击；点 ↺ 恢复推荐。";

        lblMiState = new Label();
        lblMiState.ForeColor = Theme.Green;
        lblMiState.AutoSize = false;

        btnMiSave = AppleButton.Make("保存", "Primary", 110, 30);

        cardMi.Controls.AddRange(new Control[]
        {
            chkMiEnable, lblMiInterval, txtMiP, lblMiRange, btnMiReset,
            trkMi, lblMiRec, lblMiState, btnMiSave
        });
        tabMi.Controls.Add(cardMi);

        trkMi.ValueChanged += delegate { txtMi.Text = trkMi.Value.ToString(); };
        txtMi.TextChanged += delegate
        {
            int v;
            if (int.TryParse(txtMi.Text, out v) && v >= Data.MiMin && v <= Data.MiMax)
            {
                if (trkMi.Value != v) trkMi.Value = v;
            }
        };
        btnMiReset.Click += delegate
        {
            chkMiEnable.Checked = true;
            trkMi.Value = Data.MiDefault;
            txtMi.Text = Data.MiDefault.ToString();
            Status("已恢复推荐：启用 · " + Data.MiDefault + " ms（点保存生效）");
        };
        btnMiSave.Click += delegate
        {
            int v;
            if (!int.TryParse(txtMi.Text, out v)) v = Data.MiDefault;
            if (v < Data.MiMin) v = Data.MiMin;
            if (v > Data.MiMax) v = Data.MiMax;
            Data.MiEnabled = chkMiEnable.Checked;
            Data.MiInterval = v;
            Data.SaveAllSettings();
            UpdateMiControls();
            Status("防误触已保存：" + (Data.MiEnabled ? "启用" : "关闭") + " · " + v + " ms");
        };
    }

    private void UpdateMiControls()
    {
        if (chkMiEnable == null) return;
        chkMiEnable.Checked = Data.MiEnabled;
        int n = Data.MiInterval;
        if (n < Data.MiMin) n = Data.MiMin;
        if (n > Data.MiMax) n = Data.MiMax;
        trkMi.Value = n;
        txtMi.Text = n.ToString();
        if (Data.MiEnabled)
        {
            lblMiState.Text = "当前：启用 · " + n + " ms";
            lblMiState.ForeColor = Theme.Green;
        }
        else
        {
            lblMiState.Text = "当前：关闭 · " + n + " ms";
            lblMiState.ForeColor = Theme.Tert;
        }
    }

    // ================================================================ 布局
    private void LayoutSet()
    {
        int ws = tabSet.ClientSize.Width;
        if (ws < 480) ws = 960;
        int cws = ws - 32;
        int y = 16;

        // 模糊音卡片（总开关 + 5 对逐对开关）
        cardFuzzy.SetBounds(16, y, cws, 216);
        chkFuzzy.Location = new Point(18, 34);
        lblFuzzyState.SetBounds(cws - 340, 36, 320, 20);
        lblFuzzyPairTitle.Location = new Point(18, 64);
        for (int i = 0; i < 5; i++) chkFzPair[i].Location = new Point(18 + i * 136, 86);
        lblFuzzyHint.SetBounds(18, 116, cws - 36, 92);
        y += 216 + 12;

        // 按键 / 英文候选卡片
        cardKeys.SetBounds(16, y, cws, 268);
        chkShiftR.Location = new Point(18, 32);
        chkShiftL.Location = new Point(18, 60);
        lblKeysCaps.Location = new Point(18, 94);
        fieldKeysCaps.SetBounds(150, 90, 160, 30);
        chkEnCand.Location = new Point(18, 132);
        lblEnState.SetBounds(cws - 320, 134, 304, 20);
        chkSmartPunct.Location = new Point(18, 160);
        lblKeysHint.SetBounds(18, 192, cws - 36, 64);
        y += 268 + 12;

        // 默认显示条数
        cardPage.SetBounds(16, y, cws, 136);
        lblPage.Location = new Point(18, 36);
        cmbPageP.SetBounds(90, 30, 92, 30);
        btnPageSave.SetBounds(192, 30, 88, 30);
        lblPageHint.SetBounds(18, 74, cws - 36, 56);
        y += 136 + 12;

        // 缓存清理
        cardClear.SetBounds(16, y, cws, 116);
        lblClear.SetBounds(18, 34, cws - 36, 36);
        btnClearClip.SetBounds(18, 76, 170, 32);
        btnClearFav.SetBounds(200, 76, 170, 32);
        y += 116 + 12;

        // 文件位置
        cardFiles.SetBounds(16, y, cws, 176);
        tbFilesP.SetBounds(18, 32, cws - 36, 134);
        y += 176 + 12;

        // 小狼毫原生设置
        cardNative.SetBounds(16, y, cws, 110);
        lblNative.SetBounds(18, 34, cws - 36, 36);
        btnNative.SetBounds(18, 74, 200, 32);
    }

    private void LayoutVoice()
    {
        int wv = tabVoice.ClientSize.Width;
        if (wv < 480) wv = 960;
        int cwv = wv - 32;
        cardPunct.SetBounds(16, 16, cwv, 170);
        chkPunct.Location = new Point(18, 34);
        lblPunctState.SetBounds(cwv - 320, 36, 300, 20);
        lblPunctHint.SetBounds(18, 68, cwv - 36, 92);
        // 快捷键卡片：按钮一行 + 状态一行 + 说明三行
        cardHotkey.SetBounds(16, 196, cwv, 196);
        lblHotCur.SetBounds(18, 42, 130, 24);
        btnHotkey.SetBounds(150, 32, 330, 40);
        btnHotReset.SetBounds(494, 35, 140, 34);
        lblHotState.SetBounds(18, 84, cwv - 36, 24);
        lblHotHint.SetBounds(18, 114, cwv - 36, 74);
    }

    private void LayoutMi()
    {
        int wm = tabMi.ClientSize.Width;
        if (wm < 480) wm = 960;
        int cwm = wm - 32;
        cardMi.SetBounds(16, 16, cwm, 240);
        chkMiEnable.Location = new Point(18, 32);
        lblMiInterval.Location = new Point(18, 70);
        txtMiP.SetBounds(152, 66, 74, 30);
        lblMiRange.Location = new Point(236, 70);
        lblMiState.SetBounds(cwm - 268, 32, 252, 22);
        int trkW = cwm - 194;
        if (trkW < 200) trkW = 200;
        trkMi.SetBounds(18, 104, trkW, 45);
        btnMiReset.SetBounds(cwm - 164, 116, 130, 30);
        lblMiRec.SetBounds(18, 158, cwm - 36, 40);
        btnMiSave.SetBounds(cwm - 126, 200, 110, 30);
    }
}
