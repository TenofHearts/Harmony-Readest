import test from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
const result = await build({ entryPoints: ['entry/src/main/ets/services/CloudFiles.ets'], bundle: true, write: false,
  format: 'esm', platform: 'node', resolveExtensions: ['.ets', '.ts', '.js'], plugins: [{ name: 'cloud-files', setup(b) {
    b.onResolve({ filter: /^@kit\./ }, args => ({ path: args.path, namespace: 'native' }));
    b.onLoad({ filter: /.*/, namespace: 'native' }, () => ({ contents: `
      import { createHash } from 'node:crypto'; const f = () => globalThis.fileFixture;
      export const cryptoFramework = { createMd() { const md = createHash('md5'); return { async update({data}) { md.update(data); }, async digest() { return {data: new Uint8Array(md.digest())}; } }; } };
      export const fileIo = {
        OpenMode: {READ_ONLY:0, CREATE:1, READ_WRITE:2, TRUNC:4}, WhenceType: {SEEK_SET:0},
        accessSync(path) { if (!f().files.has(path)) throw Error('ENOENT'); return true; },
        openSync(path, mode) { if (mode) f().files.set(path, Buffer.alloc(0)); if (!f().files.has(path)) throw Error('ENOENT');
          const fd = ++f().fd; f().handles.set(fd, {path, offset:0}); return {fd}; },
        closeSync(file) { assertHandle(file.fd); f().handles.delete(file.fd); },
        statSync(path) { return {size:f().files.get(typeof path === 'number' ? f().handles.get(path).path : path).length}; },
        lseek(fd, offset) { f().handles.get(fd).offset = offset; },
        async read(fd, bytes) { const h = f().handles.get(fd), source = f().files.get(h.path);
          const count = Math.min(37, bytes.byteLength, source.length - h.offset); new Uint8Array(bytes).set(source.subarray(h.offset, h.offset+count)); h.offset += count; return count; },
        writeSync(fd, bytes) { const h = f().handles.get(fd); if (f().failWrite) throw Error('DISK_FULL');
          const source = Buffer.from(bytes).subarray(0, 31), old = f().files.get(h.path);
          f().files.set(h.path, Buffer.concat([old.subarray(0,h.offset), source])); h.offset += source.length; return source.length; },
        unlinkSync(path) { f().files.delete(path); }, renameSync(from,to) { f().files.set(to,f().files.get(from)); f().files.delete(from); }
      };
      function assertHandle(fd) { if (!f().handles.has(fd)) throw Error('DOUBLE_CLOSE'); }
      export const http = { RequestMethod:{PUT:'PUT',GET:'GET'}, createHttp() {
        const listeners = {}; return {on(name, fn) {listeners[name]=fn;}, destroy() {},
          async request(url, options) { f().requests.push({url, options}); return {responseCode:200}; },
          async requestInStream(url, options) { f().requests.push({url, options});
            if (f().networkError) throw Error('OFFLINE');
            const bytes = f().incoming; for (let n=0;n<bytes.length;n+=53) { const part = bytes.subarray(n,n+53); listeners.dataReceive(part.buffer.slice(part.byteOffset,part.byteOffset+part.length)); }
            listeners.dataEnd(); return f().status;
          }
        };
      } };
    ` }));
    b.onLoad({ filter: /\.ets$/ }, async args => ({ contents: await readFile(args.path, 'utf8'), loader: 'ts' }));
  }}] });
const { CloudFiles } = await import(`data:text/javascript;base64,${Buffer.from(result.outputFiles[0].text).toString('base64')}`);
function fixture(size=18000) { return globalThis.fileFixture = {files:new Map(), handles:new Map(), fd:0, status:200, requests:[], incoming:Buffer.from(Array.from({length:size},(_,n)=>n%251))}; }
function digest(bytes) {
  const md = createHash('md5'); for (let i=-1;i<=10;i++) { const start=Math.min(bytes.length,1024<<(2*i)); if(start>=bytes.length) break; md.update(bytes.subarray(start,Math.min(start+1024,bytes.length))); } return md.digest('hex');
}
test('streamed EPUB download verifies Readest partial MD5, handles short writes and atomically publishes content', async () => {
  const f=fixture(), files=new CloudFiles(); await files.download('https://objects.test/book','/private/book.epub',digest(f.incoming));
  assert.deepEqual(f.files.get('/private/book.epub'),f.incoming); assert.equal(f.files.has('/private/book.epub.download'),false);
  assert.equal(f.handles.size,0); assert.equal(await files.digest('/private/book.epub'),digest(f.incoming));
  assert.deepEqual(Buffer.from(await files.bytes('/private/book.epub')),f.incoming);
  await files.upload('https://objects.test/upload','/private/book.epub'); assert.ok(f.requests.every(r=>!r.options.header));
});
test('truncated, oversized, corrupt, network and disk failures retain existing content and clean temporary descriptors', async () => {
  for (const reason of ['size','hash','network','write','status']) {
    const f=fixture(100), files=new CloudFiles(); f.files.set('/private/book.epub',Buffer.from('existing'));
    if(reason==='network') f.networkError=true; if(reason==='write') f.failWrite=true; if(reason==='status') f.status=404;
    await assert.rejects(files.download('https://objects.test/book','/private/book.epub',reason==='hash'?'0'.repeat(32):'',reason==='size'?50:1000));
    assert.equal(f.files.get('/private/book.epub').toString(),'existing'); assert.equal(f.files.has('/private/book.epub.download'),false); assert.equal(f.handles.size,0);
  }
});
