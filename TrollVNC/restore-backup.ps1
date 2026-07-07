# TrollVNC Restore From Backup Script
# Usage: .\restore-backup.ps1

$ProjectRoot = $PSScriptRoot
$BackupDir = Join-Path $ProjectRoot "build_output/backup"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  TrollVNC Restore From Backup" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$Backups = Get-ChildItem -Path $BackupDir -Filter "*.zip" | Sort-Object LastWriteTime -Descending

if ($Backups.Count -eq 0) {
    Write-Host "[Error] No backup files found" -ForegroundColor Red
    Write-Host "Path: $BackupDir" -ForegroundColor Gray
    exit 1
}

Write-Host "Available Backups:" -ForegroundColor Yellow
Write-Host ""
$i = 1
foreach ($backup in $Backups) {
    $size = if ($backup.Length -gt 1MB) { "{0:N2} MB" -f ($backup.Length / 1MB) } else { "{0:N2} KB" -f ($backup.Length / 1KB) }
    $date = $backup.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
    Write-Host "  [$i] $date - $($backup.Name) ($size)" -ForegroundColor White
    $i++
}

Write-Host ""
$selection = Read-Host "Enter backup number to restore (1-$($Backups.Count), Q to quit)"

if ($selection -eq "Q" -or $selection -eq "q") {
    Write-Host "Cancelled" -ForegroundColor Gray
    exit 0
}

$index = [int]$selection - 1
if ($index -lt 0 -or $index -ge $Backups.Count) {
    Write-Host "[Error] Invalid selection" -ForegroundColor Red
    exit 1
}

$SelectedBackup = $Backups[$index]

Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  About to restore:" -ForegroundColor Yellow
Write-Host "  $($SelectedBackup.Name)" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""

Write-Host "[WARNING] This will overwrite current code!" -ForegroundColor Red
$confirm = Read-Host "Confirm restore? (yes/no)"

if ($confirm -ne "yes") {
    Write-Host "Cancelled" -ForegroundColor Gray
    exit 0
}

Write-Host ""
Write-Host "[1/3] Extracting backup..." -ForegroundColor Yellow

$TempDir = Join-Path $BackupDir "temp_restore"
if (Test-Path $TempDir) {
    Remove-Item -Path $TempDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $TempDir | Out-Null

Expand-Archive -Path $SelectedBackup.FullName -DestinationPath $TempDir -Force

$ExtractedRoot = Get-ChildItem -Path $TempDir -Directory | Select-Object -First 1
if ($ExtractedRoot) {
    $SourceDir = $ExtractedRoot.FullName
} else {
    $SourceDir = $TempDir
}

Write-Host "[2/3] Restoring files..." -ForegroundColor Yellow

$DirsToRestore = @(
    "src",
    "include",
    "include-spi",
    "include-simulator",
    "prefs",
    "app",
    "lib",
    "lib-simulator",
    "devkit",
    "layout",
    "PrivateFrameworks",
    "Artworks"
)

foreach ($dir in $DirsToRestore) {
    $SourcePath = Join-Path $SourceDir $dir
    $DestPath = Join-Path $ProjectRoot $dir

    if (Test-Path $SourcePath) {
        Write-Host "  Restore: $dir" -ForegroundColor Gray
        if (Test-Path $DestPath) {
            Remove-Item -Path $DestPath -Recurse -Force
        }
        Copy-Item -Path $SourcePath -Destination $DestPath -Recurse -Force
    }
}

$MakefileSource = Join-Path $SourceDir "Makefile"
if (Test-Path $MakefileSource) {
    Copy-Item -Path $MakefileSource -Destination $ProjectRoot -Force
}

$ReadmeSource = Join-Path $SourceDir "README.md"
if (Test-Path $ReadmeSource) {
    Copy-Item -Path $ReadmeSource -Destination $ProjectRoot -Force
}

Write-Host "[3/3] Cleaning up..." -ForegroundColor Yellow
Remove-Item -Path $TempDir -Recurse -Force

$BackupInfoPath = Join-Path $SourceDir "backup_info.json"
if (Test-Path $BackupInfoPath) {
    Write-Host ""
    Write-Host "----------------------------------------" -ForegroundColor Cyan
    Write-Host "  Backup Info:" -ForegroundColor Cyan
    Write-Host "----------------------------------------" -ForegroundColor Cyan

    $BackupInfo = Get-Content $BackupInfoPath -Raw | ConvertFrom-Json
    Write-Host "  Time: $($BackupInfo.Timestamp)" -ForegroundColor White
    Write-Host "  Desc: $($BackupInfo.Description)" -ForegroundColor White
    if ($BackupInfo.Commit) {
        Write-Host "  Git:  $($BackupInfo.Commit)" -ForegroundColor Gray
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Restore Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "[Tip] Rebuild project if needed" -ForegroundColor Yellow
Write-Host ""
