# ZCode-TPS-Footer 一键安装（Windows，ZCode 3.11.x）
# 用法：双击 install.bat，或：powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
#       可选参数：-ZCodeDir "<ZCode 安装目录>"（目录下应有 resources\app.asar，默认自动探测）
#                 -DryRun（演练模式：探测 + 解包 + 注入 + 打包到暂存目录，不替换正式包、不装服务）
# 原理：解包 app.asar → 渲染层 index.html 加一行 <script> → 重打包替换（原包自动备份）。
#       数据服务经任务计划程序开机自启（对应 macOS 版的 launchd），仅监听 127.0.0.1:3117。
param(
    [string]$ZCodeDir = "",
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$TASK_NAME = 'ZCodeTPSFooterServer'
$STAGE     = Join-Path $HOME '.zcode\tps-inject'

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Ok($m)   { Write-Host "✅ $m" -ForegroundColor Green }
function Warn($m) { Write-Host "⚠️  $m" -ForegroundColor Yellow }
function Err($m)  { Write-Host "❌ $m" -ForegroundColor Red }

# ---------- 定位 ZCode 安装目录（含 resources\app.asar）----------
function Find-ZCodeRoot([string]$Hint) {
    if ($Hint) {
        if (Test-Path (Join-Path $Hint 'resources\app.asar')) { return $Hint }
        return $null
    }
    # 1) 运行中的进程路径
    $p = Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p -and $p.Path) {
        $d = Split-Path $p.Path -Parent
        if (Test-Path (Join-Path $d 'resources\app.asar')) { return $d }
    }
    # 2) 注册表卸载信息：InstallLocation 可能为空、也可能带引号（如 ZCode Skin Manager 的值就带引号），
    #    依次从 InstallLocation / UninstallString / DisplayIcon 推导候选目录，验过 resources\app.asar 才采纳
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
                    $cands += (Split-Path (($us -split ' ')[0]) -Parent)
                }
            }
            if ($i.DisplayIcon) { $cands += (Split-Path ("$($i.DisplayIcon)".Trim('"')) -Parent) }
            foreach ($c in $cands) {
                $c = "$c".Trim().Trim('"').TrimEnd('\', '/')
                if ($c -and (Test-Path (Join-Path $c 'resources\app.asar'))) { return $c }
            }
        }
    }
    # 3) 常见安装位置
    foreach ($d in @(
        "$env:LOCALAPPDATA\Programs\zcode", "$env:LOCALAPPDATA\Programs\ZCode",
        "$env:ProgramFiles\ZCode", "${env:ProgramFiles(x86)}\ZCode"
    )) {
        if (Test-Path (Join-Path $d 'resources\app.asar')) { return $d }
    }
    return $null
}

$ZCodeRoot = Find-ZCodeRoot $ZCodeDir
if (-not $ZCodeRoot) {
    Err "找不到 ZCode（需要 resources\app.asar）。请用 -ZCodeDir 指定安装目录后重试。"
    exit 1
}
$RES  = Join-Path $ZCodeRoot 'resources'
$ASAR = Join-Path $RES 'app.asar'
Ok "ZCode 安装目录：$ZCodeRoot"

# ---------- 前置检查：Node/npx 与 Python ----------
if (-not (Get-Command npx -ErrorAction SilentlyContinue)) {
    Err "需要 Node.js（npx 可用，用于解/打包 asar）。"
    exit 1
}

$pyw = (Get-Command pythonw.exe -ErrorAction SilentlyContinue).Source
if (-not $pyw) {
    $py = (Get-Command python.exe -ErrorAction SilentlyContinue).Source
    if ($py) {
        $cand = Join-Path (Split-Path $py -Parent) 'pythonw.exe'
        $pyw = if (Test-Path $cand) { $cand } else { $py }
    }
}
if (-not $pyw) {
    Err "需要 Python 3（python 在 PATH 中，用于数据服务）。"
    exit 1
}
& $pyw --version | Out-Null
if ($LASTEXITCODE -ne 0) {
    Err "Python 不可用（$pyw）。请确认 PATH 中的 python 可正常运行（微软商店占位符不算）。"
    exit 1
}

if (-not $DryRun -and (Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue)) {
    Err "检测到 ZCode 正在运行。请先完全退出 ZCode（含托盘图标）再运行本脚本（运行中会锁定 app.asar）。"
    exit 1
}

# ---------- 1) 装载文件到稳定目录（与仓库位置解耦）----------
New-Item -ItemType Directory -Force $STAGE | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'inject.js'), (Join-Path $PSScriptRoot 'tps_stats_server.py') $STAGE -Force
$srv = Join-Path $STAGE 'tps_stats_server.py'

function Test-ServerUp {
    try { return ((Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 'http://127.0.0.1:3117/healthz').Content -eq 'ok') }
    catch { return $false }
}

