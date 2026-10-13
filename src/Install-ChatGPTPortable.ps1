#Requires -Version 5.1

<#
.SYNOPSIS
下载官方 ChatGPT 包，配置当前用户的免安装启动入口。

.DESCRIPTION
使用 Windows PowerShell 5.1 和系统 curl.exe。验证官方签名、包标识和原始
应用文件后，创建启动入口及可选快捷方式。无需管理员权限，不注册 MSIX，
不安装系统服务。登录和对话仍需联网。

.PARAMETER StorageRoot
保存下载包、程序和用户配置的目录。默认复用已有目录；首次使用保存到
LocalAppData\ChatGPT-NoAdmin。相对路径按调用者的工作目录解析。

.PARAMETER Architecture
系统架构：auto 自动识别，或指定 x64、arm64。

.PARAMETER PackagePath
使用已下载的官方 MSIX，不检查在线版本；仍进行签名和清单校验。

.PARAMETER ForceDownload
重新下载官方包，不复用缓存；不能与 PackagePath 同时使用。

.PARAMETER NoShortcuts
只配置启动文件，不创建桌面和开始菜单快捷方式。

.PARAMETER Launch
配置成功后启动应用。切换版本前，请先退出正在运行的旧实例。

.PARAMETER KeepOldVersions
保留旧版本。默认清理未运行的完整旧版本，保留运行中的版本和用户数据。

.PARAMETER SignatureTimeoutSeconds
每次签名验证的超时时间，默认 180 秒。

.PARAMETER OutputJson
额外输出完整配置 JSON，供诊断使用；默认只显示中文提示。

.PARAMETER Help
显示参数帮助，不下载或配置应用。

.EXAMPLE
.\install.cmd -Launch
检查官方最新版本，完成免安装配置并启动 ChatGPT。

.EXAMPLE
.\install.cmd -StorageRoot ".\app-data" -NoShortcuts
使用指定保存目录，不创建快捷方式。

.EXAMPLE
.\install.cmd -PackagePath ".\ChatGPT-x64.msix" -NoShortcuts
使用已下载的官方包，不检查在线版本。

.EXAMPLE
.\install.cmd -Help
查看完整参数和使用示例。
#>
[CmdletBinding()]
param(
    [string]$StorageRoot,
    [ValidateSet('auto', 'x64', 'arm64')][string]$Architecture = 'auto',
    [string]$PackagePath,
    [switch]$ForceDownload,
    [switch]$NoShortcuts,
    [switch]$Launch,
    [switch]$KeepOldVersions,
    [ValidateRange(10, 1800)][int]$SignatureTimeoutSeconds = 180,
    [switch]$OutputJson,
    [switch]$Help
)

if ($Help) {
    Get-Help -Name $PSCommandPath -Detailed
    return
}

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Resolve-FileSystemPath {
    param([string]$Path)
    $pathProvider = $null
    $pathDrive = $null
    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $Path, [ref]$pathProvider, [ref]$pathDrive)
    if ($pathProvider.Name -ne 'FileSystem') { throw '请指定本地文件或文件夹路径。' }
    return [IO.Path]::GetFullPath($resolvedPath)
}

function Test-PortableInstallation {
    param([string]$Path)
    try {
        $state = Get-Content -LiteralPath (Join-Path $Path 'active.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        return $state.Mode -eq 'Portable' -and $state.PackageVersion -match '^\d+\.\d+\.\d+\.\d+$' -and
            $state.Architecture -in @('x64', 'arm64') -and $state.SHA256 -match '^[a-fA-F0-9]{64}$' -and
            (Test-Path -LiteralPath (Join-Path $Path 'versions') -PathType Container) -and
            (Test-Path -LiteralPath (Join-Path $Path 'Start-ChatGPT.cmd') -PathType Leaf)
    } catch { return $false }
}

function Get-ShortcutStorageRoots {
    param([string[]]$ShortcutPaths)
    try {
        $shell = New-Object -ComObject WScript.Shell
        foreach ($path in $ShortcutPaths) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            $target = $shell.CreateShortcut($path).TargetPath
            if ($target -notmatch '(?i)[\\/]versions[\\/][^\\/]+[\\/]app[\\/]ChatGPT\.exe$') { continue }
            $root = $target
            for ($index = 0; $index -lt 4; $index++) { $root = [IO.Path]::GetDirectoryName($root) }
            if (-not [string]::IsNullOrEmpty($root)) { $root }
        }
    } catch { Write-Warning '无法读取已有快捷方式，正在检查其他保存位置。' }
}

