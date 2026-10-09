import test from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { readFile } from 'node:fs/promises';
import { loadCore } from './core-loader.mjs';
const core = await loadCore();
const bundled = await build({ entryPoints: ['entry/src/main/ets/services/AppController.ets'], bundle: true, write: false,
  format: 'esm', platform: 'node', resolveExtensions: ['.ets', '.ts', '.js'], plugins: [{ name: 'controller-platform', setup(b) {
    b.onResolve({ filter: /^@kit\./ }, a => ({ path: a.path, namespace: 'platform' }));
    b.onLoad({ filter: /.*/, namespace: 'platform' }, () => ({ contents: `
      export const ConfigurationConstant={ColorMode:{COLOR_MODE_DARK:1}};
      export const hilog={error(){}}; export const i18n={}; export const connection={}; export const picker={}; export const webview={};` }));
    b.onResolve({ filter: /^\.\/(Repository|CredentialVault|NativeTransport|ReaderGateway|FontLibrary|ReplicaService|CloudSyncService|CloudFiles|LocalFiles|BookSharing)$/ },
      a => ({ path: a.path.slice(2), namespace: 'service' }));
    b.onLoad({ filter: /.*/, namespace: 'service' }, a => ({ contents:
      a.path === 'LocalFiles' ? 'export function removeLocalFile(){}' :
      a.path === 'BookSharing' ? 'export async function shareBook(){}' :
      a.path === 'ReaderGateway' ? `export const READER_ORIGIN='https://reader.test'; export class ReaderGateway {}` :
      a.path === 'CloudSyncService' ? `export class CloudSyncService {
        async pull(h){ return globalThis.controllerFixture.cloudPull(h); }
        async push(h,p){ return globalThis.controllerFixture.cloudPush(h,p); }
        async sync(){ globalThis.controllerFixture.librarySyncs++; }
      }` :
      a.path === 'ReplicaService' ? `export class ReplicaService {
        config={userId:'account',enabled:true}; pendingProgress=0;
        async sync(){ if(!this.config.enabled)return; this.pendingProgress=0; await this.cloudSync(this.config);await this.afterSync(); }
        async refreshStorage(){} dispose(){}
      }` :
      a.path === 'NativeTransport' ? 'export class NativeTransport { request(...args){return globalThis.controllerFixture.koRequest(...args)} }' :
      `export class ${a.path} { async save(){} async saveText(){} async clear(){} async deviceId(){return 'test-device'} }` }));
    b.onLoad({ filter: /\.ets$/ }, async a => ({ contents: await readFile(a.path, 'utf8'), loader: 'ts' }));
  }}] });
const { AppController } = await import('data:text/javascript;base64,' + Buffer.from(bundled.outputFiles[0].text).toString('base64'));
function fixture(cloud = true, ko = false) {
  const f = globalThis.controllerFixture = { pulls: 0, pushes: 0, koCalls: [], librarySyncs: 0, offline: false,
    remote: { cfi: 'epubcfi(/6/2)', percentage: .2, timestamp: 1 },
    async cloudPull() { this.pulls++; if(this.offline)throw Error('OFFLINE'); return this.remote; },
    async cloudPush(hash,p) { this.pushes++; if(this.offline)throw Error('OFFLINE'); this.remote={cfi:p.cfi, percentage:p.percentage,timestamp:2}; return this.remote; },
    async koRequest(url, method, headers, body) {
      this.koCalls.push({url,method,headers,body:body && JSON.parse(body)});
      if(this.offline)throw Error('OFFLINE');
      return {status:200,body:JSON.stringify(method==='PUT'?{updated:'OK',timestamp:2}:{progress:'/body/DocFragment[1]/body/p',percentage:.2,timestamp:1})};
    } };
  const app = new AppController({});
  app.replica.config.enabled = cloud;
  app.config.enabled=ko; app.config.userkey=ko?'key':''; app.config.username='reader'; app.config.deviceId='test-device';
  const book = Object.assign(new core.BookRecord(),{ id:'book',hash:'a'.repeat(32),title:'Test book',author:'Author',filename:'book.epub' });
  Object.assign(book.position,{cfi:'epubcfi(/6/2)',xpointer:'/body/DocFragment[1]/body/p',percentage:.2,updatedAt:1000,revision:1});
  app.books=[book]; app.activeBook=book; app.opened=true;
  app.reader={session:'test-session',async inspect(remote){return {cfi:remote.cfi || 'epubcfi(/6/8)',percentage:remote.percentage}},
    async restore(remote){return Object.assign(new core.ReadingPosition(),{cfi:remote.cfi || 'epubcfi(/6/8)',xpointer:remote.progress || '/body/DocFragment[4]/body/p',percentage:remote.percentage})}};
  return {app,f,book};
}

