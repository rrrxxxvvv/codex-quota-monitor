const fs=require('node:fs');
const path=require('node:path');
const {spawn}=require('node:child_process');
const {randomUUID}=require('node:crypto');
const sleep=ms=>new Promise(r=>setTimeout(r,ms));

class DesktopRelease {
  constructor(data){this.data=data;this.active=null;}
  async acquire(){
    if(process.platform!=='win32')throw new Error('主动释放客户端占用仅支持 Windows。');
    if(this.active)throw new Error('已有规则正在释放客户端占用。');
    const dir=path.join(this.data,'desktop-release',randomUUID());fs.mkdirSync(dir,{recursive:true});
    const statusFile=path.join(dir,'status.json'),releaseFile=path.join(dir,'release');
    const helper=spawn(path.join(process.env.SystemRoot || 'C:\\Windows','System32','WindowsPowerShell','v1.0','powershell.exe'),[
      '-NoProfile','-ExecutionPolicy','Bypass','-File',path.join(__dirname,'DesktopRelease.ps1'),
      '-Directory',dir,'-OwnerPid',String(process.pid)
    ],{windowsHide:true,stdio:'ignore'});
    let exited=false,spawnError=null;
    helper.on('error',e=>{spawnError=e;exited=true;});helper.on('exit',()=>{exited=true;});
    const read=()=>{try{return JSON.parse(fs.readFileSync(statusFile,'utf8').replace(/^\uFEFF/,''));}catch{return null;}};
    const wait=async(predicate,timeout)=>{
      const deadline=Date.now()+timeout;
      while(Date.now()<deadline){const state=read();if(state&&predicate(state))return state;if(exited)throw new Error(spawnError?.message || state?.error || '客户端释放助手意外退出，请检查 '+statusFile);await sleep(200);}
      throw new Error('客户端释放助手等待超时，请检查 '+statusFile);
    };
    const lease={statusFile,release:async()=>{
      fs.writeFileSync(releaseFile,'release');
      const state=await wait(s=>['restored','failed'].includes(s.phase),30000);
      if(state.phase==='failed')throw new Error(state.error || '无法重新打开 Codex 客户端。');
    }};
    this.active=lease;
    try{
      const state=await wait(s=>['released','failed'].includes(s.phase),45000);
      if(state.phase==='failed')throw new Error(state.error || '未能释放 Codex 客户端。');
      return {statusFile,release:async()=>{try{await lease.release();}finally{this.active=null;}}};
    }catch(e){
      // Even a timeout must tell the independent helper to restore the client.
      fs.writeFileSync(releaseFile,'release');this.active=null;throw e;
    }
  }
}
module.exports={DesktopRelease};
