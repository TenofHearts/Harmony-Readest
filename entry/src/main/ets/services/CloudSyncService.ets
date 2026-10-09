import { util } from '@kit.ArkTS';
import { BookRecord, ReadingPosition, RemoteProgress, ReplicaSettings, ProgressSyncProvider, ReaderSettings } from '../core/Models';
import { CloudClient, CloudBook, CloudConfig, cloudTime, cloudProgress, cloudStyle, bookPayload, configPayload } from '../core/CloudClient';
import { Repository } from './Repository';
import { CloudFiles } from './CloudFiles';
import { NativeTransport } from './NativeTransport';
import { ReplicaService } from './ReplicaService';
import { decideSync } from '../core/SyncPolicy';

export interface CloudHooks {
  books: () => BookRecord[];
  changed: () => void;
  style: (book: BookRecord) => Promise<void>;
  reading: () => BookRecord | undefined;
  sendPosition: (book: BookRecord, position: ReadingPosition) => Promise<RemoteProgress | null>;
  defaults: () => ReaderSettings;
  fallback: (hash: string) => Promise<RemoteProgress | null>;
}
export class CloudSyncService implements ProgressSyncProvider {
  private client: CloudClient = new CloudClient(new NativeTransport());
  private files: CloudFiles = new CloudFiles();
  private store: Repository;
  private replica: ReplicaService;
  private hooks: CloudHooks;
  private queue: Promise<void> = Promise.resolve();
  constructor(store: Repository, replica: ReplicaService, hooks: CloudHooks) { this.store = store; this.replica = replica; this.hooks = hooks; }
  async authenticate(): Promise<void> { await this.replica.session(); }
  private active(config: ReplicaSettings): void { if (!this.replica.config.enabled || !this.replica.validSession(config)) throw new Error('SESSION_CLOSED'); }
  private book(hash: string): BookRecord { const book = this.hooks.books().find((b: BookRecord) => b.hash === hash); if (!book) throw new Error('BOOK_NOT_FOUND'); return book; }
  private async acceptBook(row: CloudBook, config: ReplicaSettings): Promise<void> {
    this.active(config); if (row.format !== 'EPUB' || row.book_hash === '00000000000000000000000000000000') return;
    let book = this.hooks.books().find((b: BookRecord) => b.hash === row.book_hash);
    if (!book) {
      if (row.deleted_at) return;
      book = new BookRecord(); book.id = util.generateRandomUUID(); book.hash = row.book_hash;
      book.filename = `${row.source_title || row.title}.epub`; book.importedAt = cloudTime(row.created_at); this.hooks.books().push(book);
    }
    if (book.cloudAccount !== config.userId) { book.cloudConfig = ''; book.cloudUploaded = false; }
    book.cloudAccount = config.userId; book.cloudBook = JSON.stringify(row); book.cloudUploaded = !!row.uploaded_at;
    book.cloudDeleted = !!row.deleted_at; book.title = row.title; book.author = row.author;
    if (!book.position.cfi && row.progress?.length === 2 && row.progress[1] > 0) book.position.percentage = Math.max(0, Math.min(1, row.progress[0] / row.progress[1]));
    await this.store.save(book);
  }
  private async acceptConfig(row: CloudConfig, config: ReplicaSettings): Promise<void> {
    this.active(config); const book = this.hooks.books().find((b: BookRecord) => b.hash === row.book_hash);
    if (!book || book.cloudDeleted || row.deleted_at) return;
    if (book.cloudAccount !== config.userId) { book.cloudConfig = ''; book.cloudAccount = config.userId; }
    const previous: CloudConfig | null = book.cloudConfig ? JSON.parse(book.cloudConfig) as CloudConfig : null;
    if (previous && cloudTime(previous.updated_at) > cloudTime(row.updated_at)) return;
    book.cloudConfig = JSON.stringify(row);
    if (!book.styleDirty && row.view_settings && cloudTime(row.updated_at) > (book.styleUpdatedAt || 0)) {
      book.style = cloudStyle(row, book.style || this.hooks.defaults()); book.styleUpdatedAt = cloudTime(row.updated_at);
      await this.hooks.style(book);
    }
    if (!book.path && !book.position.cfi) {
      const remote = cloudProgress(row); if (remote?.percentage !== undefined) book.position.percentage = remote.percentage;
    }
    await this.store.save(book);
  }
  sync(config: ReplicaSettings): Promise<void> {
    const task = this.queue.then(() => this.perform(config)); this.queue = task.catch(() => {}); return task;
  }
  private async perform(config: ReplicaSettings): Promise<void> {
    this.active(config); const cursors = await this.store.cloudState(config.userId);
    const library = await this.client.pull(config, 'books', cursors[0]); this.active(config);
    let booksCursor = cursors[0];
    for (const row of library.books || []) {
      await this.acceptBook(row, config); booksCursor = Math.max(booksCursor, cloudTime(row.synced_at));
    }
    const configs = await this.client.pull(config, 'configs', cursors[1]); this.active(config);
    let configCursor = cursors[1];
    for (const row of configs.configs || []) {
      await this.acceptConfig(row, config); configCursor = Math.max(configCursor, cloudTime(row.updated_at), cloudTime(row.deleted_at));
    }
    // Advance only after every received row was applied. Replays are idempotent.
    await this.store.saveCloudState(config.userId, [booksCursor, configCursor]); this.hooks.changed();
    this.replica.pendingProgress = 0;
    for (const book of [...this.hooks.books()]) {
      this.active(config);
      if (book.cloudAccount === config.userId && book.cloudUploaded && !book.cloudDeleted && !book.cover) {
        try { await this.downloadCover(book, config); } catch {} this.active(config);
      }
      if (book.cloudDeleted || !book.hash || !this.files.exists(book.path)) continue;
      if (book.cloudAccount !== config.userId) {
        book.cloudAccount = config.userId; book.cloudBook = ''; book.cloudConfig = ''; book.cloudUploaded = false;
      }
      if (!book.cloudUploaded) {
        // Publish metadata before the signed file transfer, uploadedAt only after completion.
        const initial = await this.client.push(config, 'books', bookPayload(book)); this.active(config);
        for (const row of initial.books || []) await this.acceptBook(row, config);
        if (book.cloudDeleted) continue;
        const url = await this.client.uploadURL(config, book.hash, this.files.size(book.path)); this.active(config);
        await this.files.upload(url, book.path); this.active(config);
        if (this.files.exists(book.cover)) {
          const coverSize = this.files.size(book.cover, 4 * 1024 * 1024);
          await this.files.upload(await this.client.uploadURL(config, book.hash, coverSize, true), book.cover); this.active(config);
        }
        const complete = await this.client.push(config, 'books', bookPayload(book, true)); this.active(config);
        for (const row of complete.books || []) await this.acceptBook(row, config);
        if (!book.cloudUploaded) throw new Error('INVALID_CLOUD');
      }
      // Changing typography must preserve the cloud reading position until reconciled.
      const remote: CloudConfig | null = book.cloudConfig ? JSON.parse(book.cloudConfig) as CloudConfig : null;
      if (!book.style && !remote?.view_settings) {
        book.style = JSON.parse(JSON.stringify(this.hooks.defaults())) as ReaderSettings;
        book.styleUpdatedAt = Date.now(); book.styleDirty = true; await this.store.save(book);
      }
      if (book.style && book.styleDirty) {
        const current = await this.client.pull(config, 'configs', 0, book.hash); this.active(config);
        for (const row of current.configs || []) if (row.book_hash === book.hash) await this.acceptConfig(row, config);
        const revision = book.styleUpdatedAt;
        const accepted = await this.client.push(config, 'configs', configPayload(book)); this.active(config);
        for (const row of accepted.configs || []) {
          await this.acceptConfig(row, config);
          if (book.styleUpdatedAt === revision) { book.styleDirty = false; book.styleUpdatedAt = cloudTime(row.updated_at); await this.store.save(book); }
        }
      }
      const latest: CloudConfig | null = book.cloudConfig ? JSON.parse(book.cloudConfig) as CloudConfig : null;
      const remoteProgress = latest ? cloudProgress(latest) : null;
      if ((book.dirty || (!remoteProgress && book.position.cfi)) && book.id !== this.hooks.reading()?.id) {
        const candidate = remoteProgress || await this.hooks.fallback(book.hash); this.active(config);
        const decision = decideSync(book, candidate);
        if (decision === 'push' || (!remoteProgress && decision === 'none')) {
          book.dirty = true; await this.store.save(book);
          const snapshot = JSON.parse(JSON.stringify(book.position)) as ReadingPosition;
          await this.hooks.sendPosition(book, snapshot); this.active(config);
          if (book.position.revision === snapshot.revision) { book.dirty = false; await this.store.save(book); }
        } else this.replica.pendingProgress++;
      }
    }
    this.hooks.changed();
  }
  async download(book: BookRecord): Promise<void> {
    if (this.files.exists(book.path)) return;
    const config = await this.replica.session(); this.active(config);
    if (book.cloudAccount !== config.userId || !book.cloudUploaded) throw new Error('CLOUD_FILE_MISSING');
    const path = `${this.store.directory}/${book.id}.epub`;
    await this.files.download(await this.client.downloadURL(config, book.hash), path, book.hash); this.active(config);
    book.path = path; await this.store.save(book);
    if (!book.cover) { try { await this.downloadCover(book, config); } catch {} }
    this.hooks.changed();
  }
  private async downloadCover(book: BookRecord, config: ReplicaSettings): Promise<void> {
    const row: CloudBook | null = book.cloudBook ? JSON.parse(book.cloudBook) as CloudBook : null;
    const path = `${this.store.directory}/${book.id}.cover`;
    await this.files.download(await this.client.downloadURL(config, book.hash, true), path, row?.cover_hash || '', 4 * 1024 * 1024); this.active(config);
    book.cover = path; await this.store.save(book); this.hooks.changed();
  }
  async pull(hash: string): Promise<RemoteProgress | null> {
    const config = await this.replica.session(); this.active(config);
    const result = await this.client.pull(config, 'configs', 0, hash); this.active(config);
    let newest: CloudConfig | undefined;
    for (const row of result.configs || []) {
      if (row.book_hash !== hash) continue;
      await this.acceptConfig(row, config);
      if (!newest || cloudTime(row.updated_at) > cloudTime(newest.updated_at)) newest = row;
    }
    return newest ? cloudProgress(newest) : null;
  }
  async push(hash: string, position: ReadingPosition): Promise<RemoteProgress | null> {
    const config = await this.replica.session(); this.active(config); const book = this.book(hash);
    const styleRevision = book.styleUpdatedAt;
    const styleDirty = book.styleDirty;
    const result = await this.client.push(config, 'configs', configPayload(book, position)); this.active(config);
    const row = result.configs?.find((c: CloudConfig) => c.book_hash === hash);
    if (!row) throw new Error('INVALID_CLOUD');
    const ack = cloudProgress(row);
    if (!ack || ack.cfi !== position.cfi) throw new Error('CLOUD_CONFLICT');
    book.cloudConfig = JSON.stringify(row);
    if (styleDirty && book.styleUpdatedAt === styleRevision) { book.styleUpdatedAt = cloudTime(row.updated_at); book.styleDirty = false; }
    if (!styleDirty) await this.acceptConfig(row, config);
    await this.store.save(book); return ack;
  }
  async remove(book: BookRecord): Promise<void> {
    const config = await this.replica.session(); this.active(config);
    // A cloud deletion is explicit; bytes are retained by Readest's normal tombstone protocol.
    const response = await this.client.push(config, 'books', bookPayload(book, false, true)); this.active(config);
    const row = response.books?.find((b: CloudBook) => b.book_hash === book.hash);
    if (!row?.deleted_at) throw new Error('INVALID_CLOUD');
    await this.acceptBook(row, config); await this.store.remove(book);
    const index = this.hooks.books().findIndex((b: BookRecord) => b.id === book.id);
    if (index >= 0) this.hooks.books().splice(index, 1); this.hooks.changed();
  }
}