function Get-PortableStorageRoot {
    param([string]$RequestedRoot, [string]$DefaultRoot, [string]$LegacyRoot, [string[]]$ShortcutRoots = @())
    if (-not [string]::IsNullOrWhiteSpace($RequestedRoot)) { return Resolve-FileSystemPath $RequestedRoot }
    $recordPath = Join-Path $DefaultRoot 'storage-root.json'
    $rememberedRoot = $null
    if (Test-Path -LiteralPath $recordPath -PathType Leaf) {
        try {
            $record = Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($record.Mode -eq 'Portable' -and -not [string]::IsNullOrWhiteSpace($record.StorageRoot) -and
                [IO.Path]::IsPathRooted($record.StorageRoot)) {
                $rememberedRoot = Resolve-FileSystemPath $record.StorageRoot
                if (Test-Path -LiteralPath $rememberedRoot -PathType Container) { return $rememberedRoot }
            }
        } catch { Write-Warning '无法读取保存位置记录，正在查找已有免安装配置。' }
    }
    foreach ($candidate in @($ShortcutRoots) + @($LegacyRoot)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-PortableInstallation $candidate)) {
            return Resolve-FileSystemPath $candidate
        }
    }
    if ($null -ne $rememberedRoot) {
        throw "原保存目录不存在：$rememberedRoot。请重新连接该目录，或用 -StorageRoot 指定移动后的路径。"
    }
    return Resolve-FileSystemPath $DefaultRoot
}

function Test-NoReparsePoints {
    param([string]$Path)
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Path)
    while ($pending.Count -gt 0) {
        $item = Get-Item -LiteralPath $pending.Pop() -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        if ($item.PSIsContainer) {
            foreach ($child in Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction Stop) {
                if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
                if ($child.PSIsContainer) { $pending.Push($child.FullName) }
            }
        }
    }
    return $true
}

function Get-RunningChatGPTPaths {
    foreach ($process in Get-Process -ErrorAction Stop) {
        try { $path = $process.Path } catch {
            if ($process.ProcessName -eq 'ChatGPT') { throw '无法确定正在运行的 ChatGPT 的路径。' }
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($path)) { $path }
        elseif ($process.ProcessName -eq 'ChatGPT') { throw '无法确定正在运行的 ChatGPT 的路径。' }
    }
}

