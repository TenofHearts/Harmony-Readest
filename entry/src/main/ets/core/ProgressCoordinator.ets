import { BookRecord, ProgressSyncProvider, ReadingPosition, RemoteProgress } from './Models';
import { canAcknowledge, decideSync, remoteToken } from './SyncPolicy';

export interface SyncHooks {
  save: (book: BookRecord) => Promise<void>;
  restore: (remote: RemoteProgress) => Promise<ReadingPosition>;
  active: () => boolean;
  status: (value: string) => void;
  conflict: (remote: RemoteProgress) => void;
}

// Native and web rendering details stay outside this coordinator.
export class ProgressCoordinator {
  private queue: Promise<void> = Promise.resolve();
  private provider: ProgressSyncProvider;
  private hooks: SyncHooks;
  constructor(provider: ProgressSyncProvider, hooks: SyncHooks) { this.provider = provider; this.hooks = hooks; }

  sync(book: BookRecord, mode: string = 'auto'): Promise<void> {
    const task = this.queue.then(() => this.run(book, mode));
    this.queue = task.catch(() => {});
    return task;
  }

  private async run(book: BookRecord, mode: string): Promise<void> {
    if (!this.hooks.active() || !book.hash) return;
    this.hooks.status('checking');
    try {
      const remote = await this.provider.pull(book.hash);
      if (!this.hooks.active()) return;
      const decision = mode === 'push' ? 'push' : mode === 'pull' ? (remote ? 'pull' : 'none') : decideSync(book, remote);
      if (decision === 'conflict') { this.hooks.status('conflict'); this.hooks.conflict(remote!); return; }
      if (decision === 'pull' && remote) {
        const revision = book.position.revision;
        const position = await this.hooks.restore(remote);
        if (!this.hooks.active() || !canAcknowledge(revision, book.position.revision)) {
          this.hooks.status('pending'); return;
        }
        position.updatedAt = (remote.timestamp || 0) * 1000;
        position.revision = revision + 1;
        book.position = position; book.dirty = false; book.remoteToken = remoteToken(remote);
        await this.hooks.save(book);
      } else if (decision === 'push') {
        const snapshot = JSON.parse(JSON.stringify(book.position)) as ReadingPosition;
        await this.provider.push(book.hash, snapshot);
        if (!this.hooks.active()) return;
        // Capture the server's acknowledged timestamp without clearing concurrent reading changes.
        const ack = await this.provider.pull(book.hash);
        if (!this.hooks.active()) return;
        if (ack?.progress === snapshot.xpointer) {
          book.remoteToken = remoteToken(ack);
          if (canAcknowledge(snapshot.revision, book.position.revision)) book.dirty = false;
        } else { book.dirty = true; }
        await this.hooks.save(book);
      }
      this.hooks.status(book.dirty ? 'pending' : 'synced');
    } catch (error) { this.hooks.status('error'); throw error as Error; }
  }
}
