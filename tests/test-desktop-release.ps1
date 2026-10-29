$ErrorActionPreference = 'Stop'
# Run the production controller with a simulated process table. No real process
# termination or desktop launch is allowed in this test.
$source = [IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'DesktopRelease.ps1'))
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw $errors[0]}
$stop=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Stop-RecordedTree'},$true)
$replacement=@'
function Stop-RecordedTree($record) {
    if($script:scenario -eq 'pid-reused' -and $record.ProcessId -eq 10){
        ($script:table | Where-Object ProcessId -eq 10).CreationDate='new-identity'
    }
    if(Same-Process $record){
        $script:removed += $record.ProcessId
        $script:table=@($script:table | Where-Object ProcessId -ne $record.ProcessId)
    }
}
'@
$source=$source.Substring(0,$stop.Extent.StartOffset)+$replacement+$source.Substring($stop.Extent.EndOffset)
$controller=[ScriptBlock]::Create($source)
function Record($id,$parent,$name,$exe,$command){[pscustomobject]@{ProcessId=$id;ParentProcessId=$parent;Name=$name;ExecutablePath=$exe;CommandLine=$command;CreationDate='original'}}
function Get-CimInstance($ClassName,$Filter){
    $selected=$script:table
    if($Filter){$selected=@($selected | Where-Object ProcessId -eq ([int]($Filter -replace 'ProcessId=','')))}
    # CIM queries return snapshots, not references into the live process table.
    foreach($item in $selected){$item | Select-Object *}
}
function Get-Process($Id,$ErrorAction){$p=New-Object PSObject;$p | Add-Member ScriptMethod CloseMainWindow {return $false};return $p}
function Start-Process($FilePath,$WorkingDirectory,$WindowStyle){
    if($WindowStyle -ne 'Hidden'){throw 'Background launch must be hidden'}
    $script:launched += $FilePath
    if($script:scenario -eq 'restart-failed'){throw 'simulated launch failure'}
}
function Start-Sleep($Milliseconds,$Seconds){
    if(Test-Path -LiteralPath (Join-Path $script:testDir 'status.json')){
        $state=[IO.File]::ReadAllText((Join-Path $script:testDir 'status.json')) | ConvertFrom-Json
        if($state.phase -eq 'released'){
            if($script:scenario -eq 'owner-exit'){$script:table=@($script:table | Where-Object ProcessId -ne 1)}
            else{[IO.File]::WriteAllText((Join-Path $script:testDir 'release'),'release')}
            if($script:scenario -eq 'reopened'){$script:table += Record 30 0 'ChatGPT.exe' $script:exe 'desktop'}
        }
    }
}
$script:exe='C:\Program Files\WindowsApps\OpenAI.Codex_1_x64__test\app\ChatGPT.exe'
foreach($scenarioName in @('success','no-desktop','ambiguous','descendant','pid-reused','owner-exit','reopened','restart-failed')){
    $script:scenario=$scenarioName;$script:removed=@();$script:launched=@()
    $script:testDir=Join-Path ([IO.Path]::GetTempPath()) ('quota-release-test-'+[Guid]::NewGuid())
    [IO.Directory]::CreateDirectory($script:testDir) | Out-Null
    $script:table=@(
        (Record 1 0 'node.exe' 'C:\Monitor\node.exe' 'monitor'),
        (Record 10 0 'ChatGPT.exe' $script:exe 'desktop'),
        (Record 11 10 'codex.exe' 'C:\Users\test\AppData\Local\OpenAI\Codex\bin\version\codex.exe' 'codex app-server'),
        (Record 12 1 'codex.exe' 'C:\Users\test\AppData\Local\OpenAI\Codex\bin\version\codex.exe' 'codex app-server')
    )
    if($scenarioName -eq 'no-desktop'){$script:table=@($script:table | Where-Object ProcessId -ne 10)}
    if($scenarioName -eq 'ambiguous'){$script:table += Record 20 0 'ChatGPT.exe' $script:exe 'desktop';$script:table += Record 21 20 'codex.exe' 'C:\Users\test\AppData\Local\OpenAI\Codex\bin\version\codex.exe' 'app-server'}
    if($scenarioName -eq 'descendant'){($script:table | Where-Object ProcessId -eq 1).ParentProcessId=10}
    & $controller -Directory $script:testDir -OwnerPid 1
    $state=[IO.File]::ReadAllText((Join-Path $script:testDir 'status.json')) | ConvertFrom-Json
    if($script:removed -contains 1 -or $script:removed -contains 12){throw 'Monitor process or own server selected for termination'}
    if($scenarioName -in @('no-desktop','ambiguous','descendant')){
        if($state.phase -ne 'failed' -or $script:removed.Count -or $script:launched.Count){throw "Unsafe selection in $scenarioName"}
    }elseif($scenarioName -eq 'restart-failed'){
        if($state.phase -ne 'failed' -or $state.error -notlike '*simulated launch failure*'){throw 'Restore failure not surfaced'}
    }else{
        if($state.phase -ne 'restored'){throw "Restore failed in $scenarioName : $($state.error)"}
        $expected=if($scenarioName -in @('reopened','pid-reused')){0}else{1}
        if($script:launched.Count -ne $expected){throw "Wrong relaunch count in $scenarioName"}
        if($scenarioName -eq 'pid-reused' -and $script:removed -contains 10){throw 'Reused PID was terminated'}
        if($scenarioName -ne 'pid-reused' -and ($script:removed -notcontains 10 -or $script:removed -notcontains 11)){throw 'Recorded desktop and orphan server were not closed'}
    }
    Write-Output "PASS: simulated desktop lifecycle $scenarioName"
}
