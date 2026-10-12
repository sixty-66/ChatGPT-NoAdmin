#Requires -Version 5.1

<#
.SYNOPSIS
Downloads the latest official ChatGPT MSIX and prepares current-user portable startup.

.DESCRIPTION
Requires Windows PowerShell 5.1 and the system curl.exe for online downloads.
Verifies the Windows signatures, expected package identity and original app files
before configuring a launcher and optional current-user shortcuts. Does not
register the MSIX, install system services or request Windows administrator rights.
ChatGPT still requires an internet connection; MSIX is an offline installation
package, not an offline language model.

.PARAMETER StorageRoot
Folder for downloads, extracted versions, launcher and profile. Defaults to the
_local folder beside this project's install.cmd. Relative paths use the caller's
PowerShell working directory.

.PARAMETER Architecture
Package architecture: auto (detect Windows), x64 or arm64.

.PARAMETER PackagePath
Use an existing official MSIX instead of checking or downloading the latest online
version. The local package must pass the same signature and manifest checks.

.PARAMETER ForceDownload
Download again even when the verified package cache matches the official endpoint.
Cannot be combined with PackagePath.

.PARAMETER NoShortcuts
Configure only the launcher and active.json; do not change desktop or Start menu
shortcuts.

.PARAMETER Launch
Start the configured application after successful setup. Close an older running
instance yourself before switching versions.

.PARAMETER SignatureTimeoutSeconds
Maximum time for each Windows signature verification. Default: 180 seconds.

.PARAMETER Help
Display this help without creating files, downloading or configuring anything.

.EXAMPLE
.\install.cmd -Launch
From the project folder, check the latest official package, prepare portable
startup and launch ChatGPT.

.EXAMPLE
.\install.cmd -StorageRoot ".\app-data" -NoShortcuts
Use a custom writable storage folder without changing user shortcuts.

.EXAMPLE
.\install.cmd -PackagePath ".\ChatGPT-x64.msix" -NoShortcuts
Prepare startup from an already downloaded package without checking for updates.

.EXAMPLE
.\install.cmd -Help
Display all parameters and usage examples without changing anything.
#>
[CmdletBinding()]
param(
    [string]$StorageRoot,
    [ValidateSet('auto', 'x64', 'arm64')][string]$Architecture = 'auto',
    [string]$PackagePath,
    [switch]$ForceDownload,
    [switch]$NoShortcuts,
    [switch]$Launch,
    [ValidateRange(10, 1800)][int]$SignatureTimeoutSeconds = 180,
    [switch]$Help
)

if ($Help) {
    Get-Help -Name $PSCommandPath -Detailed
    return
}

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Resolve-FileSystemPath {
    param([string]$Path)
    $pathProvider = $null
    $pathDrive = $null
    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $Path, [ref]$pathProvider, [ref]$pathDrive)
    if ($pathProvider.Name -ne 'FileSystem') { throw 'A FileSystem path is required.' }
    return [IO.Path]::GetFullPath($resolvedPath)
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
    Write-Host "Checking the Windows signature (timeout: $SignatureTimeoutSeconds seconds): $([IO.Path]::GetFileName($Path))"
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
        if (-not $worker.Start()) { throw 'Could not start the Windows signature verification worker.' }
        $workerStarted = $true
        $outputTask = $worker.StandardOutput.ReadToEndAsync()
        $errorTask = $worker.StandardError.ReadToEndAsync()
        if (-not $worker.WaitForExit($SignatureTimeoutSeconds * 1000)) {
            $worker.Kill()
            $worker.WaitForExit()
            throw [TimeoutException]::new('Windows signature verification timed out. The package was not activated. A completed download is retained; retry or inspect Windows trust verification.')
        }
        $output = $outputTask.GetAwaiter().GetResult()
        $errorOutput = $errorTask.GetAwaiter().GetResult()
        if ($worker.ExitCode -ne 0) { throw "Windows signature verification failed: $errorOutput" }
        $signature = $output | ConvertFrom-Json
        if ($signature.Status -ne 'Valid') { throw "Windows signature verification failed: $($signature.Status): $($signature.Message)" }
        return $signature
    } finally {
        try {
            if ($workerStarted -and -not $worker.HasExited) {
                $worker.Kill()
                $worker.WaitForExit()
            }
        } catch { Write-Warning 'Could not finish cleanup of the signature verification worker.' }
        $worker.Dispose()
    }
}

