param(
  [string]$RimeDir = 'D:\rime-sandbox',
  [switch]$ShowNow,
  [int]$Tab = -1,
  [switch]$DialogTest,
  [switch]$HotkeyTest,
  [switch]$RecordTest
)
# 小狼毫 v 功能 —— 可视化设置界面（WinForms · 统一 macOS 类苹果样式）
#
# 标签页（功能菜单）：
#   剪贴板历史 / 常用语 / 词库管理 / 设置与缓存 / 语音输入 / 防误触
#
# 「词库管理」即原独立软件 dict-manager.ps1（词库管理.bat）的功能，已整体集成进
# 本窗口：加词自动注音、权重、删除、搜索、加入常用语。管理的词库文件是
# $RimeDir\cn_dicts\mydict.dict.yaml —— 真正生效的目录（原独立软件写的
# %APPDATA%\Rime 旧副本不生效，那边也已改指同一目录）。
#
# 样式约定（Apple 浅色模式）：
#   页面底色 F5F5F7 · 白色圆角卡片(12px 描边 E3E3E8) · 主色 systemBlue #007AFF
#   危险色 #FF3B30 · 成功色 #34C759 · 输入框圆角描边(聚焦变蓝) · 按钮胶囊形
#   标签栏自绘（选中白色胶囊 + 深色粗体，未选中灰字，悬停变深）
#   列表自绘（隔行浅灰 + 选中淡蓝 D6E9FF，无网格线）
#   对话框为自绘白底窗口（圆角输入框 + 胶囊按钮），不用系统 MessageBox
#
# 与输入法共享同一批文件，格式与 lua/vmenu_core.lua 完全一致：
#   <RimeDir>\clipboard-cache.txt          剪贴板历史，一行一条，最新在最前，上限 50
#   <RimeDir>\cn_dicts\favorites.dict.yaml  常用语，正文在 "..." 之后，格式 内容<Tab>键<Tab>词频
#   <RimeDir>\cn_dicts\mydict.dict.yaml     个人词库，格式 词语<Tab>拼音<Tab>权重
#   <RimeDir>\vmenu-settings.txt            clip_page=<20|30|40|50> + misinput_*
#   <RimeDir>\voice-settings.txt            punct_to_space=true|false（语音识别标点改空格）
#                                            + hotkey=ctrl+win（语音输入快捷键，voice-overlay.py 读）
#     语音单独放一个文件：lua 的 write_page / write_misinput 会整文件重写
#     vmenu-settings.txt，不认识的字段会被冲掉，放一起会丢开关状态。
# 所有文件都以「UTF-8 无 BOM」写出：带 BOM 会让第一条剪贴板内容多出不可见字符。
#
# 本文件必须保存为「UTF-8 带 BOM」，否则 Windows PowerShell 5.1 会按 ANSI 解析，
# 界面上的中文会全部变成乱码。
#
# QA 辅助（平时用不到）：
#   -Tab N          启动后直接切到第 N 个标签页（0 起）
#   -DialogTest     打开窗口后弹一个示例对话框（检查对话框样式）
#   -HotkeyTest     只跑快捷键解析/校验/显示的自检，打印 OK/FAIL 后退出（不建窗口）
#   标记文件写 "tab:N" 也能让常驻窗口切到第 N 个标签页并显示

$ErrorActionPreference = 'Stop'

# 默认目录不可用时退回注册表里登记的 RimeUserDir，避免开了窗口却读不到文件
if (-not (Test-Path -LiteralPath $RimeDir)) {
  try {
    $reg = Get-ItemProperty -Path 'HKCU:\Software\Rime\Weasel' -Name RimeUserDir -ErrorAction Stop
    if ($reg.RimeUserDir -and (Test-Path -LiteralPath $reg.RimeUserDir)) { $RimeDir = $reg.RimeUserDir }
  } catch { }
}

# ---------------------------------------------------------------------------
# 单实例
#   已经有实例在跑时不要重复开窗口，而是写一个标记文件，
#   让常驻实例（每 60ms 看一次）立刻把窗口亮出来。
# ---------------------------------------------------------------------------
# 自检模式（-HotkeyTest / -RecordTest）是秒进秒出的无窗口跑法，**不参与单实例互斥**：
# 否则常驻实例持锁时自检会被直接挡在门外，一行测试都跑不到。
$qaMode = [bool]($HotkeyTest -or $RecordTest)
$mutex = $null
$isFirst = $qaMode
if (-not $qaMode) {
  $mutex = New-Object System.Threading.Mutex($false, 'RimeVMenuSettingsGui')
  try { $isFirst = $mutex.WaitOne(0) }
  catch [System.Threading.AbandonedMutexException] { $isFirst = $true }
  catch { $isFirst = $false }
}
if (-not $isFirst) {
  # 已经有常驻实例在跑。以前这里无条件写标记文件 —— 于是「开机自启」时
  # （VMenu.exe start 与守护会几乎同时各拉一次）输掉互斥体的那个实例会把
  # 标记写下去，常驻实例收到后就把窗口弹出来了：用户看到的「一启动就自己
  # 冒出来一个设置窗口」就是这个。现在只有本次启动本来就要求显示
  # （托盘/快捷方式带 -ShowNow、或调用方自己写了标记）才写。
  if ($ShowNow) {
    try {
      $flagPath0 = Join-Path $RimeDir 'open-settings.flag'
      [IO.File]::WriteAllText($flagPath0, 'open')
    } catch { }
  }
  exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

if (-not (Test-Path -LiteralPath $RimeDir)) {
  [void][System.Windows.Forms.MessageBox]::Show("找不到 Rime 用户目录：`n`n$RimeDir", '无法打开设置')
  exit 1
}

$UTF8 = New-Object Text.UTF8Encoding($false)
$CLIP_PATH = Join-Path $RimeDir 'clipboard-cache.txt'
$FAV_PATH = Join-Path $RimeDir 'cn_dicts\favorites.dict.yaml'
$MYDICT_PATH = Join-Path $RimeDir 'cn_dicts\mydict.dict.yaml'
$CHARMAP_PATH = Join-Path $RimeDir 'cn_dicts\8105.dict.yaml'
$SET_PATH = Join-Path $RimeDir 'vmenu-settings.txt'
$FLAG_PATH = Join-Path $RimeDir 'open-settings.flag'
$VOICE_SET_PATH = Join-Path $RimeDir 'voice-settings.txt'

$MAX_CLIP = 50
$MIN_PAGE = 20
$MAX_PAGE = 50
$STEP = 10

# 防误触（与 lua/vmenu_core.lua 的 M.MISINPUT_* 常量保持一致）
$MI_DEFAULT = 30   # 推荐值（ms）：人类最快打字 ≈ 300ms/键，30ms 远低于人类下限
$MI_MIN = 10
$MI_MAX = 200

# 个人词库（与 dict-manager.ps1 保持一致）
$DefaultWeight = 100000

$script:pageSize = $MIN_PAGE
$script:clip = @()
$script:favs = @()
$script:mydict = @()
$script:charMap = $null
$script:dictSearch = ''
$script:annotating = $false
$script:AppleBtnDown = $null
$script:tabHover = -1
$script:DlgState = $null

# ---------------------------------------------------------------------------
# Apple 主题（浅色模式）
# ---------------------------------------------------------------------------
$C_BG        = [Drawing.Color]::FromArgb(245, 245, 247)   # F5F5F7 页面底色
$C_WHITE     = [Drawing.Color]::White
$C_STROKE    = [Drawing.Color]::FromArgb(227, 227, 232)   # E3E3E8 卡片描边
$C_TEXT      = [Drawing.Color]::FromArgb(29, 29, 31)      # 1D1D1F 主文字
$C_SUB       = [Drawing.Color]::FromArgb(110, 110, 115)   # 6E6E73 次要文字
$C_TERT      = [Drawing.Color]::FromArgb(161, 161, 166)   # A1A1A6 弱文字
$C_ACCENT    = [Drawing.Color]::FromArgb(0, 122, 255)     # 007AFF systemBlue
$C_ACCENT_H  = [Drawing.Color]::FromArgb(30, 140, 255)    # 悬停
$C_ACCENT_P  = [Drawing.Color]::FromArgb(0, 102, 225)     # 按下
$C_DANGER    = [Drawing.Color]::FromArgb(255, 59, 48)     # FF3B30 systemRed
$C_DANGER_H  = [Drawing.Color]::FromArgb(255, 69, 58)
$C_DANGER_P  = [Drawing.Color]::FromArgb(215, 0, 21)
$C_GREEN     = [Drawing.Color]::FromArgb(52, 199, 89)     # 34C759 systemGreen
$C_SELROW    = [Drawing.Color]::FromArgb(214, 233, 255)   # D6E9FF 选中行
$C_ALTROW    = [Drawing.Color]::FromArgb(247, 247, 249)   # F7F7F9 隔行
$C_F_BORDER  = [Drawing.Color]::FromArgb(210, 210, 215)   # 输入框描边
$C_BTN_B     = [Drawing.Color]::FromArgb(217, 217, 222)   # 普通按钮描边
$C_BTN_B_H   = [Drawing.Color]::FromArgb(199, 199, 204)   # 普通按钮悬停描边
$C_DIS_FILL  = [Drawing.Color]::FromArgb(233, 233, 236)   # 禁用填充
$C_DIS_TEXT  = [Drawing.Color]::FromArgb(174, 174, 178)   # 禁用文字
$C_BADGE_BG  = [Drawing.Color]::FromArgb(232, 241, 255)   # 徽章底
$C_BADGE_BD  = [Drawing.Color]::FromArgb(187, 217, 255)   # 徽章描边

$FONT_UI   = New-Object Drawing.Font('Microsoft YaHei UI', 9)
$FONT_HINT = New-Object Drawing.Font('Microsoft YaHei UI', 8.5)
$FONT_CARD = New-Object Drawing.Font('Microsoft YaHei UI', 10.5, [Drawing.FontStyle]::Bold)
$FONT_PAGE = New-Object Drawing.Font('Microsoft YaHei UI', 11, [Drawing.FontStyle]::Bold)
$FONT_TAB  = New-Object Drawing.Font('Microsoft YaHei UI', 9, [Drawing.FontStyle]::Bold)

# ---------------------------------------------------------------------------
# 绘图基础 + 性能
#   自绘每帧 New-Object 画刷 / 画笔 / GraphicsPath 是之前卡顿的主因：实测单元格
#   自绘 0.907 ms/格（复用画刷 + [Rectangle]::new 后 0.511 ms），一次标签页切换
#   要烧掉约 69 ms CPU，滚动和拖窗口就会掉帧。所以：
#     · 所有画刷 / 画笔建一次放脚本作用域，反复用（不再每帧新建）；
#     · 圆角路径按尺寸缓存（GraphicsPath 最贵）；
#     · 自绘控件全部打开双缓冲（闪 = 另一种「卡顿」）。
# ---------------------------------------------------------------------------
function Enable-DoubleBuffer {
  # DoubleBuffered 是 protected 属性，只能反射设置；失败就算了（不影响功能）
  param($ctrl)
  try {
    $pi = [Windows.Forms.Control].GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic')
    if ($null -ne $pi) { [void]$pi.SetValue($ctrl, $true, $null) }
  } catch { }
}

$BR_WHITE    = New-Object Drawing.SolidBrush($C_WHITE)
$BR_ACCENT   = New-Object Drawing.SolidBrush($C_ACCENT)
$BR_ACCENT_H = New-Object Drawing.SolidBrush($C_ACCENT_H)
$BR_ACCENT_P = New-Object Drawing.SolidBrush($C_ACCENT_P)
$BR_DANGER   = New-Object Drawing.SolidBrush($C_DANGER)
$BR_DANGER_H = New-Object Drawing.SolidBrush($C_DANGER_H)
$BR_DANGER_P = New-Object Drawing.SolidBrush($C_DANGER_P)
$BR_BTN_H    = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(250, 250, 251))
$BR_BTN_P    = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(232, 232, 237))
$BR_DIS      = New-Object Drawing.SolidBrush($C_DIS_FILL)
$BR_BADGE    = New-Object Drawing.SolidBrush($C_BADGE_BG)
$BR_BG       = New-Object Drawing.SolidBrush($C_BG)

$PEN_STROKE  = New-Object Drawing.Pen($C_STROKE, 1)
$PEN_FBORDER = New-Object Drawing.Pen($C_F_BORDER, 1)
$PEN_FOCUS   = New-Object Drawing.Pen($C_ACCENT, 1.5)
$PEN_BTN     = New-Object Drawing.Pen($C_BTN_B, 1)
$PEN_BTN_H   = New-Object Drawing.Pen($C_BTN_B_H, 1)
$PEN_BTN_P   = New-Object Drawing.Pen($C_F_BORDER, 1)
$PEN_BADGE   = New-Object Drawing.Pen($C_BADGE_BD, 1)
$PEN_TABPILL = New-Object Drawing.Pen([Drawing.Color]::FromArgb(216, 216, 221), 1)

