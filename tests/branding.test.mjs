import assert from 'node:assert/strict';
import test from 'node:test';
import { execFileSync } from 'node:child_process';
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import sharp from 'sharp';

const mediaPaths = ['AppScope/resources/base/media', 'entry/src/main/resources/base/media'];

test('branding regeneration replaces legacy icon dimensions in both launcher resource scopes', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'harmonyreadest-branding-'));
  try {
    for (const resource of ['src-tauri/icons/android/mipmap-xxxhdpi/ic_launcher_foreground.png', 'public/icon.png']) {
      const source = `vendor/readest/apps/readest-app/${resource}`;
      await mkdir(dirname(join(directory, source)), { recursive: true });
      await copyFile(source, join(directory, source));
    }
    for (const path of mediaPaths) {
      await mkdir(join(directory, path), { recursive: true });
      await writeFile(join(directory, path, 'foreground.png'), 'stale icon');
      await writeFile(join(directory, path, 'readest_background.png'), 'stale background');
    }
    execFileSync(process.execPath, [resolve('scripts/sync-branding.mjs')], { cwd: directory });
    for (const path of mediaPaths) {
      const foreground = await readFile(join(directory, path, 'foreground.png'));
      const metadata = await sharp(foreground).metadata();
      assert.equal(metadata.width, 1024);
      assert.equal(metadata.height, 1024);
      assert.equal(metadata.hasAlpha, true);
      const { data, info } = await sharp(foreground).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
      assert.equal(data[3], 0, 'Foreground corners remain transparent for system masking');
      let left = info.width, right = -1;
      for (let y = 0; y < info.height; y++) for (let x = 0; x < info.width; x++) {
        if (data[(y * info.width + x) * info.channels + 3] > 0) {
          left = Math.min(left, x); right = Math.max(right, x);
        }
      }
      assert.ok(left <= 3, 'Android outer padding is removed, allowing for resampling at the edge');
      assert.ok(right >= 1020, 'Artwork uses the full layer width without distortion');
      const background = await sharp(join(directory, path, 'readest_background.png')).metadata();
      assert.equal(background.width, 1024);
      assert.equal(background.height, 1024);
      const pixels = await sharp(join(directory, path, 'readest_background.png')).raw().toBuffer();
      assert.ok(pixels.every(value => value === 255), 'Background is opaque white with no rounded cutout');
      const layers = JSON.parse(await readFile(join(directory, path, 'layered_image.json'), 'utf8'));
      assert.deepEqual(layers['layered-image'], { background: '$media:readest_background', foreground: '$media:foreground' });
    }
    assert.deepEqual(await readFile(join(directory, mediaPaths[0], 'foreground.png')),
      await readFile(join(directory, mediaPaths[1], 'foreground.png')));
    assert.deepEqual(await readFile(join(directory, mediaPaths[1], 'startIcon.png')),
      await readFile('vendor/readest/apps/readest-app/public/icon.png'));
  } finally { await rm(directory, { recursive: true, force: true }); }
});
