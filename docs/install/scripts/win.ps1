curl https://github.com/AFreeChameleon/multask/releases/latest/download/multask_win.zip -o "$env:USERPROFILE\multask.zip" | Out-Null
New-Item "$env:USERPROFILE\.multi-tasker\bin" -ItemType Directory -Force | Out-Null
Expand-Archive -Force "$env:USERPROFILE\multask.zip" "$env:USERPROFILE\.multi-tasker\bin"
[Environment]::SetEnvironmentVariable("Path", [Environment]::GetEnvironmentVariable('Path', 'User') + ";$env:USERPROFILE\.multi-tasker\bin", "User")
Get-ChildItem -Path "$env:USERPROFILE\.multi-tasker\bin\multask" -Recurse -File | Move-Item -Destination "$env:USERPROFILE\.multi-tasker\bin\"
Remove-Item "$env:USERPROFILE\.multi-tasker\bin\multask"
Remove-Item "$env:USERPROFILE\multask.zip"
echo "Install finished, run: `$env:PATH += `";`$env:USERPROFILE\.multi-tasker\bin\`" to use mlt in this terminal."
