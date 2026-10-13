#Requires -Version 5.1

<#
.SYNOPSIS
Verifies graphical output and entry-point dispatch using isolated fake workers.

.DESCRIPTION
The real installer is never invoked. Callback fixtures use controls that are
never shown. An additional fixture starts the actual VBS and cloned GUI with a
real modal window, a fake installer and an automatic close timer. Only fixture
scripts in tests run as child processes; they do not download, check signatures
or access user data.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourcePath = Join-Path $projectRoot 'src\Start-ChatGPT.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "GUI source does not parse: $($parseErrors[0].Message)" }
$source = [IO.File]::ReadAllText($sourcePath)
$displayTry = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })
if ($displayTry.Count -ne 1 -or $displayTry[0].Extent.Text -notmatch 'ShowDialog') {
    throw 'Cannot isolate GUI initialization from displaying the window.'
}
$prefix = $source.Substring(0, $displayTry[0].Extent.StartOffset)
$script:GuiInitialization = [scriptblock]::Create($prefix.Replace('$PSScriptRoot', '$script:FixtureSourceDirectory'))

function Get-EventBody {
    param([string]$EventName)
    $handlers = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -eq $EventName
    }, $false))
    if ($handlers.Count -ne 1 -or $handlers[0].Arguments.Count -ne 1) { throw "Cannot isolate event $EventName." }
    $text = $handlers[0].Arguments[0].ScriptBlock.Extent.Text
    return [scriptblock]::Create($text.Substring(1, $text.Length - 2).Replace('$PSScriptRoot', '$script:FixtureSourceDirectory'))
}
$script:ShownBody = Get-EventBody 'Add_Shown'
$script:TickBody = Get-EventBody 'Add_Tick'

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) { throw "$Message Expected '$Expected'; got '$Actual'." }
}

function Invoke-Case {
    param([string]$Name, [scriptblock]$Body)
    & $Body
    $script:CaseCount++
    Write-Host "PASS: $Name"
}

function Write-FixtureScript {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, ($Text -replace '\r?\n', "`r`n"), [Text.UTF8Encoding]::new($true))
}

function Invoke-GraphicalFixture {
    param([string]$Name, [int]$WorkerExitCode, [switch]$MissingWorker)
    $script:FixtureSourceDirectory = Join-Path $script:TestRoot ($Name + '\中文 项目\src')
    [IO.Directory]::CreateDirectory($script:FixtureSourceDirectory) | Out-Null
    if (-not $MissingWorker) {
        $worker = @'
param([switch]$Launch)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::Out.WriteLine('启动参数：' + $Launch)
[Console]::Out.WriteLine('中文标准输出：准备完成')
[Console]::Error.WriteLine('中文错误输出：诊断信息')
for ($index = 1; $index -le 40; $index++) {
    [Console]::Out.WriteLine('标准输出行：' + $index)
    [Console]::Error.WriteLine('错误输出行：' + $index)
}
[Console]::Out.WriteLine('标准输出结束：最后一行')
[Console]::Error.WriteLine('错误输出结束：最后一行')
exit FIXTURE_EXIT_CODE
'@
        Write-FixtureScript (Join-Path $script:FixtureSourceDirectory 'Install-ChatGPTPortable.ps1') ($worker.Replace('FIXTURE_EXIT_CODE', [string]$WorkerExitCode))
    }
    $script:setupProcess = $null
    $script:setupOutput = $null
    $script:setupFinished = $false
    $script:setupSucceeded = $false
    $logBox.Clear()
    $closeButton.Enabled = $false
    try {
        . $script:ShownBody
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while (-not $script:setupFinished -and [DateTime]::UtcNow -lt $deadline) {
            . $script:TickBody
            if (-not $script:setupFinished) { Start-Sleep -Milliseconds 20 }
        }
        Assert-Equal $script:setupFinished $true 'The GUI worker did not finish within the fixture timeout.'
        Assert-Equal $closeButton.Enabled $true 'The Close button remained disabled after completion.'
        Assert-Equal $timer.Enabled $false 'The output timer remained enabled after completion.'
        if ($MissingWorker) {
            Assert-Equal $script:setupSucceeded $false 'A missing worker was reported as success.'
            Assert-Equal ($logBox.Text -match '找不到配置脚本') $true 'The missing-worker reason was lost.'
            Assert-Equal ($null -eq $script:setupProcess) $true 'A missing worker unexpectedly started a process.'
        } else {
            Assert-Equal $script:setupSucceeded ($WorkerExitCode -eq 0) 'GUI success differs from the child exit code.'
            foreach ($expected in @('启动参数：True', '中文标准输出：准备完成', '中文错误输出：诊断信息',
                '标准输出行：40', '错误输出行：40', '标准输出结束：最后一行', '错误输出结束：最后一行')) {
                Assert-Equal $logBox.Text.Contains($expected) $true "GUI log lost UTF-8 output '$expected'."
            }
            Assert-Equal $script:setupProcess.StartInfo.CreateNoWindow $true 'The worker creates a console window.'
            Assert-Equal $script:setupProcess.StartInfo.UseShellExecute $false 'The worker does not redirect output directly.'
            if ($WorkerExitCode -eq 0) {
                Assert-Equal ($statusLabel.Text -match '成功.*启动请求') $true 'The Chinese success status is missing.'
            } else {
                Assert-Equal ($statusLabel.Text -match '未完成') $true 'The Chinese failure status is missing.'
                Assert-Equal ($logBox.Text -match ('退出码：' + $WorkerExitCode)) $true 'The failing exit code was lost.'
            }
        }
    } finally {
        $timer.Stop()
        if ($null -ne $script:setupOutput) { $script:setupOutput.Dispose() }
        if ($null -ne $script:setupProcess) {
            if (-not $script:setupProcess.HasExited) {
                # Only the fixture worker may be stopped on test timeout.
                $script:setupProcess.Kill()
                $script:setupProcess.WaitForExit()
            }
            $script:setupProcess.Dispose()
        }
    }
}

