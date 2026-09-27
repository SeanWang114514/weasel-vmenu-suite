# build-extra-dicts.ps1 - build 4 new dict tables for rime-ice.
# ASCII-only source on purpose (PS 5.1 parses BOM-less .ps1 as ANSI).
# Usage:
#   powershell -File build-extra-dicts.ps1 -RimeDir D:\rime-sandbox -Staging "D:\VibeCoding\<CJK dir>\_dict-staging"
param(
  [Parameter(Mandatory = $true)][string]$RimeDir,
  [Parameter(Mandatory = $true)][string]$Staging,
  [Parameter(Mandatory = $true)][string]$TsMap
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$utf8 = New-Object Text.UTF8Encoding $false

function Read-DictData([string]$path) {
  $list = New-Object System.Collections.Generic.List[string]
  $inData = $false
  foreach ($line in [IO.File]::ReadLines($path)) {
    if (-not $inData) {
      if ($line.TrimEnd() -eq '...') { $inData = $true }
      continue
    }
    if ($line -eq '' -or $line[0] -eq '#') { continue }
    $list.Add($line.TrimEnd())
  }
  return $list.ToArray()
}

function Write-DictFile([string]$path, [string]$name, [string]$version, [string[]]$body) {
  $sb = New-Object Text.StringBuilder
  [void]$sb.AppendLine('# Rime dictionary')
  [void]$sb.AppendLine('# encoding: utf-8')
  [void]$sb.AppendLine('---')
  [void]$sb.AppendLine("name: $name")
  [void]$sb.AppendLine("version: `"$version`"")
  [void]$sb.AppendLine('sort: by_weight')
  [void]$sb.AppendLine('...')
  foreach ($l in $body) { [void]$sb.AppendLine($l) }
  [IO.File]::WriteAllText($path, $sb.ToString(), $utf8)
}

$ver = '2026-09-25'
$outDir = Join-Path $RimeDir 'cn_dicts'
if (-not (Test-Path $outDir)) { throw "missing cn_dicts in $RimeDir" }

# ---------------------------------------------------------------- pass 1:
# existing texts (for cross-dict dedupe) + set of chars that have a
# single-syllable entry somewhere (those are the only chars librime's
# ScriptEncoder can encode for codeless entries).
$existing = New-Object 'System.Collections.Generic.HashSet[string]'
$encodable = New-Object 'System.Collections.Generic.HashSet[string]'
$srcFiles = @('mydict', '8105', 'base', 'ext', 'tencent', 'others') |
  ForEach-Object { Join-Path $outDir "$_.dict.yaml" }
$srcFiles += (Join-Path $RimeDir 'rime_ice.dict.yaml')
foreach ($f in $srcFiles) {
  if (-not (Test-Path $f)) { throw "missing source dict: $f" }
  $inData = $false
  foreach ($line in [IO.File]::ReadLines($f)) {
    if (-not $inData) { if ($line.TrimEnd() -eq '...') { $inData = $true }; continue }
    if ($line -eq '' -or $line[0] -eq '#') { continue }
    $p = $line.TrimEnd() -split "`t"
    $text = $p[0]
    if ($text -eq '') { continue }
    [void]$existing.Add($text)
    if ($p.Count -ge 2 -and $p[1] -ne '' -and $p[1].IndexOf(' ') -lt 0 -and $text.Length -eq 1) {
      [void]$encodable.Add($text)
    }
  }
}
"existing texts : {0:N0}" -f $existing.Count
"encodable chars: {0:N0}" -f $encodable.Count

$newTexts = New-Object 'System.Collections.Generic.HashSet[string]'

# ---------------------------------------------------------------- sogouw_ext
# novel internet words only; log-rescale raw corpus weights into [100,15000]
# so buzzwords do not outrank core vocabulary (base p50=553, p90=16155).
$k = 0.27480
$sogPath = Join-Path $Staging 'sogouw.dict.yaml'
if (-not (Test-Path $sogPath)) { throw "missing $sogPath" }
$sog = New-Object System.Collections.Generic.List[string]
$sogSeen = New-Object 'System.Collections.Generic.HashSet[string]'
$sogTotal = 0; $sogDup = 0; $sogW = New-Object System.Collections.Generic.List[int]
foreach ($line in (Read-DictData $sogPath)) {
  $sogTotal++
  $p = $line -split "`t"
  if ($p.Count -lt 2) { continue }
  $text = $p[0].Trim(); $code = $p[1].Trim()
  if ($text -eq '' -or $code -eq '') { continue }
  if ($existing.Contains($text) -or $newTexts.Contains($text)) { $sogDup++; continue }
  $key = "$text|$code"
  if (-not $sogSeen.Add($key)) { continue }
  $w = 1.0
  if ($p.Count -ge 3) { $null = [double]::TryParse($p[2], [ref]$w) }
  if ($w -lt 1) { $w = 1 }
  $w2 = [int][Math]::Round(100.0 * [Math]::Pow($w, $k))
  if ($w2 -lt 100) { $w2 = 100 }
  if ($w2 -gt 15000) { $w2 = 15000 }
  $sogW.Add($w2)
  [void]$newTexts.Add($text)
  $sog.Add("$text`t$code`t$w2")
}
Write-DictFile (Join-Path $outDir 'sogouw_ext.dict.yaml') 'sogouw_ext' $ver $sog.ToArray()
$sogWSorted = $sogW.ToArray(); [Array]::Sort($sogWSorted)
$sogP50 = $sogWSorted[[int]($sogWSorted.Count / 2)]
"sogouw_ext      : total={0} kept={1} dup={2} rescaled-w[min={3} p50={4} max={5}]" -f `
  $sogTotal, $sog.Count, $sogDup, $sogWSorted[0], $sogP50, $sogWSorted[$sogWSorted.Count - 1]

# ---------------------------------------------------------------- wenxue
# idiom + poetry + classical, codeless -> librime auto-encode with absolute
# weight; strip punctuation; require every char to be encodable; <=32 chars
# (ScriptEncoder hard limit).
$punctCodes = @(0xFF0C,0x3002,0x3001,0xFF1B,0xFF1A,0xFF1F,0xFF01,0x2026,0x2014,0x2013,
  0x201C,0x201D,0x2018,0x2019,0x300A,0x300B,0x3008,0x3009,0xFF08,0xFF09,0x300C,0x300D,
  0x300E,0x300F,0x3010,0x3011,0xFF3B,0xFF3D,0xFF5B,0xFF5D,0xFF0E,0x00B7,0x30FB,0xFF5E,
  0x0020,0x0009,0x3000,0x2002,0x2003,0x200B,0xFEFF,0x00A0,0x002C,0x002E,0x003B,0x003A,
  0x0021,0x003F,0x002D,0x0027,0x0022,0x0028,0x0029,0x005B,0x005D,0x007B,0x007D)
$punct = -join ($punctCodes | ForEach-Object { [char]$_ })

# trad -> simp char map (OpenCC TSCharacters, first value only) so that
# traditional-heavy poetry/classical lines become typeable in simplified.
$rawTs = [IO.File]::ReadAllLines($TsMap)
$t2s = @{}
foreach ($l in $rawTs) {
  if ($l -eq '' -or $l[0] -eq '#') { continue }
  $kv = $l -split "`t"
  if ($kv.Count -lt 2) { continue }
  $vals = ($kv[1] -split ' ') | Where-Object { $_ -ne '' }
  if ($vals.Count -gt 0 -and -not $t2s.ContainsKey($kv[0])) { $t2s[$kv[0]] = $vals[0] }
}
"t2s map         : {0:N0} chars" -f $t2s.Count

