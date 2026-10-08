import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { loadCore } from './core-loader.mjs';
const { KoSyncClient, KoSyncSettings, ReadingPosition } = await loadCore();

test('two clients exchange exact locators through a KoSync-compatible HTTP server', async () => {
  const records = new Map();
  const server = createServer(async (req, res) => {
    res.setHeader('Content-Type', 'application/json');
    if (req.headers['x-auth-user'] !== 'test' || req.headers['x-auth-key'] !== 'key') {
      res.writeHead(401); res.end('{}'); return;
    }
    if (req.url === '/users/auth') { res.end('{"authorized":"OK"}'); return; }
    if (req.method === 'PUT' && req.url === '/syncs/progress') {
      let body = ''; for await (const chunk of req) body += chunk;
      const record = JSON.parse(body); records.set(record.document, { ...record, timestamp: Date.now() / 1000 });
      res.end('{"updated":"OK"}'); return;
    }
    const record = records.get(req.url.slice('/syncs/progress/'.length));
    if (!record) { res.writeHead(404); res.end('{}'); return; }
    // Match the official server's response, which need not echo "document".
    const { document, ...reply } = record; res.end(JSON.stringify(reply));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  // Tests replace TLS transport only. Production endpoints still require verified HTTPS.
  const transport = { async request(url, method, headers, body) {
    const response = await fetch(`${origin}${new URL(url).pathname}`, { method, headers, body });
    return { status: response.status, body: await response.text() };
  } };
  try {
    const settings = new KoSyncSettings(); settings.serverUrl = 'https://test.invalid'; settings.username = 'test'; settings.userkey = 'key';
    const a = new KoSyncClient(settings, transport), b = new KoSyncClient(settings, transport);
    await a.authenticate(); await b.authenticate();
    const hash = '0123456789abcdef0123456789abcdef'; assert.equal(await a.pull(hash), null);
    const position = new ReadingPosition(); position.xpointer = '/body/DocFragment[2]/body/p/text().12'; position.percentage = .25;
    await a.push(hash, position); assert.equal((await b.pull(hash)).progress, position.xpointer);
    position.xpointer = '/body/DocFragment[3]/body/p/text().24'; position.percentage = .45;
    await b.push(hash, position); const reply = await a.pull(hash);
    assert.equal(reply.progress, position.xpointer); assert.equal(reply.percentage, .45); assert.ok(reply.timestamp);
  } finally { await new Promise(resolve => server.close(resolve)); }
});
