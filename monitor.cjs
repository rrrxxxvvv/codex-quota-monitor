const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');
const {transition} = require('./quota-core.cjs');
const {Client} = require('./codex-client.cjs');
const {Scheduler} = require('./scheduler.cjs');
const {RemotePublisher} = require('./remote.cjs');
const root = __dirname;
const data = path.join(root, 'data');
fs.mkdirSync(data, {recursive:true});
const remote = new RemotePublisher(data);
const read = file => JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
const atomic = (file, value) => { fs.writeFileSync(file + '.tmp', JSON.stringify(value, null, 2)); fs.renameSync(file + '.tmp', file); };
const stateFile = path.join(data, 'state.json');
const statusFile = path.join(data, 'status.json');
const ackFile = path.join(data, 'ack.json');
let state = null;
try {state = read(stateFile);} catch(e) {if (e.code !== 'ENOENT') fs.copyFileSync(stateFile, stateFile + '.damaged-' + Date.now());}
let client, stopped = false, retryTimer, failures = 0;
let lastError = null, scheduler = null;
function publish(){atomic(statusFile,{running:!stopped,checkedAt:state?.checkedAt,windows:state?.currentWindows || {},resetCredits:state?.resetCredits ?? null,pending:state?.pending || [],error:lastError,failures,intervalSeconds:60});}
function acknowledge() {
  if (!state || !fs.existsSync(ackFile)) return;
  try {
    const ids = new Set(read(ackFile));
    const remaining = state.pending.filter(x=>!ids.has(x.id));
    if(remaining.length !== state.pending.length){state.pending=remaining;atomic(stateFile,state);publish();}
    fs.unlinkSync(ackFile);
  } catch {} // An incomplete UI write is retried next second.
}
async function poll() {
  try {
    if(!client || client.dead){client=new Client();await client.init();}
    const result=await client.request('account/rateLimits/read');
    if(stopped) return;
    acknowledge();
    state=transition(state,result);
    // Persist the rule trigger before advancing the monitoring baseline.
    // Replaying the sample after a crash is safe: the scheduler deduplicates cycles.
    scheduler?.observeQuota(state);
    atomic(stateFile,state); failures=0;lastError=null;publish();remote.flush();
  } catch(e) {
    if(stopped) return;
    failures++;
    lastError=String(e.message).slice(0,400);
    client?.close();client=null;publish();
  }
  if(process.argv.includes('--once')){stop();return;}
  if(!stopped) retryTimer=setTimeout(poll,Math.min(600,60*2**Math.min(failures,4))*1000);
}
function stop(){if(stopped)return;stopped=true;clearTimeout(retryTimer);clearInterval(ackTimer);remote.stop();scheduler?.stop();client?.close();publish();process.exitCode=failures?1:0;process.stdin.destroy();}
const stopFile=path.join(data,'stop-request');
if(fs.existsSync(stopFile))fs.unlinkSync(stopFile);
const ackTimer=setInterval(()=>{acknowledge();if(fs.existsSync(stopFile)){fs.unlinkSync(stopFile);stop();}},1000);
if(!process.argv.includes('--once')) {
  try{scheduler=new Scheduler(data);scheduler.start();}catch(e){atomic(path.join(data,'schedule-status.json'),{running:false,error:e.message,rules:[],logs:[]});}
  const input=readline.createInterface({input:process.stdin});
  input.on('line', line=>{if(line.trim()==='stop')stop();});
  input.on('close',stop); // Stop when the owning UI closes or crashes.
}
process.on('SIGTERM',stop);process.on('SIGINT',stop);
publish();poll();