$wen = New-Object System.Collections.Generic.List[string]
$wenStats = @()
foreach ($src in @(
    @{ f = 'luna_pinyin.idiom.dict.yaml'; w = 3000; tag = 'idiom' },
    @{ f = 'luna_pinyin.poetry.dict.yaml'; w = 1500; tag = 'poetry' },
    @{ f = 'luna_pinyin.classical.dict.yaml'; w = 1500; tag = 'classical' })) {
  $path = Join-Path $Staging $src.f
  if (-not (Test-Path $path)) { throw "missing $path" }
  $total = 0; $dup = 0; $unenc = 0; $long = 0; $kept = 0
  $seen = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($line in (Read-DictData $path)) {
    $total++
    $text = ($line -split "`t")[0]
    # trad -> simp (char-level, approximate but good enough for input phrases)
    $sb0 = New-Object Text.StringBuilder
    foreach ($c in $text.ToCharArray()) {
      $sc = [string]$c
      if ($t2s.ContainsKey($sc)) { [void]$sb0.Append($t2s[$sc]) } else { [void]$sb0.Append($sc) }
    }
    $text = $sb0.ToString()
    # strip punctuation / whitespace
    $sb2 = New-Object Text.StringBuilder
    foreach ($c in $text.ToCharArray()) { if ($punct.IndexOf([string]$c) -lt 0) { [void]$sb2.Append($c) } }
    $text = $sb2.ToString().Trim()
    if ($text -eq '') { continue }
    if ($text.Length -gt 32) { $long++; continue }
    if ($existing.Contains($text) -or $newTexts.Contains($text)) { $dup++; continue }
    if (-not $seen.Add($text)) { continue }
    $ok = $true
    foreach ($c in $text.ToCharArray()) { if (-not $encodable.Contains([string]$c)) { $ok = $false; break } }
    if (-not $ok) { $unenc++; continue }
    [void]$newTexts.Add($text)
    $wen.Add("$text`t`t$($src.w)")
    $kept++
  }
  $wenStats += "{0}: total={1} kept={2} dup={3} unencodable={4} too_long={5}" -f $src.tag, $total, $kept, $dup, $unenc, $long
}
Write-DictFile (Join-Path $outDir 'wenxue.dict.yaml') 'wenxue' $ver $wen.ToArray()
foreach ($s in $wenStats) { "wenxue $s" }

