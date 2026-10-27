param([switch]$SmokeTest, [switch]$OpenSchedule)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
$mutex = New-Object Threading.Mutex($false, 'Local\CodexQuotaMonitor_v1')
if (-not $mutex.WaitOne(0)) {
    if ($OpenSchedule) {
        [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'data\show-schedule'), 'open')
        exit
    }
    [System.Windows.MessageBox]::Show('额度监控已经在运行，请从系统托盘打开。', 'Codex 额度监控') | Out-Null
    exit
}
$script:backend = $null
$script:exiting = $false
$script:popup = $null
$script:acknowledged = New-Object 'System.Collections.Generic.HashSet[string]'
$dataDir = Join-Path $PSScriptRoot 'data'
[IO.Directory]::CreateDirectory($dataDir) | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)

function Write-UiError($errorValue) {
    try {
        $entry = [DateTimeOffset]::Now.ToString('o') + ' ' + $errorValue.ToString() + [Environment]::NewLine
        [IO.File]::AppendAllText((Join-Path $dataDir 'ui-errors.log'), $entry, $utf8)
    } catch { }
}

function New-Text($text, $size, $color) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $text; $t.FontSize = $size; $t.Foreground = $color
    $t.TextWrapping = 'Wrap'; $t.Margin = '0,0,0,14'
    return $t
}
function New-Button($text) {
    $b = New-Object System.Windows.Controls.Button
    $b.Content = $text; $b.Padding = '18,10'; $b.Margin = '0,6,10,0'; $b.FontSize = 14
    return $b
}
function New-Window($title, $width, $height) {
    $w = New-Object System.Windows.Window
    $w.Title = $title; $w.Width = $width; $w.Height = $height
    $w.MinWidth = 440; $w.MinHeight = 320; $w.Background = '#F5F7FB'
    $w.FontFamily = 'Microsoft YaHei UI'; $w.WindowStartupLocation = 'CenterScreen'
    return $w
}
function Write-Acknowledgements {
    $json = ConvertTo-Json -InputObject @($script:acknowledged) -Compress
    [IO.File]::WriteAllText((Join-Path $dataDir 'ack.json'), $json, $utf8)
}
function Show-Alert($events, [bool]$test = $false) {
    if ($script:popup) { $script:popup.Activate() | Out-Null; return }
    $w = New-Window 'Codex 额度提醒 — 手动关闭后消失' 560 440
    $w.Topmost = $true
    $w.ResizeMode = 'CanResize'
    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = '28'
    $heading = if ($test) { '测试提醒' } else { 'Codex 额度有更新' }
    $panel.Children.Add((New-Text $heading 26 '#182848')) | Out-Null
    $panel.Children.Add((New-Text '此窗口持续置顶。点击“关闭提醒”或右上角 × 才会关闭。' 14 '#53627B')) | Out-Null
    $script:alertDetails = New-Text '' 17 '#182848'
    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.MaxHeight = 210; $scroll.VerticalScrollBarVisibility = 'Auto'; $scroll.Content = $script:alertDetails
    $panel.Children.Add($scroll) | Out-Null
    $close = New-Button '关闭提醒'
    $close.Add_Click({ $script:popup.Close() })
    $panel.Children.Add($close) | Out-Null
    $w.Content = $panel
    $w.Tag = @{ Test = $test; Events = @($events) }
    $w.Add_StateChanged({ if ($this.WindowState -eq 'Minimized') { $this.WindowState = 'Normal' } })
    $w.Add_Closed({
        if (-not $this.Tag.Test -and -not $script:exiting) {
            foreach ($eventItem in $this.Tag.Events) { $script:acknowledged.Add([string]$eventItem.id) | Out-Null }
            Write-Acknowledgements
        }
        $script:popup = $null
    })
    $script:popup = $w
    Update-Alert $events $test
    $w.Show()
    $w.Activate() | Out-Null
}
function Update-Alert($events, [bool]$test) {
    if ($test) { $script:alertDetails.Text = "这是显示效果测试，没有发生真实额度重置。`n`n没有倒计时，也不会自动消失。"; return }
    $script:popup.Tag.Events = @($events)
    $lines = foreach ($eventItem in $events) {
        $stamp = ([DateTimeOffset]::Parse($eventItem.detectedAt)).ToLocalTime().ToString('MM-dd HH:mm')
        "$($eventItem.label)：$($eventItem.kind)`n剩余 $($eventItem.remaining)%　·　检测于 $stamp"
    }
    $script:alertDetails.Text = $lines -join "`n`n"
}

