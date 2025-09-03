curl https://github.com/AFreeChameleon/multask/releases/download/v0.4.2/multask-windows.zip -o "$env:USERPROFILE\mlt-win.zip" | Out-Null
New-Item "$env:USERPROFILE\.multi-tasker\bin" -ItemType Directory -Force | Out-Null
Expand-Archive -Force "$env:USERPROFILE\mlt-win.zip" "$env:USERPROFILE\.multi-tasker\bin"
[Environment]::SetEnvironmentVariable("Path", [Environment]::GetEnvironmentVariable('Path', 'User') + ";$env:USERPROFILE\.multi-tasker\bin", "User")
Remove-Item "$env:USERPROFILE\mlt-win.zip"
echo "Install finished, run: `$env:PATH += `";`$env:USERPROFILE\.multi-tasker\bin\`" to use mlt in this terminal."
