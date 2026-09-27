// Ui.cs —— Apple 浅色主题 + 自绘控件（与原 PowerShell 版样式逐一对应）
//
// 颜色/字体/画刷全部只建一次（自绘每帧 New 画刷是当年卡顿的主因）；
// 圆角路径按尺寸缓存；所有自绘控件开双缓冲。
//
// 必须用 C# 5 语法（.NET Framework 4.x 自带的 csc 只认到 C# 5）：
// 不用字符串插值、?. 、nameof、表达式体成员。

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Reflection;
using System.Windows.Forms;

internal static class Theme
{
    // ---- 颜色（Apple 浅色模式）----
    public static readonly Color Bg = Color.FromArgb(245, 245, 247);
    public static readonly Color White = Color.White;
    public static readonly Color Stroke = Color.FromArgb(227, 227, 232);
    public static readonly Color Text = Color.FromArgb(29, 29, 31);
    public static readonly Color Sub = Color.FromArgb(110, 110, 115);
    public static readonly Color Tert = Color.FromArgb(161, 161, 166);
    public static readonly Color Accent = Color.FromArgb(0, 122, 255);
    public static readonly Color AccentH = Color.FromArgb(30, 140, 255);
    public static readonly Color AccentP = Color.FromArgb(0, 102, 225);
    public static readonly Color Danger = Color.FromArgb(255, 59, 48);
    public static readonly Color DangerH = Color.FromArgb(255, 69, 58);
    public static readonly Color DangerP = Color.FromArgb(215, 0, 21);
    public static readonly Color Green = Color.FromArgb(52, 199, 89);
    public static readonly Color SelRow = Color.FromArgb(214, 233, 255);
    public static readonly Color AltRow = Color.FromArgb(247, 247, 249);
    public static readonly Color FBorder = Color.FromArgb(210, 210, 215);
    public static readonly Color BtnB = Color.FromArgb(217, 217, 222);
    public static readonly Color BtnBH = Color.FromArgb(199, 199, 204);
    public static readonly Color DisFill = Color.FromArgb(233, 233, 236);
    public static readonly Color DisText = Color.FromArgb(174, 174, 178);
    public static readonly Color BadgeBg = Color.FromArgb(232, 241, 255);
    public static readonly Color BadgeBd = Color.FromArgb(187, 217, 255);
    public static readonly Color BtnHover = Color.FromArgb(250, 250, 251);
    public static readonly Color BtnPress = Color.FromArgb(232, 232, 237);
    public static readonly Color TabPill = Color.FromArgb(216, 216, 221);
    public static readonly Color RecBlue = Color.FromArgb(0, 113, 227);

    // ---- 语义色（2026-09-26 顶栏重设计时补）----
    public static readonly Color DangerTint = Color.FromArgb(255, 242, 241);   // 危险按钮悬停浅红底
    public static readonly Color DangerTintH = Color.FromArgb(255, 229, 227);   // 危险按钮按下红底
    public static readonly Color OkText = Color.FromArgb(34, 148, 66);          // 状态条「成功」绿
    public static readonly Color TabHoverBg = Color.FromArgb(235, 235, 240);    // 标签悬停底色
    public static readonly Color Warn = Color.FromArgb(255, 149, 0);            // 警示橙（备用）

    // ---- 字体 ----
    public static readonly Font Ui = new Font("Microsoft YaHei UI", 9f);
    public static readonly Font Hint = new Font("Microsoft YaHei UI", 8.5f);
    public static readonly Font Card = new Font("Microsoft YaHei UI", 10.5f, FontStyle.Bold);
    public static readonly Font Page = new Font("Microsoft YaHei UI", 11f, FontStyle.Bold);
    public static readonly Font Tab = new Font("Microsoft YaHei UI", 9f, FontStyle.Bold);
    public static readonly Font Sym = new Font("Segoe UI Symbol", 10f);

