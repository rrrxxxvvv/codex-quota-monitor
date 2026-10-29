$ErrorActionPreference='Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, WindowsBase, System.Windows.Forms, System.Drawing
$source=[IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'DesktopAutomation.cs'))
$tests=@'
public static class DesktopLookupTests {
  static void Assert(bool value,string message){if(!value)throw new Exception(message);}
  public static void Run(){
    string[] names={"other","  聊天操作  ","Chat actions"};
    string[] labels={"聊天操作","Chat actions"};
    Assert(QuotaDesktop.UniqueReadyIndex(names,new[]{true,true,false},new[]{true,true,true},labels)==1,"trimmed Chinese label");
    Assert(QuotaDesktop.UniqueReadyIndex(names,new[]{true,true,true},new[]{true,true,true},labels)==-1,"duplicate controls must not be clicked");
    Assert(QuotaDesktop.UniqueReadyIndex(names,new[]{true,true,true},new[]{true,false,false},labels)==-1,"disabled controls must not be clicked");
    int time=0,attempts=0,checks=0;object ready=new object();
    var found=QuotaDesktop.WaitForControl(()=>++attempts>=4?ready:null,()=>checks++,ms=>time+=ms,()=>time,8000);
    Assert(found==ready&&time==750&&checks==4,"delayed UI must be retried");
    time=0;attempts=0;
    found=QuotaDesktop.WaitForControl<object>(()=>{attempts++;return null;},()=>{},ms=>time+=ms,()=>time,8000);
    Assert(found==null&&time==8000&&attempts==32,"missing UI must time out");
    bool stopped=false;time=0;
    try{QuotaDesktop.WaitForControl<object>(()=>null,()=>{throw new Exception("focus changed");},ms=>time+=ms,()=>time,8000);}catch(Exception){stopped=true;}
    Assert(stopped&&time==0,"user activity must abort the wait");
    var calls=new List<string>();
    QuotaDesktop.CopyLinkWithFallback(()=>calls.Add("menu"),()=>calls.Add("shortcut"),()=>calls.Add("reset"),()=>calls.Add("dismiss"),()=>calls.Add("check"),s=>{});
    Assert(String.Join(",",calls)=="menu","successful menu must not send shortcut");
    calls.Clear();
    QuotaDesktop.CopyLinkWithFallback(()=>{throw new QuotaDesktop.LookupException("no menu");},()=>calls.Add("shortcut"),()=>calls.Add("reset"),()=>calls.Add("dismiss"),()=>calls.Add("check"),s=>{});
    Assert(String.Join(",",calls)=="check,dismiss,reset,check,shortcut","lookup failure must use guarded shortcut");
    calls.Clear();stopped=false;
    try{QuotaDesktop.CopyLinkWithFallback(()=>{throw new Exception("user input");},()=>calls.Add("shortcut"),()=>{},()=>{},()=>{},s=>{});}catch(Exception){stopped=true;}
    Assert(stopped&&calls.Count==0,"input/focus error must not trigger fallback");
    calls.Clear();stopped=false;
    try{QuotaDesktop.CopyLinkWithFallback(()=>{throw new QuotaDesktop.LookupException("no menu");},()=>calls.Add("shortcut"),()=>{},()=>{},()=>{throw new Exception("locked");},s=>{});}catch(Exception){stopped=true;}
    Assert(stopped&&calls.Count==0,"lock detected before fallback must stop keys");
    const string id="11111111-1111-4111-8111-111111111111";
    Assert(QuotaDesktop.IsExpectedLink("codex://threads/"+id,id),"correct task link");
    Assert(!QuotaDesktop.IsExpectedLink("codex://threads/22222222-2222-4222-8222-222222222222",id),"other task must fail");
    Assert(!QuotaDesktop.IsExpectedLink("quota-check-marker",id),"unchanged clipboard must fail");
    Assert(!QuotaDesktop.IsExpectedLink("https://example.com/"+id,id),"non-Codex URL must fail");
  }
}
'@
Add-Type -TypeDefinition ($source + "`n" + $tests) -ReferencedAssemblies @('UIAutomationClient','UIAutomationTypes','WindowsBase','System.Windows.Forms','System.Drawing','System.Core','System')
[DesktopLookupTests]::Run()
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'DesktopAutomation.ps1'),[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw $parseErrors[0]}
$publish=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Publish-Ui'},$true)
. ([ScriptBlock]::Create($publish.Extent.Text))
$Directory=Join-Path ([IO.Path]::GetTempPath()) ('quota-lookup-log-test-'+[Guid]::NewGuid())
[IO.Directory]::CreateDirectory($Directory) | Out-Null
$utf8=New-Object Text.UTF8Encoding($false);$restartAllowed=$false
$log=Publish-Ui 'notSent' 'fixture: menu unavailable'
$state=[IO.File]::ReadAllText((Join-Path $Directory 'status.json')) | ConvertFrom-Json
if($state.phase -ne 'notSent' -or $state.error -ne 'fixture: menu unavailable' -or $null -eq $state.diagnostics -or $log -notlike '*notSent: fixture: menu unavailable*'){throw 'Diagnostic serialization failed'}
Write-Output 'PASS: native helper compiles; delayed/missing/duplicate controls; guarded shortcut fallback; no fallback on user input or lock; exact task ID verification. No desktop input or messages sent.'
Write-Output 'PASS: actual status publisher includes diagnostics and writes a human-readable helper log entry.'
