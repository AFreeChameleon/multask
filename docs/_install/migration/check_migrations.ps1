function Test-CommandExists {
    param (
        [Parameter(Mandatory)]
        [string]$Command
    )

    $cmd = Get-Command $Command -ErrorAction SilentlyContinue
    return $null -ne $cmd
}

$versions = @('v0.4.1', 'v0.4.2', 'v0.5.0', 'v0.5.1', 'v0.5.2')

if (Test-CommandExists "mlt") {
    $output = mlt version

    $baseVersion = ($output | Out-String).Split()[-3]

    $index = $versions.IndexOf($baseVersion)

    if ($index -ne -1) {
        for ($i=$index + 1; $i -lt $versions.Length; $i++) {
            $version = $versions[$i]
            echo "Checking for $version migration script..."
            try {
                irm "https://raw.githubusercontent.com/AFreeChameleon/multask/refs/heads/master/docs/_install/migration/$version/win.ps1" | iex
            } catch [System.Net.WebException] {
                echo "No migration needed, skipping"
                continue
            }
        }
    }
}
