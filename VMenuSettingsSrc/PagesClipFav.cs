// PagesClipFav.cs —— 剪贴板历史页 / 常用语页（控件、事件、布局、刷新）

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Text.RegularExpressions;
using System.Windows.Forms;

internal partial class MainForm : Form
{
    // ---- 剪贴板页 ----
    private Label clipInfo;
    private Label clipHint;
    private ListView clipList;
    private ListHeader clipHeader;
    private AppleCard clipCard;
    private AppleButton btnClipCopy, btnClipDel, btnClipClear, btnClipReload, btnClipTop;

    // ---- 常用语页 ----
    private Label favInfo;
    private Label favHint;
    private ListView favList;
    private ListHeader favHeader;
    private AppleCard favCard;
    private AppleButton btnFavAdd, btnFavEdit, btnFavDel, btnFavClear,
        btnFavReload, btnFavUp, btnFavDown;

    private void BuildPagesClipFav()
    {
        // ===== 剪贴板页 =====
        clipInfo = new Label();
        clipInfo.Padding = new Padding(16, 13, 16, 0);
        clipInfo.ForeColor = Theme.Sub;
        clipInfo.BackColor = Theme.Bg;
        // 固定几何：AutoSize 会在文本变化时先把标签撑大/缩回、下一次布局再拉回，
        // 页面顶部说明行就出现「先跳一下再回位」的闪动 —— 锁死盒子，永不自适应。
        clipInfo.AutoSize = false;
        clipInfo.Text = "";

        clipList = new ListView();
        Lst.Style(clipList, false);
        clipList.Columns.Add("序", 52);
        clipList.Columns.Add("剪贴板内容（最新在最上面）", 720);
        clipHeader = new ListHeader(clipList, "序", "剪贴板内容（最新在最上面）");
        clipCard = new AppleCard("", Theme.Bg, 12);

        // 颜色可视化：删除=红描边，清空=实心红（破坏性一眼可辨）
        btnClipCopy = AppleButton.Make("复制到剪贴板", "Plain", 150, 32);
        btnClipDel = AppleButton.Make("删除选中", "DangerOutline", 150, 32);
        btnClipClear = AppleButton.Make("清空全部", "Danger", 150, 32);
        btnClipReload = AppleButton.Make("重新载入", "Plain", 150, 32);
        btnClipTop = AppleButton.Make("把选中项置顶", "Plain", 150, 32);

        clipHint = new Label();
        clipHint.AutoSize = false;   // 固定盒子：AutoSize 会让内容宽度/高度溢出视图，缩放后出现残留滚动位移
        clipHint.ForeColor = Theme.Sub;
        clipHint.Font = Theme.Hint;
        clipHint.Text =
            "输入法里按 v → 2 可以快速取用。\n\n" +
            "双击某一条可以直接编辑。\n\n" +
            "超过 50 条时自动丢弃最旧的。\n\n" +
            "多行内容会被压平成一行。";

        clipCard.Controls.AddRange(new Control[]
        {
            clipHeader, clipList, btnClipCopy, btnClipDel, btnClipClear,
            btnClipReload, btnClipTop, clipHint
        });
        tabClip.Controls.Add(clipCard);
        tabClip.Controls.Add(clipInfo);

        btnClipCopy.Click += BtnClipCopy_Click;
        btnClipDel.Click += BtnClipDel_Click;
        btnClipClear.Click += BtnClipClear_Click;
        btnClipReload.Click += delegate { RefreshClipboard(); Status("已重新载入"); };
        btnClipTop.Click += BtnClipTop_Click;
        clipList.DoubleClick += ClipList_DoubleClick;

        // ===== 常用语页 =====
        favInfo = new Label();
        favInfo.Padding = new Padding(16, 13, 16, 0);
        favInfo.ForeColor = Theme.Sub;
        favInfo.BackColor = Theme.Bg;
        favInfo.AutoSize = false;   // 同 clipInfo：固定盒子，刷新不跳

        favList = new ListView();
        Lst.Style(favList, false);
        favList.Columns.Add("序", 52);
        favList.Columns.Add("内容", 420);
        favList.Columns.Add("编码", 280);
        favHeader = new ListHeader(favList, "序", "内容", "编码");
        favCard = new AppleCard("", Theme.Bg, 12);

        btnFavAdd = AppleButton.Make("添加", "Plain", 150, 32);
        btnFavEdit = AppleButton.Make("修改选中", "Plain", 150, 32);
        btnFavDel = AppleButton.Make("删除选中", "DangerOutline", 150, 32);
        btnFavClear = AppleButton.Make("清空全部", "Danger", 150, 32);
        btnFavReload = AppleButton.Make("重新载入", "Plain", 150, 32);
        btnFavUp = AppleButton.Make("上移", "Plain", 150, 32);
        btnFavDown = AppleButton.Make("下移", "Plain", 150, 32);

        favHint = new Label();
        favHint.AutoSize = false;    // 同 clipHint：固定盒子防溢出
        favHint.ForeColor = Theme.Sub;
        favHint.Font = Theme.Hint;
        favHint.Text =
            "用法：\n" +
            "· 打字时键入编码的前 3 位，内容就会出现在候选第 2 位（纯数字编码则把编码打完，再按回车直接上屏）。\n\n" +
            "· 双击某一条可以直接修改。\n\n" +
            "· 输入法里按 v → 3 也能搜索取用。\n\n" +
            "· 这里的改动立即生效（输入法直接读这个文件）。";

        favCard.Controls.AddRange(new Control[]
        {
            favHeader, favList, btnFavAdd, btnFavEdit, btnFavDel, btnFavClear,
            btnFavReload, btnFavUp, btnFavDown, favHint
        });
        tabFav.Controls.Add(favCard);
        tabFav.Controls.Add(favInfo);

        btnFavAdd.Click += delegate { EditFavorite(-1); };
        btnFavEdit.Click += FavEdit_Click;
        btnFavDel.Click += FavDel_Click;
        btnFavClear.Click += FavClear_Click;
        btnFavReload.Click += delegate { RefreshFavorites(); Status("已重新载入"); };
        btnFavUp.Click += FavUp_Click;
        btnFavDown.Click += FavDown_Click;
        favList.DoubleClick += FavList_DoubleClick;
    }