    // ---- 画刷 / 画笔（建一次反复用）----
    public static readonly Brush BrWhite = new SolidBrush(White);
    public static readonly Brush BrAccent = new SolidBrush(Accent);
    public static readonly Brush BrAccentH = new SolidBrush(AccentH);
    public static readonly Brush BrAccentP = new SolidBrush(AccentP);
    public static readonly Brush BrDanger = new SolidBrush(Danger);
    public static readonly Brush BrDangerH = new SolidBrush(DangerH);
    public static readonly Brush BrDangerP = new SolidBrush(DangerP);
    public static readonly Brush BrBtnH = new SolidBrush(BtnHover);
    public static readonly Brush BrBtnP = new SolidBrush(BtnPress);
    public static readonly Brush BrDis = new SolidBrush(DisFill);
    public static readonly Brush BrBadge = new SolidBrush(BadgeBg);
    public static readonly Brush BrBg = new SolidBrush(Bg);
    public static readonly Brush BrDangerTint = new SolidBrush(DangerTint);
    public static readonly Brush BrDangerTintH = new SolidBrush(DangerTintH);
    public static readonly Brush BrTabHover = new SolidBrush(TabHoverBg);

    public static readonly Pen PenStroke = new Pen(Stroke, 1f);
    public static readonly Pen PenFBorder = new Pen(FBorder, 1f);
    public static readonly Pen PenFocus = new Pen(Accent, 1.5f);
    public static readonly Pen PenBtn = new Pen(BtnB, 1f);
    public static readonly Pen PenBtnH = new Pen(BtnBH, 1f);
    public static readonly Pen PenBtnP = new Pen(FBorder, 1f);
    public static readonly Pen PenBadge = new Pen(BadgeBd, 1f);
    public static readonly Pen PenTabPill = new Pen(TabPill, 1f);
    public static readonly Pen PenDangerOutline = new Pen(Danger, 1f);
    public static readonly Pen PenDangerP = new Pen(DangerP, 1f);

    public static readonly TextFormatFlags TfLeft =
        TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding |
        TextFormatFlags.EndEllipsis | TextFormatFlags.Left;
    public static readonly TextFormatFlags TfCenter =
        TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding;

    // ---- 圆角路径缓存（GraphicsPath 构造 + 4 个 AddArc 很贵）----
    private static readonly Dictionary<string, GraphicsPath> pathCache = new Dictionary<string, GraphicsPath>();

    public static GraphicsPath RoundPath(Rectangle rect, double radius)
    {
        string key = rect.X + "," + rect.Y + "," + rect.Width + "," + rect.Height + "," + radius;
        GraphicsPath hit;
        if (pathCache.TryGetValue(key, out hit)) return hit;
        double rad = radius;
        GraphicsPath path = new GraphicsPath();
        double d = rad * 2;
        if (d > rect.Width) { rad = rect.Width / 2.0; d = rad * 2; }
        if (d > rect.Height) { rad = rect.Height / 2.0; d = rad * 2; }
        if (rad <= 0.5)
        {
            path.AddRectangle(rect);
        }
        else
        {
            path.AddArc(rect.X, rect.Y, (float)d, (float)d, 180, 90);
            path.AddArc(rect.Right - (float)d, rect.Y, (float)d, (float)d, 270, 90);
            path.AddArc(rect.Right - (float)d, rect.Bottom - (float)d, (float)d, (float)d, 0, 90);
            path.AddArc(rect.X, rect.Bottom - (float)d, (float)d, (float)d, 90, 90);
            path.CloseFigure();
        }
        if (pathCache.Count > 128) pathCache.Clear();
        pathCache[key] = path;
        return path;
    }

    // DoubleBuffered 是 protected 属性，控件实例上只能反射设置
    public static void DoubleBuffer(Control c)
    {
        try
        {
            PropertyInfo pi = typeof(Control).GetProperty("DoubleBuffered",
                BindingFlags.Instance | BindingFlags.NonPublic);
            if (pi != null) pi.SetValue(c, true, null);
        }
        catch { }
    }

