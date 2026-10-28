const assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {spawn}=require('node:child_process');
const {atomic}=require('../scheduler.cjs');
if(process.platform!=='win32'){console.log('SKIP: Windows file sharing test');process.exit(0);}
const directory=fs.mkdtempSync(path.join(os.tmpdir(),'quota-state-lock-'));
const file=path.join(directory,'state.json');
const powershell=path.join(process.env.WINDIR,'System32','WindowsPowerShell','v1.0','powershell.exe');
async function lockedWrite(duration,shouldSucceed){
 fs.writeFileSync(file,JSON.stringify({count:1}));
 const script=`$f=[IO.File]::Open('${file.replaceAll("'","''")}',[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);try{[Console]::WriteLine('locked');[Threading.Thread]::Sleep(${duration})}finally{$f.Dispose()}`;
 const child=spawn(powershell,['-NoProfile','-EncodedCommand',Buffer.from(script,'utf16le').toString('base64')],{windowsHide:true,stdio:['ignore','pipe','pipe']});
 const exited=new Promise(resolve=>child.once('exit',resolve));
 await new Promise((resolve,reject)=>{
  child.stdout.on('data',chunk=>{if(chunk.toString().includes('locked'))resolve();});
  child.on('error',reject);child.on('exit',()=>reject(new Error('Lock process exited before acquiring lock')));
 });
 try{
  if(shouldSucceed){atomic(file,{count:2});assert.deepEqual(JSON.parse(fs.readFileSync(file)),{count:2});}
  else{
   // Node/libuv versions can retry internally until the reader releases its handle.
   let written=false;
   try{atomic(file,{count:2});written=true;}catch(e){assert.ok(['EPERM','EACCES','EBUSY'].includes(e.code));}
   assert.deepEqual(JSON.parse(fs.readFileSync(file)),{count:written?2:1},'state must remain complete under contention');
  }
 }finally{await exited;}
}
(async()=>{
 await lockedWrite(120,true);await lockedWrite(1200,false);
 fs.writeFileSync(file,JSON.stringify({count:1}));
 const rename=fs.renameSync;
 try{
  fs.renameSync=()=>{throw Object.assign(new Error('persistent sharing violation'),{code:'EPERM'});};
  const start=Date.now();assert.throws(()=>atomic(file,{count:2}),e=>e.code==='EPERM');
  assert.ok(Date.now()-start<2000,'application retries must be bounded');
  assert.deepEqual(JSON.parse(fs.readFileSync(file)),{count:1},'persistent replacement failure must retain previous state');
 }finally{fs.renameSync=rename;}
 console.log('PASS: real Windows reader contention, complete state after release, bounded application retries and durable state preserved on injected persistent failure.');
})().catch(e=>{console.error(e);process.exitCode=1;});
