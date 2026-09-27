# dict-manager.ps1 — 雾凇拼音个人词库可视化管理
# 双击「词库管理.bat」启动
# 设计语言：微软 Fluent（浅灰底 + 卡片）+ 蚂蚁 Ant Design（蓝色主按钮 + 表格）
#Requires -Version 5.1
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

# 生效目录：与 vmenu-settings-gui.ps1 保持一致 —— 默认 D:\rime-sandbox（真实数据
# 所在），目录不存在时退回注册表登记的 RimeUserDir，再退回 %APPDATA%\Rime，
# 避免双开词库管理却各读各的词库。
$rimeDir = 'D:\rime-sandbox'
if (-not (Test-Path -LiteralPath $rimeDir)) {
  try {
    $reg = Get-ItemProperty -Path 'HKCU:\Software\Rime\Weasel' -Name RimeUserDir -ErrorAction Stop
    if ($reg.RimeUserDir -and (Test-Path -LiteralPath $reg.RimeUserDir)) { $rimeDir = $reg.RimeUserDir }
  } catch { }
}
if (-not (Test-Path -LiteralPath $rimeDir)) { $rimeDir = Join-Path $env:APPDATA 'Rime' }
$charDict = Join-Path $rimeDir 'cn_dicts\8105.dict.yaml'
$mydict   = Join-Path $rimeDir 'cn_dicts\mydict.dict.yaml'
$favdict  = Join-Path $rimeDir 'cn_dicts\favorites.dict.yaml'
$DefaultWeight = 100000