    // Framework 版本不一，PlaceholderText 不一定有：反射设置，没有就算了
    // （原 PowerShell 版也是 try/catch 静默，行为一致）
    public static void SetPlaceholder(TextBox tb, string text)
    {
        try
        {
            PropertyInfo pi = typeof(TextBox).GetProperty("PlaceholderText");
            if (pi != null && pi.PropertyType == typeof(string))
                pi.SetValue(tb, text, null);
        }
        catch { }
    }
}

// ---------------------------------------------------------------------------
// 胶囊按钮：Kind = Primary（蓝底白字）/ Plain（白底描边）/ Danger（红底白字）/
//                    DangerOutline（白底红字红框，删除类用）
// ---------------------------------------------------------------------------
internal class AppleButton : Button
{
    public string Kind = "Plain";
    private static AppleButton pressed;

    public AppleButton()
    {
        SetBounds(0, 0, 110, 30);
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderSize = 0;
        Cursor = Cursors.Hand;
        UseVisualStyleBackColor = false;
        // 不用 Transparent：透明背景 + 自绘圆角时，圆角外的缝隙会露出未初始化的
        // 黑色缓冲（按钮底角出现黑色楔形）。按钮都坐在白色卡片上，直接给白色。
        BackColor = Theme.White;
        Theme.DoubleBuffer(this);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        try
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            // 先整格铺白：圆角外的四个角必须是卡片底色，绝不能露底
            g.FillRectangle(Theme.BrWhite, ClientRectangle);
            string kind = Kind == null || Kind.Length == 0 ? "Plain" : Kind;
            bool enabled = Enabled;
            bool hover = false;
            bool down = false;
            if (enabled)
            {
                Point pt = PointToClient(Cursor.Position);
                hover = ClientRectangle.Contains(pt);
                down = (pressed == this);
            }
            Brush brush = Theme.BrWhite;
            Pen pen = Theme.PenBtn;
            Color tc = Theme.Text;
            if (!enabled)
            {
                brush = Theme.BrDis;
                pen = null;
                tc = Theme.DisText;
            }
            else if (kind == "Primary")
            {
                brush = Theme.BrAccent;
                pen = null;
                tc = Color.White;
                if (hover) brush = Theme.BrAccentH;
                if (down) brush = Theme.BrAccentP;
            }
            else if (kind == "Danger")
            {
                brush = Theme.BrDanger;
                pen = null;
                tc = Color.White;
                if (hover) brush = Theme.BrDangerH;
                if (down) brush = Theme.BrDangerP;
            }
            else if (kind == "DangerOutline")
            {
                // 危险描边：白底红字红框（删除类按钮用；清空类用实心 Danger）
                brush = Theme.BrWhite;
                pen = Theme.PenDangerOutline;
                tc = Theme.Danger;
                if (hover) brush = Theme.BrDangerTint;
                if (down) { brush = Theme.BrDangerTintH; pen = Theme.PenDangerP; }
            }
            else
            {
                if (hover) { brush = Theme.BrBtnH; pen = Theme.PenBtnH; }
                if (down) { brush = Theme.BrBtnP; pen = Theme.PenBtnP; }
            }
            int bw = Width - 1;
            int bh = Height - 1;
            if (bw >= 2 && bh >= 2)
            {
                GraphicsPath path = Theme.RoundPath(new Rectangle(0, 0, bw, bh),
                    Math.Floor(Height / 2.0));
                g.FillPath(brush, path);
                if (pen != null) g.DrawPath(pen, path);
                TextRenderer.DrawText(g, Text, Font, ClientRectangle, tc, Theme.TfCenter);
            }
        }
        catch { }
    }

    protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); Invalidate(); }
    protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); Invalidate(); }
    protected override void OnMouseDown(MouseEventArgs e)
    { base.OnMouseDown(e); pressed = this; Invalidate(); }
    protected override void OnMouseUp(MouseEventArgs e)
    { base.OnMouseUp(e); if (pressed == this) pressed = null; Invalidate(); }
    protected override void OnMouseCaptureChanged(EventArgs e)
    { base.OnMouseCaptureChanged(e); if (pressed == this) pressed = null; Invalidate(); }
    protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); Invalidate(); }

    // 工厂（对应 PS 的 New-AppleButton）
    public static AppleButton Make(string text, string kind, int w, int h)
    {
        AppleButton b = new AppleButton();
        b.Text = text;
        b.Kind = kind;
        b.SetBounds(0, 0, w, h);
        return b;
    }
}