function Remove-OldVersions {
    param([string]$StorageRoot, [string]$ActiveVersionDirectory)
    try {
        $root = Resolve-FileSystemPath $StorageRoot
        $versionsRoot = Join-Path $root 'versions'
        $active = Resolve-FileSystemPath $ActiveVersionDirectory
        if ([IO.Path]::GetDirectoryName($active) -ne $versionsRoot -or
            -not (Test-Path -LiteralPath $active -PathType Container)) {
            Write-Warning '已跳过旧版本清理：当前版本不在本保存目录内，或文件夹已不存在。'
            return
        }
        $path = $versionsRoot
        while (-not [string]::IsNullOrEmpty($path)) {
            if (((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Write-Warning '已跳过旧版本清理：保存路径包含目录链接。'
                return
            }
            $parent = [IO.Directory]::GetParent($path)
            $path = $(if ($null -ne $parent) { $parent.FullName } else { $null })
        }
        $runningPaths = @(Get-RunningChatGPTPaths)
        $versionsPrefix = $versionsRoot + [IO.Path]::DirectorySeparatorChar
        foreach ($directory in Get-ChildItem -LiteralPath $versionsRoot -Directory -Force) {
            $candidate = [IO.Path]::GetFullPath($directory.FullName)
            if ($candidate -eq $active) { continue }
            if (-not $candidate.StartsWith($versionsPrefix, [StringComparison]::OrdinalIgnoreCase) -or
                [IO.Path]::GetDirectoryName($candidate) -ne $versionsRoot) { continue }
            if ($directory.Name -notmatch '^\d+\.\d+\.\d+\.\d+-(x64|arm64)-[a-f0-9]{12}$') {
                Write-Warning "保留无法识别的版本目录：$($directory.Name)"
                continue
            }
            try {
                if (-not (Test-NoReparsePoints $candidate)) {
                    Write-Warning "保留包含文件或目录链接的旧版本：$($directory.Name)"
                    continue
                }
                $complete = Get-Content -LiteralPath (Join-Path $candidate 'complete.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($complete.Version -notmatch '^\d+\.\d+\.\d+\.\d+$' -or
                    $complete.Architecture -notin @('x64', 'arm64') -or $complete.SHA256 -notmatch '^[a-fA-F0-9]{64}$') {
                    Write-Warning "保留完成记录无效的旧版本：$($directory.Name)"
                    continue
                }
                $expectedName = $complete.Version + '-' + $complete.Architecture + '-' + $complete.SHA256.Substring(0, 12).ToLowerInvariant()
                if ($directory.Name -ne $expectedName) {
                    Write-Warning "保留完成记录与目录不符的旧版本：$($directory.Name)"
                    continue
                }
                $candidatePrefix = $candidate + [IO.Path]::DirectorySeparatorChar
                $runningPaths = @(Get-RunningChatGPTPaths)
                $inUse = @($runningPaths | Where-Object { $_.StartsWith($candidatePrefix, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
                if ($inUse) {
                    Write-Warning "保留正在运行的版本 $($directory.Name)。退出应用后再次更新即可清理。"
                    continue
                }
                Remove-Item -LiteralPath $candidate -Recurse -Force -ErrorAction Stop
                Write-Host "已清理旧版本：$($directory.Name)"
            } catch { Write-Warning "已保留旧版本 $($directory.Name)：$($_.Exception.Message)" }
        }
    } catch { Write-Warning "已跳过旧版本清理：$($_.Exception.Message)" }
}

function Write-AtomicBytes {
    param([string]$Path, [byte[]]$Bytes)
    $temporaryPath = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllBytes($temporaryPath, $Bytes)
        if ([IO.File]::Exists($Path)) {
            [IO.File]::Replace($temporaryPath, $Path, [Management.Automation.Language.NullString]::Value)
        } else {
            [IO.File]::Move($temporaryPath, $Path)
        }
    } finally {
        if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
    }
}

function Get-BoundedSignature {
    param([string]$Path)
    Write-Host "正在验证签名（最多等待 $SignatureTimeoutSeconds 秒）：$([IO.Path]::GetFileName($Path))"
    $encodedPath = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Path))
    $workerCode = @"
`$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new(`$false)
try {
    `$path = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encodedPath'))
    `$signature = Get-AuthenticodeSignature -LiteralPath `$path
    `$subject = `$null
    `$issuer = `$null
    if (`$null -ne `$signature.SignerCertificate) {
        `$subject = `$signature.SignerCertificate.Subject
        `$issuer = `$signature.SignerCertificate.Issuer
    }
    [Console]::Out.WriteLine(([ordered]@{Status=`$signature.Status.ToString();Subject=`$subject;Issuer=`$issuer;Message=`$signature.StatusMessage} | ConvertTo-Json -Compress))
} catch { [Console]::Error.WriteLine(`$_.Exception.Message); exit 1 }
"@
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -EncodedCommand ' +
        [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($workerCode))
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $worker = [Diagnostics.Process]::new()
    $worker.StartInfo = $startInfo
    $workerStarted = $false
    try {
        if (-not $worker.Start()) { throw '无法启动 Windows 签名验证进程。' }
        $workerStarted = $true
        $outputTask = $worker.StandardOutput.ReadToEndAsync()
        $errorTask = $worker.StandardError.ReadToEndAsync()
        if (-not $worker.WaitForExit($SignatureTimeoutSeconds * 1000)) {
            $worker.Kill()
            $worker.WaitForExit()
            throw [TimeoutException]::new('签名验证超时，未启用该包。完整下载已保留，请重试；也可用 -SignatureTimeoutSeconds 600 延长等待。')
        }
        $output = $outputTask.GetAwaiter().GetResult()
        $errorOutput = $errorTask.GetAwaiter().GetResult()
        if ($worker.ExitCode -ne 0) { throw "Windows 签名验证失败：$errorOutput" }
        $signature = $output | ConvertFrom-Json
        if ($signature.Status -ne 'Valid') { throw "Windows 签名验证失败：$($signature.Status)：$($signature.Message)" }
        return $signature
    } finally {
        try {
            if ($workerStarted -and -not $worker.HasExited) {
                $worker.Kill()
                $worker.WaitForExit()
            }
        } catch { Write-Warning '未能完成签名验证进程的清理。' }
        $worker.Dispose()
    }
}

function Get-VerifiedPackage {
    param([string]$Path, [string]$ExpectedArchitecture)
    $signature = Get-BoundedSignature $Path
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $archive.GetEntry('AppxManifest.xml')
        if ($null -eq $entry) { throw '官方包中缺少 AppxManifest.xml 清单。' }
        $reader = [IO.StreamReader]::new($entry.Open())
        try { [xml]$manifest = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $identity = $manifest.GetElementsByTagName('Identity')[0]
        if ($null -eq $identity) { throw '官方包缺少包标识。' }
        $publisher = $identity.GetAttribute('Publisher')
        if ($identity.GetAttribute('Name') -ne 'OpenAI.Codex' -or
            $publisher -ne 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B' -or
            $signature.Subject -ne $publisher) {
            throw '包标识或发布者不符，无法确认是预期的官方签名 OpenAI.Codex 包。'
        }
        $packageArchitecture = $identity.GetAttribute('ProcessorArchitecture')
        if ($packageArchitecture -ne $ExpectedArchitecture) {
            throw "包架构 $packageArchitecture 与所选架构 $ExpectedArchitecture 不符。"
        }
        foreach ($family in $manifest.GetElementsByTagName('TargetDeviceFamily')) {
            if ([Environment]::OSVersion.Version -lt [version]$family.GetAttribute('MinVersion')) {
                throw "该版本要求 Windows $($family.GetAttribute('MinVersion')) 或更高版本。"
            }
        }
        if ($manifest.GetElementsByTagName('PackageDependency').Count -gt 0) {
            throw '官方包新增了系统框架依赖，需要重新确认免安装启动方式。'
        }
        if ($null -eq $archive.GetEntry('app/ChatGPT.exe') -or
            $null -eq $archive.GetEntry('app/resources/app.asar')) {
            throw '缺少预期的程序或资源文件，官方包的文件布局可能已改变。'
        }
        return [pscustomobject]@{
            Version = ([version]$identity.GetAttribute('Version')).ToString()
            Architecture = $packageArchitecture
            Publisher = $publisher
            SHA256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
            Bytes = (Get-Item -LiteralPath $Path).Length
        }
    } finally { $archive.Dispose() }
}

