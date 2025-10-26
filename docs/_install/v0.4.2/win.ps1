curl https://github.com/AFreeChameleon/multask/releases/download/v0.4.2/multask-windows.zip -o "$env:USERPROFILE\mlt-win.zip" | Out-Null
$multaskBinDir = "$env:USERPROFILE\.multi-tasker\bin"
New-Item $multaskBinDir -ItemType Directory -Force | Out-Null
Expand-Archive -Force "$env:USERPROFILE\mlt-win.zip" $multaskBinDir
if (-Not [Environment]::GetEnvironmentVariable('Path', 'User').Contains($multaskBinDir)) {
    echo "Adding multask bin dir to PATH"
    [Environment]::SetEnvironmentVariable("Path", [Environment]::GetEnvironmentVariable('Path', 'User') + ";$multaskBinDir", "User")
}
Remove-Item "$env:USERPROFILE\mlt-win.zip"
echo "Install finished, run: `$env:PATH += `";`$env:USERPROFILE\.multi-tasker\bin\`" to use mlt in this terminal."
