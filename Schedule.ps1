# Loaded by Monitor.ps1; no independent background process is needed.
function Save-ScheduleConfig {
    $payload = @{ version = 1; timeZone = 'Asia/Shanghai'; rules = @($script:scheduleRules.ToArray()) }
    $file = Join-Path $dataDir 'schedule-rules.json'
    $temporary = $file + '.ui-tmp'
    [IO.File]::WriteAllText($temporary, ($payload | ConvertTo-Json -Depth 12), $utf8)
    Move-Item -LiteralPath $temporary -Destination $file -Force
}
function Refresh-RuleList {
    $script:ruleList.Items.Clear()
    foreach ($rule in $script:scheduleRules) {
        $item = New-Object System.Windows.Controls.ListBoxItem
        $stateLabel = if ($rule.enabled) { '已启用' } else { '未启用' }
        $condition = if ($rule.type -eq 'quotaReset') {
            $scope = switch ($rule.quotaWindow) { 'fiveHour' { '五小时' }; 'weekly' { '每周' }; default { '任一额度' } }
            "额度刷新 · $scope"
        } else { '每日定时 · ' + ($rule.times -join '、') }
        $item.Content = "$($rule.name)  [$stateLabel]`n$condition"
        $item.Tag = $rule.id; $item.Padding = '8'; $item.Margin = '0,0,0,5'
        $script:ruleList.Items.Add($item) | Out-Null
    }
}
function Update-RuleTypeFields {
    if (-not $script:dailyFields -or -not $script:quotaFields) { return }
    $isQuota = $script:ruleType.SelectedIndex -eq 1
    $script:dailyFields.Visibility = if ($isQuota) { 'Collapsed' } else { 'Visible' }
    $script:quotaFields.Visibility = if ($isQuota) { 'Visible' } else { 'Collapsed' }
}
function Update-RunLimitFields {
    if ($script:runLimitBox) { $script:runLimitBox.Visibility = if ($script:runMode.SelectedIndex -eq 1) { 'Visible' } else { 'Collapsed' } }
    Update-TriggerProgress
}
function Update-TriggerProgress {
    if (-not $script:triggerProgress) { return }
    $saved = @($script:scheduleRules | Where-Object { $_.id -eq $script:editingRuleId }) | Select-Object -First 1
    $live = @($script:lastScheduleStatus.rules | Where-Object { $_.id -eq $script:editingRuleId }) | Select-Object -First 1
    $count = 0
    $savedActivation = if ($saved.activationId) { $saved.activationId } else { 'legacy' }
    $liveActivation = if ($live.activationId) { $live.activationId } else { 'legacy' }
    if ($saved -and $live -and $savedActivation -eq $liveActivation) { $count = [int]$live.triggerCount }
    $limitText = if ($script:runLimit) { $script:runLimit.Text.Trim() } else { '' }
    $script:triggerProgress.Text = "已触发 $count / $limitText 次"
}
function Select-Rule($id) {
    $script:editingRuleId = $id
    $rule = @($script:scheduleRules | Where-Object { $_.id -eq $id }) | Select-Object -First 1
    if ($rule) {
        $script:ruleName.Text = $rule.name
        $script:ruleTimes.Text = $rule.times -join ', '
        $script:ruleThread.Text = $rule.existingThreadId
        $script:ruleEnabled.IsChecked = $rule.enabled
        $script:ruleType.SelectedIndex = if ($rule.type -eq 'quotaReset') { 1 } else { 0 }
        $script:quotaWindow.SelectedIndex = switch ($rule.quotaWindow) { 'fiveHour' { 0 }; 'weekly' { 1 }; default { 2 } }
        $script:runMode.SelectedIndex = if ($null -ne $rule.runLimit) { 1 } else { 0 }
        $script:runLimit.Text = if ($null -ne $rule.runLimit) { [string]$rule.runLimit } else { '1' }
    } else {
        $script:ruleName.Text = ''
        $script:ruleTimes.Text = ''
        $script:ruleThread.Text = ''
        $script:ruleEnabled.IsChecked = $false
        $script:ruleType.SelectedIndex = 0
        $script:quotaWindow.SelectedIndex = 2
        $script:runMode.SelectedIndex = 0
        $script:runLimit.Text = '1'
    }
    Update-RuleTypeFields
    Update-RunLimitFields
    $script:scheduleFeedback.Text = ''
    Update-ScheduleStatus
}
function Send-ScheduleCommand($type) {
    $rule = @($script:scheduleRules | Where-Object { $_.id -eq $script:editingRuleId }) | Select-Object -First 1
    if (-not $rule) { $script:scheduleFeedback.Text = '请先填写触发条件并保存规则。'; return }
    $dir = Join-Path $dataDir 'schedule-commands'; [IO.Directory]::CreateDirectory($dir) | Out-Null
    $file = Join-Path $dir (([Guid]::NewGuid().ToString()) + '.json')
    $temporary = $file + '.tmp'
    [IO.File]::WriteAllText($temporary, (@{type = $type; ruleId = $rule.id} | ConvertTo-Json), $utf8)
    Move-Item -LiteralPath $temporary -Destination $file
    $script:scheduleFeedback.Text = if ($type -eq 'runNow') { '已提交一次实际执行。请在下方查看结果。' } else { '已提交解除暂停请求；不会补发已经过去的时刻。' }
}
function Update-ScheduleStatus {
    if (-not $script:scheduleWindow) { return }
    try {
        $file = Join-Path $dataDir 'schedule-status.json'
        if (-not [IO.File]::Exists($file)) { $script:ruleStatus.Text = '正在等待定时服务…'; return }
        $status = [IO.File]::ReadAllText($file) | ConvertFrom-Json
        $script:lastScheduleStatus = $status
        Update-TriggerProgress
        if ($status.error) { $script:ruleStatus.Text = '定时服务异常：' + $status.error; return }
        # The UI owns the rule file. Merge bindings into saved rule objects only;
        # never reload the editor or overwrite unsaved name/time changes.
        $bindingsChanged = $false
        foreach ($savedRule in $script:scheduleRules) {
            $liveRule = @($status.rules | Where-Object { $_.id -eq $savedRule.id }) | Select-Object -First 1
            if ($liveRule.binding -and -not $savedRule.existingThreadId) {
                $savedRule.existingThreadId = [string]$liveRule.binding.threadId
                $bindingsChanged = $true
            }
            $savedActivation = if ($savedRule.activationId) { $savedRule.activationId } else { 'legacy' }
            $liveActivation = if ($liveRule.activationId) { $liveRule.activationId } else { 'legacy' }
            if (($liveRule.autoDisabled -or $liveRule.blocked) -and $savedRule.enabled -and $savedActivation -eq $liveActivation) {
                $savedRule.enabled = $false
                $bindingsChanged = $true
                if ($savedRule.id -eq $script:editingRuleId) { $script:ruleEnabled.IsChecked = $false }
                foreach ($listItem in $script:ruleList.Items) { if ($listItem.Tag -eq $savedRule.id) { $listItem.Content = ([string]$listItem.Content).Replace('[已启用]', '[未启用]') } }
            }
        }
        if ($bindingsChanged) { Save-ScheduleConfig }
        $rule = @($status.rules | Where-Object { $_.id -eq $script:editingRuleId }) | Select-Object -First 1
        $info = New-Object 'System.Collections.Generic.List[string]'
        if (-not $rule) { $info.Add('新规则默认关闭。保存后可单独启用。') }
        else {
            if ($rule.binding) {
                $script:ruleThread.Text = [string]$rule.binding.threadId
                $script:ruleThread.IsReadOnly = $true
            } else {
                $info.Add('尚未绑定：首次执行时创建，或使用你填写的已有会话 ID。')
                $script:ruleThread.IsReadOnly = $false
            }
            if ($null -ne $rule.runLimit) { $info.Add("已触发 $($rule.triggerCount) / $($rule.runLimit) 次") }
            if ($rule.blocked) { $info.Add('异常已停用：' + $rule.blocked.message + '。修正后重新勾选启用并保存。') }
            elseif ($rule.autoDisabled) { $info.Add('已达到次数上限，规则自动关闭。重新启用并保存将从 0 次开始。') }
            elseif ($rule.enabled -and $rule.type -eq 'quotaReset') { $info.Add('等待接口确认额度刷新。首次读取不触发，同一额度周期最多执行一次。') }
            elseif ($rule.nextAt) { $info.Add('下次执行（北京时间）：' + [DateTimeOffset]::Parse($rule.nextAt).ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-dd HH:mm')) }
            else { $info.Add('当前未启用自动执行。') }
            if ($rule.lastRun) {
                $run = $rule.lastRun
                $info.Add('最近结果：' + $run.message)
                if ($run.after) {
                    foreach ($property in $run.after.PSObject.Properties) {
                        $quota = $property.Value
                        $reset = [DateTimeOffset]::FromUnixTimeSeconds([long]$quota.resetsAt).ToOffset([TimeSpan]::FromHours(8)).ToString('MM-dd HH:mm')
                        $info.Add("$($quota.label)：剩余 $($quota.remaining)%，重置时间 $reset")
                    }
                }
                if ($run.quotaError) { $info.Add($run.quotaError) }
            }
        }
        if (-not $rule) { $script:ruleThread.IsReadOnly = $false }
        if ($status.busy) { $info.Add('有规则正在执行，请等待完成。') }
        $script:ruleStatus.Text = $info -join "`n"
        $logs = @($status.logs | Where-Object { -not $_.ruleId -or $_.ruleId -eq $script:editingRuleId } | Select-Object -Last 10)
        $script:ruleLog.Text = (@($logs | ForEach-Object {
            $time = [DateTimeOffset]::Parse($_.at).ToOffset([TimeSpan]::FromHours(8)).ToString('MM-dd HH:mm:ss')
            "$time  $($_.message)"
        }) -join "`n")
    } catch {
        $script:ruleStatus.Text = '状态更新失败，正在重试：' + $_.Exception.Message
        if (Get-Command Write-UiError -ErrorAction SilentlyContinue) { Write-UiError $_ }
    }
}
function New-RuleTextBox {
    $box = New-Object System.Windows.Controls.TextBox
    $box.FontSize = 14; $box.Padding = '8'; $box.Margin = '0,0,0,10'
    return $box
}
function Show-ScheduleWindow {
    if ($script:scheduleWindow) { $script:scheduleWindow.Show(); $script:scheduleWindow.Activate() | Out-Null; return }
    $script:scheduleRules = New-Object 'System.Collections.Generic.List[object]'
    $file = Join-Path $dataDir 'schedule-rules.json'
    try {
        if ([IO.File]::Exists($file)) {
            $config = [IO.File]::ReadAllText($file) | ConvertFrom-Json
            foreach ($rule in $config.rules) { $script:scheduleRules.Add($rule) }
        }
    } catch { [System.Windows.MessageBox]::Show('规则文件无法读取，已保留原文件，请先排查。', '定时规则') | Out-Null; return }
    $window = New-Window '自动执行规则' 960 860
    $window.MinWidth = 820; $window.MinHeight = 620
    $script:scheduleWindow = $window
    $dock = New-Object System.Windows.Controls.DockPanel
    $dock.Margin = '24'
    $heading = New-Text '自动执行规则' 26 '#182848'
    [System.Windows.Controls.DockPanel]::SetDock($heading, 'Top'); $dock.Children.Add($heading) | Out-Null
    $intro = New-Text '支持每日定时与额度刷新。首次创建会话，后续固定编辑首条“你好”并重发。' 14 '#53627B'
    [System.Windows.Controls.DockPanel]::SetDock($intro, 'Top'); $dock.Children.Add($intro) | Out-Null
    $left = New-Object System.Windows.Controls.StackPanel
    $left.Width = 225; $left.Margin = '0,0,22,0'
    [System.Windows.Controls.DockPanel]::SetDock($left, 'Left')
    $script:ruleList = New-Object System.Windows.Controls.ListBox
    $script:ruleList.Height = 390; $script:ruleList.FontSize = 13
    $script:ruleList.Add_SelectionChanged({ if ($script:ruleList.SelectedItem) { Select-Rule $script:ruleList.SelectedItem.Tag } })
    $left.Children.Add($script:ruleList) | Out-Null
    $add = New-Button '+ 添加规则'
    $add.Add_Click({ $script:ruleList.SelectedIndex = -1; Select-Rule ([Guid]::NewGuid().ToString()) })
    $left.Children.Add($add) | Out-Null
    $remove = New-Button '删除所选规则'
    $remove.Add_Click({
        for ($i = $script:scheduleRules.Count - 1; $i -ge 0; $i--) { if ($script:scheduleRules[$i].id -eq $script:editingRuleId) { $script:scheduleRules.RemoveAt($i) } }
        Save-ScheduleConfig; Refresh-RuleList; Select-Rule ([Guid]::NewGuid().ToString())
        $script:scheduleFeedback.Text = '规则已删除，原会话保留。已开始的执行会完成。'
    })
    $left.Children.Add($remove) | Out-Null
    $left.Children.Add((New-Text '每条规则固定复用一个会话。每日定时按北京时间执行；额度刷新以接口实际状态为准。' 12 '#53627B')) | Out-Null
    $dock.Children.Add($left) | Out-Null
    $editorScroll = New-Object System.Windows.Controls.ScrollViewer
    $editorScroll.VerticalScrollBarVisibility = 'Auto'
    $editor = New-Object System.Windows.Controls.StackPanel
    $editor.Margin = '0,0,12,0'
    $editor.Children.Add((New-Text '规则名称' 14 '#182848')) | Out-Null
    $script:ruleName = New-RuleTextBox; $editor.Children.Add($script:ruleName) | Out-Null
    $editor.Children.Add((New-Text '规则类型' 14 '#182848')) | Out-Null
    $script:ruleType = New-Object System.Windows.Controls.ComboBox
    $script:ruleType.Items.Add('每日定时') | Out-Null
    $script:ruleType.Items.Add('额度刷新') | Out-Null
    $script:ruleType.FontSize = 14; $script:ruleType.Padding = '8'; $script:ruleType.Margin = '0,0,0,10'
    $script:ruleType.Add_SelectionChanged({ Update-RuleTypeFields })
    $editor.Children.Add($script:ruleType) | Out-Null
    $script:dailyFields = New-Object System.Windows.Controls.StackPanel
    $script:dailyFields.Children.Add((New-Text '每天执行时间（北京时间 HH:mm，多个时间用逗号分隔）' 14 '#182848')) | Out-Null
    $script:ruleTimes = New-RuleTextBox
    $script:ruleTimes.ToolTip = '例如 08:00, 13:00, 18:00。此示例不会自动保存或启用。'
    $script:dailyFields.Children.Add($script:ruleTimes) | Out-Null
    $editor.Children.Add($script:dailyFields) | Out-Null
    $script:quotaFields = New-Object System.Windows.Controls.StackPanel
    $script:quotaFields.Children.Add((New-Text '监控哪种额度刷新' 14 '#182848')) | Out-Null
    $script:quotaWindow = New-Object System.Windows.Controls.ComboBox
    foreach ($scopeLabel in @('五小时额度', '每周额度', '任一额度（五小时或每周）')) { $script:quotaWindow.Items.Add($scopeLabel) | Out-Null }
    $script:quotaWindow.FontSize = 14; $script:quotaWindow.Padding = '8'; $script:quotaWindow.Margin = '0,0,0,10'
    $script:quotaFields.Children.Add($script:quotaWindow) | Out-Null
    $script:quotaFields.Children.Add((New-Text '每分钟检测；确认周期重置或剩余额度增加且仍有可用额度后执行。每个额度周期最多一次。' 12 '#53627B')) | Out-Null
    $editor.Children.Add($script:quotaFields) | Out-Null
    $editor.Children.Add((New-Text '会话链接或 ID（首次留空，触发后自动回填并保存）' 14 '#182848')) | Out-Null
    $script:ruleThread = New-RuleTextBox; $editor.Children.Add($script:ruleThread) | Out-Null
    $editor.Children.Add((New-Text '编辑首条会移除当前路径后续历史；执行前会保存本地历史备份。请绑定专用计时会话。' 12 '#8A5A20')) | Out-Null
    $editor.Children.Add((New-Text '运行方式' 14 '#182848')) | Out-Null
    $script:runMode = New-Object System.Windows.Controls.ComboBox
    $script:runMode.Items.Add('始终开启') | Out-Null
    $script:runMode.Items.Add('触发 X 次后关闭') | Out-Null
    $script:runMode.FontSize = 14; $script:runMode.Padding = '8'; $script:runMode.Margin = '0,0,0,10'
    $script:runMode.Add_SelectionChanged({ Update-RunLimitFields })
    $editor.Children.Add($script:runMode) | Out-Null
    $script:runLimitBox = New-Object System.Windows.Controls.StackPanel
    $script:runLimitBox.Children.Add((New-Text '触发次数（以发起发送计数，忙碌跳过不计）' 13 '#53627B')) | Out-Null
    $script:runLimit = New-RuleTextBox
    $script:runLimit.Add_TextChanged({ Update-TriggerProgress })
    $script:runLimitBox.Children.Add($script:runLimit) | Out-Null
    $script:triggerProgress = New-Text '已触发 0 次' 15 '#182848'
    $script:triggerProgress.FontWeight = 'SemiBold'
    $script:triggerProgress.Margin = '0,0,0,10'
    $script:runLimitBox.Children.Add($script:triggerProgress) | Out-Null
    $editor.Children.Add($script:runLimitBox) | Out-Null
    $script:ruleEnabled = New-Object System.Windows.Controls.CheckBox
    $script:ruleEnabled.Content = '启用这条规则'; $script:ruleEnabled.FontSize = 15; $script:ruleEnabled.Margin = '0,0,0,10'
    $editor.Children.Add($script:ruleEnabled) | Out-Null
    $actions = New-Object System.Windows.Controls.WrapPanel
    $save = New-Button '保存规则'
    $save.Add_Click({
        try {
            $name = $script:ruleName.Text.Trim()
            if (-not $name -or $name.Length -gt 80) { throw '请填写 1–80 字的规则名称。' }
            $ruleType = if ($script:ruleType.SelectedIndex -eq 1) { 'quotaReset' } else { 'daily' }
            $quotaWindow = switch ($script:quotaWindow.SelectedIndex) { 0 { 'fiveHour' }; 1 { 'weekly' }; default { 'any' } }
            $times = @()
            if ($ruleType -eq 'daily') {
                $times = @($script:ruleTimes.Text -split '[,，;；\s]+' | Where-Object { $_ } | Sort-Object -Unique)
                if ($times.Count -lt 1 -or $times.Count -gt 24 -or @($times | Where-Object { $_ -notmatch '^(?:[01]\d|2[0-3]):[0-5]\d$' }).Count -gt 0) { throw '请填写有效时间，例如 08:00, 13:00；每条规则最多 24 个时间。' }
            }
            $threadId = $script:ruleThread.Text.Trim()
            if ($threadId -match '^codex://threads/([a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12})/?$') { $threadId = $Matches[1] }
            if ($threadId -and $threadId -notmatch '^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$') { throw '请输入完整会话 ID 或 codex://threads/ 会话链接。' }
            $threadId = $threadId.ToLowerInvariant()
            $id = $script:editingRuleId
            $limitValue = $null
            if ($script:runMode.SelectedIndex -eq 1) {
                $parsedLimit = 0
                if (-not [int]::TryParse($script:runLimit.Text.Trim(), [ref]$parsedLimit) -or $parsedLimit -lt 1 -or $parsedLimit -gt 100000) { throw '触发次数请输入 1–100000 的整数。' }
                $limitValue = $parsedLimit
            }
            $oldRule = @($script:scheduleRules | Where-Object { $_.id -eq $id }) | Select-Object -First 1
            $reenabling = $script:ruleEnabled.IsChecked -and $oldRule -and -not $oldRule.enabled
            $activationId = if ($oldRule.activationId) { $oldRule.activationId } else { 'legacy' }
            if (-not $oldRule -or $reenabling -or $oldRule.runLimit -ne $limitValue) { $activationId = [Guid]::NewGuid().ToString() }
            $replacement = [PSCustomObject]@{id = $id; name = $name; enabled = [bool]$script:ruleEnabled.IsChecked; type = $ruleType; quotaWindow = $quotaWindow; runLimit = $limitValue; activationId = $activationId; times = $times; existingThreadId = $threadId}
            $found = $false
            for ($i = 0; $i -lt $script:scheduleRules.Count; $i++) {
                if ($script:scheduleRules[$i].id -eq $id) { $script:scheduleRules[$i] = $replacement; $found = $true; break }
            }
            if (-not $found) { $script:scheduleRules.Add($replacement) }
            Save-ScheduleConfig; Refresh-RuleList
            if ($reenabling) { Send-ScheduleCommand 'unblock' }
            foreach ($item in $script:ruleList.Items) { if ($item.Tag -eq $id) { $script:ruleList.SelectedItem = $item; break } }
            $script:scheduleFeedback.Text = '已保存。启用后，从下一次符合触发条件时开始执行。'
        } catch { $script:scheduleFeedback.Text = $_.Exception.Message }
    })
    $actions.Children.Add($save) | Out-Null
    $editor.Children.Add($actions) | Out-Null
    $script:scheduleFeedback = New-Text '' 13 '#356649'
    $script:scheduleFeedback.Margin = '0,12,0,10'; $editor.Children.Add($script:scheduleFeedback) | Out-Null
    $script:ruleStatus = New-Text '' 13 '#182848'; $editor.Children.Add($script:ruleStatus) | Out-Null
    $editor.Children.Add((New-Text '最近执行记录' 16 '#182848')) | Out-Null
    $script:ruleLog = New-Text '' 12 '#53627B'; $editor.Children.Add($script:ruleLog) | Out-Null
    $editorScroll.Content = $editor; $dock.Children.Add($editorScroll) | Out-Null
    $window.Content = $dock
    $script:scheduleTimer = New-Object Windows.Threading.DispatcherTimer
    $script:scheduleTimer.Interval = [TimeSpan]::FromSeconds(2)
    $script:scheduleTimer.Add_Tick({ Update-ScheduleStatus })
    $script:scheduleTimer.Start()
    $window.Add_Closed({ $script:scheduleTimer.Stop(); $script:scheduleWindow = $null })
    Refresh-RuleList
    if ($script:ruleList.Items.Count -gt 0) { $script:ruleList.SelectedIndex = 0 } else { Select-Rule ([Guid]::NewGuid().ToString()) }
    $window.Show()
    $window.Activate() | Out-Null
}
