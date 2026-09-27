# 加词.ps1 — 雾凇拼音个人词库加词脚本
# 用法：双击「加词.bat」，或右键用 PowerShell 运行本文件
# 流程：输入中文词语 → 自动查字表标注拼音 → 你确认 → 追加到个人词库 → 一键重新部署
#Requires -Version 5.1
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

# Rime 用户目录解析：环境变量覆盖 -> 注册表 RimeUserDir -> %APPDATA%\Rime -> 旧开发目录
$rimeDir = $env:RIME_DIR
if (-not $rimeDir) {
    try {
        $reg = Get-ItemProperty -Path 'HKCU:\Software\Rime\Weasel' -Name RimeUserDir -ErrorAction Stop
        if ($reg.RimeUserDir) { $rimeDir = $reg.RimeUserDir }
    } catch {}
}
if (-not $rimeDir) { $rimeDir = Join-Path $env:APPDATA 'Rime' }
if (-not (Test-Path -LiteralPath $rimeDir) -and (Test-Path -LiteralPath 'D:\rime-sandbox')) { $rimeDir = 'D:\rime-sandbox' }
$charDict = Join-Path $rimeDir 'cn_dicts\8105.dict.yaml'
$mydict   = Join-Path $rimeDir 'cn_dicts\mydict.dict.yaml'

# 从运行中的 WeaselServer 定位部署程序（不硬编码安装路径）
$deployer = $null
$proc = Get-Process WeaselServer -ErrorAction SilentlyContinue | Select-Object -First 1
if ($proc -and $proc.Path) {
    $cand = Join-Path (Split-Path $proc.Path) 'WeaselDeployer.exe'
    if (Test-Path $cand) { $deployer = $cand }
}

# ---------- 单字拼音表（从 8105 字表加载，取权重最高的读音） ----------
$script:charMap = @{}
function Import-CharMap {
    if ($script:charMap.Count -gt 0) { return }
    Get-Content $charDict -Encoding UTF8 | ForEach-Object {
        if ($_ -match '^([^\t]+?)\t([a-züv ]+?)(?:\t(\d+))?\s*$') {
            $ch = $Matches[1]; $py = $Matches[2].Trim()
            if ($ch.Length -ne 1 -or $py -eq '') { return }
            $w = if ($Matches[3]) { [long]$Matches[3] } else { 1 }
            if (-not $script:charMap.ContainsKey($ch)) { $script:charMap[$ch] = @() }
            $script:charMap[$ch] += [pscustomobject]@{ py = $py; w = $w }
        }
    }
}

# ---------- 给词语自动标注拼音 ----------
function Get-AutoPinyin([string]$word) {
    Import-CharMap
    $parts = @(); $unknown = @()
    foreach ($c in $word.GetEnumerator()) {
        $s = [string]$c
        if ($s -match '^[A-Za-z0-9]$') { $parts += $s.ToLower(); continue }  # 英文数字直接参与造词
        if ($script:charMap.ContainsKey($s)) {
            $parts += ($script:charMap[$s] | Sort-Object w -Descending | Select-Object -First 1).py
        } else {
            $unknown += $s; $parts += '?'
        }
    }
    return @{ pinyin = ($parts -join ' '); unknown = $unknown }
}

# ---------- 无 BOM UTF-8 追加一行 ----------
function Add-DictLine([string]$word, [string]$pinyin, [long]$weight) {
    $utf8NoBom = New-Object Text.UTF8Encoding $false
    [IO.File]::AppendAllText($mydict, "$word`t$pinyin`t$weight`r`n", $utf8NoBom)
}

function Main {
    Import-CharMap
    Write-Host "已载入 $($script:charMap.Count) 个单字注音" -ForegroundColor DarkGray
    Write-Host "个人词库：$mydict" -ForegroundColor DarkGray
    Write-Host "输入 q 退出`n" -ForegroundColor DarkGray

    $added = 0
    while ($true) {
        $word = (Read-Host '请输入词语（中文）').Trim()
        if ($word -eq '' ) { continue }
        if ($word -eq 'q' -or $word -eq 'Q') { break }

        # 重复检查
        $dup = Select-String -Path $mydict -Pattern "^$([regex]::Escape($word))`t" -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($dup) {
            Write-Host "  已存在：$($dup.Line)" -ForegroundColor Yellow
            $ow = (Read-Host '  是否仍要追加一条（y/N）').Trim()
            if ($ow -ne 'y' -and $ow -ne 'Y') { continue }
        }

        $r = Get-AutoPinyin $word
        if ($r.unknown.Count -gt 0) {
            Write-Host "  这些字在字表里没找到：$($r.unknown -join '，')，请手动输入完整拼音" -ForegroundColor Yellow
            $pinyin = ''
        } else {
            Write-Host "  自动注音：$($r.pinyin)" -ForegroundColor Cyan
            $pinyin = (Read-Host '  直接回车采用，或手动输入拼音（空格分隔，如 da gong ren）').Trim()
            if ($pinyin -eq '') { $pinyin = $r.pinyin }
        }
        if ($pinyin -eq '') { $pinyin = (Read-Host '  请输入拼音（空格分隔）').Trim() }
        if ($pinyin -notmatch '^[a-züv][a-züv'' ]*$') {
            Write-Host '  拼音格式不对，已跳过（只允许小写字母/空格/分词单引号）' -ForegroundColor Red
            continue
        }

        $wIn = (Read-Host '  权重（回车默认 100000，越大越靠前）').Trim()
        $weight = 100000
        if ($wIn -ne '' ) {
            $tmp = 0
            if ([long]::TryParse($wIn, [ref]$tmp) -and $tmp -gt 0) { $weight = $tmp }
            else { Write-Host '  权重无效，用默认值 100000' -ForegroundColor Yellow }
        }

        Add-DictLine $word $pinyin $weight
        $added++
        Write-Host "  ✔ 已加入：$word`t$pinyin`t$weight" -ForegroundColor Green
        Write-Host "  已保存到：$mydict" -ForegroundColor DarkGray
    }

    Write-Host "`n本次新增 $added 条。" -ForegroundColor Cyan
    if ($added -gt 0) {
        $go = (Read-Host '是否立即重新部署输入法使新词生效（Y/n）').Trim()
        if ($go -eq '' -or $go -eq 'y' -or $go -eq 'Y') {
            if ($deployer) {
                Write-Host '正在启动部署程序…' -ForegroundColor Cyan
                Start-Process $deployer
            } else {
                Write-Host '没找到 WeaselDeployer.exe，请右键任务栏小狼毫图标 →【重新部署】' -ForegroundColor Yellow
            }
        } else {
            Write-Host '记得稍后右键任务栏小狼毫图标 →【重新部署】，新词才会生效' -ForegroundColor Yellow
        }
    }
}

# 被点号引用（. .\加词.ps1）时只加载函数不进入交互，方便测试
if ($MyInvocation.InvocationName -ne '.') { Main }
