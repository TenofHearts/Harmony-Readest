import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { webview } from '@kit.ArkWeb';
import { connection } from '@kit.NetworkKit';
import { BookRecord, KoSyncSettings, ReaderCommand, ReaderEvent, ReaderSettings, RemoteProgress, ReadingPosition } from '../core/Models';
import { KoSyncClient, normalizeServer } from '../core/KoSyncClient';
import { ProgressCoordinator, SyncHooks } from '../core/ProgressCoordinator';
import { isCurrentSession } from '../core/SyncPolicy';
import { errorMessage } from '../core/Errors';
import { Repository } from './Repository';
import { CredentialVault } from './CredentialVault';
import { NativeTransport } from './NativeTransport';
import { ReaderGateway } from './ReaderGateway';
import { removeLocalFile } from './LocalFiles';

export class AppController {
  static current?: AppController;
  books: BookRecord[] = [];
  activeBook?: BookRecord;
  appearance: ReaderSettings = new ReaderSettings();
  config: KoSyncSettings = new KoSyncSettings();
  status: string = 'idle';
  error: string = '';
  busy: boolean = false;
  conflict?: RemoteProgress;
  conflictPreview?: ReadingPosition;
  controls: boolean = true;
  initialized: boolean = false;
  importing: boolean = false;
  changed: () => void = () => {};
  reader?: ReaderGateway;
  private store: Repository = new Repository();
  private vault: CredentialVault = new CredentialVault();
  private coordinator?: ProgressCoordinator;
  private debounce: number = -1;
  private opened: boolean = false;
  private blocked: boolean = false;
  private restoreFailed: boolean = false;
  private epoch: number = 0;
  private importResolve?: () => void;
  private importReject?: (error: Error) => void;
  private openTimer: number = -1;
  private closeResolve?: () => void;
  private context: common.UIAbilityContext;
  private events: Promise<void> = Promise.resolve();
  private network?: connection.NetConnection;

  constructor(context: common.UIAbilityContext) { this.context = context; AppController.current = this; }

  async init(): Promise<void> {
    await this.store.init(this.context); await this.vault.init(this.context);
    this.books = await this.store.list(); this.appearance = await this.store.settings();
    try { this.config = await this.vault.load(); } catch { this.error = 'CREDENTIALS_UNAVAILABLE'; }
    this.config.deviceId = await this.store.deviceId();
    try {
      this.network = connection.createNetConnection();
      this.network.on('netAvailable', () => this.onNetworkAvailable());
      this.network.register(() => {});
    } catch { this.network = undefined; }
    this.initialized = true;
    if (this.reader?.ready) await this.setAppearance(this.appearance);
    this.changed();
  }

  attach(controller: webview.WebviewController): ReaderGateway {
    const gateway = new ReaderGateway(this.context, controller);
    gateway.onEvent = (event: ReaderEvent) => { this.events = this.events.then(() => this.handle(event)).catch((error: Error) => this.fail(error)); };
    this.reader = gateway; return gateway;
  }

  private fail(error: Error): void {
    const message = errorMessage(error);
    hilog.error(0x0000, 'HarmonyReadest', 'Operation failed: %{public}s', message);
    this.error = message; this.status = 'error'; this.changed();
  }
  private scope(): string { return `${this.config.serverUrl}|${this.config.username}`; }

  async saveConfig(config: KoSyncSettings): Promise<void> {
    config.serverUrl = normalizeServer(config.serverUrl);
    if (!config.username.trim() || !config.password) throw new Error('CREDENTIALS_REQUIRED');
    config.username = config.username.trim(); config.deviceId = await this.store.deviceId();
    await this.vault.prepare(config);
    const client = new KoSyncClient(config, new NativeTransport()); await client.authenticate();
    const previous = this.scope();
    await this.vault.save(config);
    this.epoch++; this.config = config; this.coordinator = undefined; this.conflict = undefined; this.blocked = false;
    if (previous !== this.scope()) {
      for (const book of this.books) {
        book.syncScope = this.scope(); book.dirty = false; book.remoteToken = ''; await this.store.save(book);
      }
    }
    this.status = 'connected'; this.error = ''; this.changed();
    if (this.opened && config.enabled) await this.sync('reconcile');
  }

  async disconnect(): Promise<void> {
    this.epoch++; clearTimeout(this.debounce); this.coordinator = undefined;
    await this.vault.clear();
    this.config = new KoSyncSettings(); this.config.deviceId = await this.store.deviceId();
    this.status = 'idle'; this.conflict = undefined; this.changed();
  }