    // ------------------------------------------------------------ 剪贴板
    public void RefreshClipboard()
    {
        clip = Data.LoadClipboard();
        clipStamp = Data.ClipStamp();
        clipList.BeginUpdate();
        clipList.Items.Clear();
        for (int i = 0; i < clip.Count; i++)
        {
            string t = clip[i];
            string show = t;
            if (show.Length > 160) show = show.Substring(0, 160) + " …";
            ListViewItem it = new ListViewItem((i + 1).ToString());
            it.SubItems.Add(show);
            it.Tag = i;
            clipList.Items.Add(it);
        }
        clipList.EndUpdate();
        Lst.RowBands(clipList);
        FitClipColumns();   // 条数变了滚动条就在变 → 列宽/表头必须重算
        clipInfo.Text = "当前缓存 " + clip.Count + " 条（上限 " + Data.MaxClip +
            " 条）。输入法剪贴板列表默认显示 " + Data.PageSize + " 条，按 m 键每次 +" +
            Data.Step + " 条，最多 " + Data.MaxPage + " 条。";
    }

    private void FitClipColumns()
    {
        int avail = Lst.AvailWidth(clipList);
        clipList.Columns[0].Width = 52;
        clipList.Columns[1].Width = Math.Max(160, avail - 52);
        clipHeader.SetLabels();
    }

    private void EditClipboard(int index)
    {
        if (index < 0 || index >= clip.Count) return;
        List<DialogField> fields = new List<DialogField>();
        fields.Add(new DialogField("", clip[index]));
        AppleDialogResult r = AppleDialog.Show(this, "编辑第 " + (index + 1) + " 条",
            "内容（保存后立即生效，输入法里按 v → 2 就能取用）",
            fields, "保存", "取消", false, "Primary", true, true, 470);
        if (!r.OK) return;
        string v = Regex.Replace(r.Values[0], "\r?\n", " ").Trim();
        if (v.Length == 0) { Info("内容不能为空。", "提示"); return; }
        clip[index] = v;
        Data.SaveClipboard(clip);
        RefreshClipboard();
        Status("已修改第 " + (index + 1) + " 条");
    }

    private void BtnClipCopy_Click(object sender, EventArgs e)
    {
        if (clipList.SelectedItems.Count == 0) return;
        int i = (int)clipList.SelectedItems[0].Tag;
        try
        {
            Clipboard.SetText(clip[i]);
            Status("已复制第 " + (i + 1) + " 条到剪贴板");
        }
        catch { Status("剪贴板被占用，复制失败，请重试"); }
    }

    private void BtnClipDel_Click(object sender, EventArgs e)
    {
        if (clipList.SelectedItems.Count == 0) { Status("请先选中要删除的条目"); return; }
        List<int> idx = new List<int>();
        foreach (ListViewItem it in clipList.SelectedItems) idx.Add((int)it.Tag);
        idx.Sort(delegate(int a, int b) { return b.CompareTo(a); });
        int n = idx.Count;
        if (!Confirm("确定删除选中的 " + n + " 条剪贴板记录？此操作不可恢复。", "删除剪贴板记录"))
            return;
        List<string> rest = new List<string>();
        for (int i = 0; i < clip.Count; i++)
            if (!idx.Contains(i)) rest.Add(clip[i]);
        clip = rest;
        Data.SaveClipboard(clip);
        RefreshClipboard();
        Status("已删除 " + n + " 条剪贴板记录");
    }

