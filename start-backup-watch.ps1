# TrollVNC File Watch Backup Script
# Usage: .\start-backup-watch.ps1
# Watches source files and auto-backs up on changes

param(
    [string]$Description = "",
    [int]$DebounceSeconds = 3
)

$ProjectRoot = $PSScriptRoot
$ScriptDir = $PSScriptRoot

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  TrollVNC File Watch Backup" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Project: $ProjectRoot" -ForegroundColor Gray
Write-Host "Debounce: ${DebounceSeconds}s" -ForegroundColor Gray
Write-Host ""

$BackupScript = Join-Path $ScriptDir "scripts/backup.ps1"
if (-not (Test-Path $BackupScript)) {
    Write-Host "[Error] Backup script not found: $BackupScript" -ForegroundColor Red
    exit 1
}

$WatchDirs = @(
    (Join-Path $ProjectRoot "src"),
    (Join-Path $ProjectRoot "include"),
    (Join-Path $ProjectRoot "include-spi"),
    (Join-Path $ProjectRoot "include-simulator"),
    (Join-Path $ProjectRoot "prefs"),
    (Join-Path $ProjectRoot "app"),
    (Join-Path $ProjectRoot "devkit"),
    (Join-Path $ProjectRoot "layout")
)

$FileFilters = @("*.c", "*.cpp", "*.h", "*.m", "*.mm", "*.swift", "*.sh")
$ExcludeDirs = @("node_modules", ".git", "build_output")

$LastBackupTime = Get-Date
$PendingBackup = $false
$ModifiedFiles = @()

Write-Host "[Watching] Press Ctrl+C to stop..." -ForegroundColor Yellow
Write-Host ""
Write-Host "----------------------------------------" -ForegroundColor Cyan
Write-Host ""

$watchers = @()

foreach ($dir in $WatchDirs) {
    if (Test-Path $dir) {
        $watcher = New-Object System.IO.FileSystemWatcher
        $watcher.Path = $dir
        $watcher.IncludeSubdirectories = $true
        $watcher.EnableRaisingEvents = $false

        foreach ($filter in $FileFilters) {
            Register-ObjectEvent $watcher "Changed" -Action {
                $eventPath = $Event.SourceEventArgs.FullPath
                $isExcluded = $false
                foreach ($excl in $using:ExcludeDirs) {
                    if ($eventPath -like "*\$excl\*") {
                        $isExcluded = $true
                        break
                    }
                }
                if (-not $isExcluded) {
                    $script:ModifiedFiles += $eventPath
                    $script:PendingBackup = $true
                }
            } | Out-Null

            Register-ObjectEvent $watcher "Created" -Action {
                $eventPath = $Event.SourceEventArgs.FullPath
                $isExcluded = $false
                foreach ($excl in $using:ExcludeDirs) {
                    if ($eventPath -like "*\$excl\*") {
                        $isExcluded = $true
                        break
                    }
                }
                if (-not $isExcluded) {
                    $script:ModifiedFiles += $eventPath
                    $script:PendingBackup = $true
                }
            } | Out-Null

            Register-ObjectEvent $watcher "Renamed" -Action {
                $eventPath = $Event.SourceEventArgs.FullPath
                $isExcluded = $false
                foreach ($excl in $using:ExcludeDirs) {
                    if ($eventPath -like "*\$excl\*") {
                        $isExcluded = $true
                        break
                    }
                }
                if (-not $isExcluded) {
                    $script:ModifiedFiles += $eventPath
                    $script:PendingBackup = $true
                }
            } | Out-Null
        }

        $watcher.EnableRaisingEvents = $true
        $watchers += $watcher

        Write-Host "  Watch: $dir" -ForegroundColor Gray
    }
}

Write-Host ""
Write-Host "[Started] Waiting for changes..." -ForegroundColor Green

while ($true) {
    Start-Sleep -Seconds 1

    if ($PendingBackup) {
        $timeSinceLastBackup = (Get-Date) - $LastBackupTime

        if ($timeSinceLastBackup.TotalSeconds -ge $DebounceSeconds) {
            $uniqueFiles = $ModifiedFiles | Select-Object -Unique

            Write-Host ""
            Write-Host "========================================" -ForegroundColor Yellow
            Write-Host "[Change Detected] Starting backup..." -ForegroundColor Yellow
            Write-Host "========================================" -ForegroundColor Yellow
            Write-Host ""

            foreach ($file in $uniqueFiles) {
                $relativePath = $file.Replace($ProjectRoot, "").TrimStart("\")
                Write-Host "  Changed: $relativePath" -ForegroundColor DarkGray
            }
            Write-Host ""

            $modifiedCount = $uniqueFiles.Count
            $backupDesc = if ($Description) {
                "$Description | $modifiedCount files changed"
            } else {
                "Auto backup | $modifiedCount files changed"
            }

            & $BackupScript -Description $backupDesc

            $LastBackupTime = Get-Date
            $PendingBackup = $false
            $ModifiedFiles = @()

            Write-Host "[Continue watching]..." -ForegroundColor Green
        }
    }
}

foreach ($watcher in $watchers) {
    $watcher.EnableRaisingEvents = $false
}