// ---------------------------------------------------------------------------
// 白色圆角卡片（Title 非空时左上角画一行加粗标题）
// ---------------------------------------------------------------------------
internal class AppleCard : Panel
{
    private readonly Label titleLabel;

    public AppleCard(string title, Color bg, int radius)
    {
        BackColor = bg;
        Radius = radius;
        Theme.DoubleBuffer(this);
        if (title != null && title.Length > 0)
        {
            titleLabel = new Label();
            titleLabel.Text = title;
            titleLabel.Font = Theme.Card;
            titleLabel.ForeColor = Theme.Text;
            titleLabel.AutoSize = true;
            titleLabel.Location = new Point(16, 11);
            Controls.Add(titleLabel);
        }
    }

    public int Radius { get; private set; }

    // 卡片标题改色（例如「缓存清理」这类破坏性卡片标题用红色）
    public Color TitleColor
    {
        set { if (titleLabel != null) titleLabel.ForeColor = value; }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        try
        {
            int bw = Width - 1;
            int bh = Height - 1;
            if (bw < 4 || bh < 4) return;
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            GraphicsPath path = Theme.RoundPath(new Rectangle(0, 0, bw, bh), Radius);
            e.Graphics.FillPath(Theme.BrWhite, path);
            e.Graphics.DrawPath(Theme.PenStroke, path);
        }
        catch { }
    }
}

// ---------------------------------------------------------------------------
// 圆角输入框（外框 Panel + 无边框 TextBox / ComboBox）
//   Value 读写内部控件文本；TextBox / Combo 取内部控件本体。
// ---------------------------------------------------------------------------
internal class AppleField : Panel
{
    private readonly Control inner;

    public AppleField(int x, int y, int w, int h, string text, bool multi, bool readOnly, bool combo)
    {
        SetBounds(x, y, w, h);
        BackColor = Theme.White;
        int padY = multi ? 7 : 4;
        Padding = new Padding(9, padY, 9, padY);
        if (combo)
        {
            ComboBox c = new ComboBox();
            c.DropDownStyle = ComboBoxStyle.DropDownList;
            c.FlatStyle = FlatStyle.Flat;
            c.Dock = DockStyle.Fill;
            c.BackColor = Theme.White;
            Controls.Add(c);
            inner = c;
        }
        else
        {
            TextBox t = new TextBox();
            t.BorderStyle = BorderStyle.None;
            t.Dock = DockStyle.Fill;
            t.BackColor = Theme.White;
            // 多行文本归一：Win32 多行 EDIT 只把 CRLF（\r\n）当换行，
            // 存进纯 LF 的话 EM_GETLINECOUNT=1、界面把所有行压成一行（EM 实测抓到的）。
            if (multi)
            {
                t.Multiline = true;
                t.ScrollBars = ScrollBars.Vertical;
                if (text != null && text.IndexOf('\n') >= 0 && text.IndexOf('\r') < 0)
                    text = text.Replace("\n", "\r\n");
            }
            t.Text = text == null ? "" : text;
            if (readOnly) { t.ReadOnly = true; t.BackColor = Theme.BtnHover; }
            Controls.Add(t);
            inner = t;
        }
        inner.Enter += delegate { Invalidate(); };
        inner.Leave += delegate { Invalidate(); };
        Theme.DoubleBuffer(this);
    }

