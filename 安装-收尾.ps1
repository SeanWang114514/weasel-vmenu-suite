# 安装-收尾.ps1 —— zip / exe 两种安装方式共用的收尾步骤
#
# 本脚本必须放在 Rime 用户目录里（安装.bat 会把整包复制过去，exe 安装器直接
# 装进去），以自身所在目录为根：
#   1) 定位小狼毫安装目录（没装则引导运行随包附带的安装器）
#   2) 开机自启（HKCU\...\Run\RimeVMenuWatcher -> "VMenu.exe" start）
#   3) 托盘菜单「输入法设置」入口（vmenu-tray-setup.ps1：改字 + 编译部署器代理）
#   4) 后台服务 + 语音悬浮球（clipboard-sync.bat：VMenu stop/start + VoiceOverlay）
#   5) 重新部署（WeaselDeployer /deploy，等待完成）+ patch-build-schema 兜底
#   6) 重启 WeaselServer 让新方案 / lua 生效
#
# 测试开关：环境变量 RIME_INSTALL_SKIP_POST=1 时只打印计划、不执行 2~6
# （打包脚本用它在开发机上验证安装流程而不改动真实系统状态）。
#
# 本文件必须是 UTF-8 带 BOM（PowerShell 5.1 需要）。

$ErrorActionPreference = 'Continue'
$RimeDir = $PSScriptRoot
if (-not $RimeDir) { $RimeDir = Split-Path -Parent $MyInvocation.MyCommand.Path }

Write-Host '=== Rime VMenu post-install ==='
Write-Host "Rime dir : $RimeDir"

if ($env:RIME_INSTALL_SKIP_POST) {
    Write-Host 'RIME_INSTALL_SKIP_POST is set - steps 2..6 skipped (copy-only test).'
    exit 0
}

# ---------------------------------------------------------------- 1. Weasel
function Get-WeaselDir {
    $dirs = @()
    foreach ($b in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($b) {
            $dirs += @(Get-ChildItem -Path (Join-Path $b 'Rime') -Directory `
                -Filter 'weasel-*' -ErrorAction SilentlyContinue)
        }
    }
    if ($dirs.Count -gt 0) {
        return ($dirs | Sort-Object Name -Descending | Select-Object -First 1).FullName
    }
    $p = Get-Process WeaselServer -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p -and $p.Path) { return Split-Path -Parent $p.Path }
    return $null
}

$weasel = Get-WeaselDir
if (-not $weasel) {
    $inst = Get-ChildItem -Path $RimeDir -Filter 'weasel*-installer*.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($inst) {
        Write-Host "Weasel not found - launching bundled installer: $($inst.Name)"
        Start-Process $inst.FullName
        Write-Host 'Install 小狼毫 first, then run 安装.bat again.'
    } else {
        Write-Host 'Weasel (小狼毫) not found. Install it from https://rime.im first.'
    }
    exit 1
}
Write-Host "Weasel   : $weasel"

# ------------------------------------------------------------- 2. autostart
try {
    $run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if (-not (Test-Path $run)) { New-Item -Path $run -Force | Out-Null }
    $cmd = '"{0}\VMenu.exe" start' -f $RimeDir
    Set-ItemProperty -Path $run -Name 'RimeVMenuWatcher' -Value $cmd -Type String
    Write-Host 'Autostart: RimeVMenuWatcher registered (VMenu.exe start)'
} catch {
    Write-Host "Autostart FAILED: $($_.Exception.Message)"
}

# --------------------------------------------------- 3. tray menu entry
try {
    $tray = Join-Path $RimeDir 'vmenu-tray-setup.ps1'
    if (Test-Path $tray) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $tray
        if ($LASTEXITCODE -ne 0) { Write-Host 'Tray entry: install reported an error (non-fatal).' }
        else { Write-Host 'Tray entry: done (输入法设置 in the tray menu).' }
    } else {
        Write-Host 'Tray entry: vmenu-tray-setup.ps1 missing - skipped.'
    }
} catch {
    Write-Host "Tray entry FAILED (non-fatal): $($_.Exception.Message)"
}

# ------------------------------------- 4. services + voice overlay
try {
    $sync = Join-Path $RimeDir 'clipboard-sync.bat'
    if (Test-Path $sync) {
        Write-Host 'Services  : starting VMenu (watch/sync/window) + voice overlay ...'
        & cmd /c "`"$sync`""
    } else {
        $vm = Join-Path $RimeDir 'VMenu.exe'
        if (Test-Path $vm) { & $vm stop; Start-Sleep -Seconds 1; & $vm start }
    }
} catch {
    Write-Host "Services FAILED (non-fatal): $($_.Exception.Message)"
}

# --------------------------------------------------------------- 5. deploy
try {
    $deployer = Join-Path $weasel 'WeaselDeployer.exe'
    if (Test-Path $deployer) {
        Write-Host 'Deploy    : running WeaselDeployer /deploy (first run compiles schemas) ...'
        Start-Process -FilePath $deployer -ArgumentList '/deploy' -WorkingDirectory $weasel | Out-Null
        # the tray proxy returns instantly and forwards to WeaselDeployer.real.exe,
        # so watch both names; cap the wait at 3 minutes.
        $deadline = (Get-Date).AddSeconds(180)
        while ((Get-Date) -lt $deadline) {
            $busy = Get-Process WeaselDeployer, WeaselDeployer.real -ErrorAction SilentlyContinue
            if (-not $busy) { break }
            Start-Sleep -Milliseconds 500
        }
        Write-Host 'Deploy    : finished (or timed out after 180s).'
    }

    # patch compiled schema (repairs machines where deploy skips *.custom.yaml)
    $buildSchema = Join-Path $RimeDir 'build\rime_ice.schema.yaml'
    $patch = Join-Path $RimeDir 'patch-build-schema.ps1'
    if ((Test-Path $buildSchema) -and (Test-Path $patch)) {
        Write-Host 'Schema    : applying custom.yaml deltas to build\rime_ice.schema.yaml ...'
        & powershell -NoProfile -ExecutionPolicy Bypass -File $patch -RimeDir $RimeDir
        if ($LASTEXITCODE -ne 0) { Write-Host 'Schema    : patch reported an error (non-fatal).' }
    }
} catch {
    Write-Host "Deploy FAILED (non-fatal): $($_.Exception.Message)"
}

# --------------------------------------------------- 6. restart WeaselServer
try {
    Get-Process WeaselServer -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1
    $ws = Join-Path $weasel 'WeaselServer.exe'
    if (Test-Path $ws) {
        Start-Process -FilePath $ws -WorkingDirectory $weasel
        Start-Sleep -Seconds 3
    }
    if (Get-Process WeaselServer -ErrorAction SilentlyContinue) {
        Write-Host 'WeaselServer: restarted.'
    } else {
        Write-Host 'WeaselServer: did not come back up - start it from the tray.'
    }
} catch {
    Write-Host "WeaselServer restart FAILED: $($_.Exception.Message)"
}

Write-Host ''
Write-Host '=== All done ==='
Write-Host 'Typing tips: press v to open the feature menu, v then 1 for the settings window.'
Write-Host 'Voice input : hold Ctrl+Win to talk (hotkey editable in the settings window).'
exit 0
