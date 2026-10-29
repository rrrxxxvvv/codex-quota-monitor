const fs=require('node:fs'),path=require('node:path');
const {spawn}=require('node:child_process');
const {randomUUID}=require('node:crypto');
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
class DesktopUi {
  constructor(data){this.data=data;this.active=null;}
  cancel(){if(this.active)fs.writeFileSync(path.join(this.active,'cancel'),'cancel');}
  async send(plan,beforeSubmit){
    if(process.platform!=='win32')return {status:'notSent',error:'界面发送仅支持 Windows。'};
    if(this.active)throw new Error('界面发送通道忙碌。');
    const dir=path.join(this.data,'ui-automation',randomUUID());fs.mkdirSync(dir,{recursive:true});this.active=dir;
    fs.writeFileSync(path.join(dir,'plan.json'),JSON.stringify(plan));
    const logFile=path.join(dir,'helper.log'),fd=fs.openSync(logFile,'a');
    const child=spawn(path.join(process.env.SystemRoot || 'C:\\Windows','System32','WindowsPowerShell','v1.0','powershell.exe'),['-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',path.join(__dirname,'DesktopAutomation.ps1'),'-Directory',dir],{windowsHide:true,stdio:['ignore',fd,fd]});fs.closeSync(fd);
    let exited=false,error=null,authorized=false,prechecked=false;
    child.once('error',e=>{error=e.message;exited=true;});child.once('exit',()=>{exited=true;});
    const read=()=>{try{return JSON.parse(fs.readFileSync(path.join(dir,'status.json'),'utf8').replace(/^\uFEFF/,''));}catch{return null;}};
    try{
      const deadline=Date.now()+65000;
      while(Date.now()<deadline){
        const state=read();
        if(state?.phase==='ready'&&!prechecked){
          prechecked=true;
          try{await beforeSubmit();authorized=true;fs.writeFileSync(path.join(dir,'commit'),'commit');}
          catch(e){error=e.message;this.cancel();}
        }
        if(['notSent','submitted','uncertain'].includes(state?.phase))return {status:authorized&&state.phase==='notSent'?'uncertain':state.phase,error:error || state.error,restartAllowed:state.restartAllowed!==false&&!error,logFile,statusFile:path.join(dir,'status.json')};
        if(exited)return {status:'uncertain',error:error || '界面助手意外退出，未确认是否提交。',logFile};
        await sleep(150);
      }
      this.cancel();
      for(let i=0;i<30&&!exited;i++)await sleep(200);
      const final=read();
      if(!exited){child.kill();await new Promise(resolve=>child.once('exit',resolve));}
      return {status:!authorized&&final?.phase==='notSent'?'notSent':'uncertain',error:'界面操作超时；'+(final?.error || '请核对任务及草稿。'),logFile};
    }finally{
      // Prompt text is transient; logs/status contain structure and errors only.
      fs.rmSync(path.join(dir,'plan.json'),{force:true});this.active=null;
    }
  }
}
module.exports={DesktopUi};
