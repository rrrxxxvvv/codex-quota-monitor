const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),os=require('node:os'),http=require('node:http'),crypto=require('node:crypto');
const {RemotePublisher,endpoint,snapshot}=require('../remote.cjs');
(async()=>{
  assert.equal(endpoint('127.0.0.1:18765'),'http://127.0.0.1:18765/v1/quota');
  assert.throws(()=>endpoint('ftp://example.com')); assert.throws(()=>endpoint('http://user:pass@example.com'));
  const dir=fs.mkdtempSync(path.join(__dirname,'remote-test-'));
  let requests=0,fail=true;
  const secret='x'.repeat(32);
  const server=http.createServer(async(req,res)=>{let body='';for await(const b of req)body+=b;requests++;assert.equal(req.headers['x-quota-signature'],crypto.createHmac('sha256',secret).update(req.headers['x-quota-time']+'\n'+body).digest('hex'));const b=JSON.parse(body);assert(!body.includes('private-account'));assert.equal(b.resetCredits,null);assert.equal(b.qq,"12345678");res.writeHead(fail?503:200,{'Content-Type':'application/json'});res.end(JSON.stringify({ok:!fail}));});
  await new Promise(r=>server.listen(0,'127.0.0.1',r));
  let now=100000; const pub=new RemotePublisher(dir,{now:()=>now});
  try{
    fs.writeFileSync(path.join(dir,'remote-config.json'),JSON.stringify({enabled:true,address:`127.0.0.1:${server.address().port}`,secret,qq:"12345678"}));
    fs.writeFileSync(path.join(dir,'state.json'),JSON.stringify({accountId:'private-account',checkedAt:new Date().toISOString(),currentWindows:{week:{label:'每周',usedPercent:20,windowDurationMins:10080,resetsAt:2000000000}}}));
    await pub.flush();assert.equal(requests,1);assert(JSON.parse(fs.readFileSync(path.join(dir,'remote-status.json'))).error);
    fail=false;await pub.flush();assert.equal(requests,1);now+=60000;await pub.flush();assert.equal(requests,2);assert.equal(JSON.parse(fs.readFileSync(path.join(dir,'remote-status.json'))).error,null);
    await pub.flush();assert.equal(requests,2);
    const stateFile=path.join(dir,'state.json');const changed=JSON.parse(fs.readFileSync(stateFile));changed.checkedAt=new Date(Date.now()+60000).toISOString();fs.writeFileSync(stateFile,JSON.stringify(changed));await pub.flush();assert.equal(requests,2);now+=60000;await pub.flush();assert.equal(requests,3);
    const configFile=path.join(dir,'remote-config.json');const cfg=JSON.parse(fs.readFileSync(configFile));cfg.notifications={weeklyReset:false,expiryDays:[3,1]};fs.writeFileSync(configFile,JSON.stringify(cfg));await pub.flush();assert.equal(requests,4,'settings changes upload the same sample immediately');
    fs.writeFileSync(configFile,JSON.stringify({enabled:false}));await pub.flush();assert.equal(requests,4);
    console.log('PASS: endpoint validation, HMAC, no account credentials, upload retry, dedup and disabled mode');
  }finally{pub.stop();await new Promise(r=>server.close(r));fs.rmSync(dir,{recursive:true,force:true});}
})().catch(e=>{console.error(e);process.exitCode=1;});
