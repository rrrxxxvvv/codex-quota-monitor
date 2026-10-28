const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const os=require('node:os');
const {validateConfig,dueJobs,nextTime,beijing}=require('../schedule-core.cjs');
const {transition}=require('../quota-core.cjs');
const {Scheduler,atomic}=require('../scheduler.cjs');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'scheduler-tests-'));
const id='11111111-1111-4111-8111-111111111111';
const rule={id:'morning',name:'每日节奏',enabled:true,times:['08:00','13:00','18:00'],existingThreadId:''};
const config=validateConfig({version:1,timeZone:'Asia/Shanghai',rules:[rule]});
const now=Date.parse('2026-10-27T00:00:05Z');
assert.deepEqual(beijing(now),{date:'2026-10-27',time:'08:00'});
let state={runs:{},blocked:{}};
assert.equal(dueJobs(config,state,now).length,1);
state.runs['morning|2026-10-27|08:00']={};
assert.equal(dueJobs(config,state,now).length,0);
assert.equal(dueJobs(config,state,Date.parse('2026-10-27T05:00:00Z')).length,1);
assert.equal(dueJobs(config,state,now+60000).length,0,'no late catch-up');
assert.equal(nextTime(rule,now),'2026-10-27T05:00:00.000Z');
assert.equal(nextTime({...rule,enabled:false},now),null);
state.blocked.morning={};assert.equal(dueJobs(config,state,Date.parse('2026-10-27T05:00:00Z')).length,0);
assert.throws(()=>validateConfig({...config,rules:[{...rule,times:['25:00']}]}));
assert.throws(()=>validateConfig({...config,rules:[rule,rule]}));
assert.throws(()=>validateConfig({...config,timeZone:'UTC'}));

