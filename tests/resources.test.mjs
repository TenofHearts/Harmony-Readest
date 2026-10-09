import assert from 'node:assert/strict';
import test from 'node:test';
import { execFileSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const locales = ['base', 'zh_CN'];
const resourcePath = locale => `entry/src/main/resources/${locale}/element/string.json`;
const resources = new Map(await Promise.all(locales.map(async locale =>
  [locale, JSON.parse(await readFile(resourcePath(locale), 'utf8')).string])));

test('native literal and conditional UI labels exist in both language packages', async () => {
  const page = await readFile('entry/src/main/ets/pages/Index.ets', 'utf8');
  const keys = new Set([...page.matchAll(/this\.t\('([a-z0-9_]+)'\)/g)].map(match => match[1]));
  // Include both branches: the sign-in loading label is only read after a click.
  for (const call of page.matchAll(/this\.t\(([^)\n]+)\)/g))
    for (const branch of call[1].matchAll(/[?:]\s*'([a-z0-9_]+)'/g)) keys.add(branch[1]);
  const service = await readFile('entry/src/main/ets/services/ReplicaService.ets', 'utf8');
  for (const status of service.matchAll(/(?:this\.)?status(?:: string)?\s*=\s*'([a-z_]+)'/g))
    keys.add(`replica_status_${status[1]}`);
  assert.ok(keys.has('connecting'), 'The sign-in pending state must be checked');
  for (const [locale, entries] of resources) {
    const names = new Set(entries.map(entry => entry.name));
    assert.equal(names.size, entries.length, `${locale}: duplicate resource names`);
    for (const key of keys) assert.ok(names.has(key), `${locale}: missing UI label ${key}`);
    for (const entry of entries) assert.ok(typeof entry.value === 'string' && entry.value.trim(), `${locale}: empty ${entry.name}`);
  }
});

test('resource regeneration preserves the complete font and replica language packages', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'harmonyreadest-resources-'));
  try {
    await mkdir(join(directory, 'AppScope/resources/base/element'), { recursive: true });
    execFileSync(process.execPath, [resolve('scripts/resources.mjs')], { cwd: directory });
    for (const [locale, entries] of resources) {
      const generated = JSON.parse(await readFile(join(directory, resourcePath(locale)), 'utf8')).string;
      const byName = values => Object.fromEntries(values.map(entry => [entry.name, entry.value]));
      assert.deepEqual(byName(generated), byName(entries), `${locale}: generator and shipped package diverge`);
    }
  } finally { await rm(directory, { recursive: true, force: true }); }
});
