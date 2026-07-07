# TrollVNC 停止文件监控
# 使用方法: .\stop-backup-watch.ps1
# 停止所有正在运行的监控进程

$ProcessName = "powershell"

Write-Host "正在停止监控进程..." -ForegroundColor Yellow

# 查找并停止包含备份监控脚本的 PowerShell 进程
$Processes = Get-Process -Name "powershell" -ErrorAction SilentlyContinue

$Stopped = $false
foreach ($proc in $Processes) {
    try {
        $cmd = $proc.CommandLine
        if ($cmd -like "*start-backup-watch*") {
            Write-Host "停止进程 PID: $($proc.Id)" -ForegroundColor Cyan
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            $Stopped = $true
        }
    } catch {
        # 无法获取 CommandLine，继续
    }
}

if ($Stopped) {
    Write-Host ""
    Write-Host "[完成] 监控已停止" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "[提示] 未找到运行中的监控进程" -ForegroundColor Yellow
}
