const timePattern=/^(?:[01]\d|2[0-3]):[0-5]\d$/;
const idPattern=/^[a-zA-Z0-9_-]{1,80}$/;
function validateConfig(input) {
  if(!input || input.version!==1 || input.timeZone!=='Asia/Shanghai' || !Array.isArray(input.rules))throw new Error('规则文件格式不正确（需要 version=1、Asia/Shanghai 和 rules 列表）。');
  if(input.rules.length>50)throw new Error('最多支持 50 条规则。');
  const ids=new Set();
  const rules=input.rules.map(r=>{
    if(!idPattern.test(r.id || '') || ids.has(r.id))throw new Error('规则 ID 无效或重复。');ids.add(r.id);
    if(typeof r.name!=='string' || !r.name.trim() || r.name.length>80)throw new Error('请填写 1–80 字的规则名称。');
    if(typeof r.enabled!=='boolean')throw new Error('规则启用状态无效。');
    const type=r.type ?? 'daily';
    if(!['daily','quotaReset'].includes(type))throw new Error(`${r.name}：未知规则类型。`);
    const quotaWindow=r.quotaWindow ?? 'any';
    if(!['any','fiveHour','weekly'].includes(quotaWindow))throw new Error(`${r.name}：额度范围无效。`);
    const runLimit=r.runLimit ?? null;
    if(runLimit!==null && (!Number.isInteger(runLimit)||runLimit<1||runLimit>100000))throw new Error(`${r.name}：触发次数必须是 1–100000 的整数。`);
    const activationId=r.activationId ?? 'legacy';
    if(typeof activationId!=='string'||!idPattern.test(activationId))throw new Error(`${r.name}：启用标识无效。`);
    const times=type==='daily'?r.times:[];
    if(type==='daily' && (!Array.isArray(times) || !times.length || times.length>24 || times.some(t=>typeof t!=='string'||!timePattern.test(t))))throw new Error(`${r.name}：时间必须是 HH:mm，每条规则最多 24 个时间。`);
    let existingThreadId=(r.existingThreadId || '').trim();
    const link=existingThreadId.match(/^codex:\/\/threads\/([a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12})\/?$/i);
    if(link)existingThreadId=link[1];
    if(existingThreadId && !/^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/i.test(existingThreadId))throw new Error(`${r.name}：请输入完整本机会话 ID 或 codex://threads/ 会话链接。`);
    existingThreadId=existingThreadId.toLowerCase();
    return {id:r.id,name:r.name.trim(),enabled:r.enabled,type,quotaWindow,runLimit,activationId,times:[...new Set(times)].sort(),existingThreadId};
  });
  return {version:1,timeZone:'Asia/Shanghai',rules};
}
function beijing(now=Date.now()){
  const s=new Date(now+8*3600000).toISOString();
  return {date:s.slice(0,10),time:s.slice(11,16)};
}
function dueJobs(config,state,now=Date.now()){
  const {date,time}=beijing(now);
  return config.rules.filter(r=>r.enabled && (r.type ?? 'daily')==='daily' && r.times.includes(time)).map(rule=>({rule,key:`${rule.id}|${date}|${time}`,scheduledAt:`${date} ${time}`})).filter(job=>!state.runs[job.key] && !state.blocked[job.rule.id]);
}
function nextTime(rule,now=Date.now()){
  if(!rule.enabled || rule.type==='quotaReset')return null;
  const {date}=beijing(now);
  for(let day=0;day<2;day++)for(const time of rule.times){const ms=Date.parse(`${date}T${time}:00+08:00`)+day*86400000;if(ms>now)return new Date(ms).toISOString();}
  return null;
}
function matchesQuota(rule,event){
  if(rule.type!=='quotaReset'||!rule.enabled)return false;
  const duration=event.windowDurationMins;
  return rule.quotaWindow==='fiveHour'?duration===300:rule.quotaWindow==='weekly'?duration===10080:[300,10080].includes(duration);
}
module.exports={validateConfig,beijing,dueJobs,nextTime,matchesQuota};