# TextFormatFlags 组合也是每次自绘都要用，预先算好
$TF_LEFT = [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor
           [System.Windows.Forms.TextFormatFlags]::NoPadding -bor
           [System.Windows.Forms.TextFormatFlags]::EndEllipsis -bor
           [System.Windows.Forms.TextFormatFlags]::Left
$TF_CENTER = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor
             [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor
             [System.Windows.Forms.TextFormatFlags]::NoPadding

$script:pathCache = @{}
function Get-RoundPath {
  # 圆角矩形路径（参数用 Rect / Radius：PowerShell 参数名大小写不敏感，不能叫 $r）
  # 同尺寸只构造一次并复用 —— GraphicsPath 构造 + 4 个 AddArc 很贵。
  param([Drawing.Rectangle]$Rect, [double]$Radius)
  $key = "$($Rect.X),$($Rect.Y),$($Rect.Width),$($Rect.Height),$Radius"
  $hit = $script:pathCache[$key]
  if ($null -ne $hit) { return $hit }
  $rad = $Radius
  $path = New-Object Drawing.Drawing2D.GraphicsPath
  $d = $rad * 2
  if ($d -gt $Rect.Width) { $rad = $Rect.Width / 2.0; $d = $rad * 2 }
  if ($d -gt $Rect.Height) { $rad = $Rect.Height / 2.0; $d = $rad * 2 }
  if ($rad -le 0.5) {
    $path.AddRectangle($Rect)
  } else {
    $path.AddArc($Rect.X, $Rect.Y, $d, $d, 180, 90)
    $path.AddArc($Rect.Right - $d, $Rect.Y, $d, $d, 270, 90)
    $path.AddArc($Rect.Right - $d, $Rect.Bottom - $d, $d, $d, 0, 90)
    $path.AddArc($Rect.X, $Rect.Bottom - $d, $d, $d, 90, 90)
    $path.CloseFigure()
  }
  if ($script:pathCache.Count -gt 128) { $script:pathCache.Clear() }
  $script:pathCache[$key] = $path
  return $path
}

# --- 胶囊按钮 ---------------------------------------------------------------
# Kind: Primary（蓝底白字）/ Plain（白底描边）/ Danger（红底白字）
function New-AppleButton {
  param([string]$Text, [string]$Kind = 'Plain', [int]$W = 110, [int]$H = 30)
  $b = New-Object Windows.Forms.Button
  $b.Text = $Text
  $b.SetBounds(0, 0, $W, $H)
  $b.FlatStyle = 'Flat'
  $b.FlatAppearance.BorderSize = 0
  $b.Cursor = 'Hand'
  $b.UseVisualStyleBackColor = $false
  try { $b.BackColor = [Drawing.Color]::Transparent } catch { $b.BackColor = $C_WHITE }
  $b.Tag = $Kind
  $b.Add_Paint({ param($s, $e) Draw-AppleButton $s $e })
  $b.Add_MouseEnter({ $this.Invalidate() })
  $b.Add_MouseLeave({ $this.Invalidate() })
  $b.Add_MouseDown({ $script:AppleBtnDown = $this; $this.Invalidate() })
  $b.Add_MouseUp({ $script:AppleBtnDown = $null; $this.Invalidate() })
  $b.Add_MouseCaptureChanged({
    if ($script:AppleBtnDown -eq $this) { $script:AppleBtnDown = $null }
    $this.Invalidate()
  })
  $b.Add_EnabledChanged({ $this.Invalidate() })
  Enable-DoubleBuffer $b
  return $b
}

function Draw-AppleButton {
  param($b, $e)
  try {
    $g = $e.Graphics
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $kind = 'Plain'
    if ($b.Tag -is [string] -and $b.Tag.Length -gt 0) { $kind = $b.Tag }
    $enabled = $b.Enabled
    $hover = $false
    $down = $false
    if ($enabled) {
      $pt = $b.PointToClient([Windows.Forms.Cursor]::Position)
      $hover = $b.ClientRectangle.Contains($pt)
      $down = ($script:AppleBtnDown -eq $b)
    }
    $brush = $BR_WHITE
    $pen = $PEN_BTN
    $tc = $C_TEXT
    if (-not $enabled) {
      $brush = $BR_DIS
      $pen = $null
      $tc = $C_DIS_TEXT
    } elseif ($kind -eq 'Primary') {
      $brush = $BR_ACCENT
      $pen = $null
      $tc = [Drawing.Color]::White
      if ($hover) { $brush = $BR_ACCENT_H }
      if ($down) { $brush = $BR_ACCENT_P }
    } elseif ($kind -eq 'Danger') {
      $brush = $BR_DANGER
      $pen = $null
      $tc = [Drawing.Color]::White
      if ($hover) { $brush = $BR_DANGER_H }
      if ($down) { $brush = $BR_DANGER_P }
    } else {
      if ($hover) { $brush = $BR_BTN_H; $pen = $PEN_BTN_H }
      if ($down) { $brush = $BR_BTN_P; $pen = $PEN_BTN_P }
    }
    $bw = $b.Width - 1
    $bh = $b.Height - 1
    if ($bw -lt 2 -or $bh -lt 2) { return }
    $path = Get-RoundPath ([Drawing.Rectangle]::new(0, 0, $bw, $bh)) ([Math]::Floor($b.Height / 2.0))
    $g.FillPath($brush, $path)
    if ($null -ne $pen) { $g.DrawPath($pen, $path) }
    [System.Windows.Forms.TextRenderer]::DrawText($g, $b.Text, $b.Font, $b.ClientRectangle, $tc, $TF_CENTER)
  } catch { }
}

# --- 白色圆角卡片 -----------------------------------------------------------
# Title 非空时在卡片左上角画一行加粗标题；Bg 是卡片外的底色（圆角外露出来）。
function New-AppleCard {
  param([string]$Title = '', [Drawing.Color]$Bg, [int]$Radius = 12)
  $p = New-Object Windows.Forms.Panel
  if ($null -eq $Bg) { $Bg = $C_BG }
  $p.BackColor = $Bg
  $p.Add_Paint({
    param($s, $e)
    try {
      $bw = $s.Width - 1
      $bh = $s.Height - 1
      if ($bw -lt 4 -or $bh -lt 4) { return }
      $e.Graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
      $path = Get-RoundPath ([Drawing.Rectangle]::new(0, 0, $bw, $bh)) $Radius
      $e.Graphics.FillPath($BR_WHITE, $path)
      $e.Graphics.DrawPath($PEN_STROKE, $path)
    } catch { }
  })
  Enable-DoubleBuffer $p
  if ($Title -ne '') {
    $lbl = New-Object Windows.Forms.Label
    $lbl.Text = $Title
    $lbl.Font = $FONT_CARD
    $lbl.ForeColor = $C_TEXT
    $lbl.AutoSize = $true
    $lbl.Location = New-Object Drawing.Point(16, 11)
    $p.Controls.Add($lbl)
  }
  return $p
}

# --- 圆角输入框（外框面板 + 无边框 TextBox/ComboBox） -------------------------
# 返回外框 Panel；内部控件挂在 .Tag 上（$field.Tag.Text）。
function New-AppleField {
  param(
    [int]$X, [int]$Y, [int]$W, [int]$H = 30,
    [string]$Text = '',
    [switch]$Multi, [switch]$ReadOnly, [switch]$Combo
  )
  $p = New-Object Windows.Forms.Panel
  $p.SetBounds($X, $Y, $W, $H)
  $p.BackColor = $C_WHITE
  $padY = 4
  if ($Multi) { $padY = 7 }
  $p.Padding = New-Object Windows.Forms.Padding(9, $padY, 9, $padY)
  $inner = $null
  if ($Combo) {
    $c = New-Object Windows.Forms.ComboBox
    $c.DropDownStyle = 'DropDownList'
    $c.FlatStyle = 'Flat'
    $c.Dock = 'Fill'
    $c.BackColor = $C_WHITE
    $p.Controls.Add($c)
    $inner = $c
  } else {
    $t = New-Object Windows.Forms.TextBox
    $t.BorderStyle = 'None'
    $t.Dock = 'Fill'
    $t.BackColor = $C_WHITE
    $t.Text = $Text
    if ($Multi) { $t.Multiline = $true; $t.ScrollBars = 'Vertical' }
    if ($ReadOnly) { $t.ReadOnly = $true; $t.BackColor = [Drawing.Color]::FromArgb(250, 250, 251) }
    $p.Controls.Add($t)
    $inner = $t
  }
  $p.Tag = $inner
  $inner.Add_Enter({ $this.Parent.Invalidate() })
  $inner.Add_Leave({ $this.Parent.Invalidate() })
  $p.Add_Paint({
    param($s, $e)
    try {
      $bw = $s.Width - 1
      $bh = $s.Height - 1
      if ($bw -lt 4 -or $bh -lt 4) { return }
      $e.Graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
      $path = Get-RoundPath ([Drawing.Rectangle]::new(0, 0, $bw, $bh)) 7
      # 只读框的底色 (250,250,251) 与普通按钮悬停色相同，直接复用缓存画刷
      $fill = $BR_WHITE
      if ($s.Tag -is [Windows.Forms.TextBox] -and $s.Tag.ReadOnly) { $fill = $BR_BTN_H }
      $e.Graphics.FillPath($fill, $path)
      $focused = $false
      if ($s.Controls.Count -gt 0) { $focused = $s.Controls[0].Focused }
      if ($focused) { $e.Graphics.DrawPath($PEN_FOCUS, $path) } else { $e.Graphics.DrawPath($PEN_FBORDER, $path) }
    } catch { }
  })
  Enable-DoubleBuffer $p
  return $p
}

# --- 圆角徽章（计数用） ------------------------------------------------------
function New-AppleBadge {
  param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H = 24)
  $p = New-Object Windows.Forms.Panel
  $p.SetBounds($X, $Y, $W, $H)
  $p.BackColor = $C_WHITE
  $p.Add_Paint({
    param($s, $e)
    try {
      $bw = $s.Width - 1
      $bh = $s.Height - 1
      if ($bw -lt 4 -or $bh -lt 4) { return }
      $e.Graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
      $path = Get-RoundPath ([Drawing.Rectangle]::new(0, 0, $bw, $bh)) ([Math]::Floor($s.Height / 2.0))
      $e.Graphics.FillPath($BR_BADGE, $path)
      $e.Graphics.DrawPath($PEN_BADGE, $path)
    } catch { }
  })
  Enable-DoubleBuffer $p
  $lbl = New-Object Windows.Forms.Label
  $lbl.Text = $Text
  $lbl.Font = $FONT_HINT
  $lbl.ForeColor = $C_ACCENT
  $lbl.Dock = 'Fill'
  $lbl.TextAlign = [Drawing.ContentAlignment]::MiddleCenter
  $p.Controls.Add($lbl)
  $p.Tag = $lbl
  return $p
}

# --- 列表样式（白底、无网格、隔行浅灰、选中淡蓝、自绘单元格） ------------------
function Style-AppleListView {
  # 用「原生行」而不是 OwnerDraw 自绘：OwnerDraw 每画一个单元格都要回调一次
  # PowerShell 脚本块（实测 0.907 ms/格），一次重绘 20 行 × 3 列就是 60 多次回调，
  # 滚动和拖窗口会明显卡顿；原生绘制整窗只要 ~5.5 ms（快 4 倍）。
  # 隔行浅灰改用 ListViewItem.BackColor（原生也认，实测整行生效），
  # 选中行用系统高亮（蓝底白字），观感和苹果列表一致。
  param($lv, [switch]$Single)
  $lv.View = 'Details'
  $lv.FullRowSelect = $true
  $lv.MultiSelect = (-not $Single)
  $lv.HideSelection = $false
  $lv.GridLines = $false
  $lv.BorderStyle = 'None'
  $lv.HeaderStyle = 'None'   # 表头自己画（见 New-AppleHeader）
  $lv.BackColor = $C_WHITE
  $lv.ForeColor = $C_TEXT
  $lv.Font = $FONT_UI
  $lv.OwnerDraw = $false
  Enable-DoubleBuffer $lv      # 不开双缓冲滚动时会闪，看着也像卡顿
}

function Set-ListRowBands {
  # 隔行浅灰：原生 ListView 只对 BackColor 生效的项上色，整行铺满
  param($lv)
  for ($i = 1; $i -lt $lv.Items.Count; $i += 2) { $lv.Items[$i].BackColor = $C_ALTROW }
}

# --- 外置表头 ---------------------------------------------------------------
# 表头自己画：OwnerDraw 时代系统表头（SysHeader32）在却不画字，所以关掉原生表头，
# 在列表上方放一条白色表头 + 底部发丝线；标签位置严格按列宽现算。
function New-AppleHeader {
  param($lv, [string[]]$Labels)
  $p = New-Object Windows.Forms.Panel
  $p.BackColor = $C_WHITE
  $p.Tag = @{ List = $lv; Labels = @() }
  foreach ($t in $Labels) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $t
    $l.Font = $FONT_HINT
    $l.ForeColor = $C_SUB
    $l.TextAlign = [Drawing.ContentAlignment]::MiddleLeft
    $p.Controls.Add($l)
    $p.Tag.Labels += $l
  }
  $p.Add_Paint({
    param($s, $e)
    try {
      $y = $s.Height - 1
      $e.Graphics.DrawLine($PEN_STROKE, 0, $y, $s.Width, $y)
    } catch { }
  })
  Enable-DoubleBuffer $p
  Set-AppleHeaderLabels $p
  return $p
}

function Set-AppleHeaderLabels {
  # 表头标签严格按当前列宽排；文字内缩和原生单元格对齐（第 1 列 8px、其余 10px，
  # 实测原生 ListView 的内缩就是这两个值）——对不上就是用户看到的「表头与数据错位」。
  param($hdr)
  $lv = $hdr.Tag.List
  $h = $hdr.Height
  if ($h -le 0) { $h = 22 }
  $x = 0
  for ($i = 0; $i -lt $lv.Columns.Count -and $i -lt $hdr.Tag.Labels.Count; $i++) {
    $cw = $lv.Columns[$i].Width
    $pad = 10
    if ($i -eq 0) { $pad = 8 }
    $w = $cw - $pad - 4
    if ($w -lt 10) { $w = 10 }
    $hdr.Tag.Labels[$i].SetBounds(($x + $pad), 0, $w, $h)
    $x += $cw
  }
}

function Set-AppleHeaderBounds {
  # 表头位置跟随列表；列宽变化后也必须再调一次（见 Fit-*Columns）
  param($hdr, [int]$X, [int]$Y, [int]$W, [int]$H)
  $hdr.SetBounds($X, $Y, $W, $H)
  Set-AppleHeaderLabels $hdr
}

# --- 列宽：一律按「客户区宽度」算 -------------------------------------------
# ListView 出现竖向滚动条时 ClientSize.Width 会自动扣掉滚动条宽度（96dpi 下 17px，
# 本机 150% DPI 虚拟化下实测 26px）。以前用 Width（含滚动条）算，列宽合计超出
# 客户区 → 冒出一条横向滚动条、最后一列被切、数据列还会横向滚走 —— 这正是
# 用户报的「错位」。现在统一按 ClientSize.Width 分配并留 2px 余量。
function Get-ListAvailWidth {
  param($lv)
  $w = $lv.ClientSize.Width
  if ($w -le 0) { $w = $lv.Width }
  return ($w - 2)
}

function Fit-ClipColumns {
  $avail = Get-ListAvailWidth $clipList
  $clipList.Columns[0].Width = 52
  $clipList.Columns[1].Width = [Math]::Max(160, $avail - 52)
  Set-AppleHeaderLabels $clipHeader
}

function Fit-FavColumns {
  $avail = Get-ListAvailWidth $favList
  $favList.Columns[0].Width = 52
  $favList.Columns[2].Width = 260
  $favList.Columns[1].Width = [Math]::Max(150, $avail - 52 - 260)
  Set-AppleHeaderLabels $favHeader
}

function Fit-DictColumns {
  $avail = Get-ListAvailWidth $dictList
  $wtW = 110
  $pyW = [int](($avail - $wtW) * 0.45)
  if ($pyW -lt 150) { $pyW = 150 }
  $dictList.Columns[2].Width = $wtW
  $dictList.Columns[1].Width = $pyW
  $dictList.Columns[0].Width = [Math]::Max(120, $avail - $pyW - $wtW)
  Set-AppleHeaderLabels $dictHeader
}

# ---------------------------------------------------------------------------
# 通用对话框（Apple 样式：白底、圆角输入框、胶囊按钮）
#   Fields: @(@{Label='…'; Value='…'}, …)
#   返回 [pscustomobject]@{ OK = <bool>; Values = @(…) }
#   事件处理必须走 $script:DlgState：ScriptBlock 在函数返回后看不到局部变量，
#   只有脚本作用域变量和 $this（= sender）可靠。
# ---------------------------------------------------------------------------
function Show-AppleDialog {
  param(
    [string]$Title,
    [string]$Message = '',
    [object[]]$Fields = @(),
    [string]$OKText = '确定',
    [string]$CancelText = '取消',
    [switch]$NoCancel,
    [string]$Kind = 'Primary',
    [switch]$MultiFirst,
    [switch]$RequireFirst,
    [int]$Width = 470
  )
  $dlg = New-Object Windows.Forms.Form
  $dlg.Text = $Title
  $dlg.FormBorderStyle = 'FixedDialog'
  $dlg.MaximizeBox = $false
  $dlg.MinimizeBox = $false
  $dlg.StartPosition = 'CenterParent'
  $dlg.AutoScaleMode = 'None'
  $dlg.BackColor = $C_WHITE
  $dlg.Font = $FONT_UI

  $innerW = $Width - 36
  $y = 18
  if ($Message -ne '') {
    $sz = [System.Windows.Forms.TextRenderer]::MeasureText(
      $Message, $FONT_UI, (New-Object Drawing.Size($innerW, 0)),
      [System.Windows.Forms.TextFormatFlags]::WordBreak -bor
      [System.Windows.Forms.TextFormatFlags]::NoPadding)
    $msgH = $sz.Height
    if ($msgH -lt 18) { $msgH = 18 }
    $lblMsg = New-Object Windows.Forms.Label
    $lblMsg.Text = $Message
    $lblMsg.Font = $FONT_UI
    $lblMsg.ForeColor = $C_TEXT
    $lblMsg.AutoSize = $false
    $lblMsg.SetBounds(18, $y, $innerW, $msgH)
    $dlg.Controls.Add($lblMsg)
    $y = $y + $msgH + 12
  }

  $boxes = @()
  $i = 0
  foreach ($f in $Fields) {
    $lblText = ''
    $val = ''
    if ($f -is [hashtable]) {
      if ($f.ContainsKey('Label')) { $lblText = "$($f.Label)" }
      if ($f.ContainsKey('Value')) { $val = "$($f.Value)" }
    }
    if ($lblText -ne '') {
      $fl = New-Object Windows.Forms.Label
      $fl.Text = $lblText
      $fl.Font = $FONT_HINT
      $fl.ForeColor = $C_SUB
      $fl.AutoSize = $true
      $fl.Location = New-Object Drawing.Point(18, $y)
      $dlg.Controls.Add($fl)
      $y = $y + 18
    }
    $fh = 30
    $multiThis = $false
    if ($i -eq 0 -and $MultiFirst) { $fh = 88; $multiThis = $true }
    $fld = New-AppleField -X 18 -Y $y -W $innerW -H $fh -Text $val -Multi:$multiThis
    $dlg.Controls.Add($fld)
    $boxes += $fld.Tag
    $y = $y + $fh + 12
    $i = $i + 1
  }

  $err = $null
  $btnH = 30
  $btnW = 86
  $by = $y + 2
  if ($RequireFirst -and $boxes.Count -gt 0) {
    $err = New-Object Windows.Forms.Label
    $err.Font = $FONT_HINT
    $err.ForeColor = $C_DANGER
    $err.AutoSize = $false
    $err.SetBounds(18, $by, $innerW, 16)
    $err.Text = ''
    $dlg.Controls.Add($err)
    $by = $by + 18
  }
  $totalH = $by + $btnH + 18
  $dlg.ClientSize = New-Object Drawing.Size($Width, $totalH)

  $ok = New-AppleButton -Text $OKText -Kind $Kind -W $btnW -H $btnH
  $ok.Left = $Width - 18 - $btnW
  $ok.Top = $by
  $dlg.Controls.Add($ok)

  $script:DlgState = @{ Dlg = $dlg; Boxes = $boxes; Err = $err }

  if (-not $NoCancel) {
    $cancel = New-AppleButton -Text $CancelText -Kind 'Plain' -W $btnW -H $btnH
    $cancel.Left = $ok.Left - 8 - $btnW
    $cancel.Top = $by
    $dlg.Controls.Add($cancel)
    $cancel.Add_Click({
      $script:DlgState.Dlg.DialogResult = [Windows.Forms.DialogResult]::Cancel
      $script:DlgState.Dlg.Close()
    })
    $dlg.CancelButton = $cancel
  }
  $dlg.AcceptButton = $ok

  $ok.Add_Click({
    $st = $script:DlgState
    if ($st.Err -ne $null) {
      $first = ''
      if ($st.Boxes.Count -gt 0) { $first = $st.Boxes[0].Text }
      if ([string]::IsNullOrWhiteSpace($first)) {
        $st.Err.Text = '这一项不能为空。'
        return
      }
    }
    $st.Dlg.DialogResult = [Windows.Forms.DialogResult]::OK
    $st.Dlg.Close()
  })

  $null = $dlg.ShowDialog($form)
  $vals = @()
  foreach ($bx in $script:DlgState.Boxes) { $vals += $bx.Text }
  $result = [pscustomobject]@{ OK = ($dlg.DialogResult -eq [Windows.Forms.DialogResult]::OK); Values = $vals }
  $script:DlgState = $null
  $dlg.Dispose()
  return $result
}

function Confirm {
  param([string]$Message, [string]$Title = '请确认')
  $r = Show-AppleDialog -Title $Title -Message $Message -Kind 'Danger' -OKText '确定' -CancelText '取消'
  return [bool]$r.OK
}

function Show-Info {
  param([string]$Message, [string]$Title = '提示')
  $null = Show-AppleDialog -Title $Title -Message $Message -Kind 'Primary' -OKText '知道了' -NoCancel
}

# ---------------------------------------------------------------------------
# 文件读写（UTF-8 无 BOM）
# ---------------------------------------------------------------------------
function Read-AllLines {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return @() }
  return @([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) -split "`r?`n")
}

function Write-TextFile {
  param([string]$Path, [string]$Text)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $tmp = "$Path.tmp"
  [IO.File]::WriteAllText($tmp, $Text, $UTF8)
  Move-Item -Force $tmp $Path
}

function Load-Settings {
  $script:pageSize = $MIN_PAGE
  $script:miEnabled = $true
  $script:miInterval = $MI_DEFAULT
  foreach ($line in (Read-AllLines -Path $SET_PATH)) {
    if ($line -match '^\s*clip_page\s*=\s*(\d+)') {
      $n = [int]$Matches[1]
      if ($n -ge $MIN_PAGE -and $n -le $MAX_PAGE) { $script:pageSize = $n }
    }
    if ($line -match '^\s*misinput_interval\s*=\s*(\d+)') {
      $n = [int]$Matches[1]
      if ($n -ge $MI_MIN -and $n -le $MI_MAX) { $script:miInterval = $n }
    }
    if ($line -match '^\s*misinput_protect\s*=\s*(\w+)') {
      $script:miEnabled = ($Matches[1] -eq 'true')
    }
  }
}

function Save-Settings {
  param([int]$Page)
  if ($Page -lt $MIN_PAGE) { $Page = $MIN_PAGE }
  if ($Page -gt $MAX_PAGE) { $Page = $MAX_PAGE }
  $script:pageSize = $Page
  Save-AllSettings
}

function Save-AllSettings {
  # 一次写全所有字段：任何一处保存都不会冲掉其它设置
  # （输入法端 lua 的 write_page / write_misinput 也是这种写法，两边一致）。
  $miOn = if ($script:miEnabled) { 'true' } else { 'false' }
  Write-TextFile -Path $SET_PATH -Text ("# v 功能菜单设置`nclip_page=$($script:pageSize)`nmisinput_protect=$miOn`nmisinput_interval=$($script:miInterval)`n")
}

# --- 语音输入设置（独立文件：lua 会整文件重写 vmenu-settings.txt，
#     标点开关放那里会被冲掉；voice-overlay.py 读的也是这个文件） ---
function Load-VoiceSettings {
  $script:punctSpace = $true   # 默认开：识别结果里的标点转成空格
  $script:hotkey = $HOTKEY_DEFAULT
  $script:asrThreads = $ASR_THREADS_DEFAULT
  foreach ($line in (Read-AllLines -Path $VOICE_SET_PATH)) {
    if ($line -match '^\s*punct_to_space\s*=\s*(\S+)') {
      $script:punctSpace = ($Matches[1] -match '^(1|true|on|yes)$')
    }
    if ($line -match '^\s*hotkey\s*=\s*(\S+)') {
      # 只认合法值：文件被人手改坏就退回默认，别把坏值显示出来又传给悬浮球
      $toks = @($Matches[1] -split '\+' | Where-Object { $_ })
      if (-not (Test-HotkeyTokens $toks)) { $script:hotkey = $Matches[1] }
    }
    if ($line -match '^\s*asr_threads\s*=\s*(\d+)') {
      # CPU 占用闸门：只认 1..物理核数，越界退回默认（写 0/999 会把机器打死）
      $n = [int]$Matches[1]
      if ($n -ge 1 -and $n -le $script:cpuPhysCores) { $script:asrThreads = $n }
    }
  }
}

function Save-VoiceSettings {
  $v = if ($script:punctSpace) { 'true' } else { 'false' }
  $txt = "# 语音输入设置（voice-overlay.py 读取）`npunct_to_space=$v`nhotkey=$($script:hotkey)`nasr_threads=$($script:asrThreads)`n"
  if ($script:hotkeyRecPid -gt 0) {
    # 录制中：让悬浮球暂停热键检测（它会查这个 pid 是否还活着）
    $txt += "hotkey_recorder_pid=$($script:hotkeyRecPid)`n"
  }
  Write-TextFile -Path $VOICE_SET_PATH -Text $txt
}

