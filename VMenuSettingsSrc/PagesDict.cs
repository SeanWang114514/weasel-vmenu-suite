// PagesDict.cs —— 词库管理页（原 dict-manager.ps1 集成：加词自动注音、权重、
// 删除、搜索、加入常用语）

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Text.RegularExpressions;
using System.Windows.Forms;

internal partial class MainForm : Form
{
    private Label dictTitle;
    private Label dictSub;
    private Label dictEmpty;
    private Label dictSelLabel;
    private Label dictSelWtLabel;
    private Label dictLblWord;
    private Label dictLblPy;
    private Label dictLblWt;
    private Label dictTip;
    private Label dictPathLabel;
    private Label dictHintLabel;
    private AppleBadge dictBadge;
    private AppleCard dictCardList, dictCardAdd, dictCardPath;
    private AppleField dictSearchP, dictSelWtP, dictWordP, dictPinyinP, dictWeightP;
    private AppleButton btnDictRefresh, btnDictWeight, btnDictDelete,
        btnDictAdd, btnDictFav, btnOpenFolder;
    private ListView dictList;
    private ListHeader dictHeader;

    private TextBox dictSearch { get { return dictSearchP.TextBox; } }
    private TextBox dictSelWt { get { return dictSelWtP.TextBox; } }
    private TextBox dictWord { get { return dictWordP.TextBox; } }
    private TextBox dictPinyin { get { return dictPinyinP.TextBox; } }
    private TextBox dictWeight { get { return dictWeightP.TextBox; } }