    public TextBox TextBox { get { return inner as TextBox; } }
    public ComboBox Combo { get { return inner as ComboBox; } }

    public string Value
    {
        get { return inner.Text; }
        set { inner.Text = value == null ? "" : value; }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        try
        {
            int bw = Width - 1;
            int bh = Height - 1;
            if (bw < 4 || bh < 4) return;
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            GraphicsPath path = Theme.RoundPath(new Rectangle(0, 0, bw, bh), 7);
            Brush fill = Theme.BrWhite;
            TextBox tb = inner as TextBox;
            if (tb != null && tb.ReadOnly) fill = Theme.BrBtnH;
            e.Graphics.FillPath(fill, path);
            bool focused = Controls.Count > 0 && Controls[0].Focused;
            e.Graphics.DrawPath(focused ? Theme.PenFocus : Theme.PenFBorder, path);
        }
        catch { }
    }
}

// ---------------------------------------------------------------------------
// 圆角徽章（计数用）
// ---------------------------------------------------------------------------
internal class AppleBadge : Panel
{
    private readonly Label lbl;

    public AppleBadge(string text, int x, int y, int w, int h)
    {
        SetBounds(x, y, w, h);
        BackColor = Theme.White;
        Theme.DoubleBuffer(this);
        lbl = new Label();
        lbl.Text = text;
        lbl.Font = Theme.Hint;
        lbl.ForeColor = Theme.Accent;
        lbl.Dock = DockStyle.Fill;
        lbl.TextAlign = ContentAlignment.MiddleCenter;
        Controls.Add(lbl);
    }

    public string BadgeText
    {
        get { return lbl.Text; }
        set { lbl.Text = value; }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        try
        {
            int bw = Width - 1;
            int bh = Height - 1;
            if (bw < 4 || bh < 4) return;
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            GraphicsPath path = Theme.RoundPath(new Rectangle(0, 0, bw, bh),
                Math.Floor(Height / 2.0));
            e.Graphics.FillPath(Theme.BrBadge, path);
            e.Graphics.DrawPath(Theme.PenBadge, path);
        }
        catch { }
    }
}

// ---------------------------------------------------------------------------
// 列表样式 / 隔行底色
// ---------------------------------------------------------------------------
internal static class Lst
{
    public static void Style(ListView lv, bool single)
    {
        lv.View = View.Details;
        lv.FullRowSelect = true;
        lv.MultiSelect = !single;
        lv.HideSelection = false;
        lv.GridLines = false;
        lv.BorderStyle = BorderStyle.None;
        lv.HeaderStyle = ColumnHeaderStyle.None;   // 表头自己画（ListHeader）
        lv.BackColor = Theme.White;
        lv.ForeColor = Theme.Text;
        lv.Font = Theme.Ui;
        lv.OwnerDraw = false;
        Theme.DoubleBuffer(lv);
    }

    public static void RowBands(ListView lv)
    {
        for (int i = 1; i < lv.Items.Count; i += 2) lv.Items[i].BackColor = Theme.AltRow;
    }

    // 列宽按客户区宽度算（出现竖向滚动条时 Width 会多算滚动条宽 → 横向错位）
    public static int AvailWidth(ListView lv)
    {
        int w = lv.ClientSize.Width;
        if (w <= 0) w = lv.Width;
        return w - 2;
    }
}

// ---------------------------------------------------------------------------
// 外置表头（白底 + 底部发丝线，标签严格按列宽排）
// ---------------------------------------------------------------------------
internal class ListHeader : Panel
{
    public readonly ListView List;
    public readonly List<Label> Labels = new List<Label>();