# 把「线程数」翻译成人话占用档位（实测数据来自本机 i7-13620H / 16 逻辑核）：
#   2 -> ~12%   4 -> ~26%   6 -> ~36%   8+ -> ~48% 以上（物理核外开始空转）
function Update-CpuControls {
  if (-not $lblCpuCur -or -not $trkCpu) { return }
  $n = [int]$trkCpu.Value
  $est = switch ($n) {
    { $_ -le 2 } { '约 12%' }
    { $_ -le 4 } { '约 26%' }
    { $_ -le 6 } { '约 36%' }
    { $_ -le 8 } { '约 48%' }
    default      { '可能打满' }
  }
  $speed = if ($n -le 2) { '识别最快' } elseif ($n -le 4) { '识别很快' } elseif ($n -le 6) { '识别较快' } else { '速度提升有限' }
  $lblCpuCur.Text = "当前：$n 线程 —— 整机 CPU $est，$speed"
  $lblCpuCur.ForeColor = if ($n -le 4) { $C_GREEN } elseif ($n -le 6) { $C_ACCENT } else { $C_DANGER }
}

# --- 快捷键（hotkey=ctrl+win 之类，voice-overlay.py 每 0.4s 看一次 mtime 热更新）---
# 录制方式：点「点击录制」按钮 -> **直接在键盘上按你想要的组合** -> 松开即录入。
# 录制期间写 hotkey_recorder_pid=<本进程 pid>：悬浮球查到这个进程还活着就暂停检测，
# 免得「录制」这个动作本身被当成一次长按触发；字段消失或 pid 不在了就自动恢复。
$HOTKEY_DEFAULT = 'ctrl+win'
# --- ASR 线程数（CPU 占用闸门）---
# llama.cpp 默认按逻辑核数（本机 16）开线程，空转自旋会把整机 CPU 打到 ~59%、
# 瞬时打满；限制到物理核以内实测整机占用降到 ~26%，且**总 CPU 消耗反而少 54%**，
# 墙钟只慢约 15ms。识别率与模型完全不变（同一份权重，只改并行度）。
$ASR_THREADS_DEFAULT = 4
$script:cpuPhysCores = 4
try {
  # 物理核数（不是逻辑核）：开到超过物理核只会空转自旋，越开越慢越费电
  $ci = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
  if ($ci.NumberOfCores -gt 0) { $script:cpuPhysCores = [int]$ci.NumberOfCores }
} catch {
  try { $script:cpuPhysCores = [int][Environment]::ProcessorCount } catch { }
}
$script:asrThreads = $ASR_THREADS_DEFAULT
$script:hotkey = $HOTKEY_DEFAULT
$script:hotkeyRecPid = 0
$script:hotState = ''                  # '' | lead | up | press | collect
$script:hotGot = @()
$script:hotLeadUntil = [DateTime]::MinValue
$script:hotEndAt = [DateTime]::MinValue

# 轮询读键（GetAsyncKeyState）——和 voice-overlay 同一套思路：**不装任何键盘钩子**，
# 对系统输入零风险；录制只在本窗口进行，焦点丢了也照样能录。
if (-not ('VMenuHotkey.Native' -as [type])) {
  Add-Type -Namespace VMenuHotkey -Name Native -MemberDefinition @'
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
'@
}
function Test-KeyDown([int]$Vk) {
  return (([VMenuHotkey.Native]::GetAsyncKeyState($Vk) -band 0x8000) -ne 0)
}

# 修饰键：左右两侧合并成一组（按任意一侧都算），顺序即显示顺序
$MOD_ORDER = @('ctrl', 'alt', 'shift', 'win')
$MOD_VKS = @{ ctrl = @(0xA2, 0xA3); alt = @(0xA4, 0xA5); shift = @(0xA0, 0xA1); win = @(0x5B, 0x5C) }

$KEY_VK = @{}                          # token -> vk
$VK_KEY = @{}                          # vk -> token（修饰键除外，它们单独聚合）
function Add-KeyMap([int]$Vk, [string]$Token) { $KEY_VK[$Token] = $Vk; $VK_KEY[$Vk] = $Token }
Add-KeyMap 0x08 'backspace'
Add-KeyMap 0x09 'tab'
Add-KeyMap 0x0D 'enter'
Add-KeyMap 0x1B 'esc'
Add-KeyMap 0x20 'space'
Add-KeyMap 0x21 'pageup'
Add-KeyMap 0x22 'pagedown'
Add-KeyMap 0x23 'end'
Add-KeyMap 0x24 'home'
Add-KeyMap 0x25 'left'
Add-KeyMap 0x26 'up'
Add-KeyMap 0x27 'right'
Add-KeyMap 0x28 'down'
Add-KeyMap 0x2C 'printscreen'
Add-KeyMap 0x2D 'insert'
Add-KeyMap 0x2E 'delete'
for ($i = 0; $i -lt 10; $i++) { Add-KeyMap (0x30 + $i) "$i" }
for ($i = 0; $i -lt 26; $i++) { Add-KeyMap (0x41 + $i) ([string][char](0x61 + $i)) }
for ($i = 1; $i -le 24; $i++) { Add-KeyMap (0x6F + $i) "f$i" }     # 0x70 = F1
$punctKeys = @{ 0xBA = 'semicolon'; 0xBB = 'equals'; 0xBC = 'comma'; 0xBD = 'minus'
  0xBE = 'period'; 0xBF = 'slash'; 0xC0 = 'backquote'; 0xDB = 'lbracket'
  0xDC = 'backslash'; 0xDD = 'rbracket'; 0xDE = 'quote' }
foreach ($k in $punctKeys.Keys) { Add-KeyMap ([int]$k) $punctKeys[$k] }
foreach ($m in $MOD_ORDER) { $KEY_VK[$m] = $MOD_VKS[$m][0] }        # 校验时要认识修饰键

$KEY_DISPLAY = @{ ctrl = 'Ctrl'; alt = 'Alt'; shift = 'Shift'; win = 'Win'
  space = '空格'; enter = '回车'; esc = 'Esc'; tab = 'Tab'; backspace = '退格'
  delete = 'Del'; insert = 'Ins'; home = 'Home'; end = 'End'; pageup = 'PgUp'
  pagedown = 'PgDn'; left = '←'; up = '↑'; right = '→'; down = '↓'
  printscreen = 'PrtSc'; semicolon = ';'; equals = '='; comma = ','; minus = '-'
  period = '.'; slash = '/'; backquote = '`'; lbracket = '['; backslash = '\'
  rbracket = ']'; quote = "'" }

function Get-HotkeyDownVks {
  # 当前按下的键。跳过通用修饰码（0x10/0x11/0x12，左右键会重复计一次）
  # 和 VK_PACKET（0xE7，注入字符时系统会短暂置位）。1..7 是鼠标，不参与。
  $got = @()
  for ($vk = 8; $vk -lt 256; $vk++) {
    if ($vk -eq 0x10 -or $vk -eq 0x11 -or $vk -eq 0x12 -or $vk -eq 0xE7) { continue }
    if (Test-KeyDown $vk) { $got += $vk }
  }
  return ,$got
}

function ConvertTo-HotkeyTokens([int[]]$Vks) {
  # vk 集合 -> token 数组（修饰键在前，其余按 vk 升序）—— 与 voice-overlay 一致
  $tokens = @()
  foreach ($m in $MOD_ORDER) {
    if ($Vks | Where-Object { $MOD_VKS[$m] -contains $_ }) { $tokens += $m }
  }
  $modVks = @($MOD_ORDER | ForEach-Object { $MOD_VKS[$_] } | ForEach-Object { $_ })
  $rest = @($Vks | Where-Object { $modVks -notcontains $_ } | Sort-Object)
  foreach ($vk in $rest) {
    if ($VK_KEY.ContainsKey([int]$vk)) { $tokens += $VK_KEY[[int]$vk] }
    else { $tokens += ('vk:0x{0:X2}' -f $vk) }   # 没名字的键也能存（悬浮球认这个写法）
  }
  return ,$tokens
}

function Test-HotkeyTokens([string[]]$Tokens) {
  # 合法返回 $null，否则返回中文错误提示（规则与 voice-overlay.parse_hotkey 完全一致）
  if (-not $Tokens -or $Tokens.Count -eq 0) { return '快捷键是空的' }
  if ($Tokens.Count -gt 4) { return '最多 4 个键' }
  if ((@($Tokens | Select-Object -Unique)).Count -ne $Tokens.Count) { return '按键重复' }
  foreach ($t in $Tokens) {
    if (-not $KEY_VK.ContainsKey($t)) { return "不认识这个按键：$t" }
  }
  $safe = @('ctrl', 'alt', 'win')
  if (-not ($Tokens | Where-Object { $safe -contains $_ })) {
    return '至少要包含 Ctrl / Alt / Win 之一（只有 Shift 会和正常打字冲突）'
  }
  if ($Tokens.Count -eq 1 -and $Tokens[0] -eq 'win') { return '单独按 Win 会弹出开始菜单，换一个组合' }
  return $null
}

function Get-HotkeyDisplay([string[]]$Tokens) {
  $parts = @()
  foreach ($t in $Tokens) {
    if ($KEY_DISPLAY.ContainsKey($t)) { $parts += $KEY_DISPLAY[$t] }
    elseif ($t.Length -eq 1) { $parts += $t.ToUpper() }            # a -> A
    elseif ($t -cmatch '^f\d{1,2}$') { $parts += $t.ToUpper() }     # f9 -> F9
    else { $parts += $t }
  }
  return ($parts -join ' + ')
}

function Get-HotkeyRisk([string[]]$Tokens) {
  # 提醒但**不拦截**：按住期间目标软件同样会收到这些按键（可能真执行复制/粘贴）
  $mods = @('ctrl', 'alt')
  if (-not ($Tokens | Where-Object { $mods -contains $_ })) { return $null }
  $keys = @($Tokens | Where-Object { $MOD_ORDER -notcontains $_ })
  if (($Tokens -contains 'ctrl') -and ($keys -contains 'space')) {
    return 'Ctrl+空格 会和小狼毫的中英切换冲突，建议换一个组合'
  }
  foreach ($k in $keys) {
    if ($k -cmatch '^[a-z0-9]$') {
      return '按住期间目标软件也会收到这些按键，可能触发它自己的快捷键（复制/粘贴等）；更稳妥可选 F1~F12'
    }
  }
  return $null
}

function Get-HotkeyTokens([string]$Config) {
  # 'ctrl+win' -> token 数组（非法 -> 默认）
  $toks = @([string]$Config -split '\+' | Where-Object { $_ })
  if (Test-HotkeyTokens $toks) { return ,@($HOTKEY_DEFAULT -split '\+') }
  return ,$toks
}

