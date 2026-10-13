#Requires -Version 5.1

<#
.SYNOPSIS
Verifies portable storage discovery and old-version cleanup without installing.

.DESCRIPTION
Loads only function definitions through the PowerShell AST. All files and
junctions belong to an isolated test directory; no downloads, signatures,
shortcuts or real application processes are involved.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$sourcePath = Join-Path $PSScriptRoot '..\src\Install-ChatGPTPortable.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw "Installer source does not parse: $($parseErrors[0].Message)"
}
$definitions = $ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $false)
. ([scriptblock]::Create(($definitions | ForEach-Object { $_.Extent.Text }) -join "`r`n"))
foreach ($name in @('Test-PortableInstallation', 'Get-PortableStorageRoot',
    'Get-RunningChatGPTPaths', 'Remove-OldVersions', 'Test-NoReparsePoints')) {
    if (-not (Test-Path -LiteralPath ('Function:\' + $name))) {
        throw "Expected installer helper is missing: $name"
    }
}
$script:OriginalRunningFunction = (Get-Item -LiteralPath Function:\Get-RunningChatGPTPaths).ScriptBlock
$script:OriginalAtomicFunction = (Get-Item -LiteralPath Function:\Write-AtomicBytes).ScriptBlock
$mainTry = @($ast.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.TryStatementAst]
})
if ($mainTry.Count -ne 1) { throw 'Expected one installer entry-point try statement.' }
$bodyText = $mainTry[0].Body.Extent.Text
$bodyText = $bodyText.Substring(1, $bodyText.Length - 2)
$localDataAssignment = '$localAppData = [Environment]::GetFolderPath(''LocalApplicationData'')'
if (-not $bodyText.Contains($localDataAssignment)) { throw 'Cannot isolate the installer user-data directory.' }
# All source statements run unchanged except the platform folder lookup, which
# points at the fixture. No real per-user data or configuration is accessed.
$isolatedBody = $bodyText.Replace($localDataAssignment, '$localAppData = $script:IntegrationLocalAppData')
$isolatedBody = $isolatedBody.Replace('$PSScriptRoot', '$script:TestRoot')
$script:IntegrationBody = [scriptblock]::Create($isolatedBody)
$finallyText = $mainTry[0].Finally.Extent.Text
$script:IntegrationFinally = [scriptblock]::Create($finallyText.Substring(1, $finallyText.Length - 2))
$script:RunningPaths = @()
$script:RunningPathSequence = @()
$script:RunningPathCallCount = 0
$script:RunningPathFailure = $false
$script:MockProcesses = @()

# Both stubs are scoped to this verification script and cannot inspect real apps.
function Get-Process {
    [CmdletBinding()]
    param()
    return $script:MockProcesses
}

function Get-RunningChatGPTPaths {
    if ($script:RunningPathFailure) { throw 'Simulated inaccessible ChatGPT process path.' }
    if ($script:RunningPathSequence.Count -gt 0) {
        $index = [Math]::Min($script:RunningPathCallCount, $script:RunningPathSequence.Count - 1)
        $script:RunningPathCallCount++
        return $script:RunningPathSequence[$index].Paths
    }
    return $script:RunningPaths
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected'; got '$Actual'."
    }
}

function Assert-Exists {
    param([string]$Path, [bool]$Expected, [string]$Message)
    Assert-Equal -Actual (Test-Path -LiteralPath $Path) -Expected $Expected -Message $Message
}

function Invoke-Case {
    param([string]$Name, [scriptblock]$Body)
    $script:RunningPaths = @()
    $script:RunningPathSequence = @()
    $script:RunningPathCallCount = 0
    $script:RunningPathFailure = $false
    $script:MockProcesses = @()
    & $Body
    $script:CaseCount++
    Write-Host "PASS: $Name"
}

function New-TestDirectory {
    param([string]$Name)
    $path = Join-Path $script:TestRoot $Name
    [IO.Directory]::CreateDirectory($path) | Out-Null
    return $path
}

function Write-TestJson {
    param([string]$Path, $Value)
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
}

function New-InstallationFixture {
    param([string]$Name)
    $path = New-TestDirectory $Name
    [IO.Directory]::CreateDirectory((Join-Path $path 'versions')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $path 'Start-ChatGPT.cmd'), '@echo test only')
    Write-TestJson (Join-Path $path 'active.json') ([ordered]@{
        Mode = 'Portable'
        PackageVersion = '1.2.3.4'
        Architecture = 'x64'
        SHA256 = ('a' * 64)
        # Stale absolute paths deliberately simulate a moved installation.
        Executable = 'Z:\old-location\versions\app\ChatGPT.exe'
        ProfileDirectory = 'Z:\old-location\portable-profile'
        Launcher = 'Z:\old-location\Start-ChatGPT.cmd'
    })
    return $path
}

