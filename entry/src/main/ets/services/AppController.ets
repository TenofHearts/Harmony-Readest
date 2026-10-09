import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { webview } from '@kit.ArkWeb';
import { connection } from '@kit.NetworkKit';
import { i18n } from '@kit.LocalizationKit';
import { BookRecord, KoSyncSettings, ReaderCommand, ReaderEvent, ReaderSettings, ThemeSettings, RemoteProgress, ReadingPosition } from '../core/Models';
import { isThemeMode, isThemeColor } from '../core/Themes';
import { KoSyncClient, normalizeServer } from '../core/KoSyncClient';
import { ProgressCoordinator, SyncHooks } from '../core/ProgressCoordinator';
import { isCurrentSession } from '../core/SyncPolicy';
import { errorMessage } from '../core/Errors';
import { Repository } from './Repository';
import { CredentialVault } from './CredentialVault';
import { NativeTransport } from './NativeTransport';
import { ReaderGateway, READER_ORIGIN } from './ReaderGateway';
import { FontLibrary } from './FontLibrary';
import { ReplicaService } from './ReplicaService';
import { CloudSyncService, CloudHooks } from './CloudSyncService';
import { CombinedProgress } from '../core/CombinedProgress';
import { CloudFiles } from './CloudFiles';
import { validTypography } from '../core/TypographyPolicy';
import { migrateAppearance, StoredAppearance, validAppearanceEvent } from '../core/ThemePolicy';
import { removeLocalFile } from './LocalFiles';
import { readerAppearance } from '../core/AppearancePolicy';
import { validAnnotations } from '../core/AnnotationPolicy';
import { shareBook } from './BookSharing';

export class AppController {
  static current?: AppController;
  books: BookRecord[] = [];
  activeBook?: BookRecord;
  appearance: ReaderSettings = new ReaderSettings();
  activeAppearance: ReaderSettings = new ReaderSettings();
  language: string = 'auto';
  libraryTheme: ThemeSettings = new ThemeSettings();
  systemDark: boolean = false;
  config: KoSyncSettings = new KoSyncSettings();
  fonts: FontLibrary = new FontLibrary();
  replica: ReplicaService = new ReplicaService(this.fonts);
  status: string = 'idle';
  error: string = '';
  busy: boolean = false;
  conflict?: RemoteProgress;
  conflictPreview?: ReadingPosition;
  controls: boolean = true;
  initialized: boolean = false;
  importing: boolean = false;
  changed: () => void = () => {};
  readerAction: (action: string) => void = () => {};
  reader?: ReaderGateway;
  private store: Repository = new Repository();
  private cloud: CloudSyncService;
  private coordinatorScope: string = '';
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
  private closing: boolean = false;
  private picking: boolean = false;
  private appliedLanguage: string = '';
  private changingLanguage: boolean = false;
  private configurationLanguage: string = '';
  private languageWrites: Promise<void> = Promise.resolve();
  private context: common.UIAbilityContext;
  private events: Promise<void> = Promise.resolve();
  private network?: connection.NetConnection;

