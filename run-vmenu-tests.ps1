param(
  [string]$ShotDir = '',
  [int]$X = 60, [int]$Y = 70, [int]$W = 1160, [int]$H = 340
)
# Drive the v-menu through a scripted sequence and capture one screenshot per
# step. ASCII-only source on purpose: Windows PowerShell 5.1 parses BOM-less
# UTF-8 scripts as ANSI, so any non-ASCII literal here (including a path such as
# the workspace folder) would be corrupted. All paths are derived from
# $PSScriptRoot instead.

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
if (-not $ShotDir) { $ShotDir = Join-Path $here 'shots\vmenu' }
if (-not (Test-Path $ShotDir)) { New-Item -ItemType Directory -Path $ShotDir -Force | Out-Null }

$harness = Join-Path $here 'ime-test.ps1'
$focus = Join-Path $here 'focus-notepad.ps1'
if (-not (Test-Path $harness)) { throw "missing harness: $harness" }

$steps = [ordered]@{
  '01-menu'            = 'esc,v'
  '02-menu-1-set'      = 'esc,v,1'
  '03-set-1-clip20'    = 'esc,v,1,1'
  '04-clip-more30'     = 'esc,v,1,1,m'
  '05-clip-more40'     = 'esc,v,1,1,m,m'
  '06-clip-more50cap'  = 'esc,v,1,1,m,m,m'
  '07-clip-page3'      = 'esc,v,1,1,equals,equals'
  '08-clip-delete'     = 'esc,v,1,1,d'
  '09-clip-clearconf'  = 'esc,v,1,1,x'
  '10-quick-clip'      = 'esc,v,2'
  '11-fav'             = 'esc,v,3'
  '12-set-2-fav'       = 'esc,v,1,2'
  '13-set-3-pagesize'  = 'esc,v,1,3'
  '14-set-4-clearconf' = 'esc,v,1,4'
  '15-raw-v2'          = 'esc,v,4,v,2'
  '16-raw-va'          = 'esc,v,4,v,a'
  '17-menu-then-a'     = 'esc,v,a'
  '18-menu-then-5'     = 'esc,v,5'
}

foreach ($k in $steps.Keys) {
  $keys = $steps[$k]
  $out = Join-Path $ShotDir "$k.png"
  $r = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $harness -Keys $keys -Out $out -NoFocus -X $X -Y $Y -ShotW $W -ShotH $H
  $title = ($r | Select-String 'FOREGROUND=').Line
  "$k  <- [$keys]  $title"
}
"shots in $ShotDir"
