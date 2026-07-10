<#
.SYNOPSIS
    WearMax 表盘图片更新脚本 (update-watchface.ps1)
.DESCRIPTION
    通过 adb 更新手表表盘图片, 流程:
      1. 用 adb shell wm size 获取手表屏幕分辨率 (宽 x 高)。
      2. 提示用户拖入与屏幕分辨率相同的图片 (支持 png/jpg/jpeg/bmp/gif)。
      3. 校验图片像素尺寸与屏幕分辨率是否一致。
      4. adb shell rm 清空 /sdcard/Pictures/watchface/ 下的旧图片。
      5. adb push 将新图片推送至 /sdcard/Pictures/watchface/。
.NOTES
    需在 PowerShell 5.1+ 运行; 依赖 adb 与已连接的手表设备。
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

# 读取图片尺寸需要 System.Drawing
try {
    Add-Type -AssemblyName System.Drawing
} catch {
    Write-Host "[ERROR] 无法加载 System.Drawing 程序集: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

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

# 统一执行 adb 命令:
#   - 局部降级 ErrorActionPreference 为 Continue, 避免 PS5.1 在 Stop 模式下
#     把 adb 写入 stderr 的进度/提示信息当作 NativeCommandError 终止脚本。
#   - 用 2>&1 合并 stderr, 逐行回显给用户, 并返回结构化结果 (ExitCode + Output)。
function Invoke-AdbCommand {
    param([parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = $null
    $code = 1
    try {
        $output = & adb @Arguments 2>&1
        $code = $LASTEXITCODE
        foreach ($line in $output) {
            if ($null -ne $line) {
                Write-Host "  $line" -ForegroundColor DarkGray
            }
        }
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    return [pscustomobject]@{ ExitCode = $code; Output = $output }
}

# 检测 adb 是否可用且至少有一台处于 device 状态的设备连接
function Test-AdbDevice {
    if (-not (Test-CommandAvailable -Name 'adb')) {
        Write-Err '未检测到 adb, 请先安装 platform-tools 并加入 PATH。'
        return $false
    }
    $r = Invoke-AdbCommand 'devices'
    if ($r.ExitCode -ne 0) {
        Write-Err "adb devices 执行失败 (退出码 $($r.ExitCode))。"
        return $false
    }
    # adb devices 输出形如:  <serial><空白>device  (状态为 device 表示就绪)
    $deviceLines = @($r.Output | Where-Object { "$_" -match '^\S+\s+device\s*$' })
    if ($deviceLines.Count -eq 0) {
        Write-Err '未检测到就绪设备, 请确认手表已通过 USB/无线 adb 连接并授权 (状态应为 device)。'
        return $false
    }
    return $true
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

Write-Host '=== WearMax 表盘更新 ===' -ForegroundColor Cyan
Write-Host ''

if (-not (Test-AdbDevice)) {
    exit 1
}

# 1. 获取屏幕分辨率
Write-Info '获取屏幕分辨率...'
$r = Invoke-AdbCommand 'shell' 'wm' 'size'
if ($r.ExitCode -ne 0) {
    Write-Err "adb shell wm size 执行失败 (退出码 $($r.ExitCode))。"
    exit 1
}

# 将输出 (可能含 ErrorRecord) 统一转为文本以便正则解析
$sizeText = ($r.Output | ForEach-Object { "$_" }) -join "`n"
$physical = [regex]::Match($sizeText, 'Physical size:\s*(\d+)\s*x\s*(\d+)')
$override = [regex]::Match($sizeText, 'Override size:\s*(\d+)\s*x\s*(\d+)')

$screenW = 0
$screenH = 0
if ($override.Success) {
    # 若存在软件覆盖分辨率, 以实际生效的为准
    $screenW = [int]$override.Groups[1].Value
    $screenH = [int]$override.Groups[2].Value
    Write-Warn "检测到 Override size, 将以覆盖后的分辨率为准: ${screenW}x${screenH}"
} elseif ($physical.Success) {
    $screenW = [int]$physical.Groups[1].Value
    $screenH = [int]$physical.Groups[2].Value
} else {
    Write-Err '无法从 wm size 输出中解析分辨率, 原始输出:'
    Write-Host $sizeText -ForegroundColor DarkGray
    exit 1
}

Write-Host ''

# 2. 提示用户拖入图片
Write-Info "请将一张 ${screenW}x${screenH} 像素的图片拖入本窗口 (或粘贴其完整路径), 然后按回车:"
$imagePath = Read-Host '图片路径'
# 去除拖入时可能带上的首尾引号与多余空白
$imagePath = $imagePath.Trim('"').Trim()
if ([string]::IsNullOrWhiteSpace($imagePath)) {
    Write-Err '未提供图片路径。'
    exit 1
}
if (-not (Test-Path -LiteralPath $imagePath -PathType Leaf)) {
    Write-Err "图片文件不存在: $imagePath"
    exit 1
}

# 3. 校验图片尺寸
$img = $null
$imgW = 0
$imgH = 0
try {
    $fullPath = (Get-Item -LiteralPath $imagePath).FullName
    $img = [System.Drawing.Image]::FromFile($fullPath)
    $imgW = $img.Width
    $imgH = $img.Height
} catch {
    Write-Err "无法读取图片尺寸, 该文件可能不是受支持的图片格式: $($_.Exception.Message)"
    exit 1
} finally {
    if ($null -ne $img) { $img.Dispose() }
}

Write-Ok "图片尺寸: ${imgW} x ${imgH}"

if ($imgW -ne $screenW -or $imgH -ne $screenH) {
    Write-Warn "图片尺寸 ${imgW}x${imgH} 与屏幕分辨率 ${screenW}x${screenH} 不一致, 可能导致显示拉伸/留白/不生效。"
    $confirm = Read-Host '是否仍然继续? (y/N)'
    if ($confirm -notmatch '^\s*[yY]') {
        Write-Err '已取消。'
        exit 1
    }
}

# 4. 清空旧表盘
Write-Info '清空旧表盘...'
# 先确保目录存在, 避免空目录 glob 失败
$null = Invoke-AdbCommand 'shell' 'mkdir' '-p' '/sdcard/Pictures/watchface'
$r = Invoke-AdbCommand 'shell' 'rm' '-f' '/sdcard/Pictures/watchface/*'
if ($r.ExitCode -ne 0) {
    Write-Warn "清空旧表盘时返回非零退出码 ($($r.ExitCode)), 已继续。"
} else {
    Write-Ok '已清空旧表盘。'
}

# 5. 推送新图片
$fileName = Split-Path $imagePath -Leaf
Write-Info "推送图片: $fileName -> /sdcard/Pictures/watchface/ ..."
$r = Invoke-AdbCommand 'push' $imagePath '/sdcard/Pictures/watchface/'
if ($r.ExitCode -ne 0) {
    Write-Err "推送图片失败 (退出码 $($r.ExitCode))。"
    exit 1
}

Write-Ok "表盘已更新: $fileName -> /sdcard/Pictures/watchface/$fileName"