    public ListHeader(ListView lv, params string[] labels)
    {
        List = lv;
        BackColor = Theme.White;
        foreach (string t in labels)
        {
            Label l = new Label();
            l.Text = t;
            l.Font = Theme.Hint;
            l.ForeColor = Theme.Sub;
            l.TextAlign = ContentAlignment.MiddleLeft;
            Controls.Add(l);
            Labels.Add(l);
        }
        Theme.DoubleBuffer(this);
        SetLabels();
    }

    // 第 1 列内缩 8px、其余 10px，和原生 ListView 单元格对齐
    public void SetLabels()
    {
        int h = Height;
        if (h <= 0) h = 22;
        int x = 0;
        int n = Math.Min(List.Columns.Count, Labels.Count);
        for (int i = 0; i < n; i++)
        {
            int cw = List.Columns[i].Width;
            int pad = i == 0 ? 8 : 10;
            int w = cw - pad - 4;
            if (w < 10) w = 10;
            Labels[i].SetBounds(x + pad, 0, w, h);
            x += cw;
        }
    }

    public void SetHeaderBounds(int x, int y, int w, int h)
    {
        SetBounds(x, y, w, h);
        SetLabels();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        try
        {
            int y = Height - 1;
            e.Graphics.DrawLine(Theme.PenStroke, 0, y, Width, y);
        }
        catch { }
    }
}

// ---------------------------------------------------------------------------
// 通用对话框（Apple 样式：白底、圆角输入框、胶囊按钮）
// ---------------------------------------------------------------------------
internal class DialogField
{
    public string Label;
    public string Value;
    public DialogField(string label, string value) { Label = label; Value = value; }
}

internal class AppleDialogResult
{
    public bool OK;
    public string[] Values;
}

internal static class AppleDialog
{
    public static AppleDialogResult Show(IWin32Window owner, string title, string message,
        List<DialogField> fields, string okText, string cancelText, bool noCancel,
        string kind, bool multiFirst, bool requireFirst, int width)
    {
        if (fields == null) fields = new List<DialogField>();
        if (okText == null || okText.Length == 0) okText = "确定";
        if (cancelText == null || cancelText.Length == 0) cancelText = "取消";
        if (width <= 0) width = 470;

        Form dlg = new Form();
        dlg.Text = title;
        dlg.FormBorderStyle = FormBorderStyle.FixedDialog;
        dlg.MaximizeBox = false;
        dlg.MinimizeBox = false;
        dlg.StartPosition = FormStartPosition.CenterParent;
        dlg.AutoScaleMode = AutoScaleMode.None;
        dlg.BackColor = Theme.White;
        dlg.Font = Theme.Ui;

        int innerW = width - 36;
        int y = 18;
        if (message != null && message.Length > 0)
        {
            Size sz = TextRenderer.MeasureText(message, Theme.Ui, new Size(innerW, 0),
                TextFormatFlags.WordBreak | TextFormatFlags.NoPadding);
            int msgH = sz.Height;
            if (msgH < 18) msgH = 18;
            Label lblMsg = new Label();
            lblMsg.Text = message;
            lblMsg.Font = Theme.Ui;
            lblMsg.ForeColor = Theme.Text;
            lblMsg.AutoSize = false;
            lblMsg.SetBounds(18, y, innerW, msgH);
            dlg.Controls.Add(lblMsg);
            y = y + msgH + 12;
        }

        List<TextBox> boxes = new List<TextBox>();
        for (int i = 0; i < fields.Count; i++)
        {
            DialogField f = fields[i];
            if (f.Label != null && f.Label.Length > 0)
            {
                Label fl = new Label();
                fl.Text = f.Label;
                fl.Font = Theme.Hint;
                fl.ForeColor = Theme.Sub;
                fl.AutoSize = true;
                fl.Location = new Point(18, y);
                dlg.Controls.Add(fl);
                y = y + 18;
            }
            int fh = 30;
            bool multiThis = (i == 0 && multiFirst);
            if (multiThis) fh = 88;
            AppleField fld = new AppleField(18, y, innerW, fh,
                f.Value == null ? "" : f.Value, multiThis, false, false);
            dlg.Controls.Add(fld);
            boxes.Add(fld.TextBox);
            y = y + fh + 12;
        }

        Label err = null;
        int btnH = 30;
        int btnW = 86;
        int by = y + 2;
        if (requireFirst && boxes.Count > 0)
        {
            err = new Label();
            err.Font = Theme.Hint;
            err.ForeColor = Theme.Danger;
            err.AutoSize = false;
            err.SetBounds(18, by, innerW, 16);
            err.Text = "";
            dlg.Controls.Add(err);
            by = by + 18;
        }
        int totalH = by + btnH + 18;
        dlg.ClientSize = new Size(width, totalH);

        AppleButton ok = AppleButton.Make(okText, kind, btnW, btnH);
        ok.Left = width - 18 - btnW;
        ok.Top = by;
        dlg.Controls.Add(ok);

        if (!noCancel)
        {
            AppleButton cancel = AppleButton.Make(cancelText, "Plain", btnW, btnH);
            cancel.Left = ok.Left - 8 - btnW;
            cancel.Top = by;
            dlg.Controls.Add(cancel);
            cancel.Click += delegate
            {
                dlg.DialogResult = DialogResult.Cancel;
                dlg.Close();
            };
            dlg.CancelButton = cancel;
        }
        dlg.AcceptButton = ok;

        Label errLabel = err;
        ok.Click += delegate
        {
            if (errLabel != null)
            {
                string first = boxes.Count > 0 ? boxes[0].Text : "";
                if (string.IsNullOrEmpty(first) || first.Trim().Length == 0)
                {
                    errLabel.Text = "这一项不能为空。";
                    return;
                }
            }
            dlg.DialogResult = DialogResult.OK;
            dlg.Close();
        };

        dlg.ShowDialog(owner);

        AppleDialogResult result = new AppleDialogResult();
        result.OK = (dlg.DialogResult == DialogResult.OK);
        string[] vals = new string[boxes.Count];
        for (int i = 0; i < boxes.Count; i++) vals[i] = boxes[i].Text;
        result.Values = vals;
        dlg.Dispose();
        return result;
    }
}