function Invoke-OfficialCurl {
    param([string[]]$Arguments)
    $curl = Get-Command curl.exe -ErrorAction Stop
    & $curl.Source '--disable' @Arguments
    if ($LASTEXITCODE -ne 0) { throw "下载或版本查询失败（curl.exe 退出码：$LASTEXITCODE）。请检查网络连接后重试。" }
}

function Get-LatestMetadata {
    param([string]$Uri, [string]$Directory)
    $headersPath = Join-Path $Directory ('headers-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Invoke-OfficialCurl -Arguments @('--fail', '--location', '--silent', '--show-error', '--retry', '2',
            '--connect-timeout', '30', '--max-time', '120', '--head', '--dump-header', $headersPath,
            '--output', 'NUL', $Uri)
        $headers = [IO.File]::ReadAllText($headersPath)
        $values = @{}
        foreach ($key in @('etag', 'content-length', 'x-ms-meta-package_version')) {
            $headerMatches = [regex]::Matches($headers, '(?im)^' + [regex]::Escape($key) + ':\s*([^\r\n]+)')
            if ($headerMatches.Count -gt 0) { $values[$key] = $headerMatches[$headerMatches.Count - 1].Groups[1].Value.Trim() }
        }
        return [pscustomobject]@{
            ETag = $values['etag']
            ContentLength = $values['content-length']
            Version = $values['x-ms-meta-package_version']
        }
    } finally {
        if ([IO.File]::Exists($headersPath)) { [IO.File]::Delete($headersPath) }
    }
}

function Assert-AppExecutable {
    param([string]$AppDirectory)
    foreach ($relative in @('ChatGPT.exe', 'chrome.dll', 'resources\app.asar', 'resources\icon-chatgpt.ico')) {
        if (-not (Test-Path -LiteralPath (Join-Path $AppDirectory $relative) -PathType Leaf)) {
            throw "缺少免安装启动所需文件：$relative"
        }
    }
    $signature = Get-BoundedSignature (Join-Path $AppDirectory 'ChatGPT.exe')
    if ($signature.Subject -notmatch 'OpenAI OpCo, LLC') {
        throw '解压后的 ChatGPT.exe 未通过 OpenAI 签名验证。'
    }
}

