import { copyFile, writeFile } from 'node:fs/promises';
import sharp from 'sharp';

// Use the Attune artwork for launcher, splash and About; system owns masking.
const artwork = 'assets/branding/attune-book-icon.png';
const foreground = await sharp(artwork)
  .resize(1024, 1024, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
  .png().toBuffer();
const background = await sharp({ create: { width: 1024, height: 1024, channels: 3, background: '#ffffff' } })
  .png().toBuffer();
for (const directory of ['AppScope/resources/base/media', 'entry/src/main/resources/base/media']) {
  await writeFile(`${directory}/foreground.png`, foreground);
  await writeFile(`${directory}/readest_background.png`, background);
  await writeFile(`${directory}/layered_image.json`, JSON.stringify({ 'layered-image': { background: '$media:readest_background', foreground: '$media:foreground' } }, null, 2) + '\n');
}
const inAppArtwork = await sharp('assets/branding/attune-book-transparent.png').resize(1024, 1024).png().toBuffer();
await writeFile('entry/src/main/resources/base/media/startIcon.png', inAppArtwork);

// The Readest Cloud provider retains Readest's original service branding.
await copyFile(new URL('../vendor/readest/apps/readest-app/public/icon.png', import.meta.url), 'entry/src/main/resources/base/media/readest_service.png');