$DefaultHeader = @(
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

# ---------- 单字拼音表（从 8105 字表加载，取权重最高的读音） ----------
$script:charMap = @{}
function Import-CharMap {
  if ($script:charMap.Count -gt 0) { return }
  Get-Content $charDict -Encoding UTF8 | ForEach-Object {
    if ($_ -match "^([^\t]+?)\t([a-züv ]+?)(?:\t(\d+))?\s*$") {
      $ch = $Matches[1]; $py = $Matches[2].Trim()
      if ($ch.Length -ne 1 -or $py -eq '') { return }
      $w = if ($Matches[3]) { [long]$Matches[3] } else { 1 }
      if (-not $script:charMap.ContainsKey($ch)) { $script:charMap[$ch] = @() }
      $script:charMap[$ch] += [pscustomobject]@{ py = $py; w = $w }
    }
  }
}

function Get-AutoPinyin([string]$word) {
  Import-CharMap
  $parts = @(); $unknown = @()
  foreach ($c in $word.GetEnumerator()) {
    $s = [string]$c
    if ($s -match '^[A-Za-z0-9]$') { $parts += $s.ToLower(); continue }
    if ($script:charMap.ContainsKey($s)) {
      $parts += ($script:charMap[$s] | Sort-Object w -Descending | Select-Object -First 1).py
    } else {
      $unknown += $s; $parts += '?'
    }
  }
  return @{ pinyin = ($parts -join ' '); unknown = $unknown }
}

# ---------- 词库读写 ----------
function Read-DictEntries {
  $entries = @()
  if (-not (Test-Path $mydict)) { return $entries }
  Get-Content $mydict -Encoding UTF8 | ForEach-Object {
    if ($_ -match "^(.+?)\t([A-Za-züv' ]+?)(?:\t(\d+))?\s*$") {
      $w = $Matches[1]
      if ($w.StartsWith('#') -or $w.StartsWith('-')) { return }
      $wt = if ($Matches[3]) { [long]$Matches[3] } else { $DefaultWeight }
      $entries += [pscustomobject]@{ Word = $w; Pinyin = $Matches[2].Trim(); Weight = $wt }
    }
  }
  return $entries
}

function Read-FavoriteEntries {
  $entries = @()
  if (-not (Test-Path $favdict)) { return $entries }
  Get-Content $favdict -Encoding UTF8 | ForEach-Object {
    if ($_ -match "^([^\t]+)\t([^\t]+)(?:\t(\d+))?\s*$" -and -not $_.StartsWith('#')) {
      $entries += [pscustomobject]@{ Word = $Matches[1]; Pinyin = $Matches[2]; Weight = if ($Matches[3]) {[long]$Matches[3]} else {$DefaultWeight} }
    }
  }
  return $entries
}

function Save-FavoriteEntries($entries) {
  $lines = @('# Rime dictionary','# encoding: utf-8','---','name: favorites','version: "2026-09-06"','sort: by_weight','...','')
  foreach ($e in $entries) { $lines += "$($e.Word)`t$($e.Pinyin)`t$($e.Weight)" }
  [IO.File]::WriteAllLines($favdict, $lines, (New-Object Text.UTF8Encoding $false))
}

function Save-DictEntries($entries) {
  $header = @()
  $foundMarker = $false
  if (Test-Path $mydict) {
    Get-Content $mydict -Encoding UTF8 | ForEach-Object {
      if (-not $foundMarker) {
        $header += $_
        if ($_ -eq '# 下面开始写你的词，一行一个') { $foundMarker = $true }
      }
    }
  }
  if (-not $foundMarker) { $header = $DefaultHeader }
  $lines = @() + $header
  $i = 0
  $indexed = foreach ($e in $entries) { [pscustomobject]@{ e = $e; i = ($i++) } }
  foreach ($x in ($indexed | Sort-Object @{ Expression = { $_.e.Weight }; Descending = $true }, @{ Expression = { $_.i } })) {
    $lines += "$($x.e.Word)`t$($x.e.Pinyin)`t$($x.e.Weight)"
  }
  $utf8NoBom = New-Object Text.UTF8Encoding $false
  [IO.File]::WriteAllLines($mydict, $lines, $utf8NoBom)
}

# ---------- 主窗口 ----------
function New-ManagerWindow {
  Import-CharMap

  $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="个人词库管理 · 雾凇拼音" Height="660" Width="800"
        Background="#F3F2F1" FontFamily="Microsoft YaHei UI, Segoe UI" FontSize="14"
        WindowStartupLocation="CenterScreen">
  <Window.Resources>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="16"/>
      <Setter Property="BorderBrush" Value="#EDEBE9"/>
      <Setter Property="BorderThickness" Value="1"/>
      <!-- 注：刻意不用 DropShadowEffect，它会强制 WPF 走软件渲染，输入时明显卡顿 -->
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button">
      <Setter Property="Background" Value="#1677FF"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="16,0"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#4096FF"/>
        </Trigger>
        <Trigger Property="IsPressed" Value="True">
          <Setter Property="Background" Value="#0958D9"/>
        </Trigger>
        <Trigger Property="IsEnabled" Value="False">
          <Setter Property="Background" Value="#F5F5F5"/>
          <Setter Property="Foreground" Value="#BFBFBF"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="BtnDefault" TargetType="Button">
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="#323130"/>
      <Setter Property="BorderBrush" Value="#D9D9D9"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="16,0"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="BorderBrush" Value="#4096FF"/>
          <Setter Property="Foreground" Value="#4096FF"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource BtnDefault}">
      <Setter Property="Foreground" Value="#FF4D4F"/>
      <Setter Property="BorderBrush" Value="#FFA39E"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#FFF1F0"/>
          <Setter Property="BorderBrush" Value="#FF4D4F"/>
          <Setter Property="Foreground" Value="#FF4D4F"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Height" Value="32"/>
      <Setter Property="Padding" Value="8,4"/>
      <Setter Property="BorderBrush" Value="#D9D9D9"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="#FAFAFA"/>
      <Setter Property="Foreground" Value="#605E5C"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
      <Setter Property="BorderBrush" Value="#EDEBE9"/>
    </Style>
  </Window.Resources>

  <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="24">
    <StackPanel Orientation="Vertical">
      <!-- 页头 -->
      <StackPanel Margin="0,0,0,16">
        <TextBlock Text="个人词库管理" FontSize="20" FontWeight="Bold" Foreground="#323130"/>
        <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
          <TextBlock Text="雾凇拼音 · 你的加词在这里统一管理" FontSize="12" Foreground="#605E5C" VerticalAlignment="Center"/>
          <Border Background="#E6F4FF" CornerRadius="10" Padding="10,2" Margin="8,0,0,0" BorderBrush="#91CAFF" BorderThickness="1">
            <TextBlock x:Name="lblCount" Text="共 0 条" FontSize="12" Foreground="#1677FF"/>
          </Border>
        </StackPanel>
      </StackPanel>

      <!-- 已加词列表 -->
      <Border Style="{StaticResource Card}" Margin="0,0,0,16">
        <StackPanel>
          <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
            <TextBlock Text="已加词语" FontSize="14" FontWeight="SemiBold" Foreground="#323130" VerticalAlignment="Center"/>
            <TextBlock Text="搜索：" Margin="16,0,0,0" Foreground="#605E5C" VerticalAlignment="Center"/>
            <TextBox x:Name="txtSearch" Width="200" Margin="4,0,0,0"/>
            <Button x:Name="btnRefresh" Content="刷新" Style="{StaticResource BtnDefault}" Margin="8,0,0,0"/>
          </StackPanel>
          <DataGrid x:Name="grid" AutoGenerateColumns="False" IsReadOnly="True"
                    SelectionMode="Single" MinHeight="160" MaxHeight="240"
                    RowHeight="32" GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#F0F0F0"
                    AlternatingRowBackground="#FAFAFA" Background="White" BorderBrush="#EDEBE9" BorderThickness="1">
            <DataGrid.Columns>
              <DataGridTextColumn Header="词语" Binding="{Binding Word}" Width="*"/>
              <DataGridTextColumn Header="拼音" Binding="{Binding Pinyin}" Width="*"/>
              <DataGridTextColumn Header="权重" Binding="{Binding Weight}" Width="120"/>
            </DataGrid.Columns>
          </DataGrid>
          <TextBlock x:Name="lblEmpty" Text="还没有加过词，在下方输入框加第一个吧"
                     Foreground="#A19F9D" FontSize="12" Margin="0,8,0,0" Visibility="Collapsed"/>
          <!-- 选中行操作 -->
          <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
            <TextBlock x:Name="lblSelected" Text="未选中" FontSize="12" Foreground="#605E5C" VerticalAlignment="Center" Width="220"/>
            <TextBlock Text="权重：" Foreground="#605E5C" VerticalAlignment="Center"/>
            <TextBox x:Name="txtSelWeight" Width="110" Margin="4,0,0,0"/>
            <Button x:Name="btnUpdateWeight" Content="更新权重" Style="{StaticResource BtnDefault}" Margin="8,0,0,0"/>
            <Button x:Name="btnDelete" Content="删除所选" Style="{StaticResource BtnDanger}" Margin="8,0,0,0"/>
          </StackPanel>
        </StackPanel>
      </Border>

      <!-- 添加新词 -->
      <Border Style="{StaticResource Card}" Margin="0,0,0,16">
        <StackPanel>
          <TextBlock Text="添加新词" FontSize="14" FontWeight="SemiBold" Foreground="#323130" Margin="0,0,0,12"/>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="140"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <TextBlock Text="词语 *" Foreground="#605E5C" FontSize="12" Grid.Column="0"/>
            <TextBlock Text="拼音（空格分隔）" Foreground="#605E5C" FontSize="12" Grid.Column="1"/>
            <TextBlock Text="权重" Foreground="#605E5C" FontSize="12" Grid.Column="2"/>
            <TextBox x:Name="txtWord" Grid.Row="1" Grid.Column="0" Margin="0,4,8,0"/>
            <TextBox x:Name="txtPinyin" Grid.Row="1" Grid.Column="1" Margin="0,4,8,0"/>
            <TextBox x:Name="txtWeight" Grid.Row="1" Grid.Column="2" Margin="0,4,8,0" Text="100000"/>
            <StackPanel Grid.Row="1" Grid.Column="3" Orientation="Horizontal" Margin="0,4,0,0">
               <Button x:Name="btnAdd" Content="加入词库" Style="{StaticResource BtnPrimary}"/>
               <Button x:Name="btnFavorite" Content="加入收藏" Style="{StaticResource BtnDefault}" Margin="8,0,0,0"/>
             </StackPanel>
          </Grid>
          <TextBlock x:Name="lblAddTip" Text="输入词语后自动标注拼音（可手动修改），权重越大排名越靠前。"
                     FontSize="12" Foreground="#A19F9D" Margin="0,8,0,0" TextWrapping="Wrap"/>
        </StackPanel>
      </Border>

      <!-- 页脚：文件位置 -->
      <Border Style="{StaticResource Card}">
        <StackPanel>
          <TextBlock Text="保存位置" FontSize="14" FontWeight="SemiBold" Foreground="#323130" Margin="0,0,0,8"/>
          <TextBlock x:Name="lblPath" FontSize="12" Foreground="#605E5C" TextWrapping="Wrap"/>
          <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
            <Button x:Name="btnOpenFolder" Content="打开所在文件夹" Style="{StaticResource BtnDefault}"/>
            <TextBlock Text="改完记得重新部署输入法（右键任务栏小狼毫图标 → 重新部署）"
                       FontSize="12" Foreground="#A19F9D" VerticalAlignment="Center" Margin="12,0,0,0" TextWrapping="Wrap"/>
          </StackPanel>
        </StackPanel>
      </Border>
    </StackPanel>
  </ScrollViewer>
</Window>
'@

  $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
  $win = [System.Windows.Markup.XamlReader]::Load($reader)

  $grid = $win.FindName('grid')
  $lblCount = $win.FindName('lblCount')
  $lblEmpty = $win.FindName('lblEmpty')
  $lblSelected = $win.FindName('lblSelected')
  $txtSearch = $win.FindName('txtSearch')
  $txtWord = $win.FindName('txtWord')
  $txtPinyin = $win.FindName('txtPinyin')
  $txtWeight = $win.FindName('txtWeight')
  $txtSelWeight = $win.FindName('txtSelWeight')
  $lblAddTip = $win.FindName('lblAddTip')
  $lblPath = $win.FindName('lblPath')
  $btnFavorite = $win.FindName('btnFavorite')

  $items = New-Object System.Collections.ObjectModel.ObservableCollection[Object]
  $grid.ItemsSource = $items
  $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($items)
  $script:searchText = ''
  $view.Filter = {
    param($it)
    if ([string]::IsNullOrWhiteSpace($script:searchText)) { return $true }
    return $it.Word.Contains($script:searchText) -or $it.Pinyin.Contains($script:searchText)
  }

  # 注意：事件处理跑在独立作用域，$refresh/$tip 必须放 script 域，否则事件里 &$script:tip 会是空。
  # 控件一律经 $script:ui 取，不依赖闭包。
  $script:refresh = {
    $ui = $script:ui
    $ui.items.Clear()
    foreach ($e in (Read-DictEntries)) { $ui.items.Add($e) | Out-Null }
    $ui.view.Refresh()
    $ui.lblCount.Text = "共 $($ui.items.Count) 条"
    if ($ui.items.Count -eq 0) { $ui.lblEmpty.Visibility = 'Visible' } else { $ui.lblEmpty.Visibility = 'Collapsed' }
  }

  $script:tip = {
    param($msg, $ok)
    $script:ui.lblAddTip.Text = $msg
    if ($ok) { $script:ui.lblAddTip.Foreground = '#52C41A' } else { $script:ui.lblAddTip.Foreground = '#FF4D4F' }
  }

  $script:searchTimer = New-Object System.Windows.Threading.DispatcherTimer
  $script:searchTimer.Interval = [TimeSpan]::FromMilliseconds(250)
  $script:searchTimer.Add_Tick({
    $script:searchTimer.Stop()
    $script:searchText = $script:ui.txtSearch.Text.Trim()
    $script:ui.view.Refresh()
  })
  # 搜索防抖：停手 250ms 后再过滤，避免每个按键都全量刷新 DataGrid
  $txtSearch.Add_TextChanged({ $script:searchTimer.Stop(); $script:searchTimer.Start() })
  $win.FindName('btnRefresh').Add_Click({ &$script:refresh; &$script:tip '已刷新。' $true })

  $script:ui = @{
    win = $win; grid = $grid; items = $items; view = $view
    lblCount = $lblCount; lblEmpty = $lblEmpty; lblSelected = $lblSelected
    txtSearch = $txtSearch; txtWord = $txtWord; txtPinyin = $txtPinyin
    txtWeight = $txtWeight; txtSelWeight = $txtSelWeight
    lblAddTip = $lblAddTip; lblPath = $lblPath
  }

  # 输入词语自动注音（防重入：写拼音框会触发它自己的事件，不能回头再进这里）
  # 注意：WPF 事件 ScriptBlock 跑在独立作用域，闭包捕获不到函数局部变量，
  # 所以控件一律经 $script:ui 取，事件源用 $this（sender）而不用闭包变量。
  $script:annotating = $false
  $txtWord.Add_TextChanged({
    if ($script:annotating) { return }
    $script:annotating = $true
    try {
      $src = $this
      if ($src -eq $null) { $src = $script:ui.txtWord }
      $w = $src.Text.Trim()
      if ($w -eq '') { return }
      $r = Get-AutoPinyin $w
      if ($r.unknown.Count -eq 0) {
        if ($script:ui.txtPinyin.Text -ne $r.pinyin) { $script:ui.txtPinyin.Text = $r.pinyin }
        &$script:tip '已自动标注拼音（可手动修改），权重越大排名越靠前。' $true
      } else {
        &$script:tip ('“' + ($r.unknown -join '”“') + '”在字表里没找到，请手动输入完整拼音。') $false
      }
    } finally {
      $script:annotating = $false
    }
  })

  $btnFavorite.Add_Click({
    $ui = $script:ui
    $word = $ui.txtWord.Text.Trim()
    if ($word -eq '' -or $word.Contains("`r") -or $word.Contains("`n")) { &$script:tip '收藏内容必须是单行，且不能为空。' $false; return }
    $key = $word.Substring(0, [Math]::Min(3, $word.Length)).ToLower()
    $fav = @(Read-FavoriteEntries)
    $fav += [pscustomobject]@{ Word = $word; Pinyin = $key; Weight = $DefaultWeight }
    Save-FavoriteEntries $fav
    $ui.txtWord.Clear(); &$script:tip ("已加入收藏，触发码：v3$key；保存到：$favdict") $true
  })

  $win.FindName('btnAdd').Add_Click({
    $ui = $script:ui
    $word = $ui.txtWord.Text.Trim()
    if ($word -eq '') { &$script:tip '请先输入词语。' $false; return }
    $pinyin = $ui.txtPinyin.Text.Trim().ToLower()
    if ($pinyin -eq '') {
      $r = Get-AutoPinyin $word
      if ($r.unknown.Count -gt 0) { &$script:tip '拼音为空，请手动输入拼音（空格分隔）。' $false; return }
      $pinyin = $r.pinyin
      $ui.txtPinyin.Text = $pinyin
    }
    if ($pinyin -notmatch "^[a-züv][a-züv' ]*$") { &$script:tip '拼音格式不对（只允许小写字母/空格/分词单引号）。' $false; return }
    $weight = $DefaultWeight
    if ($ui.txtWeight.Text.Trim() -ne '') {
      $tmp = 0
      if ([long]::TryParse($ui.txtWeight.Text.Trim(), [ref]$tmp) -and $tmp -gt 0) { $weight = $tmp }
      else { &$script:tip '权重无效，请输入正整数。' $false; return }
    }
    $dup = $ui.items | Where-Object { $_.Word -eq $word } | Select-Object -First 1
    if ($dup) {
      $msg = '“' + $word + '”已存在（' + $dup.Pinyin + '），要再追加一条吗？'
      $ans = [System.Windows.MessageBox]::Show($msg, '重复提醒',
        [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
      if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }
    $all = @() + $ui.items + [pscustomobject]@{ Word = $word; Pinyin = $pinyin; Weight = $weight }
    Save-DictEntries $all
    &$script:refresh
    $ui.txtWord.Clear(); $ui.txtPinyin.Clear(); $ui.txtWeight.Text = "$DefaultWeight"
    &$script:tip ("已加入 “" + $word + "”，保存在：" + $mydict) $true
  })

  $grid.Add_SelectionChanged({
    $ui = $script:ui
    $sel = $ui.grid.SelectedItem
    if ($sel) {
      $ui.lblSelected.Text = "已选：$($sel.Word)"
      $ui.txtSelWeight.Text = "$($sel.Weight)"
    } else {
      $ui.lblSelected.Text = '未选中'
      $ui.txtSelWeight.Text = ''
    }
  })

  $win.FindName('btnUpdateWeight').Add_Click({
    $ui = $script:ui
    $sel = $ui.grid.SelectedItem
    if (-not $sel) { &$script:tip '请先在列表中选中一个词。' $false; return }
    $tmp = 0
    if (-not ([long]::TryParse($ui.txtSelWeight.Text.Trim(), [ref]$tmp)) -or $tmp -le 0) {
      &$script:tip '权重无效，请输入正整数。' $false; return
    }
    $sel.Weight = $tmp
    Save-DictEntries @() + $ui.items
    &$script:refresh
    &$script:tip ("“" + $sel.Word + "”权重已改为 $tmp，保存在：" + $mydict) $true
  })

  $win.FindName('btnDelete').Add_Click({
    $ui = $script:ui
    $sel = $ui.grid.SelectedItem
    if (-not $sel) { &$script:tip '请先在列表中选中一个词。' $false; return }
    $q = '确定删除“' + $sel.Word + '”吗？'
    $ans = [System.Windows.MessageBox]::Show($q, '删除确认',
      [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
    if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { return }
    $rest = @() + ($ui.items | Where-Object { $_ -ne $sel })
    Save-DictEntries $rest
    &$script:refresh
    &$script:tip ("已删除 “" + $sel.Word + "”，保存在：" + $mydict) $true
  })

  $lblPath.Text = $mydict
  $win.FindName('btnOpenFolder').Add_Click({
    if (Test-Path -LiteralPath $mydict -PathType Leaf) {
      # explorer 的 /select 参数必须和逗号连在一起，不能写成 PowerShell 的两个参数。
      Start-Process -FilePath 'explorer.exe' -ArgumentList @('/select,', $mydict)
    } else {
      [System.Windows.MessageBox]::Show(
        ('找不到词库文件：' + $mydict),
        '打开文件夹失败',
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error) | Out-Null
    }
  })

  &$script:refresh
  return $win
}

if ($MyInvocation.InvocationName -ne '.') {
  $w = New-ManagerWindow
  $w.ShowDialog() | Out-Null
}
