const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const read = file => JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
const atomic = (file, value) => { fs.writeFileSync(file+'.tmp', JSON.stringify(value,null,2)); fs.renameSync(file+'.tmp',file); };
function endpoint(address) {
  const url = new URL(address.includes('://') ? address : `http://${address}`);
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash || !['','/'].includes(url.pathname)) throw Error('请填写服务器 IP:端口或 HTTP(S) 根地址');
  url.pathname = '/v1/quota'; return url.href;
}
function notificationSettings(raw={}) {
  const value={};
  for(const key of ['weeklyReset','offCycleReset','cardExpiry']) {
    value[key]=raw[key] ?? true;
    if(typeof value[key]!=='boolean')throw Error('通知开关必须为布尔值');
  }
  const days=raw.expiryDays ?? [7,1];
  if(!Array.isArray(days) || !days.length || days.length>10 || days.some(x=>!Number.isInteger(x)||x<1||x>365)) throw Error('到期阈值需为 1–365 天的整数，最多 10 项');
  value.expiryDays=[...new Set(days)].sort((a,b)=>b-a);
  return value;
}
function snapshot(state, qq, notifications=notificationSettings()) {
  if(typeof qq!=='string' || !/^[1-9][0-9]{4,11}$/.test(qq)) throw Error('请填写接收推送和查询额度的 QQ 号');
  return {version:2, qq, notifications, accountKey:crypto.createHash('sha256').update(state.accountId).digest('hex'), checkedAt:state.checkedAt,
    windows:Object.entries(state.currentWindows).map(([key,w])=>({key,label:w.label,usedPercent:w.usedPercent,windowDurationMins:w.windowDurationMins,resetsAt:w.resetsAt})),
    resetCredits:state.resetCredits ?? null};
}
function uploadInterval(config) {
  const seconds=config.uploadIntervalSeconds ?? 60;
  if(!Number.isInteger(seconds) || seconds<15 || seconds>86400) throw Error('上传间隔请输入 15–86400 秒的整数');
  return seconds;
}
function uploadError(error) {
  const code=error.cause?.code || error.code;
  if(code==='ECONNREFUSED')return '服务器拒绝连接：请检查接收服务已启用，以及服务器/Docker 已开放并映射接收端口（ECONNREFUSED）';
  if(['ETIMEDOUT','UND_ERR_CONNECT_TIMEOUT'].includes(code) || ['AbortError','TimeoutError'].includes(error.name))return '连接超时：请检查服务器地址、防火墙和端口映射';
  if(['ENOTFOUND','EAI_AGAIN'].includes(code))return '服务器域名解析失败：请检查地址或 DNS';
  return String(error.message)+(code ? `（${code}）` : '');
}
class RemotePublisher {
  constructor(data, {now=Date.now}={}) { this.data=data; this.now=now; this.lastAttempt=-Infinity; this.busy=false; this.closed=false; this.timer=setInterval(()=>this.flush(),1000); }
  status(value) { const key=JSON.stringify(value); if(key===this.lastStatus)return; atomic(path.join(this.data,'remote-status.json'),value);this.lastStatus=key; }
  async flush() {
    if(this.busy || this.closed) return;
    this.busy=true;
    try {
      let config; try {config=read(path.join(this.data,'remote-config.json'));} catch(e) {if(e.code!=='ENOENT')throw e;}
      if(!config?.enabled) {this.lastSent=null;this.configKey=null;this.lastAttempt=-Infinity;this.status({enabled:false,error:null});return;}
      if(typeof config.secret!=='string' || config.secret.length<32) throw Error('连接密钥至少需要 32 个字符');
      const url=endpoint(config.address);
      const intervalSeconds=uploadInterval(config);
      const qq=String(config.qq || '').trim();
      if(!/^[1-9][0-9]{4,11}$/.test(qq)) throw Error('请填写接收推送和查询额度的 QQ 号');
      const notifications=notificationSettings(config.notifications);
      const configKey=JSON.stringify([url,config.secret,intervalSeconds,qq,notifications]);
      if(configKey!==this.configKey) {this.configKey=configKey;this.lastAttempt=-Infinity;this.lastSent=null;}
      if(this.now()-this.lastAttempt<intervalSeconds*1000) return;
      let state; try {state=read(path.join(this.data,'state.json'));} catch(e) {if(e.code!=='ENOENT')throw e;}
      if(!state?.checkedAt) {this.status({enabled:true,error:'等待首次额度采集'});return;}
      const identity=url+'|'+config.secret+'|'+state.checkedAt;
      if(identity===this.lastSent) return;
      this.lastAttempt=this.now();
      const body=JSON.stringify(snapshot(state,qq,notifications)), timestamp=String(Math.floor(Date.now()/1000));
      const signature=crypto.createHmac('sha256',config.secret).update(timestamp+'\n'+body).digest('hex');
      this.controller=new AbortController(); const timeout=setTimeout(()=>this.controller?.abort(),10000);
      try {
        const response=await fetch(url,{method:'POST',redirect:'error',headers:{'Content-Type':'application/json','X-Quota-Time':timestamp,'X-Quota-Signature':signature},body,signal:this.controller.signal});
        if(!response.ok) throw Error(`接收端返回 HTTP ${response.status}`);
        const reply=await response.json(); if(reply.ok!==true)throw Error('接收端未确认保存');
        this.lastSent=identity;
        this.status({enabled:true,error:null,lastUploadedAt:new Date().toISOString(),checkedAt:state.checkedAt,intervalSeconds});
      } finally {clearTimeout(timeout);this.controller=null;}
    } catch(e) { if(!this.closed)this.status({enabled:true,error:uploadError(e).slice(0,200),attemptedAt:new Date().toISOString()}); }
    finally {this.busy=false;}
  }
  stop(){this.closed=true;clearInterval(this.timer);this.controller?.abort();}
}
module.exports={RemotePublisher,endpoint,snapshot,uploadInterval,notificationSettings};
