const fs=require('node:fs');
const path=require('node:path');
const {randomUUID}=require('node:crypto');
const {Client}=require('./codex-client.cjs');
const {windowsFrom}=require('./quota-core.cjs');
const {validateConfig,dueJobs,nextTime,beijing,matchesQuota}=require('./schedule-core.cjs');
const {inspectActivity}=require('./thread-activity.cjs');
const read=file=>JSON.parse(fs.readFileSync(file,'utf8').replace(/^\uFEFF/,''));
function atomic(file,value){
  fs.writeFileSync(file+'.tmp',JSON.stringify(value,null,2));
  // Windows readers/scanners may briefly deny replacement. Never remove the
  // last durable state; retry only transient sharing/permission errors.
  for(let attempt=0;;attempt++){
    try{fs.renameSync(file+'.tmp',file);return;}
    catch(e){
      if(attempt>=5 || !['EPERM','EACCES','EBUSY'].includes(e.code))throw e;
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,10*2**attempt);
    }
  }
}

class Scheduler {
  constructor(data,options={}){
    this.data=data;this.makeClient=options.makeClient || (()=>new Client());this.inspectActivity=options.inspectActivity || inspectActivity;
    this.confirmationTimeoutMs=options.confirmationTimeoutMs ?? 10000;
    this.activeRuns=new Map();
    fs.mkdirSync(data,{recursive:true});
    this.configFile=path.join(data,'schedule-rules.json');
    this.stateFile=path.join(data,'schedule-state.json');
    this.statusFile=path.join(data,'schedule-status.json');
    this.commandDir=path.join(data,'schedule-commands');fs.mkdirSync(this.commandDir,{recursive:true});
    this.config={version:1,timeZone:'Asia/Shanghai',rules:[]};
    if(!fs.existsSync(this.configFile))atomic(this.configFile,this.config);
    this.state={version:1,bindings:{},runs:{},blocked:{},logs:[]};
    if(fs.existsSync(this.stateFile)) {
      try{this.state=read(this.stateFile);if(!this.state.bindings||!this.state.runs||!this.state.blocked||!Array.isArray(this.state.logs))throw new Error('invalid');}
      catch{throw new Error('定时执行状态损坏。已停止定时发送；请保留 schedule-state.json 排查，不能自动重建绑定。');}
    }
    for(const run of Object.values(this.state.runs))if(run.status==='running'){
      run.status='uncertain';run.message='上次执行中断，结果待核对；不会自动重发。';
      this.state.blocked[run.ruleId]={message:run.message,phase:run.phase,at:new Date().toISOString()};
    }
    this.state.quotaQueue ||= [];
    this.state.quotaHandled ||= {};
    this.state.triggerCounts ||= {};
    this.busy=false;this.stopped=false;this.error=null;this.lastTick=Date.now();this.client=null;
    this.save();this.refresh();this.publish();
  }
  save(){atomic(this.stateFile,this.state);}
  log(ruleId,message,level='info'){
    this.state.logs.push({at:new Date().toISOString(),ruleId,message,level});
    this.state.logs=this.state.logs.slice(-150);this.save();
  }
  refresh(){try{this.config=validateConfig(read(this.configFile));this.error=null;}catch(e){this.error=e.message;}}
  count(rule){const record=this.state.triggerCounts[rule.id];return record?.activationId===(rule.activationId ?? 'legacy')?record.count:0;}
  exhausted(rule){return rule.runLimit!=null && this.count(rule)>=rule.runLimit;}
  observeQuota(snapshot){
    this.refresh();
    if(this.error || !snapshot.accountId || !snapshot.changes?.length)return;
    for(const rule of this.config.rules){
      if(this.state.blocked[rule.id] || this.exhausted(rule))continue;
      const matches=snapshot.changes.filter(event=>matchesQuota(rule,event) && event.remaining>0);
      const fresh=matches.filter(event=>!this.state.quotaHandled[`${rule.id}|${snapshot.accountId}|${event.windowKey}|${event.resetsAt}`]);
      if(!fresh.length)continue;
      // Mark each quota cycle before enqueueing. Notification dismissal has no effect.
      for(const event of fresh)this.state.quotaHandled[`${rule.id}|${snapshot.accountId}|${event.windowKey}|${event.resetsAt}`]=Date.now();
      const key=`quota|${rule.id}|${snapshot.accountId}|${fresh.map(x=>`${x.windowKey}:${x.resetsAt}`).sort().join(',')}`;
      this.state.quotaQueue.push({key,ruleId:rule.id,accountId:snapshot.accountId,detectedAt:Date.now(),events:fresh});
      this.state.logs.push({at:new Date().toISOString(),ruleId:rule.id,level:'info',message:`已检测额度刷新，等待执行：${fresh.map(x=>x.label).join('、')}`});
    }
    this.state.logs=this.state.logs.slice(-150);this.save();this.publish();
  }
  publish(){atomic(this.statusFile,{running:!this.stopped,busy:this.busy||this.activeRuns.size>0,error:this.error,checkedAt:new Date().toISOString(),rules:this.config.rules.map(r=>({...r,enabled:r.enabled && !this.exhausted(r) && !this.state.blocked[r.id],autoDisabled:this.exhausted(r),triggerCount:this.count(r),binding:this.state.bindings[r.id] || null,blocked:this.state.blocked[r.id] || null,nextAt:this.exhausted(r)||this.state.blocked[r.id]?null:nextTime(r),lastRun:Object.values(this.state.runs).filter(x=>x.ruleId===r.id).sort((a,b)=>b.at.localeCompare(a.at))[0] || null})),logs:this.state.logs.slice(-50)});}
  async pollActiveRuns(){
    for(const [ruleId,active] of this.activeRuns){
      if(active.checking)continue;
      active.checking=true;
      const {client,run}=active;
      try{
        const page=await this.submittedTurns(client,run);
        if(this.stopped)return;
        const turn=page.data.find(t=>t.id===run.turnId);
        if(!turn)throw new Error('无法找到已发送的任务，请检查会话；不会自动重发。');
        if(turn.status==='inProgress')continue;
        if(turn.status!=='completed')throw new Error(`任务结束状态为 ${turn.status}：${turn.error?.message || '请检查会话'}`);
        run.status='success';run.phase='complete';run.message='自定义消息对应的任务已完成。';
        this.log(ruleId,run.message);
      }catch(e){
        if(this.stopped)return;
        run.status='uncertain';run.message=e.message;
        this.state.blocked[ruleId]={message:e.message,phase:run.phase,at:new Date().toISOString()};this.log(ruleId,e.message,'error');
      }finally{
        active.checking=false;
        if(run.status!=='running'){client.close();this.activeRuns.delete(ruleId);this.save();this.publish();}
      }
    }
  }
  phase(run,phase){run.phase=phase;this.save();this.publish();}
  async submittedTurns(client,run,allowPending=false){
    let page;
    try{page=await client.request('thread/turns/list',{threadId:run.threadId,sortDirection:'asc',limit:3,itemsView:'full'});}
    catch(e){
      // A newly accepted turn can precede creation of its paginated history.
      if(allowPending && e.rpcCode===-32601 && /paginated_threads is not supported yet/.test(e.message))return {data:[],nextCursor:null};
      throw e;
    }
    const turn=page.data.find(t=>t.id===run.turnId);
    if(turn?.status==='interrupted'){
      // The persisted snapshot can briefly lag behind the owning live runtime.
      // Keep the connection alive while that runtime is still executing.
      const metadata=await client.request('thread/read',{threadId:run.threadId,includeTurns:false});
      if(metadata.thread.status.type==='active')return {...page,data:page.data.map(t=>t.id===run.turnId?{...t,status:'inProgress'}:t)};
    }
    return page;
  }
  async allTurns(client,threadId){
    let cursor=null,turns=[];
    do{
      const page=await client.request('thread/turns/list',{threadId,sortDirection:'asc',limit:50,itemsView:'full',cursor});
      turns.push(...page.data);cursor=page.nextCursor;
      if(turns.length>1000)throw new Error('指定会话历史过长，请选择专用计时会话。');
    }while(cursor);
    return turns;
  }
  async execute(rule,key,scheduledAt='手动执行',triggerAccountId=null){
    if(this.busy || this.stopped)return;
    if(this.state.runs[key])return;
    if(this.exhausted(rule))return;
    if(this.state.blocked[rule.id])throw new Error('该规则存在待核对的异常，需先处理。');
    this.busy=true;
    const run={ruleId:rule.id,at:new Date().toISOString(),scheduledAt,status:'running',phase:'checking',threadId:null,message:'正在检查账号与会话'};
    this.state.runs[key]=run;this.save();this.publish();
    if(this.activeRuns.has(rule.id)){
      run.status='skipped';run.message='此规则的上次任务仍在执行，本次跳过。';this.log(rule.id,run.message);this.busy=false;this.publish();return run;
    }
    const client=this.makeClient();this.client=client;
    let mutationAttempted=false;
    try{
      await client.init();
      const before=await client.request('account/rateLimits/read');
      if(!before.accountId)throw new Error('未能确认当前登录账号。');
      if(triggerAccountId && triggerAccountId!==before.accountId)throw new Error('额度刷新事件所属账号与当前账号不同，本次没有发送消息。');
      run.before=windowsFrom(before);
      let binding=this.state.bindings[rule.id];
      if(binding && binding.accountId!==before.accountId)throw new Error('当前登录账号与绑定账号不同；请切回原账号或新建规则。');
      if(binding && rule.existingThreadId && binding.threadId!==rule.existingThreadId)throw new Error('已绑定会话与填写的 ID 不同；请新建规则，避免修改原绑定。');
      if(!binding && rule.existingThreadId){
        // Validate first, then pin the supplied ID. Never silently create a replacement.
        const found=await client.request('thread/read',{threadId:rule.existingThreadId,includeTurns:false});
        if(found.thread.historyMode!=='paginated')throw new Error('此旧格式会话不支持编辑首条重发，请改用新的专用工作会话。');
        binding={threadId:rule.existingThreadId,accountId:before.accountId,createdByMonitor:false};
        this.state.bindings[rule.id]=binding;this.save();
      }
      let created=false;
      if(!binding){
        const cwd=path.join(this.data,'greeting-session');fs.mkdirSync(cwd,{recursive:true});
        this.phase(run,'creating');mutationAttempted=true;
        const result=await client.request('thread/start',{cwd,ephemeral:false,sandbox:'read-only',approvalPolicy:'never'});
        binding={threadId:result.thread.id,accountId:before.accountId,createdByMonitor:true};
        this.state.bindings[rule.id]=binding;run.threadId=binding.threadId;created=true;this.save();
        await client.request('thread/name/set',{threadId:binding.threadId,name:rule.name});
      }
      run.threadId=binding.threadId;
      // A brand-new thread has no source rollout until its first turn starts.
      // Reading/resuming it here fails on current Codex versions.
      // Existing threads still require all activity/history checks before revert.
      if(!created){
      this.phase(run,'checking-thread');
      const metadata=await client.request('thread/read',{threadId:binding.threadId,includeTurns:false});
      if(metadata.thread.historyMode!=='paginated')throw new Error('此会话不支持官方编辑重发接口。');
      if(metadata.thread.status.type==='active'){
        run.status='skipped';run.message='会话正在执行任务，本次跳过，没有中断或追加消息。';this.log(rule.id,run.message);return run;
      }
      if(!created){
        const activity=this.inspectActivity(metadata.thread.path);
        if(activity==='active'){
          run.status='skipped';run.message='会话的最新记录仍有未结束任务，本次跳过，没有编辑消息。';this.log(rule.id,run.message);return run;
        }
        if(activity==='unknown')throw new Error('无法可靠确认会话空闲，已停止本次执行。');
      }
      this.phase(run,'resuming-thread');
      const resumed=await client.request('thread/resume',{threadId:binding.threadId,excludeTurns:true});
      if(resumed.thread.status.type==='active'){
        run.status='skipped';run.message='会话正在执行任务，本次跳过。';this.log(rule.id,run.message);return run;
      }
      const turns=await this.allTurns(client,binding.threadId);
      if(turns.some(t=>t.status==='inProgress')){
        run.status='skipped';run.message='会话有尚未结束的消息，本次跳过。';this.log(rule.id,run.message);return run;
      }
      if(turns.length){
        const current=await client.request('thread/read',{threadId:binding.threadId,includeTurns:false});
        if(current.thread.status.type==='active'||this.inspectActivity(current.thread.path)!=='idle'){
          run.status='skipped';run.message='编辑前检测到任务忙碌或状态未确认，本次跳过。';this.log(rule.id,run.message);return run;
        }
        const backupDir=path.join(this.data,'history-backups');fs.mkdirSync(backupDir,{recursive:true});
        const backup=path.join(backupDir,`${binding.threadId}-${Date.now()}.json`);
        atomic(backup,{threadId:binding.threadId,at:new Date().toISOString(),turns});run.backup=backup;
        this.phase(run,'reverting');mutationAttempted=true;
        await client.request('thread/revert',{threadId:binding.threadId,beforeTurnId:turns[0].id});
        const empty=await client.request('thread/turns/list',{threadId:binding.threadId,sortDirection:'asc',limit:1,itemsView:'summary'});
        if(empty.data.length)throw new Error('回退后历史未清空，已停止发送，避免累积上下文。');
      }
      }
      this.phase(run,'sending');mutationAttempted=true;
      // Reserve a trigger before submitting. An uncertain transport result cannot
      // exceed the user's maximum by retrying after restart.
      this.state.triggerCounts[rule.id]={activationId:rule.activationId ?? 'legacy',count:this.count(rule)+1};
      run.triggerNumber=this.count(rule);this.save();
      const message=rule.message ?? '你好';
      const response=await client.request('turn/start',{threadId:binding.threadId,clientUserMessageId:randomUUID(),input:[{type:'text',text:message}]});
      run.turnId=response.turn.id;this.phase(run,'waiting');
      let completed=null;
      const deadline=Date.now()+this.confirmationTimeoutMs;
      while(!this.stopped && Date.now()<deadline){
        const page=await this.submittedTurns(client,run,true);
        const turn=page.data.find(t=>t.id===run.turnId);
        if(turn && turn.status!=='inProgress'){completed=turn;break;}
        await new Promise(resolve=>setTimeout(resolve,1000));
      }
      if(completed && completed.status!=='completed')throw new Error(`消息已提交但状态为 ${completed.status}：${completed.error?.message || '请检查会话'}`);
      const final=await this.submittedTurns(client,run);
      const users=final.data.flatMap(t=>t.items).filter(i=>i.type==='userMessage');
      if(final.data.length!==1 || final.nextCursor || final.data[0].id!==run.turnId || users.length!==1 || users[0].content.filter(x=>x.type==='text').map(x=>x.text).join('')!==message)throw new Error('发送后会话历史与预期不符，请核对；已暂停该规则。');
      const currentTurn=final.data[0];
      if(!['completed','inProgress'].includes(currentTurn.status))throw new Error(`消息已提交但状态为 ${currentTurn.status}：${currentTurn.error?.message || '请检查会话'}`);
      run.status='success';run.phase='complete';run.message=created?'已创建并绑定专用会话，自定义消息发送成功。':'已在原会话编辑首条并重发自定义消息；当前历史只有一轮。';
      if(currentTurn.status==='inProgress'){
        run.status='running';run.phase='waiting';run.message+='任务仍在运行，后续触发会先检查是否空闲。';
        this.activeRuns.set(rule.id,{client,run,checking:false});
      }
      try{run.after=windowsFrom(await client.request('account/rateLimits/read'));}catch(e){run.quotaError='消息已完成，但额度读取失败：'+e.message;}
      run.message+=' 计时是否变化以接口返回的重置时间为准。';
      this.log(rule.id,run.message);
    }catch(e){
      run.error={message:e.message,rpcMethod:e.rpcMethod ?? null,rpcCode:e.rpcCode ?? null};
      if(!mutationAttempted && run.phase==='resuming-thread' && e.rpcMethod==='thread/resume' && /already has an active writer\b/i.test(e.message)){
        run.status='skipped';run.reason='active-writer';
        run.message='此会话的写入连接仍被另一个 Codex 客户端持有。本次跳过，未修改历史、未发送消息，不计次数；规则保持启用。桌面端可继续使用其他会话；已打开过此会话时，仅切走或重新勾选规则不会立即释放占用，请等待占用客户端释放后再等下次触发。';
        this.log(rule.id,run.message,'warning');return run;
      }
      run.status=mutationAttempted?'uncertain':'failed';run.message=e.message;
      this.state.blocked[rule.id]={message:e.message,phase:run.phase,at:new Date().toISOString()};
      this.log(rule.id,e.message,'error');
    }finally{
      this.save();if(!this.activeRuns.has(rule.id))client.close();this.client=null;this.busy=false;this.publish();
    }
    return run;
  }
  async processCommands(){
    for(const file of fs.readdirSync(this.commandDir).filter(x=>x.endsWith('.json')).sort()){
      const full=path.join(this.commandDir,file);let command;
      try{command=read(full);}catch{continue;}
      // Claim on disk before taking action; a crash must not replay the command.
      fs.renameSync(full,full+'.claimed');
      try{
        const rule=this.config.rules.find(x=>x.id===command.ruleId);
        if(!rule)throw new Error('规则不存在，请先保存。');
        if(command.type==='runNow')await this.execute(rule,`manual|${file}`);
        else if(command.type==='unblock'){
          const blocked=this.state.blocked[rule.id];
          if(blocked?.phase==='creating' && !this.state.bindings[rule.id] && !rule.existingThreadId)throw new Error('上次创建结果未知；请先把已创建会话的 ID 填入规则后保存，避免重复新建。');
          delete this.state.blocked[rule.id];this.log(rule.id,'已解除异常暂停。已记录的执行时刻不会补发。');
        }else throw new Error('未知操作。');
      }catch(e){this.log(command.ruleId,e.message,'error');}
      fs.unlinkSync(full+'.claimed');
    }
  }
  async tick(now=Date.now()){
    if(this.busy || this.stopped)return;
    this.refresh();
    if(this.error){this.publish();return;}
    // A sleep/restart never catches up a backlog. Only the current minute is eligible.
    if(now-this.lastTick>90000)this.log(null,'检测到运行间隔或电脑休眠；过去的定时时刻不补发。');
    this.lastTick=now;
    await this.processCommands();
    while(this.state.quotaQueue.length && !this.stopped){
      const job=this.state.quotaQueue[0];
      this.refresh();if(this.error)break;
      const rule=this.config.rules.find(x=>x.id===job.ruleId);
      const relevant=rule && job.events.some(event=>matchesQuota(rule,event));
      if(!relevant || this.exhausted(rule) || this.state.blocked[job.ruleId] || Date.now()-job.detectedAt>600000){
        this.log(job.ruleId,'额度刷新事件未执行：规则已停用、异常暂停、条件已变更或事件超过 10 分钟。');
      }else if(!this.state.runs[job.key]){
        await this.execute(rule,job.key,`额度刷新：${job.events.map(x=>x.label).join('、')}`,job.accountId);
      }
      this.state.quotaQueue.shift();this.save();
    }
    for(const job of dueJobs(this.config,this.state,Date.now())){
      this.refresh();
      const freshRule=dueJobs(this.config,this.state,Date.now()).find(x=>x.key===job.key)?.rule;
      if(this.error || !freshRule || this.exhausted(freshRule))continue;
      if(job.scheduledAt!==`${beijing().date} ${beijing().time}`){this.log(job.rule.id,'等待其他规则期间已错过该时刻，本次不补发。');continue;}
      await this.execute(freshRule,job.key,job.scheduledAt);
    }
    const cutoff=new Date(Date.now()-35*86400000).toISOString();
    for(const [key,run] of Object.entries(this.state.runs))if(run.at<cutoff && run.status!=='running')delete this.state.runs[key];
    for(const [key,at] of Object.entries(this.state.quotaHandled))if(at<Date.now()-35*86400000)delete this.state.quotaHandled[key];
    this.save();this.publish();
  }
  start(){this.timer=setInterval(()=>{this.pollActiveRuns().catch(e=>{this.error=e.message;this.publish();});this.tick().catch(e=>{this.error=e.message;this.publish();});},5000);this.tick().catch(e=>{this.error=e.message;this.publish();});}
  stop(){
    this.stopped=true;clearInterval(this.timer);this.client?.close();
    for(const [ruleId,{client,run}] of this.activeRuns){
      run.status='uncertain';run.message='监控退出时任务尚未确认完成，请检查会话；不会自动重发。';
      this.state.blocked[ruleId]={message:run.message,phase:run.phase,at:new Date().toISOString()};client.close();
    }
    this.activeRuns.clear();this.save();this.publish();
  }
}
module.exports={Scheduler,atomic};