function Get-VerifiedPackage {
    param([string]$Path, [string]$ExpectedArchitecture)
    $signature = Get-BoundedSignature $Path
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $archive.GetEntry('AppxManifest.xml')
        if ($null -eq $entry) { throw 'AppxManifest.xml is missing.' }
        $reader = [IO.StreamReader]::new($entry.Open())
        try { [xml]$manifest = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $identity = $manifest.GetElementsByTagName('Identity')[0]
        if ($null -eq $identity) { throw 'The package identity is missing.' }
        $publisher = $identity.GetAttribute('Publisher')
        if ($identity.GetAttribute('Name') -ne 'OpenAI.Codex' -or
            $publisher -ne 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B' -or
            $signature.Subject -ne $publisher) {
            throw 'This is not the expected Store-signed OpenAI.Codex package.'
        }
        $packageArchitecture = $identity.GetAttribute('ProcessorArchitecture')
        if ($packageArchitecture -ne $ExpectedArchitecture) {
            throw "Package architecture $packageArchitecture does not match $ExpectedArchitecture."
        }
        foreach ($family in $manifest.GetElementsByTagName('TargetDeviceFamily')) {
            if ([Environment]::OSVersion.Version -lt [version]$family.GetAttribute('MinVersion')) {
                throw "This package requires Windows $($family.GetAttribute('MinVersion')) or newer."
            }
        }
        if ($manifest.GetElementsByTagName('PackageDependency').Count -gt 0) {
            throw 'This package now declares framework dependencies. Unpackaged startup must be reassessed.'
        }
        if ($null -eq $archive.GetEntry('app/ChatGPT.exe') -or
            $null -eq $archive.GetEntry('app/resources/app.asar')) {
            throw 'The expected app/ executable and resources are missing. The package layout may have changed.'
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
    if ($LASTEXITCODE -ne 0) { throw "curl.exe failed with exit code $LASTEXITCODE. TLS verification remains enabled." }
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
            throw "Required portable file is missing: $relative"
        }
    }
    $signature = Get-BoundedSignature (Join-Path $AppDirectory 'ChatGPT.exe')
    if ($signature.Subject -notmatch 'OpenAI OpCo, LLC') {
        throw 'The extracted ChatGPT.exe does not have a valid OpenAI signature.'
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
                throw "Archive path escapes the application directory: $($entry.FullName)"
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
                throw "Cached version is incomplete: $($entry.FullName). Keep it for diagnosis and use another StorageRoot."
            }
            $sourceStream = $entry.Open()
            $fileStream = $null
            try {
                $fileStream = [IO.File]::OpenRead($filePath)
                $sourceHash = [BitConverter]::ToString($sha256.ComputeHash($sourceStream))
                $fileHash = [BitConverter]::ToString($sha256.ComputeHash($fileStream))
                if ($sourceHash -ne $fileHash) {
                    throw "Cached file differs from the verified package: $($entry.FullName). Use another StorageRoot."
                }
            } finally {
                $sourceStream.Dispose()
                if ($null -ne $fileStream) { $fileStream.Dispose() }
            }
        }
        foreach ($file in Get-ChildItem -LiteralPath $AppDirectory -File -Recurse -Force) {
            if (-not $expectedFiles.Contains($file.FullName)) {
                throw "Cached version contains a file absent from the verified package: $($file.Name). Use another StorageRoot."
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
            } catch { Write-Warning "Could not restore $($item.Path); the previous file is in $BackupDirectory." }
        }
        throw
    }
}

