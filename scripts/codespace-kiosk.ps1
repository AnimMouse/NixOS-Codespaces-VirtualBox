<#
.SYNOPSIS
  Open a codespace editor in a chrome-less Firefox window, on the Windows host.

.DESCRIPTION
  Firefox has no desktop PWA support, so a normal tab is the only other option —
  and in a normal tab Ctrl+W closes the editor with it and Ctrl+Shift+P opens a
  private window instead of the command palette. Kiosk mode plus a dedicated
  profile avoids both: no tab to close by reflex, and its own history, cookies
  and session separate from your browsing.

  Press F11 to leave kiosk mode, Alt+F4 to close. Inside the editor, F1 is the
  command palette.

.PARAMETER Target
  A port (8001), a full URL, or the name of a codespace — a name is looked up
  over SSH with `codespace list`. Defaults to the hub editor on 8000.

.EXAMPLE
  .\codespace-kiosk.ps1              # hub editor
  .\codespace-kiosk.ps1 8002
  .\codespace-kiosk.ps1 frp-flyapp
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string]$Target = '8000',

  [string]$ProfileName = 'codespace',

  [int]$SshPort = 2222
)

$ErrorActionPreference = 'Stop'

function Find-Firefox {
  $candidates = @(
    "$env:ProgramFiles\Mozilla Firefox\firefox.exe",
    "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe"
  )
  foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
  $cmd = Get-Command firefox.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  throw "Firefox not found. Pass -Verbose or edit Find-Firefox in this script."
}

function Resolve-Url {
  param([string]$T)

  if ($T -match '^https?://') { return $T }
  if ($T -match '^\d+$')      { return "http://localhost:$T/" }

  # A codespace name: ask the VM which port it was given.
  Write-Verbose "Looking up '$T' on the VM over SSH"
  $rows = & ssh -p $SshPort dev@localhost 'codespace list' 2>$null
  if ($LASTEXITCODE -ne 0) {
    throw "Could not reach the VM over SSH to look up '$T'. Give a port instead."
  }
  foreach ($row in $rows) {
    $f = ($row -split '\s+') | Where-Object { $_ -ne '' }
    # -match '^\d+$' also skips the header row, whose second column is "PORT".
    if ($f.Count -ge 2 -and $f[0] -eq $T -and $f[1] -match '^\d+$') {
      return "http://localhost:$($f[1])/"
    }
  }
  throw "No codespace named '$T'. Run: ssh -p $SshPort dev@localhost codespace list"
}

$firefox = Find-Firefox
$url     = Resolve-Url -T $Target

# Created on first use. Keeping the editor off your default profile means its
# cookies and session survive independently of your normal browsing.
$profiles = & $firefox -P 2>&1 | Out-String
if ($profiles -notmatch [regex]::Escape($ProfileName)) {
  Write-Host "Creating Firefox profile '$ProfileName'"
  & $firefox -CreateProfile $ProfileName | Out-Null
  Start-Sleep -Milliseconds 500
}

Write-Host "Opening $url"
# --no-remote so this gets its own instance rather than a tab in whatever
# Firefox window happens to be open already.
& $firefox --no-remote -P $ProfileName --kiosk $url