    private void BuildPagesDict()
    {
        dictTitle = new Label();
        dictTitle.Text = "个人词库管理";
        dictTitle.Font = Theme.Page;
        dictTitle.ForeColor = Theme.Text;
        dictTitle.AutoSize = true;

        dictSub = new Label();
        dictSub.Text = "雾凇拼音 · 你的加词在这里统一管理";
        dictSub.Font = Theme.Hint;
        dictSub.ForeColor = Theme.Sub;
        dictSub.AutoSize = true;

        dictBadge = new AppleBadge("共 0 条", 0, 0, 92, 24);

        dictCardList = new AppleCard("已加词语", Theme.Bg, 12);
        dictSearchP = new AppleField(0, 0, 190, 28, "", false, false, false);
        Theme.SetPlaceholder(dictSearch, "搜索词语或拼音");
        btnDictRefresh = AppleButton.Make("刷新", "Plain", 70, 28);
        dictList = new ListView();
        Lst.Style(dictList, true);
        dictList.Columns.Add("词语", 300);
        dictList.Columns.Add("拼音", 240);
        dictList.Columns.Add("权重", 110);
        dictHeader = new ListHeader(dictList, "词语", "拼音", "权重");
        dictEmpty = new Label();
        dictEmpty.Font = Theme.Hint;
        dictEmpty.ForeColor = Theme.Tert;
        dictEmpty.TextAlign = ContentAlignment.MiddleCenter;
        dictEmpty.Text = "还没有加过词，在下方输入框加第一个吧";
        dictSelLabel = new Label();
        dictSelLabel.Font = Theme.Hint;
        dictSelLabel.ForeColor = Theme.Sub;
        dictSelLabel.Text = "未选中";
        dictSelWtLabel = new Label();
        dictSelWtLabel.Font = Theme.Hint;
        dictSelWtLabel.ForeColor = Theme.Sub;
        dictSelWtLabel.AutoSize = true;
        dictSelWtLabel.Text = "权重：";
        dictSelWtP = new AppleField(0, 0, 92, 28, "", false, false, false);
        btnDictWeight = AppleButton.Make("更新权重", "Plain", 100, 30);
        btnDictDelete = AppleButton.Make("删除所选", "DangerOutline", 100, 30);  // 删除=红

        dictCardAdd = new AppleCard("添加新词", Theme.Bg, 12);
        dictLblWord = MakeSmallLabel("词语 *");
        dictLblPy = MakeSmallLabel("拼音（空格分隔）");
        dictLblWt = MakeSmallLabel("权重");
        dictWordP = new AppleField(0, 0, 200, 30, "", false, false, false);
        dictPinyinP = new AppleField(0, 0, 200, 30, "", false, false, false);
        dictWeightP = new AppleField(0, 0, 96, 30, "", false, false, false);
        dictWeight.Text = Data.DefaultWeight.ToString();
        btnDictAdd = AppleButton.Make("加入词库", "Primary", 108, 30);
        btnDictFav = AppleButton.Make("加入常用语", "Plain", 108, 30);
        dictTip = new Label();
        dictTip.Font = Theme.Hint;
        dictTip.ForeColor = Theme.Tert;
        dictTip.Text = "输入词语后自动标注拼音（可手动修改），权重越大排名越靠前。";

        dictCardPath = new AppleCard("", Theme.Bg, 12);
        dictPathLabel = new Label();
        dictPathLabel.Font = Theme.Hint;
        dictPathLabel.ForeColor = Theme.Sub;
        dictPathLabel.Text = "保存位置：" + Data.MydictPath;
        dictHintLabel = new Label();
        dictHintLabel.Font = Theme.Hint;
        dictHintLabel.ForeColor = Theme.Tert;
        dictHintLabel.Text = "改完记得重新部署输入法（右键任务栏小狼毫图标 → 重新部署）";
        btnOpenFolder = AppleButton.Make("打开所在文件夹", "Plain", 136, 30);

        dictCardList.Controls.AddRange(new Control[]
        {
            dictSearchP, btnDictRefresh, dictHeader, dictList, dictEmpty,
            dictSelLabel, dictSelWtLabel, dictSelWtP, btnDictWeight, btnDictDelete
        });
        dictCardAdd.Controls.AddRange(new Control[]
        {
            dictLblWord, dictLblPy, dictLblWt,
            dictWordP, dictPinyinP, dictWeightP, btnDictAdd, btnDictFav, dictTip
        });
        dictCardPath.Controls.AddRange(new Control[] { dictPathLabel, dictHintLabel, btnOpenFolder });
        tabDict.Controls.AddRange(new Control[]
        {
            dictTitle, dictSub, dictBadge, dictCardList, dictCardAdd, dictCardPath
        });

        // --- 事件 ---
        dictSearch.TextChanged += delegate
        {
            // 搜索防抖：停手 200ms 后再过滤
            if (dictTimer != null) { dictTimer.Stop(); dictTimer.Start(); }
        };

        btnDictRefresh.Click += delegate
        {
            RefreshMyDictList();
            SetDictTip("已刷新。", true);
            Status("词库已重新载入");
        };

        // 输入词语自动注音（防重入：写拼音框会再次触发 TextChanged）
        dictWord.TextChanged += DictWord_TextChanged;

        btnDictAdd.Click += BtnDictAdd_Click;
        btnDictFav.Click += BtnDictFav_Click;

        dictList.SelectedIndexChanged += delegate
        {
            if (dictList.SelectedItems.Count > 0)
            {
                DictEntry ent = (DictEntry)dictList.SelectedItems[0].Tag;
                dictSelLabel.Text = "已选：" + ent.Word;
                dictSelWt.Text = ent.Weight.ToString();
            }
            else
            {
                dictSelLabel.Text = "未选中";
                dictSelWt.Text = "";
            }
        };

        btnDictWeight.Click += BtnDictWeight_Click;
        btnDictDelete.Click += BtnDictDelete_Click;

        dictList.DoubleClick += delegate
        {
            // 双击 = 把词填回下方输入框方便补一条（不直接改词条）
            if (dictList.SelectedItems.Count == 0) return;
            DictEntry ent = (DictEntry)dictList.SelectedItems[0].Tag;
            dictWord.Text = ent.Word;
            dictPinyin.Text = ent.Pinyin;
            dictWeight.Text = ent.Weight.ToString();
            SetDictTip("已填入下方输入框，改完点「加入词库」会作为新词条追加；旧词条请在列表里删除。", true);
        };

        btnOpenFolder.Click += delegate
        {
            if (System.IO.File.Exists(Data.MydictPath))
            {
                try
                {
                    ProcessStartInfo psi = new ProcessStartInfo("explorer.exe",
                        "/select,\"" + Data.MydictPath + "\"");
                    psi.UseShellExecute = true;
                    Process.Start(psi);
                }
                catch { Info("打不开：" + Data.MydictPath, "打开文件夹失败"); }
            }
            else
            {
                Info("找不到词库文件：" + Data.MydictPath, "打开文件夹失败");
            }
        };
    }