// ---------------------------------------------------------------------------
// 自绘标签栏（2026-09-26 重写顶栏：替换原生 TabControl 的 owner-draw）
//
// 原来的问题（截图帧序列取证）：原生 SysTabControl32 是独立 HWND，owner-draw
// 一次选中要走「原生擦除 → 逐格重绘」多帧，实测抓到中间帧：
//   ① 整条栏空一帧（胶囊+文字全消失）② 白胶囊画了、文字还没画的空胶囊帧
//   → 用户看到的就是「顶栏跳动/闪」。DoubleBuffered 属性对原生控件无效。
//
// 重写后的保证：
//   * 单一受管 Panel，SetStyle 双缓冲 —— 每次状态变化只成一帧，原子上屏；
//   * 槽宽按「最粗的选中字体」一次算死：悬停/选中切换只换字重与颜色，
//     邻居槽位坐标恒定 —— 没有任何位移可跳；
//   * 无原生分隔线，底边一条发丝线，一次画完。
// ---------------------------------------------------------------------------
internal class AppleTabBar : Panel
{
    private readonly string[] labels;
    private readonly Font fontReg = Theme.Ui;
    private readonly Font fontSel = Theme.Tab;
    private readonly int[] slotX;   // 槽左边界；slotX[labels.Length] = 末尾 x
    private int selected;
    private int hover = -1;
    public event Action<int> TabChanged;

    public int Selected
    {
        get { return selected; }
        set { Select(value); }
    }

