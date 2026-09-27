param(
  [switch]$Revert,
  [string]$InstallDir = '',
  [string]$GuiScript  = '',
  [string]$WrapperCs  = ''
)
# =============================================================================
# vmenu 托盘菜单入口安装 / 撤销
#
# 目标：在小狼毫托盘图标右键菜单里，把「输入法设定 (S)」变成「输入法设置 (S)」，
#       点它就打开 vmenu 可视化设置窗口（输入法里 v → 1 的那个窗口）。
#
# 原理（实测 + 源码核对，见仓库 docs/ARCHITECTURE.md）：
#   1) 托盘右键菜单是 WeaselServer.exe 里的菜单资源，项与命令号写死，
#      无法通过配置文件新增项；
#   2) 服务端对命令号的处理只有一件事：启动安装目录下的 WeaselDeployer.exe
#      （无参数=输入法设定；/deploy=重新部署；/dict=用户词典管理；/sync=用户资料同步）；
#   3) 所以本脚本做两件可逆的事：
#        a. 就地改 WeaselServer.exe 里那个菜单项的文字：输入法设定 → 输入法设置
#           （UTF-16 等长替换，只改 2 个字节，不动任何偏移量）；
#        b. 把真正的 WeaselDeployer.exe 改名为 WeaselDeployer.real.exe，
#           用一个小代理（vmenu-deployer-wrapper.cs 编译而来）顶替它的位置：
#             不带参数 → 打开 vmenu 设置窗口；带参数 → 原样转发给 .real.exe。
#
# 撤销：vmenu-tray-setup.ps1 -Revert
# 备份：WeaselServer.exe.vmenu-bak（改之前自动生成，撤销时用它还原）
# =============================================================================

$ErrorActionPreference = 'Stop'

# Resolve locations when not passed explicitly (portable install support):
#   InstallDir -> newest weasel-* dir under Program Files\Rime
#   GuiScript / WrapperCs -> files next to this script (the package layout).
if (-not $InstallDir) {
  $cand = Get-ChildItem -Path (Join-Path $env:ProgramFiles 'Rime') -Directory -Filter 'weasel-*' -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending | Select-Object -First 1
  if (-not $cand -and ${env:ProgramFiles(x86)}) {
    $cand = Get-ChildItem -Path (Join-Path ${env:ProgramFiles(x86)} 'Rime') -Directory -Filter 'weasel-*' -ErrorAction SilentlyContinue |
      Sort-Object Name -Descending | Select-Object -First 1
  }
  if ($cand) { $InstallDir = $cand.FullName } else { $InstallDir = 'C:\Program Files\Rime\weasel-0.17.4' }
}
if (-not $GuiScript)  { $GuiScript  = Join-Path $PSScriptRoot 'vmenu-settings-gui.ps1' }
if (-not $WrapperCs)  { $WrapperCs  = Join-Path $PSScriptRoot 'vmenu-deployer-wrapper.cs' }

$server    = Join-Path $InstallDir 'WeaselServer.exe'
$serverBak = "$server.vmenu-bak"
$deployer  = Join-Path $InstallDir 'WeaselDeployer.exe'
$realDep   = Join-Path $InstallDir 'WeaselDeployer.real.exe'
$csc       = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$lnkDir    = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\小狼毫输入法'
$lnkOld    = Join-Path $lnkDir '【小狼毫】输入法设定.lnk'
$lnkNew    = Join-Path $lnkDir '【小狼毫】输入法设置.lnk'

# 用字符码拼出标签，避免脚本文件编码影响匹配
$labelOld = ([char]0x8F93) + ([char]0x5165) + ([char]0x6CD5) + ([char]0x8BBE) + ([char]0x5B9A) + ' (&S)'  # 输入法设定 (&S)
$labelNew = ([char]0x8F93) + ([char]0x5165) + ([char]0x6CD5) + ([char]0x8BBE) + ([char]0x7F6E) + ' (&S)'  # 输入法设置 (&S)

