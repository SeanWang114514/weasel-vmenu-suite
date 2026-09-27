# stage-suite-repo.ps1 —— 把工作区整理成可直接推送到 GitHub 的 weasel-vmenu-suite 仓库
# 只复制「源码 / 脚本 / 配置 / 运行时」，不复制构建产物、模型、截图、备份。
$ErrorActionPreference = 'Stop'
$Root = 'D:\VibeCoding\输入法'
$Dest = Join-Path $Root 'repo\weasel-vmenu-suite'

if (Test-Path $Dest) { Remove-Item $Dest -Recurse -Force }
New-Item -ItemType Directory -Path $Dest -Force | Out-Null

# 整个目录一起复制（这些是仓库的一部分）
$keepDirs = @('packaging', 'VMenuSettingsSrc', 'lua', 'dist', 'llama.cpp', 'corpus', 'rime-sandbox')
# 绝不进仓库
$skipDirs = @('build', '__pycache__', '.git')
$skipFiles = @('*.userdb', 'installation.yaml', 'user.yaml', '*.log', 'lua-probe.txt',
               'panel-probe.txt', 'open-settings.flag', '*.bak', '*.bak.*')

foreach ($d in $keepDirs) {
  $src = Join-Path $Root $d
  if (-not (Test-Path $src)) { Write-Host "skip missing dir: $d"; continue }
  $dst = Join-Path $Dest $d
  New-Item -ItemType Directory -Path $dst -Force | Out-Null
  $args = @($src, $dst, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1')
  $args += '/XD'
  foreach ($s in $skipDirs) { $args += (Join-Path $src $s) }
  $args += '/XF'
  foreach ($s in $skipFiles) { $args += $s }
  & robocopy @args | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "robocopy failed for $d ($LASTEXITCODE)" }
}

# 根目录的单个文件
$rootFiles = @(
  'README-必读.md', '使用说明.md', '词库与要求.md',
  'VMenu.exe', 'VMenuSettings.exe', 'weasel-0.17.4.0-installer.exe',
  'VMenu.cs', 'vmenu-deployer-wrapper.cs', 'voice-overlay.py', 'voice-input.py',
  'voice-punct-test.py', 'check_dlls.py',
  'add-word.ps1', 'build-extra-dicts.ps1', 'caret-probe.ps1', 'clipboard-sync.ps1',
  'clipboard-sync-stop.ps1', 'deploy-ime.ps1', 'dict-manager.ps1', 'dump-ime-ui.ps1',
  'focus-notepad.ps1', 'gui-dblclick-test.ps1', 'ime-probe.ps1', 'ime-probe2.ps1',
  'ime-probe3.ps1', 'ime-switch.ps1', 'ime-test.ps1', 'list-windows.ps1',
  'patch-build-schema.ps1', 'punct-test.ps1', 'repro-ghost.ps1', 'run-vmenu-tests.ps1',
  'shot-window.ps1', 'switch-ime.ps1', 'test-clean.ps1', 'type-and-shot.ps1',
  'type-test.ps1', 'ui-dump.ps1', 'v1-e2e-test.ps1', 'v1-latency-test.ps1',
  'vmenu-settings-gui.ps1', 'vmenu-tray-setup.ps1', 'vmenu-watcher.ps1',
  'vmenu-watcher-stop.ps1', 'window-keys-shot.ps1', '安装-收尾.ps1',
  '安装.bat', '安装-收尾.bat', '打开设置.bat', '重建部署.bat', '加词.bat',
  '词库管理.bat', '语音输入.bat', '语音输入-悬浮球.bat', '下载Qwen模型.bat',
  'Stop-Helpers.bat', 'clipboard-sync.bat', '设置.bat',
  'icon-reset.png', 'icon-reset-transparent.png',
  'candidate-settings.txt', 'fuzzy-settings.txt', 'smart-punct-settings.txt',
  'vmenu-settings.txt', 'voice-settings.txt', 'predict-bigram.txt',
  'rime_ice.custom.yaml', 'default.custom.yaml', 'weasel.custom.yaml',
  'custom_phrase.txt', 'favorites.dict.yaml', 'predict-bigram.txt'
) | Sort-Object -Unique

foreach ($f in $rootFiles) {
  $src = Join-Path $Root $f
  if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $Dest -Force }
  else { Write-Host "skip missing file: $f" }
}

$files = Get-ChildItem $Dest -Recurse -File
$sum = ($files | Measure-Object Length -Sum).Sum
Write-Host ("staged: {0} files, {1} MB -> {2}" -f $files.Count, [math]::Round($sum / 1MB, 1), $Dest)
Write-Host 'largest 8:'
$files | Sort-Object Length -Descending | Select-Object -First 8 |
  ForEach-Object { "  {0,8} MB  {1}" -f [math]::Round($_.Length / 1MB, 1), $_.FullName.Replace("$Dest\", '') }