function New-VersionFixture {
    param([string]$StorageRoot, [string]$Version, [string]$Architecture = 'x64', [string]$HashCharacter = 'a')
    $hash = $HashCharacter * 64
    $path = Join-Path (Join-Path $StorageRoot 'versions') ($Version + '-' + $Architecture + '-' + $hash.Substring(0, 12))
    [IO.Directory]::CreateDirectory((Join-Path $path 'app')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $path 'app\ChatGPT.exe'), 'Fixture, not an executable.')
    Write-TestJson (Join-Path $path 'complete.json') ([ordered]@{
        Version = $Version
        Architecture = $Architecture
        SHA256 = $hash
        Files = 1
    })
    return $path
}

function New-TestJunction {
    param([string]$Path, [string]$Target)
    New-Item -ItemType Junction -Path $Path -Target $Target | Out-Null
    $script:Junctions.Add($Path)
}

function Invoke-TestCleanup {
    param([string]$StorageRoot, [string]$ActiveVersionDirectory)
    Remove-OldVersions -StorageRoot $StorageRoot -ActiveVersionDirectory $ActiveVersionDirectory 3>$null
}

function Invoke-IntegrationSetup {
    param(
        [string]$FixtureName,
        [switch]$KeepVersions,
        [switch]$FailRecord,
        [switch]$JsonResult,
        [switch]$RequestLaunch,
        [ValidateSet('Running', 'HandedOff', 'StartFailure', 'NonzeroExit')][string]$LaunchOutcome = 'Running',
        [switch]$CaptureResult
    )
    $StorageRoot = New-InstallationFixture $FixtureName
    $old = New-VersionFixture $StorageRoot '1.0.0.0' 'x64' 'b'
    $new = New-VersionFixture $StorageRoot '2.0.0.0' 'x64' 'a'
    $script:IntegrationLocalAppData = New-TestDirectory ($FixtureName + '-local-app-data')
    $default = Join-Path $script:IntegrationLocalAppData 'ChatGPT-NoAdmin'
    [IO.Directory]::CreateDirectory($default) | Out-Null
    $script:IntegrationRecordPath = Join-Path $default 'storage-root.json'
    Write-TestJson $script:IntegrationRecordPath @{Mode='Portable';StorageRoot=(Join-Path $script:TestRoot 'previous-root')}
    $priorRecord = [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:IntegrationRecordPath))
    $priorState = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $StorageRoot 'active.json')))
    $priorLauncher = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $StorageRoot 'Start-ChatGPT.cmd')))
    $script:IntegrationFailRecord = [bool]$FailRecord
    $script:IntegrationLaunchOutcome = $LaunchOutcome
    $script:IntegrationLaunchRequests = [Collections.Generic.List[object]]::new()
    $script:IntegrationWaitMilliseconds = $null

    # The controlled local-package reuse branch cannot download, validate a real
    # signature, create COM shortcuts, extract an app, or start a process.
    function Get-VerifiedPackage {
        param([string]$Path, [string]$ExpectedArchitecture)
        return [pscustomobject]@{Version='2.0.0.0';Architecture='x64';SHA256=('a' * 64);Bytes=1;Publisher='Fixture'}
    }
    function Assert-CachedFiles { param([string]$Path, [string]$AppDirectory) }
    function Invoke-OfficialCurl { throw 'Unexpected download in the integration fixture.' }
    function Get-BoundedSignature { throw 'Unexpected signature check in the integration fixture.' }
    function Expand-AppFiles { throw 'Unexpected extraction in the integration fixture.' }
    function Get-ShortcutStorageRoots { throw 'Unexpected shortcut access in the integration fixture.' }
    function Start-Process {
        [CmdletBinding()]
        param([string]$FilePath, [string]$ArgumentList, [string]$WorkingDirectory,
            [string]$WindowStyle, [switch]$PassThru)
        $script:IntegrationLaunchRequests.Add([pscustomobject]@{
            FilePath=$FilePath;ArgumentList=$ArgumentList;WorkingDirectory=$WorkingDirectory;
            WindowStyle=$WindowStyle;PassThru=[bool]$PassThru
        })
        if ($script:IntegrationLaunchOutcome -eq 'StartFailure') {
            throw 'Simulated application launch failure.'
        }
        $process = [pscustomobject]@{
            Id=12345
            HasExited=($script:IntegrationLaunchOutcome -ne 'Running')
            ExitCode=$(if ($script:IntegrationLaunchOutcome -eq 'NonzeroExit') { 17 } else { 0 })
        }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
            param([int]$Milliseconds)
            $script:IntegrationWaitMilliseconds = $Milliseconds
            return $this.HasExited
        }
        $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
        return $process
    }
    function Write-AtomicBytes {
        param([string]$Path, [byte[]]$Bytes)
        if ($script:IntegrationFailRecord -and $Path -eq $script:IntegrationRecordPath) {
            $script:IntegrationFailRecord = $false
            throw 'Simulated failure writing the storage-location record.'
        }
        & $script:OriginalAtomicFunction -Path $Path -Bytes $Bytes
    }

    $Architecture = 'x64'
    $PackagePath = Join-Path $StorageRoot 'fixture.msix'
    [IO.File]::WriteAllText($PackagePath, 'Fixture only, not an MSIX.')
    $ForceDownload = $false
    $NoShortcuts = $true
    $Launch = [bool]$RequestLaunch
    $OutputJson = [bool]$JsonResult
    $KeepOldVersions = [bool]$KeepVersions
    $lockStream = $null
    $stageDirectory = $null
    $runId = [guid]::NewGuid().ToString('N')
    $utf8 = [Text.UTF8Encoding]::new($false)
    $failed = $false
    $capturedOutput = [Collections.Generic.List[object]]::new()
    try {
        . $script:IntegrationBody 6>&1 | ForEach-Object { $capturedOutput.Add($_) }
    } catch {
        $recordFailure = $FailRecord -and $_.Exception.Message -eq 'Simulated failure writing the storage-location record.'
        $launchFailure = $RequestLaunch -and $LaunchOutcome -in @('StartFailure', 'NonzeroExit')
        if (-not $recordFailure -and -not $launchFailure) { throw }
        $failed = $true
    } finally {
        . $script:IntegrationFinally
    }
    if ($FailRecord) {
        Assert-Equal $failed $true 'Expected record-write failure did not occur.'
        Assert-Equal $configurationCommitted $false 'A failed configuration was reported as committed.'
        Assert-Equal ([Convert]::ToBase64String([IO.File]::ReadAllBytes($script:IntegrationRecordPath))) $priorRecord 'Saved storage changed on failed configuration.'
        Assert-Equal ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $StorageRoot 'active.json')))) $priorState 'Active state was not rolled back.'
        Assert-Equal ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $StorageRoot 'Start-ChatGPT.cmd')))) $priorLauncher 'Launcher was not rolled back.'
        Assert-Exists $old $true 'Cleanup ran after a failed configuration transaction.'
    } else {
        Assert-Equal $failed ($RequestLaunch -and $LaunchOutcome -in @('StartFailure', 'NonzeroExit')) 'Unexpected launch outcome.'
        Assert-Equal $configurationCommitted $true 'Successful configuration was not reported as committed.'
        $active = Get-Content -LiteralPath (Join-Path $StorageRoot 'active.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $remembered = Get-Content -LiteralPath $script:IntegrationRecordPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-Equal $active.PackageVersion '2.0.0.0' 'The new version was not activated.'
        Assert-Equal $remembered.StorageRoot $StorageRoot 'The storage root was not remembered.'
        Assert-Exists $old ([bool]$KeepVersions) 'Old-version behavior differs from KeepOldVersions.'
    }
    Assert-Exists $new $true 'The activated version was removed.'
    Assert-Equal $script:IntegrationLaunchRequests.Count ([int][bool]$RequestLaunch) 'Unexpected application launch count.'
    if ($RequestLaunch) {
        $request = $script:IntegrationLaunchRequests[0]
        Assert-Equal $request.FilePath (Join-Path $new 'app\ChatGPT.exe') 'The wrong application was launched.'
        Assert-Equal $request.ArgumentList ('--user-data-dir="' + (Join-Path $StorageRoot 'portable-profile') + '"') 'The existing portable profile was not used.'
        Assert-Equal $request.WorkingDirectory (Join-Path $new 'app') 'The launch working directory differs.'
        Assert-Equal $request.PassThru $true 'The launch process was not returned for verification.'
        if ($LaunchOutcome -ne 'StartFailure') {
            Assert-Equal $script:IntegrationWaitMilliseconds 3000 'The bounded startup check differs.'
        }
    }
    if ($CaptureResult) {
        $hostOutput = @($capturedOutput | Where-Object { $_ -is [Management.Automation.InformationRecord] } | ForEach-Object { $_.MessageData.ToString() }) -join "`r`n"
        $standardOutput = @($capturedOutput | Where-Object { $_ -isnot [Management.Automation.InformationRecord] } | ForEach-Object { $_.ToString() }) -join "`r`n"
        return [pscustomobject]@{HostOutput=$hostOutput;StandardOutput=$standardOutput;Failed=$failed;StorageRoot=$StorageRoot}
    }
}

