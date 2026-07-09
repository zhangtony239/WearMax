<#
.SYNOPSIS
    小米手表一代环境自动初始化脚本 (baiji.ps1)
.DESCRIPTION
    一阶段功能：
      1. 检测电脑上是否安装 scrcpy，未安装则提示用户自行下载并加入 PATH。
      2. 遍历第三方应用 (pm list package -3) 并全部 adb uninstall。
      3. 遍历 USELESS_SYS_APPS 列表，逐个 adb shell pm uninstall --user 0。
.NOTES
    需在管理员或普通 PowerShell 中以具备 adb 调试权限的环境运行。
#>

# 修正控制台编码，保证中文输出不乱码
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding           = [System.Text.Encoding]::UTF8
} catch {
    # 忽略编码设置失败
}

#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 全局变量
# ---------------------------------------------------------------------------

# 无用系统应用包名列表 (按需增删)
# 这些通常是小米手表一代中可安全对当前用户禁用的预装系统应用
$USELESS_SYS_APPS = @(
    'com.android.wallpaper.livepicker',     # 动态壁纸选择器 (手表无用)
    'com.android.providers.calendar',       # 日历提供程序
    'com.android.providers.media.modules',  # 媒体模块 (按需)
    'com.miui.calculator',                 # 小米计算器
    'com.miui.notes',                       # 小米便签
    'com.miui.weather2',                    # 小米天气
    'com.miui.personalassistant',           # 智能助理 / 负一屏
    'com.miui.analytics',                   # 小米用户体验计划
    'com.xiaomi.market',                    # 应用商店 (手表端)
    'com.xiaomi.simactivate.service'        # SIM 激活服务 (手表多无 SIM)
)

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO]  $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[OK]    $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN]  $Message" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

# 检测某个可执行程序是否在 PATH 中可用
function Test-CommandAvailable {
    param([string]$Name)
    $cmd = Get-Command -Name $Name -ErrorAction SilentlyContinue
    return $null -ne $cmd
}

# ---------------------------------------------------------------------------
# 阶段 1: 环境依赖检测 (scrcpy / adb)
# ---------------------------------------------------------------------------

function Test-Scrcpy {
    Write-Info '检测 scrcpy 是否已安装...'
    if (Test-CommandAvailable -Name 'scrcpy') {
        $scrcpyCmd = Get-Command -Name 'scrcpy' -ErrorAction SilentlyContinue
        Write-Ok "已检测到 scrcpy: $($scrcpyCmd.Source)"
        return $true
    }

    Write-Warn '未检测到 scrcpy。'
    Write-Host ''
    Write-Host '请自行下载并安装 scrcpy，并将其所在目录加入系统 PATH 环境变量。' -ForegroundColor Yellow
    Write-Host '  项目主页: https://github.com/Genymobile/scrcpy' -ForegroundColor Yellow
    Write-Host '  Windows 版本下载解压后，将解压目录添加到 PATH 即可。' -ForegroundColor Yellow
    Write-Host '  安装完成后请重新打开终端，再次运行本脚本。' -ForegroundColor Yellow
    Write-Host ''
    return $false
}

# 确认已连接的小米手表设备
function Confirm-Device {
    Write-Info '检测已连接的 adb 设备...'
    $devices = (& adb devices) | Where-Object { $_ -match '\bdevice\b' }

    if ($null -eq $devices -or $devices.Count -eq 0) {
        Write-Err '未检测到处于 "device" 状态的设备。'
        Write-Host '请确认: 1) 手表已通过 USB/蓝牙连接; 2) 已开启开发者选项与 USB 调试; 3) 已在手表上授权此电脑。' -ForegroundColor Yellow
        return $false
    }

    Write-Ok "检测到 $($devices.Count) 台设备:"
    $devices | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
    return $true
}

# ---------------------------------------------------------------------------
# 阶段 2: 卸载所有第三方应用 (pm list package -3)
# ---------------------------------------------------------------------------

function Uninstall-ThirdPartyApps {
    Write-Info '枚举第三方应用 (pm list package -3)...'

    $rawLines = & adb shell pm list package -3
    if ($LASTEXITCODE -ne 0) {
        Write-Err '执行 "adb shell pm list package -3" 失败。'
        return
    }

    # 解析出包名 (行格式: package:com.xxx.xxx)
    $packages = $rawLines |
        Where-Object { $_ -match '^package:' } |
        ForEach-Object { ($_ -replace '^package:', '').Trim() }

    if ($packages.Count -eq 0) {
        Write-Ok '没有第三方应用需要卸载。'
        return
    }

    Write-Info "共发现 $($packages.Count) 个第三方应用，开始卸载..."
    $success = 0
    $failed  = 0

    foreach ($pkg in $packages) {
        Write-Host "  -> 卸载: $pkg" -NoNewline
        & adb uninstall $pkg *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Host '  [成功]' -ForegroundColor Green
            $success++
        } else {
            Write-Host '  [失败]' -ForegroundColor Red
            $failed++
        }
    }

    Write-Ok "第三方应用卸载完成: 成功 $success / 失败 $failed / 总计 $($packages.Count)。"
}

# ---------------------------------------------------------------------------
# 阶段 3: 卸载无用系统应用 (pm uninstall --user 0)
# ---------------------------------------------------------------------------

function Uninstall-UselessSysApps {
    param([string[]]$Apps)

    if ($null -eq $Apps -or $Apps.Count -eq 0) {
        Write-Warn 'USELESS_SYS_APPS 列表为空，跳过系统应用卸载。'
        return
    }

    Write-Info "开始卸载无用系统应用，共 $($Apps.Count) 个 (使用 --user 0，不影响其它用户)..."
    $success = 0
    $failed  = 0
    $skipped = 0

    foreach ($pkg in $Apps) {
        $pkg = $pkg.Trim()
        if ([string]::IsNullOrWhiteSpace($pkg)) { continue }

        Write-Host "  -> 卸载: $pkg" -NoNewline
        $output = & adb shell pm uninstall --user 0 $pkg 2>&1
        $outText = ($output | Out-String).Trim()

        if ($outText -match 'Success') {
            Write-Host '  [成功]' -ForegroundColor Green
            $success++
        } elseif ($outText -match 'Not installed|Unknown package|Failed') {
            # 设备上不存在该包或已卸载，视为跳过
            Write-Host '  [跳过]' -ForegroundColor DarkGray
            $skipped++
        } else {
            Write-Host "  [失败] $outText" -ForegroundColor Red
            $failed++
        }
    }

    Write-Ok "系统应用卸载完成: 成功 $success / 失败 $failed / 跳过 $skipped / 总计 $($Apps.Count)。"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

function Main {
    Write-Host ''
    Write-Host '================================================' -ForegroundColor White
    Write-Host '  小米手表一代 环境自动初始化脚本 (baiji.ps1)' -ForegroundColor White
    Write-Host '  阶段一: 依赖检测 / 第三方应用卸载 / 系统精简'   -ForegroundColor White
    Write-Host '================================================' -ForegroundColor White
    Write-Host ''

    # 1) 依赖检测
    if (-not (Test-Scrcpy)) {
        Write-Err '缺少 scrcpy，终止流程。'
        exit 1
    }
    if (-not (Confirm-Device)) {
        Write-Err '没有可用设备，终止流程。'
        exit 1
    }

    # 2) 卸载所有第三方应用
    Uninstall-ThirdPartyApps

    # 3) 卸载无用系统应用
    Uninstall-UselessSysApps -Apps $USELESS_SYS_APPS

    Write-Host ''
    Write-Ok '阶段一初始化全部完成。'
    Write-Host ''
}

Main