function Invoke-CommandFixture {
    param([string]$FixtureDirectory, [string]$Arguments = '')
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $startInfo.Arguments = '/d /c ""' + (Join-Path $FixtureDirectory 'install.cmd') + '" ' + $Arguments + '"'
    $startInfo.WorkingDirectory = $FixtureDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $worker = [Diagnostics.Process]::new()
    $worker.StartInfo = $startInfo
    try {
        if (-not $worker.Start()) { throw 'Could not start the isolated command fixture.' }
        $stdout = $worker.StandardOutput.ReadToEndAsync()
        $stderr = $worker.StandardError.ReadToEndAsync()
        if (-not $worker.WaitForExit(20000)) {
            $worker.Kill()
            $worker.WaitForExit()
            throw 'The command fixture timed out.'
        }
        return [pscustomobject]@{ExitCode=$worker.ExitCode;Output=$stdout.GetAwaiter().GetResult();Error=$stderr.GetAwaiter().GetResult()}
    } finally { $worker.Dispose() }
}

function Stop-OwnedFixtureProcess {
    param([string]$MarkerPath)
    if (-not (Test-Path -LiteralPath $MarkerPath -PathType Leaf)) { return }
    $identity = [IO.File]::ReadAllText($MarkerPath) | ConvertFrom-Json
    $ownedProcess = $null
    try {
        try { $ownedProcess = [Diagnostics.Process]::GetProcessById([int]$identity.Id) }
        catch [ArgumentException] { return }
        if ($ownedProcess.HasExited) { return }
        # Both markers are written by fixture scripts. Start time prevents a
        # recycled PID from identifying an unrelated user process.
        if ($ownedProcess.ProcessName -ne 'powershell' -or
            $ownedProcess.StartTime.ToUniversalTime().Ticks -ne [long]$identity.StartTicks) {
            throw 'Refusing to stop a process that does not match the fixture identity.'
        }
        $ownedProcess.Kill()
        if (-not $ownedProcess.WaitForExit(5000)) { throw 'The owned fixture process did not exit.' }
    } finally {
        if ($null -ne $ownedProcess) { $ownedProcess.Dispose() }
    }
}