class FakeClient {
 constructor(server){this.server=server;}
 async init(){}close(){}
 async request(method,p){
  const s=this.server;s.calls.push(method);
  if(s.fail===method)throw new Error('simulated uncertain RPC');
  if(method==='account/rateLimits/read')return {accountId:s.account || 'a',rateLimits:{limitId:'codex',primary:{usedPercent:5,resetsAt:2000000000,windowDurationMins:300}}};
  if(method==='thread/start'){s.created++;s.turns=[];return {thread:{id,historyMode:'paginated'}};}
  if(method==='thread/name/set')return {};
  if(method==='thread/read'||method==='thread/resume'){
   if(s.created && !s.sent)throw new Error('invalid paginated history lineage: missing source rollout');
   return {thread:{id,historyMode:'paginated',status:{type:s.active?'active':'idle'}}};
  }
  if(method==='thread/turns/list'){
   if(s.created && !s.sent)throw new Error('invalid paginated history lineage: missing source rollout');
   return {data:s.turns,nextCursor:null};
  }
  if(method==='thread/revert'){assert.equal(p.beforeTurnId,s.turns[0].id);s.reverts++;s.turns=[];return {thread:{id}};}
  if(method==='turn/start'){assert.equal(s.turns.length,0,'no append to history');s.sent++;s.turns=[{id:'turn-'+s.sent,status:s.longRunning?'inProgress':'completed',items:[{type:'userMessage',content:[{type:'text',text:p.input[0].text}]}]}];return {turn:s.turns[0]};}
  throw new Error('unexpected '+method);
 }
}
function setup(name,server,existing=''){
 const dir=path.join(root,name);fs.mkdirSync(dir);
 const r={...rule,existingThreadId:existing};atomic(path.join(dir,'schedule-rules.json'),{...config,rules:[r]});
 return {scheduler:new Scheduler(dir,{makeClient:()=>new FakeClient(server),inspectActivity:()=>server.diskActive?'active':'idle'}),r,dir};
}
function server(){return {calls:[],turns:[],sent:0,created:0,reverts:0};}
(async()=>{
 const s=server();const {scheduler:q,r,dir}=setup('normal',s);
 assert.equal((await q.execute(r,'first')).status,'success');assert.equal(s.created,1);assert.equal(s.sent,1);
 const bound=q.state.bindings.morning.threadId;
 assert.equal((await q.execute(r,'second')).status,'success');assert.equal(s.created,1);assert.equal(s.reverts,1);assert.equal(s.turns.length,1);assert.equal(q.state.bindings.morning.threadId,bound);
 await q.execute(r,'second');assert.equal(s.sent,2,'same slot never sent twice');q.stop();
 const restored=new Scheduler(dir,{makeClient:()=>new FakeClient(s),inspectActivity:()=>s.diskActive?'active':'idle'});
 await restored.execute(r,'third');assert.equal(s.created,1,'restart preserves binding');assert.equal(s.sent,3);
 s.active=true;assert.equal((await restored.execute(r,'busy')).status,'skipped');assert.equal(s.sent,3,'busy task untouched');s.active=false;
 s.diskActive=true;assert.equal((await restored.execute(r,'disk-busy')).status,'skipped');assert.equal(s.sent,3,'cross-process busy task untouched');s.diskActive=false;
 s.account='b';assert.equal((await restored.execute(r,'switch')).status,'failed');assert.equal(s.sent,3,'different account never sends');restored.stop();
 const u=server();u.fail='turn/start';const uncertain=setup('uncertain',u);assert.equal((await uncertain.scheduler.execute(uncertain.r,'uncertain')).status,'uncertain');assert.ok(uncertain.scheduler.state.blocked.morning);
 await assert.rejects(()=>uncertain.scheduler.execute(uncertain.r,'next'));uncertain.scheduler.stop();
 const restart=new Scheduler(uncertain.dir,{makeClient:()=>new FakeClient(u)});assert.ok(restart.state.blocked.morning);restart.stop();
 const v=server();v.turns=[{id:'old',status:'completed',items:[]}];const existing=setup('existing',v,id);assert.equal((await existing.scheduler.execute(existing.r,'one')).status,'success');assert.equal(v.created,0);assert.equal(v.reverts,1);assert.equal(v.turns.length,1);existing.scheduler.stop();
 const w=server();const interrupted=setup('interrupted',w);interrupted.scheduler.state.runs.crash={ruleId:'morning',at:new Date().toISOString(),status:'running',phase:'creating'};interrupted.scheduler.save();interrupted.scheduler.stop();
 const recovery=new Scheduler(interrupted.dir,{makeClient:()=>new FakeClient(w)});assert.equal(recovery.state.runs.crash.status,'uncertain');assert.ok(recovery.state.blocked.morning);assert.equal(w.created,0);recovery.stop();
 const quotaDir=path.join(root,'quota');fs.mkdirSync(quotaDir);
 let qr={...rule,type:'quotaReset',quotaWindow:'fiveHour',times:[],message:'额度刷新后执行这条自定义消息',runLimit:2,activationId:'quota-v1'};
 atomic(path.join(quotaDir,'schedule-rules.json'),{...config,rules:[qr]});
 const qs=server();let qe=new Scheduler(quotaDir,{makeClient:()=>new FakeClient(qs),inspectActivity:()=> 'idle'});
 const seconds=Math.floor(Date.now()/1000);
 const quotaResult=(primary,secondary)=>({accountId:'a',rateLimits:{limitId:'codex',primary,secondary}});
 const five={usedPercent:100,resetsAt:seconds-1,windowDurationMins:300};
 const week={usedPercent:80,resetsAt:seconds-1,windowDurationMins:10080};
 const baseline=transition(null,quotaResult(five,week));qe.observeQuota(baseline);assert.equal(qe.state.quotaQueue.length,0,'initial sample never fires');
 const refreshed=transition(baseline,quotaResult({...five,usedPercent:10,resetsAt:seconds+18000},{...week,usedPercent:0,resetsAt:seconds+604800}));
 qe.observeQuota(refreshed);assert.equal(qe.state.quotaQueue.length,1);assert.equal(qe.state.quotaQueue[0].events.length,1,'5h filter excludes week');
 qe.observeQuota(refreshed);assert.equal(qe.state.quotaQueue.length,1,'same cycle queued once');
 await qe.tick();assert.equal(qs.sent,1);assert.equal(qe.count(qr),1);assert.equal(qs.turns[0].items[0].content[0].text,qr.message);
 const furtherRecovery=transition(refreshed,quotaResult({...five,usedPercent:0,resetsAt:seconds+18000},{...week,usedPercent:0,resetsAt:seconds+604800}));
 qe.observeQuota(furtherRecovery);assert.equal(qe.state.quotaQueue.length,0,'same-cycle additional recovery does not repeat');
 const nextEvent={...refreshed,changes:refreshed.changes.filter(x=>x.windowDurationMins===300).map(x=>({...x,resetsAt:x.resetsAt+18000,id:x.id+'next'}))};
 qe.observeQuota(nextEvent);await qe.tick();assert.equal(qs.sent,2);assert.ok(qe.exhausted(qr));
 const status=JSON.parse(fs.readFileSync(path.join(quotaDir,'schedule-status.json')));assert.equal(status.rules[0].enabled,false);assert.equal(status.rules[0].autoDisabled,true);
 const thirdEvent={...nextEvent,changes:nextEvent.changes.map(x=>({...x,resetsAt:x.resetsAt+18000}))};
 qe.observeQuota(thirdEvent);await qe.tick();assert.equal(qs.sent,2,'limit prevents further sends');qe.stop();
 qe=new Scheduler(quotaDir,{makeClient:()=>new FakeClient(qs),inspectActivity:()=> 'idle'});assert.ok(qe.exhausted(qr),'limit survives restart');
 qr={...qr,activationId:'quota-v2'};atomic(path.join(quotaDir,'schedule-rules.json'),{...config,rules:[qr]});qe.refresh();assert.equal(qe.count(qr),0,'explicit reactivation starts a new count');qe.stop();
 const anyDir=path.join(root,'quota-any');fs.mkdirSync(anyDir);const anyRule={...qr,quotaWindow:'any',runLimit:null};atomic(path.join(anyDir,'schedule-rules.json'),{...config,rules:[anyRule]});
 const anyServer=server();const anyEngine=new Scheduler(anyDir,{makeClient:()=>new FakeClient(anyServer),inspectActivity:()=> 'idle'});
 anyEngine.observeQuota(refreshed);assert.equal(anyEngine.state.quotaQueue.length,1);assert.equal(anyEngine.state.quotaQueue[0].events.length,2,'simultaneous resets are coalesced');
 await anyEngine.tick();assert.equal(anyServer.sent,1);
 anyEngine.observeQuota(nextEvent);anyEngine.state.quotaQueue[0].detectedAt=Date.now()-601000;await anyEngine.tick();assert.equal(anyServer.sent,1,'expired event is not replayed');anyEngine.stop();
 assert.throws(()=>validateConfig({...config,rules:[{...qr,runLimit:0}]}));
 // Custom text is preserved on first creation, first-turn replacement and quota triggers.
 const cs=server(),custom=setup('custom',cs);
 custom.r.message='分析下面的内容：\n保留换行、空格与标点。  ';
 assert.equal((await custom.scheduler.execute(custom.r,'custom-first')).status,'success');
 assert.equal(cs.turns[0].items[0].content[0].text,custom.r.message);
 custom.r.message='第二条自定义任务';
 await custom.scheduler.execute(custom.r,'custom-edit');
 assert.equal(cs.turns.length,1);assert.equal(cs.reverts,1);
 assert.equal(cs.turns[0].items[0].content[0].text,custom.r.message);custom.scheduler.stop();
 const ls=server();ls.longRunning=true;
 const long=setup('long',ls);long.scheduler.confirmationTimeoutMs=0;
 let closed=0;long.scheduler.makeClient=()=>{const client=new FakeClient(ls);client.close=()=>closed++;return client;};
 const longRun=await long.scheduler.execute({...long.r,message:'长任务'},'long-first');
 assert.equal(longRun.status,'running');assert.equal(closed,0,'keep app-server alive for long task');
 assert.equal((await long.scheduler.execute(long.r,'long-next')).status,'skipped');
 assert.equal(long.scheduler.count(long.r),1,'busy skip does not consume limit');
 await long.scheduler.pollActiveRuns();assert.equal(closed,0);
 ls.turns[0].status='completed';await long.scheduler.pollActiveRuns();
 assert.equal(longRun.status,'success');assert.equal(closed,1);assert.equal(long.scheduler.activeRuns.size,0);long.scheduler.stop();
 const failedServer=server();failedServer.longRunning=true;
 const failing=setup('long-failed',failedServer);failing.scheduler.confirmationTimeoutMs=0;
 const failedRun=await failing.scheduler.execute(failing.r,'failed-first');
 failedServer.turns[0].status='failed';failedServer.turns[0].error={message:'simulated task failure'};
 await failing.scheduler.pollActiveRuns();assert.equal(failedRun.status,'uncertain');assert.ok(failing.scheduler.state.blocked.morning);assert.equal(failing.scheduler.activeRuns.size,0);failing.scheduler.stop();
 const stopServer=server();stopServer.longRunning=true;
 const stopping=setup('long-stop',stopServer);stopping.scheduler.confirmationTimeoutMs=0;
 await stopping.scheduler.execute(stopping.r,'stop-first');stopping.scheduler.stop();
 assert.equal(stopping.scheduler.state.runs['stop-first'].status,'uncertain');assert.ok(stopping.scheduler.state.blocked.morning);
 // The main tick path must execute both new time triggers, not only daily rules.
 for(const type of ['dates','interval']){
   const ts=server(),timed=setup('tick-'+type,ts);const local=beijing();
   const tr={...timed.r,type,message:'日期触发 '+type,times:[],dates:[`${local.date}T${local.time}`],startAt:`${local.date}T${local.time}`,intervalMinutes:60,runLimit:1};
   atomic(path.join(timed.dir,'schedule-rules.json'),{...config,rules:[tr]});
   await timed.scheduler.tick();await timed.scheduler.tick();
   assert.equal(ts.sent,1,type+' trigger through scheduler');assert.equal(ts.turns[0].items[0].content[0].text,tr.message);
   assert.equal(timed.scheduler.count(tr),1);assert.ok(timed.scheduler.exhausted(tr));timed.scheduler.stop();
 }
 console.log('PASS: custom text, first-message replacement, long-task connection lifetime, busy skip, completion, shutdown, dated/interval tick path and once limits.');
 console.log('PASS: Beijing time, daily schedule, invalid inputs, disabled/blocked rules, missed times, deduplication, first creation, fixed binding, first-turn revert, restart, busy task, account switch, uncertain send, existing task, crash recovery.');
 console.log('PASS: quota reset rules, baseline suppression, window filter, cycle deduplication, combined resets, expiry, trigger limits, restart and reactivation.');
})().catch(e=>{console.error(e);process.exitCode=1;});