    private Label MakeSmallLabel(string text)
    {
        Label l = new Label();
        l.Text = text;
        l.Font = Theme.Hint;
        l.ForeColor = Theme.Sub;
        l.AutoSize = true;
        return l;
    }

    private void SetDictTip(string msg, bool ok)
    {
        if (dictTip == null) return;
        dictTip.Text = msg;
        dictTip.ForeColor = ok ? Theme.Green : Theme.Danger;
    }

    private void DictTimer_Tick(object sender, EventArgs e)
    {
        dictTimer.Stop();
        dictSearchText = dictSearch.Text;
        RefreshMyDictList();
    }

    private void DictWord_TextChanged(object sender, EventArgs e)
    {
        if (annotating) return;
        annotating = true;
        try
        {
            string w = dictWord.Text.Trim();
            if (w.Length == 0) return;
            object[] r = Data.AutoPinyin(w);
            string py = (string)r[0];
            List<string> unknown = (List<string>)r[1];
            if (unknown.Count == 0)
            {
                if (dictPinyin.Text != py) dictPinyin.Text = py;
                SetDictTip("已自动标注拼音（可手动修改），权重越大排名越靠前。", true);
            }
            else
            {
                string quoted = "";
                for (int i = 0; i < unknown.Count; i++)
                {
                    if (i > 0) quoted += "”“";
                    quoted += unknown[i];
                }
                SetDictTip("“" + quoted + "”在字表里没找到，请手动输入完整拼音。", false);
            }
        }
        finally { annotating = false; }
    }

    public void RefreshMyDictList()
    {
        if (dictList == null) return;
        mydict = Data.ReadMyDict();
        string q = "";
        if (dictSearch != null) q = dictSearch.Text.Trim().ToLower();
        List<DictEntry> shown = mydict;
        if (q.Length > 0)
        {
            shown = new List<DictEntry>();
            foreach (DictEntry e in mydict)
            {
                if (e.Word.ToLower().IndexOf(q, StringComparison.Ordinal) >= 0 ||
                    e.Pinyin.ToLower().IndexOf(q, StringComparison.Ordinal) >= 0)
                    shown.Add(e);
            }
        }
        dictList.BeginUpdate();
        dictList.Items.Clear();
        foreach (DictEntry ent in shown)
        {
            ListViewItem it = new ListViewItem(ent.Word);
            it.SubItems.Add(ent.Pinyin);
            it.SubItems.Add(ent.Weight.ToString());
            it.Tag = ent;
            dictList.Items.Add(it);
        }
        dictList.EndUpdate();
        Lst.RowBands(dictList);
        FitDictColumns();
        if (dictBadge != null) dictBadge.BadgeText = "共 " + mydict.Count + " 条";
        if (mydict.Count == 0)
        {
            dictEmpty.Text = "还没有加过词，在下方输入框加第一个吧";
            dictEmpty.Visible = true;
        }
        else if (shown.Count == 0)
        {
            dictEmpty.Text = "没有匹配「" + q + "」的词";
            dictEmpty.Visible = true;
        }
        else
        {
            dictEmpty.Visible = false;
        }
    }

    private void FitDictColumns()
    {
        int avail = Lst.AvailWidth(dictList);
        int wtW = 110;
        int pyW = (int)((avail - wtW) * 0.45);
        if (pyW < 150) pyW = 150;
        dictList.Columns[2].Width = wtW;
        dictList.Columns[1].Width = pyW;
        dictList.Columns[0].Width = Math.Max(120, avail - pyW - wtW);
        dictHeader.SetLabels();
    }

