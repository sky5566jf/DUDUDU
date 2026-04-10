# TrollVNC Code Backup Script
# Usage: .\backup.ps1

param(
    [string]$Description = ""
)

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$BackupDir = Join-Path $ProjectRoot "build_output/backup"
$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

if (-not (Test-Path $BackupDir)) {
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
}

$BackupName = "TrollVNC_backup_$Timestamp"
$BackupFolder = Join-Path $BackupDir $BackupName

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  TrollVNC Code Backup" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "[1/2] Copying source code..." -ForegroundColor Yellow

$DirsToBackup = @(
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

$ExcludePatterns = @(
    "*.o",
    "*.a",
    "node_modules",
    ".git",
    "build_output",
    "*.tbd"
)

New-Item -ItemType Directory -Force -Path $BackupFolder | Out-Null

foreach ($dir in $DirsToBackup) {
    $SourcePath = Join-Path $ProjectRoot $dir
    if (Test-Path $SourcePath) {
        Write-Host "  Backup: $dir" -ForegroundColor Gray
        $DestPath = Join-Path $BackupFolder $dir
        Copy-Item -Path $SourcePath -Destination $DestPath -Recurse -Force
    }
}

$Makefile = Join-Path $ProjectRoot "Makefile"
if (Test-Path $Makefile) {
    Copy-Item -Path $Makefile -Destination $BackupFolder -Force
}

$Readme = Join-Path $ProjectRoot "README.md"
if (Test-Path $Readme) {
    Copy-Item -Path $Readme -Destination $BackupFolder -Force
}

$BackupInfo = @{
    Timestamp = $Timestamp
    Description = if ($Description) { $Description } else { "None" }
    Branch = git -C $ProjectRoot branch --show-current 2>$null
    Commit = git -C $ProjectRoot rev-parse HEAD 2>$null
    CommitMessage = git -C $ProjectRoot log -1 --pretty="%B" 2>$null
}

$InfoPath = Join-Path $BackupFolder "backup_info.json"
$BackupInfo | ConvertTo-Json -Depth 3 | Out-File -FilePath $InfoPath -Encoding UTF8

Write-Host ""
Write-Host "[2/2] Creating zip archive..." -ForegroundColor Yellow

$ZipPath = "$BackupDir/$BackupName.zip"
Compress-Archive -Path $BackupFolder -DestinationPath $ZipPath -Force
Remove-Item -Path $BackupFolder -Recurse -Force

$BackupSize = (Get-Item $ZipPath).Length
$SizeStr = if ($BackupSize -gt 1MB) { "{0:N2} MB" -f ($BackupSize / 1MB) } else { "{0:N2} KB" -f ($BackupSize / 1KB) }

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Backup Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "  File: $BackupName.zip" -ForegroundColor White
Write-Host "  Size: $SizeStr" -ForegroundColor White
Write-Host "  Desc: $($BackupInfo.Description)" -ForegroundColor White
if ($BackupInfo.Commit) {
    Write-Host "  Git:  $($BackupInfo.Commit)" -ForegroundColor Gray
}
Write-Host ""
Write-Host "  Path: $ZipPath" -ForegroundColor Gray
Write-Host ""

Write-Host "----------------------------------------" -ForegroundColor Cyan
Write-Host "  Current Backup List:" -ForegroundColor Cyan
Write-Host "----------------------------------------" -ForegroundColor Cyan
Get-ChildItem -Path $BackupDir -Filter "*.zip" | Sort-Object LastWriteTime -Descending | Select-Object -First 10 | ForEach-Object {
    $s = if ($_.Length -gt 1MB) { "{0:N2} MB" -f ($_.Length / 1MB) } else { "{0:N2} KB" -f ($_.Length / 1KB) }
    Write-Host "  $($_.Name) ($s)" -ForegroundColor White
}
Write-Host ""