. (Join-Path $PSScriptRoot 'Schedule.ps1')
. (Join-Path $PSScriptRoot 'Remote.ps1')

try {
    $main = New-Window 'Codex 额度监控与自动执行' 680 590
    $main.MinHeight = 540
    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = '28'
    $panel.Children.Add((New-Text 'Codex 额度监控' 28 '#182848')) | Out-Null
    $panel.Children.Add((New-Text '每分钟读取官方额度状态 · 重置后持续置顶提醒' 14 '#53627B')) | Out-Null
    $script:health = New-Text '正在连接本机 Codex 服务…' 14 '#356649'
    $script:details = New-Text '' 16 '#182848'
    $panel.Children.Add($script:health) | Out-Null
    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.Height = 205; $scroll.VerticalScrollBarVisibility = 'Auto'; $scroll.Content = $script:details
    $panel.Children.Add($scroll) | Out-Null
    $buttons = New-Object System.Windows.Controls.WrapPanel
    $scheduleButton = New-Button '自动执行规则'
    $scheduleButton.Add_Click({ Show-ScheduleWindow })
    $remoteButton = New-Button 'AstrBot 推送'
    $remoteButton.Add_Click({ Show-RemoteWindow })
    $hideButton = New-Button '收起到托盘'
    $hideButton.Add_Click({ $main.Hide() })
    $exitButton = New-Button '退出监控'
    $exitButton.Add_Click({ $script:exiting = $true; $main.Close() })
    foreach ($b in @($scheduleButton, $remoteButton, $hideButton, $exitButton)) { $buttons.Children.Add($b) | Out-Null }
    $panel.Children.Add($buttons) | Out-Null
    $hint = New-Text '关闭此主窗口会收起到托盘；“退出监控”才会停止。电脑睡眠或关机期间无法检测，恢复运行后继续检查。' 12 '#53627B'
    $hint.Margin = '0,18,0,0'; $panel.Children.Add($hint) | Out-Null
    $main.Content = $panel
    $main.Add_Closing({ if (-not $script:exiting) { $_.Cancel = $true; $main.Hide() } })

    $tray = New-Object System.Windows.Forms.NotifyIcon
    $tray.Icon = [System.Drawing.SystemIcons]::Information
    $tray.Text = 'Codex 额度监控'; $tray.Visible = $true
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $showMenu = $menu.Items.Add('打开额度监控')
    $showMenu.Add_Click({ $main.Show(); $main.Activate() | Out-Null })
    $scheduleMenu = $menu.Items.Add('自动执行规则')
    $scheduleMenu.Add_Click({ Show-ScheduleWindow })
    $quitMenu = $menu.Items.Add('退出监控')
    $quitMenu.Add_Click({ $script:exiting = $true; $main.Close() })
    $tray.ContextMenuStrip = $menu
    $tray.Add_DoubleClick({ $main.Show(); $main.Activate() | Out-Null })

    $nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $nodeCommand) { throw '未找到 Node.js。请先安装 Node.js，或将 node.exe 加入 PATH。' }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $nodeCommand.Source
    $start.Arguments = '"' + (Join-Path $PSScriptRoot 'monitor.cjs') + '"'
    $start.WorkingDirectory = $PSScriptRoot
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $script:backend = [Diagnostics.Process]::Start($start)

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(1)
    $timer.Add_Tick({
        try {
            $showScheduleFile = Join-Path $dataDir 'show-schedule'
            if ([IO.File]::Exists($showScheduleFile)) { [IO.File]::Delete($showScheduleFile); Show-ScheduleWindow }
            if ($script:backend.HasExited) { $script:health.Text = '监控进程已退出，请退出此程序后重新启动。'; $script:health.Foreground = '#B33B32'; return }
            $statusPath = Join-Path $dataDir 'status.json'
            if (-not [IO.File]::Exists($statusPath)) { return }
            $s = [IO.File]::ReadAllText($statusPath) | ConvertFrom-Json
            if ($s.error) {
                $script:health.Text = "读取失败，正在自动重试（显示上次成功数据）：$($s.error)"
                $script:health.Foreground = '#B33B32'
            } elseif ($s.checkedAt) {
                $checked = [DateTimeOffset]::Parse($s.checkedAt)
                $stale = ([DateTimeOffset]::Now - $checked).TotalSeconds -gt 180
                $script:health.Text = if ($stale) { '数据暂未更新，等待下一次成功读取。上次：' + $checked.ToLocalTime().ToString('MM-dd HH:mm:ss') } else { '监控中 · 最近成功检查：' + $checked.ToLocalTime().ToString('MM-dd HH:mm:ss') }
                $script:health.Foreground = if ($stale) { '#B36B20' } else { '#356649' }
            }
            $lines = foreach ($prop in $s.windows.PSObject.Properties) {
                $w = $prop.Value
                $reset = [DateTimeOffset]::FromUnixTimeSeconds([long]$w.resetsAt).ToLocalTime().ToString('yyyy-MM-dd HH:mm')
                "$($w.label)`n剩余 $($w.remaining)%（已用 $($w.usedPercent)%）`n接口返回的下次重置时间：$reset"
            }
            $lines = @($lines)
            if ($null -ne $s.resetCredits) {
                $cardText = "重置卡剩余次数：$($s.resetCredits.availableCount)"
                foreach ($expiry in $s.resetCredits.expiresAt) {
                    $expiryText = if ($null -eq $expiry) { '接口未提供' } else { [DateTimeOffset]::FromUnixTimeSeconds([long]$expiry).ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-dd HH:mm:ss') }
                    $cardText += "`n到期时间（北京时间）：$expiryText"
                }
                $lines += $cardText
            } else { $lines += '重置卡剩余次数／到期时间：接口暂未提供' }
            $script:details.Text = $lines -join "`n`n"
            $pending = @($s.pending | Where-Object { -not $script:acknowledged.Contains([string]$_.id) })
            if ($pending.Count -gt 0) {
                if (-not $script:popup) { Show-Alert $pending $false }
                elseif (-not $script:popup.Tag.Test) { Update-Alert $pending $false }
            }
        } catch { $script:health.Text = '正在等待完整状态数据…' }
    })
    $timer.Start()
    $app = New-Object Windows.Application
    $app.ShutdownMode = 'OnMainWindowClose'
    $app.Add_DispatcherUnhandledException({
        param($sender, $eventArgs)
        $eventArgs.Handled = $true
        Write-UiError $eventArgs.Exception
        if ($script:scheduleFeedback) { $script:scheduleFeedback.Text = '操作未完成：' + $eventArgs.Exception.GetBaseException().Message }
        if ($script:health) { $script:health.Text = '界面操作未完成，监控继续运行。详情已记录。' }
    })
    if ($OpenSchedule -and -not $SmokeTest) { $main.Add_ContentRendered({ Show-ScheduleWindow }) }
    if ($SmokeTest) {
        $main.Add_ContentRendered({ Show-Alert @() $true; Show-ScheduleWindow })
        $smoke = New-Object Windows.Threading.DispatcherTimer
        $smoke.Interval = [TimeSpan]::FromSeconds(8)
        $smoke.Add_Tick({
            $result = @{ Topmost = $script:popup.Topmost; Visible = $script:popup.IsVisible; BackendAlive = -not $script:backend.HasExited; StatusText = $script:health.Text; ScheduleVisible = $script:scheduleWindow.IsVisible; ScheduleRuleCount = $script:ruleList.Items.Count; ScheduleStatus = $script:ruleStatus.Text }
            [IO.File]::WriteAllText((Join-Path $dataDir 'smoke-test.json'), ($result | ConvertTo-Json), $utf8)
            $visual = $script:scheduleWindow
            $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$visual.ActualWidth, [int]$visual.ActualHeight, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
            $bitmap.Render($visual)
            $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
            $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
            $stream = [IO.File]::Create((Join-Path $dataDir 'schedule-preview.png'))
            try { $encoder.Save($stream) } finally { $stream.Dispose() }
            $smoke.Stop(); $script:exiting = $true; $main.Close()
        })
        $smoke.Start()
    }
    $app.Run($main) | Out-Null
} catch {
    [IO.File]::WriteAllText((Join-Path $dataDir 'startup-error.txt'), $_.ToString(), $utf8)
    [System.Windows.MessageBox]::Show($_.Exception.Message, '额度监控启动失败') | Out-Null
} finally {
    if ($timer) { $timer.Stop() }
    if ($tray) { $tray.Visible = $false; $tray.Dispose() }
    if ($script:backend -and -not $script:backend.HasExited) {
        try { $script:backend.StandardInput.WriteLine('stop'); $script:backend.StandardInput.Close() } catch {}
        if (-not $script:backend.WaitForExit(5000)) { $script:backend.Kill() }
    }
    $mutex.ReleaseMutex(); $mutex.Dispose()
}
