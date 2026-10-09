import test from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { readFile } from 'node:fs/promises';

// Use real AES-GCM and the platform's missing-key semantics around the real vault.
const result = await build({
  entryPoints: ['entry/src/main/ets/services/CredentialVault.ets'], bundle: true, write: false,
  format: 'esm', platform: 'node', resolveExtensions: ['.ets', '.ts', '.js'],
  plugins: [{ name: 'credential-fixture', setup(b) {
    b.onResolve({ filter: /^@kit\./ }, args => ({ path: args.path, namespace: 'kit' }));
    b.onLoad({ filter: /.*/, namespace: 'kit' }, () => ({ contents: `
      import { randomBytes, createCipheriv, createDecipheriv, createHash } from 'node:crypto';
      export const preferences = { async getPreferences() { return globalThis.vaultFixture.prefs; } };
      export const util = {
        Base64Helper: class {
          encodeToStringSync(value) { return Buffer.from(value).toString('base64'); }
          decodeSync(value) { return new Uint8Array(Buffer.from(value, 'base64')); }
        },
        TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value); } },
        TextDecoder: { create() { return { decodeToString(value) { return new TextDecoder().decode(value); } }; } }
      };
      export const cryptoFramework = {
        createRandom() { return { generateRandomSync(n) { return { data: randomBytes(n) }; } }; },
        createMd() { const hash = createHash('md5'); return {
          async update(value) { hash.update(value.data); }, async digest() { return { data: hash.digest() }; }
        }; }
      };
      const tags = { HUKS_TAG_ALGORITHM: 1, HUKS_TAG_KEY_SIZE: 2, HUKS_TAG_PURPOSE: 3,
        HUKS_TAG_BLOCK_MODE: 4, HUKS_TAG_PADDING: 5, HUKS_TAG_NONCE: 6, HUKS_TAG_AE_TAG: 7 };
      const parameter = (options, tag) => options.properties.find(p => p.tag === tag)?.value;
      export const huks = {
        HuksTag: tags, HuksKeyAlg: { HUKS_ALG_AES: 1 }, HuksKeySize: { HUKS_AES_KEY_SIZE_256: 256 },
        HuksCipherMode: { HUKS_MODE_GCM: 1 }, HuksKeyPadding: { HUKS_PADDING_NONE: 0 },
        HuksKeyPurpose: { HUKS_KEY_PURPOSE_ENCRYPT: 1, HUKS_KEY_PURPOSE_DECRYPT: 2 },
        async isKeyItemExist() { throw { code: 12000011, message: -13 }; },
        async hasKeyItem(alias) { if (globalThis.vaultFixture.error) throw globalThis.vaultFixture.error; return globalThis.vaultFixture.keys.has(alias); },
        async generateKeyItem(alias) { const f = globalThis.vaultFixture; f.generated++; f.keys.set(alias, randomBytes(32)); },
        async initSession(alias, options) { return { handle: { alias, options } }; },
        async finishSession(handle, options) {
          const nonce = parameter(options, tags.HUKS_TAG_NONCE), key = globalThis.vaultFixture.keys.get(handle.alias);
          const decrypt = parameter(options, tags.HUKS_TAG_PURPOSE) === 2;
          const cipher = decrypt ? createDecipheriv('aes-256-gcm', key, nonce) : createCipheriv('aes-256-gcm', key, nonce);
          if (decrypt) cipher.setAuthTag(parameter(options, tags.HUKS_TAG_AE_TAG));
          const output = Buffer.concat([cipher.update(options.inData), cipher.final()]);
          return { outData: new Uint8Array(decrypt ? output : Buffer.concat([output, cipher.getAuthTag()])) };
        },
        async abortSession() {}
      };
    ` }));
    b.onLoad({ filter: /\.ets$/ }, async args => ({ contents: await readFile(args.path, 'utf8'), loader: 'ts' }));
  }}]
});
const { CredentialVault } = await import(`data:text/javascript;base64,${Buffer.from(result.outputFiles[0].text).toString('base64')}`);

function fixture() {
  const data = new Map();
  globalThis.vaultFixture = { keys: new Map(), generated: 0, data, prefs: {
    async get(key, fallback) { return data.get(key) ?? fallback; },
    async put(key, value) { data.set(key, value); }, async delete(key) { data.delete(key); }, async flush() {}
  } };
  return globalThis.vaultFixture;
}

test('first credential save creates the missing key; encrypted Unicode credentials reload and updates reuse the key', async () => {
  const f = fixture(), vault = new CredentialVault('test-key', 'test-prefs'); await vault.init({});
  const settings = { username: '测试-reader', password: '密码-🔐', serverUrl: 'https://sync.example' };
  await vault.prepare(settings); await vault.save(settings); assert.equal(f.generated, 1);
  assert.ok(!f.data.get('sealed').includes(settings.password));
  const migrated = value => ({ ...value, strategy: 'prompt', customHeaders: {}, sendMetadata: false, lastSyncedAt: 0 });
  assert.deepEqual(await vault.load(), migrated(settings));
  settings.password = 'updated'; await vault.prepare(settings); await vault.save(settings);
  assert.equal(f.generated, 1); assert.deepEqual(await vault.load(), migrated(settings));
  const sealed = JSON.parse(f.data.get('sealed')); const bytes = Buffer.from(sealed.ciphertext, 'base64'); bytes[0] ^= 1;
  sealed.ciphertext = bytes.toString('base64'); f.data.set('sealed', JSON.stringify(sealed));
  await assert.rejects(vault.load());
});

test('a key-store failure cannot replace saved credentials or silently generate a new key', async () => {
  const f = fixture(), vault = new CredentialVault(); await vault.init({});
  f.data.set('sealed', 'existing'); f.error = { code: 12000005, message: 'IPC failed' };
  await assert.rejects(vault.save({ password: 'test' }));
  assert.equal(f.generated, 0); assert.equal(f.data.get('sealed'), 'existing');
});

test('Readest tokens use a separate encrypted vault and clearing them cannot change KoSync credentials', async () => {
  const f = fixture(), ko = new CredentialVault('kosync-key', 'kosync-prefs'); await ko.init({});
  const credentials = { username: 'fixture-user', password: 'fixture-password' }; await ko.save(credentials);
  const koCipher = f.data.get('sealed'), replicaData = new Map();
  f.prefs = { async get(key, fallback) { return replicaData.get(key) ?? fallback; }, async put(key, value) { replicaData.set(key, value); },
    async delete(key) { replicaData.delete(key); }, async flush() {} };
  const replica = new CredentialVault('replica-key', 'replica-prefs'); await replica.init({});
  const session = JSON.stringify({ accessToken: 'fixture-access-token', refreshToken: 'fixture-refresh-token', cursor: 'saved-cursor' });
  await replica.saveText(session); assert.equal(await replica.loadText(), session);
  assert.ok(!replicaData.get('sealed').includes('fixture-access-token')); assert.equal(f.keys.size, 2);
  await replica.clear(); assert.equal(await replica.loadText(), '');
  assert.equal(f.data.get('sealed'), koCipher); assert.deepEqual(await ko.load(), { ...credentials, strategy: 'prompt', customHeaders: {}, sendMetadata: false, lastSyncedAt: 0 });
});
