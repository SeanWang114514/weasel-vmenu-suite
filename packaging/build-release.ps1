# build-release.ps1 —— 组装发布树 -> 打 zip（rime-install 兼容）-> 编译 exe 直装包
#
# 用法（在仓库任意位置）：
#   powershell -File packaging\build-release.ps1                 # 完整构建（含模型）
#   powershell -File packaging\build-release.ps1 -NoModels       # 跳过 971MB 模型拷贝（冒烟）
#   powershell -File packaging\build-release.ps1 -SkipExe        # 只打 zip
#   powershell -File packaging\build-release.ps1 -SkipZip        # 只编 exe
#
# 产物：
#   out\RimeVMenu-<ver>.zip        zip 根目录 = RimeVMenu-<ver>\（rime-install.bat
#                                  解包规则要求根文件夹名 = zip 主文件名）
#   out\RimeVMenu-Setup-<ver>.exe  Inno Setup 直装包
#
# 发布树 stage\RimeVMenu-<ver>\ 的组成：
#   1) Rime 配置（来自实时 Rime 用户目录，剔除 build/ userdb/ 备份/日志，剪贴板缓存清空）
#   2) 外挂 exe 与脚本（VMenu/Voice* 从 dist\ 优先取，其余来自仓库根）
#   3) llama.cpp CPU 运行时（剔除 CUDA/RPC，保证无显卡也能跑）
#   4) Qwen3-ASR 两个模型（-NoModels 跳过）
#   5) 小狼毫安装器 + README-必读.md
param(
  [string]$Version = '1.0.1',
  [string]$RimeSrc = 'D:\rime-sandbox',
  [string]$LlamaSrc = 'D:\王修翊\llama.cpp',
  [switch]$NoModels,
  [switch]$SkipZip,
  [switch]$SkipExe
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot          # packaging\.. = 仓库根

# 允许在没有 D:\rime-sandbox 的机器上退回仓库内的 rime-sandbox\ 副本
if (-not (Test-Path (Join-Path $RimeSrc 'rime_ice.schema.yaml'))) {
  $alt = Join-Path $Root 'rime-sandbox'
  if (Test-Path (Join-Path $alt 'rime_ice.schema.yaml')) { $RimeSrc = $alt }
  else { throw "Rime source dir not found: $RimeSrc" }
}

# llama.cpp 运行时同样要能退回仓库内的副本：默认值指向开发者本机路径，
# 全新 clone 的机器上没有那个目录，原来会直接 throw —— 从源码构建必挂。
if (-not (Test-Path (Join-Path $LlamaSrc 'llama-server.exe'))) {
  $altLlama = Join-Path $Root 'llama.cpp'
  if (Test-Path (Join-Path $altLlama 'llama-server.exe')) { $LlamaSrc = $altLlama }
  else { throw "llama runtime source not found: $LlamaSrc (set -LlamaSrc, or put a CPU build in $altLlama)" }
}

$Name  = "RimeVMenu-$Version"
$Stage = Join-Path $Root "stage\$Name"
$Out   = Join-Path $Root 'out'
Write-Host "== build-release: $Name =="
Write-Host "Rime config source: $RimeSrc"
Write-Host "Llama runtime source: $LlamaSrc"

if (Test-Path (Join-Path $Root 'stage')) { Remove-Item (Join-Path $Root 'stage') -Recurse -Force }
New-Item -ItemType Directory -Path $Stage, $Out -Force | Out-Null

# ---------------------------------------------------------------- 1) 配置
$skipDirs  = @('build', '__pycache__')
$skipFiles = @('installation.yaml', 'user.yaml', 'vmenu-debug.log', 'smart-punct.log',
               'lua-probe.txt', 'panel-probe.txt', 'open-settings.flag', 'voice-overlay.log')
$copied = 0
Get-ChildItem $RimeSrc -Force | ForEach-Object {
  if ($_.PSIsContainer) {
    if ($_.Name -in $skipDirs -or $_.Name -like '*.userdb') { return }
    Copy-Item $_.FullName -Destination (Join-Path $Stage $_.Name) -Recurse -Force
  } else {
    if ($_.Name -in $skipFiles) { return }
    if ($_.Name -like '*.bak*') { return }
    Copy-Item $_.FullName -Destination (Join-Path $Stage $_.Name) -Force
  }
  $copied++
}
# 剪贴板历史属于隐私数据：发布树里必须是空文件（首次运行由同步进程重建）
[IO.File]::WriteAllText((Join-Path $Stage 'clipboard-cache.txt'), '')
# lua 子目录里的备份同样剔除
Get-ChildItem $Stage -Recurse -File -Filter '*.bak*' -ErrorAction SilentlyContinue |
  Remove-Item -Force
Write-Host "config staged ($copied top-level entries)"

# ------------------------------------------------------------ 2) 外挂与脚本
$helpers = @(
  'VMenu.exe', 'VMenuSettings.exe', 'VoiceOverlay.exe', 'VoiceInput.exe',
  '打开设置.bat', 'clipboard-sync.bat', 'clipboard-sync.ps1', 'clipboard-sync-stop.ps1',
  'vmenu-watcher.ps1', 'vmenu-watcher-stop.ps1', 'vmenu-settings-gui.ps1',
  'patch-build-schema.ps1', 'vmenu-tray-setup.ps1', 'vmenu-deployer-wrapper.cs',
  'dict-manager.ps1', 'add-word.ps1', '加词.bat', '词库管理.bat', '重建部署.bat',
  '语音输入.bat', '语音输入-悬浮球.bat', 'voice-overlay.py', 'voice-input.py',
  '安装.bat', '安装-收尾.bat', '安装-收尾.ps1', 'Stop-Helpers.bat', '下载Qwen模型.bat',
  'weasel-0.17.4.0-installer.exe', '使用说明.md', 'README-必读.md'
)
foreach ($h in $helpers) {
  $src = $null
  foreach ($base in @((Join-Path $Root 'dist'), $Root)) {
    $c = Join-Path $base $h
    if (Test-Path -LiteralPath $c) { $src = $c; break }
  }
  if (-not $src) { throw "helper missing: $h" }
  Copy-Item -LiteralPath $src -Destination (Join-Path $Stage $h) -Force
}
Write-Host "helpers staged ($($helpers.Count) files)"

# ---------------------------------------------------------- 3) llama.cpp 运行时
if (-not (Test-Path (Join-Path $LlamaSrc 'llama-server.exe'))) {
  throw "llama runtime source not found: $LlamaSrc (set -LlamaSrc)"
}
$llamaDst = Join-Path $Stage 'llama.cpp'
New-Item -ItemType Directory -Path $llamaDst -Force | Out-Null
Get-ChildItem $LlamaSrc -File | Where-Object {
  ($_.Name -eq 'llama-server.exe' -or $_.Name -eq 'LICENSE-LLVM-OpenMP' -or $_.Extension -eq '.dll') -and
  $_.Name -notmatch '^(cublas|cudart|ggml-cuda|ggml-rpc)'
} | ForEach-Object { Copy-Item $_.FullName -Destination $llamaDst -Force }
$llamaSrv = Join-Path $llamaDst 'llama-server.exe'
if (-not (Test-Path $llamaSrv)) { throw "llama-server.exe failed to stage" }
Write-Host "llama runtime staged ($((Get-ChildItem $llamaDst | Measure-Object Length -Sum).Sum / 1MB -as [int]) MB, CPU-only)"

# ------------------------------------------------------------------ 4) 模型
$models = @('Qwen3-ASR-0.6B-Q8_0.gguf', 'mmproj-Qwen3-ASR-0.6B-Q8_0.gguf')
if ($NoModels) {
  Write-Host 'models: SKIPPED (-NoModels)'
} else {
  foreach ($m in $models) {
    $src = Join-Path $Root $m
    if (-not (Test-Path $src)) { throw "model missing: $src (run 下载Qwen模型.bat)" }
    [IO.File]::Copy($src, (Join-Path $Stage $m), $true)
  }
  Write-Host "models staged ($([math]::Round((Get-ChildItem $Stage -Filter '*.gguf' | Measure-Object Length -Sum).Sum / 1MB)) MB)"
}

# ---------------------------------------------------------------- 5) 自检
$must = @(
  'rime_ice.schema.yaml', 'rime_ice.custom.yaml', 'weasel.custom.yaml', 'default.custom.yaml',
  'predict-bigram.txt', 'custom_phrase.txt', 'fuzzy-settings.txt', 'candidate-settings.txt',
  'voice-settings.txt', 'vmenu-settings.txt',
  (Join-Path 'lua' 'vmenu_core.lua'), (Join-Path 'lua' 'menu_processor.lua'),
  (Join-Path 'lua' 'fuzzy_filter.lua'), (Join-Path 'lua' 'en_gate.lua'),
  (Join-Path 'lua' 'predict_filter.lua'), (Join-Path 'lua' 'lunar.db'),
  (Join-Path 'cn_dicts' 'mydict.dict.yaml'), (Join-Path 'cn_dicts' 'favorites.dict.yaml'),
  (Join-Path 'cn_dicts' 'base.dict.yaml'), (Join-Path 'en_dicts' 'en.dict.yaml'),
  (Join-Path 'opencc' 'emoji.json'),
  'VMenu.exe', 'VMenuSettings.exe', 'VoiceOverlay.exe', 'VoiceInput.exe',
  '安装.bat', '安装-收尾.bat', '安装-收尾.ps1', 'Stop-Helpers.bat', '下载Qwen模型.bat',
  'vmenu-tray-setup.ps1', 'vmenu-deployer-wrapper.cs', 'patch-build-schema.ps1',
  '打开设置.bat', 'clipboard-sync.bat', '重建部署.bat', '语音输入.bat', '语音输入-悬浮球.bat',
  'weasel-0.17.4.0-installer.exe', '使用说明.md', 'README-必读.md',
  (Join-Path 'llama.cpp' 'llama-server.exe')
)
$missing = @()
foreach ($f in $must) { if (-not (Test-Path (Join-Path $Stage $f))) { $missing += $f } }
if (-not $NoModels) { foreach ($m in $models) { if (-not (Test-Path (Join-Path $Stage $m))) { $missing += $m } } }
if ($missing.Count) { throw "stage verification FAILED, missing:`n  " + ($missing -join "`n  ") }
Write-Host 'stage verification: OK'

$sizeMB = [math]::Round((Get-ChildItem $Stage -Recurse -File | Measure-Object Length -Sum).Sum / 1MB)
Write-Host "stage size: $sizeMB MB"

# ------------------------------------------------------------------ 6) zip
if (-not $SkipZip) {
  $sevenZip = $null
  foreach ($c in @((Get-ChildItem (Join-Path $env:ProgramFiles 'Rime') -Recurse -Filter 7z.exe -EA SilentlyContinue | Select-Object -First 1).FullName,
                   'C:\Program Files\7-Zip\7z.exe')) { if ($c -and (Test-Path $c)) { $sevenZip = $c; break } }
  if (-not $sevenZip) { $sevenZip = (Get-Command 7z.exe -EA Stop).Source }
  $zipPath = Join-Path $Out "$Name.zip"
  if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
  Push-Location (Split-Path $Stage)
  try {
    # -mcu=on  = 强制「文件名按 UTF-8 存储并置 UTF-8 标志位」（zip flag bit 11）。
    # 不加这个开关时 7z 只在「本地代码页不是 936」之类的条件下才自动选 UTF-8：
    # 本机 (ACP=936) 实测写出来的是**裸 GBK 字节 + 无 UTF-8 标志**——7-Zip / Explorer
    # 在简体中文机上看着正常，但 .NET ZipFile、macOS、Linux 以及所有非 GBK 的
    # Windows 会把「安装.bat / 语音输入.bat」这类文件名解码成乱码，
    # 而 rime-install.bat 是靠文件名找包的。必须显式打开。
    & $sevenZip a -tzip -mx=5 -bd -y -mcu=on $zipPath $Name | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "7z zip failed: $LASTEXITCODE" }
  } finally { Pop-Location }
  # 验证 zip 根 = RimeVMenu-<ver>\（rime-install 解包规则）
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zf = [IO.Compression.ZipFile]::OpenRead($zipPath)
  try {
    $first = $zf.Entries | Select-Object -First 1 -ExpandProperty FullName
    if ($first -notlike "$Name/*") { throw "zip root mismatch: $first" }
    # 回归断言：非 ASCII 文件名必须能被 .NET（严格按 UTF-8 读）解出来。
    # 之前没这个断言时，「文件名静默退化成 GBK」这种事故一路发到了 Release。
    $cn = $zf.Entries | Where-Object { $_.FullName -match '[^\x00-\x7F]' }
    if ($cn.Count -eq 0) { throw "zip has no non-ASCII entry names - expected 安装.bat etc." }
    foreach ($e in $cn) {
      if ($e.FullName -match '\uFFFD') { throw "zip entry name mojibake: $($e.FullName)" }
      if ($e.FullName -notmatch '[\u4e00-\u9fff]') { throw "zip entry name not decoded as UTF-8: $($e.FullName)" }
    }
    Write-Host "zip entry names: $($cn.Count) non-ASCII entries decode as UTF-8 OK"
  } finally { $zf.Dispose() }
  Write-Host ("zip: {0}  ({1} MB)" -f $zipPath, [math]::Round((Get-Item $zipPath).Length / 1MB))
}

