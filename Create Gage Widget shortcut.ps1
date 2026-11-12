# Creates a "Gage Widget" shortcut on your desktop.
# Run it by double-clicking "Create Gage Widget shortcut.cmd" in this same folder.
# To also start the widget at login, copy the new shortcut into shell:startup.

trap { Write-Host "`nFailed: $_" -ForegroundColor Red; exit 1 }   # the .cmd pauses so the error stays readable

if (-not (Test-Path "$PSScriptRoot\gage-widget.ps1")) { throw "gage-widget.ps1 isn't in $PSScriptRoot. Keep all the Gage Widget files in one folder." }

$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Gage Widget.lnk'
$s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
$s.TargetPath       = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$s.Arguments        = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSScriptRoot\gage-widget.ps1`""
$s.WorkingDirectory = $PSScriptRoot
$s.IconLocation     = "$PSScriptRoot\gage-widget.ico"
$s.WindowStyle      = 7   # start minimized so the console barely flashes
$s.Description      = 'Gage Widget: latest USGS discharge and stage'
$s.Save()
"Created $lnk"
Read-Host 'Press Enter to close'