# --- 自检：powershell -File vmenu-settings-gui.ps1 -HotkeyTest（不建窗口，秒出结果）---
if ($HotkeyTest) {
  $fails = @()
  function Assert([bool]$Cond, [string]$Msg) { if (-not $Cond) { $script:fails += $Msg } }

  Assert (-not (Test-HotkeyTokens @('ctrl', 'win'))) 'ctrl+win 应合法'
  Assert (-not (Test-HotkeyTokens @('ctrl', 'alt', 'space'))) 'ctrl+alt+space 应合法'
  Assert ([bool](Test-HotkeyTokens @())) '空快捷键必须拒绝'
  Assert ([bool](Test-HotkeyTokens @('shift', 'a'))) '只有 Shift 必须拒绝（会撞正常打字）'
  Assert ([bool](Test-HotkeyTokens @('win'))) '单独 Win 必须拒绝（弹开始菜单）'
  Assert ([bool](Test-HotkeyTokens @('ctrl', 'nope'))) '未知按键必须拒绝'
  Assert ([bool](Test-HotkeyTokens @('ctrl', 'a', 'a'))) '重复按键必须拒绝'
  Assert ([bool](Test-HotkeyTokens @('ctrl', 'f1', 'f2', 'f3', 'f4', 'f5'))) '超过 4 键必须拒绝'

  # 显示断言必须 -ceq（PowerShell 的 -eq 不分大小写，会把 f9/F9 判成一样）
  Assert ((Get-HotkeyDisplay @('ctrl', 'win')) -ceq 'Ctrl + Win') '显示 Ctrl + Win'
  Assert ((Get-HotkeyDisplay @('alt', 'space')) -ceq 'Alt + 空格') '显示 Alt + 空格'
  Assert ((Get-HotkeyDisplay @('f9')) -ceq 'F9') '显示 F9（不能是 f9）'
  Assert ((Get-HotkeyDisplay @('ctrl', 'alt', 'f9')) -ceq 'Ctrl + Alt + F9') '显示 Ctrl + Alt + F9'

  $rt = Get-HotkeyTokens 'ctrl+alt+space'
  Assert (($rt -join ',') -eq 'ctrl,alt,space') '配置串读取 ctrl+alt+space'
  Assert (((Get-HotkeyTokens 'shift+a') -join ',') -eq 'ctrl,win') '非法配置要退回默认'

  $tk = ConvertTo-HotkeyTokens @(0xA2, 0x20)                 # 左 Ctrl + 空格
  Assert (($tk -join ',') -eq 'ctrl,space') 'vk 集合 -> ctrl+space'
  $tk2 = ConvertTo-HotkeyTokens @(0xA3, 0x41)                # 右 Ctrl + A
  Assert (($tk2 -join ',') -eq 'ctrl,a') '右侧 Ctrl 也算 ctrl'
  $tk3 = ConvertTo-HotkeyTokens @(0xA0, 0x74)                # 左 Shift + F5
  Assert (($tk3 -join ',') -eq 'shift,f5') 'vk 集合 -> shift+f5'
  Assert ((Get-HotkeyTokens ((ConvertTo-HotkeyTokens @(0xA2, 0x5B)) -join '+')) -join ',' -eq 'ctrl,win') `
    '往返 ctrl+win'
  Assert ([bool](Get-HotkeyRisk @('ctrl', 'c'))) 'Ctrl+C 要给风险提醒'
  Assert (-not (Get-HotkeyRisk @('ctrl', 'f9'))) 'Ctrl+F9 不需要提醒'

  if ($fails.Count) { $fails | ForEach-Object { "FAIL: $_" }; exit 1 }
  'ps-hotkey selftest OK'
  exit 0
}

# --- 前后鼻音模糊设置（独立文件 fuzzy-settings.txt，voice-settings.txt 同款做法）---
#     由 lua/fuzzy_filter.lua 每秒至多读一次：改动保存后 1 秒内在输入法里生效，
#     不走 vmenu-settings.txt（那个文件 lua 端会整文件重写，会把未知字段冲掉）。
$FZ_SET_PATH = Join-Path $RimeDir 'fuzzy-settings.txt'
$script:fzLoading = $false
$script:fzNasal = $true   # 默认开启前后鼻音模糊

function Load-FuzzySettings {
  $script:fzNasal = $true   # 文件缺失 / 字段缺失 = 开启
  foreach ($line in (Read-AllLines -Path $FZ_SET_PATH)) {
    if ($line -match '^\s*nasal\s*=\s*(\S+)') {
      $script:fzNasal = -not ($Matches[1] -match '^(0|false|off|no)$')
    }
  }
}

function Save-FuzzySettings {
  $v = if ($script:fzNasal) { 'true' } else { 'false' }
  Write-TextFile -Path $FZ_SET_PATH -Text ("# 前后鼻音模糊输入（fuzzy_filter.lua 读取）`nnasal=$v`n")
}

function Update-FuzzyControls {
  # 初始载入与每次重新显示窗口时刷新（文件可能被外部改动）
  if ($null -eq $chkFuzzy) { return }
  $script:fzLoading = $true            # 抑制 CheckedChanged 里的保存副作用
  try { $chkFuzzy.Checked = [bool]$script:fzNasal } finally { $script:fzLoading = $false }
  if ($script:fzNasal) {
    $lblFuzzyState.Text = '当前：开启（模糊词保留并显示真实拼音）'
    $lblFuzzyState.ForeColor = $C_GREEN
  } else {
    $lblFuzzyState.Text = '当前：关闭（只显示与输入完全一致的词）'
    $lblFuzzyState.ForeColor = $C_TERT
  }
}

function Update-VoiceControls {
  # 初始载入与每次重新显示窗口时刷新（文件可能被外部改动）
  if ($null -eq $chkPunct) { return }
  $script:voiceLoading = $true          # 抑制 CheckedChanged 里的保存副作用
  try { $chkPunct.Checked = [bool]$script:punctSpace } finally { $script:voiceLoading = $false }
  $lblPunctState.Text = "当前：$(if ($script:punctSpace) { '标点 → 空格' } else { '保留标点' })"
  if ($script:punctSpace) { $lblPunctState.ForeColor = $C_GREEN } else { $lblPunctState.ForeColor = $C_TERT }
  try { $script:voiceLoading = $true; $trkCpu.Value = [int]$script:asrThreads } finally { $script:voiceLoading = $false }
  Update-CpuControls
  if ($null -eq $btnHotkey) { return }
  if ($script:hotState) { return }      # 正在录制，别把进行中的提示刷掉
  $disp = Get-HotkeyDisplay (Get-HotkeyTokens $script:hotkey)
  $btnHotkey.Text = $disp
  $lblHotState.Text = "当前：$disp（长按说话，松开结束）"
  $lblHotState.ForeColor = $C_GREEN
}

function Update-MiControls {
  # 把当前设置刷到防误触页的控件上（初始载入与每次重新显示窗口时调用）
  if ($null -eq $chkMiEnable) { return }
  $chkMiEnable.Checked = [bool]$script:miEnabled
  $n = [int]$script:miInterval
  if ($n -lt $MI_MIN) { $n = $MI_MIN }
  if ($n -gt $MI_MAX) { $n = $MI_MAX }
  $trkMi.Value = $n
  $txtMi.Text = "$n"
  if ($script:miEnabled) {
    $lblMiState.Text = "当前：启用 · $n ms"
    $lblMiState.ForeColor = $C_GREEN
  } else {
    $lblMiState.Text = "当前：关闭 · $n ms"
    $lblMiState.ForeColor = $C_TERT
  }
}

function Clip-Stamp {
  # 剪贴板缓存文件的指纹（修改时间 + 长度），用来发现「别处改过它」：
  # v 菜单里清空历史、后台 clipboard-sync 新增了一条，都会改这个文件。
  $fi = Get-Item -LiteralPath $CLIP_PATH -ErrorAction SilentlyContinue
  if ($null -eq $fi) { return 'missing' }
  return ('{0}:{1}' -f $fi.LastWriteTimeUtc.Ticks, $fi.Length)
}

function Load-Clipboard {
  $list = New-Object System.Collections.ArrayList
  foreach ($line in (Read-AllLines -Path $CLIP_PATH)) {
    $t = "$line".Trim()
    if ($t.Length -gt 0) {
      [void]$list.Add($t)
      if ($list.Count -ge $MAX_CLIP) { break }
    }
  }
  $script:clip = @($list)
}

function Save-Clipboard {
  $text = ''
  if ($script:clip.Count -gt 0) { $text = ($script:clip -join "`n") + "`n" }
  Write-TextFile -Path $CLIP_PATH -Text $text
}

$FAV_HEADER = "# Rime dictionary`n# encoding: utf-8`n---`nname: favorites`nversion: `"2026-09-11`"`nsort: by_weight`n...`n"

function Load-Favorites {
  $list = New-Object System.Collections.ArrayList
  $body = $false
  foreach ($line in (Read-AllLines -Path $FAV_PATH)) {
    if (-not $body) {
      if ($line -match '^\.\.\.') { $body = $true }
      continue
    }
    $parts = $line -split "`t"
    if ($parts.Count -ge 2) {
      $w = $parts[0].Trim()
      $k = $parts[1].Trim()
      if ($w.Length -gt 0 -and $k.Length -gt 0) {
        [void]$list.Add([pscustomobject]@{ Word = $w; Key = $k })
      }
    }
  }
  $script:favs = @($list)
}

function Save-Favorites {
  $sb = New-Object Text.StringBuilder
  [void]$sb.Append($FAV_HEADER)
  foreach ($f in $script:favs) {
    [void]$sb.Append($f.Word).Append("`t").Append($f.Key).Append("`t100000`n")
  }
  Write-TextFile -Path $FAV_PATH -Text $sb.ToString()
}

# ---------------------------------------------------------------------------
# 个人词库（mydict）—— 逻辑与原 dict-manager.ps1 一致，目录改用生效的 $RimeDir
# ---------------------------------------------------------------------------
$MYDICT_HEADER = @(
  '# Rime dictionary',
  '# encoding: utf-8',
  '#',
  '# 个人词库（自己加词用，不会被雾凇更新覆盖）',
  '# 格式：词语<Tab>拼音（空格分隔）<Tab>权重（可选，越大越靠前）',
  '# 示例：',
  '# 雾凇	wu song	100000',
  '# 打工人	da gong ren	10000',
  '#',
  '---',
  'name: mydict',
  'version: "2026-09-06"',
  'sort: by_weight',
  '...',
  '',
  '# 下面开始写你的词，一行一个'
)

function Import-CharMap {
  # 单字拼音表（从 8105 字表加载，取权重最高的读音）；只加载一次。
  if ($null -ne $script:charMap) { return }
  $script:charMap = @{}
  if (-not (Test-Path -LiteralPath $CHARMAP_PATH)) { return }
  foreach ($line in [IO.File]::ReadAllLines($CHARMAP_PATH, [Text.Encoding]::UTF8)) {
    if ($line -match "^([^\t]+?)\t([a-züv ]+?)(?:\t(\d+))?\s*$") {
      $ch = $Matches[1]
      $py = $Matches[2].Trim()
      if ($ch.Length -ne 1 -or $py -eq '') { continue }
      $w = 1
      if ($Matches[3]) { $w = [long]$Matches[3] }
      if (-not $script:charMap.ContainsKey($ch)) { $script:charMap[$ch] = @() }
      $script:charMap[$ch] += [pscustomobject]@{ py = $py; w = $w }
    }
  }
}

function Get-AutoPinyin {
  param([string]$Word)
  Import-CharMap
  $parts = @()
  $unknown = @()
  foreach ($c in $Word.ToCharArray()) {
    $s = [string]$c
    if ($s -match '^[A-Za-z0-9]$') { $parts += $s.ToLower(); continue }
    if ($script:charMap.ContainsKey($s)) {
      $parts += ($script:charMap[$s] | Sort-Object w -Descending | Select-Object -First 1).py
    } else {
      $unknown += $s
      $parts += '?'
    }
  }
  return @{ pinyin = ($parts -join ' '); unknown = $unknown }
}

function Read-MyDict {
  $entries = @()
  if (-not (Test-Path -LiteralPath $MYDICT_PATH)) { return $entries }
  foreach ($line in [IO.File]::ReadAllLines($MYDICT_PATH, [Text.Encoding]::UTF8)) {
    if ($line -match "^(.+?)\t([A-Za-züv' ]+?)(?:\t(\d+))?\s*$") {
      $w = $Matches[1]
      if ($w.StartsWith('#') -or $w.StartsWith('-')) { continue }
      $wt = $DefaultWeight
      if ($Matches[3]) { $wt = [long]$Matches[3] }
      $entries += [pscustomobject]@{ Word = $w; Pinyin = $Matches[2].Trim(); Weight = $wt }
    }
  }
  return $entries
}

function Save-MyDict {
  param($Entries)
  $header = @()
  $foundMarker = $false
  if (Test-Path -LiteralPath $MYDICT_PATH) {
    foreach ($line in [IO.File]::ReadAllLines($MYDICT_PATH, [Text.Encoding]::UTF8)) {
      if (-not $foundMarker) {
        $header += $line
        if ($line -eq '# 下面开始写你的词，一行一个') { $foundMarker = $true }
      }
    }
  }
  if (-not $foundMarker) { $header = $MYDICT_HEADER }
  $lines = @() + $header
  $i = 0
  $indexed = foreach ($e in $Entries) { [pscustomobject]@{ e = $e; i = ($i++) } }
  foreach ($x in ($indexed | Sort-Object @{ Expression = { $_.e.Weight }; Descending = $true }, @{ Expression = { $_.i } })) {
    $lines += "$($x.e.Word)`t$($x.e.Pinyin)`t$($x.e.Weight)"
  }
  [IO.File]::WriteAllLines($MYDICT_PATH, $lines, $UTF8)
}

# ---------------------------------------------------------------------------
# 窗体
# ---------------------------------------------------------------------------
$form = New-Object Windows.Forms.Form
$form.Text = '小狼毫 v 功能 · 可视化设置'
$form.AutoScaleMode = 'None'
$form.ClientSize = New-Object Drawing.Size(960, 620)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object Drawing.Size(820, 520)
$form.Font = $FONT_UI
$form.BackColor = $C_BG
# 整窗双缓冲：拖窗口 / 切页不再闪（闪看着就是卡顿）。
# 注意 DoubleBuffered 是 protected 属性，直接 $form.DoubleBuffered = $true 会报
# 「找不到属性 DoubleBuffered」并让脚本当场退出（这次就是这么崩的），必须走反射。
Enable-DoubleBuffer $form

$tabs = New-Object Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabs.Padding = New-Object Drawing.Point(20, 9)
$tabs.BackColor = $C_BG
$tabs.DrawMode = 'OwnerDrawFixed'
# 标签栏是自绘的，不双缓冲的话切换/悬停时整条标签栏会先刷成底色再画字，
# 看起来就是「闪一下」。
Enable-DoubleBuffer $tabs

$tabClip = New-Object Windows.Forms.TabPage
$tabClip.Text = '  剪贴板历史  '
$tabFav = New-Object Windows.Forms.TabPage
$tabFav.Text = '  常用语  '
$tabDict = New-Object Windows.Forms.TabPage
$tabDict.Text = '  词库管理  '
$tabSet = New-Object Windows.Forms.TabPage
$tabSet.Text = '  设置与缓存  '
$tabVoice = New-Object Windows.Forms.TabPage
$tabVoice.Text = '  语音输入  '
$tabMi = New-Object Windows.Forms.TabPage
$tabMi.Text = '  防误触  '
foreach ($tp in @($tabClip, $tabFav, $tabDict, $tabSet, $tabVoice, $tabMi)) {
  $tp.BackColor = $C_BG
  [void]$tabs.TabPages.Add($tp)
}

# 标签栏自绘：选中 = 白色胶囊 + 深色粗体；未选中 = 灰字（悬停变深）
$tabs.Add_DrawItem({
  param($s, $e)
  try {
    $g = $e.Graphics
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $r = $e.Bounds
    # 先整格铺底色，盖掉原生标签底纹
    $fx = $r.X
    $fw = $r.Width + 1
    if ($fx -gt 0) { $fx = $r.X - 1; $fw = $r.Width + 2 }
    $bgRect = New-Object Drawing.Rectangle($fx, $r.Y, $fw, $r.Height)
    $bgBrush = New-Object Drawing.SolidBrush($C_BG)
    $g.FillRectangle($bgBrush, $bgRect)
    $sel = ($s.SelectedIndex -eq $e.Index)
    $tc = $C_SUB
    $font = $s.Font
    if ($sel) {
      $px = $r.X + 2
      $py = $r.Y + 4
      $pw = $r.Width - 4
      $ph = $r.Height - 8
      if ($pw -gt 4 -and $ph -gt 4) {
        # 选中胶囊：路径按尺寸缓存、画刷/画笔预先建好（每帧 New-Object 会掉帧）
        $ppath = Get-RoundPath ([Drawing.Rectangle]::new($px, $py, $pw, $ph)) ($ph / 2.0)
        $g.FillPath($BR_WHITE, $ppath)
        $g.DrawPath($PEN_TABPILL, $ppath)
      }
      $tc = $C_TEXT
      $font = $FONT_TAB
    } elseif ($e.Index -eq $script:tabHover) {
      $tc = $C_TEXT
    }
    [System.Windows.Forms.TextRenderer]::DrawText($g, $s.TabPages[$e.Index].Text.Trim(), $font, $r, $tc, $TF_CENTER)
  } catch { }
})
$tabs.Add_MouseMove({
  $p = $this.PointToClient([Windows.Forms.Cursor]::Position)
  $hit = -1
  for ($i = 0; $i -lt $this.TabCount; $i++) {
    if ($this.GetTabRect($i).Contains($p)) { $hit = $i; break }
  }
  if ($hit -ne $script:tabHover) {
    $script:tabHover = $hit
    # 只重画标签条自己：Invalidate($false) 不连子控件一起作废，
    # 否则鼠标在标签上移一下就会把整页（含列表）重画一遍。
    $this.Invalidate($false)
  }
})
$tabs.Add_MouseLeave({ $script:tabHover = -1; $this.Invalidate($false) })
$tabs.Add_SelectedIndexChanged({
  # 同上：标签条重画就够了，新显示的那一页自己会画。
  $this.Invalidate($false)
  # 刚显示出来的页是在这一刻才拿到最终尺寸的（TabControl 先设 Bounds 再报选中变化），
  # 所以切页后必须重排。标记故意不清：万一时序上拿到的还是旧尺寸，
  # 主循环 60ms 内会再补排一次（这一步就是治「切页/缩放后错位」的关键）。
  $script:layoutDirty = $true
  if ($script:layoutReady) { Layout-Tabs }
})

$status = New-Object Windows.Forms.StatusStrip
$status.BackColor = $C_WHITE
$status.SizingGrip = $false
Enable-DoubleBuffer $status       # 底部状态栏也是自绘的，一起双缓冲
$statusLabel = New-Object Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = '就绪'
$statusLabel.Spring = $true
$statusLabel.TextAlign = 'MiddleLeft'
$statusLabel.ForeColor = $C_SUB
$statusLabel.Font = $FONT_HINT
[void]$status.Items.Add($statusLabel)
$status.Add_Paint({
  param($s, $e)
  try {
    $e.Graphics.DrawLine($PEN_STROKE, 0, 0, $s.ClientSize.Width, 0)
  } catch { }
})

# ===== 剪贴板页 =====
# 位置一律由 Layout-Tabs 按「实际客户区尺寸」现算，不用 Dock / Anchor：
# 本进程没有 DPI 感知清单，Windows 会对坐标做 DPI 虚拟化，写死的绝对坐标会被
# 平移放大，按钮会跑到窗口外面（表现为「只有列表、没有按钮」）。
$clipInfo = New-Object Windows.Forms.Label
$clipInfo.Padding = New-Object Windows.Forms.Padding(16, 13, 16, 0)
$clipInfo.ForeColor = $C_SUB
$clipInfo.Text = ''

$clipList = New-Object Windows.Forms.ListView
Style-AppleListView $clipList
[void]$clipList.Columns.Add('序', 52)
[void]$clipList.Columns.Add('剪贴板内容（最新在最上面）', 720)
$clipHeader = New-AppleHeader $clipList @('序', '剪贴板内容（最新在最上面）')

$clipCard = New-AppleCard

$btnClipCopy   = New-AppleButton -Text '复制到剪贴板' -Kind 'Plain' -W 150 -H 32
$btnClipDel    = New-AppleButton -Text '删除选中' -Kind 'Plain' -W 150 -H 32
$btnClipClear  = New-AppleButton -Text '清空全部' -Kind 'Plain' -W 150 -H 32
$btnClipReload = New-AppleButton -Text '重新载入' -Kind 'Plain' -W 150 -H 32
$btnClipTop    = New-AppleButton -Text '把选中项置顶' -Kind 'Plain' -W 150 -H 32

$clipHint = New-Object Windows.Forms.Label
$clipHint.ForeColor = $C_SUB
$clipHint.Font = $FONT_HINT
$clipHint.Text = "输入法里按 v → 2 可以快速取用。`n`n双击某一条可以直接编辑。`n`n超过 50 条时自动丢弃最旧的。`n`n多行内容会被压平成一行。"

function Refresh-Clipboard {
  Load-Clipboard
  $script:clipStamp = Clip-Stamp
  $clipList.BeginUpdate()
  $clipList.Items.Clear()
  for ($i = 0; $i -lt $script:clip.Count; $i++) {
    $t = $script:clip[$i]
    $show = $t
    if ($show.Length -gt 160) { $show = $show.Substring(0, 160) + ' …' }
    $it = New-Object Windows.Forms.ListViewItem(("" + ($i + 1)))
    [void]$it.SubItems.Add($show)
    $it.Tag = $i
    [void]$clipList.Items.Add($it)
  }
  $clipList.EndUpdate()
  Set-ListRowBands $clipList
  # 条数变化会决定竖向滚动条在不在 → 客户区宽度变了，列宽/表头必须重算
  Fit-ClipColumns
  $clipInfo.Text = "当前缓存 $($script:clip.Count) 条（上限 $MAX_CLIP 条）。输入法剪贴板列表默认显示 $($script:pageSize) 条，按 m 键每次 +$STEP 条，最多 $MAX_PAGE 条。"
}

function Edit-Clipboard {
  param([int]$Index = -1)
  if ($Index -lt 0 -or $Index -ge $script:clip.Count) { return }
  $r = Show-AppleDialog -Title "编辑第 $($Index + 1) 条" `
    -Message '内容（保存后立即生效，输入法里按 v → 2 就能取用）' `
    -Fields @(@{ Label = ''; Value = $script:clip[$Index] }) `
    -MultiFirst -RequireFirst -OKText '保存'
  if (-not $r.OK) { return }
  $v = ($r.Values[0] -replace "`r?`n", ' ').Trim()
  if ($v.Length -eq 0) { Show-Info '内容不能为空。' '提示'; return }
  $script:clip[$Index] = $v
  Save-Clipboard
  Refresh-Clipboard
  $statusLabel.Text = "已修改第 $($Index + 1) 条"
}

# ===== 常用语页 =====
$favInfo = New-Object Windows.Forms.Label
$favInfo.Padding = New-Object Windows.Forms.Padding(16, 13, 16, 0)
$favInfo.ForeColor = $C_SUB

$favList = New-Object Windows.Forms.ListView
Style-AppleListView $favList
[void]$favList.Columns.Add('序', 52)
[void]$favList.Columns.Add('内容', 420)
[void]$favList.Columns.Add('编码', 280)
$favHeader = New-AppleHeader $favList @('序', '内容', '编码')

$favCard = New-AppleCard

$btnFavAdd    = New-AppleButton -Text '添加' -Kind 'Plain' -W 150 -H 32
$btnFavEdit   = New-AppleButton -Text '修改选中' -Kind 'Plain' -W 150 -H 32
$btnFavDel    = New-AppleButton -Text '删除选中' -Kind 'Plain' -W 150 -H 32
$btnFavClear  = New-AppleButton -Text '清空全部' -Kind 'Plain' -W 150 -H 32
$btnFavReload = New-AppleButton -Text '重新载入' -Kind 'Plain' -W 150 -H 32
$btnFavUp     = New-AppleButton -Text '上移' -Kind 'Plain' -W 150 -H 32
$btnFavDown   = New-AppleButton -Text '下移' -Kind 'Plain' -W 150 -H 32

$favHint = New-Object Windows.Forms.Label
$favHint.ForeColor = $C_SUB
$favHint.Font = $FONT_HINT
$favHint.Text = "用法：`n· 打字时键入编码的前 3 位，内容就会出现在候选第 2 位（纯数字编码则把编码打完，再按回车直接上屏）。`n`n· 双击某一条可以直接修改。`n`n· 输入法里按 v → 3 也能搜索取用。`n`n· 这里的改动立即生效（输入法直接读这个文件）。"

function Refresh-Favorites {
  Load-Favorites
  $favList.BeginUpdate()
  $favList.Items.Clear()
  for ($i = 0; $i -lt $script:favs.Count; $i++) {
    $it = New-Object Windows.Forms.ListViewItem(("" + ($i + 1)))
    [void]$it.SubItems.Add($script:favs[$i].Word)
    [void]$it.SubItems.Add($script:favs[$i].Key)
    $it.Tag = $i
    [void]$favList.Items.Add($it)
  }
  $favList.EndUpdate()
  Set-ListRowBands $favList
  Fit-FavColumns
  $favInfo.Text = "共 $($script:favs.Count) 条常用语。打字时键入编码前 3 位，内容会出现在候选第 2 位；纯数字编码把编码打完再按回车即可直接上屏。"
}

function Edit-Favorite {
  param([int]$Index = -1)
  $title = if ($Index -ge 0) { '修改常用语' } else { '添加常用语' }
  $v1 = ''
  $v2 = ''
  if ($Index -ge 0 -and $Index -lt $script:favs.Count) {
    $v1 = $script:favs[$Index].Word
    $v2 = $script:favs[$Index].Key
  }
  $r = Show-AppleDialog -Title $title `
    -Fields @(
      @{ Label = '内容（要上屏的文字）'; Value = $v1 },
      @{ Label = '编码（拼音等，用于 vfav 搜索；可留空则与内容相同）'; Value = $v2 }
    ) `
    -RequireFirst -OKText '保存'
  if (-not $r.OK) { return }
  $w = "$($r.Values[0])".Trim()
  $k = "$($r.Values[1])".Trim()
  if ($w.Length -eq 0) { Show-Info '内容不能为空。' '提示'; return }
  if ($k.Length -eq 0) { $k = $w }
  if ($Index -ge 0) {
    $script:favs[$Index].Word = $w
    $script:favs[$Index].Key = $k
  } else {
    $script:favs = @($script:favs) + [pscustomobject]@{ Word = $w; Key = $k }
  }
  Save-Favorites
  Refresh-Favorites
  $statusLabel.Text = if ($Index -ge 0) { "已修改：$w" } else { "已添加：$w（编码 $k）" }
}

# ===== 词库管理页（原 dict-manager.ps1 集成） =====
$dictTitle = New-Object Windows.Forms.Label
$dictTitle.Text = '个人词库管理'
$dictTitle.Font = $FONT_PAGE
$dictTitle.ForeColor = $C_TEXT
$dictTitle.AutoSize = $true

$dictSub = New-Object Windows.Forms.Label
$dictSub.Text = '雾凇拼音 · 你的加词在这里统一管理'
$dictSub.Font = $FONT_HINT
$dictSub.ForeColor = $C_SUB
$dictSub.AutoSize = $true

$dictBadge = New-AppleBadge -Text '共 0 条' -X 0 -Y 0 -W 92 -H 24

$dictCardList = New-AppleCard -Title '已加词语'
$dictSearchP = New-AppleField -X 0 -Y 0 -W 190 -H 28
$dictSearch = $dictSearchP.Tag
try { $dictSearch.PlaceholderText = '搜索词语或拼音' } catch { }
$btnDictRefresh = New-AppleButton -Text '刷新' -Kind 'Plain' -W 70 -H 28
$dictList = New-Object Windows.Forms.ListView
Style-AppleListView $dictList -Single
[void]$dictList.Columns.Add('词语', 300)
[void]$dictList.Columns.Add('拼音', 240)
[void]$dictList.Columns.Add('权重', 110)
$dictHeader = New-AppleHeader $dictList @('词语', '拼音', '权重')
$dictEmpty = New-Object Windows.Forms.Label
$dictEmpty.Font = $FONT_HINT
$dictEmpty.ForeColor = $C_TERT
$dictEmpty.TextAlign = [Drawing.ContentAlignment]::MiddleCenter
$dictEmpty.Text = '还没有加过词，在下方输入框加第一个吧'
$dictSelLabel = New-Object Windows.Forms.Label
$dictSelLabel.Font = $FONT_HINT
$dictSelLabel.ForeColor = $C_SUB
$dictSelLabel.Text = '未选中'
$dictSelWtLabel = New-Object Windows.Forms.Label
$dictSelWtLabel.Font = $FONT_HINT
$dictSelWtLabel.ForeColor = $C_SUB
$dictSelWtLabel.AutoSize = $true
$dictSelWtLabel.Text = '权重：'
$dictSelWtP = New-AppleField -X 0 -Y 0 -W 92 -H 28
$dictSelWt = $dictSelWtP.Tag
$btnDictWeight = New-AppleButton -Text '更新权重' -Kind 'Plain' -W 100 -H 30
$btnDictDelete = New-AppleButton -Text '删除所选' -Kind 'Plain' -W 100 -H 30

$dictCardAdd = New-AppleCard -Title '添加新词'
$dictLblWord = New-Object Windows.Forms.Label
$dictLblWord.Text = '词语 *'
$dictLblWord.Font = $FONT_HINT
$dictLblWord.ForeColor = $C_SUB
$dictLblWord.AutoSize = $true
$dictLblPy = New-Object Windows.Forms.Label
$dictLblPy.Text = '拼音（空格分隔）'
$dictLblPy.Font = $FONT_HINT
$dictLblPy.ForeColor = $C_SUB
$dictLblPy.AutoSize = $true
$dictLblWt = New-Object Windows.Forms.Label
$dictLblWt.Text = '权重'
$dictLblWt.Font = $FONT_HINT
$dictLblWt.ForeColor = $C_SUB
$dictLblWt.AutoSize = $true
$dictWordP = New-AppleField -X 0 -Y 0 -W 200 -H 30
$dictWord = $dictWordP.Tag
$dictPinyinP = New-AppleField -X 0 -Y 0 -W 200 -H 30
$dictPinyin = $dictPinyinP.Tag
$dictWeightP = New-AppleField -X 0 -Y 0 -W 96 -H 30
$dictWeight = $dictWeightP.Tag
$dictWeight.Text = "$DefaultWeight"
$btnDictAdd = New-AppleButton -Text '加入词库' -Kind 'Primary' -W 108 -H 30
$btnDictFav = New-AppleButton -Text '加入常用语' -Kind 'Plain' -W 108 -H 30
$dictTip = New-Object Windows.Forms.Label
$dictTip.Font = $FONT_HINT
$dictTip.ForeColor = $C_TERT
$dictTip.Text = '输入词语后自动标注拼音（可手动修改），权重越大排名越靠前。'

$dictCardPath = New-AppleCard
$dictPathLabel = New-Object Windows.Forms.Label
$dictPathLabel.Font = $FONT_HINT
$dictPathLabel.ForeColor = $C_SUB
$dictPathLabel.Text = "保存位置：$MYDICT_PATH"
$dictHintLabel = New-Object Windows.Forms.Label
$dictHintLabel.Font = $FONT_HINT
$dictHintLabel.ForeColor = $C_TERT
$dictHintLabel.Text = '改完记得重新部署输入法（右键任务栏小狼毫图标 → 重新部署）'
$btnOpenFolder = New-AppleButton -Text '打开所在文件夹' -Kind 'Plain' -W 136 -H 30

function Set-DictTip {
  param([string]$Msg, [bool]$Ok)
  if ($null -eq $dictTip) { return }
  $dictTip.Text = $Msg
  if ($Ok) { $dictTip.ForeColor = $C_GREEN } else { $dictTip.ForeColor = $C_DANGER }
}

function Refresh-MyDictList {
  if ($null -eq $dictList) { return }
  $script:mydict = @(Read-MyDict)
  $q = ''
  if ($null -ne $dictSearch) { $q = $dictSearch.Text.Trim().ToLower() }
  $shown = $script:mydict
  if ($q -ne '') {
    $shown = @($script:mydict | Where-Object {
      $_.Word.ToLower().Contains($q) -or $_.Pinyin.ToLower().Contains($q)
    })
  }
  $dictList.BeginUpdate()
  $dictList.Items.Clear()
  foreach ($ent in $shown) {
    $it = New-Object Windows.Forms.ListViewItem("$($ent.Word)")
    [void]$it.SubItems.Add($ent.Pinyin)
    [void]$it.SubItems.Add("$($ent.Weight)")
    $it.Tag = $ent
    [void]$dictList.Items.Add($it)
  }
  $dictList.EndUpdate()
  Set-ListRowBands $dictList
  Fit-DictColumns
  if ($null -ne $dictBadge -and $null -ne $dictBadge.Tag) {
    $dictBadge.Tag.Text = "共 $($script:mydict.Count) 条"
  }
  if ($script:mydict.Count -eq 0) {
    $dictEmpty.Text = '还没有加过词，在下方输入框加第一个吧'
    $dictEmpty.Visible = $true
  } elseif ($shown.Count -eq 0) {
    $dictEmpty.Text = "没有匹配「$q」的词"
    $dictEmpty.Visible = $true
  } else {
    $dictEmpty.Visible = $false
  }
}

# ===== 设置页 =====
$cardPage = New-AppleCard -Title '剪贴板列表默认显示条数'
$lblPage = New-Object Windows.Forms.Label
$lblPage.Text = '默认显示：'
$lblPage.ForeColor = $C_TEXT
$lblPage.AutoSize = $true
$lblPage.Location = New-Object Drawing.Point(18, 36)
$cmbPageP = New-AppleField -X 90 -Y 30 -W 92 -H 30 -Combo
$cmbPage = $cmbPageP.Tag
[void]$cmbPage.Items.AddRange(@('20', '30', '40', '50'))
$btnPageSave = New-AppleButton -Text '保存' -Kind 'Primary' -W 88 -H 30
$lblPageHint = New-Object Windows.Forms.Label
$lblPageHint.ForeColor = $C_SUB
$lblPageHint.Font = $FONT_HINT
$lblPageHint.Text = "20 条是下限、50 条是上限（超出部分自动丢弃最旧的）。`n在输入法剪贴板列表里按 m 键（或 + 键）每次多看 10 条，翻页用 - / = 或鼠标滚轮。"

$cardClear = New-AppleCard -Title '缓存清理（二次确认）'
$lblClear = New-Object Windows.Forms.Label
$lblClear.ForeColor = $C_SUB
$lblClear.Text = '清空剪贴板历史缓存：删除 clipboard-cache.txt 里的全部内容，不可恢复。'
$btnClearClip = New-AppleButton -Text '清理剪贴板缓存' -Kind 'Plain' -W 170 -H 32
$btnClearFav = New-AppleButton -Text '清空全部常用语' -Kind 'Plain' -W 170 -H 32

$cardFiles = New-AppleCard -Title '文件位置（改动即时写入）'
$tbFilesP = New-AppleField -X 18 -Y 32 -W 860 -H 104 -Multi -ReadOnly
$tbFiles = $tbFilesP.Tag
$tbFiles.Text = "剪贴板历史：$CLIP_PATH`r`n常用语：$FAV_PATH`r`n个人词库：$MYDICT_PATH`r`n设置：$SET_PATH`r`n语音设置：$VOICE_SET_PATH`r`n`r`n" +
  "提示：改完这里的内容后无需重启输入法；输入法每次打开 v 菜单都会重新读取。`r`n" +
  "若在输入法里改了内容想在这里看到，点「重新载入」即可。"

# 小狼毫原生设置：托盘右键菜单里的「输入法设置」打开的是本窗口；
# 小狼毫自带的设置对话框（配色、字体、候选条数等）从这里打开。
$cardNative = New-AppleCard -Title '小狼毫原生设置'
$lblNative = New-Object Windows.Forms.Label
$lblNative.ForeColor = $C_SUB
$lblNative.Text = "托盘图标右键菜单里的「输入法设置 (S)」打开的就是本窗口。`n小狼毫自带的设置对话框（配色 / 字体 / 候选窗口样式）用下面的按钮打开。"
$btnNative = New-AppleButton -Text '打开小狼毫原生设置' -Kind 'Primary' -W 200 -H 32

$btnNative.Add_Click({
  $dir = 'C:\Program Files\Rime\weasel-0.17.4'
  $real = Join-Path $dir 'WeaselDeployer.real.exe'
  if (-not (Test-Path -LiteralPath $real)) { $real = Join-Path $dir 'WeaselDeployer.exe' }
  try {
    Start-Process -FilePath $real
    $statusLabel.Text = '已打开小狼毫原生设置'
  } catch {
    Show-Info "打不开：`r`n$real`r`n`r`n$($_.Exception.Message)" 'vmenu'
  }
})

# ===== 前后鼻音模糊（设置与缓存页） =====
# 开关写独立文件 fuzzy-settings.txt（见 Load-FuzzySettings 注释），lua 滤镜
# fuzzy_filter.lua 每秒至多读一次，改完 1 秒内生效，无需重启输入法。
$cardFuzzy = New-AppleCard -Title '前后鼻音模糊输入（an/ang、en/eng、in/ing、ian/iang、uan/uang）'

$chkFuzzy = New-Object Windows.Forms.CheckBox
$chkFuzzy.Text = '允许模糊输入（前鼻音当后鼻音打也能出词）'
$chkFuzzy.ForeColor = $C_TEXT
$chkFuzzy.AutoSize = $true

$lblFuzzyState = New-Object Windows.Forms.Label
$lblFuzzyState.AutoSize = $true

$lblFuzzyHint = New-Object Windows.Forms.Label
$lblFuzzyHint.ForeColor = $C_SUB
$lblFuzzyHint.Font = $FONT_HINT
$lblFuzzyHint.Text = "开启时：只差前后鼻音的词照样上候选，排在精确匹配之后（例：输 yinda 先出「瘾大 因打」，再出「应 ying 答」）。`n" +
  "关闭时：只显示与输入完全一致的词（输 yinda 不再出应答）。`n" +
  "改动即时保存，下一次按键即生效，无需重启输入法。"

$chkFuzzy.Add_CheckedChanged({
  if ($script:fzLoading) { return }     # 程序化赋值不触发保存
  $script:fzNasal = $chkFuzzy.Checked
  Save-FuzzySettings
  Update-FuzzyControls
  $statusLabel.Text = "前后鼻音模糊已保存：$(if ($script:fzNasal) { '开启' } else { '关闭' })（下一次按键生效）"
})

# ===== 语音输入页 =====
# 标点转空格开关：写 voice-settings.txt（独立文件，见 Load-VoiceSettings 注释），
# 由常驻的 voice-overlay.py 在每次识别结果上生效，改完**下一次识别**即生效，
# 不需要重启悬浮球。
$cardPunct = New-AppleCard -Title '识别结果里的标点符号'
$chkPunct = New-Object Windows.Forms.CheckBox
$chkPunct.Text = '把标点符号转换成空格（，。！？、；：… → 空格）'
$chkPunct.ForeColor = $C_TEXT
$chkPunct.AutoSize = $true

$lblPunctState = New-Object Windows.Forms.Label
$lblPunctState.ForeColor = $C_GREEN
$lblPunctState.AutoSize = $true

$lblPunctHint = New-Object Windows.Forms.Label
$lblPunctHint.ForeColor = $C_SUB
$lblPunctHint.Font = $FONT_HINT
$lblPunctHint.Text = "勾选后：识别出的「今天天气真好，我们去散步吧。」→「今天天气真好 我们去散步吧」。`n" +
  "数字里的小数点 / 千分位（3.14、1,000）不会被拆开。`n" +
  "改动即时保存，下一次语音识别即生效（流式增量与最终结果同步生效），无需重启悬浮球。"

$chkPunct.Add_CheckedChanged({
  if ($script:voiceLoading) { return }   # 程序化赋值不触发保存
  $script:punctSpace = $chkPunct.Checked
  Save-VoiceSettings
  $lblPunctState.Text = "当前：$(if ($script:punctSpace) { '标点 → 空格' } else { '保留标点' })"
  if ($script:punctSpace) { $lblPunctState.ForeColor = $C_GREEN } else { $lblPunctState.ForeColor = $C_TERT }
  $statusLabel.Text = "语音设置已保存：$(if ($script:punctSpace) { '标点转空格（下一次识别生效）' } else { '保留标点（下一次识别生效）' })"
})

# ===== 语音识别 CPU 占用卡片 =====
# 为什么需要这个：llama.cpp 默认 `-t -1` 按**逻辑核数**开线程（本机 16），
# 多核空转自旋同步，识别瞬间把 CPU 打满（实测整机 59%、峰值 78%）。
# 限制到物理核以内后整机占用降到 ~26%，而且**总 CPU 消耗反而更少**（省 54%），
# 因为省掉了超订线程的同步开销；墙钟只慢约 15ms，体感无差别。
# 识别率完全不受影响：同一份模型权重，只有并行度变了。
$cardCpu = New-AppleCard -Title '语音识别 CPU 占用'

$lblCpuCur = New-Object Windows.Forms.Label
$lblCpuCur.ForeColor = $C_GREEN
$lblCpuCur.AutoSize = $true

$lblCpuHint = New-Object Windows.Forms.Label
$lblCpuHint.ForeColor = $C_SUB
$lblCpuHint.Font = $FONT_HINT
$lblCpuHint.Text = "识别线程数越少，CPU 占用越低，但识别会略慢一点（模型和识别率完全不变）。`n" +
  "默认 4 线程，实测整机占用约 26%（原来 16 线程约 59%，且总耗电更高）。`n" +
  "本机物理核数：$($script:cpuPhysCores) —— 超过物理核只会空转自旋，越开越慢。`n" +
  "改动即时保存，**重新打开一次语音输入（重启悬浮球）后生效**。"

$trkCpu = New-Object Windows.Forms.TrackBar
$trkCpu.Minimum = 1
$trkCpu.Maximum = [Math]::Max(1, $script:cpuPhysCores)
$trkCpu.TickFrequency = 1
$trkCpu.SmallChange = 1
$trkCpu.LargeChange = 1
$trkCpu.AutoSize = $false
$trkCpu.Height = 34

$trkCpu.Add_Scroll({
  if ($script:voiceLoading) { return }
  $script:asrThreads = [int]$trkCpu.Value
  Update-CpuControls
  Save-VoiceSettings
  $statusLabel.Text = "语音识别线程数已保存：$($script:asrThreads)（重启悬浮球后生效）"
})

# ===== 语音输入快捷键卡片 =====
# 点「点击录制」按钮 -> **直接在键盘上按你想要的组合** -> 松开即录入并保存。
# 录制用 20ms 轮询 GetAsyncKeyState（和 voice-overlay 一样不装任何键盘钩子），
# 所以焦点在哪都录得到；录制期间悬浮球会暂停热键检测（pid 字段），录完自动恢复。
$cardHotkey = New-AppleCard -Title '语音输入快捷键（按住说话）'

$lblHotCur = New-Object Windows.Forms.Label
$lblHotCur.Text = '当前快捷键：'
$lblHotCur.ForeColor = $C_TEXT
$lblHotCur.AutoSize = $true

$btnHotkey = New-AppleButton -Text '点击录制' -Kind 'Primary' -W 330 -H 40
$btnHotkey.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10.5, [Drawing.FontStyle]::Bold)

$btnHotReset = New-AppleButton -Text ([string][char]0x21BA + " 恢复默认") -Kind 'Plain' -W 140 -H 34
$btnHotReset.Font = New-Object Drawing.Font('Segoe UI Symbol', 10)

$lblHotState = New-Object Windows.Forms.Label
$lblHotState.ForeColor = $C_GREEN
$lblHotState.AutoSize = $false

$lblHotHint = New-Object Windows.Forms.Label
$lblHotHint.ForeColor = $C_SUB
$lblHotHint.Font = $FONT_HINT
$lblHotHint.Text = "点「点击录制」后，直接在键盘上按下想要的组合（例如 Ctrl + Alt + 空格），松开即录入；" +
  "按 Esc 或再点一次按钮取消。`n" +
  "必须包含 Ctrl / Alt / Win 之一。按住期间目标软件也会收到这些按键，别选复制/粘贴这类会真执行的组合。`n" +
  "改完立即保存并生效（悬浮球每 0.4 秒看一次配置，无需重启）；录制期间悬浮球会自动暂停检测。"

$hotTimer = New-Object Windows.Forms.Timer
$hotTimer.Interval = 20

function Stop-HotkeyRecord([string]$Reason) {
  # 收尾：停表、清状态，**最重要的是把 hotkey_recorder_pid 清掉并写回文件**，
  # 否则悬浮球会一直以为你在录制、快捷键就废了（pid 探活是兜底，别依赖它）。
  $hotTimer.Stop()
  $script:hotState = ''
  $script:hotkeyRecPid = 0
  Save-VoiceSettings
  $disp = Get-HotkeyDisplay (Get-HotkeyTokens $script:hotkey)
  $btnHotkey.Text = $disp
  if ($Reason) {
    $lblHotState.Text = "$Reason · 当前仍为 $disp"
    $lblHotState.ForeColor = $C_TERT
    $statusLabel.Text = "语音快捷键：$Reason"
  }
}

function Start-HotkeyRecord {
  if ($script:hotState) { Stop-HotkeyRecord '已取消录制'; return }   # 再点一次 = 取消
  $script:hotkeyRecPid = $PID
  Save-VoiceSettings                        # 让悬浮球开始暂停检测
  $script:hotState = 'lead'
  $script:hotGot = @()
  $script:hotLeadUntil = (Get-Date).AddMilliseconds(650)   # 给悬浮球 0.4s 检查窗口
  $script:hotEndAt = (Get-Date).AddSeconds(20)
  $btnHotkey.Text = '准备中…'
  $lblHotState.Text = '正在暂停悬浮球的快捷键检测…'
  $lblHotState.ForeColor = $C_TERT
  $form.ActiveControl = $null               # 别让空格/回车顺手触发按钮自身
  $hotTimer.Start()
}

$hotTimer.Add_Tick({
  if (-not $script:hotState) { $hotTimer.Stop(); return }
  if ((Get-Date) -gt $script:hotEndAt) { Stop-HotkeyRecord '录制超时'; return }
  $down = Get-HotkeyDownVks
  if ($down -contains 0x1B) { Stop-HotkeyRecord '已取消（按了 Esc）'; return }
  switch ($script:hotState) {
    'lead' {
      if ((Get-Date) -ge $script:hotLeadUntil) {
        $script:hotState = 'up'
        $btnHotkey.Text = '请先松开所有键…'
        $lblHotState.Text = '松开所有键之后，按下你想要的快捷键（例如 Ctrl + Alt + 空格）'
        $lblHotState.ForeColor = $C_TEXT
      }
    }
    'up' {
      if ($down.Count -eq 0) {
        $script:hotState = 'press'
        $btnHotkey.Text = '请按下新的快捷键…'
        $lblHotState.Text = '按住不放，可以继续加键；全部松开即录入'
        $lblHotState.ForeColor = $C_TEXT
      }
    }
    'press' {
      if ($down.Count -gt 0) {
        $script:hotGot = @($down)
        $script:hotState = 'collect'
        $btnHotkey.Text = (Get-HotkeyDisplay (ConvertTo-HotkeyTokens $down)) + '  +…'
        $lblHotState.Text = '可以继续加键，全部松开即完成'
        $lblHotState.ForeColor = $C_TEXT
      }
    }
    'collect' {
      foreach ($vk in $down) { if ($script:hotGot -notcontains $vk) { $script:hotGot += $vk } }
      if ($down.Count -eq 0) {
        $hotTimer.Stop()
        $tokens = ConvertTo-HotkeyTokens $script:hotGot
        $err = Test-HotkeyTokens $tokens
        $disp = Get-HotkeyDisplay $tokens
        $script:hotState = ''
        $script:hotkeyRecPid = 0
        if ($err) {
          Save-VoiceSettings                # 存回旧值，同时清掉 pid 字段
          $cur = Get-HotkeyDisplay (Get-HotkeyTokens $script:hotkey)
          $btnHotkey.Text = $cur
          $lblHotState.Text = "没保存：$err（当前仍是 $cur）"
          $lblHotState.ForeColor = $C_DANGER
          $statusLabel.Text = "语音快捷键没保存：$err"
        } else {
          $script:hotkey = ($tokens -join '+')
          Save-VoiceSettings                # 新值 + 清 pid，一次写完
          $btnHotkey.Text = $disp
          $risk = Get-HotkeyRisk $tokens
          if ($risk) {
            $lblHotState.Text = "已保存：$disp ｜ $risk"
            $lblHotState.ForeColor = [Drawing.Color]::FromArgb(255, 149, 0)  # systemOrange
          } else {
            $lblHotState.Text = "已保存：$disp（按住说话，下一次按键生效）"
            $lblHotState.ForeColor = $C_GREEN
          }
          $statusLabel.Text = "语音快捷键已保存：$disp"
        }
        return
      }
    }
  }
})

$btnHotkey.Add_Click({ Start-HotkeyRecord })

$btnHotReset.Add_Click({
  if ($script:hotState) { Stop-HotkeyRecord '已取消录制' }
  $script:hotkey = $HOTKEY_DEFAULT
  Save-VoiceSettings
  $disp = Get-HotkeyDisplay (Get-HotkeyTokens $script:hotkey)
  $btnHotkey.Text = $disp
  $lblHotState.Text = "已恢复默认：$disp（按住说话）"
  $lblHotState.ForeColor = $C_GREEN
  $statusLabel.Text = "语音快捷键已恢复默认：$disp"
})

# ===== 防误触页 =====
# 两次按键间隔 < 阈值时吞掉后一个键（键盘抖动 / 手滑连击）。
# 阈值与开关写在 vmenu-settings.txt 的 misinput_* 字段，由 lua/menu_processor.lua 每键读取。
$cardMi = New-AppleCard -Title '防误触（间隔太短的连续按键自动吞掉）'

$chkMiEnable = New-Object Windows.Forms.CheckBox
$chkMiEnable.Text = '启用防误触'
$chkMiEnable.ForeColor = $C_TEXT
$chkMiEnable.AutoSize = $true

$lblMiInterval = New-Object Windows.Forms.Label
$lblMiInterval.Text = '最小间隔（毫秒）：'
$lblMiInterval.ForeColor = $C_TEXT
$lblMiInterval.AutoSize = $true

$txtMiP = New-AppleField -X 152 -Y 66 -W 74 -H 30
$txtMi = $txtMiP.Tag
$txtMi.TextAlign = 'Center'

$lblMiRange = New-Object Windows.Forms.Label
$lblMiRange.Text = "（范围 $MI_MIN ~ $MI_MAX ms，推荐 $MI_DEFAULT ms）"
$lblMiRange.ForeColor = $C_SUB
$lblMiRange.AutoSize = $true

# 恢复推荐值：↺（逆时针圆环箭头）
$btnMiReset = New-AppleButton -Text ([string][char]0x21BA + " 恢复推荐") -Kind 'Plain' -W 130 -H 30
$btnMiReset.Font = New-Object Drawing.Font('Segoe UI Symbol', 10)

$trkMi = New-Object Windows.Forms.TrackBar
$trkMi.Minimum = $MI_MIN
$trkMi.Maximum = $MI_MAX
$trkMi.TickFrequency = 10
$trkMi.SmallChange = 5
$trkMi.LargeChange = 10
$trkMi.BackColor = $C_WHITE

$lblMiRec = New-Object Windows.Forms.Label
$lblMiRec.ForeColor = [Drawing.Color]::FromArgb(0, 113, 227)
$lblMiRec.Text = "推荐 ${MI_DEFAULT} ms：人类最快打字约 300 ms/键、反应时间约 150 ms， 30 ms`n远在人类极限之下，只拦键盘抖动与手滑连击；点 ↺ 恢复推荐。"

$lblMiState = New-Object Windows.Forms.Label
$lblMiState.ForeColor = $C_GREEN
$lblMiState.AutoSize = $true

$btnMiSave = New-AppleButton -Text '保存' -Kind 'Primary' -W 110 -H 30

# --- 事件 ---
$trkMi.Add_ValueChanged({ $txtMi.Text = "$($trkMi.Value)" })
$txtMi.Add_TextChanged({
  $v = 0
  if ([int]::TryParse($txtMi.Text, [ref]$v) -and $v -ge $MI_MIN -and $v -le $MI_MAX) {
    if ($trkMi.Value -ne $v) { $trkMi.Value = $v }
  }
})
$btnMiReset.Add_Click({
  $chkMiEnable.Checked = $true
  $trkMi.Value = $MI_DEFAULT
  $txtMi.Text = "$MI_DEFAULT"
  $statusLabel.Text = "已恢复推荐：启用 · $MI_DEFAULT ms（点保存生效）"
})
$btnMiSave.Add_Click({
  $v = 0
  if (-not [int]::TryParse($txtMi.Text, [ref]$v)) { $v = $MI_DEFAULT }
  if ($v -lt $MI_MIN) { $v = $MI_MIN }
  if ($v -gt $MI_MAX) { $v = $MI_MAX }
  $script:miEnabled = [bool]$chkMiEnable.Checked
  $script:miInterval = $v
  Save-AllSettings
  Update-MiControls
  $statusLabel.Text = "防误触已保存：$(if ($script:miEnabled) { '启用' } else { '关闭' }) · $v ms"
})

# ---------------------------------------------------------------------------
# 事件
# ---------------------------------------------------------------------------
$btnClipCopy.Add_Click({
  if ($clipList.SelectedItems.Count -eq 0) { return }
  $i = [int]$clipList.SelectedItems[0].Tag
  [Windows.Forms.Clipboard]::SetText($script:clip[$i])
  $statusLabel.Text = "已复制第 $($i + 1) 条到剪贴板"
})

$btnClipDel.Add_Click({
  if ($clipList.SelectedItems.Count -eq 0) { $statusLabel.Text = '请先选中要删除的条目'; return }
  $idx = @($clipList.SelectedItems | ForEach-Object { [int]$_.Tag }) | Sort-Object -Descending
  $n = $idx.Count
  if (-not (Confirm -Message "确定删除选中的 $n 条剪贴板记录？此操作不可恢复。" -Title '删除剪贴板记录')) { return }
  $list = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt $script:clip.Count; $i++) {
    if ($idx -notcontains $i) { [void]$list.Add($script:clip[$i]) }
  }
  $script:clip = @($list)
  Save-Clipboard
  Refresh-Clipboard
  $statusLabel.Text = "已删除 $n 条剪贴板记录"
})

