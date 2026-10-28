param(
    [ValidateSet('x64', 'arm64')][string]$Architecture = 'x64',
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$nodeVersion = '24.22.1'
# SHA-256 values from https://nodejs.org/dist/v24.22.1/SHASUMS256.txt
$hashes = @{
    x64 = 'd2046d28c2c3dcd211ac5145c0bf30e2047ef9dfb306693c8c6e2eccd8b95fa5'
    arm64 = 'a0c807319fede24c4a0d8f84564c82a619bd313b16b10c007c383c2609e99171'
}
$version = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'VERSION')).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid application version.' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$cache = Join-Path $PSScriptRoot '.build-cache'
[IO.Directory]::CreateDirectory($cache) | Out-Null
$archiveName = "node-v$nodeVersion-win-$Architecture.zip"
$archivePath = Join-Path $cache $archiveName
if (-not [IO.File]::Exists($archivePath)) {
    Write-Output "Downloading official Node.js $nodeVersion ($Architecture)..."
    $url = "https://nodejs.org/dist/v$nodeVersion/$archiveName"
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & $curl.Source --fail --location --silent --show-error --connect-timeout 30 --max-time 300 --retry 2 --output ($archivePath + '.download') $url
        if ($LASTEXITCODE -ne 0) { throw 'Node.js download failed. Check the network and retry.' }
    } else {
        $download = New-Object Net.WebClient
        try { $download.DownloadFile($url, $archivePath + '.download') }
        finally { $download.Dispose() }
    }
    Move-Item -LiteralPath ($archivePath + '.download') -Destination $archivePath -Force
}
if ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hashes[$Architecture]) {
    throw "Node archive checksum mismatch. Remove the cached archive and retry: $archivePath"
}
$stage = Join-Path ([IO.Path]::GetTempPath()) ('codex-quota-package-' + [Guid]::NewGuid().ToString())
$package = Join-Path $stage 'CodexQuotaMonitor'
$nodeDirectory = Join-Path $package 'runtime'
[IO.Directory]::CreateDirectory($nodeDirectory) | Out-Null
try {
    # Explicit source allowlist: never copy data, credentials, logs or build output.
    $files = @('Monitor.ps1', 'Schedule.ps1', 'Remote.ps1', 'Start.vbs', 'Settings.vbs',
        'monitor.cjs', 'codex-client.cjs', 'quota-core.cjs', 'schedule-core.cjs',
        'scheduler.cjs', 'thread-activity.cjs', 'remote.cjs', 'VERSION', 'README.md', 'CHANGELOG.md')
    foreach ($file in $files) { [IO.File]::Copy((Join-Path $PSScriptRoot $file), (Join-Path $package $file)) }
    $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        foreach ($name in @('node.exe', 'LICENSE')) {
            $entry = $archive.GetEntry("node-v$nodeVersion-win-$Architecture/$name")
            if (-not $entry) { throw "Missing runtime file: $name" }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $nodeDirectory $name))
        }
    } finally { $archive.Dispose() }
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $nodeDirectory 'VERSION'), "Node.js v$nodeVersion`r`nWindows $Architecture`r`nhttps://nodejs.org/`r`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $package 'START-HERE.txt'), @"
Codex Quota Monitor $version - Windows $Architecture portable

1. Extract the entire ZIP into a writable folder.
2. Install Codex and sign in on this computer.
3. Double-click Start.vbs. Settings.vbs opens the rule editor.

Node.js is included in runtime/. No Node.js or npm installation is required.
Windows PowerShell 5.1, WPF and Windows Script Host are required.
Do not run directly inside the ZIP, or remove runtime/.
Settings are created in data/ on first launch. Do not redistribute your data/.
For upgrades, exit the monitor, replace program files and retain your own data/.
See README.md for Chinese instructions and AstrBot integration.
"@, $utf8)
    $target = Join-Path $OutputDirectory "CodexQuotaMonitor-$version-win-$Architecture-portable.zip"
    $temporary = $target + '.' + [Guid]::NewGuid().ToString() + '.tmp'
    [IO.Compression.ZipFile]::CreateFromDirectory($stage, $temporary, [IO.Compression.CompressionLevel]::Optimal, $false)
    Move-Item -LiteralPath $temporary -Destination $target -Force
    $checksum = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($target + '.sha256', "$checksum  $([IO.Path]::GetFileName($target))`n", $utf8)
    Write-Output "Created: $target"
    Write-Output "SHA256: $checksum"
} finally {
    # Only remove the unique staging directory created inside the system temp folder.
    $resolved = [IO.Path]::GetFullPath($stage)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -like 'codex-quota-package-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
