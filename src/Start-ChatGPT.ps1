#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# .NET callbacks collect output without running PowerShell on a worker thread.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

public static class ChatGptSetupWindow
{
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(IntPtr window, IntPtr insertAfter,
        int x, int y, int width, int height, uint flags);

    public static void Show(IntPtr window)
    {
        // SWP_SHOWWINDOW explicitly reveals the form even when WScript starts
        // PowerShell with SW_HIDE. The PowerShell console stays hidden.
        const uint flags = 0x0040 | 0x0001 | 0x0002 | 0x0004 | 0x0010;
        if (!SetWindowPos(window, IntPtr.Zero, 0, 0, 0, 0, flags))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
}

public sealed class ChatGptSetupOutput : IDisposable
{
    private readonly Process process;
    private readonly ConcurrentQueue<string> lines = new ConcurrentQueue<string>();
    private int pendingStreams = 2;

    public ChatGptSetupOutput(Process process)
    {
        this.process = process;
        process.OutputDataReceived += ReceiveOutput;
        process.ErrorDataReceived += ReceiveOutput;
    }

    private void ReceiveOutput(object sender, DataReceivedEventArgs args)
    {
        if (args.Data == null)
            Interlocked.Decrement(ref pendingStreams);
        else
            lines.Enqueue(args.Data);
    }

    public bool TryRead(out string line) { return lines.TryDequeue(out line); }
    public bool StreamsFinished { get { return Interlocked.CompareExchange(ref pendingStreams, 0, 0) == 0; } }

