<#
.SYNOPSIS
    WearMax 安装资源准备脚本 (install.ps1)
.DESCRIPTION
    两阶段功能：
      阶段一 (资源准备):
        1. 创建缓存目录 .install/ (相对脚本所在目录, 避免污染项目根)。
        2. 通过 GitHub Releases API 解析各仓库的最新版本 (latest),
           下载以下三个资源 (版本号由 latest 动态解析, 不再硬编码)：
             - zeroclaw   : zhangtony239/zeroclaw 的 armv7 android 二进制 (tar.gz)
             - termux-app : termux/termux-app 的 debug armeabi-v7a APK
             - termux-api : termux/termux-api 的 debug APK
        3. 解压 zeroclaw 的 tar.gz, 仅保留其中的 zeroclaw 二进制文件 (随后删除压缩包)。
      阶段二 (adb 部署到手表):
        4. 检测 adb 与已连接设备, 安装两个 Termux APK (termux-app / termux-api)。
        5. 将 zeroclaw 二进制 adb push 到手表 /sdcard/ 下。
        6. 将项目内 termux/ 文件夹下的全部内容 adb push 到手表 /sdcard/ 下。
        7. 提示用户自行跟随 setup.md 在手表 Termux 内完成 zeroclaw 配置。
        8. 部署完成后清理本地缓存目录 .install/ (释放磁盘空间, 避免污染项目根)。
.NOTES
    需在 PowerShell 5.1+ 运行; Windows 10 (1803+) / Windows 11 自带 tar.exe 用于解压 tar.gz。
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

# 强制 TLS 1.2 (PowerShell 5.1 默认可能较低, GitHub API 要求 TLS 1.2+)
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
    # 忽略
}

# ---------------------------------------------------------------------------
# 全局变量
# ---------------------------------------------------------------------------

# 缓存目录 (相对脚本所在目录)
$CacheDir = Join-Path $PSScriptRoot '.install'

# 项目内 termux 配置目录 (相对脚本所在目录)
$TermuxDir = Join-Path $PSScriptRoot 'termux'

# 资源清单: AssetMatch 为资产名正则 (版本号部分用 .* 通配, 实现 "latest" 动态解析)
$Resources = @(
    [pscustomobject]@{
        Name        = 'zeroclaw'
        Repo        = 'zhangtony239/zeroclaw'
        AssetMatch  = '^zeroclaw-armv7-linux-androideabi\.tar\.gz$'
        IsArchive   = $true
        ExtractName = 'zeroclaw'
    }
    [pscustomobject]@{
        Name        = 'termux-app'
        Repo        = 'termux/termux-app'
        AssetMatch  = '^termux-app_v.*debug_armeabi-v7a\.apk$'
        IsArchive   = $false
        ExtractName = $null
    }
    [pscustomobject]@{
        Name        = 'termux-api'
        Repo        = 'termux/termux-api'
        AssetMatch  = '^termux-api-app_v.*debug\.apk$'
        IsArchive   = $false
        ExtractName = $null
    }
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

# 调用 GitHub API 获取仓库的最新 release 对象 (含 tag_name 与 assets)
function Resolve-LatestRelease {
    param([string]$Repo)
    $apiUrl = "https://api.github.com/repos/$Repo/releases/latest"
    try {
        $release = Invoke-RestMethod -Uri $apiUrl -Headers @{ 'User-Agent' = 'WearMax-installer' } -ErrorAction Stop
    } catch {
        Write-Err "获取 $Repo 的最新版本失败: $($_.Exception.Message)"
        return $null
    }
    return $release
}

# 在 release 的资产中按正则匹配目标文件, 返回单个 asset 对象
function Find-ReleaseAsset {
    param($Release, [string]$Pattern, [string]$ResourceName)

    # 用 @(...) 强制数组上下文, 避免单条结果在 StrictMode 下 .Count 报错
    $hits = @($Release.assets | Where-Object { $_.name -match $Pattern })
    if ($null -eq $hits -or $hits.Count -eq 0) {
        Write-Err "在版本 $($Release.tag_name) 的资产中未找到匹配 '$Pattern' 的文件 ($ResourceName)。"
        Write-Host '  该 release 可用资产:' -ForegroundColor DarkGray
        foreach ($a in $Release.assets) {
            Write-Host "    $($a.name)" -ForegroundColor DarkGray
        }
        return $null
    }
    if ($hits.Count -gt 1) {
        Write-Warn "匹配 '$Pattern' 的资产有 $($hits.Count) 个, 将使用第一个: $($hits[0].name)"
    }
    return $hits[0]
}

# 下载文件 (禁用进度条以提升 Invoke-WebRequest 在 PS 5.1 下的传输速度)
function Invoke-FileDownload {
    param([string]$Url, [string]$Destination)
    $previous = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -ErrorAction Stop
    } finally {
        $ProgressPreference = $previous
    }
}

