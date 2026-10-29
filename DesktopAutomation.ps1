param([Parameter(Mandatory=$true)][string]$Directory)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, WindowsBase, System.Windows.Forms, System.Drawing
Add-Type -Path (Join-Path $PSScriptRoot 'DesktopAutomation.cs') -ReferencedAssemblies @('UIAutomationClient', 'UIAutomationTypes', 'WindowsBase', 'System.Windows.Forms', 'System.Drawing', 'System.Core', 'System')
$utf8 = New-Object Text.UTF8Encoding($false)
$plan = [IO.File]::ReadAllText((Join-Path $Directory 'plan.json')) | ConvertFrom-Json
$committed = $false; $changed = $false; $editOpened = $false; $editor = $null
$restartAllowed = $true
$sendNames = @('发送','Send','傳送','送信','보내기','Envoyer','Senden','Enviar','Invia','Отправить')
$editNames = @('编辑消息','Edit message','編輯訊息','メッセージを編集','메시지 수정','Modifier le message','Nachricht bearbeiten','Editar mensaje','Editar mensagem','Modifica messaggio','Редактировать сообщение')
$cancelNames = @('取消','Cancel','キャンセル','취소','Annuler','Abbrechen','Cancelar','Annulla','Отмена')
function Publish-Ui($phase,$errorText) {
    [IO.File]::WriteAllText((Join-Path $Directory 'status.json.tmp'), (@{phase=$phase;error=$errorText;restartAllowed=$restartAllowed;at=[DateTime]::UtcNow.ToString('o');diagnostics=@([QuotaDesktop]::Diagnostics())} | ConvertTo-Json -Depth 4 -Compress), $utf8)
    Move-Item -LiteralPath (Join-Path $Directory 'status.json.tmp') -Destination (Join-Path $Directory 'status.json') -Force
    Write-Output ([DateTime]::UtcNow.ToString('o') + ' ' + $phase + $(if($errorText){': '+$errorText}else{''}))
}
function Wait-Editor($names) {
    for($i=0;$i -lt 20;$i++){try{return [QuotaDesktop]::One(50004,$names)}catch{Start-Sleep -Milliseconds 200}}
    throw '无法唯一定位输入框。'
}
function Canonical-Text([string]$text) { return $text.Replace("`r`n","`n").Replace("`r","`n").TrimEnd("`n") }
try {
    Publish-Ui 'opening' $null
    [QuotaDesktop]::Open($plan.threadId)
    [QuotaDesktop]::AssertThread($plan.threadId)
    # Refuse to overwrite any existing draft in the composer.
    $composer = [QuotaDesktop]::One(50004,$null)
    $draft=[QuotaDesktop]::Text($composer).Trim()
    $placeholderOnly=$draft -eq $composer.Current.Name -and @([QuotaDesktop]::Find(50000,$sendNames)).Count -eq 0
    if ($draft.Length -gt 0 -and -not $placeholderOnly) { $restartAllowed=$false; throw '目标任务已有草稿，保持草稿不变。' }
    if ($plan.action -eq 'replaceLast') {
        if (-not $plan.expectedLastMessage) { throw '没有可核对的末条消息。' }
        # Scroll only within this task, then hover the exact last user message.
        [QuotaDesktop]::Click($composer)
        [QuotaDesktop]::Chord(0x1B,$false,$false)
        [QuotaDesktop]::Hover([QuotaDesktop]::Message($plan.expectedLastMessage))
        [QuotaDesktop]::Click([QuotaDesktop]::One(50000,$editNames));$editOpened=$true
        $editor = Wait-Editor $editNames
        if ((Canonical-Text ([QuotaDesktop]::Text($editor))) -ne (Canonical-Text $plan.expectedLastMessage)) { throw '编辑框内容与末条消息不一致。' }
    } elseif ($plan.action -eq 'append') { $editor=$composer } else { throw '未知发送方式。' }
    [QuotaDesktop]::Click($editor)
    if ($plan.action -eq 'replaceLast') { [QuotaDesktop]::Chord(0x41,$true,$false) }
    $changed=$true
    [QuotaDesktop]::Type($plan.message)
    if ((Canonical-Text ([QuotaDesktop]::Text($editor))) -ne (Canonical-Text $plan.message)) { throw '输入后的内容校验失败。' }
    [QuotaDesktop]::AssertThread($plan.threadId)
    Publish-Ui 'ready' $null
    $deadline=[DateTime]::UtcNow.AddSeconds(30)
    while(-not (Test-Path -LiteralPath (Join-Path $Directory 'commit'))){
        if((Test-Path -LiteralPath (Join-Path $Directory 'cancel')) -or [DateTime]::UtcNow -gt $deadline){throw '发送前核验取消或超时。'}
        [QuotaDesktop]::Check();Start-Sleep -Milliseconds 100
    }
    [QuotaDesktop]::AssertThread($plan.threadId)
    if ((Canonical-Text ([QuotaDesktop]::Text($editor))) -ne (Canonical-Text $plan.message)) { throw '提交前草稿被改变。' }
    $send=[QuotaDesktop]::One(50000,$sendNames)
    $committed=$true;Publish-Ui 'submitting' $null
    [QuotaDesktop]::Click($send)
    Publish-Ui 'submitted' $null
} catch {
    $problem=$_.Exception.Message
    if($problem -match '前台窗口已改变|其他键鼠输入|桌面已锁定|取消或超时|草稿被改变'){$restartAllowed=$false}
    if($committed){Publish-Ui 'uncertain' $problem}
    else {
        try {
            if($editOpened){
                [QuotaDesktop]::AssertThread($plan.threadId);[QuotaDesktop]::Click([QuotaDesktop]::One(50000,$cancelNames))
                for($i=0;$i -lt 20 -and @([QuotaDesktop]::Find(50004,$editNames)).Count -gt 0;$i++){Start-Sleep -Milliseconds 100}
                if(@([QuotaDesktop]::Find(50004,$editNames)).Count -gt 0){throw '未能确认已退出编辑。'}
            }
            elseif($changed){
                [QuotaDesktop]::AssertThread($plan.threadId)
                if((Canonical-Text ([QuotaDesktop]::Text($editor))) -ne (Canonical-Text $plan.message)){throw '草稿已被改变，不能自动清理。'}
                [QuotaDesktop]::Click($editor);[QuotaDesktop]::Chord(0x41,$true,$false);[QuotaDesktop]::Chord(0x08,$false,$false)
                $remaining=[QuotaDesktop]::Text($editor).Trim()
                if($remaining.Length -gt 0 -and -not ($remaining -eq $editor.Current.Name -and @([QuotaDesktop]::Find(50000,$sendNames)).Count -eq 0)){throw '未能确认草稿已清理。'}
            }
            Publish-Ui 'notSent' $problem
        } catch { Publish-Ui 'uncertain' ($problem + '；界面恢复未确认：' + $_.Exception.Message) }
    }
}
