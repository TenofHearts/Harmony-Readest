import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { transform } from 'esbuild';
const source = await readFile('entry/src/main/ets/core/LegalMarkdown.ets', 'utf8');
const compiled = await transform(source, { loader: 'ts', format: 'esm' });
const { legalBlocks, legalSpans } = await import(`data:text/javascript;base64,${Buffer.from(compiled.code).toString('base64')}`);
test('legal documents format headings, lists, inline code and safe external links', () => {
  const blocks = legalBlocks('# Title\n\n## Detail\n\n- **Credit**: [upstream](https://example.org) and `file.ts`\n\n---');
  assert.equal(blocks[0].kind, 'heading'); assert.equal(blocks[0].level, 1);
  assert.equal(blocks[1].level, 2); assert.ok(blocks[2].spans[0].text.startsWith('• '));
  assert.ok(blocks[2].spans.some(s => s.bold && s.text === 'Credit'));
  assert.ok(blocks[2].spans.some(s => s.code && s.text === 'file.ts'));
  assert.ok(blocks[2].spans.some(s => s.url === 'https://example.org'));
  assert.equal(blocks.at(-1).kind, 'rule');
  assert.ok(legalSpans('[unsafe](javascript:alert)').every(s => !s.url));
});
test('actual privacy and notices retain their content and format table rows for narrow screens', async () => {
  const privacy = legalBlocks(await readFile('PRIVACY.md', 'utf8'));
  assert.ok(privacy.filter(b => b.kind === 'heading').length > 8);
  const notices = legalBlocks(await readFile('THIRD_PARTY_NOTICES.md', 'utf8'));
  assert.equal(notices.filter(b => b.kind === 'table').length, 4);
  assert.ok(notices.some(b => b.spans.some(s => s.url === 'https://github.com/readest/readest')));
  const license = await readFile('LICENSE', 'utf8');
  assert.equal(legalBlocks(license).flatMap(b => b.spans.map(s => s.text)).join('\n').replace(/\s/g,''), license.replace(/\s/g,''));
});
test('launcher and ability labels use separate English and Chinese names', async () => {
  for (const [locale, expected] of [['base', 'Attune'], ['zh_CN', '墨契']]) {
    for (const [path, key] of [[`AppScope/resources/${locale}/element/string.json`, 'app_name'], [`entry/src/main/resources/${locale}/element/string.json`, 'EntryAbility_label']]) {
      const data = JSON.parse(await readFile(path, 'utf8')); assert.equal(data.string.find(s => s.name === key).value, expected);
    }
  }
});
