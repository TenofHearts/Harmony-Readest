import { copyFile, writeFile } from 'node:fs/promises';

// Use Readest's original raster artwork, without redrawing the icon.
const upstream = 'vendor/readest/apps/readest-app';
for (const directory of ['AppScope/resources/base/media', 'entry/src/main/resources/base/media']) {
  await copyFile(`${upstream}/src-tauri/icons/android/mipmap-xxxhdpi/ic_launcher_foreground.png`, `${directory}/foreground.png`);
  await writeFile(`${directory}/readest_background.svg`, '<svg xmlns="http://www.w3.org/2000/svg" width="432" height="432" viewBox="0 0 432 432"><rect width="432" height="432" fill="#ffffff"/></svg>\n');
  await writeFile(`${directory}/layered_image.json`, JSON.stringify({ 'layered-image': { background: '$media:readest_background', foreground: '$media:foreground' } }, null, 2) + '\n');
}
await copyFile(`${upstream}/public/icon.png`, 'entry/src/main/resources/base/media/startIcon.png');
