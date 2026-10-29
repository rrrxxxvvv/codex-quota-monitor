const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const {Scheduler}=require('../scheduler.cjs');
const {validateConfig}=require('../schedule-core.cjs');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'quota-delivery-'));
const id='11111111-1111-4111-8111-111111111111';
const rule={id:'route',name:'route',enabled:true,type:'daily',times:['08:00'],message:'message',messageAction:'append',existingThreadId:id,deliveryMode:'apiUiRestart',releaseDesktopOnConflict:true};
const turn=(id,text)=>({id,status:'completed',items:[{type:'userMessage',content:[{type:'text',text}]}]});
function setup(options={}){
 const s={locked:true,turns:[turn('old','original')],calls:[],ui:0,released:0,restored:0,...options};
 const q=new Scheduler(path.join(root,String(Math.random())),{inspectActivity:()=>s.busy?'active':'idle',makeClient:()=>({init:async()=>{},close:()=>{s.calls.push('close');},request:async(m,p)=>{
  s.calls.push(m);
  if(m==='account/rateLimits/read')return {accountId:'fixture'};
  if(m==='thread/read')return {thread:{id,historyMode:'paginated',status:{type:'idle'},path:'fixture'}};
  if(m==='thread/start'){s.locked=false;s.turns=[];return {thread:{id}};}
  if(m==='thread/name/set')return {};
  if(m==='thread/resume'){if(s.locked)throw Object.assign(new Error('already has an active writer'),{rpcMethod:m,rpcCode:-32600});return {thread:{status:{type:'idle'}}};}
  if(m==='thread/turns/list'){
   if(s.uiSent&&s.hydrationPending){s.hydrationPending=false;return {data:s.turns.map((t,i)=>i===s.turns.length-1?{...t,items:[]}:t),nextCursor:null};}
   if(s.uiSent&&s.interruptedReads>0){s.interruptedReads--;return {data:s.turns.map((t,i)=>i===s.turns.length-1?{...t,status:'interrupted'}:t),nextCursor:null};}
   return {data:p.sortDirection==='desc'?[...s.turns].reverse().slice(0,p.limit):s.turns,nextCursor:null};
  }
  if(m==='turn/start'){if(s.sendError)throw Error('uncertain transport');const t=turn('api-new',p.input[0].text);s.turns.push(t);return {turn:t};}
  if(m==='thread/revert'){s.turns.pop();return {};}
  throw Error('Unexpected '+m);
 }}),desktopUi:{cancel(){},async send(plan,commit){s.ui++;
  if(s.uiMode==='success'){await commit();if(plan.action==='replaceLast')s.turns.pop();s.turns.push(turn('ui-new',plan.message.replace(/\r\n/g,'\n')+'\n'));s.uiSent=true;return {status:'submitted'};}
  if(s.uiMode==='uncertain'){await commit();return {status:'uncertain',error:'unknown click result'};}
  if(s.uiMode==='draftChanged')return {status:'uncertain',error:'draft changed by user'};
  if(s.uiMode==='protected')return {status:'notSent',error:'existing draft or user input',restartAllowed:false};
  return {status:'notSent',error:'unsupported controls'};
 }},desktopRelease:{async acquire(){s.released++;if(s.releaseError)throw Error('release failed');s.locked=false;return {statusFile:'fixture',async release(){s.restored++;assert.equal(s.calls.at(-1),'close','writer closed before reopening');if(s.restoreError)throw Error('restart failed');}};}}});
 return {s,q};
}
(async()=>{
 for(const action of ['append','replaceLast']){
  const {s,q}=setup({uiMode:'success',locked:false});const r={...rule,deliveryMode:'ui',messageAction:action,replaceLastConfirmed:true};
  const result=await q.execute(r,'direct-ui');assert.equal(result.status,'success',result.message);assert.equal(result.deliveryRoute,'ui');
  assert.equal(s.ui,1);assert.equal(s.released,0);assert.equal(q.count(r),1);assert.ok(!s.calls.includes('thread/resume'));assert.ok(!s.calls.includes('turn/start'));assert.ok(!s.calls.includes('thread/revert'));q.stop();
 }
 for(const mode of ['protected','notSent','uncertain']){
  const {s,q}=setup({uiMode:mode});const r={...rule,deliveryMode:'ui'};const result=await q.execute(r,'direct-ui-failure');
  assert.equal(result.status,mode==='uncertain'?'uncertain':'skipped');assert.equal(s.released,0);assert.ok(!s.calls.includes('thread/resume'));assert.ok(!s.calls.includes('turn/start'));assert.equal(q.count(r),mode==='uncertain'?1:0);q.stop();
 }
 {const {s,q}=setup({uiMode:'success'});const r={...rule,deliveryMode:'ui',existingThreadId:''};
  const first=await q.execute(r,'initialize');assert.equal(first.status,'success',first.message);assert.equal(first.deliveryRoute,'api-initial');assert.equal(s.ui,0);
  const next=await q.execute(r,'bound-ui');assert.equal(next.status,'success',next.message);assert.equal(next.deliveryRoute,'ui');assert.equal(s.ui,1);assert.equal(s.calls.filter(m=>m==='thread/start').length,1);assert.equal(s.calls.filter(m=>m==='turn/start').length,1);assert.ok(!s.calls.includes('thread/resume'));assert.equal(q.count(r),2);q.stop();}
 for(const action of ['append','replaceLast']){
  const {s,q}=setup({uiMode:'success'});const r={...rule,messageAction:action,replaceLastConfirmed:true};
  const result=await q.execute(r,'ui');assert.equal(result.status,'success',result.message);assert.equal(result.deliveryRoute,'ui');assert.equal(s.released,0);assert.equal(s.calls.filter(x=>x==='turn/start').length,0);assert.equal(q.count(r),1);assert.equal(s.turns.length,action==='append'?2:1);q.stop();
 }
 for(const opts of [{},{sendError:true},{restoreError:true}]){
  const {s,q}=setup(opts);const result=await q.execute(rule,'restart');assert.equal(s.ui,1);assert.equal(s.released,1);assert.equal(s.restored,1);assert.equal(q.count(rule),1);assert.equal(result.deliveryRoute,'restart-api');assert.equal(result.status,opts.sendError?'uncertain':'success');if(opts.restoreError)assert.match(result.desktopRestoreError,/restart failed/);q.stop();
 }
 {const {s,q}=setup({uiMode:'success',hydrationPending:true,interruptedReads:3});const r={...rule,message:'line one\r\nline two'};const result=await q.execute(r,'hydration');assert.equal(result.status,'success',result.message);assert.equal(s.ui,1);assert.equal(q.count(r),1);assert.equal(s.released,0);q.stop();}
 for(const mode of ['uncertain','draftChanged']){
  const {s,q}=setup({uiMode:mode});const result=await q.execute(rule,'unknown');assert.equal(result.status,'uncertain');assert.equal(s.released,0);assert.equal(s.calls.filter(x=>x==='turn/start').length,0);assert.equal(q.count(rule),mode==='uncertain'?1:0);q.stop();
 }
 for(const mode of ['api','apiUi']){const {s,q}=setup();const result=await q.execute({...rule,deliveryMode:mode},mode);assert.equal(result.status,'skipped');assert.equal(s.released,0);assert.equal(s.ui,mode==='api'?0:1);q.stop();}
 {const {s,q}=setup({uiMode:'protected'});const result=await q.execute(rule,'protected');assert.equal(result.status,'skipped');assert.equal(s.released,0);assert.equal(q.count(rule),0);q.stop();}
 {const {s,q}=setup({busy:true});assert.equal((await q.execute(rule,'busy')).status,'skipped');assert.equal(s.ui,0);assert.equal(s.released,0);q.stop();}
 {const {s,q}=setup({locked:false,sendError:true});assert.equal((await q.execute(rule,'api-error')).status,'uncertain');assert.equal(s.ui,0);assert.equal(s.released,0);q.stop();}
 {const {s,q}=setup({releaseError:true});assert.equal((await q.execute(rule,'release-error')).status,'failed');assert.equal(q.count(rule),0);q.stop();}
 const config={version:1,timeZone:'Asia/Shanghai',rules:[rule]};assert.equal(validateConfig(config).rules[0].deliveryMode,'apiUiRestart');
 assert.throws(()=>validateConfig({...config,rules:[{...rule,releaseDesktopOnConflict:false}]}));
 assert.throws(()=>validateConfig({...config,rules:[{...rule,deliveryMode:'unknown'}]}));
 assert.equal(validateConfig({...config,rules:[{...rule,deliveryMode:undefined}]}).rules[0].deliveryMode,'api');
 console.log('PASS: API -> UI -> restart fallback; append/edit; no fallback after uncertain submission; no double counting; restore on failure; busy protection; explicit mode and consent.');
})().catch(e=>{console.error(e);process.exitCode=1;});