    private void BtnClipClear_Click(object sender, EventArgs e)
    {
        if (clip.Count == 0) { Status("剪贴板缓存已经是空的"); return; }
        if (!Confirm("确定清空全部 " + clip.Count + " 条剪贴板历史？此操作不可恢复。", "清空剪贴板缓存"))
            return;
        clip.Clear();
        Data.SaveClipboard(clip);
        RefreshClipboard();
        Status("剪贴板缓存已清空");
    }

    private void BtnClipTop_Click(object sender, EventArgs e)
    {
        if (clipList.SelectedItems.Count == 0) return;
        int i = (int)clipList.SelectedItems[0].Tag;
        if (i == 0) return;
        string item = clip[i];
        clip.RemoveAt(i);
        clip.Insert(0, item);
        Data.SaveClipboard(clip);
        RefreshClipboard();
        Status("已置顶");
    }

    private void ClipList_DoubleClick(object sender, EventArgs e)
    {
        if (clipList.SelectedItems.Count == 0) return;
        EditClipboard((int)clipList.SelectedItems[0].Tag);
    }

    // ------------------------------------------------------------ 常用语
    public void RefreshFavorites()
    {
        favs = Data.LoadFavorites();
        favList.BeginUpdate();
        favList.Items.Clear();
        for (int i = 0; i < favs.Count; i++)
        {
            ListViewItem it = new ListViewItem((i + 1).ToString());
            it.SubItems.Add(favs[i].Word);
            it.SubItems.Add(favs[i].Key);
            it.Tag = i;
            favList.Items.Add(it);
        }
        favList.EndUpdate();
        Lst.RowBands(favList);
        FitFavColumns();
        favInfo.Text = "共 " + favs.Count + " 条常用语。打字时键入编码前 3 位，内容会出现在候选第 2 位；纯数字编码把编码打完再按回车即可直接上屏。";
    }

    private void FitFavColumns()
    {
        int avail = Lst.AvailWidth(favList);
        favList.Columns[0].Width = 52;
        favList.Columns[2].Width = 260;
        favList.Columns[1].Width = Math.Max(150, avail - 52 - 260);
        favHeader.SetLabels();
    }

    private void EditFavorite(int index)
    {
        string title = index >= 0 ? "修改常用语" : "添加常用语";
        string v1 = "";
        string v2 = "";
        if (index >= 0 && index < favs.Count)
        {
            v1 = favs[index].Word;
            v2 = favs[index].Key;
        }
        List<DialogField> fields = new List<DialogField>();
        fields.Add(new DialogField("内容（要上屏的文字）", v1));
        fields.Add(new DialogField("编码（拼音等，用于 vfav 搜索；可留空则与内容相同）", v2));
        AppleDialogResult r = AppleDialog.Show(this, title, "", fields,
            "保存", "取消", false, "Primary", false, true, 470);
        if (!r.OK) return;
        string w = (r.Values[0] == null ? "" : r.Values[0]).Trim();
        string k = (r.Values.Length > 1 && r.Values[1] != null ? r.Values[1] : "").Trim();
        if (w.Length == 0) { Info("内容不能为空。", "提示"); return; }
        if (k.Length == 0) k = w;
        if (index >= 0)
        {
            favs[index].Word = w;
            favs[index].Key = k;
        }
        else
        {
            FavEntry e = new FavEntry();
            e.Word = w;
            e.Key = k;
            favs.Add(e);
        }
        Data.SaveFavorites(favs);
        RefreshFavorites();
        Status(index >= 0 ? "已修改：" + w : "已添加：" + w + "（编码 " + k + "）");
    }

    private void FavList_DoubleClick(object sender, EventArgs e)
    {
        if (favList.SelectedItems.Count == 0) return;
        EditFavorite((int)favList.SelectedItems[0].Tag);
    }

    private void FavEdit_Click(object sender, EventArgs e)
    {
        if (favList.SelectedItems.Count == 0) { Status("请先选中要修改的条目"); return; }
        EditFavorite((int)favList.SelectedItems[0].Tag);
    }

