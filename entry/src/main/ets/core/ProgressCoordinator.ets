import { BookRecord, ProgressSyncProvider, ReadingPosition, RemoteProgress } from './Models';
import { canAcknowledge, decideSync, remoteToken, uploadedToken } from './SyncPolicy';

export interface SyncHooks {
  save: (book: BookRecord) => Promise<void>;
  restore: (remote: RemoteProgress) => Promise<ReadingPosition>;
  inspect: (remote: RemoteProgress) => Promise<ReadingPosition>;
  deviceId: string;
  active: () => boolean;
  status: (value: string) => void;
  conflict: (remote: RemoteProgress, preview?: ReadingPosition) => void;
}

// Native and web rendering details stay outside this coordinator.
export class ProgressCoordinator {
  private queue: Promise<void> = Promise.resolve();
  private provider: ProgressSyncProvider;
  private hooks: SyncHooks;
  private reconciled: boolean = false;
  private awaitingChoice: boolean = false;
  private pendingRemote?: RemoteProgress;
  constructor(provider: ProgressSyncProvider, hooks: SyncHooks) { this.provider = provider; this.hooks = hooks; }

  sync(book: BookRecord, mode: string = 'upload'): Promise<void> {
    const task = this.queue.then(() => this.run(book, mode));
    this.queue = task.catch(() => {});
    return task;
  }

  // Continue an already reconciled upload after the renderer session closes.
  // Unresolved choices and newer revisions retain the same protection as reading uploads.
  uploadPending(book: BookRecord, active: () => boolean): Promise<void> {
    const task = this.queue.then(async () => {
      if (!this.reconciled || this.awaitingChoice || !book.dirty || !book.hash || !active()) return;
      const snapshot = JSON.parse(JSON.stringify(book.position)) as ReadingPosition;
      const ack = await this.provider.push(book.hash, snapshot);
      if (!active()) return;
      book.remoteToken = ack?.timestamp ? remoteToken(ack) : uploadedToken(snapshot.xpointer, snapshot.percentage, ack?.device_id || '');
      if (canAcknowledge(snapshot.revision, book.position.revision)) book.dirty = false;
      await this.hooks.save(book);
    });
    this.queue = task.catch(() => {}); return task;
  }

  private async run(book: BookRecord, mode: string): Promise<void> {
    if (!this.hooks.active() || !book.hash) return;
    if (mode === 'upload' && (!this.reconciled || this.awaitingChoice)) return;
    if (mode === 'reconcile') this.reconciled = false;
    this.hooks.status('checking');
    try {
      // Only opening a book/app reconciles with remote. Reading and reconnecting
      // publish this device's resume position without fetching another position.
      const choosing = mode === 'keep-local' || mode === 'use-remote';
      const remote = choosing ? this.pendingRemote || null : mode === 'reconcile' ? await this.provider.pull(book.hash) : null;
      if (!this.hooks.active()) return;
      if (choosing && !remote) return;
      let decision = mode === 'upload' || mode === 'manual-upload' || mode === 'keep-local' ? 'push' :
        mode === 'use-remote' ? 'pull' : decideSync(book, remote);
      if (decision === 'conflict' && remote) {
        let preview: ReadingPosition | undefined;
        let differs = true;
        const sameDevice = !!this.hooks.deviceId && remote.device_id === this.hooks.deviceId;
        if (sameDevice && remote.percentage !== undefined) {
          differs = Math.abs(book.position.percentage - remote.percentage) > 0.01;
        } else {
          try {
            preview = await this.hooks.inspect(remote);
            differs = preview.cfi !== book.position.cfi && Math.abs(book.position.percentage - preview.percentage) > 0.0001;
          } catch { differs = true; }
        }
        if (!this.hooks.active()) return;
        if (differs) {
          this.awaitingChoice = true; this.reconciled = false; this.pendingRemote = remote;
          this.hooks.status('conflict'); this.hooks.conflict(remote, preview); return;
        }
        book.remoteToken = remoteToken(remote);
        await this.hooks.save(book);
        decision = book.dirty ? 'push' : 'none';
      }
      if (decision === 'pull' && remote) {
        const revision = book.position.revision;
        const position = await this.hooks.restore(remote);
        if (!this.hooks.active() || !canAcknowledge(revision, book.position.revision)) {
          this.hooks.status('pending'); return;
        }
        position.updatedAt = (remote.timestamp || 0) * 1000;
        position.revision = revision + 1;
        book.position = position; book.dirty = !!this.provider.acceptRemote; book.remoteToken = remoteToken(remote);
        await this.hooks.save(book);
        if (this.provider.acceptRemote) {
          const snapshot = JSON.parse(JSON.stringify(position)) as ReadingPosition;
          await this.provider.acceptRemote(book.hash, snapshot);
          if (!this.hooks.active()) return;
          if (canAcknowledge(snapshot.revision, book.position.revision)) book.dirty = false;
          await this.hooks.save(book);
        }
      } else if (decision === 'push') {
        const snapshot = JSON.parse(JSON.stringify(book.position)) as ReadingPosition;
        const ack = await this.provider.push(book.hash, snapshot);
        if (!this.hooks.active()) return;
        // The PUT response acknowledges only this snapshot, never a concurrent edit.
        // Retain its identity even if this server does not return a timestamp.
        book.remoteToken = ack?.timestamp ? remoteToken(ack) : uploadedToken(snapshot.xpointer, snapshot.percentage, ack?.device_id || '');
        if (canAcknowledge(snapshot.revision, book.position.revision)) book.dirty = false;
        await this.hooks.save(book);
      }
      this.reconciled = true; this.awaitingChoice = false; this.pendingRemote = undefined;
      this.hooks.status(book.dirty ? 'pending' : 'synced');
    } catch (error) { this.hooks.status('error'); throw error as Error; }
  }
}