# 解压 zeroclaw 的 tar.gz, 仅保留其中的 zeroclaw 二进制 (随后删除压缩包)
function Expand-ZeroclawArchive {
    param([string]$Archive, [string]$DestinationDir, [string]$ExtractName)

    $tempDir = Join-Path $DestinationDir ('_extract_' + [Guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        # 使用系统自带 tar.exe 解压; -z 自动处理 gzip
        & tar -xzf $Archive -C $tempDir
        if ($LASTEXITCODE -ne 0) {
            Write-Err "解压失败 (tar 退出码 $LASTEXITCODE): $Archive"
            return $false
        }

        # 在解压结果中递归查找目标二进制 (兼容归档内存在子目录的情况)
        $found = Get-ChildItem -Path $tempDir -Recurse -Filter $ExtractName | Select-Object -First 1
        if ($null -eq $found) {
            Write-Err "解压后未在归档中找到文件 '$ExtractName'。"
            Write-Host '  归档内容:' -ForegroundColor DarkGray
            Get-ChildItem -Path $tempDir -Recurse | ForEach-Object {
                Write-Host "    $($_.FullName.Substring($tempDir.Length))" -ForegroundColor DarkGray
            }
            return $false
        }

        # 仅保留目标二进制, 删除原始压缩包
        $target = Join-Path $DestinationDir $ExtractName
        Copy-Item -Path $found.FullName -Destination $target -Force
        Remove-Item -Path $Archive -Force
        return $true
    } finally {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -Path $tempDir -Recurse -Force
        }
    }
}

# ---------------------------------------------------------------------------
# adb 部署相关工具函数
# ---------------------------------------------------------------------------

# 统一执行 adb 命令的 helper:
#   - 局部降级 ErrorActionPreference 为 Continue, 避免 PS5.1 在 Stop 模式下
#     把 adb 写入 stderr 的进度/提示信息当作 NativeCommandError 终止脚本。
#   - 用 2>&1 合并 stderr, 逐行回显给用户, 仍可正常检查 $LASTEXITCODE。
function Invoke-AdbCommand {
    param([parameter(ValueFromRemainingArguments = $true)][string[]]$Args)

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # 将 stderr 合并到 stdout 后捕获为对象数组, 逐行回显
        $output = & adb @Args 2>&1
        foreach ($line in $output) {
            if ($null -ne $line) {
                Write-Host "  $line" -ForegroundColor DarkGray
            }
        }
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    return $LASTEXITCODE
}

# 获取已就绪 (state=device) 的 adb 设备 id 列表; 排除 unauthorized/offline
function Get-AdbDevices {
    # 局部降级 ErrorActionPreference, 避免 PS5.1 在 Stop 模式下把 adb 写入
    # stderr 的 daemon 启动信息当作 NativeCommandError 终止脚本。
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & adb devices 2>&1
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    $devices = @()
    foreach ($line in $output) {
        if ($line -is [string]) {
            $text = $line
        } else {
            $text = $line.ToString()
        }
        $text = $text.Trim()
        if ($text -eq '' -or $text -match 'List of devices attached') { continue }
        $parts = $text -split '\s+' | Where-Object { $_ -ne '' }
        if ($parts.Count -ge 2 -and $parts[1] -eq 'device') {
            $devices += $parts[0]
        }
    }
    return $devices
}

# 通过 adb 安装 apk (-r 覆盖已安装的同名包)
function Install-Apk {
    param([string]$ApkPath)
    if (-not (Test-Path -LiteralPath $ApkPath)) {
        Write-Err "APK 文件不存在: $ApkPath"
        return $false
    }
    $code = Invoke-AdbCommand install -r "$ApkPath"
    if ($code -ne 0) {
        Write-Err "adb install 失败 (退出码 $code): $ApkPath"
        return $false
    }
    Write-Ok "  安装成功: $ApkPath"
    return $true
}

# 通过 adb 推送本地单个文件到设备
function Push-File {
    param([string]$LocalPath, [string]$RemotePath)
    if (-not (Test-Path -LiteralPath $LocalPath)) {
        Write-Err "本地文件不存在: $LocalPath"
        return $false
    }
    $code = Invoke-AdbCommand push "$LocalPath" "$RemotePath"
    if ($code -ne 0) {
        Write-Err "adb push 失败 (退出码 $code): $LocalPath -> $RemotePath"
        return $false
    }
    Write-Ok "  推送成功: $LocalPath -> $RemotePath"
    return $true
}