    private void FavDel_Click(object sender, EventArgs e)
    {
        if (favList.SelectedItems.Count == 0) { Status("请先选中要删除的条目"); return; }
        List<int> idx = new List<int>();
        foreach (ListViewItem it in favList.SelectedItems) idx.Add((int)it.Tag);
        idx.Sort(delegate(int a, int b) { return b.CompareTo(a); });
        int n = idx.Count;
        if (!Confirm("确定删除选中的 " + n + " 条常用语？此操作不可恢复。", "删除常用语"))
            return;
        List<FavEntry> rest = new List<FavEntry>();
        for (int i = 0; i < favs.Count; i++)
            if (!idx.Contains(i)) rest.Add(favs[i]);
        favs = rest;
        Data.SaveFavorites(favs);
        RefreshFavorites();
        Status("已删除 " + n + " 条常用语");
    }

    private void FavClear_Click(object sender, EventArgs e)
    {
        if (favs.Count == 0) { Status("常用语已经是空的"); return; }
        if (!Confirm("确定清空全部 " + favs.Count + " 条常用语？此操作不可恢复。", "清空常用语"))
            return;
        favs.Clear();
        Data.SaveFavorites(favs);
        RefreshFavorites();
        Status("常用语已全部清空");
    }

    private void FavUp_Click(object sender, EventArgs e)
    {
        if (favList.SelectedItems.Count == 0) return;
        int i = (int)favList.SelectedItems[0].Tag;
        if (i <= 0) return;
        FavEntry tmp = favs[i - 1];
        favs[i - 1] = favs[i];
        favs[i] = tmp;
        Data.SaveFavorites(favs);
        RefreshFavorites();
        if (i - 1 < favList.Items.Count)
        {
            favList.Items[i - 1].Selected = true;
            favList.Items[i - 1].EnsureVisible();
        }
        Status("已上移");
    }

    private void FavDown_Click(object sender, EventArgs e)
    {
        if (favList.SelectedItems.Count == 0) return;
        int i = (int)favList.SelectedItems[0].Tag;
        if (i >= favs.Count - 1) return;
        FavEntry tmp = favs[i + 1];
        favs[i + 1] = favs[i];
        favs[i] = tmp;
        Data.SaveFavorites(favs);
        RefreshFavorites();
        if (i + 1 < favList.Items.Count)
        {
            favList.Items[i + 1].Selected = true;
            favList.Items[i + 1].EnsureVisible();
        }
        Status("已下移");
    }

    // ------------------------------------------------------------ 布局
    private void LayoutClip()
    {
        int w = tabClip.ClientSize.Width;
        int h = tabClip.ClientSize.Height;
        if (w < 480) w = 960;
        if (h < 320) h = 560;
        clipInfo.SetBounds(0, 0, w, InfoH);
        int cw = w - 24;
        int chh = h - InfoH - 12;
        clipCard.SetBounds(12, InfoH, cw, chh);
        int btnX = cw - 164;
        int listW = btnX - 12 - 14;
        clipList.SetBounds(14, 36, listW, chh - 50);
        btnClipCopy.SetBounds(btnX, 14, 150, 32);
        btnClipDel.SetBounds(btnX, 54, 150, 32);
        btnClipClear.SetBounds(btnX, 94, 150, 32);
        btnClipReload.SetBounds(btnX, 134, 150, 32);
        btnClipTop.SetBounds(btnX, 186, 150, 32);
        int hintH = chh - 246;
        if (hintH < 60) hintH = 60;
        clipHint.SetBounds(btnX, 232, 150, hintH);
        clipHeader.SetHeaderBounds(14, 14, listW, 22);
        FitClipColumns();
    }

    private void LayoutFav()
    {
        int w = tabFav.ClientSize.Width;
        int h = tabFav.ClientSize.Height;
        if (w < 480) w = 960;
        if (h < 320) h = 560;
        favInfo.SetBounds(0, 0, w, InfoH);
        int cw = w - 24;
        int ch = h - InfoH - 12;
        favCard.SetBounds(12, InfoH, cw, ch);
        int btnX = cw - 164;
        int listW = btnX - 12 - 14;
        favList.SetBounds(14, 36, listW, ch - 50);
        btnFavAdd.SetBounds(btnX, 14, 150, 32);
        btnFavEdit.SetBounds(btnX, 54, 150, 32);
        btnFavDel.SetBounds(btnX, 94, 150, 32);
        btnFavClear.SetBounds(btnX, 134, 150, 32);
        btnFavReload.SetBounds(btnX, 174, 150, 32);
        btnFavUp.SetBounds(btnX, 226, 150, 32);
        btnFavDown.SetBounds(btnX, 266, 150, 32);
        int hintH = ch - 326;
        if (hintH < 60) hintH = 60;
        favHint.SetBounds(btnX, 312, 150, hintH);
        favHeader.SetHeaderBounds(14, 14, listW, 22);
        FitFavColumns();
    }
}