    public void Dispose()
    {
        process.OutputDataReceived -= ReceiveOutput;
        process.ErrorDataReceived -= ReceiveOutput;
    }
}
'@

$form = New-Object System.Windows.Forms.Form
$form.Text = 'ChatGPT 免安装'
$form.ClientSize = New-Object System.Drawing.Size(720, 480)
$form.MinimumSize = New-Object System.Drawing.Size(620, 420)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
$form.Add_Load({ [ChatGptSetupWindow]::Show($form.Handle) })

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = '正在准备 ChatGPT，请稍候…'
$statusLabel.Location = New-Object System.Drawing.Point(20, 18)
$statusLabel.Size = New-Object System.Drawing.Size(680, 28)
$statusLabel.Anchor = 'Top, Left, Right'
$form.Controls.Add($statusLabel)

$explanationLabel = New-Object System.Windows.Forms.Label
$explanationLabel.Text = '将检查官方版本、完成免安装配置并请求启动。首次下载可能需要几分钟。'
$explanationLabel.Location = New-Object System.Drawing.Point(20, 52)
$explanationLabel.Size = New-Object System.Drawing.Size(680, 36)
$explanationLabel.Anchor = 'Top, Left, Right'
$form.Controls.Add($explanationLabel)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(20, 93)
$progressBar.Size = New-Object System.Drawing.Size(680, 12)
$progressBar.Style = 'Marquee'
$progressBar.MarqueeAnimationSpeed = 30
$progressBar.Anchor = 'Top, Left, Right'
$form.Controls.Add($progressBar)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location = New-Object System.Drawing.Point(20, 121)
$logBox.Size = New-Object System.Drawing.Size(680, 290)
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.Anchor = 'Top, Bottom, Left, Right'
$logBox.BackColor = [System.Drawing.SystemColors]::Window
$logBox.MaxLength = 0
$form.Controls.Add($logBox)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = '关闭'
$closeButton.Location = New-Object System.Drawing.Point(590, 429)
$closeButton.Size = New-Object System.Drawing.Size(110, 32)
$closeButton.Anchor = 'Bottom, Right'
$closeButton.Enabled = $false
$closeButton.Add_Click({ $form.Close() })
$form.Controls.Add($closeButton)

$script:setupProcess = $null
$script:setupOutput = $null
$script:setupFinished = $false
$script:setupSucceeded = $false
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 150

function Complete-SetupDisplay {
    param([bool]$Succeeded, [string]$FailureReason)
    $timer.Stop()
    $script:setupFinished = $true
    $script:setupSucceeded = $Succeeded
    $progressBar.MarqueeAnimationSpeed = 0
    $progressBar.Style = 'Blocks'
    if ($Succeeded) {
        $progressBar.Value = 100
        $statusLabel.Text = '免安装配置成功，已发出启动请求'
        $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(20, 110, 65)
        $explanationLabel.Text = '如未看到 ChatGPT，请先退出已运行的旧实例，再使用桌面快捷方式启动。'
    } else {
        $progressBar.Value = 0
        $statusLabel.Text = '操作未完成，请查看下方原因'
        $statusLabel.ForeColor = [System.Drawing.Color]::Firebrick
        $explanationLabel.Text = '可选中并复制日志。解决提示中的问题后，再次双击启动即可重试。'
        if (-not [string]::IsNullOrWhiteSpace($FailureReason)) {
            $logBox.AppendText($FailureReason + [Environment]::NewLine)
        }
    }
    $closeButton.Enabled = $true
    $form.AcceptButton = $closeButton
}

$timer.Add_Tick({
    try {
        $line = $null
        while ($script:setupOutput.TryRead([ref]$line)) {
            $logBox.AppendText($line + [Environment]::NewLine)
        }
        if ($script:setupProcess.HasExited -and $script:setupOutput.StreamsFinished) {
            # Drain any final lines queued while checking completion.
            while ($script:setupOutput.TryRead([ref]$line)) {
                $logBox.AppendText($line + [Environment]::NewLine)
            }
            if ($script:setupProcess.ExitCode -eq 0) {
                Complete-SetupDisplay -Succeeded $true
            } else {
                Complete-SetupDisplay -Succeeded $false -FailureReason ('配置进程退出，退出码：' + $script:setupProcess.ExitCode)
            }
        }
    } catch {
        Complete-SetupDisplay -Succeeded $false -FailureReason ('无法读取运行状态：' + $_.Exception.Message)
    }
})

$form.Add_Shown({
    try {
        $coreScript = Join-Path $PSScriptRoot 'Install-ChatGPTPortable.ps1'
        if (-not (Test-Path -LiteralPath $coreScript -PathType Leaf)) {
            throw '找不到配置脚本，请完整解压项目后再运行。'
        }
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "' + $coreScript + '" -Launch'
        $startInfo.WorkingDirectory = [Environment]::CurrentDirectory
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.WindowStyle = 'Hidden'
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
        $script:setupProcess = New-Object System.Diagnostics.Process
        $script:setupProcess.StartInfo = $startInfo
        $script:setupOutput = New-Object ChatGptSetupOutput($script:setupProcess)
        if (-not $script:setupProcess.Start()) { throw '无法启动配置进程。' }
        $script:setupProcess.BeginOutputReadLine()
        $script:setupProcess.BeginErrorReadLine()
        $timer.Start()
    } catch {
        Complete-SetupDisplay -Succeeded $false -FailureReason $_.Exception.Message
    }
})

$form.Add_FormClosing({
    param($sender, $eventArgs)
    if (-not $script:setupFinished -and $eventArgs.CloseReason -eq 'UserClosing') {
        $eventArgs.Cancel = $true
        [void][System.Windows.Forms.MessageBox]::Show($form, '正在下载或配置，请等待完成后再关闭。', 'ChatGPT 免安装', 'OK', 'Information')
    }
})

try {
    [void]$form.ShowDialog()
} finally {
    $timer.Stop()
    $timer.Dispose()
    if ($null -ne $script:setupOutput) { $script:setupOutput.Dispose() }
    if ($null -ne $script:setupProcess) { $script:setupProcess.Dispose() }
    $form.Dispose()
}
# VBS recognizes exit 2 as a setup failure already explained in this window.
if ($script:setupSucceeded) { exit 0 }
exit 2