  async importBooks(): Promise<void> {
    if (!this.reader?.ready || this.busy) return;
    const selected = await new picker.DocumentViewPicker(this.context).select({ maxSelectNumber: 20,
      fileSuffixFilters: ['EPUB books|.epub'] });
    if (!selected.length) return;
    this.busy = true; this.importing = true; this.error = ''; this.changed();
    try {
      for (const uri of selected) {
        let name = decodeURIComponent(uri.split('/').pop() || 'Book.epub');
        if (!name.toLowerCase().endsWith('.epub')) name += '.epub';
        const book = await this.store.importFile(uri, name);
        this.activeBook = book;
        await new Promise<void>((resolve: () => void, reject: (error: Error) => void) => {
          const timer = setTimeout(() => {
            this.importResolve = undefined; this.importReject = undefined;
            this.reader!.reset(); reject(new Error('IMPORT_TIMEOUT'));
          }, 30000);
          this.importResolve = () => { clearTimeout(timer); this.importReject = undefined; resolve(); };
          this.importReject = (error: Error) => { clearTimeout(timer); this.importResolve = undefined; this.importReject = undefined; reject(error); };
          this.reader!.open(book, true).catch((error: Error) => this.importReject?.(error));
        });
        const duplicate = this.books.find((existing: BookRecord) => existing.hash === book.hash);
        await this.reader!.send(this.command('close')); this.reader!.cancel();
        if (!book.hash || duplicate) {
          removeLocalFile(book.path);
          removeLocalFile(book.cover);
          if (duplicate) this.error = 'DUPLICATE_BOOK';
        } else { await this.store.save(book); this.books.unshift(book); }
      }
    } catch (error) {
      this.fail(error as Error);
    } finally {
      try {
        if (this.activeBook && !this.books.some((value: BookRecord) => value.id === this.activeBook!.id)) {
          removeLocalFile(this.activeBook.path); removeLocalFile(this.activeBook.cover);
        }
      } finally {
        this.importResolve = undefined; this.importReject = undefined;
        this.activeBook = undefined; this.importing = false; this.busy = false; this.opened = false;
        this.reader?.cancel(); this.changed();
      }
    }
  }

  async open(book: BookRecord): Promise<void> {
    if (!this.reader?.ready || this.busy) return;
    this.epoch++; this.coordinator = undefined; this.opened = false; this.blocked = false; this.restoreFailed = false;
    this.activeBook = book; this.conflict = undefined; this.error = ''; this.controls = true;
    this.busy = true; book.lastOpenedAt = Date.now();
    if (book.syncScope !== this.scope()) { book.syncScope = this.scope(); book.remoteToken = ''; book.dirty = false; }
    await this.store.save(book); this.changed();
    const epoch = this.epoch;
    this.openTimer = setTimeout(() => {
      if (epoch !== this.epoch || this.opened) return;
      this.reader?.reset(); this.activeBook = undefined; this.busy = false;
      this.fail(new Error('READER_TIMEOUT'));
    }, 30000);
    try { await this.reader.open(book); } catch (error) {
      clearTimeout(this.openTimer); this.reader.cancel(); this.activeBook = undefined;
      this.busy = false; this.fail(error as Error);
    }
  }

  command(type: string): ReaderCommand { const command = new ReaderCommand(); command.type = type; return command; }

  async close(): Promise<void> {
    clearTimeout(this.openTimer);
    clearTimeout(this.debounce);
    if (!this.activeBook) return;
    await this.events;
    this.busy = true; this.changed();
    // Flush the chosen local position before tearing down the reader.
    try { if (!this.blocked && this.config.enabled) await this.sync(); } catch {}
    if (this.opened && this.reader) {
      await new Promise<void>((resolve: () => void) => {
        const timer = setTimeout(resolve, 2000);
        this.closeResolve = () => { clearTimeout(timer); resolve(); };
        this.reader!.send(this.command('close')).catch(() => resolve());
      });
    }
    await this.events;
    this.epoch++; this.reader?.cancel(); this.coordinator = undefined;
    this.activeBook = undefined; this.opened = false; this.busy = false; this.conflict = undefined;
    this.books.sort((a: BookRecord, b: BookRecord) => b.lastOpenedAt - a.lastOpenedAt); this.changed();
  }

  async remove(book: BookRecord): Promise<void> {
    await this.store.remove(book); this.books = this.books.filter((item: BookRecord) => item.id !== book.id); this.changed();
  }

  async setAppearance(settings: ReaderSettings): Promise<void> {
    this.appearance = settings; await this.store.saveSettings(settings);
    const command = this.command('appearance'); command.settings = settings;
    if (this.reader?.ready) await this.reader.send(command); this.changed();
  }