    public AppleTabBar(string[] texts)
    {
        labels = new string[texts.Length];
        for (int i = 0; i < texts.Length; i++) labels[i] = texts[i].Trim();
        slotX = new int[labels.Length + 1];
        int x = 14;
        for (int i = 0; i < labels.Length; i++)
        {
            slotX[i] = x;
            // 槽宽永远用「选中态（粗体）」的文本量：切换选中时槽位绝不动
            int tw = TextRenderer.MeasureText(labels[i], fontSel, Size.Empty,
                TextFormatFlags.NoPadding).Width;
            x += tw + 28;              // 左右各留 ~14px 呼吸
        }
        slotX[labels.Length] = x;

        Dock = DockStyle.Top;
        Height = 40;
        BackColor = Theme.Bg;
        SetStyle(ControlStyles.AllPaintingInWmPaint |
                 ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.UserPaint, true);
        Theme.DoubleBuffer(this);
    }

    public void Select(int i)
    {
        if (i < 0 || i >= labels.Length) return;
        if (i == selected) return;
        selected = i;
        Invalidate();
        if (TabChanged != null) TabChanged(i);
    }

    private int Hit(Point p)
    {
        for (int i = 0; i < labels.Length; i++)
            if (p.X >= slotX[i] && p.X < slotX[i + 1]) return i;
        return -1;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        int h = Hit(e.Location);
        if (h != hover) { hover = h; Invalidate(); }
    }

    protected override void OnMouseLeave(EventArgs e)
    {
        base.OnMouseLeave(e);
        if (hover != -1) { hover = -1; Invalidate(); }
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        int h = Hit(e.Location);
        if (h >= 0) Select(h);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        try
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Theme.Bg);
            for (int i = 0; i < labels.Length; i++)
            {
                bool sel = (i == selected);
                bool hov = (i == hover);
                int w = slotX[i + 1] - slotX[i] - 6;
                Rectangle r = new Rectangle(slotX[i], 6, w, Height - 12);
                if (sel && w > 8 && r.Height > 8)
                {
                    GraphicsPath pp = Theme.RoundPath(r, r.Height / 2.0);
                    g.FillPath(Theme.BrWhite, pp);
                    g.DrawPath(Theme.PenTabPill, pp);
                }
                else if (hov && w > 8 && r.Height > 8)
                {
                    GraphicsPath pp = Theme.RoundPath(r, r.Height / 2.0);
                    g.FillPath(Theme.BrTabHover, pp);
                }
                Color tc = (sel || hov) ? Theme.Text : Theme.Sub;
                Font f = sel ? fontSel : fontReg;
                TextRenderer.DrawText(g, labels[i], f, r, tc, Theme.TfCenter);
            }
            // 底边发丝线（替代原生标签分隔线）
            g.SmoothingMode = SmoothingMode.Default;
            g.DrawLine(Theme.PenStroke, 0, Height - 1, Width, Height - 1);
        }
        catch { }
        base.OnPaint(e);
    }
}

// ---------------------------------------------------------------------------
// 页面容器（替代 TabPage）：双缓冲 + 自动滚动，其它行为与 TabPage 一致
// ---------------------------------------------------------------------------
internal class ApplePage : Panel
{
    public ApplePage()
    {
        BackColor = Theme.Bg;
        AutoScroll = true;
        SetStyle(ControlStyles.AllPaintingInWmPaint |
                 ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.UserPaint |
                 ControlStyles.Selectable, true);
        // 可获焦（等同旧 TabPage）：点页面空白处后滚轮才能滚；切换页后焦点在窗体上
        // 时由 MainForm.OnMouseWheel 转发进来。
        TabStop = true;
        Theme.DoubleBuffer(this);
    }

    // 滚轮翻页（delta 为 MouseEventArgs.Delta，正=向上）
    public void ScrollByWheel(int delta)
    {
        int lines = delta / 120;
        if (lines == 0) lines = delta > 0 ? 1 : -1;
        int y = -AutoScrollPosition.Y - lines * 60;
        if (y < 0) y = 0;
        AutoScrollPosition = new Point(AutoScrollPosition.X, y);
    }
}
