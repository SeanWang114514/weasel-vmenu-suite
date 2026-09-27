param(
  [string]$RimeDir = 'D:\rime-sandbox',
  [int]$Max = 50,
  [int]$IntervalMs = 1000
)
# Clipboard history sync - fully independent of the IME process.
# The IME side (lua/vmenu_core.lua) ONLY reads/writes this text file; it never
# spawns a process, which is what used to freeze the input method.
#
# File format: one clipboard entry per line, newest first.
# Entries are de-duplicated, capped at $Max, oldest dropped first.
#
# THE FILE IS THE SINGLE SOURCE OF TRUTH.
#   The settings window and the v-menu both clear the history by rewriting
#   clipboard-cache.txt, so this process must notice an external change and throw
#   away its in-memory copy. It used to keep the list ONLY in memory and rewrite
#   the whole file on every copy, so cleared entries came back on the next copy
#   (reported by the user: "clear it, copy once, and the old entries are back").
#   Now the file is re-read whenever its stamp (mtime + size) changes, which also
#   makes edits made in the settings window stick instead of being overwritten.
#
#   A clipboard change is detected with GetClipboardSequenceNumber(), which bumps
#   on every copy - including re-copying exactly the same text, which the old
#   "compare with the last text" check missed.
#
# ASCII-only source on purpose: Windows PowerShell 5.1 parses BOM-less UTF-8
# scripts as ANSI, which breaks quoting when non-ASCII comments are present.

$ErrorActionPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force -Path $RimeDir | Out-Null
$cache = Join-Path $RimeDir 'clipboard-cache.txt'
$utf8 = New-Object Text.UTF8Encoding($false)

Add-Type -Namespace Win32 -Name Clip -MemberDefinition @'
[DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
'@

function Get-Stamp {
  $fi = Get-Item -LiteralPath $cache -ErrorAction SilentlyContinue
  if ($null -eq $fi) { return 'missing' }
  return ('{0}:{1}' -f $fi.LastWriteTimeUtc.Ticks, $fi.Length)
}

function Read-History {
  param([string]$Path)
  $items = @()
  if (Test-Path -LiteralPath $Path) {
    $items = @(Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue |
      Where-Object { $_ -ne $null -and $_.Trim().Length -gt 0 })
  }
  return $items
}

function Write-History {
  param([string]$Path, [string[]]$Items)
  $tmp = "$Path.tmp"
  $lines = @()
  foreach ($i in $Items) {
    if ($null -ne $i -and $i.Trim().Length -gt 0) { $lines += $i.Trim() }
  }
  $text = ''
  if ($lines.Count -gt 0) { $text = ($lines -join "`n") + "`n" }
  [IO.File]::WriteAllText($tmp, $text, $utf8)
  Move-Item -Force $tmp $Path
}

function Get-ClipText {
  $t = $null
  try { $t = Get-Clipboard -Raw -ErrorAction Stop } catch { return $null }
  if ($null -eq $t) { return $null }
  # Flatten newlines: the cache format is one entry per line.
  $t = ($t -replace "`r`n", ' ') -replace "[`r`n]", ' '
  $t = $t.Trim()
  if ($t.Length -eq 0) { return $null }
  if ($t.Length -gt 2000) { $t = $t.Substring(0, 2000) }
  return $t
}

$history = @(Read-History -Path $cache)
if ($history.Count -gt $Max) { $history = $history[0..($Max - 1)] }
# Make sure the file exists even on first run.
if (-not (Test-Path -LiteralPath $cache)) { Write-History -Path $cache -Items $history }
$stamp = Get-Stamp
$seq = [Win32.Clip]::GetClipboardSequenceNumber()

while ($true) {
  # (1) Did somebody else change the file (clear / edit / delete)?
  $now = Get-Stamp
  if ($now -ne $stamp) {
    $history = @(Read-History -Path $cache)
    if ($history.Count -gt $Max) { $history = $history[0..($Max - 1)] }
    if ($now -eq 'missing') {
      Write-History -Path $cache -Items $history
      $now = Get-Stamp
    }
    $stamp = $now
    # Whatever sits on the clipboard right now is not a new copy: mark its
    # sequence as already handled, so clearing the history does not instantly
    # re-add the entry that is currently on the clipboard.
    $seq = [Win32.Clip]::GetClipboardSequenceNumber()
  }

  # (2) A new copy?
  $s = [Win32.Clip]::GetClipboardSequenceNumber()
  if ($s -ne $seq) {
    $seq = $s
    $text = Get-ClipText
    if ($text) {
      $new = @($text)
      foreach ($old in $history) { if ($old -ne $text) { $new += $old } }
      if ($new.Count -gt $Max) { $new = $new[0..($Max - 1)] }
      $history = $new
      Write-History -Path $cache -Items $history
      $stamp = Get-Stamp
    }
  }

  Start-Sleep -Milliseconds $IntervalMs
}
