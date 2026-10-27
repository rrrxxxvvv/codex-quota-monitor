function Show-RemoteWindow {
    if ($script:remoteWindow) { $script:remoteWindow.Activate() | Out-Null; return }
    $w = New-Object System.Windows.Window
    $script:remoteWindow = $w
    $w.Title = 'AstrBot 额度推送'; $w.Width = 570; $w.Height = 740
    $w.WindowStartupLocation = 'CenterScreen'
    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = '24'
    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Auto'; $scroll.Content = $panel; $w.Content = $scroll
    $panel.Children.Add((New-Text 'AstrBot 额度推送' 24 '#182848')) | Out-Null
    $enabled = New-Object System.Windows.Controls.CheckBox
    $enabled.Content = '启用远程上传'; $enabled.Margin = '0,14,0,14'
    $panel.Children.Add($enabled) | Out-Null
    $panel.Children.Add((New-Text '接收服务器 IP:端口（或 HTTPS 根地址）' 14 '#182848')) | Out-Null
    $address = New-RuleTextBox; $panel.Children.Add($address) | Out-Null
    $panel.Children.Add((New-Text '绑定 QQ 号（必填，用于推送与额度查询）' 14 '#182848')) | Out-Null
    $qq = New-RuleTextBox; $panel.Children.Add($qq) | Out-Null
    $panel.Children.Add((New-Text '连接密钥（两端一致，至少 32 个字符）' 14 '#182848')) | Out-Null
    $secret = New-Object System.Windows.Controls.PasswordBox
    $secret.Padding = '8'; $secret.Margin = '0,0,0,12'
    $panel.Children.Add($secret) | Out-Null
    $panel.Children.Add((New-Text '上传间隔（秒，15–86400，默认 60）' 14 '#182848')) | Out-Null
    $interval = New-RuleTextBox; $interval.Text = '60'; $panel.Children.Add($interval) | Out-Null
    $panel.Children.Add((New-Text '额度仍每分钟采集一次，仅上传新采集结果。上传失败按此间隔重试；间隔较长会延迟 QQ 推送，查询可能显示数据过期。' 12 '#53627B')) | Out-Null
    $panel.Children.Add((New-Text '额度仅推送给绑定 QQ，查询也只返回该 QQ 的数据。请先添加机器人为好友，可私聊开启或关闭额度推送。' 13 '#53627B')) | Out-Null
    $panel.Children.Add((New-Text 'QQ 通知设置（随上传同步，仅作用于绑定 QQ）' 16 '#182848')) | Out-Null
    $noticeBoxes = @{}
    foreach ($entry in @(@('weeklyReset','每周额度更新'), @('offCycleReset','周期外重置及可用额度增加'), @('cardExpiry','重置卡到期提醒'))) {
        $box = New-Object System.Windows.Controls.CheckBox
        $box.Content = $entry[1]; $box.IsChecked = $true; $box.Margin = '0,0,0,10'
        $noticeBoxes[$entry[0]] = $box; $panel.Children.Add($box) | Out-Null
    }
    $panel.Children.Add((New-Text '到期提醒阈值（天，逗号分隔；默认 7, 1）' 14 '#182848')) | Out-Null
    $expiryDays = New-RuleTextBox; $expiryDays.Text = '7, 1'; $panel.Children.Add($expiryDays) | Out-Null
    $panel.Children.Add((New-Text '每个阈值 1–365 天，最多 10 项；每张卡在每档只提醒一次。Bot 私聊中的关闭推送仍是总开关；额度查询不受影响。' 12 '#53627B')) | Out-Null
    $file = Join-Path $dataDir 'remote-config.json'
    if ([IO.File]::Exists($file)) {
        try { $c = [IO.File]::ReadAllText($file) | ConvertFrom-Json; $enabled.IsChecked = [bool]$c.enabled; $address.Text = $c.address; $secret.Password = $c.secret } catch {}
        if ($null -ne $c.uploadIntervalSeconds) { $interval.Text = [string]$c.uploadIntervalSeconds }
        if ($c.qq) { $qq.Text = [string]$c.qq }
        if ($c.notifications) {
            foreach ($key in $noticeBoxes.Keys) { if ($null -ne $c.notifications.$key) { $noticeBoxes[$key].IsChecked = [bool]$c.notifications.$key } }
            if ($c.notifications.expiryDays) { $expiryDays.Text = $c.notifications.expiryDays -join ', ' }
        }
    }
    $feedback = New-Text '' 13 '#53627B'
    $save = New-Button '保存上传设置'
    $save.Tag = @{enabled=$enabled;address=$address;qq=$qq;secret=$secret;interval=$interval;notices=$noticeBoxes;expiryDays=$expiryDays;feedback=$feedback;file=$file}
    $save.Add_Click({
        $v = $this.Tag
        try {
            $a = $v.address.Text.Trim()
            $days = @()
            foreach ($part in @($v.expiryDays.Text -split '[,，;；\s]+' | Where-Object { $_ })) {
                $day = 0
                if (-not [int]::TryParse($part, [ref]$day) -or $day -lt 1 -or $day -gt 365) { throw '到期阈值请输入 1–365 天的整数，例如 7, 1。' }
                $days += $day
            }
            if ($days.Count -lt 1 -or $days.Count -gt 10) { throw '到期阈值需要 1–10 项。' }
            $notifications = @{weeklyReset=[bool]$v.notices.weeklyReset.IsChecked;offCycleReset=[bool]$v.notices.offCycleReset.IsChecked;cardExpiry=[bool]$v.notices.cardExpiry.IsChecked;expiryDays=@($days | Sort-Object -Descending -Unique)}
            $seconds = 0
            if (-not [int]::TryParse($v.interval.Text.Trim(), [ref]$seconds) -or $seconds -lt 15 -or $seconds -gt 86400) { throw '上传间隔请输入 15–86400 秒的整数。' }
            if ($v.enabled.IsChecked) {
                if ($v.qq.Text.Trim() -notmatch '^[1-9][0-9]{4,11}$') { throw '请填写有效的绑定 QQ 号。' }
                $uriText = if ($a -match '://') { $a } else { 'http://' + $a }
                $u = [Uri]$uriText
                if (-not $u.IsAbsoluteUri -or $u.Scheme -notin @('http','https') -or -not $u.Host -or $u.UserInfo -or $u.Query -or $u.Fragment -or $u.AbsolutePath -ne '/') { throw '请填写有效 IP:端口或 HTTP(S) 根地址。' }
                if ($v.secret.Password.Length -lt 32) { throw '连接密钥至少需要 32 个字符。' }
            }
            $payload = @{enabled=[bool]$v.enabled.IsChecked;address=$a;qq=$v.qq.Text.Trim();secret=$v.secret.Password;uploadIntervalSeconds=$seconds;notifications=$notifications}
            [IO.File]::WriteAllText(($v.file + '.tmp'), ($payload | ConvertTo-Json -Depth 6), $utf8)
            Move-Item -LiteralPath ($v.file + '.tmp') -Destination $v.file -Force
            $v.feedback.Text = '已保存，上传设置会自动生效。'
        } catch { $v.feedback.Text = $_.Exception.Message }
    })
    $panel.Children.Add($save) | Out-Null
    $panel.Children.Add($feedback) | Out-Null
    $statusText = New-Text '' 13 '#53627B'; $panel.Children.Add($statusText) | Out-Null
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(2)
    $script:remoteStatusText = $statusText
    $timer.Add_Tick({
        try {
            $s = [IO.File]::ReadAllText((Join-Path $dataDir 'remote-status.json')) | ConvertFrom-Json
            $script:remoteStatusText.Text = if (-not $s.enabled) { '上传未启用。' } elseif ($s.error) { '上传状态：' + $s.error } else { '已上传采集时间：' + [DateTimeOffset]::Parse($s.checkedAt).ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-dd HH:mm:ss') }
        } catch { $script:remoteStatusText.Text = '等待上传状态…' }
    })
    $timer.Start(); $w.Tag = $timer
    $w.Add_Closed({ $this.Tag.Stop(); $script:remoteWindow = $null })
    $w.Show()
}
