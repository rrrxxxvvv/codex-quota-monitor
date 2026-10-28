// Real installed Codex app-server + isolated state + loopback-only model fixture.
// No real account credentials, inference, or user conversation is used.
const assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),http=require('node:http');
const {Client}=require('../codex-client.cjs');
const {Scheduler,atomic}=require('../scheduler.cjs');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'quota-writer-integration-'));
const clients=[];let calls=0,scheduler;
const server=http.createServer((req,res)=>{
 req.resume();req.on('end',()=>{
  calls++;
  const id='resp_'+calls,item={id:'msg_'+calls,type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:'ok',annotations:[]}]};
  const response={id,object:'response',created_at:Math.floor(Date.now()/1000),status:'completed',model:'local-test',output:[item],usage:{input_tokens:1,output_tokens:1,total_tokens:2}};
  res.writeHead(200,{'Content-Type':'text/event-stream'});
  for(const event of [{type:'response.created',response:{...response,status:'in_progress',output:[]}},{type:'response.output_item.added',output_index:0,item:{...item,status:'in_progress',content:[]}},{type:'response.output_text.delta',item_id:item.id,output_index:0,content_index:0,delta:'ok'},{type:'response.output_item.done',output_index:0,item},{type:'response.completed',response}])res.write('event: '+event.type+'\ndata: '+JSON.stringify(event)+'\n\n');
  res.end();
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
  try{page=await client.request('thread/turns/list',{threadId,sortDirection:'asc',limit:10,itemsView:'full'});}
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
 const rule={id:'writer-test',name:'Local writer test',enabled:true,type:'daily',times:['08:00'],message:'replacement local fixture',existingThreadId:thread.id,runLimit:2,activationId:'test'};
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
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(async()=>{
 scheduler?.stop();await Promise.all(clients.map(close));server.closeAllConnections();server.close();
});
