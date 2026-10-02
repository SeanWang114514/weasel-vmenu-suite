# build-release.ps1 —— 组装发布树 -> 打 zip（rime-install 兼容）-> 编译 exe 直装包
#
# 用法（在仓库任意位置）：
#   powershell -File packaging\build-release.ps1                       # CPU 版（完整，含模型）
#   powershell -File packaging\build-release.ps1 -Gpu                  # GPU 版（含 CUDA，+600MB）
#   powershell -File packaging\build-release.ps1 -NoModels             # 跳过 971MB 模型拷贝（冒烟）
#   powershell -File packaging\build-release.ps1 -SkipExe              # 只打 zip
#   powershell -File packaging\build-release.ps1 -SkipZip              # 只编 exe
#   powershell -File packaging\build-release.ps1 -NoModels -SkipZip -Gpu -CudaSrc <dir>
#
# 两个版本（CPU / GPU）：
#   CPU 版：不带 CUDA 运行时，约 1.1 GB。任何机器都能装，语音走 CPU（整机 ~26%）。
#   GPU 版：带 CUDA 运行时（cuBLAS 等，+600MB），约 1.75 GB。
#           N 卡机器上自动用 GPU（~11% CPU、约 2.3 倍速），没 N 卡时自动回落 CPU。
#   功能完全一致，只是识别速度和 CPU 占用不同 —— 见设置窗口「语音识别设备」卡片。
#
# 产物：
#   out\RimeVMenu-<ver>.zip             zip 根目录 = RimeVMenu-<ver>\（rime-install.bat
#                                       解包规则要求根文件夹名 = zip 主文件名）
#   out\RimeVMenu-Setup-<ver>.exe       Inno Setup 直装包
#   GPU 版把 <ver> 换成 <ver>-GPU（文件名与 stage 目录名同步带 -GPU 后缀），
#   这样两个包可以共存、Repack 时不会互相覆盖。
#
# 发布树 stage\RimeVMenu-<ver>[-GPU]\ 的组成：
#   1) Rime 配置（来自实时 Rime 用户目录，剔除 build/ userdb/ 备份/日志，剪贴板缓存清空）
#   2) 外挂 exe 与脚本（VMenu/Voice* 从 dist\ 优先取，其余来自仓库根）
#   3) llama.cpp 运行时（CPU 版剔除 CUDA/RPC；GPU 版整组带上 CUDA）
#   4) Qwen3-ASR 两个模型（-NoModels 跳过）
#   5) 小狼毫安装器 + README-必读.md
param(
  [string]$Version = '1.1.0',
  [string]$RimeSrc = 'D:\rime-sandbox',
  [string]$LlamaSrc = 'D:\王修翊\llama.cpp',
  [string]$CudaSrc = '',
  [switch]$Gpu,
  [switch]$NoModels,
  [switch]$SkipZip,
  [switch]$SkipExe
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot          # packaging\.. = 仓库根
# GPU 版：文件名/版本串带 -GPU 后缀，与 CPU 版并存不冲突
$VerTag = if ($Gpu) { "$Version-GPU" } else { $Version }
$CPU_VER = $Version

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

$Name  = "RimeVMenu-$VerTag"
$Stage = Join-Path $Root "stage\$Name"
$Out   = Join-Path $Root 'out'
Write-Host "== build-release: $Name ($(if ($Gpu) { 'GPU/CUDA' } else { 'CPU' })) =="
Write-Host "Rime config source: $RimeSrc"
Write-Host "Llama runtime source: $LlamaSrc"
if ($Gpu -and $CudaSrc) { Write-Host "CUDA runtime source: $CudaSrc" }

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
# ★ 关键：第 1 步会把实时 Rime 目录**整目录**拷过来，而开发机的 rime-sandbox\llama.cpp
#   里可能残留着测试用的 CUDA dll（为了验证 GPU 路径临时拷进去的）。
#   第 3 步只做 Copy-Item -Force、从不删除，于是那些 dll 会一路混进「CPU 版」包里
#   —— 实测漏进 627MB，zip 从 1.1GB 涨到 1.6GB，而且普通用户白下。
#   所以进第 3 步前先把目标目录整个清空，保证内容是第 3 步**唯一**决定的。
if (Test-Path $llamaDst) { Remove-Item $llamaDst -Recurse -Force }
New-Item -ItemType Directory -Path $llamaDst -Force | Out-Null

# GPU 版：带上 CUDA 后端（>600MB）。llama.cpp 的 CUDA 后端强依赖 cuBLAS，
# 缺任何一个 dll 都不是「降级」而是**启动直接失败**，所以整组一起带。
# CPU 版剔除这组 dll：无 N 卡的用户不必白下 600MB，语音走 CPU 一样能用。
$cudaPattern = '^(cublas|cudart|ggml-cuda|ggml-rpc)'
if ($Gpu) {
  $cudaSrc = $LlamaSrc
  if (-not (Test-Path (Join-Path $cudaSrc 'ggml-cuda.dll'))) {
    # 允许显式指定 CUDA 运行时来源（例如本机另一个 CUDA 构建目录）
    if ($CudaSrc -and (Test-Path (Join-Path $CudaSrc 'ggml-cuda.dll'))) {
      $cudaSrc = $CudaSrc
    } else {
      throw ("GPU 版需要 CUDA 运行时，但 $LlamaSrc 里没有 ggml-cuda.dll。`n" +
             "请用 -CudaSrc <目录> 指定一个含 cublas/cudart/ggml-cuda 的 llama.cpp 构建，`n" +
             "或改装官方 CUDA 构建的 llama-server.exe + dll 到该目录。")
    }
  }
  Get-ChildItem $LlamaSrc -File | Where-Object {
    ($_.Name -eq 'llama-server.exe' -or $_.Name -eq 'LICENSE-LLVM-OpenMP' -or $_.Extension -eq '.dll')
  } | ForEach-Object { Copy-Item $_.FullName -Destination $llamaDst -Force }
  # CUDA dll 可能不在 $LlamaSrc（用 -CudaSrc 指定）：补齐缺失的那几个
  if ($cudaSrc -ne $LlamaSrc) {
    Get-ChildItem $cudaSrc -File | Where-Object {
      $_.Extension -eq '.dll' -and $_.Name -match $cudaPattern
    } | ForEach-Object { Copy-Item $_.FullName -Destination $llamaDst -Force }
  }
} else {
  Get-ChildItem $LlamaSrc -File | Where-Object {
    ($_.Name -eq 'llama-server.exe' -or $_.Name -eq 'LICENSE-LLVM-OpenMP' -or $_.Extension -eq '.dll') -and
    $_.Name -notmatch $cudaPattern
  } | ForEach-Object { Copy-Item $_.FullName -Destination $llamaDst -Force }
}
$llamaSrv = Join-Path $llamaDst 'llama-server.exe'
if (-not (Test-Path $llamaSrv)) { throw "llama-server.exe failed to stage" }
# 两个方向都要断言，缺了任一个都会静默出错：
#   GPU 版缺 CUDA dll -> llama-server 起来就崩（不是优雅降级，是启动失败）
#   CPU 版混进 CUDA dll -> 白胖 627MB（回归过一次，见上面第 3 步的注释）
if ($Gpu) {
  foreach ($n in @('ggml-cuda.dll', 'cublas64_13.dll', 'cublasLt64_13.dll', 'cudart64_13.dll')) {
    if (-not (Test-Path (Join-Path $llamaDst $n))) {
      throw "GPU 版缺少 CUDA 运行时: $n"
    }
  }
} else {
  $leak = Get-ChildItem $llamaDst -File | Where-Object { $_.Name -match $cudaPattern }
  if ($leak) {
    throw ("CPU 版混入了 CUDA 运行时（zip 会平白胖 600MB+）：`n  " +
           (($leak | Select-Object -ExpandProperty Name) -join "`n  "))
  }
}
$llamaMB = [int]((Get-ChildItem $llamaDst | Measure-Object Length -Sum).Sum / 1MB)
Write-Host ("llama runtime staged ({0} MB, {1})" -f $llamaMB, $(if ($Gpu) { 'CUDA' } else { 'CPU-only' }))

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
# ★ 回归断言：语音脚本必须是带 GPU 支持的版本。
#   第 1 步是「整目录拷实时 Rime 用户目录」，而实时目录里的 voice-*.py 是**开发时手动
#   同步过去的副本**。一旦忘了同步，包里就会装出「exe 有 GPU、.py 没有」的混合状态：
#   启动器优先用 exe 所以平时看不出问题，但 语音输入.bat / 语音输入-悬浮球.bat 的
#   python 回落分支会静默退回 CPU —— 实测漏过一次（.py 落后 master 155 行）。
#   exe 是二进制没法从源码断言，所以这里只查 .py，并要求它认得 asr_device。
foreach ($py in @('voice-overlay.py', 'voice-input.py')) {
  $p = Join-Path $Stage $py
  if (-not (Test-Path $p)) { throw "stage verification FAILED: missing $py" }
  $src = Get-Content $p -Raw
  foreach ($needle in @('asr_device', 'gpu_available', 'ngl')) {
    if ($src -notmatch [regex]::Escape($needle)) {
      throw ("$py 是旧版（不含 '$needle'），会装出「exe 支持 GPU、py 回落 CPU」的混合包。`n" +
             "  修法：把工作区 master 的 $py 同步到 Rime 源目录（$RimeSrc）后重新构建。")
    }
  }
}

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
  # 版本号必须与 RimeVMenu.iss 里的 #define 一致。
  # iss 里两个 define 各司其职：
  #   MyVerNum     = 纯数字 a.b.c，VersionInfoVersion 只能用这个（带 -GPU 会被 Inno 拒绝）
  #   MyAppVersion = 显示 / 输出文件名，GPU 版是 "1.1.0-GPU"
  # ★ 早先的做法是「临时改写 iss 再还原」，踩了两个坑：
  #   1) WriteAllText 会把 CRLF 写没、并让 Inno 按 ANSI 解码 —— 中文全变乱码、编译失败；
  #   2) finally 里还原依赖异常路径，一旦中途抛错就留下脏文件。
  #   现在改用 ISCC 的 /D 命令行宏覆盖，**完全不碰 iss**，天然可重入、失败无残留。
  #   注意：/D 的值是 Inno 预处理器表达式，字符串要写成 "..."（带引号），
  #   因此 PowerShell 侧要用 `" 转义把引号带进参数。
  $issPath = Join-Path $Root 'packaging\RimeVMenu.iss'
  $issText = Get-Content $issPath -Raw
  if ($issText -notmatch ('#define MyVerNum\s+"' + [regex]::Escape($CPU_VER) + '"')) {
    throw "version mismatch: build script $CPU_VER vs packaging\RimeVMenu.iss (edit the #define there)"
  }
  $iscc = Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'
  if (-not (Test-Path $iscc)) { $iscc = 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe' }
  if (-not (Test-Path $iscc)) { throw 'ISCC.exe not found (install Inno Setup 6)' }

  $isccArgs = @($issPath)
  if ($Gpu) {
    # ★ 必须满足两个条件才能覆盖成功，缺一个都会静默编出 CPU 版文件名：
    #   1) iss 里那两个 define 得包在 #ifndef 里（见 RimeVMenu.iss 顶部注释）；
    #      不包的话文件里的 #define 永远压过命令行 /D。
    #   2) /D 的值**不能加引号**。写成 /DMyAppVersion="1.1.0-GPU" 时 Inno 会把
    #      引号当成值的一部分，导致 OutputBaseFilename 非法、直接编译失败
    #      （报 "Value of [Setup] section directive OutputBaseFileName is invalid"）。
    $isccArgs += "/DMyAppVersion=$VerTag"
    $isccArgs += "/DMyStageDir=..\stage\RimeVMenu-$VerTag"
    Write-Host "ISCC: MyAppVersion=$VerTag  MyStageDir=..\stage\RimeVMenu-$VerTag"
  }
  & $iscc @isccArgs
  if ($LASTEXITCODE -ne 0) { throw "ISCC failed: $LASTEXITCODE" }
  $exePath = Join-Path $Out "RimeVMenu-Setup-$VerTag.exe"
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
