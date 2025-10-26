echo "Upgrading from 0.4.2 to 0.5.0"

$tasksPath = "$env:USERPROFILE\.multi-tasker\tasks"
$tasksDirs = (Get-ChildItem -Path $tasksPath -Directory).Name

foreach($dir in $tasksDirs) {
    echo "Adding interactive and boot to task id: $dir"

    $jsonPath = "$env:USERPROFILE\.multi-tasker\tasks\$dir\stats.json"
    if (Test-Path $jsonPath) {
        $jsonData = Get-Content -Path $jsonPath -Raw | ConvertFrom-Json
        $jsonData | Add-Member -NotePropertyName interactive -NotePropertyValue $false -Force
        $jsonData | Add-Member -NotePropertyName boot -NotePropertyValue $false -Force
        $newData = $jsonData | ConvertTo-Json -Compress
        $utf8NoBOM = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($jsonPath, $newData, $utf8NoBOM)
    } else {
        echo "Task with id: $dir doesn't exist, skipping..."
    }
}

echo "Upgraded to v0.5.0"
