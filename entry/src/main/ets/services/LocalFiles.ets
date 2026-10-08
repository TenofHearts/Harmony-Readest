import { fileIo as fs } from '@kit.CoreFileKit';

// accessSync throws for a missing file. Cleanup must never leave the UI busy
// or replace the original import error with an ENOENT from a second unlink.
export function removeLocalFile(path: string): void {
  if (!path) return;
  try { fs.accessSync(path); } catch { return; }
  fs.unlinkSync(path);
}