$script:CaseCount = 0
$script:Junctions = [Collections.Generic.List[string]]::new()
$runId = [guid]::NewGuid().ToString('N')
$script:TestRoot = Join-Path $PSScriptRoot ('.tmp-lifecycle-' + $runId)
[IO.Directory]::CreateDirectory($script:TestRoot) | Out-Null
try {
    Invoke-Case 'A new installation selects the shared default without creating it' {
        $default = Join-Path $script:TestRoot 'default-new'
        $legacy = Join-Path $script:TestRoot 'legacy-missing'
        $actual = Get-PortableStorageRoot -DefaultRoot $default -LegacyRoot $legacy
        Assert-Equal $actual $default 'Fresh default differs.'
        Assert-Exists $default $false 'Discovery must not create an installation.'
    }

    Invoke-Case 'Explicit relative storage wins over saved and discovered installations' {
        $default = New-TestDirectory 'default-explicit'
        $legacy = New-InstallationFixture 'legacy-explicit'
        Write-TestJson (Join-Path $default 'storage-root.json') @{Mode='Portable';StorageRoot=$legacy}
        Push-Location $script:TestRoot
        try {
            $actual = Get-PortableStorageRoot -RequestedRoot '.\requested-root' -DefaultRoot $default -LegacyRoot $legacy -ShortcutRoots @($legacy)
        } finally { Pop-Location }
        Assert-Equal $actual (Join-Path $script:TestRoot 'requested-root') 'Explicit caller-relative storage differs.'
    }

    Invoke-Case 'A missing saved root follows a recognized moved installation' {
        $default = New-TestDirectory 'default-remembered'
        $legacy = New-InstallationFixture 'legacy-remembered'
        $saved = Join-Path $script:TestRoot 'remembered-missing'
        Write-TestJson (Join-Path $default 'storage-root.json') @{Mode='Portable';StorageRoot=$saved}
        $actual = Get-PortableStorageRoot -DefaultRoot $default -LegacyRoot $legacy -ShortcutRoots @($legacy)
        Assert-Equal $actual $legacy 'Moved installation was ignored after the remembered path vanished.'
        Assert-Exists $saved $false 'Discovery must not create the remembered storage.'
    }

    Invoke-Case 'A missing saved root without a moved installation requires an explicit path' {
        $default = New-TestDirectory 'default-remembered-missing'
        $saved = Join-Path $script:TestRoot 'remembered-missing-no-candidate'
        Write-TestJson (Join-Path $default 'storage-root.json') @{Mode='Portable';StorageRoot=$saved}
        $threw = $false
        try {
            Get-PortableStorageRoot -DefaultRoot $default -LegacyRoot (Join-Path $script:TestRoot 'unknown-legacy') | Out-Null
        } catch { $threw = $true }
        Assert-Equal $threw $true 'A missing saved root silently created or selected another installation.'
        Assert-Exists $saved $false 'Missing remembered storage was created.'
    }

    Invoke-Case 'An existing saved root precedes discoveries even when its app is damaged' {
        $default = New-TestDirectory 'default-remembered-existing'
        $saved = New-TestDirectory 'remembered-existing-damaged'
        $legacy = New-InstallationFixture 'legacy-remembered-existing'
        Write-TestJson (Join-Path $default 'storage-root.json') @{Mode='Portable';StorageRoot=$saved}
        $actual = Get-PortableStorageRoot -DefaultRoot $default -LegacyRoot $legacy -ShortcutRoots @($legacy)
        Assert-Equal $actual $saved 'Existing damaged storage was replaced by another installation.'
    }

    Invoke-Case 'The first valid shortcut installation precedes a legacy local installation' {
        $default = Join-Path $script:TestRoot 'default-shortcut'
        $legacy = New-InstallationFixture 'legacy-shortcut'
        $shortcut = New-InstallationFixture 'shortcut-first'
        $second = New-InstallationFixture 'shortcut-second'
        $unknown = New-TestDirectory 'shortcut-unknown'
        $actual = Get-PortableStorageRoot -DefaultRoot $default -LegacyRoot $legacy -ShortcutRoots @($unknown, $shortcut, $second)
        Assert-Equal $actual $shortcut 'Shortcut precedence differs.'
    }

    Invoke-Case 'A moved legacy installation with stale absolute paths is reused' {
        $legacy = New-InstallationFixture 'legacy-moved'
        Assert-Equal (Test-PortableInstallation $legacy) $true 'Moved installation was not recognized.'
        $actual = Get-PortableStorageRoot -DefaultRoot (Join-Path $script:TestRoot 'default-moved') -LegacyRoot $legacy
        Assert-Equal $actual $legacy 'Moved legacy storage was replaced.'
    }

    Invoke-Case 'Invalid saved roots fall back to a recognized legacy installation' {
        $default = New-TestDirectory 'default-invalid-pointer'
        $legacy = New-InstallationFixture 'legacy-invalid-pointer'
        $pointer = Join-Path $default 'storage-root.json'
        foreach ($invalid in @(
            @{Mode='Portable';StorageRoot='.\relative-root'},
            @{Mode='Other';StorageRoot=(Join-Path $script:TestRoot 'other-root')},
            @{Mode='Portable'}
        )) {
            Write-TestJson $pointer $invalid
            $actual = Get-PortableStorageRoot -DefaultRoot $default -LegacyRoot $legacy 3>$null
            Assert-Equal $actual $legacy 'Invalid saved root was trusted.'
        }
        [IO.File]::WriteAllText($pointer, '{ broken json')
        $actual = Get-PortableStorageRoot -DefaultRoot $default -LegacyRoot $legacy 3>$null
        Assert-Equal $actual $legacy 'Broken saved root prevented reuse.'
    }

    Invoke-Case 'Installation recognition rejects malformed identity and missing layout' {
        $root = New-InstallationFixture 'installation-invalid-state'
        $statePath = Join-Path $root 'active.json'
        $valid = [IO.File]::ReadAllText($statePath)
        foreach ($property in @('Mode', 'PackageVersion', 'Architecture', 'SHA256')) {
            $state = $valid | ConvertFrom-Json
            $state.$property = 'invalid'
            Write-TestJson $statePath $state
            Assert-Equal (Test-PortableInstallation $root) $false "Malformed $property was accepted."
        }
        [IO.File]::WriteAllText($statePath, '{ broken json')
        Assert-Equal (Test-PortableInstallation $root) $false 'Malformed JSON was accepted.'
        [IO.File]::WriteAllText($statePath, $valid)
        [IO.File]::Delete((Join-Path $root 'Start-ChatGPT.cmd'))
        Assert-Equal (Test-PortableInstallation $root) $false 'Installation without a launcher was accepted.'
        [IO.File]::WriteAllText((Join-Path $root 'Start-ChatGPT.cmd'), '@echo test only')
        [IO.Directory]::Delete((Join-Path $root 'versions'))
        Assert-Equal (Test-PortableInstallation $root) $false 'Installation without versions was accepted.'
    }

    Invoke-Case 'A recognized but damaged application is reused rather than duplicated' {
        $root = New-InstallationFixture 'installation-missing-executable'
        Assert-Equal (Test-PortableInstallation $root) $true 'Missing app files prevented storage recognition.'
        $actual = Get-PortableStorageRoot -DefaultRoot (Join-Path $script:TestRoot 'default-damaged') -LegacyRoot $root
        Assert-Equal $actual $root 'Damaged storage was replaced with a duplicate.'
    }

    Invoke-Case 'Running path collection includes readable auxiliary processes' {
        $chatgpt = Join-Path $script:TestRoot 'fake-app\ChatGPT.exe'
        $helper = Join-Path $script:TestRoot 'fake-app\crashpad_handler.exe'
        $script:MockProcesses = @(
            [pscustomobject]@{ProcessName='ChatGPT';Path=$chatgpt},
            [pscustomobject]@{ProcessName='crashpad_handler';Path=$helper},
            [pscustomobject]@{ProcessName='System';Path=$null}
        )
        $paths = @(& $script:OriginalRunningFunction)
        Assert-Equal ($paths -contains $chatgpt) $true 'ChatGPT path was not protected.'
        Assert-Equal ($paths -contains $helper) $true 'Auxiliary process path was not protected.'
    }

    Invoke-Case 'An unreadable ChatGPT path prevents uncertain cleanup' {
        foreach ($unreadable in @(
            [pscustomobject]@{ProcessName='ChatGPT';Path=$null},
            ([pscustomobject]@{ProcessName='ChatGPT'} | Add-Member -MemberType ScriptProperty -Name Path -Value { throw 'Path access denied.' } -PassThru)
        )) {
            $script:MockProcesses = @($unreadable)
            $threw = $false
            try { & $script:OriginalRunningFunction | Out-Null } catch { $threw = $true }
            Assert-Equal $threw $true 'An unreadable ChatGPT path was ignored.'
        }
    }

    Invoke-Case 'Unreadable unrelated system processes do not prevent cleanup' {
        $process = [pscustomobject]@{ProcessName='System'}
        $process | Add-Member -MemberType ScriptProperty -Name Path -Value { throw 'System path access denied.' }
        $script:MockProcesses = @($process)
        $paths = @(& $script:OriginalRunningFunction)
        Assert-Equal $paths.Count 0 'Unreadable unrelated process yielded a path.'
    }

    Invoke-Case 'Completed old versions are removed while active files and user data survive' {
        $root = New-TestDirectory 'cleanup-standard'
        $active = New-VersionFixture $root '2.0.0.0' 'x64' 'a'
        $old = New-VersionFixture $root '1.0.0.0' 'x64' 'b'
        $arm = New-VersionFixture $root '1.0.0.0' 'arm64' 'c'
        $sentinels = @()
        foreach ($folder in @('portable-profile', 'downloads', 'configuration-backups')) {
            $path = Join-Path $root $folder
            [IO.Directory]::CreateDirectory($path) | Out-Null
            $sentinel = Join-Path $path 'preserve.txt'
            [IO.File]::WriteAllText($sentinel, 'Keep this user data.')
            $sentinels += $sentinel
        }
        Invoke-TestCleanup $root $active
        Assert-Exists $active $true 'The active version was removed.'
        Assert-Exists (Join-Path $active 'app\ChatGPT.exe') $true 'The active executable was removed.'
        Assert-Exists $old $false 'A completed old x64 version remains.'
        Assert-Exists $arm $false 'A completed old Arm64 version remains.'
        foreach ($sentinel in $sentinels) { Assert-Exists $sentinel $true 'Data outside versions was removed.' }
    }

    Invoke-Case 'Running application and auxiliary process versions survive' {
        $root = New-TestDirectory 'cleanup-running'
        $active = New-VersionFixture $root '4.0.0.0' 'x64' 'a'
        $running = New-VersionFixture $root '3.0.0.0' 'x64' 'b'
        $helper = New-VersionFixture $root '2.0.0.0' 'x64' 'c'
        $unused = New-VersionFixture $root '1.0.0.0' 'x64' 'd'
        $script:RunningPaths = @((Join-Path $running 'app\ChatGPT.exe'), (Join-Path $helper 'app\crashpad_handler.exe'))
        Invoke-TestCleanup $root $active
        Assert-Exists $running $true 'The running application version was removed.'
        Assert-Exists $helper $true 'An auxiliary process version was removed.'
        Assert-Exists $unused $false 'An unused completed version was not removed.'
    }

    Invoke-Case 'An unknown running path preserves all old versions' {
        $root = New-TestDirectory 'cleanup-unknown-process'
        $active = New-VersionFixture $root '2.0.0.0' 'x64' 'a'
        $old = New-VersionFixture $root '1.0.0.0' 'x64' 'b'
        $script:RunningPathFailure = $true
        Invoke-TestCleanup $root $active
        Assert-Exists $old $true 'A version was removed despite an unknown process path.'
    }

    Invoke-Case 'A version launched after the first process snapshot survives' {
        $root = New-TestDirectory 'cleanup-late-launch'
        $active = New-VersionFixture $root '2.0.0.0' 'x64' 'a'
        $old = New-VersionFixture $root '1.0.0.0' 'x64' 'b'
        $script:RunningPathSequence = @(
            [pscustomobject]@{Paths=@()},
            [pscustomobject]@{Paths=@((Join-Path $old 'app\ChatGPT.exe'))}
        )
        Invoke-TestCleanup $root $active
        Assert-Equal ($script:RunningPathCallCount -ge 2) $true 'Process paths were not rechecked before deletion.'
        Assert-Exists $old $true 'A version launched during cleanup was removed.'
    }

    Invoke-Case 'Unknown, incomplete and mismatched version directories survive' {
        $root = New-TestDirectory 'cleanup-unmanaged'
        $active = New-VersionFixture $root '9.0.0.0' 'x64' 'a'
        $old = New-VersionFixture $root '8.0.0.0' 'x64' 'b'
        $unknown = Join-Path $root 'versions\my-manual-backup'
        [IO.Directory]::CreateDirectory($unknown) | Out-Null
        $incomplete = New-VersionFixture $root '7.0.0.0' 'x64' 'c'
        [IO.File]::Delete((Join-Path $incomplete 'complete.json'))
        $broken = New-VersionFixture $root '6.0.0.0' 'x64' 'd'
        [IO.File]::WriteAllText((Join-Path $broken 'complete.json'), '{ invalid json')
        $mismatched = New-VersionFixture $root '5.0.0.0' 'x64' 'e'
        Write-TestJson (Join-Path $mismatched 'complete.json') @{Version='5.0.0.0';Architecture='arm64';SHA256=('e' * 64);Files=1}
        $badHash = New-VersionFixture $root '4.0.0.0' 'x64' 'f'
        Write-TestJson (Join-Path $badHash 'complete.json') @{Version='4.0.0.0';Architecture='x64';SHA256='f';Files=1}
        $missingProperty = New-VersionFixture $root '3.0.0.0' 'x64' '1'
        Write-TestJson (Join-Path $missingProperty 'complete.json') @{Version='3.0.0.0';Architecture='x64';Files=1}
        Invoke-TestCleanup $root $active
        Assert-Exists $old $false 'A valid old version was not removed.'
        foreach ($path in @($unknown, $incomplete, $broken, $mismatched, $badHash, $missingProperty)) {
            Assert-Exists $path $true 'An unknown or invalid version was removed.'
        }
    }

    Invoke-Case 'An active path outside the versions root prevents every deletion' {
        $root = New-TestDirectory 'cleanup-outside-active'
        $old = New-VersionFixture $root '1.0.0.0' 'x64' 'a'
        $outside = New-TestDirectory 'cleanup-outside-active\versions-other\2.0.0.0-x64-bbbbbbbbbbbb'
        Invoke-TestCleanup $root $outside
        Assert-Exists $old $true 'Cleanup accepted a sibling prefix as an active version.'
    }

    Invoke-Case 'A missing or nested active version prevents every deletion' {
        $root = New-TestDirectory 'cleanup-invalid-active'
        $old = New-VersionFixture $root '1.0.0.0' 'x64' 'a'
        Invoke-TestCleanup $root (Join-Path $root 'versions\missing')
        Assert-Exists $old $true 'Cleanup accepted a missing active version.'
        Invoke-TestCleanup $root (Join-Path $old 'app')
        Assert-Exists $old $true 'Cleanup accepted a nested active directory.'
    }

    Invoke-Case 'A running path in a similarly named sibling is not a containment match' {
        $root = New-TestDirectory 'cleanup-process-prefix'
        $active = New-VersionFixture $root '2.0.0.0' 'x64' 'a'
        $old = New-VersionFixture $root '1.0.0.0' 'x64' 'b'
        $script:RunningPaths = @($old + '-other\app\ChatGPT.exe')
        Invoke-TestCleanup $root $active
        Assert-Exists $old $false 'A sibling prefix incorrectly protected a version.'
    }

    Invoke-Case 'A junction candidate is retained and its external target is untouched' {
        $root = New-TestDirectory 'cleanup-candidate-link'
        $active = New-VersionFixture $root '3.0.0.0' 'x64' 'a'
        $externalRoot = New-TestDirectory 'external-candidate-link'
        $externalVersion = New-VersionFixture $externalRoot '1.0.0.0' 'x64' 'b'
        $linked = Join-Path $root ('versions\' + [IO.Path]::GetFileName($externalVersion))
        New-TestJunction $linked $externalVersion
        $unused = New-VersionFixture $root '2.0.0.0' 'x64' 'c'
        Assert-Equal (Test-NoReparsePoints $linked) $false 'A junction was considered a safe directory.'
        Invoke-TestCleanup $root $active
        Assert-Exists $linked $true 'A junction version was removed.'
        Assert-Exists (Join-Path $externalVersion 'app\ChatGPT.exe') $true 'An external junction target was modified.'
        Assert-Exists $unused $false 'A separate safe old version was not removed.'
    }

    Invoke-Case 'A nested junction protects the whole candidate directory' {
        $root = New-TestDirectory 'cleanup-nested-link'
        $active = New-VersionFixture $root '2.0.0.0' 'x64' 'a'
        $old = New-VersionFixture $root '1.0.0.0' 'x64' 'b'
        $external = New-TestDirectory 'external-nested-link'
        $sentinel = Join-Path $external 'preserve.txt'
        [IO.File]::WriteAllText($sentinel, 'External data must survive.')
        New-TestJunction (Join-Path $old 'app\nested-link') $external
        Assert-Equal (Test-NoReparsePoints $old) $false 'A nested junction was missed.'
        Invoke-TestCleanup $root $active
        Assert-Exists $old $true 'A version containing a junction was removed.'
        Assert-Exists $sentinel $true 'Nested junction target data was modified.'
    }

    Invoke-Case 'A junction versions root prevents every deletion' {
        $root = New-TestDirectory 'cleanup-versions-link'
        $externalRoot = New-TestDirectory 'external-versions-link'
        $activeExternal = New-VersionFixture $externalRoot '2.0.0.0' 'x64' 'a'
        $oldExternal = New-VersionFixture $externalRoot '1.0.0.0' 'x64' 'b'
        New-TestJunction (Join-Path $root 'versions') (Join-Path $externalRoot 'versions')
        $activeLinked = Join-Path $root ('versions\' + [IO.Path]::GetFileName($activeExternal))
        Invoke-TestCleanup $root $activeLinked
        Assert-Exists $oldExternal $true 'A linked versions root permitted external deletion.'
    }

    Invoke-Case 'A junction storage root prevents every deletion' {
        $externalRoot = New-TestDirectory 'external-storage-link'
        $activeExternal = New-VersionFixture $externalRoot '2.0.0.0' 'x64' 'a'
        $oldExternal = New-VersionFixture $externalRoot '1.0.0.0' 'x64' 'b'
        $root = Join-Path $script:TestRoot 'cleanup-storage-link'
        New-TestJunction $root $externalRoot
        $activeLinked = Join-Path $root ('versions\' + [IO.Path]::GetFileName($activeExternal))
        Invoke-TestCleanup $root $activeLinked
        Assert-Exists $oldExternal $true 'A linked storage root permitted external deletion.'
    }

    Invoke-Case 'A junction ancestor of storage prevents every deletion' {
        $externalParent = New-TestDirectory 'external-storage-ancestor'
        $externalRoot = Join-Path $externalParent 'storage'
        [IO.Directory]::CreateDirectory($externalRoot) | Out-Null
        $activeExternal = New-VersionFixture $externalRoot '2.0.0.0' 'x64' 'a'
        $oldExternal = New-VersionFixture $externalRoot '1.0.0.0' 'x64' 'b'
        $parentLink = Join-Path $script:TestRoot 'cleanup-storage-ancestor-link'
        New-TestJunction $parentLink $externalParent
        $root = Join-Path $parentLink 'storage'
        $activeLinked = Join-Path $root ('versions\' + [IO.Path]::GetFileName($activeExternal))
        Invoke-TestCleanup $root $activeLinked
        Assert-Exists $oldExternal $true 'A linked storage ancestor permitted external deletion.'
    }

    Invoke-Case 'A normal directory tree passes reparse checks' {
        $root = New-TestDirectory 'plain-directory'
        [IO.Directory]::CreateDirectory((Join-Path $root 'nested\deep')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'nested\deep\plain.txt'), 'Plain fixture.')
        Assert-Equal (Test-NoReparsePoints $root) $true 'A normal directory tree was rejected.'
    }

    Invoke-Case 'The setup transaction remembers storage and cleans old versions after activation' {
        Invoke-IntegrationSetup 'integration-success'
    }

    Invoke-Case 'KeepOldVersions skips cleanup in the setup transaction' {
        Invoke-IntegrationSetup 'integration-keep' -KeepVersions
    }

    Invoke-Case 'A failed storage record commit restores configuration and skips cleanup' {
        Invoke-IntegrationSetup 'integration-rollback' -FailRecord
    }

    Invoke-Case 'Default setup reports success in Chinese without printing JSON' {
        $result = Invoke-IntegrationSetup 'integration-chinese-output' -CaptureResult
        Assert-Equal $result.StandardOutput.Trim() '' 'Default setup printed structured output.'
        Assert-Equal ($result.HostOutput -match '成功') $true 'The Chinese success summary is missing.'
        Assert-Equal ($result.HostOutput -match '2\.0\.0\.0') $true 'The configured version is missing from the summary.'
    }

    Invoke-Case 'Explicit JSON output contains the saved portable configuration' {
        $result = Invoke-IntegrationSetup 'integration-json-output' -JsonResult -CaptureResult
        $state = $result.StandardOutput | ConvertFrom-Json
        Assert-Equal $state.Mode 'Portable' 'JSON mode differs.'
        Assert-Equal $state.PackageVersion '2.0.0.0' 'JSON version differs.'
        Assert-Equal $state.StorageRoot $result.StorageRoot 'JSON storage differs.'
        Assert-Equal $state.SystemServiceInstalledByPipeline $false 'JSON reports service installation.'
        Assert-Equal $state.PackageRegisteredByPipeline $false 'JSON reports package registration.'
    }

    Invoke-Case 'A running mock application receives a verified launch request' {
        $result = Invoke-IntegrationSetup 'integration-launch-success' -RequestLaunch -CaptureResult
        Assert-Equal $result.StandardOutput.Trim() '' 'Launching printed structured output by default.'
        Assert-Equal ($result.HostOutput -match '启动') $true 'The Chinese launch summary is missing.'
    }

    Invoke-Case 'A successful early exit may hand off to an existing application instance' {
        Invoke-IntegrationSetup 'integration-launch-handoff' -RequestLaunch -LaunchOutcome HandedOff
    }

    Invoke-Case 'An application launch exception preserves committed configuration and cleanup' {
        Invoke-IntegrationSetup 'integration-launch-failure' -RequestLaunch -LaunchOutcome StartFailure
    }

    Invoke-Case 'An immediate nonzero application exit preserves committed configuration and cleanup' {
        Invoke-IntegrationSetup 'integration-launch-nonzero' -RequestLaunch -LaunchOutcome NonzeroExit
    }

    Write-Host "Verified $script:CaseCount portable lifecycle cases without running installation."
} finally {
    # Remove only junction entries themselves; never recursively follow their targets.
    for ($index = $script:Junctions.Count - 1; $index -ge 0; $index--) {
        $junctionPath = $script:Junctions[$index]
        if ([IO.Directory]::Exists($junctionPath)) { [IO.Directory]::Delete($junctionPath) }
    }
    $resolvedTestRoot = [IO.Path]::GetFullPath($script:TestRoot)
    $testPrefix = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedTestRoot.StartsWith($testPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolvedTestRoot) -ne ('.tmp-lifecycle-' + $runId)) {
        throw 'Refusing to delete a test directory outside the verification workspace.'
    }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
}
