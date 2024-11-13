curl https://github.com/AFreeChameleon/multask/releases/download/0.20.0/multask_win-0.20.0.zip -o "$env:USERPROFILE\mlt-win.zip" | Out-Null
New-Item "$env:USERPROFILE\.multi-tasker\bin" -ItemType Directory -Force | Out-Null
Expand-Archive -Force "$env:USERPROFILE\mlt-win.zip" "$env:USERPROFILE\.multi-tasker\bin"
[Environment]::SetEnvironmentVariable("Path", [Environment]::GetEnvironmentVariable('Path', 'User') + ";$env:USERPROFILE\.multi-tasker\bin", "User")
Get-ChildItem -Path "$env:USERPROFILE\.multi-tasker\bin\multask_win-0.20.0" -Recurse -File | Move-Item -Destination "$env:USERPROFILE\.multi-tasker\bin\"
Remove-Item "$env:USERPROFILE\.multi-tasker\bin\multask_win-0.20.0"
Remove-Item "$env:USERPROFILE\mlt-win.zip"
echo "Install finished, run: `$env:PATH += `";`$env:USERPROFILE\.multi-tasker\bin\`" to use mlt in this terminal."
