param([Parameter(Mandatory=$true)][string]$Directory, [Parameter(Mandatory=$true)][int]$OwnerPid)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
$statusPath = Join-Path $Directory 'status.json'
$releasePath = Join-Path $Directory 'release'
$desktop = $null
$closingStarted = $false
$failure = $null
function Publish-Release($phase, $message) {
    $state = @{ phase = $phase; at = [DateTime]::UtcNow.ToString('o'); error = $message }
    [IO.File]::WriteAllText($statusPath + '.tmp', ($state | ConvertTo-Json -Compress), $utf8)
    Move-Item -LiteralPath ($statusPath + '.tmp') -Destination $statusPath -Force
}
function Same-Process($record) {
    $current = Get-CimInstance Win32_Process -Filter "ProcessId=$($record.ProcessId)"
    return $current -and $current.CreationDate -eq $record.CreationDate -and $current.ExecutablePath -eq $record.ExecutablePath
}
function Stop-RecordedTree($record) {
    if (Same-Process $record) {
        & "$env:SystemRoot\System32\taskkill.exe" /PID ([string]$record.ProcessId) /T /F | Out-Null
        if ($LASTEXITCODE -ne 0 -and (Same-Process $record)) { throw '无法结束已确认的 Codex 客户端进程。' }
    }
}
try {
    $owner = Get-CimInstance Win32_Process -Filter "ProcessId=$OwnerPid"
    if (-not $owner) { throw '监控进程已退出，取消释放。' }
    $all = @(Get-CimInstance Win32_Process)
    # Identify the installed Codex desktop and its direct app-server child.
    # Never select by codex.exe name alone: the monitor also owns that executable.
    $candidates = @($all | Where-Object {
        $_.Name -in @('ChatGPT.exe', 'Codex.exe') -and $_.ExecutablePath -and
        ($_.ExecutablePath -match '\\WindowsApps\\OpenAI\.Codex_[^\\]+\\app\\(?:ChatGPT|Codex)\.exe$' -or
         $_.ExecutablePath -match '\\OpenAI\\Codex\\app\\(?:ChatGPT|Codex)\.exe$') -and
        $_.CommandLine -notmatch '--type='
    })
    $roots = @($candidates | Where-Object { $candidate = $_; @($all | Where-Object {
        $_.ParentProcessId -eq $candidate.ProcessId -and $_.Name -eq 'codex.exe' -and
        $_.CommandLine -match '\bapp-server\b' -and $_.ExecutablePath -match '\\OpenAI\\Codex\\bin\\[^\\]+\\codex\.exe$'
    }).Count -gt 0 })
    if ($roots.Count -ne 1) { throw '无法唯一识别本机 Codex 桌面客户端及其后台；未结束任何进程，请手动退出客户端。' }
    $desktop = $roots[0]
    $ancestor = $owner
    $seen = @{}
    while ($ancestor) {
        if ($seen.ContainsKey([string]$ancestor.ProcessId)) { throw '进程父子关系异常，取消退出客户端。' }
        $seen[[string]$ancestor.ProcessId] = $true
        if ($ancestor.ProcessId -eq $desktop.ProcessId) { throw '监控自身由该 Codex 进程树启动，不能安全退出；请从桌面快捷方式独立启动监控。' }
        $parentId = $ancestor.ParentProcessId
        $ancestor = $all | Where-Object { $_.ProcessId -eq $parentId } | Select-Object -First 1
    }
    $servers = @($all | Where-Object { $_.ParentProcessId -eq $desktop.ProcessId -and $_.Name -eq 'codex.exe' -and $_.CommandLine -match '\bapp-server\b' })
    if (Test-Path -LiteralPath $releasePath) { throw '释放操作已取消。' }
    if (-not (Same-Process $owner)) { throw '监控进程已退出，取消释放。' }
    Publish-Release 'closing' $null
    $closingStarted = $true
    if (Same-Process $desktop) {
        $process = Get-Process -Id $desktop.ProcessId -ErrorAction SilentlyContinue
        if ($process -and $process.CloseMainWindow()) { Start-Sleep -Seconds 3 }
    }
    Stop-RecordedTree $desktop
    # A graceful UI exit can leave an orphaned app-server. Only touch the captured
    # child with the same executable and creation time, never a reused PID.
    foreach ($server in $servers) { Stop-RecordedTree $server }
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $remaining = @( @($desktop) + $servers | Where-Object { Same-Process $_ } )
        if ($remaining.Count -eq 0) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($remaining.Count -gt 0) { throw '客户端后台未退出，未尝试发送。' }
    Publish-Release 'released' $null
    # Independent helper restores the UI if the monitor crashes or exits too.
    while (-not (Test-Path -LiteralPath $releasePath) -and (Same-Process $owner)) { Start-Sleep -Milliseconds 500 }
} catch { $failure = $_.Exception.Message }
finally {
    if ($closingStarted -and $desktop) {
        try {
            $alreadyReopened = @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -eq $desktop.ExecutablePath -and $_.CommandLine -notmatch '--type=' })
            if (-not (Same-Process $desktop) -and $alreadyReopened.Count -eq 0) {
                Start-Process -FilePath $desktop.ExecutablePath -WorkingDirectory ([IO.Path]::GetDirectoryName($desktop.ExecutablePath)) -WindowStyle Hidden | Out-Null
            }
        } catch { $failure = '重新打开 Codex 失败：' + $_.Exception.Message }
    }
    if ($failure) { Publish-Release 'failed' $failure } else { Publish-Release 'restored' $null }
}