test('Readest-only timer sync never republishes an unchanged local position over another device', async () => {
  const {app,f}=fixture(); await app.sync('reconcile'); f.remote={cfi:'epubcfi(/6/8)',percentage:.8,timestamp:4};
  await app.replica.sync(); assert.equal(f.pushes,0);assert.equal(f.pulls,1);assert.equal(f.koCalls.length,0);
});
test('Readest card Sync now reconciles and preserves a remote conflict instead of uploading', async () => {
  const {app,f}=fixture();await app.sync('reconcile');f.remote={cfi:'epubcfi(/6/8)',percentage:.8,timestamp:4};
  await app.syncNow();assert.equal(app.conflict.cfi,f.remote.cfi);assert.equal(f.pushes,0);assert.equal(app.replica.pendingProgress,1);
  await app.replica.sync();assert.equal(f.pushes,0);
});
test('a failed Readest-only opening check recovers on the next timer sync', async () => {
  const {app,f}=fixture();f.offline=true;await assert.rejects(app.sync('reconcile'),/OFFLINE/);
  f.offline=false;await app.replica.sync();assert.equal(f.pulls,2);assert.equal(app.status,'synced');assert.equal(f.pushes,0);
});
test('network recovery retries an unresolved opening check and still offers a position choice', async () => {
  const {app,f}=fixture();f.offline=true;await assert.rejects(app.sync('reconcile'));
  f.offline=false;f.remote={cfi:'epubcfi(/6/8)',percentage:.8};app.onNetworkAvailable();
  await new Promise(r=>setTimeout(r,10));assert.equal(app.status,'conflict');assert.equal(f.pushes,0);
});
test('KoSync works alone and only uploads a new saved revision', async () => {
  const {app,f,book}=fixture(false,true);await app.sync('reconcile');await app.sync();
  assert.equal(f.koCalls.filter(c=>c.method==='PUT').length,0);assert.equal(f.pulls,0);
  book.position.xpointer='/body/DocFragment[2]/body/p';book.position.cfi='epubcfi(/6/4)';book.position.revision++;book.dirty=true;
  await app.sync();assert.equal(f.koCalls.filter(c=>c.method==='PUT').length,1);assert.equal(book.dirty,false);
});
test('matching Readest progress converges KoSync and Receive only suppresses mirrored sends', async () => {
  const {app,f}=fixture(true,true);await app.sync('reconcile');assert.equal(f.koCalls.filter(c=>c.method==='PUT').length,1);
  await app.updateSyncOptions(true,'Test','receive',true,'X-Gateway: test');
  assert.equal(f.koCalls.filter(c=>c.method==='PUT').length,1);assert.equal(f.pushes,0);
});
test('turning off KoSync preserves pending Readest progress and checks the new provider scope', async () => {
  const {app,book,f}=fixture(true,true);await app.sync('reconcile');
  book.dirty=true;book.position.cfi='epubcfi(/6/4)';book.position.xpointer='/body/DocFragment[2]/body/p';book.position.updatedAt=3000;book.position.percentage=.4;
  await app.updateSyncOptions(false,'Test');assert.equal(book.dirty,true);assert.ok(app.conflict);assert.equal(f.pushes,0);
});

test('KoSync-only recovery retries closed offline edits without bypassing differing remote positions', async () => {
  const {app,f,book}=fixture(false,true);await app.sync('reconcile');
  app.activeBook=undefined;app.opened=false;book.dirty=true;
  f.offline=true;await assert.rejects(app.retryProgress(),/OFFLINE/);assert.equal(book.dirty,true);
  f.offline=false;await app.retryProgress();assert.equal(book.dirty,false);
  assert.equal(f.koCalls.filter(c=>c.method==='PUT').length,1);
  book.dirty=true;book.remoteToken='';book.position.xpointer='/body/DocFragment[2]/body/p';
  await app.syncNow();assert.equal(book.dirty,true);assert.equal(app.koStatus,'pending');
  assert.equal(f.koCalls.filter(c=>c.method==='PUT').length,1);
});

test('closed KoSync retries respect Send only and Receive only across restart', async () => {
  const {app,f,book}=fixture(false,true);app.activeBook=undefined;app.opened=false;book.dirty=true;
  app.config.strategy='receive';await app.retryProgress();assert.equal(f.koCalls.length,0);assert.equal(book.dirty,true);
  app.config.strategy='send';await app.retryProgress();assert.equal(book.dirty,false);
  assert.deepEqual(f.koCalls.map(c=>c.method),['PUT']);
});

test('closed KoSync acknowledgments cannot clear a newer revision or a changed account', async () => {
  const {app,f,book}=fixture(false,true);app.activeBook=undefined;app.opened=false;book.dirty=true;app.config.strategy='send';
  f.koRequest=async()=>{book.position.revision++;return {status:200,body:'{"updated":"OK","timestamp":2}'};};
  await app.retryProgress();assert.equal(book.dirty,true);
  f.koRequest=async()=>{app.config=new core.KoSyncSettings();return {status:200,body:'{"updated":"OK","timestamp":3}'};};
  await app.retryProgress();assert.equal(book.dirty,true);
});