function Get-ServerProcess { Get-Process -Name WeaselServer -ErrorAction SilentlyContinue }
function Stop-Server {
  $p = Get-ServerProcess
  if ($p) { $p | Stop-Process -Force; Start-Sleep -Seconds 2 }
}
function Start-Server {
  if (-not (Get-ServerProcess)) {
    Start-Process (Join-Path $InstallDir 'WeaselServer.exe') -WorkingDirectory $InstallDir
    Start-Sleep -Seconds 5
  }
}
function Find-All {
  param([byte[]]$Hay, [byte[]]$Needle)
  $hits = New-Object System.Collections.ArrayList
  for ($i = 0; $i -le $Hay.Length - $Needle.Length; $i++) {
    if ($Hay[$i] -ne $Needle[0]) { continue }
    $ok = $true
    for ($j = 1; $j -lt $Needle.Length; $j++) { if ($Hay[$i + $j] -ne $Needle[$j]) { $ok = $false; break } }
    if ($ok) { [void]$hits.Add($i) }
  }
  return $hits
}
function Test-Label {
  param([string]$Path)
  $b = [IO.File]::ReadAllBytes($Path)
  $nOld = Find-All $b ([Text.Encoding]::Unicode.GetBytes($labelOld))
  $nNew = Find-All $b ([Text.Encoding]::Unicode.GetBytes($labelNew))
  return [pscustomobject]@{ Old = $nOld.Count; New = $nNew.Count }
}

if ($Revert) {
  Write-Host '=== 撤销 vmenu 托盘入口 ===' -ForegroundColor Cyan
  Stop-Server
  if (Test-Path $serverBak) {
    Copy-Item $serverBak $server -Force
    Write-Host "  已还原 WeaselServer.exe（来自 $serverBak）"
  } else { Write-Host '  没有找到备份，跳过还原 exe' -ForegroundColor Yellow }
  if (Test-Path $realDep) {
    Remove-Item $deployer -Force -ErrorAction SilentlyContinue
    Move-Item $realDep $deployer -Force
    Write-Host '  已把 WeaselDeployer.real.exe 改名回 WeaselDeployer.exe'
  } else { Write-Host '  没有找到 WeaselDeployer.real.exe，跳过' -ForegroundColor Yellow }
  if ((Test-Path $lnkNew) -and -not (Test-Path $lnkOld)) {
    Rename-Item $lnkNew (Split-Path -Leaf $lnkOld)
    Write-Host '  开始菜单快捷方式名字已还原'
  }
  Start-Server
  $t = Test-Label $server
  Write-Host ("  校验：exe 里 旧标签={0} 处，新标签={1} 处" -f $t.Old, $t.New)
  Write-Host '=== 撤销完成 ===' -ForegroundColor Green
  exit 0
}

Write-Host '=== 安装 vmenu 托盘入口 ===' -ForegroundColor Cyan

# 0) 前置检查
foreach ($p in @($server, $deployer)) {
  if (-not (Test-Path $p)) { throw "找不到文件：$p" }
}
if (-not (Test-Path $WrapperCs)) { throw "找不到代理源码：$WrapperCs" }
if (-not (Test-Path $csc)) { throw "找不到 C# 编译器：$csc" }
if (-not (Test-Path $GuiScript)) { Write-Host "  警告：找不到设置窗口脚本 $GuiScript（代理会退回原生设置对话框）" -ForegroundColor Yellow }

# 1) 备份 exe（只备份一次，保证备份是原始版本）
if (-not (Test-Path $serverBak)) {
  Stop-Server
  Copy-Item $server $serverBak -Force
  Write-Host "  已备份 WeaselServer.exe → $serverBak"
} else {
  Write-Host '  WeaselServer.exe 备份已存在，沿用（不会被覆盖）'
}

# 2) 改菜单项文字
$t0 = Test-Label $server
if ($t0.New -gt 0 -and $t0.Old -eq 0) {
  Write-Host '  菜单项文字已经是「输入法设置」，跳过'
} else {
  Stop-Server
  $bytes = [IO.File]::ReadAllBytes($server)
  $needle = [Text.Encoding]::Unicode.GetBytes($labelOld)
  $repl   = [Text.Encoding]::Unicode.GetBytes($labelNew)
  if ($needle.Length -ne $repl.Length) { throw '内部错误：新旧标签长度不一致' }
  $hits = Find-All $bytes $needle
  if ($hits.Count -eq 0) { throw "在 WeaselServer.exe 里找不到菜单项文字（可能版本不同）" }
  foreach ($off in $hits) { for ($j = 0; $j -lt $repl.Length; $j++) { $bytes[$off + $j] = $repl[$j] } }
  [IO.File]::WriteAllBytes($server, $bytes)
  Write-Host ("  已就地修改菜单项文字（{0} 处，共 {1} 字节）" -f $hits.Count, $repl.Length)
}

