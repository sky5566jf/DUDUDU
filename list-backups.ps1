# TrollVNC List Backups
# Usage: .\list-backups.ps1

$ProjectRoot = $PSScriptRoot
$BackupDir = Join-Path $ProjectRoot "build_output/backup"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  TrollVNC Backup List" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$Backups = Get-ChildItem -Path $BackupDir -Filter "*.zip" | Sort-Object LastWriteTime -Descending

if ($Backups.Count -eq 0) {
    Write-Host "[Info] No backup files found" -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

Write-Host "Total: $($Backups.Count) backups" -ForegroundColor Green
Write-Host ""

foreach ($backup in $Backups) {
    $size = if ($backup.Length -gt 1MB) { "{0:N2} MB" -f ($backup.Length / 1MB) } else { "{0:N2} KB" -f ($backup.Length / 1KB) }
    $date = $backup.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")

    Write-Host "----------------------------------------" -ForegroundColor DarkGray
    Write-Host "  File: $($backup.Name)" -ForegroundColor White
    Write-Host "  Time: $date" -ForegroundColor Gray
    Write-Host "  Size: $size" -ForegroundColor Gray

    $TempDir = Join-Path $BackupDir "temp_info"
    if (Test-Path $TempDir) {
        Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Force -Path $TempDir | Out-Null

    try {
        Expand-Archive -Path $backup.FullName -DestinationPath $TempDir -Force -ErrorAction Stop
        $InfoFile = Get-ChildItem -Path $TempDir -Recurse -Filter "backup_info.json" -ErrorAction SilentlyContinue | Select-Object -First 1

        if ($InfoFile) {
            $Info = Get-Content $InfoFile.FullName -Raw | ConvertFrom-Json
            if ($Info.Description) {
                Write-Host "  Desc: $($Info.Description)" -ForegroundColor Cyan
            }
            if ($Info.Commit) {
                Write-Host "  Git:  $($Info.Commit.Substring(0, [Math]::Min(8, $Info.Commit.Length)))" -ForegroundColor DarkGray
            }
        }
    } catch {
    } finally {
        if (Test-Path $TempDir) {
            Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ""
Write-Host "----------------------------------------" -ForegroundColor Cyan
Write-Host ""
Write-Host "Location: $BackupDir" -ForegroundColor Gray
Write-Host ""

$TotalSize = ($Backups | Measure-Object -Property Length -Sum).Sum
$TotalSizeStr = if ($TotalSize -gt 1GB) { "{0:N2} GB" -f ($TotalSize / 1GB) } elseif ($TotalSize -gt 1MB) { "{0:N2} MB" -f ($TotalSize / 1MB) } else { "{0:N2} KB" -f ($TotalSize / 1KB) }
Write-Host "Total size: $TotalSizeStr" -ForegroundColor Yellow
Write-Host ""
