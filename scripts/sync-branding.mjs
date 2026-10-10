import { copyFile, writeFile } from 'node:fs/promises';
import sharp from 'sharp';

// Remove Android's baked-in inset; HarmonyOS applies its own launcher mask.
const upstream = 'vendor/readest/apps/readest-app';
const foreground = await sharp(`${upstream}/src-tauri/icons/android/mipmap-xxxhdpi/ic_launcher_foreground.png`)
  .trim({ threshold: 0 })
  .resize(1024, 1024, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
  .png().toBuffer();
const background = await sharp({ create: { width: 1024, height: 1024, channels: 3, background: '#ffffff' } })
  .png().toBuffer();
for (const directory of ['AppScope/resources/base/media', 'entry/src/main/resources/base/media']) {
  await writeFile(`${directory}/foreground.png`, foreground);
  await writeFile(`${directory}/readest_background.png`, background);
  await writeFile(`${directory}/layered_image.json`, JSON.stringify({ 'layered-image': { background: '$media:readest_background', foreground: '$media:foreground' } }, null, 2) + '\n');
}
await copyFile(`${upstream}/public/icon.png`, 'entry/src/main/resources/base/media/startIcon.png');
