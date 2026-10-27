const fs=require('node:fs');

// A separate app-server reports persisted in-flight turns as "interrupted".
// Read only lifecycle markers from the exact rollout path returned by Codex.
// Never edit rollout files or infer idleness from a stale API status alone.
function inspectActivity(file){
  if(!file) return 'unknown';
  const size=fs.statSync(file).size;
  if(size>64*1024*1024)throw new Error('会话记录过大，无法可靠核对忙碌状态；请绑定专用计时会话。');
  const text=fs.readFileSync(file,'utf8');
  const lines=text.split('\n');let activity='empty';
  for(let i=0;i<lines.length;i++){
    if(!lines[i].trim())continue;
    let record;
    try{record=JSON.parse(lines[i]);}catch{return 'unknown';}
    if(record.type!=='event_msg')continue;
    const type=record.payload?.type;
    if(type==='task_started')activity='active';
    if(type==='task_complete'||type==='turn_aborted')activity='idle';
  }
  return activity;
}
module.exports={inspectActivity};
