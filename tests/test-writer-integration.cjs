// Real installed Codex app-server + isolated state + loopback-only model fixture.
// No real account credentials, inference, or user conversation is used.
const assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),http=require('node:http');
const {Client}=require('../codex-client.cjs');
const {Scheduler,atomic}=require('../scheduler.cjs');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'quota-writer-integration-'));
const clients=[];let calls=0,scheduler,holdNextResponse=false,releaseHeldResponse;
const server=http.createServer((req,res)=>{
 req.resume();req.on('end',()=>{
  calls++;
  const id='resp_'+calls,item={id:'msg_'+calls,type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:'ok',annotations:[]}]};
  const response={id,object:'response',created_at:Math.floor(Date.now()/1000),status:'completed',model:'local-test',output:[item],usage:{input_tokens:1,output_tokens:1,total_tokens:2}};
  const send=()=>{
  res.writeHead(200,{'Content-Type':'text/event-stream'});
  for(const event of [{type:'response.created',response:{...response,status:'in_progress',output:[]}},{type:'response.output_item.added',output_index:0,item:{...item,status:'in_progress',content:[]}},{type:'response.output_text.delta',item_id:item.id,output_index:0,content_index:0,delta:'ok'},{type:'response.output_item.done',output_index:0,item},{type:'response.completed',response}])res.write('event: '+event.type+'\ndata: '+JSON.stringify(event)+'\n\n');
  res.end();
  };
  if(holdNextResponse){holdNextResponse=false;releaseHeldResponse=send;}else send();
 });
});
async function close(client){
 if(client.proc.exitCode!==null||client.proc.signalCode!==null)return;
 const exited=new Promise(resolve=>client.proc.once('exit',resolve));client.close();await exited;
}
async function waitTurn(client,threadId,turnId){
 const deadline=Date.now()+20000;
 while(Date.now()<deadline){
  let page;
  try{page=await client.request('thread/turns/list',{threadId,sortDirection:'desc',limit:50,itemsView:'full'});}
  catch(e){if(e.rpcCode!==-32601)throw e;}
  const turn=page?.data.find(x=>x.id===turnId);
  if(turn&&turn.status!=='inProgress'){assert.equal(turn.status,'completed',JSON.stringify(turn.error));return;}
  await new Promise(r=>setTimeout(r,250));
 }
 throw new Error('Local fixture turn did not finish');
}
(async()=>{
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 fs.writeFileSync(path.join(root,'config.toml'),`model = "local-test"\nmodel_provider = "local_test"\n[model_providers.local_test]\nname = "Local test"\nbase_url = "http://127.0.0.1:${server.address().port}/v1"\nwire_api = "responses"\nrequires_openai_auth = false\n`);
 const env={...process.env,CODEX_HOME:root};delete env.OPENAI_API_KEY;delete env.CODEX_API_KEY;
 function makeClient(){
  const c=new Client({env});clients.push(c);
  const request=c.request.bind(c);
  c.request=(method,...args)=>method==='account/rateLimits/read'?Promise.resolve({accountId:'local-fixture',rateLimits:{limitId:'codex',primary:{usedPercent:1,resetsAt:2000000000,windowDurationMins:300}}}):request(method,...args);
  return c;
 }
 const owner=makeClient();await owner.init();
 const thread=(await owner.request('thread/start',{cwd:root,ephemeral:false,sandbox:'read-only',approvalPolicy:'never'})).thread;
 const first=(await owner.request('turn/start',{threadId:thread.id,input:[{type:'text',text:'original local fixture'}]})).turn;
 await waitTurn(owner,thread.id,first.id);
 const data=path.join(root,'monitor-data');fs.mkdirSync(data);
 const rule={id:'writer-test',name:'Local writer test',enabled:true,type:'daily',times:['08:00'],message:'replacement local fixture',existingThreadId:thread.id,runLimit:2,activationId:'test',messageAction:'replaceLast',replaceLastConfirmed:true};
 atomic(path.join(data,'schedule-rules.json'),{version:1,timeZone:'Asia/Shanghai',rules:[rule]});
 scheduler=new Scheduler(data,{makeClient});
 const skipped=await scheduler.execute(rule,'locked');
 assert.equal(skipped.status,'skipped');assert.equal(skipped.reason,'active-writer');
 assert.equal(skipped.error.rpcMethod,'thread/resume');assert.match(skipped.error.message,/already has an active writer/);
 assert.equal(scheduler.count(rule),0);assert.equal(scheduler.state.blocked[rule.id],undefined);assert.equal(calls,1,'no inference while locked');
 const untouched=await owner.request('thread/turns/list',{threadId:thread.id,sortDirection:'asc',limit:10,itemsView:'full'});
 assert.equal(untouched.data.length,1);assert.equal(untouched.data[0].id,first.id,'history untouched');
 console.log('PASS: real idle owner -> active-writer error on resume -> skip without history edits, message, count or disabling.');
 await close(owner);
 const success=await scheduler.execute(rule,'released');
 assert.equal(success.status,'success',success.message);assert.equal(success.threadId,thread.id);assert.equal(scheduler.count(rule),1);assert.equal(calls,2);
 await close(clients[clients.length-1]);
 const repeated=await scheduler.execute(rule,'repeat');
 assert.equal(repeated.status,'success',repeated.message);assert.equal(repeated.threadId,thread.id);assert.equal(scheduler.count(rule),2);assert.equal(calls,3);
 await close(clients[clients.length-1]);
 const reader=makeClient();await reader.init();
 const final=await reader.request('thread/turns/list',{threadId:thread.id,sortDirection:'asc',limit:10,itemsView:'full'});
 assert.equal(final.data.length,1);assert.equal(final.nextCursor,null);
 const users=final.data[0].items.filter(x=>x.type==='userMessage');
 assert.equal(users.length,1);assert.equal(users[0].content.filter(x=>x.type==='text').map(x=>x.text).join(''),rule.message);
 assert.ok(scheduler.exhausted(rule));
 console.log('PASS: release owner -> actual resume/revert/resend twice in fixed thread -> one current turn -> count limit. Local model requests only.');

 // Keep another client running an unrelated task in the SAME Codex home.
 // Listing/reading the monitored thread must not acquire its writer.
 const other=makeClient();await other.init();
 const unrelated=(await other.request('thread/start',{cwd:root,ephemeral:false,sandbox:'read-only',approvalPolicy:'never'})).thread;
 holdNextResponse=true;
 const unrelatedTurn=(await other.request('turn/start',{threadId:unrelated.id,input:[{type:'text',text:'unrelated held local fixture'}]})).turn;
 const heldDeadline=Date.now()+15000;
 while(!releaseHeldResponse&&Date.now()<heldDeadline)await new Promise(r=>setTimeout(r,100));
 assert.ok(releaseHeldResponse,'unrelated task is waiting for its local model response');
 const baseline=calls;
 const coexist={...rule,id:'coexist-test',name:'Coexist test',existingThreadId:null,runLimit:3};
 const created=await scheduler.execute(coexist,'coexist-created');
 assert.equal(created.status,'success',created.message);
 const boundId=created.threadId;
 await close(clients[clients.length-1]);
 for(let i=0;i<2;i++){
  await other.request('thread/list',{limit:100,modelProviders:[]});
  await other.request('thread/read',{threadId:boundId,includeTurns:false});
  await other.request('thread/turns/list',{threadId:boundId,sortDirection:'asc',limit:10,itemsView:'full'});
  const loaded=await other.request('thread/loaded/list',{});
  assert.ok(loaded.data.includes(unrelated.id),'other client still owns its own task');
  assert.ok(!loaded.data.includes(boundId),'read/list do not load the monitored task');
  const resent=await scheduler.execute(coexist,'coexist-repeat-'+i);
  assert.equal(resent.status,'success',resent.message);assert.equal(resent.threadId,boundId);
  await close(clients[clients.length-1]);
  const history=await other.request('thread/turns/list',{threadId:boundId,sortDirection:'asc',limit:10,itemsView:'full'});
  assert.equal(history.data.length,1);assert.equal(history.nextCursor,null);
  assert.equal(history.data[0].items.filter(x=>x.type==='userMessage').length,1);
  const stillActive=await other.request('thread/read',{threadId:unrelated.id,includeTurns:false});
  assert.equal(stillActive.thread.status.type,'active','unrelated task was not stopped');
 }
 assert.equal(scheduler.count(coexist),3);assert.equal(calls,baseline+3);
 releaseHeldResponse();releaseHeldResponse=null;
 await waitTurn(other,unrelated.id,unrelatedTurn.id);
 console.log('PASS: another client continuously running an unrelated task in the same home -> create and bind once -> read/list target -> resend twice in fixed thread, one turn, count 3; unrelated task completes normally.');

 // Merely switching focus / unsubscribing is not immediate writer release.
 await other.request('thread/resume',{threadId:boundId,excludeTurns:true});
 const unsubscribed=await other.request('thread/unsubscribe',{threadId:boundId});
 assert.equal(unsubscribed.status,'unsubscribed');
 const afterUnsubscribe={...coexist,id:'unsubscribe-test',existingThreadId:boundId};
 const retained=await scheduler.execute(afterUnsubscribe,'unsubscribe-retained');
 assert.equal(retained.status,'skipped');assert.equal(retained.reason,'active-writer');
 assert.equal(scheduler.count(afterUnsubscribe),0);assert.equal(calls,baseline+3);
 await close(other);
 const releasedAgain=await scheduler.execute(afterUnsubscribe,'unsubscribe-released');
 assert.equal(releasedAgain.status,'success',releasedAgain.message);assert.equal(releasedAgain.threadId,boundId);
 console.log('PASS: resume then unsubscribe retains writer immediately -> safe skip; owner exit releases it -> same target succeeds.');
 await close(clients[clients.length-1]);
 const seed=makeClient();await seed.init();await seed.request('thread/resume',{threadId:boundId,excludeTurns:true});
 for(let i=0;i<12;i++){
  const turn=(await seed.request('turn/start',{threadId:boundId,input:[{type:'text',text:'preserved history '+i}]})).turn;
  await waitTurn(seed,boundId,turn.id);
 }
 const beforeAppend=await seed.request('thread/turns/list',{threadId:boundId,sortDirection:'asc',limit:50,itemsView:'full'});
 assert.equal(beforeAppend.data.length,13);await close(seed);
 const appendRule={...rule,id:'append-test',existingThreadId:boundId,messageAction:'append',replaceLastConfirmed:false,message:'continue local fixture'};
 for(let i=0;i<2;i++){
  const appended=await scheduler.execute(appendRule,'append-'+i);
  assert.equal(appended.status,'success',appended.message);assert.equal(appended.threadId,boundId);assert.equal(appended.backup,undefined);
  await close(clients[clients.length-1]);
 }
 const afterAppend=await reader.request('thread/turns/list',{threadId:boundId,sortDirection:'asc',limit:50,itemsView:'full'});
 assert.equal(afterAppend.data.length,15);
 assert.deepEqual(afterAppend.data.slice(0,13),beforeAppend.data,'all 13 original turns preserved byte-for-byte as returned');
 for(const turn of afterAppend.data.slice(13))assert.equal(turn.items.find(x=>x.type==='userMessage').content.filter(x=>x.type==='text').map(x=>x.text).join(''),appendRule.message);
 assert.equal(scheduler.count(appendRule),2);
 console.log('PASS: append twice to a real 13-turn task -> all 13 original turns unchanged, 15 total turns, same thread ID, count 2, no history revert.');
 const replaceRule={...appendRule,id:'replace-last-test',messageAction:'replaceLast',replaceLastConfirmed:true,message:'edited final local fixture'};
 for(let i=0;i<2;i++){
  const replaced=await scheduler.execute(replaceRule,'replace-last-'+i);
  assert.equal(replaced.status,'success',replaced.message);assert.equal(replaced.threadId,boundId);assert.ok(replaced.backup);
  await close(clients[clients.length-1]);
  const afterEdit=await reader.request('thread/turns/list',{threadId:boundId,sortDirection:'asc',limit:50,itemsView:'full'});
  assert.equal(afterEdit.data.length,15);
  assert.deepEqual(afterEdit.data.slice(0,14),afterAppend.data.slice(0,14),'editing the final message never reverts earlier turns');
  assert.equal(afterEdit.data.at(-1).items.find(x=>x.type==='userMessage').content.filter(x=>x.type==='text').map(x=>x.text).join(''),replaceRule.message);
 }
 console.log('PASS: edit final user message twice in the real 15-turn task -> preceding 14 turns unchanged, same thread, last turn only replaced.');
 // Exercise the full scheduler against a real competing app-server. UI failure
 // and desktop lifecycle are injected; the writer acquisition and turn are real.
 const conflictOwner=makeClient();await conflictOwner.init();await conflictOwner.request('thread/resume',{threadId:boundId,excludeTurns:true});
 let uiAttempts=0,releaseAttempts=0,restored=false;
 scheduler.desktopUi={cancel(){},async send(){uiAttempts++;return {status:'notSent',error:'fixture unsupported UI'};}};
 scheduler.desktopRelease={async acquire(){releaseAttempts++;await close(conflictOwner);return {statusFile:'fixture',async release(){
   const reopened=makeClient();await reopened.init();
   await reopened.request('thread/resume',{threadId:boundId,excludeTurns:true});restored=true;await close(reopened);
 }}}};
 const fallback={...appendRule,id:'fallback-test',deliveryMode:'apiUiRestart',releaseDesktopOnConflict:true};
 const fallbackResult=await scheduler.execute(fallback,'fallback');
 assert.equal(fallbackResult.status,'success',fallbackResult.message);assert.equal(fallbackResult.deliveryRoute,'restart-api');
 assert.equal(uiAttempts,1);assert.equal(releaseAttempts,1);assert.ok(restored);assert.equal(scheduler.count(fallback),1);
 const afterFallback=await reader.request('thread/turns/list',{threadId:boundId,sortDirection:'asc',limit:50,itemsView:'full'});
 assert.equal(afterFallback.data.length,16);assert.deepEqual(afterFallback.data.slice(0,14),afterAppend.data.slice(0,14));
 console.log('PASS: full fallback scheduler with real conflicting writer -> simulated unsupported UI -> owner exit -> API append -> new owner resumes after monitor closes. Desktop shutdown itself is not exercised.');
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(async()=>{
 releaseHeldResponse?.();
 scheduler?.stop();await Promise.all(clients.map(close));server.closeAllConnections();server.close();
});