# 递归推送本地目录下全部内容到设备指定目录 (保持相对子目录结构)
# LocalDir  : 本地源目录 (如 .\termux)
# RemoteDir : 设备目标目录 (如 /sdcard/); 尾部无需带斜杠
function Push-Directory {
    param([string]$LocalDir, [string]$RemoteDir)

    if (-not (Test-Path -LiteralPath $LocalDir)) {
        Write-Err "本地目录不存在: $LocalDir"
        return $false
    }

    # 收集所有文件 (含子目录), 用平铺列表逐个推送
    # 用 @(...) 强制数组上下文, 避免单文件/空结果在 StrictMode 下 .Count 报错
    $files = @(Get-ChildItem -Path $LocalDir -Recurse -File)
    if ($null -eq $files -or $files.Count -eq 0) {
        Write-Warn "本地目录为空, 跳过推送: $LocalDir"
        return $true
    }

    # adb push 单个文件时可自动创建设备端所需的父目录, 因此无需提前 mkdir
    $ok = $true
    foreach ($f in $files) {
        # 计算文件相对本地根目录的相对路径 (用正斜杠, 兼容 adb 远端路径)
        $rel = $f.FullName.Substring($LocalDir.Length).TrimStart('\','/') -replace '\\','/'
        $remotePath = "$RemoteDir/$rel"
        Write-Info "推送 $($f.FullName) -> $remotePath"
        $code = Invoke-AdbCommand push "$($f.FullName)" "$remotePath"
        if ($code -ne 0) {
            Write-Err "  推送失败 (退出码 $code): $($f.FullName) -> $remotePath"
            $ok = $false
        }
    }
    if ($ok) {
        Write-Ok "  目录推送完成: $LocalDir -> $RemoteDir"
    }
    return $ok
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

function Main {
    Write-Host ''
    Write-Host '================================================' -ForegroundColor White
    Write-Host '  WearMax 安装资源准备脚本 (install.ps1)' -ForegroundColor White
    Write-Host '  解析 latest 版本 / 下载资源 / 解压 zeroclaw' -ForegroundColor White
    Write-Host '================================================' -ForegroundColor White
    Write-Host ''

    # 1) 创建缓存目录
    if (-not (Test-Path -LiteralPath $CacheDir)) {
        New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
        Write-Ok "已创建缓存目录: $CacheDir"
    } else {
        Write-Ok "缓存目录已存在: $CacheDir"
    }

    # 2) 依赖检测: tar.exe (用于解压 zeroclaw tar.gz)
    if (-not (Test-CommandAvailable -Name 'tar')) {
        Write-Err '未检测到 tar.exe, 无法解压 zeroclaw 归档。'
        Write-Host '  Windows 10 (1803+) / Windows 11 自带 tar.exe; 请确认系统环境。' -ForegroundColor Yellow
        exit 1
    }

    # 3) 逐个解析 latest 并下载
    $success = 0
    $failed  = 0
    $LocalPaths = @{}   # 记录各资源最终本地路径, 供阶段二 adb 部署使用

    foreach ($r in $Resources) {
        Write-Info "处理 [$($r.Name)] ($($r.Repo))..."

        $release = Resolve-LatestRelease -Repo $r.Repo
        if ($null -eq $release) {
            $failed++
            continue
        }
        Write-Host "  最新版本: $($release.tag_name)" -ForegroundColor Gray

        $asset = Find-ReleaseAsset -Release $release -Pattern $r.AssetMatch -ResourceName $r.Name
        if ($null -eq $asset) {
            $failed++
            continue
        }

        $dest = Join-Path $CacheDir $asset.name
        Write-Info "  下载 $($asset.name) ..."
        try {
            Invoke-FileDownload -Url $asset.browser_download_url -Destination $dest
        } catch {
            Write-Err "下载失败: $($_.Exception.Message)"
            $failed++
            continue
        }
        Write-Ok "  已保存: $dest"

        # 4) zeroclaw 需解压并仅保留二进制
        $finalPath = $dest
        if ($r.IsArchive) {
            $ok = Expand-ZeroclawArchive -Archive $dest -DestinationDir $CacheDir -ExtractName $r.ExtractName
            if (-not $ok) {
                $failed++
                continue
            }
            $finalPath = Join-Path $CacheDir $r.ExtractName
            Write-Ok "  已解压并仅保留: $finalPath"
        }

        # 记录最终本地路径, 供阶段二 adb 部署使用
        $LocalPaths[$r.Name] = $finalPath
        $success++
    }

    Write-Host ''
    Write-Ok "资源准备完成: 成功 $success / 失败 $failed / 总计 $($Resources.Count)。"
    if ($failed -gt 0) {
        exit 1
    }

    # ===================================================================
    # 阶段二: 通过 adb 将资源部署到手表
    # ===================================================================
    Write-Host ''
    Write-Host '================================================' -ForegroundColor White
    Write-Host '  阶段二: 通过 adb 部署到手表' -ForegroundColor White
    Write-Host '  (安装 Termux APK / 推送 zeroclaw 与手表侧脚本)' -ForegroundColor White
    Write-Host '================================================' -ForegroundColor White
    Write-Host ''

    # 1) 启动 adb server 并检测已连接设备
    Write-Info '启动 adb server 并检测已连接设备...'
    # 用统一 helper 降级 ErrorActionPreference, 避免 adb stderr 触发终止错误
    Invoke-AdbCommand start-server | Out-Null
    # 用 @(...) 强制数组上下文, 避免单设备/空结果在 StrictMode 下 .Count 报错
    $devices = @(Get-AdbDevices)
    if ($devices.Count -eq 0) {
        Write-Err '未检测到就绪的 Android 设备。'
        Write-Host '  请确认:' -ForegroundColor Yellow
        Write-Host '    1. 手表已通过 USB 连接 (或在同一局域网下使用无线调试)。' -ForegroundColor Yellow
        Write-Host '    2. 手表已开启 开发者选项 -> USB 调试。' -ForegroundColor Yellow
        Write-Host '    3. 手表上已授权此计算机 (留意手表屏幕的 USB 调试授权弹窗)。' -ForegroundColor Yellow
        exit 1
    }
    Write-Ok "检测到 $($devices.Count) 台就绪设备: $($devices -join ', ')"

    # 2) 安装 termux-app (主程序, 先装)
    $termuxAppApk = $LocalPaths['termux-app']
    Write-Info "安装 termux-app: $termuxAppApk"
    if (-not (Install-Apk -ApkPath $termuxAppApk)) {
        exit 1
    }

    # 3) 安装 termux-api (依赖 termux-app, 后装)
    $termuxApiApk = $LocalPaths['termux-api']
    Write-Info "安装 termux-api: $termuxApiApk"
    if (-not (Install-Apk -ApkPath $termuxApiApk)) {
        exit 1
    }

    # 4) 推送 zeroclaw 二进制到手表 /sdcard/
    $zeroclawBin = $LocalPaths['zeroclaw']
    $remotePath  = '/sdcard/zeroclaw'
    Write-Info "推送 zeroclaw 到手表: $zeroclawBin -> $remotePath"
    if (-not (Push-File -LocalPath $zeroclawBin -RemotePath $remotePath)) {
        exit 1
    }

    # 5) 推送 termux/ 目录下全部内容到手表 /sdcard/
    Write-Info "推送手表侧脚本目录: $TermuxDir -> /sdcard/"
    if (-not (Push-Directory -LocalDir $TermuxDir -RemoteDir '/sdcard')) {
        exit 1
    }

    # ===================================================================
    # 清理本地缓存目录 .install/
    # ===================================================================
    Write-Host ''
    Write-Info '清理本地缓存目录...'
    if (Test-Path -LiteralPath $CacheDir) {
        try {
            Remove-Item -Path $CacheDir -Recurse -Force -ErrorAction Stop
            Write-Ok "已删除缓存目录: $CacheDir"
        } catch {
            Write-Warn "清理缓存目录失败, 可手动删除: $CacheDir"
            Write-Host "  原因: $($_.Exception.Message)" -ForegroundColor DarkGray
        }
    } else {
        Write-Ok "缓存目录已不存在, 无需清理: $CacheDir"
    }

    # ===================================================================
    # 完成: 引导用户进入下一阶段
    # ===================================================================
    Write-Host ''
    Write-Ok 'WearMax 电脑侧安装阶段全部完成。'
    Write-Host ''
    Write-Host '下一步操作 (请在手表上完成):' -ForegroundColor White
    Write-Host '  1. 在手表上打开 Termux 应用。' -ForegroundColor White
    Write-Host '  2. 请自行跟随 setup.md 文档, 完成 Termux 内的 zeroclaw 配置。' -ForegroundColor White
    Write-Host ''
}

Main