function Expand-AppFiles {
    param([string]$Path, [string]$AppDirectory)
    $prefix = [IO.Path]::GetFullPath($AppDirectory) + [IO.Path]::DirectorySeparatorChar
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entries = @($archive.Entries | Where-Object { $_.FullName.StartsWith('app/', [StringComparison]::Ordinal) })
        foreach ($entry in $entries) {
            $relative = $entry.FullName.Substring(4).Replace('/', '\')
            if ($relative.Length -eq 0) { continue }
            $target = [IO.Path]::GetFullPath((Join-Path $AppDirectory $relative))
            if (-not $target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "包内文件路径越出应用目录，已停止解压：$($entry.FullName)"
            }
        }
        $count = 0
        foreach ($entry in $entries) {
            $relative = $entry.FullName.Substring(4).Replace('/', '\')
            if ($relative.Length -eq 0) { continue }
            $target = Join-Path $AppDirectory $relative
            if ($entry.FullName.EndsWith('/')) {
                [IO.Directory]::CreateDirectory($target) | Out-Null
            } else {
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
                $count++
            }
        }
        return $count
    } finally { $archive.Dispose() }
}

function Assert-CachedFiles {
    param([string]$Path, [string]$AppDirectory)
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    $expectedFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    try {
        foreach ($entry in $archive.Entries) {
            if (-not $entry.FullName.StartsWith('app/') -or $entry.FullName.EndsWith('/')) { continue }
            $filePath = Join-Path $AppDirectory ($entry.FullName.Substring(4).Replace('/', '\'))
            [void]$expectedFiles.Add([IO.Path]::GetFullPath($filePath))
            if (-not (Test-Path -LiteralPath $filePath -PathType Leaf) -or
                (Get-Item -LiteralPath $filePath).Length -ne $entry.Length) {
                throw "已有版本缺少文件或文件大小不符：$($entry.FullName)。请修复报错中的版本目录，再使用原保存目录重试。"
            }
            $sourceStream = $entry.Open()
            $fileStream = $null
            try {
                $fileStream = [IO.File]::OpenRead($filePath)
                $sourceHash = [BitConverter]::ToString($sha256.ComputeHash($sourceStream))
                $fileHash = [BitConverter]::ToString($sha256.ComputeHash($fileStream))
                if ($sourceHash -ne $fileHash) {
                    throw "已有文件与已验证官方包不符：$($entry.FullName)。请修复该版本目录，再使用原保存目录重试。"
                }
            } finally {
                $sourceStream.Dispose()
                if ($null -ne $fileStream) { $fileStream.Dispose() }
            }
        }
        foreach ($file in Get-ChildItem -LiteralPath $AppDirectory -File -Recurse -Force) {
            if (-not $expectedFiles.Contains($file.FullName)) {
                throw "已有版本包含官方包中没有的文件：$($file.Name)。请修复该版本目录，再使用原保存目录重试。"
            }
        }
    } finally { $sha256.Dispose(); $archive.Dispose() }
    Assert-AppExecutable $AppDirectory
}

function Commit-Configuration {
    param([object[]]$Changes, [string]$BackupDirectory)
    [IO.Directory]::CreateDirectory($BackupDirectory) | Out-Null
    $applied = [Collections.Generic.List[object]]::new()
    try {
        foreach ($change in $Changes) {
            $previous = $null
            if ([IO.File]::Exists($change.Path)) {
                $previous = [IO.File]::ReadAllBytes($change.Path)
                [IO.File]::WriteAllBytes((Join-Path $BackupDirectory $change.Label), $previous)
            }
            Write-AtomicBytes -Path $change.Path -Bytes $change.Bytes
            $applied.Add([pscustomobject]@{Path=$change.Path;Previous=$previous})
        }
    } catch {
        for ($index = $applied.Count - 1; $index -ge 0; $index--) {
            $item = $applied[$index]
            try {
                if ($null -ne $item.Previous) { Write-AtomicBytes -Path $item.Path -Bytes $item.Previous }
                elseif ([IO.File]::Exists($item.Path)) { [IO.File]::Delete($item.Path) }
            } catch { Write-Warning "未能恢复 $($item.Path)；原文件备份位于 $BackupDirectory。" }
        }
        throw
    }
}

$lockStream = $null
$stageDirectory = $null
$runId = [guid]::NewGuid().ToString('N')
$utf8 = [Text.UTF8Encoding]::new($false)
try {
    $configurationCommitted = $false
    if ($env:OS -ne 'Windows_NT') { throw '此工具只能在 Windows 上运行。' }
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($localAppData)) { throw '无法获取当前用户的应用数据目录。' }
    $defaultRoot = Join-Path $localAppData 'ChatGPT-NoAdmin'
    $shortcutRoots = @()
    if ([string]::IsNullOrWhiteSpace($StorageRoot)) {
        $existingShortcuts = @()
        foreach ($folder in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
            if (-not [string]::IsNullOrEmpty($folder)) { $existingShortcuts += Join-Path $folder 'ChatGPT（免安装）.lnk' }
        }
        $shortcutRoots = @(Get-ShortcutStorageRoots -ShortcutPaths $existingShortcuts)
    }
    $StorageRoot = Get-PortableStorageRoot -RequestedRoot $StorageRoot -DefaultRoot $defaultRoot -LegacyRoot (Join-Path $PSScriptRoot '..\_local') -ShortcutRoots $shortcutRoots
    Write-Host "保存位置：$StorageRoot"
    $downloadsDirectory = Join-Path $StorageRoot 'downloads'
    $versionsDirectory = Join-Path $StorageRoot 'versions'
    $stagingDirectory = Join-Path $StorageRoot 'staging'
    foreach ($directory in @($StorageRoot, $downloadsDirectory, $versionsDirectory, $stagingDirectory)) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    try {
        $lockStream = [IO.File]::Open((Join-Path $StorageRoot 'pipeline.lock'), [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch { throw '无法锁定保存目录。另一个配置流程可能正在运行，或当前用户没有目录写入权限。' }

    $nativeArchitecture = $env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrWhiteSpace($nativeArchitecture)) { $nativeArchitecture = $env:PROCESSOR_ARCHITECTURE }
    if ($nativeArchitecture -notin @('AMD64', 'ARM64')) { throw "不支持此 Windows 架构：$nativeArchitecture" }
    if ($Architecture -eq 'auto') {
        switch ($nativeArchitecture.ToUpperInvariant()) {
            'AMD64' { $Architecture = 'x64' }
            'ARM64' { $Architecture = 'arm64' }
            default { throw "不支持此 Windows 架构：$nativeArchitecture" }
        }
    }
    if ($nativeArchitecture -eq 'AMD64' -and $Architecture -eq 'arm64') {
        throw '此 x64 Windows 系统无法运行 Arm64 包。'
    }
    if ($ForceDownload -and -not [string]::IsNullOrWhiteSpace($PackagePath)) {
        throw '-ForceDownload 不能与 -PackagePath 同时使用。'
    }

    $sourceUri = 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-' + $Architecture + '.msix'
    $latestChecked = $false
    $downloaded = $false
    $remote = $null
    if (-not [string]::IsNullOrWhiteSpace($PackagePath)) {
        $packageFile = Resolve-FileSystemPath $PackagePath
        Write-Host '正在使用指定的本地包，不检查在线版本。'
        $package = Get-VerifiedPackage $packageFile $Architecture
    } else {
        Write-Host "正在检查官方最新版本（$Architecture）……"
        $remote = Get-LatestMetadata -Uri $sourceUri -Directory $downloadsDirectory
        $latestChecked = $true
        $packageFile = Join-Path $downloadsDirectory ('ChatGPT-' + $Architecture + '.msix')
        $metadataFile = $packageFile + '.json'
        $useCache = $false
        if (-not $ForceDownload -and (Test-Path -LiteralPath $packageFile) -and (Test-Path -LiteralPath $metadataFile)) {
            try {
                $cached = Get-Content -LiteralPath $metadataFile -Raw -Encoding UTF8 | ConvertFrom-Json
                if (-not [string]::IsNullOrEmpty($remote.ETag) -and $cached.ETag -eq $remote.ETag -and $cached.SourceUri -eq $sourceUri) {
                    $package = Get-VerifiedPackage $packageFile $Architecture
                    $useCache = $package.SHA256 -eq $cached.SHA256 -and
                        ([string]::IsNullOrEmpty($remote.Version) -or $package.Version -eq $remote.Version) -and
                        ([string]::IsNullOrEmpty($remote.ContentLength) -or $package.Bytes -eq [long]$remote.ContentLength)
                }
            } catch {
                if ($_.Exception -is [TimeoutException]) { throw }
                Write-Warning '已有下载缓存无法复用，正在重新下载官方包。'
            }
        }
        if (-not $useCache) {
            $pendingFile = Join-Path $downloadsDirectory ('ChatGPT-' + $Architecture + '.pending.msix')
            $pendingMetadataFile = $pendingFile + '.json'
            $reusePending = $false
            if (-not $ForceDownload -and (Test-Path -LiteralPath $pendingFile) -and (Test-Path -LiteralPath $pendingMetadataFile)) {
                try {
                    $pending = Get-Content -LiteralPath $pendingMetadataFile -Raw -Encoding UTF8 | ConvertFrom-Json
                    $reusePending = -not [string]::IsNullOrEmpty($remote.ETag) -and $pending.ETag -eq $remote.ETag -and
                        $pending.SourceUri -eq $sourceUri -and (Get-Item -LiteralPath $pendingFile).Length -eq $pending.Bytes -and
                        ([string]::IsNullOrEmpty($remote.ContentLength) -or $pending.Bytes -eq [long]$remote.ContentLength)
                } catch { $reusePending = $false }
            }
            if ($reusePending) {
                Write-Host '正在重新验证上次保留的完整下载，通过签名和清单检查后才会使用。'
            } else {
                $partialFile = Join-Path $downloadsDirectory ('ChatGPT-' + $Architecture + '-' + $runId + '.partial.msix')
                Write-Host '正在下载官方包，首次下载可能需要几分钟，请稍候……'
                try {
                    Invoke-OfficialCurl -Arguments @('--fail', '--location', '--silent', '--show-error', '--retry', '2',
                        '--connect-timeout', '30', '--max-time', '3600', '--output', $partialFile, $sourceUri)
                    if (-not [string]::IsNullOrEmpty($remote.ContentLength) -and
                        (Get-Item -LiteralPath $partialFile).Length -ne [long]$remote.ContentLength) {
                        throw '下载大小与官方版本信息不符，下载期间可能发布了新版，请重试。'
                    }
                    $pendingMetadata = [ordered]@{SourceUri=$sourceUri;ETag=$remote.ETag;Bytes=(Get-Item -LiteralPath $partialFile).Length}
                    if ([IO.File]::Exists($pendingFile)) { [IO.File]::Replace($partialFile, $pendingFile, [Management.Automation.Language.NullString]::Value) }
                    else { [IO.File]::Move($partialFile, $pendingFile) }
                    Write-AtomicBytes -Path $pendingMetadataFile -Bytes $utf8.GetBytes(($pendingMetadata | ConvertTo-Json))
                    $downloaded = $true
                } finally {
                    if ([IO.File]::Exists($partialFile)) { [IO.File]::Delete($partialFile) }
                }
            }
            $package = Get-VerifiedPackage $pendingFile $Architecture
            if (-not [string]::IsNullOrEmpty($remote.Version) -and $package.Version -ne $remote.Version) {
                throw '下载包与官方版本信息不符，请重试以获取完整的最新包。'
            }
            if ([IO.File]::Exists($packageFile)) { [IO.File]::Replace($pendingFile, $packageFile, [Management.Automation.Language.NullString]::Value) }
            else { [IO.File]::Move($pendingFile, $packageFile) }
            [IO.File]::Delete($pendingMetadataFile)
            $metadata = [ordered]@{SourceUri=$sourceUri;ETag=$remote.ETag;Version=$package.Version;SHA256=$package.SHA256;Bytes=$package.Bytes}
            Write-AtomicBytes -Path $metadataFile -Bytes $utf8.GetBytes(($metadata | ConvertTo-Json))
        } else { Write-Host '已是官方当前版本，签名和文件校验通过，无需重新下载。' }
    }

    $versionName = $package.Version + '-' + $Architecture + '-' + $package.SHA256.Substring(0, 12).ToLowerInvariant()
    $versionDirectory = Join-Path $versionsDirectory $versionName
    $appDirectory = Join-Path $versionDirectory 'app'
    $completeFile = Join-Path $versionDirectory 'complete.json'
    $stageDirectory = Join-Path $stagingDirectory $runId
    [IO.Directory]::CreateDirectory($stageDirectory) | Out-Null
    if (Test-Path -LiteralPath $versionDirectory) {
        if (-not (Test-Path -LiteralPath $completeFile)) { throw '版本目录缺少完成记录，请修复该版本目录，再使用原保存目录重试。' }
        $complete = Get-Content -LiteralPath $completeFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($complete.SHA256 -ne $package.SHA256) { throw '已有版本的完成记录与官方包不符。' }
        Assert-CachedFiles $packageFile $appDirectory
        Write-Host "已有程序文件校验通过，继续使用版本 $($package.Version)。"
    } else {
        Write-Host "正在解压官方原始文件：版本 $($package.Version)……"
        $stageAppDirectory = Join-Path $stageDirectory 'app'
        $fileCount = Expand-AppFiles $packageFile $stageAppDirectory
        Assert-AppExecutable $stageAppDirectory
        $complete = [ordered]@{Version=$package.Version;Architecture=$Architecture;SHA256=$package.SHA256;Files=$fileCount}
        [IO.File]::WriteAllText((Join-Path $stageDirectory 'complete.json'), ($complete | ConvertTo-Json), $utf8)
        Move-Item -LiteralPath $stageDirectory -Destination $versionDirectory -ErrorAction Stop
        [IO.Directory]::CreateDirectory($stageDirectory) | Out-Null
    }

    $executable = Join-Path $appDirectory 'ChatGPT.exe'
    $profileDirectory = Join-Path $StorageRoot 'portable-profile'
    $shortcutPaths = @()
    $changes = [Collections.Generic.List[object]]::new()
    if (-not $NoShortcuts) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcutName = 'ChatGPT（免安装）.lnk'
        $shortcutFolders = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))
        $labels = @('Desktop.lnk', 'StartMenu.lnk')
        for ($index = 0; $index -lt $shortcutFolders.Count; $index++) {
            $folder = $shortcutFolders[$index]
            if ([string]::IsNullOrEmpty($folder) -or -not (Test-Path -LiteralPath $folder -PathType Container)) {
                throw '当前用户的快捷方式目录不可用。可用 -NoShortcuts 只配置保存目录中的启动文件。'
            }
            $temporaryShortcut = Join-Path $stageDirectory $labels[$index]
            $shortcut = $shell.CreateShortcut($temporaryShortcut)
            $shortcut.TargetPath = $executable
            $shortcut.Arguments = '--user-data-dir="' + $profileDirectory + '"'
            $shortcut.WorkingDirectory = $appDirectory
            $shortcut.IconLocation = Join-Path $appDirectory 'resources\icon-chatgpt.ico'
            $shortcut.Description = 'ChatGPT 免安装启动（当前用户权限）'
            $shortcut.Save()
            $shortcutPath = Join-Path $folder $shortcutName
            $shortcutPaths += $shortcutPath
            $changes.Add([pscustomobject]@{Path=$shortcutPath;Label=$labels[$index];Bytes=[IO.File]::ReadAllBytes($temporaryShortcut)})
        }
    }

    $launcherPath = Join-Path $StorageRoot 'Start-ChatGPT.cmd'
    $launcher = @"
@echo off
chcp 65001 >nul
setlocal DisableDelayedExpansion
if not exist "%~dp0versions\$versionName\app\ChatGPT.exe" (
    echo [失败] 找不到 ChatGPT 程序，请重新双击项目中的 install.cmd 完成配置。
    pause
    exit /b 1
)
start "" /D "%~dp0versions\$versionName\app" "%~dp0versions\$versionName\app\ChatGPT.exe" --user-data-dir="%~dp0portable-profile"
if errorlevel 1 (
    echo [失败] 无法启动 ChatGPT，请检查程序文件和当前用户的运行权限。
    pause
    exit /b 1
)
exit /b 0
"@
    $state = [ordered]@{
        Mode = 'Portable'
        StorageRoot = $StorageRoot
        ConfiguredAt = [DateTimeOffset]::Now.ToString('o')
        PackageVersion = $package.Version
        Architecture = $Architecture
        SHA256 = $package.SHA256
        LatestOnlineVersionChecked = $latestChecked
        DownloadedThisRun = $downloaded
        SourceUri = $(if ($latestChecked) { $sourceUri } else { $null })
        PackagePath = $packageFile
        Executable = $executable
        ProfileDirectory = $profileDirectory
        Launcher = $launcherPath
        ShortcutPaths = $shortcutPaths
        SystemServiceInstalledByPipeline = $false
        PackageRegisteredByPipeline = $false
    }
    $launcherBytes = $utf8.GetBytes(($launcher -replace '\r?\n', "`r`n") + "`r`n")
    $changes.Add([pscustomobject]@{Path=$launcherPath;Label='Start-ChatGPT.cmd';Bytes=$launcherBytes})
    $changes.Add([pscustomobject]@{Path=(Join-Path $StorageRoot 'active.json');Label='active.json';Bytes=$utf8.GetBytes(($state | ConvertTo-Json -Depth 4))})
    [IO.Directory]::CreateDirectory($defaultRoot) | Out-Null
    $storageRecord = [ordered]@{Mode='Portable';StorageRoot=$StorageRoot}
    $changes.Add([pscustomobject]@{Path=(Join-Path $defaultRoot 'storage-root.json');Label='storage-root.json';Bytes=$utf8.GetBytes(($storageRecord | ConvertTo-Json))})
    $backupDirectory = Join-Path (Join-Path $StorageRoot 'configuration-backups') $runId
    Commit-Configuration -Changes $changes.ToArray() -BackupDirectory $backupDirectory
    $configurationCommitted = $true
    Write-Host "[成功] 免安装配置已完成：版本 $($package.Version)（$Architecture）。" -ForegroundColor Green
    if ($shortcutPaths.Count -gt 0) {
        Write-Host '下次可直接双击桌面或开始菜单中的“ChatGPT（免安装）”。'
    } else {
        Write-Host "下次可双击启动文件：$launcherPath"
    }
    if (-not $KeepOldVersions) { Remove-OldVersions -StorageRoot $StorageRoot -ActiveVersionDirectory $versionDirectory }
    if ($Launch) {
        $process = Start-Process -FilePath $executable -ArgumentList ('--user-data-dir="' + $profileDirectory + '"') -WorkingDirectory $appDirectory -WindowStyle Normal -PassThru
        try {
            if ($process.WaitForExit(3000) -and $process.ExitCode -ne 0) {
                throw "ChatGPT 启动后退出，退出码：$($process.ExitCode)。"
            }
            Write-Host "[成功] 已发出 ChatGPT 启动请求（进程 $($process.Id)）。" -ForegroundColor Green
            Write-Host '请确认应用窗口已打开；若要切换版本，请先退出旧实例，再双击快捷方式。'
        } finally {
            $process.Dispose()
        }
    }
    if ($OutputJson) { $state | ConvertTo-Json -Depth 4 }
} catch {
    if ($configurationCommitted) {
        [Console]::Error.WriteLine('[失败] 免安装配置已保存，但启动未完成。可尝试使用桌面快捷方式重新启动。')
    } else {
        [Console]::Error.WriteLine('[失败] 免安装配置未完成。')
    }
    [Console]::Error.WriteLine(('原因：' + $_.Exception.Message))
    exit 1
} finally {
    if ($null -ne $stageDirectory -and (Test-Path -LiteralPath $stageDirectory)) {
        $resolvedStage = [IO.Path]::GetFullPath($stageDirectory)
        $stagingPrefix = [IO.Path]::GetFullPath((Join-Path $StorageRoot 'staging')) + [IO.Path]::DirectorySeparatorChar
        if ($resolvedStage.StartsWith($stagingPrefix, [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($resolvedStage) -eq $runId) {
            Remove-Item -LiteralPath $resolvedStage -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if ($null -ne $lockStream) { $lockStream.Dispose() }
}
