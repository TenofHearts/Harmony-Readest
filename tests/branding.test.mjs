import assert from 'node:assert/strict';
import test from 'node:test';
import { execFileSync } from 'node:child_process';
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import sharp from 'sharp';

const mediaPaths = ['AppScope/resources/base/media', 'entry/src/main/resources/base/media'];

async function artworkBounds(image) {
  const { data, info } = await sharp(image).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  let left = info.width, right = -1, top = info.height, bottom = -1;
  for (let y = 0; y < info.height; y++) for (let x = 0; x < info.width; x++) {
    if (data[(y * info.width + x) * info.channels + 3] >= 128) {
      left = Math.min(left, x); right = Math.max(right, x);
      top = Math.min(top, y); bottom = Math.max(bottom, y);
    }
  }
  assert.ok(right >= left && bottom >= top, 'Foreground contains visible artwork');
  return [left / info.width, top / info.height, (right + 1) / info.width, (bottom + 1) / info.height];
}

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
    const originalBounds = await artworkBounds('vendor/readest/apps/readest-app/src-tauri/icons/android/mipmap-xxxhdpi/ic_launcher_foreground.png');
    for (const path of mediaPaths) {
      const foreground = await readFile(join(directory, path, 'foreground.png'));
      const metadata = await sharp(foreground).metadata();
      assert.equal(metadata.width, 1024);
      assert.equal(metadata.height, 1024);
      assert.equal(metadata.hasAlpha, true);
      const data = await sharp(foreground).ensureAlpha().raw().toBuffer();
      assert.equal(data[3], 0, 'Foreground corners remain transparent for system masking');
      const bounds = await artworkBounds(foreground);
      for (let edge = 0; edge < bounds.length; edge++) {
        assert.ok(Math.abs(bounds[edge] - originalBounds[edge]) <= 2 / 1024,
          'Original foreground spacing and proportions are preserved within resampling tolerance');
      }
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