$lockStream = $null
$stageDirectory = $null
$runId = [guid]::NewGuid().ToString('N')
$utf8 = [Text.UTF8Encoding]::new($false)
try {
    if ($env:OS -ne 'Windows_NT') { throw 'This pipeline requires Windows.' }
    if ([string]::IsNullOrWhiteSpace($StorageRoot)) {
        $StorageRoot = Join-Path $PSScriptRoot '..\_local'
    }
    $StorageRoot = Resolve-FileSystemPath $StorageRoot
    $downloadsDirectory = Join-Path $StorageRoot 'downloads'
    $versionsDirectory = Join-Path $StorageRoot 'versions'
    $stagingDirectory = Join-Path $StorageRoot 'staging'
    foreach ($directory in @($StorageRoot, $downloadsDirectory, $versionsDirectory, $stagingDirectory)) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    try {
        $lockStream = [IO.File]::Open((Join-Path $StorageRoot 'pipeline.lock'), [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch { throw 'Cannot lock this StorageRoot. Another pipeline may be running, or the folder is not writable.' }

    $nativeArchitecture = $env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrWhiteSpace($nativeArchitecture)) { $nativeArchitecture = $env:PROCESSOR_ARCHITECTURE }
    if ($nativeArchitecture -notin @('AMD64', 'ARM64')) { throw "Unsupported Windows architecture: $nativeArchitecture" }
    if ($Architecture -eq 'auto') {
        switch ($nativeArchitecture.ToUpperInvariant()) {
            'AMD64' { $Architecture = 'x64' }
            'ARM64' { $Architecture = 'arm64' }
            default { throw "Unsupported Windows architecture: $nativeArchitecture" }
        }
    }
    if ($nativeArchitecture -eq 'AMD64' -and $Architecture -eq 'arm64') {
        throw 'An Arm64 package cannot run on this x64 Windows system.'
    }
    if ($ForceDownload -and -not [string]::IsNullOrWhiteSpace($PackagePath)) {
        throw 'ForceDownload cannot be combined with PackagePath.'
    }

    $sourceUri = 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-' + $Architecture + '.msix'
    $latestChecked = $false
    $downloaded = $false
    $remote = $null
    if (-not [string]::IsNullOrWhiteSpace($PackagePath)) {
        $packageFile = Resolve-FileSystemPath $PackagePath
        Write-Host 'Using the specified local package. The latest online version is not checked.'
        $package = Get-VerifiedPackage $packageFile $Architecture
    } else {
        Write-Host "Checking the latest official $Architecture package..."
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
                Write-Warning 'The download cache cannot be reused; downloading a verified replacement.'
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
                Write-Host 'Rechecking the retained complete download. It is not trusted until signature and manifest checks pass.'
            } else {
                $partialFile = Join-Path $downloadsDirectory ('ChatGPT-' + $Architecture + '-' + $runId + '.partial.msix')
                Write-Host "Downloading $sourceUri"
                try {
                    Invoke-OfficialCurl -Arguments @('--fail', '--location', '--silent', '--show-error', '--retry', '2',
                        '--connect-timeout', '30', '--max-time', '3600', '--output', $partialFile, $sourceUri)
                    if (-not [string]::IsNullOrEmpty($remote.ContentLength) -and
                        (Get-Item -LiteralPath $partialFile).Length -ne [long]$remote.ContentLength) {
                        throw 'The download size differs from the HEAD response. Retry; the endpoint may have updated during the download.'
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
                throw 'The package version differs from the HEAD response. Retry to fetch a consistent latest package.'
            }
            if ([IO.File]::Exists($packageFile)) { [IO.File]::Replace($pendingFile, $packageFile, [Management.Automation.Language.NullString]::Value) }
            else { [IO.File]::Move($pendingFile, $packageFile) }
            [IO.File]::Delete($pendingMetadataFile)
            $metadata = [ordered]@{SourceUri=$sourceUri;ETag=$remote.ETag;Version=$package.Version;SHA256=$package.SHA256;Bytes=$package.Bytes}
            Write-AtomicBytes -Path $metadataFile -Bytes $utf8.GetBytes(($metadata | ConvertTo-Json))
        } else { Write-Host 'The cached official package matches the current endpoint; its signature and SHA256 were rechecked.' }
    }

    $versionName = $package.Version + '-' + $Architecture + '-' + $package.SHA256.Substring(0, 12).ToLowerInvariant()
    $versionDirectory = Join-Path $versionsDirectory $versionName
    $appDirectory = Join-Path $versionDirectory 'app'
    $completeFile = Join-Path $versionDirectory 'complete.json'
    $stageDirectory = Join-Path $stagingDirectory $runId
    [IO.Directory]::CreateDirectory($stageDirectory) | Out-Null
    if (Test-Path -LiteralPath $versionDirectory) {
        if (-not (Test-Path -LiteralPath $completeFile)) { throw 'The version directory has no completion record. Use another StorageRoot.' }
        $complete = Get-Content -LiteralPath $completeFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($complete.SHA256 -ne $package.SHA256) { throw 'The cached version completion record does not match this package.' }
        Assert-CachedFiles $packageFile $appDirectory
        Write-Host "Reusing extracted version $($package.Version)."
    } else {
        Write-Host "Extracting the original app files for version $($package.Version)..."
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
                throw 'A current-user shortcut folder is unavailable. Use NoShortcuts to configure only the launcher.'
            }
            $temporaryShortcut = Join-Path $stageDirectory $labels[$index]
            $shortcut = $shell.CreateShortcut($temporaryShortcut)
            $shortcut.TargetPath = $executable
            $shortcut.Arguments = '--user-data-dir="' + $profileDirectory + '"'
            $shortcut.WorkingDirectory = $appDirectory
            $shortcut.IconLocation = Join-Path $appDirectory 'resources\icon-chatgpt.ico'
            $shortcut.Description = 'ChatGPT extracted for current-user startup. Windows services are not installed.'
            $shortcut.Save()
            $shortcutPath = Join-Path $folder $shortcutName
            $shortcutPaths += $shortcutPath
            $changes.Add([pscustomobject]@{Path=$shortcutPath;Label=$labels[$index];Bytes=[IO.File]::ReadAllBytes($temporaryShortcut)})
        }
    }

    $launcherPath = Join-Path $StorageRoot 'Start-ChatGPT.cmd'
    $launcher = @"
@echo off
setlocal DisableDelayedExpansion
if not exist "%~dp0versions\$versionName\app\ChatGPT.exe" (
    echo ChatGPT.exe was not found. Run the setup pipeline again.
    exit /b 1
)
start "" /D "%~dp0versions\$versionName\app" "%~dp0versions\$versionName\app\ChatGPT.exe" --user-data-dir="%~dp0portable-profile"
"@
    $state = [ordered]@{
        Mode = 'Portable'
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
    $launcherBytes = [Text.Encoding]::ASCII.GetBytes(($launcher -replace '\r?\n', "`r`n") + "`r`n")
    $changes.Add([pscustomobject]@{Path=$launcherPath;Label='Start-ChatGPT.cmd';Bytes=$launcherBytes})
    $changes.Add([pscustomobject]@{Path=(Join-Path $StorageRoot 'active.json');Label='active.json';Bytes=$utf8.GetBytes(($state | ConvertTo-Json -Depth 4))})
    $backupDirectory = Join-Path (Join-Path $StorageRoot 'configuration-backups') $runId
    Commit-Configuration -Changes $changes.ToArray() -BackupDirectory $backupDirectory
    Write-Host "Portable startup configured: $launcherPath"
    Write-Host 'No elevation, package registration, service installation, or sandbox-disabling flags were used.'
    if ($Launch) {
        $process = Start-Process -FilePath $executable -ArgumentList ('--user-data-dir="' + $profileDirectory + '"') -WorkingDirectory $appDirectory -WindowStyle Normal -PassThru
        Write-Host "Launch requested (process $($process.Id)). Close an older running instance to switch versions."
    }
    $state | ConvertTo-Json -Depth 4
} catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
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
