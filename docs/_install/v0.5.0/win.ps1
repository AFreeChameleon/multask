# Checking to migrate data - CANNOT run this because v0.4.2 doesnt allow redirecting content
# irm "https://raw.githubusercontent.com/AFreeChameleon/multask-zig/refs/heads/develop-2/docs/_install/migration/check_migrations.ps1?token=GHSAT0AAAAAADGHQRJ52NNOOK7NYGSYKTTI2HFVYUQ" | iex

# Downloading the exes
curl https://github.com/AFreeChameleon/multask/releases/download/v0.5.0/multask-windows.zip -o "$env:USERPROFILE\mlt-win.zip" | Out-Null
$multaskBinDir = "$env:USERPROFILE\.multi-tasker\bin"
New-Item $multaskBinDir -ItemType Directory -Force | Out-Null
Expand-Archive -Force "$env:USERPROFILE\mlt-win.zip" $multaskBinDir
if (-Not [Environment]::GetEnvironmentVariable('Path', 'User').Contains($multaskBinDir)) {
    echo "Adding multask bin dir to PATH"
    [Environment]::SetEnvironmentVariable("Path", [Environment]::GetEnvironmentVariable('Path', 'User') + ";$multaskBinDir", "User")
}
Remove-Item "$env:USERPROFILE\mlt-win.zip"
echo "Install finished, run: `$env:PATH += `";`$env:USERPROFILE\.multi-tasker\bin\`" to use mlt in this terminal."
