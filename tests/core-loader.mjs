import { build } from 'esbuild';
import { readFile } from 'node:fs/promises';
export async function loadCore() {
  const result = await build({ stdin: { contents: `export * from './entry/src/main/ets/core/Models.ets';
    export * from './entry/src/main/ets/core/SyncPolicy.ets'; export * from './entry/src/main/ets/core/KoSyncClient.ets';
    export * from './entry/src/main/ets/core/ProgressCoordinator.ets'; export * from './entry/src/main/ets/core/Errors.ets';
    export * from './entry/src/main/ets/core/Themes.ets'; export * from './entry/src/main/ets/core/ThemePolicy.ets';
    export * from './entry/src/main/ets/core/AppearancePolicy.ets';
    export * from './entry/src/main/ets/core/FontPolicy.ets'; export * from './entry/src/main/ets/core/TypographyPolicy.ets';
    export * from './entry/src/main/ets/core/ReplicaClient.ets';
    export * from './entry/src/main/ets/core/CloudClient.ets'; export * from './entry/src/main/ets/core/CombinedProgress.ets';`, resolveDir: process.cwd() },
    bundle: true, write: false, format: 'esm', platform: 'node',
    resolveExtensions: ['.ets', '.ts', '.js'], plugins: [{ name: 'arkts-core', setup(b) {
      b.onLoad({ filter: /\.ets$/ }, async args => ({ contents: await readFile(args.path, 'utf8'), loader: 'ts' }));
    }}] });
  return import(`data:text/javascript;base64,${Buffer.from(result.outputFiles[0].text).toString('base64')}`);
}
