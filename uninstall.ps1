# ZCode-TPS-Footer 一键回滚（Windows）：恢复原始 app.asar + 卸载数据服务
# 用法：双击 uninstall.bat，或：powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1
#       可选参数：-ZCodeDir "<ZCode 安装目录>"（默认自动探测）
param([string]$ZCodeDir = "")

$ErrorActionPreference = 'Continue'
$TASK_NAME = 'ZCodeTPSFooterServer'
$PORT = 3117

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Ok($m)   { Write-Host "✅ $m" -ForegroundColor Green }
function Warn($m) { Write-Host "⚠️  $m" -ForegroundColor Yellow }
function Err($m)  { Write-Host "❌ $m" -ForegroundColor Red }

function Find-ZCodeRoot([string]$Hint) {
    if ($Hint) {
        if (Test-Path (Join-Path $Hint 'resources\app.asar')) { return $Hint }
        return $null
    }
    $p = Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p -and $p.Path) {
        $d = Split-Path $p.Path -Parent
        if (Test-Path (Join-Path $d 'resources\app.asar')) { return $d }
    }
    foreach ($k in @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )) {
        foreach ($i in (Get-ItemProperty $k -ErrorAction SilentlyContinue)) {
            if ($i.DisplayName -notlike '*ZCode*') { continue }
            $cands = @()
            if ($i.InstallLocation) { $cands += "$($i.InstallLocation)" }
            if ($i.UninstallString) {
                $us = "$($i.UninstallString)".Trim()
                if ($us.StartsWith('"')) {
                    $end = $us.IndexOf('"', 1)
                    if ($end -gt 1) { $cands += (Split-Path ($us.Substring(1, $end - 1)) -Parent) }
                } else {
                    $cands += (Split-Path (($us -split ' ')[0]) -Parent) }
            }
            if ($i.DisplayIcon) { $cands += (Split-Path ("$($i.DisplayIcon)".Trim('"')) -Parent) }
            foreach ($c in $cands) {
                $c = "$c".Trim().Trim('"').TrimEnd('\', '/')
                if ($c -and (Test-Path (Join-Path $c 'resources\app.asar'))) { return $c }
            }
        }
    }
    foreach ($d in @(
        "$env:LOCALAPPDATA\Programs\zcode", "$env:LOCALAPPDATA\Programs\ZCode",
        "$env:ProgramFiles\ZCode", "${env:ProgramFiles(x86)}\ZCode"
    )) {
        if (Test-Path (Join-Path $d 'resources\app.asar')) { return $d }
    }
    return $null
}

# 1) 卸载开机自启（三种注册方式都清理，幂等）
Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false -ErrorAction SilentlyContinue
if (Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue) {
    & schtasks /Delete /F /TN $TASK_NAME | Out-Null
}
$vbs = Join-Path ([System.Environment]::GetFolderPath('Startup')) 'zcode-tps-footer.vbs'
if (Test-Path $vbs) { Remove-Item $vbs -Force; Ok "已删除启动文件夹项（zcode-tps-footer.vbs）" }

# 2) 停掉正在运行的数据服务（按端口 3117 找进程，只杀 python）
try {
    $conns = Get-NetTCPConnection -LocalPort $PORT -State Listen -ErrorAction SilentlyContinue
    foreach ($c in $conns) {
        $proc = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -like 'python*') {
            Stop-Process -Id $proc.Id -Force
            Ok "已停止数据服务（PID $($proc.Id)）"
        }
    }
} catch {}

# 3) 恢复原始 app.asar（ZCode 运行中会锁文件，需先退出）
$ZCodeRoot = Find-ZCodeRoot $ZCodeDir
if ($ZCodeRoot) {
    $RES  = Join-Path $ZCodeRoot 'resources'
    $ASAR = Join-Path $RES 'app.asar'
    if (Test-Path "$ASAR.tps-bak") {
        if (Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue) {
            Err "检测到 ZCode 正在运行，无法恢复 app.asar。请完全退出 ZCode 后重新运行本脚本。"
        } else {
            Copy-Item "$ASAR.tps-bak" $ASAR -Force
            Ok "已恢复原始 app.asar。完全退出 ZCode 再打开即回到纯原生。"
        }
    } else {
        Warn "没找到备份 app.asar.tps-bak（可能从未注入过）。数据服务已卸载。"
    }
} else {
    Warn "未定位到 ZCode 安装目录，跳过 asar 恢复（数据服务已卸载）。"
}

Write-Host ""
Write-Host "说明：~/.zcode/tps-inject 暂存目录保留（无害，可手动删除）。"
