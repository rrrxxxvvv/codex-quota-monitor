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
        $stateLabel = if (-not $rule.messageAction -or $rule.needsActionReview) { '待选择发送方式' } elseif ($rule.enabled) { '已启用' } else { '未启用' }
        $condition = if ($rule.type -eq 'quotaReset') {
            $scope = switch ($rule.quotaWindow) { 'fiveHour' { '五小时' }; 'weekly' { '每周' }; default { '任一额度' } }
            "额度刷新 · $scope"
        } elseif ($rule.type -eq 'dates') { '指定日期 · ' + (@($rule.dates).Count) + ' 个时刻' }
        elseif ($rule.type -eq 'interval') { "间隔重复 · 每 $($rule.intervalMinutes) 分钟" }
        else { '每日定时 · ' + ($rule.times -join '、') }
        $item.Content = "$($rule.name)  [$stateLabel]`n$condition"
        $item.Tag = $rule.id; $item.Padding = '8'; $item.Margin = '0,0,0,5'
        $script:ruleList.Items.Add($item) | Out-Null
    }
}
function Update-RuleTypeFields {
    if (-not $script:dailyFields -or -not $script:quotaFields) { return }
    $script:dailyFields.Visibility = if ($script:ruleType.SelectedIndex -eq 0) { 'Visible' } else { 'Collapsed' }
    $script:quotaFields.Visibility = if ($script:ruleType.SelectedIndex -eq 1) { 'Visible' } else { 'Collapsed' }
    if ($script:datesFields) { $script:datesFields.Visibility = if ($script:ruleType.SelectedIndex -eq 2) { 'Visible' } else { 'Collapsed' } }
    if ($script:intervalFields) { $script:intervalFields.Visibility = if ($script:ruleType.SelectedIndex -eq 3) { 'Visible' } else { 'Collapsed' } }
}
function Update-RunLimitFields {
    if ($script:runLimitBox) { $script:runLimitBox.Visibility = if ($script:runMode.SelectedIndex -eq 1) { 'Visible' } else { 'Collapsed' } }
    Update-TriggerProgress
}
function Update-MessageActionFields {
    if (-not $script:replaceLastConsent) { return }
    $script:replaceLastConsent.Visibility = if ($script:messageAction.SelectedIndex -eq 1) { 'Visible' } else { 'Collapsed' }
    $script:messageActionHelp.Text = if ($script:messageAction.SelectedIndex -eq 1) { '替换最后一轮用户消息及对应回复，保留此前各轮历史，执行前备份。若最后一轮含多条用户消息，则停止并提示手动处理。' } else { '在原会话末尾发送上面的内容，保留全部已有对话。适合发送“继续”或安排新的工作。' }
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
    $script:triggerProgress.Text = switch ($script:runMode.SelectedIndex) { 1 { "已触发 $count / $limitText 次" }; 2 { "已触发 $count / 1 次" }; default { "已触发 $count 次" } }
}
function Select-Rule($id) {
    $script:editingRuleId = $id
    $rule = @($script:scheduleRules | Where-Object { $_.id -eq $id }) | Select-Object -First 1
    $script:ruleDates.Items.Clear()
    Set-RuleDateTime $script:datePicker ([DateTime]::UtcNow.AddHours(8).AddMinutes(5).ToString('yyyy-MM-ddTHH:mm'))
    Set-RuleDateTime $script:intervalPicker ([DateTime]::UtcNow.AddHours(8).AddMinutes(5).ToString('yyyy-MM-ddTHH:mm'))
    $script:intervalValue.Text = '5'; $script:intervalUnit.SelectedIndex = 1
    if ($rule) {
        $script:ruleName.Text = $rule.name
        $script:ruleTimes.Text = $rule.times -join ', '
        $script:ruleThread.Text = $rule.existingThreadId
        $script:ruleEnabled.IsChecked = $rule.enabled
        $script:ruleType.SelectedIndex = switch ($rule.type) { 'quotaReset' { 1 }; 'dates' { 2 }; 'interval' { 3 }; default { 0 } }
        $script:ruleMessage.Text = if ($null -ne $rule.message) { $rule.message } else { '你好' }
        $script:messageAction.SelectedIndex = switch ($rule.messageAction) { 'append' { 0 }; 'replaceLast' { 1 }; default { -1 } }
        $script:replaceLastConsent.IsChecked = $rule.replaceLastConfirmed -eq $true
        $script:releaseDesktopConsent.IsChecked = $rule.releaseDesktopOnConflict -eq $true
        $script:deliveryMode.SelectedIndex = switch ($rule.deliveryMode) { 'ui' { 0 }; 'apiUi' { 2 }; 'apiUiRestart' { 3 }; default { 1 } }
        if (-not $rule.messageAction -or $rule.needsActionReview) { $script:ruleEnabled.IsChecked = $false }
        foreach ($date in $rule.dates) { $script:ruleDates.Items.Add($date.Replace('T', ' ')) | Out-Null }
        if ($rule.type -eq 'interval') {
            Set-RuleDateTime $script:intervalPicker $rule.startAt
            $script:intervalValue.Text = [string]$rule.intervalMinutes; $script:intervalUnit.SelectedIndex = 0
        }
        $script:quotaWindow.SelectedIndex = switch ($rule.quotaWindow) { 'fiveHour' { 0 }; 'weekly' { 1 }; default { 2 } }
        $script:runMode.SelectedIndex = if ($rule.runLimit -eq 1) { 2 } elseif ($null -ne $rule.runLimit) { 1 } else { 0 }
        $script:runLimit.Text = if ($null -ne $rule.runLimit) { [string]$rule.runLimit } else { '1' }
    } else {
        $script:ruleName.Text = ''
        $script:ruleTimes.Text = ''
        $script:ruleMessage.Text = '你好'
        $script:messageAction.SelectedIndex = 0
        $script:replaceLastConsent.IsChecked = $false
        $script:releaseDesktopConsent.IsChecked = $false
        $script:deliveryMode.SelectedIndex = 0
        $script:ruleThread.Text = ''
        $script:ruleEnabled.IsChecked = $false
        $script:ruleType.SelectedIndex = 0
        $script:quotaWindow.SelectedIndex = 2
        $script:runMode.SelectedIndex = 0
        $script:runLimit.Text = '1'
    }
    Update-RuleTypeFields
    Update-MessageActionFields
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
        if ($script:scheduleLogLocation) { $script:scheduleLogLocation.Visibility = 'Collapsed' }
        Update-TriggerProgress
        if ($status.error) { $script:ruleStatus.Text = '定时服务异常：' + $status.error; $script:scheduleLogLocation.Visibility = 'Visible'; return }
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
            if (($liveRule.autoDisabled -or $liveRule.blocked -or $liveRule.needsActionReview) -and $savedRule.enabled -and $savedActivation -eq $liveActivation) {
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
            if ($rule.lastRun.deliveryRoute) { $info.Add('本次发送通道：' + (@{api='接口';ui='界面操作';'restart-api'='退出客户端后接口发送';'api-initial'='首次创建任务，接口初始化'}[$rule.lastRun.deliveryRoute])) }
            if ($rule.lastRun.uiLog) { $info.Add('界面日志：' + $rule.lastRun.uiLog) }
            if ($rule.lastRun.uiStatusLog) { $info.Add('界面状态日志：' + $rule.lastRun.uiStatusLog) }
            if ($rule.lastRun.desktopReleaseLog) { $info.Add('客户端恢复日志：' + $rule.lastRun.desktopReleaseLog) }
            if ($rule.lastRun.desktopRestoreError) { $info.Add('客户端恢复失败：' + $rule.lastRun.desktopRestoreError) }
            if ($rule.blocked -or $rule.lastRun.status -in @('failed', 'uncertain') -or $rule.lastRun.reason -in @('active-writer','ui-not-sent')) { $script:scheduleLogLocation.Visibility = 'Visible' }
            if ($rule.binding) {
                $script:ruleThread.Text = [string]$rule.binding.threadId
                $script:ruleThread.IsReadOnly = $true
            } else {
                $info.Add('尚未绑定：首次执行时创建，或使用你填写的已有会话 ID。')
                $script:ruleThread.IsReadOnly = $false
            }
            if ($null -ne $rule.runLimit) { $info.Add("已触发 $($rule.triggerCount) / $($rule.runLimit) 次") }
            if ($rule.needsActionReview) { $info.Add('旧规则已暂停：请选择发送方式后保存并启用。默认追加保留全部历史；编辑末条仅替换最后一轮。') }
            elseif ($rule.blocked) { $info.Add('异常已停用：' + $rule.blocked.message + '。修正后重新勾选启用并保存。') }
            elseif ($rule.autoDisabled) { $info.Add('已达到次数上限，规则自动关闭。重新启用并保存将从 0 次开始。') }
            elseif ($rule.enabled -and $rule.type -eq 'quotaReset') { $info.Add('等待接口确认额度刷新。首次读取不触发，同一额度周期最多执行一次。') }
            elseif ($rule.nextAt) { $info.Add('下次执行（北京时间）：' + [DateTimeOffset]::Parse($rule.nextAt).ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-dd HH:mm')) }
            elseif ($rule.enabled -and $rule.type -eq 'dates') { $info.Add('所有指定时刻均已过去，没有下次执行；过去时刻不会补发。') }
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
        if ($script:scheduleLogLocation) { $script:scheduleLogLocation.Visibility = 'Visible' }
        $script:ruleStatus.Text = '状态更新失败，正在重试：' + $_.Exception.Message
        if (Get-Command Write-UiError -ErrorAction SilentlyContinue) { Write-UiError $_ }
    }
}
function New-RuleTextBox {
    $box = New-Object System.Windows.Controls.TextBox
    $box.FontSize = 14; $box.Padding = '8'; $box.Margin = '0,0,0,10'
    return $box
}
function New-RuleTimePicker {
    $panel = New-Object System.Windows.Controls.WrapPanel
    $hour = New-Object System.Windows.Controls.ComboBox
    $minute = New-Object System.Windows.Controls.ComboBox
    foreach ($n in 0..23) { $hour.Items.Add($n.ToString('00')) | Out-Null }
    foreach ($n in 0..59) { $minute.Items.Add($n.ToString('00')) | Out-Null }
    foreach ($control in @($hour, $minute)) { $control.FontSize = 14; $control.Width = 65; $control.Padding = '5'; $control.Margin = '0,0,6,8'; $control.SelectedIndex = 0 }
    $panel.Children.Add($hour) | Out-Null
    $panel.Children.Add((New-Text ':' 14 '#182848')) | Out-Null
    $panel.Children.Add($minute) | Out-Null
    return [PSCustomObject]@{Panel = $panel; Hour = $hour; Minute = $minute}
}
function New-RuleDateTimePicker {
    $time = New-RuleTimePicker
    $date = New-Object System.Windows.Controls.DatePicker
    $date.Width = 150; $date.FontSize = 14; $date.Margin = '0,0,10,8'; $date.SelectedDateFormat = 'Short'
    $time.Panel.Children.Insert(0, $date)
    return [PSCustomObject]@{Panel = $time.Panel; Date = $date; Hour = $time.Hour; Minute = $time.Minute}
}
function Set-RuleDateTime($picker, [string]$value) {
    $date = [DateTime]::ParseExact($value, "yyyy-MM-dd'T'HH:mm", [Globalization.CultureInfo]::InvariantCulture)
    $picker.Date.SelectedDate = $date.Date; $picker.Hour.SelectedIndex = $date.Hour; $picker.Minute.SelectedIndex = $date.Minute
}
function Get-RuleDateTime($picker) {
    if (-not $picker.Date.SelectedDate -or $picker.Hour.SelectedIndex -lt 0 -or $picker.Minute.SelectedIndex -lt 0) { throw '请选择有效日期和时间。' }
    return $picker.Date.SelectedDate.ToString('yyyy-MM-dd') + 'T' + $picker.Hour.SelectedItem + ':' + $picker.Minute.SelectedItem
}
function New-RuleSection($parent, $title) {
    $border = New-Object System.Windows.Controls.Border
    $border.Background = 'White'; $border.BorderBrush = '#E2E8F0'; $border.BorderThickness = '1'
    $border.CornerRadius = '10'; $border.Padding = '18'; $border.Margin = '0,0,0,14'
    $panel = New-Object System.Windows.Controls.StackPanel
    $heading = New-Text $title 16 '#182848'; $heading.FontWeight = 'SemiBold'
    $panel.Children.Add($heading) | Out-Null
    $border.Child = $panel; $parent.Children.Add($border) | Out-Null
    return $panel
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
    } catch { Write-UiError $_; [System.Windows.MessageBox]::Show(("规则文件无法读取，已保留原文件。`n错误日志：" + [IO.Path]::GetFullPath((Join-Path $dataDir 'ui-errors.log')) + "`n规则文件：" + [IO.Path]::GetFullPath($file)), '定时规则') | Out-Null; return }
    $window = New-Window '自动执行规则' 1040 860
    $window.MinWidth = 820; $window.MinHeight = 620
    $window.Resources = [Windows.Markup.XamlReader]::Parse(@'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Style TargetType="Button">
    <Setter Property="Background" Value="White"/><Setter Property="Foreground" Value="#334155"/>
    <Setter Property="BorderBrush" Value="#CBD5E1"/><Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
      <Border x:Name="surface" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="surface" Property="Opacity" Value="0.8"/></Trigger>
        <Trigger Property="IsPressed" Value="True"><Setter TargetName="surface" Property="Opacity" Value="0.6"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter TargetName="surface" Property="Opacity" Value="0.45"/></Trigger>
        <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="surface" Property="BorderBrush" Value="#2563EB"/><Setter TargetName="surface" Property="BorderThickness" Value="2"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="TextBox">
    <Setter Property="BorderBrush" Value="#CBD5E1"/><Setter Property="BorderThickness" Value="1"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
    <Style.Triggers><Trigger Property="IsKeyboardFocused" Value="True"><Setter Property="BorderBrush" Value="#2563EB"/></Trigger></Style.Triggers>
  </Style>
  <Style TargetType="ListBoxItem">
    <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListBoxItem">
      <Border x:Name="surface" Background="Transparent" CornerRadius="6" Padding="{TemplateBinding Padding}"><ContentPresenter/></Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="surface" Property="Background" Value="#F1F5F9"/></Trigger>
        <Trigger Property="IsSelected" Value="True"><Setter TargetName="surface" Property="Background" Value="#E8F0FF"/><Setter Property="Foreground" Value="#1D4ED8"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
</ResourceDictionary>
'@)
    $script:scheduleWindow = $window
    $dock = New-Object System.Windows.Controls.DockPanel
    $dock.Margin = '24'
    $heading = New-Text '自动执行规则' 26 '#182848'
    [System.Windows.Controls.DockPanel]::SetDock($heading, 'Top'); $dock.Children.Add($heading) | Out-Null
    $intro = New-Text '设置何时触发、发送什么，以及执行次数。所有时间均为北京时间。' 13 '#64748B'
    [System.Windows.Controls.DockPanel]::SetDock($intro, 'Top'); $dock.Children.Add($intro) | Out-Null
    $left = New-Object System.Windows.Controls.DockPanel
    $left.Width = 210; $left.Margin = '0,0,20,0'
    [System.Windows.Controls.DockPanel]::SetDock($left, 'Left')
    $script:ruleList = New-Object System.Windows.Controls.ListBox
    $script:ruleList.FontSize = 13; $script:ruleList.Padding = '6'; $script:ruleList.BorderThickness = '0'; $script:ruleList.Background = 'Transparent'
    [System.Windows.Controls.ScrollViewer]::SetHorizontalScrollBarVisibility($script:ruleList, 'Disabled')
    $script:ruleList.Add_SelectionChanged({ if ($script:ruleList.SelectedItem) { Select-Rule $script:ruleList.SelectedItem.Tag } })
    $leftActions = New-Object System.Windows.Controls.StackPanel
    [System.Windows.Controls.DockPanel]::SetDock($leftActions, 'Top'); $left.Children.Add($leftActions) | Out-Null
    $leftActions.Children.Add((New-Text '我的规则' 15 '#334155')) | Out-Null
    $add = New-Button '+ 添加规则'
    $add.Add_Click({ $script:ruleList.SelectedIndex = -1; Select-Rule ([Guid]::NewGuid().ToString()) })
    $add.Margin = '0,0,0,8'; $add.Background = '#EFF6FF'; $add.Foreground = '#1D4ED8'; $add.BorderBrush = '#BFDBFE'
    $leftActions.Children.Add($add) | Out-Null
    $remove = New-Button '删除所选规则'
    $remove.Add_Click({
        for ($i = $script:scheduleRules.Count - 1; $i -ge 0; $i--) { if ($script:scheduleRules[$i].id -eq $script:editingRuleId) { $script:scheduleRules.RemoveAt($i) } }
        Save-ScheduleConfig; Refresh-RuleList; Select-Rule ([Guid]::NewGuid().ToString())
        $script:scheduleFeedback.Text = '规则已删除，原会话保留。已开始的执行会完成。'
    })
    $leftBottom = New-Object System.Windows.Controls.StackPanel
    [System.Windows.Controls.DockPanel]::SetDock($leftBottom, 'Bottom'); $left.Children.Add($leftBottom) | Out-Null
    $remove.Foreground = '#9F4545'; $remove.Margin = '0,12,0,12'; $leftBottom.Children.Add($remove) | Out-Null
    $leftBottom.Children.Add((New-Text '请保持电脑和监控运行。错过的时刻不补发，忙碌跳过不占次数。' 12 '#64748B')) | Out-Null
    $left.Children.Add($script:ruleList) | Out-Null
    $dock.Children.Add($left) | Out-Null
    $editorHost = New-Object System.Windows.Controls.DockPanel
    $footer = New-Object System.Windows.Controls.Border
    $footer.Background = 'White'; $footer.BorderBrush = '#E2E8F0'; $footer.BorderThickness = '1'; $footer.CornerRadius = '10'; $footer.Padding = '16,12'; $footer.Margin = '0,10,0,0'
    [System.Windows.Controls.DockPanel]::SetDock($footer, 'Bottom'); $editorHost.Children.Add($footer) | Out-Null
    $footerContent = New-Object System.Windows.Controls.StackPanel; $footer.Child = $footerContent
    $footerRow = New-Object System.Windows.Controls.DockPanel; $footerContent.Children.Add($footerRow) | Out-Null
    $editorScroll = New-Object System.Windows.Controls.ScrollViewer
    $editorScroll.VerticalScrollBarVisibility = 'Auto'
    $editorRoot = New-Object System.Windows.Controls.StackPanel
    $editorRoot.Margin = '0,0,10,0'
    $editor = New-RuleSection $editorRoot '触发条件'
    $editor.Children.Add((New-Text '规则名称' 14 '#182848')) | Out-Null
    $script:ruleName = New-RuleTextBox; $editor.Children.Add($script:ruleName) | Out-Null
    $editor.Children.Add((New-Text '触发器' 14 '#182848')) | Out-Null
    $script:ruleType = New-Object System.Windows.Controls.ComboBox
    $script:ruleType.Items.Add('每日定时') | Out-Null
    $script:ruleType.Items.Add('额度刷新') | Out-Null
    $script:ruleType.Items.Add('指定日期时间（可添加多个）') | Out-Null
    $script:ruleType.Items.Add('从指定日期开始按间隔重复') | Out-Null
    $signalOption = New-Object System.Windows.Controls.ComboBoxItem
    $signalOption.Content = '程序运行完毕信号（暂未开放）'; $signalOption.IsEnabled = $false
    $script:ruleType.Items.Add($signalOption) | Out-Null
    $script:ruleType.FontSize = 14; $script:ruleType.Padding = '8'; $script:ruleType.Margin = '0,0,0,10'
    $script:ruleType.Add_SelectionChanged({ Update-RuleTypeFields })
    $editor.Children.Add($script:ruleType) | Out-Null
    $script:dailyFields = New-Object System.Windows.Controls.StackPanel
    $script:dailyFields.Children.Add((New-Text '每天执行时间（北京时间 HH:mm，多个时间用逗号分隔）' 14 '#182848')) | Out-Null
    $script:ruleTimes = New-RuleTextBox
    $script:ruleTimes.ToolTip = '例如 08:00, 13:00, 18:00。此示例不会自动保存或启用。'
    $script:dailyFields.Children.Add($script:ruleTimes) | Out-Null
    $script:dailyPicker = New-RuleTimePicker
    $addTime = New-Button '添加时间'
    $addTime.Add_Click({
        $value = $script:dailyPicker.Hour.SelectedItem + ':' + $script:dailyPicker.Minute.SelectedItem
        $script:ruleTimes.Text = (@(@($script:ruleTimes.Text -split '[,，;；\s]+' | Where-Object { $_ }) + $value) | Sort-Object -Unique) -join ', '
    })
    $script:dailyPicker.Panel.Children.Add($addTime) | Out-Null
    $script:dailyFields.Children.Add($script:dailyPicker.Panel) | Out-Null
    $editor.Children.Add($script:dailyFields) | Out-Null
    $script:quotaFields = New-Object System.Windows.Controls.StackPanel
    $script:quotaFields.Children.Add((New-Text '监控哪种额度刷新' 14 '#182848')) | Out-Null
    $script:quotaWindow = New-Object System.Windows.Controls.ComboBox
    foreach ($scopeLabel in @('五小时额度', '每周额度', '任一额度（五小时或每周）')) { $script:quotaWindow.Items.Add($scopeLabel) | Out-Null }
    $script:quotaWindow.FontSize = 14; $script:quotaWindow.Padding = '8'; $script:quotaWindow.Margin = '0,0,0,10'
    $script:quotaFields.Children.Add($script:quotaWindow) | Out-Null
    $script:quotaFields.Children.Add((New-Text '每分钟检测；确认周期重置或剩余额度增加且仍有可用额度后执行。每个额度周期最多一次。' 12 '#53627B')) | Out-Null
    $editor.Children.Add($script:quotaFields) | Out-Null
    $script:datesFields = New-Object System.Windows.Controls.StackPanel
    $script:datesFields.Children.Add((New-Text '选择执行日期和时间（北京时间）' 14 '#182848')) | Out-Null
    $script:datePicker = New-RuleDateTimePicker
    $script:datesFields.Children.Add($script:datePicker.Panel) | Out-Null
    $dateActions = New-Object System.Windows.Controls.WrapPanel
    $addDate = New-Button '添加日期时间'
    $addDate.Add_Click({
        try {
            $value = (Get-RuleDateTime $script:datePicker).Replace('T', ' ')
            if (-not $script:ruleDates.Items.Contains($value)) { $script:ruleDates.Items.Add($value) | Out-Null }
            $script:scheduleFeedback.Text = ''
        } catch { Write-UiError $_; $script:scheduleFeedback.Text = $_.Exception.Message + "`n日志：" + [IO.Path]::GetFullPath((Join-Path $dataDir 'ui-errors.log')) }
    })
    $removeDate = New-Button '移除所选时间'
    $removeDate.Add_Click({ if ($null -ne $script:ruleDates.SelectedItem) { $script:ruleDates.Items.Remove($script:ruleDates.SelectedItem) } })
    $dateActions.Children.Add($addDate) | Out-Null; $dateActions.Children.Add($removeDate) | Out-Null
    $script:datesFields.Children.Add($dateActions) | Out-Null
    $script:ruleDates = New-Object System.Windows.Controls.ListBox
    $script:ruleDates.Height = 105; $script:ruleDates.FontSize = 14; $script:ruleDates.Margin = '0,0,0,10'
    $script:datesFields.Children.Add($script:ruleDates) | Out-Null
    $editor.Children.Add($script:datesFields) | Out-Null
    $script:intervalFields = New-Object System.Windows.Controls.StackPanel
    $script:intervalFields.Children.Add((New-Text '首次执行日期和时间（北京时间）' 14 '#182848')) | Out-Null
    $script:intervalPicker = New-RuleDateTimePicker
    $script:intervalFields.Children.Add($script:intervalPicker.Panel) | Out-Null
    $script:intervalFields.Children.Add((New-Text '此后每隔（按开始时间计算，不随任务耗时推迟）' 13 '#53627B')) | Out-Null
    $intervalRow = New-Object System.Windows.Controls.WrapPanel
    $script:intervalValue = New-RuleTextBox; $script:intervalValue.Width = 100
    $script:intervalUnit = New-Object System.Windows.Controls.ComboBox
    foreach ($unit in @('分钟', '小时', '天')) { $script:intervalUnit.Items.Add($unit) | Out-Null }
    $script:intervalUnit.FontSize = 14; $script:intervalUnit.Padding = '8'; $script:intervalUnit.Margin = '10,0,0,10'
    $intervalRow.Children.Add($script:intervalValue) | Out-Null; $intervalRow.Children.Add($script:intervalUnit) | Out-Null
    $script:intervalFields.Children.Add($intervalRow) | Out-Null
    $editor.Children.Add($script:intervalFields) | Out-Null
    $editor = New-RuleSection $editorRoot '消息与会话'
    $editor.Children.Add((New-Text '发送方式（与触发器、消息内容独立设置）' 14 '#182848')) | Out-Null
    $script:messageAction = New-Object System.Windows.Controls.ComboBox
    $script:messageAction.Items.Add('追加消息 · 保留历史（默认）') | Out-Null
    $script:messageAction.Items.Add('编辑末条用户消息并重发 · 保留此前历史') | Out-Null
    $script:messageAction.FontSize = 14; $script:messageAction.Padding = '8'; $script:messageAction.Margin = '0,0,0,10'
    $script:messageAction.Add_SelectionChanged({ Update-MessageActionFields })
    $editor.Children.Add($script:messageAction) | Out-Null
    $script:messageActionHelp = New-Text '' 12 '#8A5A20'; $editor.Children.Add($script:messageActionHelp) | Out-Null
    $script:replaceLastConsent = New-Object System.Windows.Controls.CheckBox
    $script:replaceLastConsent.Content = '允许此规则替换最后一轮用户消息及对应回复'
    $script:replaceLastConsent.Margin = '0,0,0,12'; $editor.Children.Add($script:replaceLastConsent) | Out-Null
    $editor.Children.Add((New-Text '消息内容 · 支持多行，最多 20000 字' 13 '#64748B')) | Out-Null
    $script:ruleMessage = New-RuleTextBox
    $script:ruleMessage.AcceptsReturn = $true; $script:ruleMessage.TextWrapping = 'Wrap'; $script:ruleMessage.Height = 130; $script:ruleMessage.VerticalContentAlignment = 'Top'
    $script:ruleMessage.VerticalScrollBarVisibility = 'Auto'
    $editor.Children.Add($script:ruleMessage) | Out-Null
    $editor.Children.Add((New-Text '新建会话沿用只读权限；自定义消息不会自动授予文件修改或命令审批权限。' 12 '#53627B')) | Out-Null
    $editor.Children.Add((New-Text '会话链接或 ID（首次留空，触发后自动回填并保存）' 14 '#182848')) | Out-Null
    $script:ruleThread = New-RuleTextBox; $editor.Children.Add($script:ruleThread) | Out-Null
    $editor.Children.Add((New-Text '专用任务可减少占用冲突。桌面端打开任务后，仅切换页面不一定释放占用；可在下方配置界面发送及退出客户端的回退方式。' 12 '#53627B')) | Out-Null
    $editor.Children.Add((New-Text '发送通道（依次尝试，结果不确定时停止）' 14 '#182848')) | Out-Null
    $script:deliveryMode = New-Object System.Windows.Controls.ComboBox
    foreach ($label in @('界面发送（默认）', '仅接口', '接口 → 界面操作', '接口 → 界面操作 → 退出客户端后接口发送并重开')) { $script:deliveryMode.Items.Add($label) | Out-Null }
    $script:deliveryMode.FontSize = 14; $script:deliveryMode.Padding = '8'; $script:deliveryMode.Margin = '0,0,0,10'
    $editor.Children.Add($script:deliveryMode) | Out-Null
    $editor.Children.Add((New-Text '界面发送直接操作目标任务，不先尝试接口或自动关闭客户端。任务 ID 留空时，首次创建由接口初始化，后续触发使用界面；已有规则保留原通道。' 12 '#53627B')) | Out-Null
    $editor.Children.Add((New-Text '界面通道需要桌面解锁，并短暂使用键鼠。等待任务菜单加载，找不到时尝试 Ctrl+Alt+L 复制链接，必须核对 ID 才发送；已有草稿不覆盖，用户输入或切换窗口会停止回退。诊断日志位于 data/ui-automation，含客户端版本、控件数量及识别方式。' 12 '#53627B')) | Out-Null
    $script:releaseDesktopConsent = New-Object System.Windows.Controls.CheckBox
    $script:releaseDesktopConsent.Content = '允许最后一级关闭整个 Codex（可能中断其他任务），完成后重开'
    $script:releaseDesktopConsent.Margin = '0,8,0,8'
    $editor.Children.Add($script:releaseDesktopConsent) | Out-Null
    $editor.Children.Add((New-Text '默认关闭。开启即允许终止整个客户端及其后台，可能中断其他任务（包括当前对话）。仅目标任务已空闲但仍被占用时执行；消息任务结束、失败或监控退出后尝试恢复客户端。无法只释放一个对话。' 12 '#9F4545')) | Out-Null
    $editor = New-RuleSection $editorRoot '运行方式'
    $script:runMode = New-Object System.Windows.Controls.ComboBox
    $script:runMode.Items.Add('始终开启') | Out-Null
    $script:runMode.Items.Add('触发 X 次后关闭') | Out-Null
    $script:runMode.Items.Add('仅执行一次') | Out-Null
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
    $editor.Children.Add($script:runLimitBox) | Out-Null
    $editor.Children.Add($script:triggerProgress) | Out-Null
    $script:ruleEnabled = New-Object System.Windows.Controls.CheckBox
    $script:ruleEnabled.Content = '启用这条规则'; $script:ruleEnabled.FontSize = 14; $script:ruleEnabled.VerticalAlignment = 'Center'
    $save = New-Button '保存规则'
    $save.Background = '#2563EB'; $save.Foreground = 'White'; $save.BorderBrush = '#2563EB'; $save.Margin = '12,0,0,0'; $save.MinWidth = 120
    [System.Windows.Controls.DockPanel]::SetDock($save, 'Right'); $footerRow.Children.Add($save) | Out-Null
    $footerRow.Children.Add($script:ruleEnabled) | Out-Null
    $save.Add_Click({
        try {
            $name = $script:ruleName.Text.Trim()
            if (-not $name -or $name.Length -gt 80) { throw '请填写 1–80 字的规则名称。' }
            $ruleType = switch ($script:ruleType.SelectedIndex) { 0 { 'daily' }; 1 { 'quotaReset' }; 2 { 'dates' }; 3 { 'interval' }; default { throw '该触发器暂未开放。' } }
            $message = $script:ruleMessage.Text
            if (-not $message.Trim() -or $message.Length -gt 20000) { throw '消息内容需要 1–20000 字，不能全为空白。' }
            $action = switch ($script:messageAction.SelectedIndex) { 0 { 'append' }; 1 { 'replaceLast' }; default { throw '请选择发送方式：追加消息，或编辑末条用户消息并重发。' } }
            $replaceLastConfirmed = $action -eq 'replaceLast' -and $script:replaceLastConsent.IsChecked -eq $true
            if ($action -eq 'replaceLast' -and -not $replaceLastConfirmed) { throw '编辑末条会替换最后一轮。请勾选允许替换，或改用追加消息。' }
            $delivery = switch ($script:deliveryMode.SelectedIndex) { 0 { 'ui' }; 1 { 'api' }; 2 { 'apiUi' }; 3 { 'apiUiRestart' }; default { throw '请选择发送通道。' } }
            if ($delivery -eq 'apiUiRestart' -and $script:releaseDesktopConsent.IsChecked -ne $true) { throw '第三条通道会退出整个 Codex 客户端，请勾选允许关闭客户端。' }
            $quotaWindow = switch ($script:quotaWindow.SelectedIndex) { 0 { 'fiveHour' }; 1 { 'weekly' }; default { 'any' } }
            $times = @()
            if ($ruleType -eq 'daily') {
                $times = @($script:ruleTimes.Text -split '[,，;；\s]+' | Where-Object { $_ } | Sort-Object -Unique)
                if ($times.Count -lt 1 -or $times.Count -gt 24 -or @($times | Where-Object { $_ -notmatch '^(?:[01]\d|2[0-3]):[0-5]\d$' }).Count -gt 0) { throw '请填写有效时间，例如 08:00, 13:00；每条规则最多 24 个时间。' }
            }
            $dates = @(); $startAt = $null; $intervalMinutes = $null
            if ($ruleType -eq 'dates') {
                $dates = @($script:ruleDates.Items | ForEach-Object { ([string]$_).Replace(' ', 'T') } | Sort-Object -Unique)
                if ($dates.Count -lt 1 -or $dates.Count -gt 100) { throw '请添加 1–100 个执行日期时间。' }
            }
            if ($ruleType -eq 'interval') {
                $startAt = Get-RuleDateTime $script:intervalPicker
                $parsedInterval = 0
                if (-not [int]::TryParse($script:intervalValue.Text.Trim(), [ref]$parsedInterval) -or $parsedInterval -lt 1 -or $parsedInterval -gt 525600) { throw '间隔必须为正整数，最长 365 天。' }
                $multiplier = switch ($script:intervalUnit.SelectedIndex) { 0 { 1 }; 1 { 60 }; 2 { 1440 }; default { throw '请选择间隔单位。' } }
                $intervalMinutes = $parsedInterval * $multiplier
                if ($intervalMinutes -gt 525600) { throw '间隔最长 365 天。' }
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
            if ($script:runMode.SelectedIndex -eq 2) { $limitValue = 1 }
            $oldRule = @($script:scheduleRules | Where-Object { $_.id -eq $id }) | Select-Object -First 1
            $reenabling = $script:ruleEnabled.IsChecked -and $oldRule -and -not $oldRule.enabled
            $activationId = if ($oldRule.activationId) { $oldRule.activationId } else { 'legacy' }
            if (-not $oldRule -or $reenabling -or $oldRule.runLimit -ne $limitValue) { $activationId = [Guid]::NewGuid().ToString() }
            $replacement = [PSCustomObject]@{id = $id; name = $name; enabled = [bool]$script:ruleEnabled.IsChecked; type = $ruleType; message = $message; messageAction = $action; deliveryMode = $delivery; replaceLastConfirmed = [bool]$replaceLastConfirmed; needsActionReview = $false; releaseDesktopOnConflict = [bool]$script:releaseDesktopConsent.IsChecked; quotaWindow = $quotaWindow; runLimit = $limitValue; activationId = $activationId; times = $times; dates = $dates; startAt = $startAt; intervalMinutes = $intervalMinutes; existingThreadId = $threadId}
            $found = $false
            for ($i = 0; $i -lt $script:scheduleRules.Count; $i++) {
                if ($script:scheduleRules[$i].id -eq $id) { $script:scheduleRules[$i] = $replacement; $found = $true; break }
            }
            if (-not $found) { $script:scheduleRules.Add($replacement) }
            Save-ScheduleConfig; Refresh-RuleList
            if ($reenabling) { Send-ScheduleCommand 'unblock' }
            foreach ($item in $script:ruleList.Items) { if ($item.Tag -eq $id) { $script:ruleList.SelectedItem = $item; break } }
            $script:scheduleFeedback.Text = '已保存。启用后，从下一次符合触发条件时开始执行。'
        } catch { Write-UiError $_; $script:scheduleFeedback.Text = $_.Exception.Message + "`n日志：" + [IO.Path]::GetFullPath((Join-Path $dataDir 'ui-errors.log')) }
    })
    $script:scheduleFeedback = New-Text '' 13 '#356649'
    $script:scheduleFeedback.Margin = '0,8,0,0'; $footerContent.Children.Add($script:scheduleFeedback) | Out-Null
    $editor = New-RuleSection $editorRoot '执行状态'
    $script:ruleStatus = New-Text '' 13 '#182848'; $editor.Children.Add($script:ruleStatus) | Out-Null
    $script:scheduleLogLocation = New-LogLocation @('schedule-state.json', 'schedule-status.json', 'ui-errors.log')
    $script:scheduleLogLocation.Visibility = 'Collapsed'; $editor.Children.Add($script:scheduleLogLocation) | Out-Null
    $logExpander = New-Object System.Windows.Controls.Expander
    $logExpander.Header = '最近执行记录'; $logExpander.FontSize = 13
    $script:ruleLog = New-Text '' 12 '#53627B'; $script:ruleLog.Margin = '0,10,0,0'; $logExpander.Content = $script:ruleLog
    $editor.Children.Add($logExpander) | Out-Null
    $editorScroll.Content = $editorRoot; $editorHost.Children.Add($editorScroll) | Out-Null; $dock.Children.Add($editorHost) | Out-Null
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
