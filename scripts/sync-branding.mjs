import { writeFile } from 'node:fs/promises';
import sharp from 'sharp';

// Use the HReadest artwork for launcher, splash and About; system owns masking.
const artwork = 'assets/branding/hreadest-icon.png';
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
await writeFile('entry/src/main/resources/base/media/startIcon.png', foreground);