# ---------------------------------------------------------------- kaomoji
$kae = New-Object System.Collections.Generic.List[string]
$kaeSeen = New-Object 'System.Collections.Generic.HashSet[string]'
$kaeTotal = 0
foreach ($f in @('kaomoji_pinyin.dict.yaml', 'kaomoji_kmj.dict.yaml')) {
  $path = Join-Path (Join-Path $Staging 'kaomoji') "output\$f"
  if (-not (Test-Path $path)) { throw "missing $path" }
  foreach ($line in (Read-DictData $path)) {
    $kaeTotal++
    $p = $line -split "`t"
    if ($p.Count -lt 2) { continue }
    $text = $p[0]; $code = $p[1].Trim()
    if ($text -eq '' -or $code -eq '') { continue }
    $w = '0'
    if ($p.Count -ge 3 -and $p[2].Trim() -ne '') { $w = $p[2].Trim() }
    if (-not $kaeSeen.Add("$text|$code")) { continue }
    [void]$newTexts.Add($text)
    $kae.Add("$text`t$code`t$w")
  }
}
Write-DictFile (Join-Path $outDir 'kaomoji.dict.yaml') 'kaomoji' $ver $kae.ToArray()
"kaomoji         : source={0} kept={1}" -f $kaeTotal, $kae.Count

# ---------------------------------------------------------------- symbols_ext
# core = yangshann symbols head (marks / circled+roman numerals / math /
# full Greek), plus a curated symbol tail, plus authored strict-ASCII
# operators and currency symbols.
$symPath = Join-Path $Staging 'symbols.dict.yaml'
if (-not (Test-Path $symPath)) { throw "missing $symPath" }
$raw = [IO.File]::ReadAllLines($symPath)
$omegaIdx = -1
for ($i = 0; $i -lt $raw.Length; $i++) {
  if ($raw[$i] -ceq ([string][char]0x03A9 + "`t" + 'omega')) { $omegaIdx = $i; break }
}
if ($omegaIdx -lt 0) { throw 'omega line not found in symbols.dict.yaml' }
$dataStart = -1
for ($i = 0; $i -lt $raw.Length; $i++) { if ($raw[$i].TrimEnd() -eq '...') { $dataStart = $i + 1; break } }
if ($dataStart -lt 0) { throw 'no data section in symbols.dict.yaml' }
$sym = New-Object System.Collections.Generic.List[string]
$symSeen = New-Object 'System.Collections.Generic.HashSet[string]'
function Add-Sym([string]$line) {
  $p = $line -split "`t"
  if ($p.Count -lt 2) { return }
  $t = $p[0]; $c = $p[1].Trim()
  if ($t -eq '' -or $c -eq '') { return }
  if ($script:symSeen.Add("$t|$c")) { $script:sym.Add($line) }
}
for ($i = $dataStart; $i -le $omegaIdx; $i++) { if ($raw[$i].TrimEnd() -ne '') { Add-Sym $raw[$i].TrimEnd() } }
# curated tail: pure symbols only (arrows, stars, legal, taiji, gender,
# infinity, envelope, check/cross); emoji pictographs are intentionally out.
$tailKeep = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($cp in @(0x2B06,0x2B07,0x2B05,0x27A1,0x2196,0x2197,0x2198,0x2199,
    0x2605,0x2606,0x2733,0x2747,0x2709,0x00A9,0x00AE,0x221E,0x262F,0x2642,0x2641,
    0x2714,0x2716)) { [void]$tailKeep.Add([string][char]$cp) }