$btnClipClear.Add_Click({
  if ($script:clip.Count -eq 0) { $statusLabel.Text = '剪贴板缓存已经是空的'; return }
  if (-not (Confirm -Message "确定清空全部 $($script:clip.Count) 条剪贴板历史？此操作不可恢复。" -Title '清空剪贴板缓存')) { return }
  $script:clip = @()
  Save-Clipboard
  Refresh-Clipboard
  $statusLabel.Text = '剪贴板缓存已清空'
})

$btnClipReload.Add_Click({ Refresh-Clipboard; $statusLabel.Text = '已重新载入' })

$btnClipTop.Add_Click({
  if ($clipList.SelectedItems.Count -eq 0) { return }
  $i = [int]$clipList.SelectedItems[0].Tag
  if ($i -eq 0) { return }
  $item = $script:clip[$i]
  $list = New-Object System.Collections.ArrayList
  [void]$list.Add($item)
  for ($j = 0; $j -lt $script:clip.Count; $j++) { if ($j -ne $i) { [void]$list.Add($script:clip[$j]) } }
  $script:clip = @($list)
  Save-Clipboard
  Refresh-Clipboard
  $statusLabel.Text = '已置顶'
})

# 双击所选条目 → 直接在弹框里编辑
$clipList.Add_DoubleClick({
  if ($clipList.SelectedItems.Count -eq 0) { return }
  Edit-Clipboard -Index ([int]$clipList.SelectedItems[0].Tag)
})

