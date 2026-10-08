import test from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { readFile } from 'node:fs/promises';

const result = await build({
  entryPoints: ['entry/src/main/ets/services/ReaderGateway.ets'], bundle: true, write: false,
  format: 'esm', platform: 'node', resolveExtensions: ['.ets', '.ts', '.js'],
  plugins: [{ name: 'gateway-fixture', setup(b) {
    b.onResolve({ filter: /^@kit\./ }, args => ({ path: args.path, namespace: 'kit' }));
    b.onLoad({ filter: /.*/, namespace: 'kit' }, () => ({ contents: `
      export const util = { generateRandomUUID: () => 'session' };
      export const fileIo = {
        OpenMode: { READ_ONLY: 0 },
        openSync() { const f = globalThis.gatewayFixture; f.opens++; f.offset = 0; return {fd: 42}; },
        statSync() { return {size: globalThis.gatewayFixture.bytes.length}; },
        async read(fd, buffer, options) {
          const f = globalThis.gatewayFixture;
          const bytes = f.bytes.subarray(f.offset, f.offset + options.length);
          new Uint8Array(buffer).set(bytes); f.offset += bytes.length; return bytes.length;
        },
        closeSync() { const f = globalThis.gatewayFixture; if (++f.closes > f.opens) throw Error('Bad file descriptor'); }
      };
    ` }));
    b.onLoad({ filter: /\.ets$/ }, async args => ({ contents: await readFile(args.path, 'utf8'), loader: 'ts' }));
  }}]
});
const { ReaderGateway, READER_ORIGIN } = await import(`data:text/javascript;base64,${Buffer.from(result.outputFiles[0].text).toString('base64')}`);
globalThis.WebResourceResponse = class {
  constructor() { this.done = new Promise(resolve => this.resolve = resolve); }
  setResponseEncoding() {} setReasonMessage() {} setResponseMimeType() {}
  setResponseCode(code) { this.code = code; }
  setResponseData(data) { this.data = data; }
  setResponseIsReady(ready) {
    if (!ready) this.pending = true;
    if (ready && this.pending) this.resolve();
  }
};

test('EPUB binary response owns and closes its file once; cancelling cannot double-close it', async () => {
  const bytes = Uint8Array.from({ length: 600000 }, (_, i) => i % 251);
  globalThis.gatewayFixture = { bytes, opens: 0, closes: 0 };
  const gateway = new ReaderGateway({}, { async runJavaScript() {} });
  await gateway.open({ id: 'book', path: '/private/book.epub', position: {} }, true);
  const response = gateway.resource(`${READER_ORIGIN}/books/book.epub`);
  await response.done;
  assert.equal(response.code, 200); assert.ok(response.data instanceof ArrayBuffer);
  assert.deepEqual(new Uint8Array(response.data), bytes);
  gateway.cancel(); gateway.cancel();
  assert.equal(gatewayFixture.opens, 1); assert.equal(gatewayFixture.closes, 1);
  assert.equal(gateway.resource(`${READER_ORIGIN}/books/book.epub`).code, 404);
  assert.equal(gateway.resource('https://example.com/tracker').code, 404);
});