if (-not $DryRun) {
    # ---------- 2) 数据服务：开机自启 + 立即拉起 ----------
    # 已有旧版服务在跑则先停（用新文件重启，保证升级生效）
    try {
        Get-NetTCPConnection -LocalPort 3117 -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
            $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -like 'python*') { Stop-Process -Id $proc.Id -Force }
        }
        Start-Sleep -Milliseconds 500
    } catch {}
    # pythonw 无控制台，经 cmd shim 把 stdout/stderr 重定向到 server.log（与 macOS launchd 行为对齐）
    $shim = Join-Path $STAGE 'start-server.cmd'
    $log  = Join-Path $STAGE 'server.log'
    $shimText = "@echo off`r`nchcp 65001 >nul`r`n`"$pyw`" `"$srv`" >> `"$log`" 2>&1`r`n"
    [System.IO.File]::WriteAllText($shim, $shimText, [System.Text.UTF8Encoding]::new($false))

    $regOk = $false
    try {
        $action  = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cmd.exe" -Argument "/c `"$shim`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User ([System.Environment]::UserName)
        Register-ScheduledTask -TaskName $TASK_NAME -Action $action -Trigger $trigger -Force | Out-Null
        $regOk = $true
        Ok "已注册开机自启（任务计划程序：$TASK_NAME）"
    } catch {
        & schtasks /Create /F /TN $TASK_NAME /SC ONLOGON /TR "cmd /c `"`"$shim`"`"" | Out-Null
        if ($LASTEXITCODE -eq 0) { $regOk = $true; Ok "已注册开机自启（schtasks：$TASK_NAME）" }
    }
    if (-not $regOk) {
        # 最后兜底：启动文件夹（VBS 隐藏窗口启动）
        $vbs = Join-Path ([System.Environment]::GetFolderPath('Startup')) 'zcode-tps-footer.vbs'
        $vbsText = 'CreateObject("Wscript.Shell").Run "cmd /c ""{0}""", 0, False' -f $shim
        [System.IO.File]::WriteAllText($vbs, $vbsText, [System.Text.UnicodeEncoding]::new($false, $true))
        Ok "已注册开机自启（启动文件夹：$vbs）"
    }

    if (-not (Test-ServerUp)) {
        Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList "/c", "`"$shim`"" -WindowStyle Hidden
        Start-Sleep -Seconds 2
    }
    if (Test-ServerUp) { Ok "数据服务就绪" } else { Warn "服务未响应（重启系统，或手动运行 $shim 后重试）" }
}

# ---------- 3) 注入 asar（幂等；ZCode 整包更新覆盖后重跑本脚本即可）----------
$MARK   = 'tps-inject/inject.js'
$repack = Join-Path $STAGE 'repack'
New-Item -ItemType Directory -Force $repack | Out-Null
# Windows 下 file URI 必须是三斜杠 + 正斜杠：file:///C:/Users/.../inject.js
$tagSrc = 'file:///' + ((Join-Path $STAGE 'inject.js') -replace '\\', '/')

Push-Location $repack
try {
    # 已注入过？（Windows 版 asar 内路径用反斜杠，extract-file 参数必须一致）
    Remove-Item '.\index.html' -Force -ErrorAction SilentlyContinue
    & npx -y '@electron/asar' extract-file $ASAR 'out\renderer\index.html' | Out-Null
    $already = (Test-Path '.\index.html') -and ((Get-Content '.\index.html' -Raw) -match [regex]::Escape($MARK))
    if ($already) {
        Ok "当前 asar 已含注入标记，无需重打。"
    } else {
        Write-Host "① 解包 ...（约 1-3 分钟）"
        if (Test-Path '.\unpacked') { Remove-Item '.\unpacked' -Recurse -Force }
        & npx -y '@electron/asar' extract $ASAR unpacked
        if ($LASTEXITCODE -ne 0) { throw "asar 解包失败" }
        $html = Join-Path $repack 'unpacked\out\renderer\index.html'
        if (-not (Test-Path $html)) { throw "解包结果里找不到 out\renderer\index.html" }

        Write-Host "② 注入 script 标签 ..."
        # 注意：Windows 版 index.html 的 </head> 前没有缩进（紧跟 link 标签），锚点用裸 </head>
        $s = [System.IO.File]::ReadAllText($html)
        if ($s -notmatch [regex]::Escape($MARK)) {
            $tag = '    <script defer src="{0}"></script>' -f $tagSrc
            $s = [regex]::new('</head>').Replace($s, "$tag`n  </head>", 1)
            [System.IO.File]::WriteAllText($html, $s, [System.Text.UTF8Encoding]::new($false))
        }

        Write-Host "③ 重打包 ..."
        & npx -y '@electron/asar' pack unpacked app.asar.patched --unpack '{**/*.node,**/spawn-helper}'
        if ($LASTEXITCODE -ne 0) { throw "asar 重打包失败" }

        if ($DryRun) {
            Write-Host "[DryRun] 已生成 $repack\app.asar.patched（演练模式：不替换正式包、不装服务）"
        } else {
            Write-Host "④ 备份并替换 ..."
            if (-not (Test-Path "$ASAR.tps-bak")) { Copy-Item $ASAR "$ASAR.tps-bak" }
            Copy-Item '.\app.asar.patched' $ASAR -Force
            if (Test-Path '.\app.asar.patched.unpacked') {
                if (Test-Path "$RES\app.asar.unpacked") { Remove-Item "$RES\app.asar.unpacked" -Recurse -Force }
                Copy-Item '.\app.asar.patched.unpacked' "$RES\app.asar.unpacked" -Recurse -Force
            }
            Ok "注入完成。"
        }
    }
} finally { Pop-Location }

Write-Host ""
if ($DryRun) {
    Write-Host "[DryRun] 演练结束：以上步骤全部通过即代表可正式安装（去掉 -DryRun 重跑）。"
} else {
    Write-Host "🎉 完成！完全退出 ZCode（含托盘图标）再打开，每条回答下方即出现统计行。"
    Write-Host "   回滚：双击 uninstall.bat ｜ ZCode 更新后：重新双击 install.bat 即可"
}