    private void BtnDictAdd_Click(object sender, EventArgs e)
    {
        string word = dictWord.Text.Trim();
        if (word.Length == 0) { SetDictTip("请先输入词语。", false); return; }
        string pinyin = dictPinyin.Text.Trim().ToLower();
        if (pinyin.Length == 0)
        {
            object[] r = Data.AutoPinyin(word);
            List<string> unknown = (List<string>)r[1];
            if (unknown.Count > 0) { SetDictTip("拼音为空，请手动输入拼音（空格分隔）。", false); return; }
            pinyin = (string)r[0];
            dictPinyin.Text = pinyin;
        }
        if (!Regex.IsMatch(pinyin, "^[a-züv][a-züv' ]*$"))
        {
            SetDictTip("拼音格式不对（只允许小写字母/空格/分词单引号）。", false);
            return;
        }
        long weight = Data.DefaultWeight;
        string wtText = dictWeight.Text.Trim();
        if (wtText.Length > 0)
        {
            long tmp;
            if (long.TryParse(wtText, out tmp) && tmp > 0) weight = tmp;
            else { SetDictTip("权重无效，请输入正整数。", false); return; }
        }
        DictEntry dup = null;
        foreach (DictEntry ent in mydict)
        {
            if (ent.Word == word) { dup = ent; break; }
        }
        if (dup != null)
        {
            string msg = "“" + word + "”已存在（" + dup.Pinyin + "），要再追加一条吗？";
            AppleDialogResult ans = AppleDialog.Show(this, "重复提醒", msg, null,
                "追加", "取消", false, "Primary", false, false, 470);
            if (!ans.OK) return;
        }
        DictEntry ne = new DictEntry();
        ne.Word = word;
        ne.Pinyin = pinyin;
        ne.Weight = weight;
        List<DictEntry> all = new List<DictEntry>(mydict);
        all.Add(ne);
        Data.SaveMyDict(all);
        RefreshMyDictList();
        dictWord.Clear();
        dictPinyin.Clear();
        dictWeight.Text = Data.DefaultWeight.ToString();
        SetDictTip("已加入 “" + word + "”，保存在：" + Data.MydictPath, true);
        Status("已加入 “" + word + "” · 记得重新部署后生效");
    }

    private void BtnDictFav_Click(object sender, EventArgs e)
    {
        string word = dictWord.Text.Trim();
        if (word.Length == 0 || word.IndexOf('\r') >= 0 || word.IndexOf('\n') >= 0)
        {
            SetDictTip("常用语内容必须是单行，且不能为空。", false);
            return;
        }
        FavEntry exists = null;
        foreach (FavEntry f in favs)
        {
            if (f.Word == word) { exists = f; break; }
        }
        if (exists != null)
        {
            SetDictTip("“" + word + "”已经在常用语里了（触发码：" + exists.Key + "）。", false);
            return;
        }
        string key = word.Substring(0, Math.Min(3, word.Length)).ToLower();
        favs = Data.LoadFavorites();      // 以文件为准，别用陈旧内存覆盖
        FavEntry ne = new FavEntry();
        ne.Word = word;
        ne.Key = key;
        favs.Add(ne);
        Data.SaveFavorites(favs);
        RefreshFavorites();
        dictWord.Clear();
        SetDictTip("已加入常用语，触发码：" + key + "（打这三位编码即可上屏）。", true);
        Status("已加入常用语：" + word);
    }

    private void BtnDictWeight_Click(object sender, EventArgs e)
    {
        if (dictList.SelectedItems.Count == 0) { SetDictTip("请先在列表中选中一个词。", false); return; }
        long tmp;
        if (!long.TryParse(dictSelWt.Text.Trim(), out tmp) || tmp <= 0)
        {
            SetDictTip("权重无效，请输入正整数。", false);
            return;
        }
        DictEntry ent = (DictEntry)dictList.SelectedItems[0].Tag;
        ent.Weight = tmp;
        Data.SaveMyDict(mydict);
        RefreshMyDictList();
        SetDictTip("“" + ent.Word + "”权重已改为 " + tmp + "，保存在：" + Data.MydictPath, true);
        Status("已更新 “" + ent.Word + "” 的权重");
    }

    private void BtnDictDelete_Click(object sender, EventArgs e)
    {
        if (dictList.SelectedItems.Count == 0) { SetDictTip("请先在列表中选中一个词。", false); return; }
        DictEntry ent = (DictEntry)dictList.SelectedItems[0].Tag;
        AppleDialogResult ans = AppleDialog.Show(this, "删除确认",
            "确定删除“" + ent.Word + "”吗？", null, "删除", "取消",
            false, "Danger", false, false, 470);
        if (!ans.OK) return;
        List<DictEntry> rest = new List<DictEntry>();
        foreach (DictEntry e2 in mydict) if (e2 != ent) rest.Add(e2);
        Data.SaveMyDict(rest);
        RefreshMyDictList();
        SetDictTip("已删除 “" + ent.Word + "”，保存在：" + Data.MydictPath, true);
        Status("已删除 “" + ent.Word + "” · 记得重新部署后生效");
    }

