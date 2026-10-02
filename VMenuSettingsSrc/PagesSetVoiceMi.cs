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
    private AppleCard cardFuzzy, cardKeys, cardPage, cardGrid, cardClear, cardFiles, cardNative;
    private CheckBox chkFuzzy;
    private Label lblFuzzyState, lblFuzzyHint, lblFuzzyPairTitle;
    private CheckBox[] chkFzPair = new CheckBox[5];
    private CheckBox chkShiftR, chkShiftL, chkEnCand, chkSmartPunct;
    private Label lblKeysCaps, lblKeysHint, lblEnState;
    private AppleField fieldKeysCaps;
    private Label lblPage, lblPageHint, lblClear, lblNative;
    private AppleField cmbPageP;
    private AppleButton btnPageSave, btnClearClip, btnClearFav, btnNative;

    // ---- 候选栏每行数量（grid-settings.txt）----
    private AppleField cmbGridCollapsedP, cmbGridExpandedP;
    private AppleButton btnGridSave;
    private Label lblGridCollapsed, lblGridExpanded, lblGridHint, lblGridState;
    private ComboBox cmbGridCollapsed { get { return cmbGridCollapsedP.Combo; } }
    private ComboBox cmbGridExpanded { get { return cmbGridExpandedP.Combo; } }
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
    private string hotState = "";            // "" | press | collect（lead/up 准备阶段已去掉）
    private List<int> hotGot = new List<int>();
    private DateTime hotEndAt = DateTime.MinValue;

    // ---- 语音识别设备卡片（GPU 加速）----
    private AppleCard cardDevice;
    private AppleField cmbDeviceP;
    private Label lblDevCur, lblDevState, lblDevHint;
    private ComboBox cmbDevice { get { return cmbDeviceP.Combo; } }

    // ---- 语音识别 CPU 占用卡片（线程数滑块）----
    private AppleCard cardCpu;
    private TrackBar trkCpu;
    private Label lblCpuCur, lblCpuHint;

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

        // --- 候选栏每行数量（写 grid-settings.txt，服务端与 lua 共读）---
        cardGrid = new AppleCard("候选栏每行数量", Theme.Bg, 12);

        lblGridCollapsed = new Label();
        lblGridCollapsed.Text = "未展开时每行：";
        lblGridCollapsed.ForeColor = Theme.Text;
        lblGridCollapsed.AutoSize = true;
        cmbGridCollapsedP = new AppleField(110, 30, 92, 30, "", false, false, true);
        cmbGridCollapsed.Items.AddRange(new object[] { "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12" });

        lblGridExpanded = new Label();
        lblGridExpanded.Text = "展开栏每行：";
        lblGridExpanded.ForeColor = Theme.Text;
        lblGridExpanded.AutoSize = true;
        cmbGridExpandedP = new AppleField(110, 30, 92, 30, "", false, false, true);
        cmbGridExpanded.Items.AddRange(new object[] { "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12" });

        btnGridSave = AppleButton.Make("保存", "Primary", 88, 30);

        lblGridState = new Label();
        lblGridState.ForeColor = Theme.Tert;
        lblGridState.Font = Theme.Hint;
        lblGridState.Text = "";

        lblGridHint = new Label();
        lblGridHint.ForeColor = Theme.Sub;
        lblGridHint.Font = Theme.Hint;
        lblGridHint.Text =
            "「未展开时每行」= 平时那条单行候选显示几个；\n" +
            "「展开栏每行」= 按 ↓ 展开成多行网格后，每行显示几个（默认 6）。\n" +
            "保存后即时生效，不用重启输入法；正在输入的候选栏会在下一次按键时按新列数排版。";
        cardGrid.Controls.AddRange(new Control[] {
            lblGridCollapsed, cmbGridCollapsedP,
            lblGridExpanded, cmbGridExpandedP,
            btnGridSave, lblGridState, lblGridHint });

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
        tabSet.Controls.Add(cardGrid);
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

        // 候选栏每行数量：写 grid-settings.txt。
        // 服务端（RimeWithWeasel.cpp 的 _GridCfgCached）和 lua（vmenu_core.lua 的
        // M.grid_cfg）都带 1 秒 TTL 缓存，所以保存后最多 1 秒生效，不用重启。
        btnGridSave.Click += delegate
        {
            int c, e;
            if (cmbGridCollapsed.SelectedItem == null || cmbGridExpanded.SelectedItem == null) return;
            if (!int.TryParse(cmbGridCollapsed.SelectedItem.ToString(), out c)) return;
            if (!int.TryParse(cmbGridExpanded.SelectedItem.ToString(), out e)) return;
            if (c < Data.GridColsMin) c = Data.GridColsMin;
            if (c > Data.GridColsMax) c = Data.GridColsMax;
            if (e < Data.GridColsMin) e = Data.GridColsMin;
            if (e > Data.GridColsMax) e = Data.GridColsMax;
            Data.GridColsCollapsed = c;
            Data.GridColsExpanded = e;
            Data.SaveGridSettings();
            RefreshGridState();
            Status("候选栏每行数量已保存：未展开 " + c + " 个 / 展开 " + e + " 个");
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

        // ===== 语音识别设备卡片（GPU 加速）=====
        // GPU 走 llama.cpp 的 CUDA 后端。实测 RTX 5060 Laptop（同一段 6.2 秒语音）：
        //   GPU -> 0.19 秒、整机 CPU 11%      CPU -> 0.43 秒、整机 CPU 26%
        // 识别结果逐字一致（同一份模型权重，只是算力位置不同）。
        // 默认 auto：探测到可用 GPU 就自动用，否则静默回落 CPU，用户不用管。
        cardDevice = new AppleCard("语音识别设备（GPU 加速）", Theme.Bg, 12);

        cmbDeviceP = new AppleField(0, 0, 260, 30, "", false, false, true);
        cmbDevice.Items.AddRange(new object[] { "自动（推荐）", "仅 CPU", "强制 GPU" });
        cmbDevice.SelectedIndex = 0;

        lblDevCur = new Label();
        lblDevCur.ForeColor = Theme.Text;
        lblDevCur.AutoSize = false;

        lblDevState = new Label();
        lblDevState.ForeColor = Theme.Green;
        lblDevState.AutoSize = false;

        lblDevHint = new Label();
        lblDevHint.ForeColor = Theme.Sub;
        lblDevHint.Font = Theme.Hint;

        cardDevice.Controls.Add(cmbDeviceP);
        cardDevice.Controls.Add(lblDevCur);
        cardDevice.Controls.Add(lblDevState);
        cardDevice.Controls.Add(lblDevHint);
        tabVoice.Controls.Add(cardDevice);

        cmbDevice.SelectedIndexChanged += delegate
        {
            if (voiceLoading) return;
            Data.AsrDevice = DeviceFromCombo();
            Data.SaveVoiceSettings();
            UpdateDeviceState();
            UpdateCpuState();
            Status("识别设备已保存：" + cmbDevice.SelectedItem +
                "（重新打开一次语音输入后生效）");
        };

        // ===== 语音识别 CPU 占用卡片（线程数）=====
        // llama.cpp 默认按逻辑核数开线程（16 核机就是 16 线程），多核空转自旋会把
        // 整机 CPU 打到 ~59%、瞬时打满；限制到物理核以内实测降到 ~26%，
        // 而且**总 CPU 消耗反而少 54%**（省掉超订线程的同步开销），墙钟只慢约 15ms。
        // 识别率完全不变：同一份权重，只改并行度。
        cardCpu = new AppleCard("语音识别 CPU 占用", Theme.Bg, 12);

        trkCpu = new TrackBar();
        trkCpu.Minimum = 1;
        trkCpu.Maximum = Math.Max(1, Data.PhysCores());
        trkCpu.TickFrequency = 1;
        trkCpu.SmallChange = 1;
        trkCpu.LargeChange = 1;
        trkCpu.AutoSize = false;
        trkCpu.Height = 34;

        lblCpuCur = new Label();
        lblCpuCur.ForeColor = Theme.Green;
        lblCpuCur.AutoSize = false;

        lblCpuHint = new Label();
        lblCpuHint.ForeColor = Theme.Sub;
        lblCpuHint.Font = Theme.Hint;
        lblCpuHint.Text =
            "识别线程数越少，CPU 占用越低，识别会略慢一点（模型和识别率完全不变）。\n" +
            "默认 4 线程，实测整机占用约 26%（原来 16 线程约 59%，且总耗电更高）。\n" +
            "本机物理核数：" + Data.PhysCores() + " —— 超过物理核只会空转自旋，越开越慢。\n" +
            "用 GPU 时这项不生效（GPU 推理 CPU 只做前后处理）；改动重启悬浮球后生效。";

        cardCpu.Controls.Add(trkCpu);
        cardCpu.Controls.Add(lblCpuCur);
        cardCpu.Controls.Add(lblCpuHint);
        tabVoice.Controls.Add(cardCpu);

        trkCpu.Scroll += delegate
        {
            if (voiceLoading) return;
            Data.AsrThreads = trkCpu.Value;
            Data.SaveVoiceSettings();
            UpdateCpuState();
            Status("语音识别线程数已保存：" + Data.AsrThreads + "（重启悬浮球后生效）");
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
        // [去掉准备时间] 原实现分两段等待：
        //   "lead"：固定等 650ms（等悬浮球检测线程进入暂停态）；
        //   "up"  ：等用户把「刚才点按钮的那一下」松开，然后才允许录入。
        // 用户反馈这两段等待完全没有必要 —— 点完按钮就想直接按组合键。
        // 现在直接进 "press"：立刻开始收录按键。悬浮球的暂停由
        // Data.SaveVoiceSettings() 写盘 + 悬浮球自己轮询完成，不需要我们空等。
        hotState = "press";
        hotGot = new List<int>();
        hotEndAt = DateTime.Now.AddSeconds(20);
        btnHotkey.Text = "请按下新的快捷键…";
        lblHotState.Text = "按住不放，可以继续加键；全部松开即录入";
        lblHotState.ForeColor = Theme.Text;
        ActiveControl = null;                           // 别让空格/回车顺手触发按钮自身
        hotTimer.Start();
    }

    private void HotTimer_Tick(object sender, EventArgs e)
    {
        if (hotState == "") { hotTimer.Stop(); return; }
        if (DateTime.Now > hotEndAt) { StopHotkeyRecord("录制超时"); return; }
        List<int> down = HotkeyKit.DownVks();
        if (down.Contains(0x1B)) { StopHotkeyRecord("已取消（按了 Esc）"); return; }

        // [去掉准备时间] 原来的 "lead" / "up" 两个等待阶段已删除，
        // 进入录制就是 "press"，按下即开始收录。
        if (hotState == "press")
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

    // ---- GPU 探测 ----
    // 三重检查缺一不可：只有显卡名不够 —— CPU 版包里没有 CUDA dll，
    // 开了 -ngl 起来就是失败。必须在 UI 上把「为什么没生效」讲清楚，
    // 否则用户只会觉得「选了 GPU 却没变快」。
    private string gpuName = "";
    private bool gpuHasNvidia, gpuCudaDlls, gpuUsable;
    private int gpuVramMB;

    private void ProbeGpu()
    {
        gpuName = ""; gpuHasNvidia = gpuCudaDlls = gpuUsable = false; gpuVramMB = 0;
        try
        {
            foreach (System.Management.ManagementObject mo in new System.Management.ManagementObjectSearcher(
                         "SELECT Name, AdapterRAM FROM Win32_VideoController").Get())
            {
                string nm = Convert.ToString(mo["Name"]);
                if (nm != null && nm.IndexOf("NVIDIA", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    gpuHasNvidia = true;
                    gpuName = nm;
                    try { gpuVramMB = (int)(Convert.ToInt64(mo["AdapterRAM"]) / (1024 * 1024)); }
                    catch { gpuVramMB = 0; }
                    break;
                }
            }
        }
        catch { }
        if (!gpuHasNvidia) return;

        string nvcuda = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                                     "System32", "nvcuda.dll");
        string llama = Path.Combine(Data.RimeDir, "llama.cpp");
        string[] need = new string[] { "ggml-cuda.dll", "cublas64_13.dll",
                                       "cublasLt64_13.dll", "cudart64_13.dll" };
        bool all = File.Exists(nvcuda);
        foreach (string n in need)
        {
            if (!File.Exists(Path.Combine(llama, n))) { all = false; break; }
        }
        gpuCudaDlls = all;
        gpuUsable = all;

        // 显存以 nvidia-smi 为准：WMI 的 AdapterRAM 是 32 位，>4GB 会回绕失真
        // （本机 8GB 卡经 WMI 读出来是 4GB，正好印证）。
        // ★ 必须异步读 + 硬超时：ReadLine() 是阻塞调用，遇到驱动卡死会**冻住设置窗口**。
        //   这里改成 BeginOutputReadLine 收集 + WaitForExit(2000)，拿不到就退回 WMI 的值。
        Process p = null;
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo("nvidia-smi",
                "--query-gpu=memory.total --format=csv,noheader,nounits");
            psi.UseShellExecute = false;
            psi.RedirectStandardOutput = true;
            psi.CreateNoWindow = true;
            p = Process.Start(psi);
            string first = null;
            // 单行输出，异步回调里取第一行即可
            p.OutputDataReceived += delegate(object s, DataReceivedEventArgs e)
            {
                if (first == null && !string.IsNullOrEmpty(e.Data)) first = e.Data;
            };
            p.BeginOutputReadLine();
            if (!p.WaitForExit(2000))
            {
                try { p.Kill(); } catch { }
            }
            // Kill 之后回调可能还没跑完，再等一小会儿把已缓冲的行收干净
            try { p.WaitForExit(500); } catch { }
            int mb;
            if (first != null && int.TryParse(first.Trim(), out mb) && mb > 0)
                gpuVramMB = mb;
        }
        catch { }
        finally
        {
            if (p != null) { try { p.Dispose(); } catch { } }
        }
    }

    private string DeviceFromCombo()
    {
        switch (cmbDevice.SelectedIndex)
        {
            case 1: return "cpu";
            case 2: return "gpu";
            default: return "auto";
        }
    }

    private void UpdateDeviceState()
    {
        if (lblDevCur == null) return;
        string label = gpuName.Length > 0 ? gpuName : "未检测到 NVIDIA 显卡";
        string vram = gpuVramMB > 0
            ? "，显存 " + Math.Round(gpuVramMB / 1024.0, 1) + " GB" : "";
        lblDevCur.Text = "显卡：" + label + vram;

        bool effGpu = Data.AsrDevice != "cpu" && gpuUsable;
        if (effGpu)
        {
            lblDevState.Text = "当前生效：GPU 加速（识别约快 2.3 倍，CPU 占用约 11%）";
            lblDevState.ForeColor = Theme.Green;
        }
        else
        {
            string why = !gpuHasNvidia ? "未检测到 NVIDIA 显卡"
                       : (!gpuCudaDlls ? "缺少 CUDA 运行时（当前装的是 CPU 版包）"
                                       : "已手动选择 CPU");
            lblDevState.Text = "当前生效：CPU（" + why + "）";
            lblDevState.ForeColor = Data.AsrDevice == "cpu" ? Theme.Tert : Theme.Accent;
        }

        if (gpuHasNvidia && !gpuCudaDlls)
        {
            lblDevHint.Text =
                "检测到 N 卡（" + gpuName + "），但当前是 CPU 版安装包，未附带 CUDA 运行时。\n" +
                "想用 GPU 加速请改装仓库 Release 里的 GPU 版安装包（约 1.75 GB），装好后这里会自动变成 GPU。\n" +
                "CPU 版 / GPU 版功能完全一致，只有识别速度和 CPU 占用不同。";
        }
        else
        {
            lblDevHint.Text =
                "GPU 加速需要 NVIDIA 显卡 + 驱动 + 安装包自带 CUDA 运行时，三者齐全才生效。\n" +
                "「自动」：能用 GPU 就用，用不了静默回落 CPU —— 推荐保持默认，不用管。\n" +
                "实测（RTX 5060 Laptop / 同一段 6.2 秒语音）：GPU 0.19 秒、占用 11%；CPU 0.43 秒、占用 26%。\n" +
                "改动即时保存，重新打开一次语音输入（重启悬浮球）后生效。";
        }
    }

    private void UpdateCpuState()
    {
        if (trkCpu == null) return;
        int n = trkCpu.Value;
        string est = n <= 2 ? "约 12%" : n <= 4 ? "约 26%" : n <= 6 ? "约 36%"
                   : n <= 8 ? "约 48%" : "可能打满";
        string speed = n <= 2 ? "识别最快" : n <= 4 ? "识别很快"
                     : n <= 6 ? "识别较快" : "速度提升有限";
        bool gpuOn = Data.AsrDevice != "cpu" && gpuUsable;
        lblCpuCur.Text = "当前：" + n + " 线程 —— 整机 CPU " + est + "，" + speed
                       + (gpuOn ? "（当前用 GPU，线程数不生效）" : "");
        lblCpuCur.ForeColor = gpuOn ? Theme.Tert
                            : n <= 4 ? Theme.Green : n <= 6 ? Theme.Accent : Theme.Danger;
        trkCpu.Enabled = !gpuOn;      // GPU 模式下 CPU 只做前后处理，滑块无意义
    }

    private void UpdateVoiceControls()
    {
        if (chkPunct == null) return;
        voiceLoading = true;
        try
        {
            chkPunct.Checked = Data.PunctSpace;
            UpdatePunctState();
            if (cmbDevice != null)
            {
                ProbeGpu();
                cmbDevice.SelectedIndex = Data.AsrDevice == "cpu" ? 1
                                        : Data.AsrDevice == "gpu" ? 2 : 0;
                UpdateDeviceState();
            }
            if (trkCpu != null)
            {
                int mx = Math.Max(1, Data.PhysCores());
                trkCpu.Maximum = mx;
                trkCpu.Value = Math.Min(Math.Max(1, Data.AsrThreads), mx);
                UpdateCpuState();
            }
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
    /// <summary>把 grid-settings.txt 的当前值刷到两个下拉框与状态行上。</summary>
    private void RefreshGridState()
    {
        if (cmbGridCollapsed == null || cmbGridExpanded == null) return;
        cmbGridCollapsed.SelectedItem = Data.GridColsCollapsed.ToString();
        if (cmbGridCollapsed.SelectedItem == null) cmbGridCollapsed.SelectedIndex = Data.GridColsCollapsedDefault - 1;
        cmbGridExpanded.SelectedItem = Data.GridColsExpanded.ToString();
        if (cmbGridExpanded.SelectedItem == null) cmbGridExpanded.SelectedIndex = Data.GridColsExpandedDefault - 1;
        if (lblGridState != null)
        {
            lblGridState.Text = "当前：未展开 " + Data.GridColsCollapsed +
                                " 个 / 展开 " + Data.GridColsExpanded + " 个";
        }
    }

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

        // 候选栏每行数量
        cardGrid.SetBounds(16, y, cws, 168);
        lblGridCollapsed.Location = new Point(18, 38);
        cmbGridCollapsedP.SetBounds(130, 32, 92, 30);
        lblGridExpanded.Location = new Point(246, 38);
        cmbGridExpandedP.SetBounds(348, 32, 92, 30);
        btnGridSave.SetBounds(456, 32, 88, 30);
        lblGridState.SetBounds(18, 72, cws - 36, 20);
        lblGridHint.SetBounds(18, 98, cws - 36, 60);
        y += 168 + 12;

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
        // 设备卡片：下拉一行 + 显卡一行 + 生效状态一行 + 说明四行
        cardDevice.SetBounds(16, 196, cwv, 208);
        cmbDeviceP.SetBounds(18, 34, 260, 30);
        lblDevCur.SetBounds(292, 40, cwv - 310, 22);
        lblDevState.SetBounds(18, 74, cwv - 36, 22);
        lblDevHint.SetBounds(18, 102, cwv - 36, 96);
        // CPU 占用卡片：滑块一行 + 状态一行 + 说明四行
        cardCpu.SetBounds(16, 416, cwv, 176);
        trkCpu.SetBounds(16, 34, cwv - 32, 34);
        lblCpuCur.SetBounds(18, 72, cwv - 36, 22);
        lblCpuHint.SetBounds(18, 96, cwv - 36, 74);
        // 快捷键卡片：按钮一行 + 状态一行 + 说明三行
        cardHotkey.SetBounds(16, 602, cwv, 196);
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