  private async handle(event: ReaderEvent): Promise<void> {
    if (event.type !== 'ready' && !isCurrentSession(this.reader?.session || '', event.session)) return;
    const book = this.activeBook;
    if (event.type === 'ready') {
      if (this.initialized) await this.setAppearance(this.appearance);
      else this.changed();
      return;
    }
    if (!book) return;
    if (event.type === 'metadata' && event.metadata) {
      if (!/^[0-9a-f]{32}$/.test(event.metadata.hash)) throw new Error('INVALID_EPUB');
      book.title = event.metadata.title || book.title; book.author = event.metadata.author;
      book.hash = event.metadata.hash; book.toc = event.metadata.toc;
    } else if (event.type === 'cover' && event.cover) {
      await this.store.cover(book, event.cover);
      if (!this.importing) await this.store.save(book);
    } else if (event.type === 'position' && event.position && !this.importing && !event.restored && this.opened) {
      if (event.position.cfi === book.position.cfi) return;
      event.position.updatedAt = Date.now(); event.position.revision = book.position.revision + 1;
      book.position = event.position; book.dirty = true; book.syncScope = this.scope();
      await this.store.save(book);
      clearTimeout(this.debounce);
      if (this.config.enabled && !this.blocked) this.debounce = setTimeout(() => { this.sync().catch(() => {}); }, 5000);
    } else if (event.type === 'position' && event.position && !book.position.cfi) {
      book.position = event.position; book.position.updatedAt = 0; book.position.revision = 0;
    } else if (event.type === 'opened') {
      clearTimeout(this.openTimer);
      if (this.importing) { this.importResolve?.(); this.importResolve = undefined; }
      else {
        this.opened = true; this.busy = false; await this.store.save(book);
        this.changed(); if (this.config.enabled) this.sync('reconcile').catch(() => {});
      }
    } else if (event.type === 'error') {
      clearTimeout(this.openTimer);
      const error = new Error(event.requestId ? 'UNRESOLVED_POSITION' : event.message || 'READER_ERROR');
      if (this.importing) { this.importReject?.(error); return; }
      if (!this.opened) { this.reader?.cancel(); this.activeBook = undefined; }
      this.busy = false; this.blocked = true; throw error;
    } else if (event.type === 'closed') { this.closeResolve?.(); this.closeResolve = undefined; }
    else if (event.type === 'toggleControls') this.controls = !this.controls;
    this.changed();
  }

  async sync(mode: string = 'upload'): Promise<void> {
    const book = this.activeBook;
    if (!book || !this.opened || !this.config.enabled || !this.config.userkey || (this.blocked && mode === 'upload')) return;
    if (mode !== 'upload') { this.blocked = false; this.restoreFailed = false; this.conflict = undefined; this.conflictPreview = undefined; }
    if (!this.coordinator) {
      const session = this.reader!.session, epoch = this.epoch, scope = this.scope();
      const hooks: SyncHooks = {
        save: (value: BookRecord): Promise<void> => this.store.save(value),
        inspect: (remote: RemoteProgress): Promise<ReadingPosition> => this.reader!.inspect(remote),
        deviceId: this.config.deviceId,
        restore: (remote: RemoteProgress): Promise<ReadingPosition> => this.reader!.restore(remote).catch((error: Error) => {
          if (epoch === this.epoch) this.restoreFailed = true; throw error;
        }),
        active: (): boolean => epoch === this.epoch && session === this.reader?.session && scope === this.scope(),
        status: (status: string): void => { if (epoch === this.epoch) { this.status = status; this.changed(); } },
        conflict: (remote: RemoteProgress, preview?: ReadingPosition): void => {
          this.conflict = remote; this.conflictPreview = preview; this.blocked = true; this.changed();
        }
      };
      this.coordinator = new ProgressCoordinator(new KoSyncClient(this.config, new NativeTransport()), hooks);
    }
    const epoch = this.epoch;
    try { await this.coordinator.sync(book, mode); if (epoch === this.epoch) this.error = ''; }
    catch (error) { if (epoch === this.epoch) { this.blocked = true; this.fail(error as Error); } throw error as Error; }
    finally { this.changed(); }
  }

  onBackground(): void {
    clearTimeout(this.debounce);
    if (this.activeBook) this.store.save(this.activeBook).catch(() => {});
    if (!this.blocked) this.sync().catch(() => {});
  }

  onForeground(): void { if (this.opened) { this.blocked = false; this.sync('reconcile').catch(() => {}); } }

  private onNetworkAvailable(): void {
    if (this.opened && !this.conflict && !this.restoreFailed) { this.blocked = false; this.sync().catch(() => {}); }
  }

  dispose(): void {
    clearTimeout(this.openTimer);
    this.onBackground(); this.epoch++; try { this.network?.unregister(() => {}); } catch {} this.reader?.cancel();
    this.changed = () => {}; if (AppController.current === this) AppController.current = undefined;
  }
}
