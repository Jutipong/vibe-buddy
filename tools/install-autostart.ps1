# Starts the bridge at logon through the per-user Startup folder: no admin
# rights needed, and no console window flashes.
#
#   powershell -ExecutionPolicy Bypass -File tools\install-autostart.ps1
#   powershell -ExecutionPolicy Bypass -File tools\install-autostart.ps1 -Remove

param([switch]$Remove)

$startup = [Environment]::GetFolderPath("Startup")
$shortcut = Join-Path $startup "VibeBuddyBridge.vbs"

if ($Remove) {
  Remove-Item $shortcut -Force -ErrorAction SilentlyContinue
  Write-Host "removed $shortcut"
  exit 0
}

$bridge = Join-Path $PSScriptRoot "bridge.ps1"
if (-not (Test-Path $bridge)) {
  Write-Host "bridge.ps1 not found next to this script" -ForegroundColor Red
  exit 1
}

# A scheduled task would need admin rights (Access denied in the root folder);
# the Startup folder is per-user and starts at logon.
$content = @"
Set sh = CreateObject("WScript.Shell")
sh.Run "cmd /c powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""$bridge"" >> ""$PSScriptRoot\bridge.log"" 2>&1", 0, False
"@

Set-Content -Path $shortcut -Value $content -Encoding ASCII
Write-Host "installed $shortcut"
Write-Host "the bridge now starts when $env:USERNAME logs in"
Get-Content $shortcut