# 3) 安装部署器代理
#    识别「当前的 WeaselDeployer.exe 是代理还是真身」**不能看文件大小**：
#    代理源码改一次、编译出来大小就变，上次就是这么把旧代理（5632 字节）当成
#    真身改名成 .real.exe，把唯一的真身（638976 字节）覆盖掉的。
#    现在改成看代理自己编译进去的标记字符串，并且：
#      · .real.exe 已经是真身（>100KB 且不含标记）→ 绝不再动它；
#      · 真要覆盖 .real.exe 之前先留一份 .real.exe.vmenu-bak（只留一次）。
$tmpExe = Join-Path $env:TEMP 'vmenu-deployer-wrapper.exe'
Remove-Item $tmpExe -Force -ErrorAction SilentlyContinue
& $csc /nologo /target:winexe /r:System.Windows.Forms.dll /out:$tmpExe $WrapperCs | Write-Host
if (-not (Test-Path $tmpExe)) { throw '代理编译失败' }

$proxyMark = 'VMenuDeployerProxy'
function Test-Proxy([string]$path) {
  if (-not (Test-Path $path)) { return $false }
  $b = [IO.File]::ReadAllBytes($path)
  return [Text.Encoding]::ASCII.GetString($b).Contains($proxyMark)
}

$realDepBak = "$realDep.vmenu-bak"
$realIsReal = (Test-Path $realDep) -and (-not (Test-Proxy $realDep)) -and ((Get-Item $realDep).Length -gt 100000)

if ($realIsReal) {
  Write-Host ("  WeaselDeployer.real.exe 已是真身（{0} 字节），跳过改名" -f (Get-Item $realDep).Length)
} elseif (Test-Proxy $deployer) {
  throw ("WeaselDeployer.real.exe 不是真身（{0} 字节），而 WeaselDeployer.exe 也是本代理 —— " -f (Get-Item $realDep -ErrorAction SilentlyContinue).Length +
         "真身已丢失，请先从 D:\weasel-build 的备份里恢复 WeaselDeployer.real.exe 再运行本脚本")
} else {
  Stop-Server
  # 只备份一次，避免把真身备份覆盖成别的东西
  if ((Test-Path $realDep) -and (-not (Test-Path $realDepBak))) {
    Copy-Item $realDep $realDepBak -Force
    Write-Host ("  已备份旧 WeaselDeployer.real.exe → $realDepBak")
  }
  Move-Item $deployer $realDep -Force
  Write-Host ("  WeaselDeployer.exe（{0} 字节，真身）→ WeaselDeployer.real.exe" -f (Get-Item $realDep).Length)
}
Copy-Item $tmpExe $deployer -Force
Write-Host ("  已安装代理 WeaselDeployer.exe（{0} 字节）" -f (Get-Item $deployer).Length)

# 4) 开始菜单快捷方式改名
if ((Test-Path $lnkOld) -and -not (Test-Path $lnkNew)) {
  Rename-Item $lnkOld (Split-Path -Leaf $lnkNew)
  Write-Host '  开始菜单「【小狼毫】输入法设定」→「【小狼毫】输入法设置」'
}

# 5) 重启服务并校验
Start-Server
$t1 = Test-Label $server
Write-Host ''
Write-Host ("校验：exe 里 旧标签={0} 处 / 新标签={1} 处" -f $t1.Old, $t1.New)
Write-Host ("文件：WeaselDeployer.exe={0} 字节，WeaselDeployer.real.exe={1} 字节" -f (Get-Item $deployer).Length, (Get-Item $realDep).Length)
Write-Host ("服务：WeaselServer PID={0}" -f ((Get-ServerProcess).Id -join ','))
Write-Host '=== 完成：右键托盘图标，菜单里现在有「输入法设置 (S)」 ===' -ForegroundColor Green
