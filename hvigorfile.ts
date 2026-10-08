import { appTasks } from '@ohos/hvigor-ohos-plugin';
import { hvigor } from '@ohos/hvigor';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';

// The DevEco Run button and CLI builds must package the same offline reader assets.
hvigor.taskGraphResolved(() => {
  const tasks = hvigor.getCommandEntryTask() || [];
  if (tasks.length && tasks.every(task => /(?:^|:)(clean|tasks|taskTree|init)$/.test(task))) return;
  const workspace = hvigor.getRootNode().getNodeDir().getPath();
  execFileSync(process.execPath, [join(workspace, 'scripts/build-reader.mjs')], { cwd: workspace, stdio: 'inherit' });
});

export default {
  system: appTasks, /* Built-in plugin of Hvigor. It cannot be modified. */
  plugins: []       /* Custom plugin to extend the functionality of Hvigor. */
}
