import test from 'node:test';
import assert from 'node:assert/strict';
import { loadCore } from './core-loader.mjs';
const {KoSyncClient,KoSyncSettings,ReadingPosition,BookRecord,ProgressCoordinator,CombinedProgress,
  parseCustomHeaders,formatCustomHeaders}=await loadCore();
const hash='a'.repeat(32);
function setup(strategy,remote={progress:'/body/DocFragment[2]/body/p',percentage:.6,timestamp:2}){
  let pulls=0,pushes=0,restores=0,conflicts=0;
  const book=new BookRecord();book.hash=hash;Object.assign(book.position,{cfi:'epubcfi(/6/2)',xpointer:'/body/DocFragment[1]/body/p',percentage:.2,updatedAt:1000,revision:1});book.dirty=true;
  const engine=new ProgressCoordinator({async pull(){pulls++;return remote},async push(){pushes++;return null}},
    {strategy,active:()=>true,deviceId:'',async save(){},status(){},conflict(){conflicts++},
      async inspect(){return {cfi:'epubcfi(/6/4)',percentage:.6}},async restore(r){restores++;return Object.assign(new ReadingPosition(),{cfi:'epubcfi(/6/4)',xpointer:r.progress,percentage:r.percentage})}});
  return {book,engine,result:()=>({pulls,pushes,restores,conflicts})};
}
test('Send only does not pull or restore remote progress',async()=>{
  const {book,engine,result}=setup('send');await engine.sync(book,'reconcile');await engine.sync(book);
  assert.deepEqual(result(),{pulls:0,pushes:1,restores:0,conflicts:0});
});
test('Receive only never uploads while reading or when closing, including missing remote records',async()=>{
  const {book,engine,result}=setup('receive');await engine.sync(book,'reconcile');book.dirty=true;
  await engine.sync(book);await engine.sync(book,'manual-upload');await engine.uploadPending(book,()=>true);assert.equal(result().pushes,0);assert.equal(result().restores,1);
  book.position.xpointer='/body/DocFragment[3]/body/p';await engine.sync(book,'reconcile');assert.equal(result().restores,2);
  const empty=setup('receive',null);await empty.engine.sync(empty.book,'reconcile');assert.equal(empty.result().pushes,0);
});
test('Always use latest follows timestamp order and still prompts on ties or missing timestamps',async()=>{
  const newer=setup('silent');await newer.engine.sync(newer.book,'reconcile');assert.equal(newer.result().restores,1);
  const older=setup('silent',{progress:'/body/DocFragment[2]/body/p',percentage:.6,timestamp:.5});
  await older.engine.sync(older.book,'reconcile');assert.equal(older.result().pushes,1);
  for(const timestamp of [1,undefined]){const tied=setup('silent',{progress:'/body/DocFragment[2]/body/p',percentage:.6,timestamp});await tied.engine.sync(tied.book,'reconcile');assert.equal(tied.result().conflicts,1)}
});
test('KoSync custom gateway headers survive Basic fallback; metadata is opt-in',async()=>{
  const calls=[],config=Object.assign(new KoSyncSettings(),{username:'reader',userkey:'key',basicKey:'basic',customHeaders:parseCustomHeaders('CF-Access-Client-Id: example\nX-Gateway: value')});
  const transport={async request(url,method,headers,body){calls.push({url,method,headers,body:body && JSON.parse(body)});return {status:calls.length===1?401:200,body:'{"updated":"OK"}'}}};
  const position=Object.assign(new ReadingPosition(),{xpointer:'/body/DocFragment[1]/body/p',percentage:.2});
  const client=new KoSyncClient(config,transport,()=>({filename:'book.epub',title:'Book',authors:'Author'}));
  await client.push(hash,position);assert.equal(calls[1].headers.Authorization,'Basic basic');assert.equal(calls[1].headers['X-Gateway'],'value');assert.equal(calls[1].body.metadata,undefined);
  config.sendMetadata=true;await client.push(hash,position);assert.equal(calls[2].body.metadata.title,'Book');
  assert.equal(formatCustomHeaders(parseCustomHeaders('X-Value: one:two')),'X-Value: one:two');
  for(const input of ['Invalid line','Host: other','Authorization: secret','X-Key: a\rInjected: b'])assert.throws(()=>parseCustomHeaders(input),/INVALID_HEADERS/);
});
test('KoSync account creation sends the digest without account auth and verifies the resulting login',async()=>{
  const calls=[],config=Object.assign(new KoSyncSettings(),{username:'reader',userkey:'digest',password:'private-password'});
  const client=new KoSyncClient(config,{async request(url,method,headers,body){calls.push({url,method,headers,body});return {status:200,body:method==='POST'?'{}':'{"authorized":"OK"}'}}});
  await client.register();assert.match(calls[0].url,/\/users\/create$/);assert.deepEqual(JSON.parse(calls[0].body),{username:'reader',password:'digest'});
  assert.equal(calls[0].headers['X-Auth-Key'],undefined);assert.ok(!calls[0].body.includes(config.password));assert.equal(calls.length,2);
});
test('combined sync does not consult a Send-only mirror for missing cloud progress',async()=>{
  const provider=new CombinedProgress({async pull(){return null}}, {async pull(){assert.fail('send-only mirror must not pull')}},'send');
  assert.equal(await provider.pull(hash),null);
});

test('KoSync reports invalid progress and native transport failures through its own status callback',async()=>{
  const config=new KoSyncSettings(),errors=[];
  const client=new KoSyncClient(config,{async request(){return {status:200,body:'{"percentage":2}'}}});
  client.result=error=>errors.push(error);await assert.rejects(client.pull(hash),/INVALID_PROGRESS/);
  assert.deepEqual(errors,['INVALID_PROGRESS']);
  const native=new KoSyncClient(config,{async request(){throw {message:401}}});
  native.result=error=>errors.push(error);await assert.rejects(native.pull(hash));
  assert.equal(errors.at(-1),'OPERATION_FAILED');
});