    // ------------------------------------------------------------ 布局
    private void LayoutDict()
    {
        int w = tabDict.ClientSize.Width;
        int h = tabDict.ClientSize.Height;
        if (w < 480) w = 960;
        if (h < 320) h = 560;
        int cw = w - 24;
        dictTitle.SetBounds(12, 9, 300, 22);
        dictSub.Location = new Point(dictTitle.Right + 10, 12);
        dictBadge.SetBounds(cw + 12 - 92, 9, 92, 24);
        int capH = 44;
        int cardB_H = 124;
        int cardC_H = 66;
        int gap = 12;
        int cardA_H = h - capH - cardB_H - cardC_H - gap * 2 - 12;
        if (cardA_H < 160) cardA_H = 160;
        int cardA_T = capH;
        dictCardList.SetBounds(12, cardA_T, cw, cardA_H);
        dictCardAdd.SetBounds(12, cardA_T + cardA_H + gap, cw, cardB_H);
        dictCardPath.SetBounds(12, cardA_T + cardA_H + gap + cardB_H + gap, cw, cardC_H);

        // 卡片 A 内部
        int dictRefreshX = cw - 16 - 70;
        int dictSearchX = dictRefreshX - 8 - 190;
        dictSearchP.SetBounds(dictSearchX, 11, 190, 28);
        btnDictRefresh.SetBounds(dictRefreshX, 11, 70, 28);
        int listA_H = cardA_H - 122;
        int maxList = cardA_H - 70 - 50;
        if (listA_H > maxList) listA_H = maxList;
        if (listA_H < 36) listA_H = 36;
        dictList.SetBounds(14, 70, cw - 28, listA_H);
        dictEmpty.SetBounds(14, 132, cw - 28, 36);
        int rowY = 70 + listA_H + 10;
        if (rowY > cardA_H - 40) rowY = cardA_H - 40;
        dictSelLabel.SetBounds(16, rowY + 3, 200, 22);
        dictSelWtLabel.SetBounds(228, rowY + 3, 50, 22);
        dictSelWtP.SetBounds(276, rowY, 92, 28);
        btnDictWeight.SetBounds(376, rowY - 1, 100, 30);
        btnDictDelete.SetBounds(cw - 16 - 100, rowY - 1, 100, 30);
        dictHeader.SetHeaderBounds(14, 48, cw - 28, 22);
        FitDictColumns();

        // 卡片 B 内部
        int contentR = cw - 16;
        int b1X = contentR - 108 - 8 - 108;
        int fieldsR = b1X - 14;
        int avail = fieldsR - 16;
        int wtW = 96;
        int rest = avail - wtW - 20;
        if (rest < 260) rest = 260;
        int pyW = (int)(rest * 0.56);
        int wordW = rest - pyW;
        dictLblWord.SetBounds(16, 40, 200, 16);
        dictLblPy.SetBounds(16 + wordW + 10, 40, 200, 16);
        dictLblWt.SetBounds(16 + wordW + 10 + pyW + 10, 40, 100, 16);
        dictWordP.SetBounds(16, 58, wordW, 30);
        dictPinyinP.SetBounds(16 + wordW + 10, 58, pyW, 30);
        dictWeightP.SetBounds(16 + wordW + 10 + pyW + 10, 58, wtW, 30);
        btnDictAdd.SetBounds(b1X, 58, 108, 30);
        btnDictFav.SetBounds(b1X + 116, 58, 108, 30);
        dictTip.SetBounds(16, 94, contentR - 16, 22);

        // 卡片 C 内部
        dictPathLabel.SetBounds(16, 14, cw - 16 - 152, 18);
        dictHintLabel.SetBounds(16, 36, cw - 16 - 152, 18);
        btnOpenFolder.SetBounds(cw - 16 - 136, 18, 136, 30);
    }
}
