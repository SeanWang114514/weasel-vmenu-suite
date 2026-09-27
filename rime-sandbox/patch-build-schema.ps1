param(
  [string]$RimeDir = ''
)
# Resolve the Rime user dir when not passed explicitly:
# env override -> registry RimeUserDir -> %APPDATA%\Rime -> legacy dev dir.
if (-not $RimeDir) { $RimeDir = $env:RIME_DIR }
if (-not $RimeDir) {
  try {
    $reg = Get-ItemProperty -Path 'HKCU:\Software\Rime\Weasel' -Name RimeUserDir -ErrorAction Stop
    if ($reg.RimeUserDir) { $RimeDir = $reg.RimeUserDir }
  } catch {}
}
if (-not $RimeDir) { $RimeDir = Join-Path $env:APPDATA 'Rime' }
if (-not (Test-Path -LiteralPath $RimeDir) -and (Test-Path -LiteralPath 'D:\rime-sandbox')) { $RimeDir = 'D:\rime-sandbox' }
# Weasel 0.17 in this environment never rebuilds build\<schema>.schema.yaml when
# only *.custom.yaml changed: WeaselDeployer /deploy loads the schemas and then
# silently stops, leaving the previously compiled schema in place. This script
# applies exactly the same three deltas the deployer *would* have applied to the
# compiled schema, so the running IME matches rime_ice.custom.yaml again.
#
# Deltas applied to build\rime_ice.schema.yaml:
#   1. engine/translators loses lua_translator@*clipboard and @*favorite
#      (those lua files were merged into lua_menu.lua / vmenu_core.lua)
#   2. recognizer/patterns loses the clipboard / favorite / vmenu entries
#      (they hijack the `punct` tag for v2 and v3, which killed the original
#       v2 = digit-two variants and v3 = digit-three variants behaviour)
#   3. punctuator/symbols/v2 and v3 get their original lists back from
#      symbols_v.yaml (they had been emptied by an older patch)
#   plus __build_info.timestamps/rime_ice.custom is refreshed so the compiled
#   schema is self-consistent with the .custom.yaml it was derived from.
#
# ASCII-only source on purpose: Windows PowerShell 5.1 parses BOM-less UTF-8
# scripts as ANSI, which corrupts quoting when non-ASCII comments are present.

$ErrorActionPreference = 'Stop'

$build = Join-Path $RimeDir 'build\rime_ice.schema.yaml'
$custom = Join-Path $RimeDir 'rime_ice.custom.yaml'
$symbols = Join-Path $RimeDir 'symbols_v.yaml'

foreach ($p in @($build, $custom, $symbols)) {
  if (-not (Test-Path $p)) { throw "missing required file: $p" }
}

Copy-Item $build "$build.prebuild-bak" -Force
$raw = Get-Content $build -Raw -Encoding UTF8
$crlf = $raw.Contains("`r`n")
$nl = if ($crlf) { "`r`n" } else { "`n" }
$lines = New-Object System.Collections.Generic.List[string]
foreach ($l in ($raw -split "`r?`n")) { $lines.Add($l) }
if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }

# ---- 1. pull the original v2 / v3 symbol lists out of symbols_v.yaml ----
$svLines = Get-Content $symbols -Encoding UTF8
$v2 = $null; $v3 = $null
foreach ($l in $svLines) {
  if ($l -match "^  'v2':\s*(\[.*\])\s*$") { $v2 = $Matches[1] }
  if ($l -match "^  'v3':\s*(\[.*\])\s*$") { $v3 = $Matches[1] }
}
if (-not $v2 -or -not $v3) { throw "could not read the v2/v3 symbol lists from $symbols" }

$drop = @(
  '    - "lua_translator@*clipboard"',
  '    - "lua_translator@*favorite"',
  '    clipboard: "^v2$"',
  '    favorite: "^v3.*$"',
  '    vmenu: "^v$"',
  # phrase_first (word-first ordering) supersedes long_word_filter; the custom
  # yaml no longer lists it, so drop it from the compiled schema as well.
  '    - "lua_filter@*long_word_filter"'
)

