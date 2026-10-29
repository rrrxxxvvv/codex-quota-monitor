$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$product = Split-Path $PSScriptRoot -Parent
$dataDir = Join-Path ([IO.Path]::GetTempPath()) ('ui-test-' + [Guid]::NewGuid().ToString())
[IO.Directory]::CreateDirectory($dataDir) | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $product 'Monitor.ps1'), [ref]$tokens, [ref]$errors)
foreach ($name in @('New-Text', 'New-Button', 'New-Window', 'Write-UiError', 'New-LogLocation')) {
    $functionAst = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name}, $true)
    . ([ScriptBlock]::Create($functionAst.Extent.Text))
}
. (Join-Path $product 'Schedule.ps1')
function Find-Button($element, $content) {
    if ($element -is [System.Windows.Controls.Button] -and $element.Content -eq $content) { return $element }
    if ($element -is [System.Windows.DependencyObject]) {
        foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($element)) {
            $found = Find-Button $child $content
            if ($found) { return $found }
        }
    }
    return $null
}
function Click-Button($content) {
    $button = Find-Button $script:scheduleWindow $content
    if (-not $button) { throw "Button not found: $content" }
    $button.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
}
try {
    Show-ScheduleWindow
    if ($script:ruleEnabled.IsChecked) { throw 'New rules should be disabled' }
    if ($script:messageAction.SelectedIndex -ne 0) { throw 'New rules must append by default' }
    $script:ruleName.Text = '设置保存验证'
    $script:ruleTimes.Text = '08:00, 13:00, 18:00'
    $script:ruleThread.Text = 'codex://threads/11111111-1111-4111-8111-111111111111'
    Click-Button '保存规则'
    $saved = [IO.File]::ReadAllText((Join-Path $dataDir 'schedule-rules.json')) | ConvertFrom-Json
    if ($saved.rules.Count -ne 1 -or $saved.rules[0].enabled -or $saved.rules[0].times.Count -ne 3) { throw 'Save round trip failed' }
    if ($saved.rules[0].existingThreadId -ne '11111111-1111-4111-8111-111111111111') { throw 'Thread link normalization failed' }
    $originalId = $saved.rules[0].id
    if ($saved.rules[0].messageAction -ne 'append' -or $saved.rules[0].replaceLastConfirmed) { throw 'Append default did not persist' }
    if ($saved.rules[0].deliveryMode -ne 'ui') { throw 'New rule direct UI default missing' }
    $script:deliveryMode.SelectedIndex = 3
    Click-Button '保存规则'
    if ($script:scheduleFeedback.Text -notlike '*勾选允许关闭客户端*') { throw 'Client shutdown consent not required' }
    $script:releaseDesktopConsent.IsChecked = $true
    Click-Button '保存规则'
    $saved = [IO.File]::ReadAllText((Join-Path $dataDir 'schedule-rules.json')) | ConvertFrom-Json
    if ($saved.rules[0].deliveryMode -ne 'apiUiRestart' -or -not $saved.rules[0].releaseDesktopOnConflict) { throw 'Three-channel route did not persist' }
    $script:deliveryMode.SelectedIndex = 1
    $script:releaseDesktopConsent.IsChecked = $false
    Click-Button '保存规则'
    $script:messageAction.SelectedIndex = 1
    Click-Button '保存规则'
    if ($script:scheduleFeedback.Text -notlike '*勾选允许替换*') { throw 'Unconfirmed replacement was accepted' }
    $script:replaceLastConsent.IsChecked = $true
    Click-Button '保存规则'
    $saved = [IO.File]::ReadAllText((Join-Path $dataDir 'schedule-rules.json')) | ConvertFrom-Json
    if ($saved.rules[0].messageAction -ne 'replaceLast' -or -not $saved.rules[0].replaceLastConfirmed) { throw 'Explicit replacement did not persist' }
    $script:scheduleRules[0].PSObject.Properties.Remove('messageAction')
    $script:scheduleRules[0].PSObject.Properties.Remove('replaceLastConfirmed')
    $script:scheduleRules[0].enabled = $true
    Select-Rule $originalId
    if ($script:messageAction.SelectedIndex -ne -1 -or $script:ruleEnabled.IsChecked) { throw 'Legacy rule silently adopted an action' }
    Click-Button '保存规则'
    if ($script:scheduleFeedback.Text -notlike '*请选择发送方式*') { throw 'Legacy rule saved without action selection' }
    $script:messageAction.SelectedIndex = 0
    Click-Button '保存规则'
    Write-Output 'PASS: append default, explicit replacement consent, and legacy rules require an action selection before re-enabling.'
    $script:ruleName.Text = '修改后名称'; $script:ruleTimes.Text = '09:00'
    Click-Button '保存规则'
    $saved = [IO.File]::ReadAllText((Join-Path $dataDir 'schedule-rules.json')) | ConvertFrom-Json
    if ($saved.rules[0].id -ne $originalId -or $saved.rules[0].times[0] -ne '09:00') { throw 'Editing changed identity or lost times' }
    $script:ruleTimes.Text = '25:99'; Click-Button '保存规则'
    if ($script:scheduleFeedback.Text -notlike '*有效时间*') { throw 'Invalid time was not rejected' }
    $script:ruleTimes.Text = '09:00'
    foreach ($removed in @('立即执行一次（实际发送）', '已核对，解除异常暂停', '复制固定会话 ID')) {
        if (Find-Button $script:scheduleWindow $removed) { throw "Removed button still exists: $removed" }
    }
    $script:ruleType.SelectedIndex = 1
    $script:quotaWindow.SelectedIndex = 1
    $script:ruleTimes.Text = ''
    $script:runMode.SelectedIndex = 1
    $script:runLimit.Text = '2'
    $script:ruleEnabled.IsChecked = $true
    Click-Button '保存规则'
    $saved = [IO.File]::ReadAllText((Join-Path $dataDir 'schedule-rules.json')) | ConvertFrom-Json
    if ($saved.rules[0].type -ne 'quotaReset' -or $saved.rules[0].quotaWindow -ne 'weekly' -or $saved.rules[0].runLimit -ne 2 -or $saved.rules[0].times.Count -ne 0) { throw 'Quota rule or limit did not save' }
    if ($script:dailyFields.Visibility -ne 'Collapsed' -or $script:quotaFields.Visibility -ne 'Visible') { throw 'Rule type fields did not switch' }
    $activation = $saved.rules[0].activationId
    $exhaustedStatus = @{ running = $true; error = $null; busy = $false; logs = @(); rules = @(@{id = $originalId; type = 'quotaReset'; enabled = $false; existingThreadId = ''; binding = $null; nextAt = $null; blocked = $null; lastRun = $null; activationId = $activation; autoDisabled = $true; runLimit = 2; triggerCount = 2}) }
    [IO.File]::WriteAllText((Join-Path $dataDir 'schedule-status.json'), ($exhaustedStatus | ConvertTo-Json -Depth 12), $utf8)
    Update-ScheduleStatus
    $saved = [IO.File]::ReadAllText((Join-Path $dataDir 'schedule-rules.json')) | ConvertFrom-Json
    if ($saved.rules[0].enabled -or $script:ruleEnabled.IsChecked) { throw 'Exhausted rule not automatically disabled' }
    if ($script:triggerProgress.Text -ne '已触发 2 / 2 次') { throw 'Visible progress did not update' }
    $script:ruleEnabled.IsChecked = $true
    Click-Button '保存规则'
    $saved = [IO.File]::ReadAllText((Join-Path $dataDir 'schedule-rules.json')) | ConvertFrom-Json
    if (-not $saved.rules[0].enabled -or $saved.rules[0].activationId -eq $activation) { throw 'Re-enable did not reset generation or stale status disabled it again' }
    if ($script:triggerProgress.Text -ne '已触发 0 / 2 次') { throw 'Visible progress did not reset on reactivation' }
    $script:scheduleRules[0].existingThreadId = ''
    Save-ScheduleConfig
    $script:ruleThread.Text = ''
    $script:ruleName.Text = '尚未保存的名称'
    $script:ruleTimes.Text = '10:25'
    $boundId = [Guid]::NewGuid().ToString()
    $liveStatus = @{ running = $true; error = $null; busy = $false; logs = @(); rules = @(@{id = $originalId; existingThreadId = ''; binding = @{threadId = $boundId}; nextAt = $null; blocked = $null; lastRun = $null}) }
    [IO.File]::WriteAllText((Join-Path $dataDir 'schedule-status.json'), ($liveStatus | ConvertTo-Json -Depth 12), $utf8)
    Update-ScheduleStatus
    if ($script:ruleThread.Text -ne $boundId -or -not $script:ruleThread.IsReadOnly) { throw 'Binding did not fill the actual rule field' }
    $saved = [IO.File]::ReadAllText((Join-Path $dataDir 'schedule-rules.json')) | ConvertFrom-Json
    if ($saved.rules[0].existingThreadId -ne $boundId) { throw 'Automatic binding was not persisted' }
    if ($script:ruleName.Text -ne '尚未保存的名称' -or $script:ruleTimes.Text -ne '10:25') { throw 'Backfill overwrote unsaved editor changes' }
    Select-Rule $originalId
    if ($script:ruleThread.Text -ne $boundId) { throw 'Binding lost after reselecting rule' }
    $script:ruleType.SelectedIndex = 2
    Set-RuleDateTime $script:datePicker '2028-02-29T23:59'
    Click-Button '添加日期时间'; Click-Button '添加日期时间'
    Set-RuleDateTime $script:datePicker '2028-03-01T08:05'
    Click-Button '添加日期时间'
    $script:ruleMessage.Text = "自定义消息`r`n第二行  "
    $script:runMode.SelectedIndex = 2
    Click-Button '保存规则'
    $saved = [IO.File]::ReadAllText((Join-Path $dataDir 'schedule-rules.json')) | ConvertFrom-Json
    if ($saved.rules[0].type -ne 'dates' -or $saved.rules[0].dates.Count -ne 2 -or $saved.rules[0].runLimit -ne 1) { throw 'Dated/once rule save failed' }
    if ($saved.rules[0].message -ne "自定义消息`r`n第二行  ") { throw 'Custom text was altered' }
    Select-Rule $originalId
    if ($script:ruleDates.Items.Count -ne 2 -or $script:runMode.SelectedIndex -ne 2 -or $script:datesFields.Visibility -ne 'Visible') { throw 'Dated rule reload failed' }
    if ($script:triggerProgress.Visibility -ne 'Visible' -or $script:triggerProgress.Text -notlike '*/ 1 次') { throw 'Once progress hidden' }
    $script:ruleDates.SelectedIndex = 0; Click-Button '移除所选时间'
    if ($script:ruleDates.Items.Count -ne 1) { throw 'Remove date failed' }
    $script:ruleType.SelectedIndex = 3
    Set-RuleDateTime $script:intervalPicker '2028-03-01T08:05'
    $script:intervalValue.Text = '5'; $script:intervalUnit.SelectedIndex = 1
    $script:runMode.SelectedIndex = 1; $script:runLimit.Text = '3'
    Click-Button '保存规则'
    $saved = [IO.File]::ReadAllText((Join-Path $dataDir 'schedule-rules.json')) | ConvertFrom-Json
    if ($saved.rules[0].type -ne 'interval' -or $saved.rules[0].startAt -ne '2028-03-01T08:05' -or $saved.rules[0].intervalMinutes -ne 300 -or $saved.rules[0].runLimit -ne 3) { throw 'Interval save failed' }
    Select-Rule $originalId
    if ((Get-RuleDateTime $script:intervalPicker) -ne '2028-03-01T08:05' -or $script:intervalValue.Text -ne '300') { throw 'Interval round trip failed' }
    $script:intervalValue.Text = '0'; Click-Button '保存规则'
    if ($script:scheduleFeedback.Text -notlike '*正整数*') { throw 'Invalid interval accepted' }
    $script:intervalValue.Text = '300'
    $script:ruleMessage.Text = ' '; Click-Button '保存规则'
    if ($script:scheduleFeedback.Text -notlike '*消息内容*') { throw 'Blank message accepted' }
    Select-Rule $originalId
    if ($script:ruleType.Items[4].IsEnabled) { throw 'Program trigger must stay disabled' }
    $script:ruleType.SelectedIndex = 0
    $script:ruleTimes.Text = ''; $script:dailyPicker.Hour.SelectedIndex = 8; $script:dailyPicker.Minute.SelectedIndex = 5
    Click-Button '添加时间'; Click-Button '添加时间'
    if ($script:ruleTimes.Text -ne '08:05') { throw 'Time picker or dedup failed' }
    Select-Rule $originalId
    Write-Output 'PASS: date/time pickers, multiple dates, interval units, custom multiline text, once progress, persistence and input validation.'
    $errorStatus = @{ running = $true; error = 'Simulated scheduler failure'; busy = $false; logs = @(); rules = @() }
    [IO.File]::WriteAllText((Join-Path $dataDir 'schedule-status.json'), ($errorStatus | ConvertTo-Json -Depth 12), $utf8)
    Update-ScheduleStatus
    if ($script:scheduleLogLocation.Visibility -ne 'Visible') { throw 'Error log location is hidden' }
    $pathBox = @($script:scheduleLogLocation.Children | Where-Object { $_ -is [Windows.Controls.TextBox] })[0]
    foreach ($logFile in @('schedule-state.json', 'schedule-status.json', 'ui-errors.log')) {
        if (-not $pathBox.Text.Contains([IO.Path]::GetFullPath((Join-Path $dataDir $logFile)))) { throw 'Log location is not absolute or is missing' }
    }
    if (-not $pathBox.IsReadOnly) { throw 'Log paths should be selectable but read-only' }
    function Start-Process { param($FilePath, $ArgumentList, $WindowStyle) $script:openedLogFolder = @{file=$FilePath;args=$ArgumentList} }
    Click-Button '打开日志文件夹'
    if ($script:openedLogFolder.file -ne 'explorer.exe' -or $script:openedLogFolder.args -ne ('"' + [IO.Path]::GetFullPath($dataDir) + '"')) { throw 'Wrong folder-open request' }
    Remove-Item Function:Start-Process
    Write-Output 'PASS: error reveals selectable absolute diagnostic paths and folder-open action targets the actual data directory.'
    . (Join-Path $product 'Remote.ps1')
    [IO.File]::WriteAllText((Join-Path $dataDir 'remote-status.json'), '{"enabled":true,"error":"Simulated upload failure"}', $utf8)
    Show-RemoteWindow
    if ($script:remoteLogLocation.Visibility -ne 'Visible' -or $script:remoteStatusText.Text -notlike '*Simulated upload failure*') { throw 'Upload diagnostics not visible' }
    $remotePaths = @($script:remoteLogLocation.Children | Where-Object { $_ -is [Windows.Controls.TextBox] })[0]
    if (-not $remotePaths.Text.Contains([IO.Path]::GetFullPath((Join-Path $dataDir 'remote-status.json')))) { throw 'Upload status path missing' }
    [IO.File]::WriteAllText((Join-Path $dataDir 'remote-status.json'), '{"enabled":false,"error":null}', $utf8)
    Update-RemoteStatus
    if ($script:remoteLogLocation.Visibility -ne 'Collapsed') { throw 'Healthy upload diagnostics did not collapse' }
    $script:remoteWindow.Close()
    Write-Output 'PASS: upload error location is visible and collapses after recovery.'
    $script:scheduleWindow.UpdateLayout()
    $script:scheduleWindow.Content.Children[-1].Children[-1].ScrollToBottom()
    $script:scheduleWindow.UpdateLayout()
    $visual = $script:scheduleWindow
    $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$visual.ActualWidth, [int]$visual.ActualHeight, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($visual)
    $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.File]::Create((Join-Path $dataDir 'ui-rule-preview.png'))
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
    Write-Output (Join-Path $dataDir 'ui-rule-preview.png')
    Click-Button '删除所选规则'
    $saved = [IO.File]::ReadAllText((Join-Path $dataDir 'schedule-rules.json')) | ConvertFrom-Json
    if ($saved.rules.Count -ne 0) { throw 'Delete failed' }
    Write-Output 'PASS: quota/daily UI, count limit, automatic disable/reactivation, removed buttons, ID backfill, persistence, unsaved edits preserved. No live messages sent.'
    $app = New-Object Windows.Application
    $app.ShutdownMode = 'OnExplicitShutdown'
    $handlerAst = $ast.Find({param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -eq 'Add_DispatcherUnhandledException'}, $true)
    . ([ScriptBlock]::Create($handlerAst.Extent.Text))
    $faultTimer = New-Object Windows.Threading.DispatcherTimer
    $faultTimer.Interval = [TimeSpan]::FromMilliseconds(50)
    $faultTimer.Add_Tick({ $faultTimer.Stop(); throw 'Simulated UI callback failure' })
    $finishTimer = New-Object Windows.Threading.DispatcherTimer
    $finishTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $finishTimer.Add_Tick({ $finishTimer.Stop(); $app.Shutdown() })
    $faultTimer.Start(); $finishTimer.Start()
    $app.Run() | Out-Null
    if (-not [IO.File]::Exists((Join-Path $dataDir 'ui-errors.log'))) { throw 'Unhandled UI error was not captured' }
    if ([IO.File]::ReadAllText((Join-Path $dataDir 'ui-errors.log')) -notlike '*Simulated UI callback failure*') { throw 'Wrong error recorded' }
    Write-Output 'PASS: real WPF dispatcher callback failure captured without terminating the application loop.'
} finally { if ($script:scheduleWindow) { $script:scheduleWindow.Close() } }
