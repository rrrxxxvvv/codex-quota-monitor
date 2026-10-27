const fs = require('node:fs');
const path = require('node:path');
const {spawn} = require('node:child_process');
const readline = require('node:readline');
const {EventEmitter} = require('node:events');

function codexPath() {
  if (process.env.CODEX_QUOTA_CODEX_PATH && fs.existsSync(process.env.CODEX_QUOTA_CODEX_PATH)) return process.env.CODEX_QUOTA_CODEX_PATH;
  const base = path.join(process.env.LOCALAPPDATA, 'OpenAI', 'Codex', 'bin');
  let candidates = [];
  try { candidates = fs.readdirSync(base).map(x=>path.join(base,x,'codex.exe')).filter(x=>fs.existsSync(x)); } catch {}
  candidates.sort((a,b)=>fs.statSync(b).mtimeMs-fs.statSync(a).mtimeMs);
  return candidates[0] || 'codex.exe';
}

class Client extends EventEmitter {
  constructor() {
    super(); this.id=0; this.pending=new Map(); this.dead=false;
    this.proc=spawn(codexPath(),['app-server','--stdio'],{windowsHide:true,stdio:['pipe','pipe','pipe']});
    this.proc.stderr.on('data',()=>{});
    this.proc.stdin.on('error',()=>{});
    readline.createInterface({input:this.proc.stdout}).on('line',line=>{
      let msg;try{msg=JSON.parse(line);}catch{return;}
      if (msg.method) {
        if(msg.id !== undefined) {
          // This client never grants tool permissions or asks the model to operate the computer.
          this.proc.stdin.write(JSON.stringify({id:msg.id,error:{code:-32601,message:'This greeting-only client does not handle tool or permission requests.'}})+'\n');
        } else this.emit('notification',msg);
        return;
      }
      const req=this.pending.get(msg.id);if(!req)return;
      clearTimeout(req.timer);this.pending.delete(msg.id);
      if(msg.error) req.reject(Object.assign(new Error(msg.error.message || 'Codex 接口返回错误'),{rpcCode:msg.error.code}));else req.resolve(msg.result);
    });
    this.proc.on('error',e=>this.fail(e));
    this.proc.on('exit',()=>this.fail(new Error('Codex 本地服务已退出')));
  }
  fail(error){this.dead=true;for(const req of this.pending.values()){clearTimeout(req.timer);req.reject(error);}this.pending.clear();}
  request(method,params,timeout=30000){return new Promise((resolve,reject)=>{
    if(this.dead)return reject(new Error('Codex 本地服务不可用'));
    const id=++this.id;
    const timer=setTimeout(()=>{this.pending.delete(id);reject(new Error(`${method} 请求超时，结果可能尚未确认`));},timeout);
    this.pending.set(id,{resolve,reject,timer});
    this.proc.stdin.write(JSON.stringify({id,method,...(params ? {params} : {})})+'\n');
  });}
  async init(){await this.request('initialize',{clientInfo:{name:'quota_reset_monitor',title:'Codex Quota Monitor',version:fs.readFileSync(path.join(__dirname,'VERSION'),'utf8').trim()}});this.proc.stdin.write(JSON.stringify({method:'initialized',params:{}})+'\n');}
  close(){this.fail(new Error('服务关闭'));this.proc.kill();}
}
module.exports={Client,codexPath};