  constructor(context: common.UIAbilityContext) {
    this.context = context; AppController.current = this;
    const hooks: CloudHooks = { books: () => this.books, changed: () => this.changed(), reading: () => this.activeBook, defaults: () => this.appearance,
      fallback: async (hash: string) => this.config.enabled && this.config.userkey ? new KoSyncClient(this.config, new NativeTransport()).pull(hash) : null,
      sendPosition: (book: BookRecord, position: ReadingPosition) => new CombinedProgress(this.cloud,
        this.config.enabled && this.config.userkey ? new KoSyncClient(this.config, new NativeTransport()) : undefined).push(book.hash, position),
      style: async (book: BookRecord) => { if (book.id === this.activeBook?.id && !this.importing && book.style) await this.applyAppearance(readerAppearance(this.appearance, book.style)); } };
    this.cloud = new CloudSyncService(this.store, this.replica, hooks);
    this.replica.cloudSync = (config) => this.cloud.sync(config);
    this.replica.afterSync = () => this.sync();
    this.systemDark = context.config?.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  async init(): Promise<void> {
    await this.store.init(this.context); await this.vault.init(this.context);
    this.books = await this.store.list(); this.appearance = await this.store.settings();
    this.activeAppearance = this.appearance;
    this.language = await this.store.language(); this.applyLanguage();
    this.libraryTheme = await this.store.librarySettings();
    // Commit both scopes before any reader-ready callback can replace legacy data.
    await this.store.saveLibrarySettings(this.libraryTheme);
    try { this.config = await this.vault.load(); } catch { this.error = 'CREDENTIALS_UNAVAILABLE'; }
    this.config.deviceId = await this.store.deviceId();
    await this.fonts.init(this.context); await this.replica.init(this.context, this.config.deviceId);
    this.replica.changed = () => this.changed(); this.replica.fontsChanged = () => this.updateFonts();
    try {
      this.network = connection.createNetConnection();
      this.network.on('netAvailable', () => this.onNetworkAvailable());
      this.network.register(() => {});
    } catch { this.network = undefined; }
    this.initialized = true;
    if (this.reader?.ready) { await this.updateFonts(); await this.applyAppearance(this.appearance); }
    this.changed();
    this.replica.sync().catch(() => {});
    this.replica.refreshStorage().catch(() => {});
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
  cloudEnabled(): boolean { return !!this.replica.config.userId && this.replica.config.enabled; }
  progressEnabled(): boolean { return this.cloudEnabled() || (this.config.enabled && !!this.config.userkey); }
  private scope(): string { return `${this.cloudEnabled() ? this.replica.config.userId : ''}|${this.config.enabled ? `${this.config.serverUrl}|${this.config.username}` : ''}`; }

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

  async updateSyncOptions(enabled: boolean, deviceName: string): Promise<void> {
    if (!this.config.userkey) return;
    // Account options change locally; saved credentials do not need a new login.
    const config = new KoSyncSettings();
    config.serverUrl = this.config.serverUrl; config.username = this.config.username;
    config.password = this.config.password; config.userkey = this.config.userkey; config.basicKey = this.config.basicKey;
    config.deviceId = this.config.deviceId; config.deviceName = deviceName.trim() || 'Readest'; config.enabled = enabled;
    await this.vault.save(config);
    this.epoch++; this.config = config; this.coordinator = undefined;
    if (!enabled) clearTimeout(this.debounce);
    this.changed();
  }

  async importBooks(): Promise<void> {
    if (!this.reader?.ready || this.busy || this.picking || this.closing || this.activeBook) return;
    this.picking = true;
    let selected: string[];
    try {
      selected = await new picker.DocumentViewPicker(this.context).select({ maxSelectNumber: 20,
        fileSuffixFilters: ['EPUB books|.epub'] });
    } finally { this.picking = false; }
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
        if (duplicate && (duplicate.cloudDeleted || (!duplicate.path && !!duplicate.cloudAccount))) {
          if (duplicate.cloudDeleted) { removeLocalFile(duplicate.path); removeLocalFile(duplicate.cover); duplicate.cloudDeleted = false; duplicate.cloudUploaded = false; }
          duplicate.path = book.path; duplicate.cover = book.cover; duplicate.toc = book.toc;
          await this.store.save(duplicate);
          book.path = ''; book.cover = '';
        } else if (!book.hash || duplicate) {
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
        this.replica.sync().catch(() => {});
      }
    }
  }

  async open(book: BookRecord): Promise<void> {
    if (!this.reader?.ready || this.busy || this.closing || this.picking) return;
    this.epoch++; this.coordinator = undefined; this.opened = false; this.blocked = false; this.restoreFailed = false;
    this.activeBook = book; this.conflict = undefined; this.error = ''; this.controls = true;
    this.busy = true; book.lastOpenedAt = Date.now();
    if (book.syncScope !== this.scope()) { book.syncScope = this.scope(); book.remoteToken = ''; book.dirty = this.cloudEnabled() && book.position.updatedAt > 0; }
    await this.store.save(book); this.changed();
    const epoch = this.epoch;
    try {
      if (!new CloudFiles().exists(book.path)) await this.cloud.download(book);
      this.activeAppearance = readerAppearance(this.appearance, book.style); this.changed();
    } catch (error) { this.activeBook = undefined; this.busy = false; this.fail(error as Error); return; }
    this.openTimer = setTimeout(() => {
      if (epoch !== this.epoch || this.opened) return;
      this.reader?.reset(); this.activeBook = undefined; this.busy = false;
      this.fail(new Error('READER_TIMEOUT'));
    }, 30000);
    try { await this.reader.open(book, false, this.activeAppearance, this.systemDark); } catch (error) {
      clearTimeout(this.openTimer); this.reader.cancel(); this.activeBook = undefined;
      this.busy = false; this.fail(error as Error);
    }
  }

  command(type: string): ReaderCommand { const command = new ReaderCommand(); command.type = type; return command; }

  async close(): Promise<void> {
    if (this.closing || !this.activeBook) return;
    const book = this.activeBook;
    this.closing = true;
    clearTimeout(this.openTimer);
    clearTimeout(this.debounce);
    await this.events;
    const coordinator = this.blocked ? undefined : this.coordinator;
    const scope = this.scope();
    // Position events save locally before close; network latency must not block navigation.
    if (this.opened && this.reader) {
      await new Promise<void>((resolve: () => void) => {
        const timer = setTimeout(resolve, 2000);
        this.closeResolve = () => { clearTimeout(timer); resolve(); };
        this.reader!.send(this.command('close')).catch(() => resolve());
      });
    }
    this.closeResolve = undefined;
    await this.events;
    this.epoch++; this.reader?.cancel(); this.coordinator = undefined;
    this.activeBook = undefined; this.opened = false; this.busy = false; this.conflict = undefined;
    this.activeAppearance = this.appearance; this.closing = false; this.changed();
    coordinator?.uploadPending(book, () => scope === this.scope() && book.syncScope === scope && this.activeBook?.id !== book.id)
      .catch(() => {});
  }

  async remove(book: BookRecord): Promise<void> {
    if (book.cloudAccount && book.cloudUploaded) {
      removeLocalFile(book.path); book.path = ''; await this.store.save(book); this.changed(); return;
    }
    await this.store.remove(book); this.books = this.books.filter((item: BookRecord) => item.id !== book.id); this.changed();
  }
  async removeCloud(book: BookRecord): Promise<void> { await this.cloud.remove(book); }

  async share(book: BookRecord): Promise<void> {
    await this.cloud.download(book);
    await shareBook(this.context, book);
  }

  async syncNow(): Promise<void> {
    // Reconcile first so a manual sync still presents conflicting positions.
    let failure: Error | undefined;
    try { await this.replica.sync(); } catch (error) { failure = error as Error; }
    await this.sync('reconcile');
    if (failure) throw failure;
  }

  async setAppearance(settings: ReaderSettings, persistBook: boolean = true): Promise<void> {
    settings = migrateAppearance(settings as StoredAppearance);
    await this.store.saveSettings(settings); this.appearance = settings;
    if (persistBook && this.activeBook && !this.importing) {
      this.activeBook.style = JSON.parse(JSON.stringify(settings)) as ReaderSettings; this.activeBook.styleUpdatedAt = Date.now(); this.activeBook.styleDirty = true;
      await this.store.save(this.activeBook);
      clearTimeout(this.debounce); this.debounce = setTimeout(() => { this.replica.sync().catch(() => {}); }, 5000);
    }
    await this.applyAppearance(settings);
  }

  private async applyAppearance(settings: ReaderSettings): Promise<void> {
    this.activeAppearance = settings;
    const command = this.command('appearance'); command.settings = settings; command.systemDark = this.systemDark;
    this.changed();
    if (this.reader?.ready) await this.reader.send(command);
  }

  private applyLanguage(): boolean {
    const language = this.language === 'auto' ? i18n.System.getSystemLanguage() : this.language;
    if (language === this.appliedLanguage) return false;
    const previous = this.appliedLanguage;
    // HarmonyOS may invoke onConfigurationUpdate synchronously inside setLanguage.
    this.appliedLanguage = language;
    this.changingLanguage = true;
    try { this.context.getApplicationContext().setLanguage(language); }
    catch (error) { this.appliedLanguage = previous; throw error as Error; }
    finally { this.changingLanguage = false; }
    return true;
  }

  async setLanguage(language: string): Promise<void> {
    if (!['auto', 'en', 'zh-Hans'].includes(language) || language === this.language) return;
    const previous = this.language;
    // Publish the choice before native callbacks, and update resources before disk I/O.
    // The repository restores it on launch; a second OS preference setter is unnecessary.
    this.language = language;
    try { this.applyLanguage(); } catch (error) { this.language = previous; throw error as Error; }
    this.changed();
    // A slow first flush must neither block the next choice nor overwrite it later.
    const write = this.languageWrites.then(() => this.store.saveLanguage(language));
    this.languageWrites = write.catch(() => {});
    await write;
  }

  onLanguageChanged(language?: string): void {
    const updated = language !== undefined && language !== this.configurationLanguage;
    if (language !== undefined) this.configurationLanguage = language;
    if (this.changingLanguage) return;
    const applied = this.language === 'auto' && this.applyLanguage();
    if (applied || updated) this.changed();
  }

  async updateFonts(): Promise<void> {
    if (this.reader?.ready) {
      this.reader.fonts = this.fonts.readerFontFiles();
      const command = this.command('fonts'); command.fonts = this.fonts.readerFonts(READER_ORIGIN); await this.reader.send(command);
    }
    this.changed();
  }

  async importFonts(): Promise<void> {
    try { await this.fonts.importFonts(); } finally { await this.updateFonts(); }
    this.replica.sync().catch(() => {});
  }

  async removeFont(id: string): Promise<void> {
    const family = this.fonts.fonts.find((font) => font.id === id)?.family;
    await this.replica.removeFont(id);
    if (family && !this.fonts.fonts.some((font) => font.family === family)) {
      const settings = JSON.parse(JSON.stringify(this.appearance)) as ReaderSettings;
      if (settings.serifFont === family) settings.serifFont = 'serif';
      if (settings.sansSerifFont === family) settings.sansSerifFont = 'sans-serif';
      if (settings.monospaceFont === family) settings.monospaceFont = 'monospace';
      if (settings.defaultCJKFont === family) settings.defaultCJKFont = '';
      await this.setAppearance(settings);
    }
  }

  async setLibraryTheme(settings: ThemeSettings): Promise<void> {
    if (!isThemeMode(settings.themeMode) || !isThemeColor(settings.themeColor)) return;
    this.libraryTheme = settings; await this.store.saveLibrarySettings(settings); this.changed();
  }

  setSystemDark(dark: boolean): void {
    if (dark === this.systemDark) return;
    this.systemDark = dark;
    const command = this.command('systemTheme'); command.systemDark = dark;
    if (this.reader?.ready) this.reader.send(command).catch(() => {});
    this.changed();
  }

  private async handle(event: ReaderEvent): Promise<void> {
    if (event.type !== 'ready' && !isCurrentSession(this.reader?.session || '', event.session)) return;
    const book = this.activeBook;
    if (event.type === 'ready') {
      if (this.initialized) await this.updateFonts();
      if (this.initialized) await this.applyAppearance(this.appearance);
      else this.changed();
      return;
    }
    if (!book) return;
    if (event.type === 'metadata' && event.metadata) {
      if (!/^[0-9a-f]{32}$/.test(event.metadata.hash)) throw new Error('INVALID_EPUB');
      book.title = event.metadata.title || book.title; book.author = event.metadata.author;
      book.hash = event.metadata.hash; book.toc = event.metadata.toc;
      if (event.metadata.metadataJSON && event.metadata.metadataJSON.length <= 1024 * 1024) book.metadataJSON = event.metadata.metadataJSON;
    } else if (event.type === 'cover' && event.cover) {
      await this.store.cover(book, event.cover);
      if (!this.importing) await this.store.save(book);
    } else if (event.type === 'position' && event.position && !this.importing && !event.restored && this.opened) {
      if (event.position.cfi === book.position.cfi) return;
      event.position.updatedAt = Date.now(); event.position.revision = book.position.revision + 1;
      book.position = event.position; book.dirty = true; book.syncScope = this.scope();
      await this.store.save(book);
      clearTimeout(this.debounce);
      if (this.progressEnabled() && !this.blocked) this.debounce = setTimeout(() => { this.sync().catch(() => {}); }, 5000);
    } else if (event.type === 'position' && event.position && !book.position.cfi) {
      book.position = event.position; book.position.updatedAt = 0; book.position.revision = 0;
    } else if (event.type === 'position') {
      return;
    } else if (event.type === 'opened') {
      clearTimeout(this.openTimer);
      if (this.importing) { this.importResolve?.(); this.importResolve = undefined; }
      else {
        this.opened = true; this.busy = false; await this.store.save(book);
        this.changed(); if (this.config.enabled || this.cloudEnabled()) this.sync('reconcile').catch(() => {});
      }
    } else if (event.type === 'error') {
      clearTimeout(this.openTimer);
      const error = new Error(event.requestId ? 'UNRESOLVED_POSITION' : event.message || 'READER_ERROR');
      if (this.importing) { this.importReject?.(error); return; }
      if (!this.opened) { this.reader?.cancel(); this.activeBook = undefined; }
      this.busy = false; this.blocked = true; throw error;
    } else if (event.type === 'closed') { this.closeResolve?.(); this.closeResolve = undefined; }
    else if (event.type === 'toggleControls') this.controls = !this.controls;
    else if (event.type === 'annotationsChanged' && event.annotations && !this.importing && this.opened) {
      if (!validAnnotations(event.annotations)) return;
      book.annotations = event.annotations;
      await this.store.save(book);
    }
    else if (event.type === 'readerAction' && event.action && ['library', 'settings', 'sync', 'share'].includes(event.action)) {
      this.readerAction(event.action);
    } else if (event.type === 'appearanceChanged' && event.settings) {
      const settings = event.settings;
      if (!validAppearanceEvent(settings as StoredAppearance) || !validTypography(migrateAppearance(settings as StoredAppearance)) || !Number.isFinite(settings.fontSize) || settings.fontSize < 1 || settings.fontSize > 120 ||
        !Number.isFinite(settings.lineHeight) || settings.lineHeight < 1 || settings.lineHeight > 3 ||
        !isThemeMode(settings.themeMode) || !isThemeColor(settings.themeColor)) return;
      await this.setAppearance(settings);
    }
    this.changed();
  }

  async sync(mode: string = 'upload'): Promise<void> {
    const book = this.activeBook;
    if (!book || !this.opened || !this.progressEnabled() || (this.blocked && mode === 'upload')) return;
    if (this.coordinatorScope !== this.scope()) {
      this.coordinator = undefined; this.coordinatorScope = this.scope(); book.syncScope = this.scope(); book.remoteToken = '';
      if (mode === 'upload') mode = 'reconcile';
    }
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
      const ko = this.config.enabled && this.config.userkey ? new KoSyncClient(this.config, new NativeTransport()) : undefined;
      this.coordinator = new ProgressCoordinator(this.cloudEnabled() ? new CombinedProgress(this.cloud, ko) : ko!, hooks);
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

  onForeground(): void { this.replica.sync().catch(() => {}); this.replica.refreshStorage().catch(() => {}); if (this.opened) { this.blocked = false; this.sync('reconcile').catch(() => {}); } }

  private onNetworkAvailable(): void {
    this.replica.sync().catch(() => {});
    if (this.opened && !this.conflict && !this.restoreFailed) { this.blocked = false; this.sync().catch(() => {}); }
  }

  dispose(): void {
    this.replica.dispose();
    clearTimeout(this.openTimer);
    this.onBackground(); this.epoch++; try { this.network?.unregister(() => {}); } catch {} this.reader?.cancel();
    this.changed = () => {}; if (AppController.current === this) AppController.current = undefined;
  }
}