function Invoke-VisibleGraphicalFixture {
    $fixtureDirectory = Join-Path $script:TestRoot '真实窗口 中文 空格项目'
    $fixtureSource = Join-Path $fixtureDirectory 'src'
    [IO.Directory]::CreateDirectory($fixtureSource) | Out-Null
    Copy-Item -LiteralPath (Join-Path $projectRoot 'Start-ChatGPT.vbs') -Destination (Join-Path $fixtureDirectory 'Start-ChatGPT.vbs')

    $coreFixture = @'
param([switch]$Launch)
$ErrorActionPreference = 'Stop'
$fixtureSelf = [Diagnostics.Process]::GetCurrentProcess()
[IO.File]::WriteAllText((Join-Path $PSScriptRoot '..\core-invoked.json'), (@{
    Id=$PID;StartTicks=$fixtureSelf.StartTime.ToUniversalTime().Ticks;Launch=[bool]$Launch
} | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
$fixtureSelf.Dispose()
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::Out.WriteLine('真实窗口回归：假配置脚本已运行')
exit 0
'@
    # Never copy or call the real installer in this full-entry fixture.
    Write-FixtureScript (Join-Path $fixtureSource 'Install-ChatGPTPortable.ps1') $coreFixture

    $processMarker = @'
$fixtureSelf = [Diagnostics.Process]::GetCurrentProcess()
[IO.File]::WriteAllText((Join-Path $PSScriptRoot '..\gui-process.json'), (@{
    Id=$PID;StartTicks=$fixtureSelf.StartTime.ToUniversalTime().Ticks
} | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
$fixtureSelf.Dispose()

'@
    $diagnostic = @'
# Test-only diagnostics preserve the production ShowDialog and event handlers.
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class ChatGptFixtureWindow
{
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindowVisible(IntPtr handle);
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
}
"@
$script:fixtureShown = $false
$script:fixtureManagedVisible = $false
$script:fixtureNativeVisible = $false
$script:fixtureConsoleVisible = $false
$script:fixtureDeadline = [DateTime]::UtcNow.AddSeconds(6)
$form.Add_Shown({ $script:fixtureShown = $true })
$fixtureTimer = New-Object System.Windows.Forms.Timer
$fixtureTimer.Interval = 100
$fixtureTimer.Add_Tick({
    $script:fixtureManagedVisible = $script:fixtureManagedVisible -or $form.Visible
    $script:fixtureNativeVisible = $script:fixtureNativeVisible -or [ChatGptFixtureWindow]::IsWindowVisible($form.Handle)
    $script:fixtureConsoleVisible = $script:fixtureConsoleVisible -or [ChatGptFixtureWindow]::IsWindowVisible([ChatGptFixtureWindow]::GetConsoleWindow())
    if ($script:setupFinished -or [DateTime]::UtcNow -ge $script:fixtureDeadline) {
        [IO.File]::WriteAllText((Join-Path $PSScriptRoot '..\window-observed.json'), (@{
            ManagedVisible=$script:fixtureManagedVisible
            NativeVisible=$script:fixtureNativeVisible
            ConsoleVisible=$script:fixtureConsoleVisible
            Shown=$script:fixtureShown
            CoreInvoked=(Test-Path -LiteralPath (Join-Path $PSScriptRoot '..\core-invoked.json'))
            SetupFinished=$script:setupFinished
            SetupSucceeded=$script:setupSucceeded
            Log=$logBox.Text
        } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        $fixtureTimer.Stop()
        # Permit automatic close even when startup visibility is incorrect.
        $script:setupFinished = $true
        $form.Close()
    }
})
$form.Add_FormClosed({ $fixtureTimer.Stop(); $fixtureTimer.Dispose() })
$fixtureTimer.Start()

'@
    $graphicalSource = $source
    $graphicalClone = $graphicalSource.Insert($displayTry[0].Extent.StartOffset, $diagnostic)
    $graphicalClone = $graphicalClone.Insert($ast.EndBlock.Statements[0].Extent.StartOffset, $processMarker)
    Write-FixtureScript (Join-Path $fixtureSource 'Start-ChatGPT.ps1') $graphicalClone

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $env:SystemRoot 'System32\cscript.exe'
    # //B also suppresses VBS failure dialogs so a fixture can never block QA.
    $startInfo.Arguments = '//B //NoLogo "' + (Join-Path $fixtureDirectory 'Start-ChatGPT.vbs') + '"'
    $startInfo.WorkingDirectory = $fixtureDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $entryProcess = [Diagnostics.Process]::new()
    $entryProcess.StartInfo = $startInfo
    try {
        if (-not $entryProcess.Start()) { throw 'Could not start the actual VBS entry fixture.' }
        $stdout = $entryProcess.StandardOutput.ReadToEndAsync()
        $stderr = $entryProcess.StandardError.ReadToEndAsync()
        if (-not $entryProcess.WaitForExit(20000)) {
            throw 'The actual VBS and real window fixture exceeded its 20-second timeout.'
        }
        $windowResultPath = Join-Path $fixtureDirectory 'window-observed.json'
        Assert-Equal (Test-Path -LiteralPath $windowResultPath -PathType Leaf) $true ('The real modal window did not record diagnostics. ' + $stderr.GetAwaiter().GetResult())
        $observed = [IO.File]::ReadAllText($windowResultPath) | ConvertFrom-Json
        $summary = "NativeVisible=$($observed.NativeVisible), ManagedVisible=$($observed.ManagedVisible), Shown=$($observed.Shown), CoreInvoked=$($observed.CoreInvoked)."
        Assert-Equal $observed.NativeVisible $true ('The VBS entry left the actual GUI hidden. ' + $summary)
        Assert-Equal $observed.ConsoleVisible $false 'The graphical entry displayed a console window.'
        Assert-Equal $observed.Shown $true ('The actual GUI Shown event never fired. ' + $summary)
        Assert-Equal $observed.CoreInvoked $true ('The actual GUI did not invoke the fake core. ' + $summary)
        Assert-Equal $observed.SetupFinished $true 'The real modal window did not finish its fake setup.'
        Assert-Equal $observed.SetupSucceeded $true 'The real modal window did not report fake setup success.'
        Assert-Equal $observed.Log.Contains('真实窗口回归：假配置脚本已运行') $true 'The real modal window lost fake-core Chinese output.'
        $coreIdentity = [IO.File]::ReadAllText((Join-Path $fixtureDirectory 'core-invoked.json')) | ConvertFrom-Json
        Assert-Equal $coreIdentity.Launch $true 'The actual GUI did not pass -Launch to the fake core.'
        Assert-Equal $entryProcess.ExitCode 0 'The actual VBS did not return the successful GUI exit code.'
        Assert-Equal $stdout.GetAwaiter().GetResult().Trim() '' 'The hidden VBS entry unexpectedly printed console output.'
    } finally {
        # Only recorded fixture identities and the process object started here
        # may be stopped. Existing ChatGPT and PowerShell processes are untouched.
        Stop-OwnedFixtureProcess (Join-Path $fixtureDirectory 'core-invoked.json')
        Stop-OwnedFixtureProcess (Join-Path $fixtureDirectory 'gui-process.json')
        if (-not $entryProcess.HasExited) {
            $entryProcess.Kill()
            $entryProcess.WaitForExit()
        }
        $entryProcess.Dispose()
    }
}

$script:CaseCount = 0
$runId = [guid]::NewGuid().ToString('N')
$script:TestRoot = Join-Path $PSScriptRoot ('.tmp-graphical-' + $runId)
[IO.Directory]::CreateDirectory($script:TestRoot) | Out-Null
$script:FixtureSourceDirectory = $script:TestRoot
$form = $null
$timer = $null
try {
    . $script:GuiInitialization
    Invoke-Case 'A hidden successful worker preserves Chinese stdout, stderr and final queued lines' {
        Invoke-GraphicalFixture 'success' 0
    }
    Invoke-Case 'A hidden failing worker displays its Chinese log and failing exit code' {
        Invoke-GraphicalFixture 'failure' 7
    }
    Invoke-Case 'A missing core script gives a readable failure without starting a worker' {
        Invoke-GraphicalFixture 'missing' 0 -MissingWorker
    }

    $dispatchDirectory = Join-Path $script:TestRoot '分派 中文 空格项目'
    $dispatchSource = Join-Path $dispatchDirectory 'src'
    [IO.Directory]::CreateDirectory($dispatchSource) | Out-Null
    Copy-Item -LiteralPath (Join-Path $projectRoot 'install.cmd') -Destination (Join-Path $dispatchDirectory 'install.cmd')
    Copy-Item -LiteralPath (Join-Path $projectRoot 'Start-ChatGPT.vbs') -Destination (Join-Path $dispatchDirectory 'Start-ChatGPT.vbs')
    $stubGuiPath = Join-Path $dispatchSource 'Start-ChatGPT.ps1'
    $stubGui = @'
$ErrorActionPreference = 'Stop'
[IO.File]::WriteAllText((Join-Path $PSScriptRoot '..\gui-invoked.txt'), 'Fixture GUI only')
exit FIXTURE_EXIT_CODE
'@
    $stubCli = @'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
@($args) | ConvertTo-Json -Compress
exit 19
'@
    Write-FixtureScript (Join-Path $dispatchSource 'Install-ChatGPTPortable.ps1') $stubCli

    Invoke-Case 'No arguments dispatches through the actual VBS to a fake GUI in a Chinese spaced path' {
        Write-FixtureScript $stubGuiPath ($stubGui.Replace('FIXTURE_EXIT_CODE', '0'))
        $result = Invoke-CommandFixture $dispatchDirectory
        Assert-Equal $result.ExitCode 0 'No-argument graphical dispatch failed.'
        Assert-Equal (Test-Path -LiteralPath (Join-Path $dispatchDirectory 'gui-invoked.txt')) $true 'The graphical worker was not invoked.'
        Assert-Equal $result.Output.Trim() '' 'Graphical dispatch invoked the CLI worker.'
    }
    Invoke-Case 'A displayed GUI failure exits through VBS without a second blocking dialog' {
        Write-FixtureScript $stubGuiPath ($stubGui.Replace('FIXTURE_EXIT_CODE', '2'))
        $result = Invoke-CommandFixture $dispatchDirectory
        Assert-Equal $result.ExitCode 1 'The displayed GUI failure was not propagated.'
        Assert-Equal $result.Output.Trim() '' 'GUI failure dispatch invoked the CLI worker.'
    }
    Invoke-Case 'Command-line arguments preserve Chinese spaced values and the core exit code' {
        Remove-Item -LiteralPath (Join-Path $dispatchDirectory 'gui-invoked.txt') -Force
        $result = Invoke-CommandFixture $dispatchDirectory '-StorageRoot "中文 保存目录 with spaces" -Launch'
        Assert-Equal $result.ExitCode 19 'The CLI exit code was not propagated.'
        $arguments = $result.Output | ConvertFrom-Json
        Assert-Equal $arguments.Count 3 'The CLI argument count differs.'
        Assert-Equal $arguments[0] '-StorageRoot' 'The first CLI parameter was lost.'
        Assert-Equal $arguments[1] '中文 保存目录 with spaces' 'A quoted Unicode CLI value was changed.'
        Assert-Equal $arguments[2] '-Launch' 'The launch parameter was lost.'
        Assert-Equal (Test-Path -LiteralPath (Join-Path $dispatchDirectory 'gui-invoked.txt')) $false 'CLI arguments unexpectedly invoked the GUI.'
    }
    Invoke-Case 'The actual VBS shows the real modal GUI and invokes only a fake core in a Chinese spaced path' {
        Invoke-VisibleGraphicalFixture
    }
    Write-Host "Verified $script:CaseCount graphical entry cases using fixture workers only."
} finally {
    if ($null -ne $timer) { $timer.Stop(); $timer.Dispose() }
    if ($null -ne $form) { $form.Dispose() }
    $resolvedTestRoot = [IO.Path]::GetFullPath($script:TestRoot)
    $testPrefix = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedTestRoot.StartsWith($testPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolvedTestRoot) -ne ('.tmp-graphical-' + $runId)) {
        throw 'Refusing to delete a fixture directory outside the verification workspace.'
    }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
}