$epoch = [long]((Get-Date (Get-Item $custom).LastWriteTimeUtc -UFormat %s))
$out = New-Object System.Collections.Generic.List[string]
$changes = New-Object System.Collections.Generic.List[string]
# fuzzy_filter must sit FIRST in engine/filters (it has to read the
# spelling-hints comment before corrector clears it). Insert it right before
# the corrector entry if this build schema does not carry it yet.
$addedFuzzy = $false
foreach ($l in $lines) {
  if ($l -match '^\s+- "?lua_filter@\*fuzzy_filter"?\s*$') { $addedFuzzy = $true; break }
}
# en_gate (中文模式英文候选开关) sits right after reduce_english_filter.
$addedEn = $false
foreach ($l in $lines) {
  if ($l -match '^\s+- "?lua_filter@\*en_gate"?\s*$') { $addedEn = $true; break }
}
# predict_filter (next-candidate bigram prediction) sits right after v_filter,
# before pin_cand_filter, so pins / long words / fav slot 2 stay authoritative.
$addedPred = $false
foreach ($l in $lines) {
  if ($l -match '^\s+- "?lua_filter@\*predict_filter"?\s*$') { $addedPred = $true; break }
}
# phrase_first (word-first ordering) sits between v_filter and predict_filter:
# it reorders the raw candidates, then predict / pin_cand get the last word and
# can still push a favourite to position 1.
$addedPhrase = $false
foreach ($l in $lines) {
  if ($l -match '^\s+- "?lua_filter@\*phrase_first"?\s*$') { $addedPhrase = $true; break }
}
foreach ($l in $lines) {
  if (-not $addedFuzzy -and $l -match '^(\s+)- "?lua_filter@\*corrector"?\s*$') {
    $out.Add("$($Matches[1])- `"lua_filter@*fuzzy_filter`"")
    $changes.Add('added fuzzy_filter before corrector')
    $addedFuzzy = $true
    $out.Add($l)
    continue
  }
  if (-not $addedPred -and $l -match '^(\s+)- "?lua_filter@\*v_filter"?\s*$') {
    $out.Add($l)
    if (-not $addedPhrase) {
      $out.Add("$($Matches[1])- `"lua_filter@*phrase_first`"")
      $changes.Add('added phrase_first after v_filter')
      $addedPhrase = $true
    }
    $out.Add("$($Matches[1])- `"lua_filter@*predict_filter`"")
    $changes.Add('added predict_filter after v_filter')
    $addedPred = $true
    continue
  }
  if (-not $addedPhrase -and $l -match '^(\s+)- "?lua_filter@\*v_filter"?\s*$') {
    $out.Add($l)
    $out.Add("$($Matches[1])- `"lua_filter@*phrase_first`"")
    $changes.Add('added phrase_first after v_filter')
    $addedPhrase = $true
    continue
  }
  if (-not $addedEn -and $l -match '^(\s+)- "?lua_filter@\*reduce_english_filter"?\s*$') {
    $out.Add($l)
    $out.Add("$($Matches[1])- `"lua_filter@*en_gate`"")
    $changes.Add('added en_gate after reduce_english_filter')
    $addedEn = $true
    continue
  }
  if ($drop -contains $l) { $changes.Add("removed: $($l.Trim())"); continue }
  if ($l -match '^(\s+)v2: \[\]\s*$') { $out.Add("$($Matches[1])v2: $v2"); $changes.Add('restored punctuator/symbols/v2'); continue }
  if ($l -match '^(\s+)v3: \[\]\s*$') { $out.Add("$($Matches[1])v3: $v3"); $changes.Add('restored punctuator/symbols/v3'); continue }
  if ($l -match '^(\s+)rime_ice\.custom:\s*\d+\s*$') { $out.Add("$($Matches[1])rime_ice.custom: $epoch"); $changes.Add("rime_ice.custom -> $epoch"); continue }
  $out.Add($l)
}

$text = ($out -join $nl) + $nl
[IO.File]::WriteAllText($build, $text, (New-Object Text.UTF8Encoding $false))

"patched: $build"
"line ending: $(if ($crlf) { 'CRLF' } else { 'LF' })"
foreach ($c in $changes) { "  $c" }

# ---- verification ----
# NOTE: -match on an array returns the matching ELEMENTS, so the text must be
# joined first; otherwise a successful match still yields a truthy result list.
$verify = (Get-Content $build -Encoding UTF8) -join "`n"
$bad = @()
if ($verify -match 'lua_translator@\*(clipboard|favorite)') { $bad += 'clipboard/favorite translator still present' }
if ($verify -match '(?m)^\s+(clipboard|favorite|vmenu):') { $bad += 'stale recognizer pattern still present' }
if ($verify -match '(?m)^\s+v[23]: \[\]\s*$') { $bad += 'v2/v3 still empty' }
if ($verify -notmatch 'lua_processor@\*menu_processor') { $bad += 'menu_processor missing' }
if ($verify -notmatch 'lua_filter@\*menu_filter') { $bad += 'menu_filter missing' }
if ($verify -notmatch 'lua_filter@\*fuzzy_filter') { $bad += 'fuzzy_filter missing' }
if ($verify -notmatch 'lua_filter@\*en_gate') { $bad += 'en_gate missing' }
if ($verify -notmatch 'lua_filter@\*predict_filter') { $bad += 'predict_filter missing' }
if ($verify -notmatch 'lua_filter@\*phrase_first') { $bad += 'phrase_first missing' }
if ($verify -match 'lua_filter@\*long_word_filter') { $bad += 'stale long_word_filter still present' }
if ($verify -notmatch 'lua_translator@\*lua_menu') { $bad += 'lua_menu missing' }
if ($bad.Count -eq 0) { 'VERIFY OK' } else { foreach ($x in $bad) { "VERIFY FAIL: $x" }; exit 1 }