# 双击常用语 → 直接修改
$favList.Add_DoubleClick({
  if ($favList.SelectedItems.Count -eq 0) { return }
  Edit-Favorite -Index ([int]$favList.SelectedItems[0].Tag)
})

$btnFavAdd.Add_Click({ Edit-Favorite -Index -1 })

$btnFavEdit.Add_Click({
  if ($favList.SelectedItems.Count -eq 0) { $statusLabel.Text = '请先选中要修改的条目'; return }
  Edit-Favorite -Index ([int]$favList.SelectedItems[0].Tag)
})

$btnFavDel.Add_Click({
  if ($favList.SelectedItems.Count -eq 0) { $statusLabel.Text = '请先选中要删除的条目'; return }
  $idx = @($favList.SelectedItems | ForEach-Object { [int]$_.Tag }) | Sort-Object -Descending
  $n = $idx.Count
  if (-not (Confirm -Message "确定删除选中的 $n 条常用语？此操作不可恢复。" -Title '删除常用语')) { return }
  $list = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt $script:favs.Count; $i++) {
    if ($idx -notcontains $i) { [void]$list.Add($script:favs[$i]) }
  }
  $script:favs = @($list)
  Save-Favorites
  Refresh-Favorites
  $statusLabel.Text = "已删除 $n 条常用语"
})

$btnFavClear.Add_Click({
  if ($script:favs.Count -eq 0) { $statusLabel.Text = '常用语已经是空的'; return }
  if (-not (Confirm -Message "确定清空全部 $($script:favs.Count) 条常用语？此操作不可恢复。" -Title '清空常用语')) { return }
  $script:favs = @()
  Save-Favorites
  Refresh-Favorites
  $statusLabel.Text = '常用语已全部清空'
})

$btnFavReload.Add_Click({ Refresh-Favorites; $statusLabel.Text = '已重新载入' })

$btnFavUp.Add_Click({
  if ($favList.SelectedItems.Count -eq 0) { return }
  $i = [int]$favList.SelectedItems[0].Tag
  if ($i -le 0) { return }
  $tmp = $script:favs[$i - 1]
  $script:favs[$i - 1] = $script:favs[$i]
  $script:favs[$i] = $tmp
  Save-Favorites
  Refresh-Favorites
  $favList.Items[$i - 1].Selected = $true
  $statusLabel.Text = '已上移'
})

$btnFavDown.Add_Click({
  if ($favList.SelectedItems.Count -eq 0) { return }
  $i = [int]$favList.SelectedItems[0].Tag
  if ($i -ge $script:favs.Count - 1) { return }
  $tmp = $script:favs[$i + 1]
  $script:favs[$i + 1] = $script:favs[$i]
  $script:favs[$i] = $tmp
  Save-Favorites
  Refresh-Favorites
  $favList.Items[$i + 1].Selected = $true
  $statusLabel.Text = '已下移'
})

$btnPageSave.Add_Click({
  $v = [int]$cmbPage.SelectedItem
  Save-Settings -Page $v
  Refresh-Clipboard
  $statusLabel.Text = "默认显示条数已保存为 $v 条"
})

$btnClearClip.Add_Click({
  if (-not (Confirm -Message "确定清理剪贴板历史缓存？`n`n这会删除 clipboard-cache.txt 的全部内容，不可恢复。" -Title '清理缓存 · 二次确认')) { return }
  $script:clip = @()
  Save-Clipboard
  Refresh-Clipboard
  $statusLabel.Text = '剪贴板缓存已清理'
})

$btnClearFav.Add_Click({
  if (-not (Confirm -Message "确定清空全部常用语？`n`n这会删除 favorites.dict.yaml 里的全部词条，不可恢复。" -Title '清空常用语 · 二次确认')) { return }
  $script:favs = @()
  Save-Favorites
  Refresh-Favorites
  $statusLabel.Text = '常用语已清空'
})

# --- 词库管理页事件 ---
$dictSearch.Add_TextChanged({
  # 搜索防抖：停手 200ms 后再过滤，避免每个按键都全量重建列表
  $script:dictSearch = $dictSearch.Text
  if ($null -ne $script:dictTimer) { $script:dictTimer.Stop(); $script:dictTimer.Start() }
})
$script:dictTimer = New-Object Windows.Forms.Timer
$script:dictTimer.Interval = 200
$script:dictTimer.Add_Tick({
  $script:dictTimer.Stop()
  $script:dictSearch = $dictSearch.Text
  Refresh-MyDictList
})

$btnDictRefresh.Add_Click({
  Refresh-MyDictList
  Set-DictTip '已刷新。' $true
  $statusLabel.Text = '词库已重新载入'
})

# 输入词语自动注音（防重入：写拼音框会触发它自己的事件，不能回头再进这里）
$dictWord.Add_TextChanged({
  if ($script:annotating) { return }
  $script:annotating = $true
  try {
    $w = $this.Text.Trim()
    if ($w -eq '') { return }
    $r = Get-AutoPinyin $w
    if ($r.unknown.Count -eq 0) {
      if ($dictPinyin.Text -ne $r.pinyin) { $dictPinyin.Text = $r.pinyin }
      Set-DictTip '已自动标注拼音（可手动修改），权重越大排名越靠前。' $true
    } else {
      Set-DictTip ('“' + ($r.unknown -join '”“') + '”在字表里没找到，请手动输入完整拼音。') $false
    }
  } finally {
    $script:annotating = $false
  }
})

$btnDictAdd.Add_Click({
  $word = $dictWord.Text.Trim()
  if ($word -eq '') { Set-DictTip '请先输入词语。' $false; return }
  $pinyin = $dictPinyin.Text.Trim().ToLower()
  if ($pinyin -eq '') {
    $r = Get-AutoPinyin $word
    if ($r.unknown.Count -gt 0) { Set-DictTip '拼音为空，请手动输入拼音（空格分隔）。' $false; return }
    $pinyin = $r.pinyin
    $dictPinyin.Text = $pinyin
  }
  if ($pinyin -notmatch "^[a-züv][a-züv' ]*$") { Set-DictTip '拼音格式不对（只允许小写字母/空格/分词单引号）。' $false; return }
  $weight = $DefaultWeight
  if ($dictWeight.Text.Trim() -ne '') {
    $tmp = 0
    if ([long]::TryParse($dictWeight.Text.Trim(), [ref]$tmp) -and $tmp -gt 0) { $weight = $tmp }
    else { Set-DictTip '权重无效，请输入正整数。' $false; return }
  }
  $dup = $script:mydict | Where-Object { $_.Word -eq $word } | Select-Object -First 1
  if ($dup) {
    $msg = '“' + $word + '”已存在（' + $dup.Pinyin + '），要再追加一条吗？'
    $ans = Show-AppleDialog -Title '重复提醒' -Message $msg -Kind 'Primary' -OKText '追加' -CancelText '取消'
    if (-not $ans.OK) { return }
  }
  $all = @() + $script:mydict + [pscustomobject]@{ Word = $word; Pinyin = $pinyin; Weight = $weight }
  Save-MyDict $all
  Refresh-MyDictList
  $dictWord.Clear()
  $dictPinyin.Clear()
  $dictWeight.Text = "$DefaultWeight"
  Set-DictTip ('已加入 “' + $word + '”，保存在：' + $MYDICT_PATH) $true
  $statusLabel.Text = '已加入 “' + $word + '” · 记得重新部署后生效'
})

$btnDictFav.Add_Click({
  $word = $dictWord.Text.Trim()
  if ($word -eq '' -or $word.Contains("`r") -or $word.Contains("`n")) {
    Set-DictTip '常用语内容必须是单行，且不能为空。' $false
    return
  }
  $exists = $script:favs | Where-Object { $_.Word -eq $word } | Select-Object -First 1
  if ($exists) { Set-DictTip ('“' + $word + '”已经在常用语里了（触发码：' + $exists.Key + '）。') $false; return }
  $key = $word.Substring(0, [Math]::Min(3, $word.Length)).ToLower()
  Load-Favorites
  $script:favs = @($script:favs) + [pscustomobject]@{ Word = $word; Key = $key }
  Save-Favorites
  Refresh-Favorites
  $dictWord.Clear()
  Set-DictTip "已加入常用语，触发码：$key（打这三位编码即可上屏）。" $true
  $statusLabel.Text = "已加入常用语：$word"
})

$dictList.Add_SelectedIndexChanged({
  $sel = $dictList.SelectedItems
  if ($sel.Count -gt 0) {
    $ent = $sel[0].Tag
    $dictSelLabel.Text = "已选：$($ent.Word)"
    $dictSelWt.Text = "$($ent.Weight)"
  } else {
    $dictSelLabel.Text = '未选中'
    $dictSelWt.Text = ''
  }
})

$btnDictWeight.Add_Click({
  $sel = $dictList.SelectedItems
  if ($sel.Count -eq 0) { Set-DictTip '请先在列表中选中一个词。' $false; return }
  $tmp = 0
  if (-not ([long]::TryParse($dictSelWt.Text.Trim(), [ref]$tmp)) -or $tmp -le 0) {
    Set-DictTip '权重无效，请输入正整数。' $false
    return
  }
  $ent = $sel[0].Tag
  $ent.Weight = $tmp
  Save-MyDict @($script:mydict)
  Refresh-MyDictList
  Set-DictTip ('“' + $ent.Word + '”权重已改为 ' + $tmp + '，保存在：' + $MYDICT_PATH) $true
  $statusLabel.Text = '已更新 “' + $ent.Word + '” 的权重'
})

$btnDictDelete.Add_Click({
  $sel = $dictList.SelectedItems
  if ($sel.Count -eq 0) { Set-DictTip '请先在列表中选中一个词。' $false; return }
  $ent = $sel[0].Tag
  $q = '确定删除“' + $ent.Word + '”吗？'
  $ans = Show-AppleDialog -Title '删除确认' -Message $q -Kind 'Danger' -OKText '删除' -CancelText '取消'
  if (-not $ans.OK) { return }
  $rest = @($script:mydict | Where-Object { $_ -ne $ent })
  Save-MyDict $rest
  Refresh-MyDictList
  Set-DictTip ('已删除 “' + $ent.Word + '”，保存在：' + $MYDICT_PATH) $true
  $statusLabel.Text = '已删除 “' + $ent.Word + '” · 记得重新部署后生效'
})

