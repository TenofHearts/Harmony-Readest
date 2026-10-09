import { ProgressSyncProvider, ReadingPosition, RemoteProgress } from './Models';

// Readest owns the resume position when enabled; KoSync receives the same chosen position.
// A failure in either channel leaves the snapshot pending for retry.
export class CombinedProgress implements ProgressSyncProvider {
  private primary: ProgressSyncProvider;
  private mirror?: ProgressSyncProvider;
  private primaryRemote: boolean = true;
  private mirrorMode: string;
  constructor(primary: ProgressSyncProvider, mirror?: ProgressSyncProvider, mirrorMode: string = 'prompt') {
    this.primary = primary; this.mirror = mirror; this.mirrorMode = mirrorMode;
  }
  async authenticate(): Promise<void> { await this.primary.authenticate(); }
  async pull(hash: string): Promise<RemoteProgress | null> {
    const primary = await this.primary.pull(hash); this.primaryRemote = !!primary;
    return primary || (this.mirror && this.mirrorMode !== 'send' ? await this.mirror.pull(hash) : null);
  }
  async push(hash: string, position: ReadingPosition): Promise<RemoteProgress | null> {
    const ack = await this.primary.push(hash, position);
    if (this.mirror && this.mirrorMode !== 'receive') await this.mirror.push(hash, position); return ack;
  }
  async acceptRemote(hash: string, position: ReadingPosition): Promise<void> {
    if (!this.primaryRemote) await this.primary.push(hash, position);
    if (this.mirror && this.mirrorMode !== 'receive') await this.mirror.push(hash, position);
  }
}