# ------------------------------------------------------------------ 7) exe
if (-not $SkipExe) {
  # 版本号必须与 RimeVMenu.iss 里的 #define 一致（inno 不吃命令行引号里的字符串表达式）
  $issPath = Join-Path $Root 'packaging\RimeVMenu.iss'
  $issText = Get-Content $issPath -Raw
  if ($issText -notmatch ('#define MyAppVersion "' + [regex]::Escape($Version) + '"')) {
    throw "version mismatch: build script $Version vs packaging\RimeVMenu.iss (edit the #define there)"
  }
  $iscc = Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'
  if (-not (Test-Path $iscc)) { $iscc = 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe' }
  if (-not (Test-Path $iscc)) { throw 'ISCC.exe not found (install Inno Setup 6)' }
  & $iscc $issPath
  if ($LASTEXITCODE -ne 0) { throw "ISCC failed: $LASTEXITCODE" }
  $exePath = Join-Path $Out "RimeVMenu-Setup-$Version.exe"
  if (-not (Test-Path $exePath)) { throw "installer not produced: $exePath" }
  Write-Host ("exe: {0}  ({1} MB)" -f $exePath, [math]::Round((Get-Item $exePath).Length / 1MB))
}

# ------------------------------------------------------------------ 8) 摘要
Write-Host ''
Write-Host '== artifacts =='
Get-ChildItem $Out -File | ForEach-Object {
  $h = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
  "{0}  {1} MB  sha256={2}" -f $_.Name, [math]::Round($_.Length / 1MB), $h.Substring(0, 16)
}