$dictList.Add_DoubleClick({
  if ($dictList.SelectedItems.Count -eq 0) { return }
  # 双击 = 把词填回下方输入框方便补一条（不直接改词条，避免误伤原内容）
  $ent = $dictList.SelectedItems[0].Tag
  $dictWord.Text = $ent.Word
  $dictPinyin.Text = $ent.Pinyin
  $dictWeight.Text = "$($ent.Weight)"
  Set-DictTip '已填入下方输入框，改完点「加入词库」会作为新词条追加；旧词条请在列表里删除。' $true
})

$btnOpenFolder.Add_Click({
  if (Test-Path -LiteralPath $MYDICT_PATH -PathType Leaf) {
    # explorer 的 /select 参数必须和逗号连在一起，不能写成 PowerShell 的两个参数。
    Start-Process -FilePath 'explorer.exe' -ArgumentList @('/select,', $MYDICT_PATH)
  } else {
    Show-Info ('找不到词库文件：' + $MYDICT_PATH) '打开文件夹失败'
  }
})

# ---------------------------------------------------------------------------
# 组装
# ---------------------------------------------------------------------------
$INFO_H = 48

# 一切坐标都在这里按「控件的实际客户区」现算，因此在任何 DPI 缩放下都成立。
function Layout-Tabs {
  # 防重复：一次切页会被三处调用（选页、Show 之后、主循环补排），但页尺寸
  # 实际只变了一次 —— 六页尺寸签名没变就直接返回，省掉重复的 ~150 次 SetBounds。
  # 这就是「一次切页 CPU 从 89ms 掉回来」的关键。
  $sig = "$($tabClip.ClientSize.Width)x$($tabClip.ClientSize.Height)," +
         "$($tabFav.ClientSize.Width)x$($tabFav.ClientSize.Height)," +
         "$($tabDict.ClientSize.Width)x$($tabDict.ClientSize.Height)," +
         "$($tabSet.ClientSize.Width)x$($tabSet.ClientSize.Height)," +
         "$($tabVoice.ClientSize.Width)x$($tabVoice.ClientSize.Height)," +
         "$($tabMi.ClientSize.Width)x$($tabMi.ClientSize.Height)," +
         "$($form.ClientSize.Width)x$($form.ClientSize.Height)"
  if ($sig -eq $script:layoutSig) { return }
  $script:layoutSig = $sig
  # --- 剪贴板页 ---
  $w = $tabClip.ClientSize.Width
  $h = $tabClip.ClientSize.Height
  if ($w -lt 480) { $w = 960 }
  if ($h -lt 320) { $h = 560 }
  $clipInfo.SetBounds(0, 0, $w, $INFO_H)
  $cw = $w - 24
  $chh = $h - $INFO_H - 12
  $clipCard.SetBounds(12, $INFO_H, $cw, $chh)
  $btnX = $cw - 164
  $listW = $btnX - 12 - 14
  $clipList.SetBounds(14, 36, $listW, ($chh - 50))
  $btnClipCopy.SetBounds($btnX, 14, 150, 32)
  $btnClipDel.SetBounds($btnX, 54, 150, 32)
  $btnClipClear.SetBounds($btnX, 94, 150, 32)
  $btnClipReload.SetBounds($btnX, 134, 150, 32)
  $btnClipTop.SetBounds($btnX, 186, 150, 32)
  $hintH = $chh - 246
  if ($hintH -lt 60) { $hintH = 60 }
  $clipHint.SetBounds($btnX, 232, 150, $hintH)
  Set-AppleHeaderBounds $clipHeader 14 14 $listW 22
  Fit-ClipColumns

  # --- 常用语页 ---
  $w2 = $tabFav.ClientSize.Width
  $h2 = $tabFav.ClientSize.Height
  if ($w2 -lt 480) { $w2 = 960 }
  if ($h2 -lt 320) { $h2 = 560 }
  $favInfo.SetBounds(0, 0, $w2, $INFO_H)
  $cw2 = $w2 - 24
  $ch2 = $h2 - $INFO_H - 12
  $favCard.SetBounds(12, $INFO_H, $cw2, $ch2)
  $btn2X = $cw2 - 164
  $list2W = $btn2X - 12 - 14
  $favList.SetBounds(14, 36, $list2W, ($ch2 - 50))
  $btnFavAdd.SetBounds($btn2X, 14, 150, 32)
  $btnFavEdit.SetBounds($btn2X, 54, 150, 32)
  $btnFavDel.SetBounds($btn2X, 94, 150, 32)
  $btnFavClear.SetBounds($btn2X, 134, 150, 32)
  $btnFavReload.SetBounds($btn2X, 174, 150, 32)
  $btnFavUp.SetBounds($btn2X, 226, 150, 32)
  $btnFavDown.SetBounds($btn2X, 266, 150, 32)
  $hint2H = $ch2 - 326
  if ($hint2H -lt 60) { $hint2H = 60 }
  $favHint.SetBounds($btn2X, 312, 150, $hint2H)
  Set-AppleHeaderBounds $favHeader 14 14 $list2W 22
  Fit-FavColumns

  # --- 词库管理页 ---
  $w3 = $tabDict.ClientSize.Width
  $h3 = $tabDict.ClientSize.Height
  if ($w3 -lt 480) { $w3 = 960 }
  if ($h3 -lt 320) { $h3 = 560 }
  $cw3 = $w3 - 24
  $dictTitle.SetBounds(12, 9, 300, 22)
  $dictSub.Location = New-Object Drawing.Point(($dictTitle.Right + 10), 12)
  $dictBadge.SetBounds(($cw3 + 12 - 92), 9, 92, 24)
  $capH = 44
  $cardB_H = 124
  $cardC_H = 66
  $gap = 12
  $cardA_H = $h3 - $capH - $cardB_H - $cardC_H - ($gap * 2) - 12
  if ($cardA_H -lt 160) { $cardA_H = 160 }
  $cardA_T = $capH
  $dictCardList.SetBounds(12, $cardA_T, $cw3, $cardA_H)
  $dictCardAdd.SetBounds(12, ($cardA_T + $cardA_H + $gap), $cw3, $cardB_H)
  $dictCardPath.SetBounds(12, ($cardA_T + $cardA_H + $gap + $cardB_H + $gap), $cw3, $cardC_H)
  # 卡片 A 内部
  $dictRefreshX = $cw3 - 16 - 70
  $dictSearchX = $dictRefreshX - 8 - 190
  $dictSearchP.SetBounds($dictSearchX, 11, 190, 28)
  $btnDictRefresh.SetBounds($dictRefreshX, 11, 70, 28)
  # 列表高度 = 卡片高 - 上下要用的固定高度；底部那一行（选中项/权重/按钮）
  # 的位置一律从「列表实际底边」往下推，不能再写死偏移 ——
  # 窗口矮的时候卡片高度被夹到下限，写死的行位置就会跑到列表上面去，
  # 表现为列表压住权重输入框和两个按钮（用户报的「错位」就是这个）。
  $listA_H = $cardA_H - 122
  $maxList = $cardA_H - 70 - 50
  if ($listA_H -gt $maxList) { $listA_H = $maxList }
  if ($listA_H -lt 36) { $listA_H = 36 }
  $dictList.SetBounds(14, 70, ($cw3 - 28), $listA_H)
  $dictEmpty.SetBounds(14, 132, ($cw3 - 28), 36)
  $rowY = 70 + $listA_H + 10
  if ($rowY -gt ($cardA_H - 40)) { $rowY = $cardA_H - 40 }
  $dictSelLabel.SetBounds(16, ($rowY + 3), 200, 22)
  $dictSelWtLabel.SetBounds(228, ($rowY + 3), 50, 22)
  $dictSelWtP.SetBounds(276, $rowY, 92, 28)
  $btnDictWeight.SetBounds(376, ($rowY - 1), 100, 30)
  $btnDictDelete.SetBounds(($cw3 - 16 - 100), ($rowY - 1), 100, 30)
  Set-AppleHeaderBounds $dictHeader 14 48 ($cw3 - 28) 22
  Fit-DictColumns
  # 卡片 B 内部
  $contentR = $cw3 - 16
  $b1X = $contentR - 108 - 8 - 108
  $fieldsR = $b1X - 14
  $avail = $fieldsR - 16
  $wtW = 96
  $rest = $avail - $wtW - 20
  if ($rest -lt 260) { $rest = 260 }
  $pyW = [int]($rest * 0.56)
  $wordW = $rest - $pyW
  $dictLblWord.SetBounds(16, 40, 200, 16)
  $dictLblPy.SetBounds((16 + $wordW + 10), 40, 200, 16)
  $dictLblWt.SetBounds((16 + $wordW + 10 + $pyW + 10), 40, 100, 16)
  $dictWordP.SetBounds(16, 58, $wordW, 30)
  $dictPinyinP.SetBounds((16 + $wordW + 10), 58, $pyW, 30)
  $dictWeightP.SetBounds((16 + $wordW + 10 + $pyW + 10), 58, $wtW, 30)
  $btnDictAdd.SetBounds($b1X, 58, 108, 30)
  $btnDictFav.SetBounds(($b1X + 116), 58, 108, 30)
  $dictTip.SetBounds(16, 94, ($contentR - 16), 22)
  # 卡片 C 内部
  $dictPathLabel.SetBounds(16, 14, ($cw3 - 16 - 152), 18)
  $dictHintLabel.SetBounds(16, 36, ($cw3 - 16 - 152), 18)
  $btnOpenFolder.SetBounds(($cw3 - 16 - 136), 18, 136, 30)

  # --- 设置与缓存页 ---
  $ws = $tabSet.ClientSize.Width
  if ($ws -lt 480) { $ws = 960 }
  $cws = $ws - 32
  $cardFuzzy.SetBounds(16, 16, $cws, 132)
  $chkFuzzy.Location = New-Object Drawing.Point(18, 34)
  $lblFuzzyState.SetBounds(($cws - 340), 36, 320, 20)
  $lblFuzzyHint.SetBounds(18, 64, ($cws - 36), 60)
  $cardPage.SetBounds(16, 160, $cws, 136)
  # 「保存」按钮必须显式摆位：New-AppleButton 的默认坐标是 (0,0)，
  # 这个按钮以前没被摆过位，就一直压在卡片标题上（按钮因此看不见也点不到）。
  $btnPageSave.SetBounds(192, 30, 88, 30)
  $lblPageHint.SetBounds(18, 74, ($cws - 36), 56)
  $cardClear.SetBounds(16, 308, $cws, 116)
  $lblClear.SetBounds(18, 34, ($cws - 36), 36)
  $btnClearClip.SetBounds(18, 76, 170, 32)
  $btnClearFav.SetBounds(200, 76, 170, 32)
  $cardFiles.SetBounds(16, 436, $cws, 146)
  $tbFilesP.SetBounds(18, 32, ($cws - 36), 104)
  $cardNative.SetBounds(16, 594, $cws, 110)
  $lblNative.SetBounds(18, 34, ($cws - 36), 36)
  $btnNative.SetBounds(18, 74, 200, 32)

  # --- 语音输入页 ---
  $wv = $tabVoice.ClientSize.Width
  if ($wv -lt 480) { $wv = 960 }
  $cwv = $wv - 32
  $cardPunct.SetBounds(16, 16, $cwv, 170)
  $chkPunct.Location = New-Object Drawing.Point(18, 34)
  $lblPunctState.SetBounds(($cwv - 320), 36, 300, 20)
  $lblPunctHint.SetBounds(18, 68, ($cwv - 36), 92)
  # CPU 占用卡片：滑块一行 + 状态一行 + 说明四行
  $cardCpu.SetBounds(16, 196, $cwv, 176)
  $trkCpu.SetBounds(16, 34, ($cwv - 32), 34)
  $lblCpuCur.SetBounds(18, 72, ($cwv - 36), 22)
  $lblCpuHint.SetBounds(18, 96, ($cwv - 36), 74)
  # 快捷键卡片：按钮一行 + 状态一行 + 说明三行
  $cardHotkey.SetBounds(16, 382, $cwv, 196)
  $lblHotCur.SetBounds(18, 42, 130, 24)
  $btnHotkey.SetBounds(150, 32, 330, 40)
  $btnHotReset.SetBounds(494, 35, 140, 34)
  $lblHotState.SetBounds(18, 84, ($cwv - 36), 24)
  $lblHotHint.SetBounds(18, 114, ($cwv - 36), 74)

  # --- 防误触页 ---
  $wm = $tabMi.ClientSize.Width
  if ($wm -lt 480) { $wm = 960 }
  $cwm = $wm - 32
  $cardMi.SetBounds(16, 16, $cwm, 240)
  $chkMiEnable.Location = New-Object Drawing.Point(18, 32)
  $lblMiInterval.Location = New-Object Drawing.Point(18, 70)
  $txtMiP.SetBounds(152, 66, 74, 30)
  $lblMiRange.Location = New-Object Drawing.Point(236, 70)
  $lblMiState.SetBounds(($cwm - 268), 32, 252, 22)
  $trkW = $cwm - 194
  if ($trkW -lt 200) { $trkW = 200 }
  $trkMi.SetBounds(18, 104, $trkW, 45)
  $btnMiReset.SetBounds(($cwm - 164), 116, 130, 30)
  # 说明文字两行就够（高 40），原来给到 56 会伸进下面「保存」按钮的框里，
  # 看起来像文字和按钮压在一起。
  $lblMiRec.SetBounds(18, 158, ($cwm - 36), 40)
  $btnMiSave.SetBounds(($cwm - 126), 200, 110, 30)
}

$clipCard.Controls.AddRange(@($clipHeader, $clipList, $btnClipCopy, $btnClipDel, $btnClipClear, $btnClipReload, $btnClipTop, $clipHint))
$tabClip.Controls.Add($clipCard)
$tabClip.Controls.Add($clipInfo)

$favCard.Controls.AddRange(@($favHeader, $favList, $btnFavAdd, $btnFavEdit, $btnFavDel, $btnFavClear, $btnFavReload, $btnFavUp, $btnFavDown, $favHint))
$tabFav.Controls.Add($favCard)
$tabFav.Controls.Add($favInfo)

$dictCardList.Controls.AddRange(@($dictSearchP, $btnDictRefresh, $dictHeader, $dictList, $dictEmpty,
    $dictSelLabel, $dictSelWtLabel, $dictSelWtP, $btnDictWeight, $btnDictDelete))
$dictCardAdd.Controls.AddRange(@($dictLblWord, $dictLblPy, $dictLblWt,
    $dictWordP, $dictPinyinP, $dictWeightP, $btnDictAdd, $btnDictFav, $dictTip))
$dictCardPath.Controls.AddRange(@($dictPathLabel, $dictHintLabel, $btnOpenFolder))
$tabDict.Controls.AddRange(@($dictTitle, $dictSub, $dictBadge, $dictCardList, $dictCardAdd, $dictCardPath))

$cardPage.Controls.AddRange(@($lblPage, $cmbPageP, $btnPageSave, $lblPageHint))
$cardFuzzy.Controls.AddRange(@($chkFuzzy, $lblFuzzyState, $lblFuzzyHint))
$cardClear.Controls.AddRange(@($lblClear, $btnClearClip, $btnClearFav))
$cardFiles.Controls.Add($tbFilesP)
$cardNative.Controls.AddRange(@($lblNative, $btnNative))
$tabSet.Controls.AddRange(@($cardFuzzy, $cardPage, $cardClear, $cardFiles, $cardNative))

$cardPunct.Controls.AddRange(@($chkPunct, $lblPunctState, $lblPunctHint))
$tabVoice.Controls.Add($cardPunct)
$cardCpu.Controls.AddRange(@($trkCpu, $lblCpuCur, $lblCpuHint))
$tabVoice.Controls.Add($cardCpu)
$cardHotkey.Controls.AddRange(@($lblHotCur, $btnHotkey, $btnHotReset, $lblHotState, $lblHotHint))
$tabVoice.Controls.Add($cardHotkey)

$cardMi.Controls.AddRange(@($chkMiEnable, $lblMiInterval, $txtMiP, $lblMiRange, $btnMiReset,
    $trkMi, $lblMiRec, $lblMiState, $btnMiSave))
$tabMi.Controls.Add($cardMi)

[void]$form.Controls.Add($tabs)
[void]$form.Controls.Add($status)

# 控件层级修正：WinForms 里「先加的控件在上层」，而卡片标题/说明文字都是在
# 按钮、输入框之前建的，于是文字的框会盖住同区域的按钮/输入框
# （默认条数卡的「保存」、防误触卡的「保存」都被盖过）。这里统一把可交互控件
# 提到最前。注意不碰 ListView：词库页「还没有加过词」的提示是故意压在列表上的。
foreach ($pg in @($tabClip, $tabFav, $tabDict, $tabSet, $tabVoice, $tabMi)) {
  foreach ($card in @($pg.Controls)) {
    if ($card -isnot [Windows.Forms.Panel]) { continue }
    foreach ($c in @($card.Controls)) {
      if ($c -is [Windows.Forms.Button] -or $c -is [Windows.Forms.TextBox] -or
          $c -is [Windows.Forms.ComboBox] -or $c -is [Windows.Forms.TrackBar] -or
          $c -is [Windows.Forms.CheckBox] -or $c -is [Windows.Forms.Panel]) {
        $c.BringToFront()
      }
    }
  }
}

foreach ($tp in @($tabClip, $tabFav, $tabDict, $tabSet, $tabVoice, $tabMi)) {
  # 页也开双缓冲：页是纯色大底，不开的话切页/拖窗口时会先闪一下底色再画控件
  # （实测开关它对 CPU 的影响落在测量噪声里 ±10ms，那就选视觉更稳的一边）。
  Enable-DoubleBuffer $tp
  # 内容比可视区高时允许纵向滚动：设置页原来最后一张卡片（小狼毫原生设置）
  # 整块落在可视区下方，既看不见也点不到，这就是用户报的「错位」。
  # 卡片高度不随宽度变化，所以不会出现「滚动条出现→重排→滚动条消失」的抖动。
  $tp.AutoScroll = $true
  # 拖窗口时 TabControl 会改所有页的尺寸，每页都触发一次 Resize：直接调 Layout-Tabs
  # 等于一次拖动重排 6 遍（就是拖窗口卡顿的来源）。改成只打标记 + 起一个 90ms 的
  # 一次性定时器，一次拖动最多重排一次。
  $tp.Add_Resize({
    $script:layoutDirty = $true
    if ($null -ne $script:layoutTimer -and -not $script:layoutTimer.Enabled) { $script:layoutTimer.Start() }
  })
}
$script:layoutDirty = $false
$script:layoutReady = $false

# 重排去抖用的「一次性」定时器：平时不跑，只有页尺寸变了才起来跑一次。
# （老的实现是 60ms 主循环里轮询这个标记 —— PowerShell 里一次轮询要 ~1ms，
#   常驻下来白烧 1.5% 的一个核，所以改成事件驱动。）
$script:layoutTimer = New-Object Windows.Forms.Timer
$script:layoutTimer.Interval = 90
$script:layoutTimer.Add_Tick({
  $script:layoutTimer.Stop()
  if ($script:layoutDirty -and $form.Visible) { Sync-Layout }
})

function Sync-Layout {
  # 立即重排一次并清掉标记。切页、显示窗口时同步调用，
  # 保证窗口「一出现就是对齐的」，不会先错位一下再修好。
  $script:layoutDirty = $false
  # 初始化早期控件还没建完（TabControl 加页时就会报选中变化），这里挡一下
  if (-not $script:layoutReady) { return }
  Layout-Tabs
}