for ($i = $omegaIdx + 1; $i -lt $raw.Length; $i++) {
  $line = $raw[$i].TrimEnd()
  if ($line -eq '' -or $line[0] -eq '#') { continue }
  $t = ($line -split "`t")[0]
  if ($tailKeep.Contains($t)) { Add-Sym $line }
}
# authored block: strict ASCII / math / currency
$authored = @(
  @('+', 'jia', 1300000), @('+', 'jia hao', 6000), @('+', 'plus', 0),
  @('-', 'jian', 130000), @('-', 'jian hao', 3600), @('-', 'minus', 0),
  @('=', 'deng yu', 267000), @('=', 'deng hao', 11000), @('=', 'equal', 0),
  @([string][char]0x00D7, 'cheng hao', 100000), @([string][char]0x00D7, 'times', 0),
  @([string][char]0x00F7, 'chu hao', 13000), @([string][char]0x00F7, 'divide', 0),
  @('<', 'xiao yu', 255000), @('>', 'da yu', 359000),
  @([string][char]0x2260, 'bu deng yu', 0),
  @([string][char]0x2248, 'yue deng yu', 0),
  @([string][char]0x00B1, 'zheng fu hao', 0),
  @([string][char]0x2264, 'xiao yu deng yu', 0),
  @([string][char]0x2265, 'da yu deng yu', 0),
  @('%', 'bai fen hao', 1600),
  @([string][char]0x2030, 'qian fen hao', 0),
  @([string][char]0x221A, 'gen hao', 0),
  @([string][char]0x00A5, 'ren min bi', 450000), @([string][char]0x00A5, 'rmb', 0), @([string][char]0x00A5, 'yuan', 0),
  @('$', 'mei yuan', 450000), @('$', 'dollar', 0),
  @([string][char]0x20AC, 'ou yuan', 200000), @([string][char]0x20AC, 'euro', 0),
  @([string][char]0x00A3, 'ying bang', 100000), @([string][char]0x00A3, 'pound', 0),
  @([string][char]0x00A2, 'cent', 0), @([string][char]0x00A2, 'me fen', 0),
  @([string][char]0x20A9, 'han yuan', 0),
  @([string][char]0x03B1, 'alfa', 0),
  @([string][char]0x03C8, 'psi', 0), @([string][char]0x03A8, 'psi', 0)
)
foreach ($a in $authored) { Add-Sym ("$($a[0])`t$($a[1])`t$($a[2])") }
Write-DictFile (Join-Path $outDir 'symbols_ext.dict.yaml') 'symbols_ext' $ver $sym.ToArray()
"symbols_ext     : kept={0} (core={1} tail+authored={2})" -f $sym.Count, ($omegaIdx - $dataStart + 1), ($sym.Count - ($omegaIdx - $dataStart + 1))

# ---------------------------------------------------------------- sanity
foreach ($n in @('sogouw_ext', 'wenxue', 'kaomoji', 'symbols_ext')) {
  $f = Join-Path $outDir "$n.dict.yaml"
  $lines = [IO.File]::ReadAllLines($f)
  "{0}: {1} lines, {2:N0} bytes" -f $n, $lines.Length, (Get-Item $f).Length
}
'DONE'
