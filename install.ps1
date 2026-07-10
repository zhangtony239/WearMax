<#
.SYNOPSIS
    WearMax 安装资源准备脚本 (install.ps1)
.DESCRIPTION
    一阶段功能：
      1. 创建缓存目录 .install/ (相对脚本所在目录, 避免污染项目根)。
      2. 通过 GitHub Releases API 解析各仓库的最新版本 (latest),
         下载以下三个资源 (版本号由 latest 动态解析, 不再硬编码)：
           - zeroclaw   : zhangtony239/zeroclaw 的 armv7 android 二进制 (tar.gz)
           - termux-app : termux/termux-app 的 debug armeabi-v7a APK
           - termux-api : termux/termux-api 的 debug APK
      3. 解压 zeroclaw 的 tar.gz, 仅保留其中的 zeroclaw 二进制文件 (随后删除压缩包)。
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
        if ($r.IsArchive) {
            $ok = Expand-ZeroclawArchive -Archive $dest -DestinationDir $CacheDir -ExtractName $r.ExtractName
            if (-not $ok) {
                $failed++
                continue
            }
            Write-Ok "  已解压并仅保留: $(Join-Path $CacheDir $r.ExtractName)"
        }

        $success++
    }

    Write-Host ''
    Write-Ok "资源准备完成: 成功 $success / 失败 $failed / 总计 $($Resources.Count)。"
    if ($failed -gt 0) {
        exit 1
    }
}

Main