# 初始载入
Load-Settings
Load-VoiceSettings
Load-FuzzySettings
$cmbPage.SelectedItem = "$($script:pageSize)"
if ($null -eq $cmbPage.SelectedItem) { $cmbPage.SelectedIndex = 0 }
Update-MiControls
Update-VoiceControls
Update-FuzzyControls
$script:layoutReady = $true     # 控件建完了，之后才允许重排
Layout-Tabs
Refresh-Clipboard
Refresh-Favorites
Refresh-MyDictList

if ($Tab -ge 0 -and $Tab -lt $tabs.TabPages.Count) { $tabs.SelectedIndex = $Tab }

$form.Add_Shown({
  Layout-Tabs
  $form.Activate()
  if ($env:VMENU_GUI_DEBUG) {
    $dbg = New-Object System.Collections.ArrayList
    [void]$dbg.Add("form ClientSize = $($form.ClientSize.Width)x$($form.ClientSize.Height)")
    [void]$dbg.Add("form Bounds = $($form.Left),$($form.Top) $($form.Width)x$($form.Height)")
    [void]$dbg.Add("tabs = $($tabs.Left),$($tabs.Top) $($tabs.Width)x$($tabs.Height)")
    [void]$dbg.Add("tabClip client = $($tabClip.ClientSize.Width)x$($tabClip.ClientSize.Height)")
    foreach ($c in @($clipInfo, $clipList, $clipCard, $btnClipCopy, $btnClipDel, $clipHint)) {
      [void]$dbg.Add(("{0} '{1}' = {2},{3} {4}x{5} vis={6} parentVisible={7}" -f `
        $c.GetType().Name, $c.Text, $c.Left, $c.Top, $c.Width, $c.Height, $c.Visible, $c.Parent.Visible))
    }
    try {
      $g = [Drawing.Graphics]::FromHwnd($form.Handle)
      [void]$dbg.Add("DpiX = $($g.DpiX)  DpiY = $($g.DpiY)")
      $g.Dispose()
    } catch { [void]$dbg.Add("DpiX query failed: $_") }
    [IO.File]::WriteAllLines((Join-Path $env:TEMP 'vmenu-gui-debug.txt'), $dbg)

    $form.Refresh()
    try {
      $bw = $form.ClientSize.Width
      $bh = $form.ClientSize.Height
      $bmp = New-Object Drawing.Bitmap($bw, $bh)
      $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $bw, $bh)))
      $bmp.Save((Join-Path $env:TEMP 'vmenu-form-bitmap.png'), [Drawing.Imaging.ImageFormat]::Png)
      $bmp.Dispose()
    } catch {
      [IO.File]::AppendAllText((Join-Path $env:TEMP 'vmenu-gui-debug.txt'), "DrawToBitmap failed: $_`r`n")
    }
  }
})
# ---------------------------------------------------------------------------
# 常驻 + 秒开
#   进程起来时就把窗口建好（先摆到屏幕外 Show 一次再 Hide），之后每 60ms 看一次
#   标记文件。输入法按 v1 只写这个标记文件，所以窗口是「立刻」弹出来的 ——
#   不需要重新启动 PowerShell 再解析这上千行脚本（那要 2-4 秒，就是之前慢的原因）。
#   点 X 关窗不退出进程，只隐藏：下次 v1 依旧秒开。
#   真正退出：用 vmenu-watcher-stop.ps1 / clipboard-sync-stop.ps1，或直接结束进程。
# ---------------------------------------------------------------------------

function Take-Flag {
  try {
    if (Test-Path -LiteralPath $FLAG_PATH) {
      $txt = ([IO.File]::ReadAllText($FLAG_PATH)).Trim()
      Remove-Item -LiteralPath $FLAG_PATH -Force -ErrorAction SilentlyContinue
      return $txt
    }
  } catch { }
  return $null
}

function Hide-SettingsWindow {
  $form.Hide()
  $statusLabel.Text = '已隐藏 · 后台常驻，v→1 秒开'
}

function Center-SettingsWindow {
  # 居中到主屏工作区。本进程是 DPI 不感知的，所以这里的坐标和窗体自己的
  # 坐标空间一致（都是被系统缩放后的虚拟坐标），不需要换算。
  try {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.StartPosition = 'Manual'
    $form.Location = New-Object Drawing.Point(
      [int]($wa.Left + ($wa.Width - $form.Width) / 2),
      [int]($wa.Top + ($wa.Height - $form.Height) / 2))
  } catch { }
}

function Show-SettingsWindow {
  if (-not $form.Visible) {
    Load-Settings
    Load-VoiceSettings
    Load-FuzzySettings
    $cmbPage.SelectedItem = "$($script:pageSize)"
    if ($null -eq $cmbPage.SelectedItem) { $cmbPage.SelectedIndex = 0 }
    Update-MiControls
    Update-VoiceControls
    Update-FuzzyControls
    Refresh-Clipboard
    Refresh-Favorites
    Refresh-MyDictList
    Layout-Tabs
  }
  # 位置：第一次居中；之后尊重用户拖动的位置，但窗口跑到屏幕外就拉回来
  if (-not $script:positioned) {
    Center-SettingsWindow
    $script:positioned = $true
  } elseif ($form.Left -lt -5000 -or $form.Top -lt -5000) {
    Center-SettingsWindow
  }
  $form.Show()
  # Show() 之后各页尺寸才最终确定，这里立刻补排一次：窗口第一次出现在用户眼前
  # 就是对齐的，不会先错位一下再跳回来。
  if ($script:layoutReady) {
    Layout-Tabs
    $script:layoutDirty = $false
  }
  if ($form.WindowState -eq [Windows.Forms.FormWindowState]::Minimized) {
    $form.WindowState = [Windows.Forms.FormWindowState]::Normal
  }
  try { [void]$form.Activate() } catch { }
  try { [void]$form.BringToFront() } catch { }
  # 前台窗口锁：TopMost 抖一下是最稳的置顶办法
  try { $form.TopMost = $true; $form.TopMost = $false } catch { }
  $statusLabel.Text = "已打开 · $(Get-Date -Format 'HH:mm:ss')"
}

$script:allowClose = $false
$form.Add_FormClosing({
  param($sender, $e)
  # 录制中被关掉/隐藏：先把 hotkey_recorder_pid 清掉再走，
  # 不然悬浮球会一直以为在录制、快捷键整段时间都不工作。
  if ($script:hotState) { Stop-HotkeyRecord '窗口已关闭' }
  # allowClose 只在收到 quit 标记（VMenu.exe stop）时置真：那时要真的退出进程。
  # 其余（点 X / Alt+F4）一律只隐藏 —— 常驻才能秒开。
  if ($script:allowClose) { return }
  if ($e.CloseReason -eq [Windows.Forms.CloseReason]::UserClosing) {
    $e.Cancel = $true
    Hide-SettingsWindow
  }
})

# 预建窗口句柄：在屏幕外真正 Show 一次再 Hide，把「第一次显示」要做的
# 布局 / 控件句柄创建工作提前做掉，这样用户第一次按 v→1 也是毫秒级；
# 屏幕外坐标（-32000）不会闪到用户。位置在第一次真正显示时再居中。
$script:positioned = $false
$form.StartPosition = 'Manual'
$form.Location = New-Object Drawing.Point(-32000, -32000)
$form.Show()
$form.Hide()

if ($ShowNow) { Show-SettingsWindow } else { $statusLabel.Text = '后台常驻 · v→1 打开' }

if ($DialogTest) {
  $null = Show-AppleDialog -Title '样式自检 · 对话框' `
    -Message '这是 Apple 样式对话框的自检：圆角输入框、胶囊按钮、主色/危险色。' `
    -Fields @(
      @{ Label = '单行输入框'; Value = '示例内容' },
      @{ Label = '多行输入框'; Value = "第一行`n第二行" }
    ) `
    -MultiFirst -RequireFirst -OKText '确定' -CancelText '取消'
}

# --- 互为看门狗 ---
# 用户报过两次「后台进程被顺手关掉后功能就死了」：本进程点 X 只隐藏不退出、
# 杀不掉，所以由它兼任保活中枢：每隔约 2 秒检查剪贴板同步与看门狗脚本，
# 死了就以完全隐藏方式重新拉起（任务栏无按钮，无法被误关）。
$script:wdDir = if ($PSScriptRoot) { $PSScriptRoot } else { 'D:\rime-sandbox' }
# 每个目标 5 秒重生冷却：即使某次检测被误判，也掀不起进程风暴。
$script:wdLastSync = [DateTime]::MinValue
$script:wdLastWatch = [DateTime]::MinValue
# 检测必须走 CIM：Windows PowerShell 5.1 的 Get-Process 根本没有 CommandLine
# 属性，用 $_.CommandLine -match 恒为假 → 看门狗以为目标永远是死的 →
# 每 2 秒无条件重生（曾经炸出 200+ 进程，整机卡死）。
function Test-HelperAlive([string]$mutexName) {
  # 助手脚本（剪贴板同步 / 看门狗）各自持有一个同名互斥体，探测只要 ~0.1ms。
  # 这里以前是 Get-CimInstance Win32_Process 查命令行：实测一次 176ms，
  # 而且跑在 UI 线程上（定时器里），等于每 2 秒把窗口冻住 176ms ——
  # 用户说的「卡顿感 / 一顿一顿」主要就是它。
  try {
    $m = [System.Threading.Mutex]::OpenExisting($mutexName)
    $m.Dispose()
    return $true
  } catch { return $false }
}

function Start-Helper([string]$scriptFile, [string]$mode) {
  # 拉活助手：优先用无控制台窗口的 VMenu.exe（直接起 powershell.exe 会闪黑框），
  # 没有这个 exe 时退回 powershell.exe。
  try {
    $exe = Join-Path $script:wdDir 'VMenu.exe'
    if (Test-Path -LiteralPath $exe) {
      Start-Process -FilePath $exe -ArgumentList $mode -WindowStyle Hidden | Out-Null
      return
    }
    Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',`
      (Join-Path $script:wdDir $scriptFile) -WindowStyle Hidden
  } catch { }
}

function Invoke-FlagCheck {
  # 标记文件内容："hide" 隐藏；"quit" 真退出；"tab:N" 切到第 N 个标签页并显示；其余显示
  $flagText = Take-Flag
  if ($null -eq $flagText) { return }
  if ($flagText -eq 'quit') {
    # VMenu.exe stop / 停止脚本用这个让常驻窗口干净退出（否则点 X 只是隐藏）
    $script:allowClose = $true
    $form.Close()
    # 消息循环是不带参数的 Run()，关掉窗体并不会自己停，要显式退出线程
    [System.Windows.Forms.Application]::ExitThread()
    return
  }
  if ($flagText -eq 'hide') {
    Hide-SettingsWindow
  } elseif ($flagText -match '^tab:\s*(\d+)$') {
    $ti = [int]$Matches[1]
    if ($ti -ge 0 -and $ti -lt $tabs.TabPages.Count) { $tabs.SelectedIndex = $ti }
    Show-SettingsWindow
  } else {
    Show-SettingsWindow
  }
}

function Invoke-MainTick {
  # 1.5 秒跑一次：剪贴板变化 + 保活兜底（快的标记文件检查在下面单独走）
  if ($form.IsDisposed) { return }
  # 文件被别处改动（v 菜单清空历史 / 后台同步新增了一条）→ 自动重载列表。
  # 不重载的话窗口里显示的是旧列表；那份旧列表一旦被「保存」写回去，
  # 已经清空的剪贴板历史就会复活（就是用户报的那个毛病）。
  if ($form.Visible) {
    if ((Clip-Stamp) -ne $script:clipStamp) { Refresh-Clipboard }
  }
  # 保活：剪贴板同步与守护进程。互斥体探测只要 0.1ms（以前用 CIM 查进程要
  # 176ms，而且是跑在 UI 线程上）。
  try {
    $now = Get-Date
    if ((-not (Test-HelperAlive 'RimeClipboardSync')) -and
        (Test-Path (Join-Path $script:wdDir 'clipboard-sync.ps1')) -and
        ($now - $script:wdLastSync).TotalSeconds -ge 10) {
      $script:wdLastSync = $now
      Start-Helper 'clipboard-sync.ps1' 'sync'
    }
    if ((-not (Test-HelperAlive 'RimeVMenuWatcher')) -and
        (Test-Path (Join-Path $script:wdDir 'vmenu-watcher.ps1')) -and
        ($now - $script:wdLastWatch).TotalSeconds -ge 10) {
      $script:wdLastWatch = $now
      Start-Helper 'vmenu-watcher.ps1' 'watch'
    }
  } catch { }
}

# ---------------------------------------------------------------------------
# 录制流程端到端自检：powershell -File vmenu-settings-gui.ps1 -RecordTest
#   不显示窗口、不移动鼠标、不抢前台（前两者会打扰正在用这台机器的人）：
#   直接调真实的 Start-HotkeyRecord，用 keybd_event 注入 Ctrl+Alt+F9 走完整
#   状态机，验证「状态机识别 / 落盘 / pid 握手 / 按钮显示」，跑完把配置还原成
#   默认 ctrl+win —— 悬浮球会热重载回去，正好把热重载也验一遍。
# ---------------------------------------------------------------------------
if ($RecordTest) {
  if (-not ('E2E.Native' -as [type])) {
    Add-Type -Namespace E2E -Name Native -MemberDefinition @'
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
'@
  }
  $script:rtMsg = @()
  $script:rtCode = 0
  $script:rtStage = 0
  $script:rtT = Get-Date
  Start-HotkeyRecord                      # 真实入口：写 pid、进 lead 期
  $script:rtTimer = New-Object Windows.Forms.Timer
  $script:rtTimer.Interval = 20
  $script:rtTimer.Add_Tick({
    $el = ((Get-Date) - $script:rtT).TotalMilliseconds
    $keys = @(0xA2, 0xA4, 0x78)           # Ctrl + Alt + F9（Windows 默认无绑定）
    switch ($script:rtStage) {
      0 { if ($el -ge 900) {
            if (Select-String -LiteralPath $VOICE_SET_PATH -Pattern 'hotkey_recorder_pid=' -Quiet) {
              $script:rtMsg += 'OK: 录制期间 hotkey_recorder_pid 已写入（悬浮球会暂停）'
            } else { $script:rtMsg += 'FAIL: 录制期间配置里没有 hotkey_recorder_pid' }
            if ($script:hotState -in @('lead', 'up', 'press', 'collect')) {
              $script:rtMsg += "OK: 状态机在跑（hotState=$($script:hotState)）"
            } else { $script:rtMsg += "FAIL: hotState='$($script:hotState)'（应处于录制中）" }
            [E2E.Native]::keybd_event($keys[0], 0, 0, [UIntPtr]::Zero)
            $script:rtStage = 1; $script:rtT = Get-Date
          } }
      1 { if ($el -ge 150) { [E2E.Native]::keybd_event($keys[1], 0, 0, [UIntPtr]::Zero); $script:rtStage = 2; $script:rtT = Get-Date } }
      2 { if ($el -ge 150) { [E2E.Native]::keybd_event($keys[2], 0, 0, [UIntPtr]::Zero); $script:rtStage = 3; $script:rtT = Get-Date } }
      3 { if ($el -ge 600) {
            foreach ($vk in @($keys[2], $keys[1], $keys[0])) {
              [E2E.Native]::keybd_event($vk, 0, 2, [UIntPtr]::Zero)   # 全松开 -> 录入
            }
            $script:rtStage = 4; $script:rtT = Get-Date
          } }
      4 { if ($el -ge 700) {
            $file = [IO.File]::ReadAllText($VOICE_SET_PATH)
            if ($script:hotkey -eq 'ctrl+alt+f9') { $script:rtMsg += 'OK: 状态机识别出 ctrl+alt+f9' }
            else { $script:rtMsg += "FAIL: hotkey='$($script:hotkey)'（期望 ctrl+alt+f9）" }
            if ($file -match '(?m)^hotkey=ctrl\+alt\+f9\s*$') { $script:rtMsg += 'OK: hotkey=ctrl+alt+f9 已落盘' }
            else { $script:rtMsg += 'FAIL: 落盘内容不对 -> ' + ($file -replace "`r?`n", ' | ') }
            if ($file -notmatch 'hotkey_recorder_pid=') {
              $script:rtMsg += 'OK: 录完 pid 字段已清掉（悬浮球恢复检测）'
            } else { $script:rtMsg += 'FAIL: pid 字段残留，悬浮球会一直暂停' }
            if ($script:hotState -eq '') { $script:rtMsg += 'OK: 状态机已收尾' }
            else { $script:rtMsg += "FAIL: hotState='$($script:hotState)' 未收尾" }
            if ($btnHotkey.Text -ceq 'Ctrl + Alt + F9') { $script:rtMsg += 'OK: 按钮显示 Ctrl + Alt + F9' }
            else { $script:rtMsg += "FAIL: 按钮显示 '$($btnHotkey.Text)'" }
            if (@($script:rtMsg | Where-Object { $_ -like 'FAIL*' }).Count) { $script:rtCode = 1 }
            # 还原默认（悬浮球会热重载回 ctrl+win，热重载本身也被这次自检覆盖）
            $script:hotkey = $HOTKEY_DEFAULT
            Save-VoiceSettings
            $script:rtTimer.Stop()
            [System.Windows.Forms.Application]::Exit()
          } }
    }
  })
  $script:rtTimer.Start()
}

# ---------------------------------------------------------------------------
# 主消息循环
#   以前是手搓的「while + DoEvents + Sleep 60」：DoEvents 会在任意时刻重入
#   消息队列，一次重绘经常被切成好几段画出来 —— 用户看到的就是「闪烁」和
#   「一顿一顿」。现在把循环交还给 WinForms 自己（Application::Run）。
#
#   为什么标记文件还是轮询、而不是 FileSystemWatcher：
#   FSW 的回调是从 IO 线程池线程上进来的，那个线程里**没有 PowerShell 运行
#   空间**，脚本块一进去就抛 PSInvalidOperationException —— 而且是未处理异常，
#   直接终止进程（实测：写一次标记文件，窗口就崩一次）。所以这里还是轮询，
#   但把快路径压到只剩一次 [IO.File]::Exists，命中才读写文件；重的检查
#   （剪贴板变化 + 保活）挪到每 25 跳（≈1.5 秒）一次。
# ---------------------------------------------------------------------------
$script:tickN = 0
$script:timer = New-Object Windows.Forms.Timer
$script:timer.Interval = 60
$script:timer.Add_Tick({
  if ([IO.File]::Exists($FLAG_PATH)) { Invoke-FlagCheck }
  $script:tickN++
  if ($script:tickN -ge 25) {
    $script:tickN = 0
    Invoke-MainTick
  }
})
$script:timer.Start()
# 这里必须用**不带参数**的 Run()。
# Application::Run($form) 会把当作主窗体的那个窗体「显示出来」—— 本窗口是
# 预建在屏幕外再 Hide() 的常驻窗口，用带窗体的重载就会在每次开机自启时把
# 窗口弹出来一次（用户报的「启动就自己冒出来」就是这个）。不带参数的 Run()
# 只开消息循环，不动任何可见性；退出走 quit 标记 → Close() + ExitThread()。
[System.Windows.Forms.Application]::Run()
if ($RecordTest) {
  $script:rtMsg | ForEach-Object { $_ }
  if ($script:rtCode) { 'record-e2e FAILED'; exit 1 }
  'record-e2e OK'
  exit 0
}
$script:timer.Stop()
$script:timer.Dispose()
if ($script:layoutTimer) { $script:layoutTimer.Dispose() }

$mutex.ReleaseMutex()
$mutex.Dispose()
