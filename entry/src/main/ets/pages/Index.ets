import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BookRecord, CustomFont, KoSyncSettings, ReaderSettings, ReaderChromeState, ThemeSettings } from '../core/Models';
import { numericSetting, setNumericSetting } from '../core/TypographyPolicy';
import { preferredFont } from '../core/AppearancePolicy';
import { BUILTIN_THEMES, ThemeDefinition, ThemePalette, themePalette, themeIsDark } from '../core/Themes';
import { AppWindow } from '../services/AppWindow';
import { AppController } from '../services/AppController';
import { errorMessage } from '../core/Errors';
import { ReaderGateway, READER_URL, BRIDGE_PERMISSION } from '../services/ReaderGateway';

class BridgeReceiver {
  private deliver: (value: string) => void;
  constructor(deliver: (value: string) => void) { this.deliver = deliver; }
  post(value: string): void { this.deliver(value); }
}

class ShelfPosition {
  percentage: number = 0;
  revision: number = 0;
}

class ShelfBook {
  id: string = '';
  title: string = '';
  author: string = '';
  filename: string = '';
  path: string = '';
  cover: string = '';
  lastOpenedAt: number = 0;
  position: ShelfPosition = new ShelfPosition();
}

class ShelfDataSource implements IDataSource {
  private items: ShelfBook[] = [];
  private listeners: DataChangeListener[] = [];
  totalCount(): number { return this.items.length; }
  getData(index: number): ShelfBook { return this.items[index]; }
  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) this.listeners.push(listener);
  }
  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listeners = this.listeners.filter((item: DataChangeListener) => item !== listener);
  }
  update(items: ShelfBook[]): void {
    this.items = items;
    for (const listener of this.listeners) listener.onDataReloaded();
  }
}

@Entry
@Component
struct Index {
  private web: webview.WebviewController = new webview.WebviewController();
  private app?: AppController;
  private gateway?: ReaderGateway;
  private receiver: BridgeReceiver = new BridgeReceiver((value: string) => this.gateway?.post(value));
  @State books: ShelfBook[] = [];
  @State reading: boolean = false;
  @State busy: boolean = false;
  @State controls: boolean = true;
  @State settingsOpen: boolean = false;
  @State chapter: string = '';
  @State progress: number = 0;
  @State status: string = 'idle';
  @State error: string = '';
  @State conflict: boolean = false;
  @State remotePercent: number = 0;
  @State remoteDevice: string = '';
  @State remoteChapter: string = '';
  @State server: string = 'https://sync.koreader.rocks';
  @State username: string = '';
  @State password: string = '';
  @State syncEnabled: boolean = true;
  @State syncConfigured: boolean = false;
  @State syncAccount: string = '';
  @State syncServer: string = '';
  @State expandedSyncServices: string[] = [];
  @State connecting: boolean = false;
  @State savingSyncOptions: boolean = false;
  @State deviceName: string = 'Readest';
  @State fontSize: number = 20;
  @State lineHeight: number = 1.7;
  @State typography: ReaderSettings = new ReaderSettings();
  @State numericDraft: Record<string, string> = {};
  @State fontSection: string = 'fonts';
  @State customFonts: CustomFont[] = [];
  @State importingFonts: boolean = false;
  @State fontPicker: string = '';
  @State appFontFamily: string = 'serif';
  @State language: string = 'auto';
  @State languageEpoch: number = 0;
  private translations: Record<string, string> = {};
  private resourceLanguage: string = '';
  private shelfSnapshot: string = '';
  private typographySnapshot: string = '';
  private chromeSnapshot: string = '';
  private shelfSource: ShelfDataSource = new ShelfDataSource();
  @State visibleCount: number = 0;
  @State replicaEmail: string = '';
  @State replicaPassword: string = '';
  @State replicaConnected: boolean = false;
  @State replicaAccount: string = '';
  @State replicaEnabled: boolean = true;
  @State replicaFonts: boolean = true;
  @State replicaBusy: boolean = false;
  @State replicaConnecting: boolean = false;
  @State replicaStatus: string = 'idle';
  @State replicaLastSynced: string = '';
  @State replicaError: string = '';
  @State storageUsage: string = '';
  @State storageAvailable: string = '';
  @State storageFiles: number = 0;
  @State storagePercent: number = 0;
  @State storageBusy: boolean = false;
  @State storageError: string = '';
  @State pendingCloudProgress: number = 0;
  @State theme: string = 'light';
  @State libraryThemeMode: string = 'auto';
  @State libraryThemeColor: string = 'default';
  @State readerThemeMode: string = 'auto';
  @State readerThemeColor: string = 'default';
  @State themeScope: string = 'library';
  @State systemDark: boolean = false;
  @State safeTop: number = 0;
  @State safeBottom: number = 0;
  @State initialized: boolean = false;
  @State confirmRemove: string = '';
  @State confirmFontRemove: string = '';
  @State query: string = '';
  @State viewMode: string = 'grid';
  @State sortBy: string = 'recent';
  @State viewMenu: boolean = false;
  @State settingsTab: string = 'font_layout';
  @State shelfWidth: number = 400;

  aboutToAppear(): void {
    this.app = new AppController(this.getUIContext().getHostContext() as common.UIAbilityContext);
    this.gateway = this.app.attach(this.web); this.app.changed = () => this.refresh();
    AppWindow.changed = () => this.refresh();
    this.app.readerAction = (action: string) => {
      if (action === 'library') this.run(() => this.app!.close());
      else if (action === 'settings') this.openSettings();
      else if (action === 'upload') this.run(() => this.app!.sync('manual-upload'));
      else if (action === 'reconcile') this.run(() => this.app!.sync('reconcile'));
    };
    this.app.init().then(() => {
      this.server = this.app!.config.serverUrl; this.username = this.app!.config.username;
      this.deviceName = this.app!.config.deviceName; this.syncEnabled = this.app!.config.enabled || !this.username;
      this.fontSize = this.app!.appearance.fontSize; this.lineHeight = this.app!.appearance.lineHeight;
      this.refresh();
    }).catch((error: Error) => { this.error = errorMessage(error); });
  }

  aboutToDisappear(): void { AppWindow.changed = () => {}; this.app?.dispose(); }
  onBackPress(): boolean {
    if (this.fontPicker) { this.fontPicker = ''; return true; }
    if (this.confirmFontRemove) { this.confirmFontRemove = ''; return true; }
    if (this.confirmRemove) { this.confirmRemove = ''; return true; }
    if (this.conflict) return true;
    if (this.settingsOpen) { this.settingsOpen = false; return true; }
    if (this.viewMenu) { this.viewMenu = false; return true; }
    if (this.reading) { this.run(() => this.gateway!.send(this.app!.command('back'))); return true; }
    return false;
  }

  private refresh(): void {
    if (!this.app) return;
    this.reading = !!this.app.activeBook && !this.app.importing; this.busy = this.app.busy;
    const locale = `${this.app.language}:${(this.getUIContext().getHostContext() as common.UIAbilityContext).config.language}`;
    if (locale !== this.resourceLanguage) { this.resourceLanguage = locale; this.translations = {}; this.languageEpoch++; }
    this.language = this.app.language;
    if (!this.reading) {
      const shelf = this.app.books.filter((book: BookRecord) => !book.cloudDeleted && (!!book.path || book.cloudAccount === this.app!.replica.config.userId))
        .map((book: BookRecord) => {
          const item = new ShelfBook(); item.id = book.id; item.title = book.title; item.author = book.author;
          item.filename = book.filename; item.path = book.path; item.cover = book.cover; item.lastOpenedAt = book.lastOpenedAt;
          item.position.percentage = book.position.percentage; item.position.revision = book.position.revision; return item;
        });
      const snapshot = JSON.stringify(shelf);
      if (snapshot !== this.shelfSnapshot) { this.shelfSnapshot = snapshot; this.books = shelf; this.updateShelf(); }
    }
    this.controls = this.app.controls;
    this.chapter = this.app.activeBook?.position.chapter || ''; this.progress = (this.app.activeBook?.position.percentage || 0) * 100;
    this.status = this.app.status; this.error = this.app.error;
    this.syncConfigured = !!this.app.config.userkey;
    this.syncAccount = this.app.config.username; this.syncServer = this.app.config.serverUrl;
    if (this.syncConfigured) this.syncEnabled = this.app.config.enabled;
    this.conflict = !!this.app.conflict; this.remotePercent = (this.app.conflictPreview?.percentage ?? this.app.conflict?.percentage ?? 0) * 100;
    this.remoteDevice = this.app.conflict?.device || this.t('remote'); this.remoteChapter = this.app.conflictPreview?.chapter || '';
    this.initialized = this.app.initialized && !!this.gateway?.ready;
    const appearance = this.reading ? this.app.activeAppearance : this.app.appearance;
    this.fontSize = appearance.fontSize; this.lineHeight = appearance.lineHeight;
    const typography = JSON.stringify(appearance);
    if (typography !== this.typographySnapshot) { this.typographySnapshot = typography; this.typography = JSON.parse(typography) as ReaderSettings; }
    const primary = this.app.fonts.nativeFamily(preferredFont(this.app.appearance));
    this.appFontFamily = this.app.appearance.defaultCJKFont ? `${this.app.appearance.defaultCJKFont},${primary}` : this.fontFamily(primary);
    if (this.customFonts.length !== this.app.fonts.fonts.length || this.customFonts.some((font: CustomFont, index: number) => font.id !== this.app!.fonts.fonts[index].id)) {
      this.customFonts = this.app.fonts.fonts.slice();
    }
    const replica = this.app.replica;
    this.replicaConnected = !!replica.config.userId; this.replicaAccount = replica.config.email;
    this.replicaEnabled = replica.config.enabled; this.replicaFonts = replica.config.syncFonts;
    this.replicaBusy = replica.busy; this.replicaStatus = replica.status; this.replicaError = replica.error;
    this.replicaLastSynced = replica.config.lastSyncedAt ? new Date(replica.config.lastSyncedAt).toLocaleString() : this.t('never_synced');
    this.storageBusy = replica.storageBusy; this.storageError = replica.storageError;
    this.pendingCloudProgress = replica.pendingProgress;
    this.storageUsage = replica.storage ? `${this.bytesLabel(replica.storage.usage)} / ${this.bytesLabel(replica.storage.quota)}` : '';
    this.storageAvailable = replica.storage ? this.bytesLabel(Math.max(0, replica.storage.quota - replica.storage.usage)) : '';
    this.storageFiles = replica.storage?.totalFiles || 0; this.storagePercent = Math.min(100, replica.storage?.usagePercentage || 0);
    this.libraryThemeMode = this.app.libraryTheme.themeMode; this.libraryThemeColor = this.app.libraryTheme.themeColor;
    this.readerThemeMode = this.app.appearance.themeMode; this.readerThemeColor = this.app.appearance.themeColor;
    this.systemDark = this.app.systemDark; this.theme = this.activeDark() ? 'dark' : 'light';
    this.safeTop = this.getUIContext().px2vp(AppWindow.topPx); this.safeBottom = this.getUIContext().px2vp(AppWindow.bottomPx);
    AppWindow.apply(this.bg(), this.fg(), this.activeDark());
    if (this.conflict) this.settingsOpen = false;
    if (this.reading && this.gateway?.ready) {
      const chrome = new ReaderChromeState(); chrome.controls = this.controls; chrome.syncEnabled = this.app.progressEnabled();
      chrome.busy = this.busy; chrome.status = this.t(`status_${this.status}`);
      const labels: Record<string, string> = { 'library': this.t('library'), 'toc': this.t('contents'), 'color': this.t('theme'), 'progress': this.t('reading_progress'),
        'font': this.t('font_layout'), 'menu': this.t('view_options'), 'close': this.t('dismiss'), 'previous': this.t('previous_page'), 'next': this.t('next_page'),
        'previousSection': this.t('previous_section'), 'nextSection': this.t('next_section'), 'historyBack': this.t('go_back'), 'historyForward': this.t('go_forward'),
        'decrease': this.t('decrease_font'), 'increase': this.t('increase_font'), 'fontSize': this.t('font_size'), 'lineHeight': this.t('line_height'),
        'light': this.t('theme_light'), 'dark': this.t('theme_dark'), 'settings': this.t('settings'),
        'upload': this.t('sync_now'), 'reconcile': this.t('check_remote'), 'auto': this.t('theme_system'), 'themeMode': this.t('theme_mode'), 'themeColor': this.t('theme_color'),
        'default': this.t('scheme_default'), 'gray': this.t('scheme_gray'), 'sepia': this.t('scheme_sepia'), 'grass': this.t('scheme_grass'),
        'cherry': this.t('scheme_cherry'), 'sky': this.t('scheme_sky'), 'solarized': this.t('scheme_solarized'), 'gruvbox': this.t('scheme_gruvbox'),
        'nord': this.t('scheme_nord'), 'contrast': this.t('scheme_contrast'), 'sunset': this.t('scheme_sunset') };
      chrome.labels = labels;
      labels["fontSize"] = this.t("font_size");
      labels["minimumFontSize"] = this.t("minimum_font_size");
      labels["fontWeight"] = this.t("font_weight");
      labels["lineHeight"] = this.t("line_height");
      labels["paragraphMargin"] = this.t("paragraph_margin");
      labels["wordSpacing"] = this.t("word_spacing");
      labels["letterSpacing"] = this.t("letter_spacing");
      labels["textIndent"] = this.t("text_indent");
      labels["marginTopPx"] = this.t("top_margin");
      labels["marginBottomPx"] = this.t("bottom_margin");
      labels["marginLeftPx"] = this.t("left_margin");
      labels["marginRightPx"] = this.t("right_margin");
      labels["gapPercent"] = this.t("additional_margin");
      labels["columnGapPx"] = this.t("column_gap");
      labels["maxColumnCount"] = this.t("max_columns");
      labels["maxInlineSize"] = this.t("max_column_width");
      labels["maxBlockSize"] = this.t("max_column_height");
      labels["overrideFont"] = this.t("override_book_font");
      labels["useBookLayout"] = this.t("use_book_layout");
      labels["fullJustification"] = this.t("full_justification");
      labels["hyphenation"] = this.t("hyphenation");
      labels["scrolled"] = this.t("scrolled_mode");
      labels["defaultFont"] = this.t("font_category");
      labels["serifFont"] = this.t("serif_font");
      labels["sansSerifFont"] = this.t("sans_serif_font");
      labels["monospaceFont"] = this.t("monospace_font");
      labels["defaultCJKFont"] = this.t("cjk_font");
      labels["manageFonts"] = this.t("manage_fonts");
      labels["fontSizes"] = this.t("font_size");
      labels["preferredFont"] = this.t("preferred_font");
      labels["paragraph"] = this.t("paragraph");
      labels["page"] = this.t("page");
      labels["fonts"] = this.t("fonts");
      labels["layout"] = this.t("layout");
      labels["serif"] = this.t("serif_font");
      labels["sans-serif"] = this.t("sans_serif_font");
      labels["monospace"] = this.t("monospace_font");
      labels["bookFont"] = this.t("book_font");
      chrome.safeTop = this.safeTop; chrome.safeBottom = this.safeBottom;
      const command = this.app.command('chrome'); command.chrome = chrome; command.systemDark = this.systemDark;
      const snapshot = JSON.stringify(chrome);
      if (snapshot !== this.chromeSnapshot) { this.chromeSnapshot = snapshot; this.gateway.send(command).catch(() => {}); }
    } else this.chromeSnapshot = '';
  }

  private t(key: string): string {
    const cached = `${this.languageEpoch}:${key}`;
    if (this.translations[cached] === undefined) this.translations[cached] = this.getUIContext().getHostContext()!.resourceManager.getStringByNameSync(key);
    return this.translations[cached];
  }
  private fontFamily(value: string): string { return this.app?.fonts.nativeFamily(value) || value || 'HarmonyOS Sans'; }
  private activeDark(): boolean { return themeIsDark(this.reading ? this.readerThemeMode : this.libraryThemeMode, this.systemDark); }
  private colors(): ThemePalette { return themePalette(this.reading ? this.readerThemeColor : this.libraryThemeColor, this.activeDark()); }
  private bg(): string { return this.reading ? this.colors().bg : this.colors().inset; }
  private fg(): string { return this.colors().fg; }
  private muted(): string { return this.colors().muted; }
  private surface(): string { return this.colors().bg; }
  private inset(): string { return this.colors().line; }
  private dividerTone(): string { return this.inset(); }
  private primary(): string { return this.colors().primary; }
  private primaryText(): string { return this.colors().primaryText; }
  private editedMode(): string { return this.themeScope === 'reader' ? this.readerThemeMode : this.libraryThemeMode; }
  private editedColor(): string { return this.themeScope === 'reader' ? this.readerThemeColor : this.libraryThemeColor; }
  private previewColors(name: string): ThemePalette { return themePalette(name, themeIsDark(this.editedMode(), this.systemDark)); }
  private openSettings(): void { this.themeScope = this.reading ? 'reader' : 'library'; this.settingsOpen = true; }
  private setTheme(mode: string, color: string): void {
    if (this.themeScope === 'reader') { this.readerThemeMode = mode; this.readerThemeColor = color; this.changeAppearance(); }
    else {
      this.libraryThemeMode = mode; this.libraryThemeColor = color;
      const settings = new ThemeSettings(); settings.themeMode = mode; settings.themeColor = color;
      this.run(() => this.app!.setLibraryTheme(settings));
    }
  }
  private columns(): string { return `repeat(${Math.min(8, Math.max(2, Math.floor((this.shelfWidth - 32) / 128)))}, 1fr)`; }
  private updateShelf(): void {
    const query = this.query.trim().toLocaleLowerCase();
    const visible = this.books.filter((book: ShelfBook) => `${book.title} ${book.author} ${book.filename}`.toLocaleLowerCase().includes(query))
      .sort((a: ShelfBook, b: ShelfBook) => this.sortBy === 'title' ? a.title.localeCompare(b.title) : b.lastOpenedAt - a.lastOpenedAt);
    this.visibleCount = visible.length; this.shelfSource.update(visible);
  }
  private selectBook(book: ShelfBook): void {
    const selected = this.app!.books.find((item: BookRecord) => item.id === book.id);
    if (selected && !this.busy) this.run(() => this.app!.open(selected));
  }
  private run(action: () => Promise<void>): void { action().catch((error: Error) => { if (this.app) this.app.error = errorMessage(error); this.error = errorMessage(error); }); }
  private changeAppearance(): void {
    const settings = JSON.parse(JSON.stringify(this.typography)) as ReaderSettings; settings.fontSize = this.fontSize; settings.lineHeight = this.lineHeight;
    settings.themeMode = this.readerThemeMode; settings.themeColor = this.readerThemeColor;
    this.run(() => this.app!.setAppearance(settings));
  }
  private connect(): void {
    const config = new KoSyncSettings(); config.serverUrl = this.server; config.username = this.username;
    config.password = this.password || this.app!.config.password; config.enabled = this.syncEnabled; config.deviceName = this.deviceName;
    this.connecting = true;
    this.app!.saveConfig(config).then(() => { this.password = ''; }).catch((error: Error) => { this.app!.error = errorMessage(error); })
      .finally(() => { this.connecting = false; this.refresh(); });
  }
  private saveSyncOptions(enabled: boolean): void {
    this.syncEnabled = enabled; this.savingSyncOptions = true;
    this.app!.updateSyncOptions(enabled, this.deviceName).catch((error: Error) => { this.app!.error = errorMessage(error); })
      .finally(() => { this.savingSyncOptions = false; this.refresh(); });
  }
  private disconnectSync(): void {
    this.savingSyncOptions = true;
    this.app!.disconnect().then(() => {
      this.username = ''; this.password = ''; this.server = this.app!.config.serverUrl;
      this.deviceName = this.app!.config.deviceName; this.syncEnabled = true;
    }).catch((error: Error) => { this.app!.error = errorMessage(error); })
      .finally(() => { this.savingSyncOptions = false; this.refresh(); });
  }
  private toggleSyncService(id: string): void {
    this.expandedSyncServices = this.expandedSyncServices.includes(id) ? this.expandedSyncServices.filter((item: string) => item !== id) : this.expandedSyncServices.concat(id);
  }
  private syncSummary(): string {
    if (!this.syncConfigured) return this.t('not_connected');
    return this.syncEnabled ? this.t('connected_as').replace('{account}', this.syncAccount) : `${this.syncAccount} · ${this.t('sync_paused')}`;
  }

  private setNumber(key: string, value: number): void {
    this.numericDraft = {};
    const settings = JSON.parse(JSON.stringify(this.typography)) as ReaderSettings;
    setNumericSetting(settings, key, value);
    if (key === 'minimumFontSize') settings.fontSize = Math.max(settings.fontSize, settings.minimumFontSize);
    if (key === 'fontSize') settings.fontSize = Math.max(settings.fontSize, settings.minimumFontSize);
    this.typography = settings; this.fontSize = settings.fontSize; this.lineHeight = settings.lineHeight; this.changeAppearance();
  }

  private draftNumber(key: string, value: string): void {
    const draft = JSON.parse(JSON.stringify(this.numericDraft)) as Record<string, string>; draft[key] = value; this.numericDraft = draft;
  }

  private commitNumber(key: string, min: number, max: number): void {
    const text = this.numericDraft[key];
    if (text !== undefined && text.trim() && Number(text) >= min && Number(text) <= max) this.setNumber(key, Number(text));
    else this.numericDraft = {};
  }

  private setFlag(key: string, value: boolean): void {
    const settings = JSON.parse(JSON.stringify(this.typography)) as ReaderSettings;
    if (key === 'overrideFont') settings.overrideFont = value;
    else if (key === 'useBookLayout') settings.useBookLayout = value;
    else if (key === 'fullJustification') settings.fullJustification = value;
    else if (key === 'hyphenation') settings.hyphenation = value;
    else if (key === 'scrolled') settings.scrolled = value;
    this.typography = settings; this.changeAppearance();
  }

  private selectedFont(key: string): string {
    if (key === 'defaultFont') return this.typography.defaultFont;
    if (key === 'serifFont') return this.typography.serifFont;
    if (key === 'sansSerifFont') return this.typography.sansSerifFont;
    if (key === 'monospaceFont') return this.typography.monospaceFont;
    return this.typography.defaultCJKFont;
  }

  private setFont(key: string, value: string): void {
    const settings = JSON.parse(JSON.stringify(this.typography)) as ReaderSettings;
    if (key === 'defaultFont') settings.defaultFont = value;
    else if (key === 'serifFont') settings.serifFont = value;
    else if (key === 'sansSerifFont') settings.sansSerifFont = value;
    else if (key === 'monospaceFont') settings.monospaceFont = value;
    else settings.defaultCJKFont = value;
    settings.overrideFont = true;
    if (key === 'serifFont') settings.defaultFont = 'serif';
    if (key === 'sansSerifFont') settings.defaultFont = 'sans-serif';
    this.typography = settings; this.changeAppearance();
  }

  private fontChoices(key: string): string[] {
    if (key === 'defaultFont') return ['serif', 'sans-serif'];
    const first = key === 'defaultCJKFont' ? '' : key === 'sansSerifFont' ? 'sans-serif' : key === 'monospaceFont' ? 'monospace' : 'serif';
    const choices: string[] = [first];
    for (const family of this.customFonts.map((font: CustomFont) => font.family).concat(this.app?.fonts.systemFonts || [])) {
      if (!choices.includes(family)) choices.push(family);
    }
    return choices;
  }

  private fontLabel(value: string): string {
    if (!value) return this.t('book_font');
    if (value === 'serif') return this.t('serif_font');
    if (value === 'sans-serif') return this.t('sans_serif_font');
    if (value === 'monospace') return this.t('monospace_font');
    return value;
  }

  private importFontFiles(): void {
    this.importingFonts = true;
    this.app!.importFonts().catch((error: Error) => { this.app!.error = errorMessage(error); })
      .finally(() => { this.importingFonts = false; this.refresh(); });
  }

  private connectReplica(): void {
    this.replicaConnecting = true;
    this.app!.replica.connect(this.replicaEmail, this.replicaPassword).then(() => { this.replicaPassword = ''; })
      .catch((error: Error) => { this.app!.replica.error = errorMessage(error); })
      .finally(() => { if (this.app!.replica.config.userId) this.replicaPassword = ''; this.replicaConnecting = false; this.refresh(); });
  }

  private saveReplicaOptions(enabled: boolean, fonts: boolean): void {
    this.replicaConnecting = true;
    this.app!.replica.options(enabled, fonts).catch((error: Error) => { this.app!.replica.error = errorMessage(error); })
      .finally(() => { this.replicaConnecting = false; this.refresh(); });
  }

  private bytesLabel(bytes: number): string {
    if (bytes >= 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
    if (bytes >= 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
    if (bytes >= 1024) return `${(bytes / 1024).toFixed(1)} KB`; return `${bytes} B`;
  }
  private errorText(): string { return this.localizedError(this.error); }
  private localizedError(value: string): string {
    const key = value.split(':')[0];
    const keys: string[] = ['AUTH_FAILED', 'HTTPS_REQUIRED', 'NOT_KOSYNC', 'CREDENTIALS_REQUIRED', 'CREDENTIALS_UNAVAILABLE',
      'DUPLICATE_BOOK', 'INVALID_EPUB', 'DRM_OR_ENCRYPTED', 'FIXED_LAYOUT_UNSUPPORTED', 'BOOK_TOO_LARGE', 'UNRESOLVED_POSITION',
      'IMPORT_TIMEOUT', 'READER_TIMEOUT', 'SERVER_ERROR', 'INVALID_PROGRESS', 'IMPORT_READ_FAILED', 'IMPORT_WRITE_FAILED', 'BOOK_NOT_FOUND',
      'NETWORK_TIMEOUT', 'NETWORK_DNS', 'NETWORK_TLS', 'NETWORK_ERROR', 'INVALID_FONT', 'INVALID_REPLICA', 'SYNC_QUOTA', 'SYNC_CLOCK'];
    return keys.includes(key) ? this.t(`error_${key.toLowerCase()}`) : this.t('error_generic');
  }

  @Builder
  icon(name: string, size: number = 20) {
    Image($rawfile(`icons/${name}${this.theme === 'dark' ? '-dark' : ''}.svg`)).width(size).height(size).objectFit(ImageFit.Contain)
  }

  @Builder
  iconButton(name: string, label: string, action: () => void, enabled: boolean = true) {
    Button({ type: ButtonType.Circle }) { this.icon(name) }
      .width(40).height(40).padding(10).backgroundColor(Color.Transparent).accessibilityText(label)
      .enabled(enabled).opacity(enabled ? 1 : 0.4).onClick(action)
  }

  @Builder
  sectionTitle(label: string) {
    Text(label).fontFamily(this.appFontFamily).fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.muted()).width('100%').margin({ bottom: 8, top: 20 })
  }

  @Builder
  rule() { Divider().color(this.dividerTone()).strokeWidth(0.5) }

  @Builder
  notice() {
    if (this.error) {
      Row({ space: 12 }) {
        Text(this.errorText()).fontFamily(this.appFontFamily).fontSize(13).fontColor('#913d35').layoutWeight(1)
        this.iconButton('close', this.t('dismiss'), () => { this.error = ''; this.app!.error = ''; })
      }.padding({ left: 16, right: 8, top: 4, bottom: 4 }).backgroundColor(this.theme === 'dark' ? '#4a2926' : '#f8e4dd').borderRadius(8).width('100%')
    }
  }

  @Builder
  appearanceControls() {
    Row() {
      ForEach(['fonts', 'layout'], (section: string) => {
        Button(this.t(section)).layoutWeight(1).height(36).fontFamily(this.appFontFamily).fontSize(14).fontColor(this.fg())
          .backgroundColor(this.fontSection === section ? this.inset() : Color.Transparent).borderRadius(20)
          .onClick(() => { this.fontSection = section; })
      })
    }.padding(2).width('100%').backgroundColor(this.surface()).borderRadius(24).margin({ bottom: 16 })
    if (this.fontSection === 'fonts') { this.fontControls() } else { this.layoutControls() }
  }

  @Builder
  numberSetting(key: string, label: string, min: number, max: number, step: number, enabled: boolean = true) {
    Row({ space: 8 }) {
      Text(this.t(label)).fontFamily(this.appFontFamily).fontSize(14).fontColor(this.fg()).layoutWeight(1)
      Row({ space: 0 }) {
        Button('−').width(32).height(32).padding(0).fontFamily(this.appFontFamily).fontSize(18).fontColor(this.fg()).backgroundColor(Color.Transparent)
          .enabled(enabled && numericSetting(this.typography, key) > min).accessibilityText(`${this.t('decrease_value')} ${this.t(label)}`)
          .onClick(() => this.setNumber(key, Math.max(min, Number((numericSetting(this.typography, key) - step).toFixed(2)))))
        TextInput({ text: this.numericDraft[key] !== undefined ? this.numericDraft[key] : `${Number(numericSetting(this.typography, key).toFixed(2))}` }).width(64).height(32).fontFamily(this.appFontFamily).fontSize(14)
          .type(min < 0 ? InputType.Normal : InputType.NUMBER_DECIMAL).textAlign(TextAlign.Center).fontColor(this.fg()).backgroundColor(Color.Transparent).enabled(enabled)
          .accessibilityText(this.t(label)).onSubmit((enterKey: EnterKeyType, event: SubmitEvent) => { const number = Number(event.text); if (event.text.trim() && number >= min && number <= max) this.setNumber(key, number); })
          .onChange((value: string) => this.draftNumber(key, value)).onEditChange((editing: boolean) => { if (!editing) this.commitNumber(key, min, max); })
        Button('+').width(32).height(32).padding(0).fontFamily(this.appFontFamily).fontSize(18).fontColor(this.fg()).backgroundColor(Color.Transparent)
          .enabled(enabled && numericSetting(this.typography, key) < max).accessibilityText(`${this.t('increase_value')} ${this.t(label)}`)
          .onClick(() => this.setNumber(key, Math.min(max, Number((numericSetting(this.typography, key) + step).toFixed(2)))))
      }.backgroundColor(this.inset()).borderRadius(8)
    }.width('100%').constraintSize({ minHeight: 56 }).padding({ left: 16, right: 12, top: 8, bottom: 8 }).opacity(enabled ? 1 : 0.45)
  }

  @Builder
  switchSetting(key: string, label: string, value: boolean, enabled: boolean = true) {
    Row({ space: 12 }) {
      Text(this.t(label)).fontFamily(this.appFontFamily).fontSize(14).fontColor(this.fg()).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: value }).selectedColor(this.primary()).enabled(enabled).accessibilityText(this.t(label))
        .onChange((checked: boolean) => this.setFlag(key, checked))
    }.width('100%').height(56).padding({ left: 16, right: 16 }).opacity(enabled ? 1 : 0.45)
  }

  @Builder
  fontSetting(key: string, label: string) {
    Row({ space: 8 }) {
      Text(this.t(label)).fontFamily(this.appFontFamily).fontSize(14).fontColor(this.fg()).layoutWeight(1)
      Button(this.fontLabel(this.selectedFont(key))).fontFamily(this.fontFamily(this.selectedFont(key)))
        .fontSize(13).fontColor(this.fg()).backgroundColor(Color.Transparent).width('56%')
        .accessibilityText(this.t(label)).onClick(() => { this.fontPicker = key; })
    }.width('100%').height(56).padding({ left: 16, right: 12 })
  }

  @Builder
  fontPickerPage() {
    Column() {
      Row() {
        Text(this.t('preferred_font')).fontFamily(this.appFontFamily).fontSize(16).fontColor(this.fg()).layoutWeight(1)
        this.iconButton('close', this.t('dismiss'), () => { this.fontPicker = ''; })
      }.width('100%').padding(12)
      List() {
        ForEach(this.fontChoices(this.fontPicker), (family: string) => {
          ListItem() {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 12 }) {
                Text(this.fontLabel(family)).fontFamily(this.fontFamily(family)).fontSize(16).fontColor(this.fg()).layoutWeight(1)
                if (family === this.selectedFont(this.fontPicker)) { Text('✓').fontFamily(this.appFontFamily).fontColor(this.primary()) }
              }.width('100%').padding(16)
            }.width('100%').padding(0).backgroundColor(Color.Transparent)
              .onClick(() => { this.setFont(this.fontPicker, family); this.fontPicker = ''; })
          }
        }, (family: string) => family)
      }.width('100%').layoutWeight(1)
    }.width('90%').height('70%').constraintSize({ maxWidth: 560, maxHeight: 640 }).backgroundColor(this.bg()).borderRadius(16)
  }

  @Builder
  languageControls() {
    Row({ space: 8 }) {
      Text(this.t('app_language')).fontFamily(this.appFontFamily).fontSize(14).fontColor(this.fg()).layoutWeight(1)
      Select([{ value: this.t('language_system') }, { value: 'English' }, { value: '简体中文' }])
        .selected(['auto', 'en', 'zh-Hans'].indexOf(this.language))
        .value(this.language === 'en' ? 'English' : this.language === 'zh-Hans' ? '简体中文' : this.t('language_system'))
        .font({ size: 13, family: this.appFontFamily }).optionFont({ size: 14, family: this.appFontFamily })
        .fontColor(this.fg()).backgroundColor(Color.Transparent)
        .onSelect((index: number) => this.run(() => this.app!.setLanguage(['auto', 'en', 'zh-Hans'][index])))
    }.width('100%').padding(16).backgroundColor(this.surface()).borderRadius(12)
  }

  @Builder
  fontControls() {
    Column() { this.switchSetting('overrideFont', 'override_book_font', this.typography.overrideFont) }
      .width('100%').backgroundColor(this.surface()).borderRadius(12).border({ width: 1, color: this.dividerTone() })
    this.sectionTitle(this.t('font_size'))
    Column() {
      this.numberSetting('fontSize', 'default_font_size', this.typography.minimumFontSize, 120, 1)
      this.rule()
      this.numberSetting('minimumFontSize', 'minimum_font_size', 1, 120, 1)
    }.width('100%').backgroundColor(this.surface()).borderRadius(12).border({ width: 1, color: this.dividerTone() })
    this.sectionTitle(this.t('font_weight'))
    Column() { this.numberSetting('fontWeight', 'font_weight', 100, 900, 100) }
      .width('100%').backgroundColor(this.surface()).borderRadius(12).border({ width: 1, color: this.dividerTone() })
    this.sectionTitle(this.t('preferred_font'))
    Column() {
      this.fontSetting('defaultFont', 'font_category'); this.rule()
      this.fontSetting('serifFont', 'serif_font'); this.rule()
      this.fontSetting('sansSerifFont', 'sans_serif_font'); this.rule()
      this.fontSetting('monospaceFont', 'monospace_font'); this.rule()
      this.fontSetting('defaultCJKFont', 'cjk_font')
    }.width('100%').backgroundColor(this.surface()).borderRadius(12).border({ width: 1, color: this.dividerTone() })
    this.sectionTitle(this.t('custom_fonts'))
    Column() {
      Row({ space: 12 }) {
        Text(this.t('manage_fonts')).fontFamily(this.appFontFamily).fontSize(14).fontColor(this.fg()).layoutWeight(1)
        Button(this.t('add_fonts')).height(36).fontFamily(this.appFontFamily).fontSize(13).fontColor(this.fg()).backgroundColor(this.inset()).borderRadius(8)
          .enabled(!this.importingFonts && !this.replicaBusy).onClick(() => this.importFontFiles())
      }.width('100%').padding(16)
      Text(this.t('font_formats')).fontFamily(this.appFontFamily).fontSize(12).fontColor(this.muted()).width('100%').padding({ left: 16, right: 16, bottom: 12 })
      ForEach(this.customFonts, (font: CustomFont) => {
        this.rule()
        Row({ space: 8 }) {
          Column({ space: 4 }) {
            Text(font.name).fontFamily(font.family).fontSize(16).fontColor(this.fg()).maxLines(1)
            Text(`${font.filename} · ${Math.round(font.byteSize / 1024)} KB`).fontFamily(this.appFontFamily).fontSize(11).fontColor(this.muted()).maxLines(1)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          this.iconButton('close', this.t('remove_font'), () => { this.confirmFontRemove = font.id; }, !this.replicaBusy && !this.importingFonts)
        }.width('100%').padding({ left: 16, right: 8, top: 8, bottom: 8 })
      }, (font: CustomFont) => font.id)
    }.width('100%').backgroundColor(this.surface()).borderRadius(12).border({ width: 1, color: this.dividerTone() })
  }

  @Builder
  layoutControls() {
    this.sectionTitle(this.t('reading_mode'))
    Column() { this.switchSetting('scrolled', 'scrolled_mode', this.typography.scrolled) }
      .width('100%').backgroundColor(this.surface()).borderRadius(12).border({ width: 1, color: this.dividerTone() })
    this.sectionTitle(this.t('paragraph'))
    Column() {
      this.switchSetting('useBookLayout', 'use_book_layout', this.typography.useBookLayout); this.rule()
      this.numberSetting('paragraphMargin', 'paragraph_margin', 0, 4, 0.1, !this.typography.useBookLayout); this.rule()
      this.numberSetting('lineHeight', 'line_height', 1, 3, 0.1, !this.typography.useBookLayout); this.rule()
      this.numberSetting('wordSpacing', 'word_spacing', -4, 8, 0.5, !this.typography.useBookLayout); this.rule()
      this.numberSetting('letterSpacing', 'letter_spacing', -2, 4, 0.5, !this.typography.useBookLayout); this.rule()
      this.numberSetting('textIndent', 'text_indent', -2, 4, 1, !this.typography.useBookLayout); this.rule()
      this.switchSetting('fullJustification', 'full_justification', this.typography.fullJustification, !this.typography.useBookLayout); this.rule()
      this.switchSetting('hyphenation', 'hyphenation', this.typography.hyphenation, !this.typography.useBookLayout)
    }.width('100%').backgroundColor(this.surface()).borderRadius(12).border({ width: 1, color: this.dividerTone() })
    this.sectionTitle(this.t('page'))
    Column() {
      this.numberSetting('marginTopPx', 'top_margin', 0, 144, 4); this.rule()
      this.numberSetting('marginBottomPx', 'bottom_margin', 0, 144, 4); this.rule()
      this.numberSetting('marginLeftPx', 'left_margin', 0, 144, 4); this.rule()
      this.numberSetting('marginRightPx', 'right_margin', 0, 144, 4); this.rule()
      this.numberSetting('gapPercent', 'additional_margin', 0, 30, 1); this.rule()
      this.numberSetting('columnGapPx', 'column_gap', 0, 200, 4, !this.typography.scrolled); this.rule()
      this.numberSetting('maxColumnCount', 'max_columns', 1, 4, 1, !this.typography.scrolled); this.rule()
      this.numberSetting('maxInlineSize', 'max_column_width', 200, 9999, 50); this.rule()
      this.numberSetting('maxBlockSize', 'max_column_height', 400, 9999, 50)
    }.width('100%').backgroundColor(this.surface()).borderRadius(12).border({ width: 1, color: this.dividerTone() })
  }

  @Builder
  themeControls() {
    Column({ space: 16 }) {
      Row() {
        ForEach(['library', 'reader'], (scope: string) => {
          Button(this.t(scope === 'library' ? 'library' : 'theme_reader')).layoutWeight(1).height(36).fontFamily(this.appFontFamily).fontSize(13).fontColor(this.fg())
            .borderRadius(20).backgroundColor(this.themeScope === scope ? this.inset() : Color.Transparent).onClick(() => { this.themeScope = scope; })
        })
      }.width('100%').padding(2).backgroundColor(this.surface()).borderRadius(24)
      Row({ space: 8 }) {
        Text(this.t('theme_mode')).fontFamily(this.appFontFamily).fontSize(14).fontColor(this.fg()).layoutWeight(1)
        Row() {
          ForEach(['auto', 'light', 'dark'], (mode: string) => {
            Button(this.t(mode === 'auto' ? 'theme_system' : `theme_${mode}`)).height(36).fontFamily(this.appFontFamily).fontSize(12).fontColor(this.fg()).padding({ left: 12, right: 12 })
              .borderRadius(20).backgroundColor(this.editedMode() === mode ? this.inset() : Color.Transparent)
              .onClick(() => { this.setTheme(mode, this.editedColor()); })
          })
        }.padding(2).backgroundColor(this.surface()).borderRadius(24)
      }.width('100%')
      Text(this.t('theme_color')).fontFamily(this.appFontFamily).fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.muted()).width('100%')
      ForEach([0, 3, 6, 9], (start: number) => {
        Row({ space: 16 }) {
          ForEach(BUILTIN_THEMES.slice(start, start + 3), (scheme: ThemeDefinition) => {
            Button({ type: ButtonType.Normal }) {
              Column({ space: 6 }) {
                Text('Aa').fontFamily(this.appFontFamily).fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.previewColors(scheme.name).fg)
                Text(this.t(`scheme_${scheme.name}`)).fontFamily(this.appFontFamily).fontSize(12).fontWeight(FontWeight.Medium)
                  .fontColor(this.previewColors(scheme.name).fg).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              }.width('100%').height(88).justifyContent(FlexAlign.Center).padding(8)
            }.layoutWeight(1).height(88).padding(0).borderRadius(8).backgroundColor(this.previewColors(scheme.name).bg)
              .border({ width: 2, color: this.editedColor() === scheme.name ? this.previewColors(scheme.name).fg : Color.Transparent })
              .shadow({ radius: 4, offsetY: 2, color: '#20000000' }).accessibilityText(this.t(`scheme_${scheme.name}`))
              .onClick(() => { this.setTheme(this.editedMode(), scheme.name); })
          }, (scheme: ThemeDefinition) => scheme.name)
          if (start === 9) { Blank().layoutWeight(1) }
        }.width('100%')
      })
    }.width('100%')
  }

  @Builder
  importCover() {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 14 }) {
        this.icon('plus', 32)
        Text(this.t('add_book')).fontFamily(this.appFontFamily).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.fg()).textAlign(TextAlign.Center)
      }.width('100%').height('100%').justifyContent(FlexAlign.Center).padding(12)
    }.width('100%').aspectRatio(28 / 41).padding(0).borderRadius(3).backgroundColor(this.surface())
      .border({ width: 1, color: this.dividerTone(), style: BorderStyle.Dashed })
      .accessibilityText(this.t('import')).enabled(this.initialized && !this.busy).onClick(() => { this.run(() => this.app!.importBooks()); })
  }

  @Builder
  library() {
    Column() {
      Row({ space: 8 }) {
        Row() {
          this.icon('search', 16)
          TextInput({ text: this.query, placeholder: this.t('search_books') }).layoutWeight(1).height(36)
            .fontFamily(this.appFontFamily).fontSize(14).fontColor(this.fg()).placeholderColor(this.muted()).backgroundColor(Color.Transparent)
            .onChange((value: string) => { this.query = value; this.updateShelf(); })
          if (this.query) { this.iconButton('close', this.t('clear_search'), () => { this.query = ''; this.updateShelf(); }) }
        }.layoutWeight(1).height(38).padding({ left: 12, right: 2 }).backgroundColor(this.inset()).borderRadius(24)
        this.iconButton('view', this.t('view_options'), () => { this.viewMenu = !this.viewMenu; })
        this.iconButton('menu', this.t('settings'), () => { this.viewMenu = false; this.openSettings(); })
      }.height(60).width('100%').padding({ left: 16, right: 12 })
      this.rule()
      Row() {
        Text(this.t('library')).fontFamily(this.appFontFamily).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.fg()).layoutWeight(1)
        Text(`${this.visibleCount} ${this.t('books')}`).fontFamily(this.appFontFamily).fontSize(12).fontColor(this.muted())
      }.height(48).width('100%').padding({ left: 24, right: 24 })
      if (this.error) { Column() { this.notice() }.padding({ left: 16, right: 16, bottom: 12 }).width('100%') }
      if (this.busy) {
        Row({ space: 10 }) { LoadingProgress().width(20).height(20).color(this.fg())
          Text(this.t('importing')).fontFamily(this.appFontFamily).fontSize(13).fontColor(this.muted()) }.height(44).width('100%').justifyContent(FlexAlign.Center)
      }
      if (!this.books.length) {
        Text(this.t('empty_description')).fontFamily(this.appFontFamily).fontSize(14).fontColor(this.muted()).width('100%').padding({ left: 24, right: 24, bottom: 20 })
      } else if (!this.visibleCount) {
        Text(this.t('no_results')).fontFamily(this.appFontFamily).fontSize(14).fontColor(this.muted()).width('100%').padding({ left: 24, right: 24, bottom: 20 })
      }
      if (this.viewMode === 'grid') {
        Grid() {
          GridItem() { Column({ space: 8 }) { this.importCover(); Text(this.t('import')).fontFamily(this.appFontFamily).fontSize(13).fontColor(this.muted()).width('100%') }.width('100%') }
          LazyForEach(this.shelfSource, (book: ShelfBook) => {
            GridItem() {
              Column({ space: 8 }) {
                Stack({ alignContent: Alignment.TopEnd }) {
                  if (book.cover) { Image(`file://${book.cover}`).width('100%').height('100%').objectFit(ImageFit.Cover) }
                  else {
                    Column({ space: 14 }) {
                      this.icon('book', 28)
                      Text(book.title).fontFamily(this.appFontFamily).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.fg()).textAlign(TextAlign.Center).maxLines(4)
                      Text(book.author || this.t('unknown_author')).fontFamily(this.appFontFamily).fontSize(11).fontColor(this.muted()).textAlign(TextAlign.Center).maxLines(2)
                    }.padding(14).width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor(this.inset())
                  }
                }.width('100%').aspectRatio(28 / 41).borderRadius(3).clip(true)
                  .shadow({ radius: 4, offsetY: 2, color: '#20000000' }).onClick(() => this.selectBook(book))
                Row({ space: 4 }) {
                  Text(book.title).fontFamily(this.appFontFamily).fontSize(13).fontColor(this.fg()).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Button({ type: ButtonType.Circle }) { this.icon('dots', 16) }.width(24).height(24).padding(4).backgroundColor(Color.Transparent)
                    .accessibilityText(this.t('remove')).onClick(() => { this.confirmRemove = book.id; })
                }.width('100%')
                Text(book.author || this.t('unknown_author')).fontFamily(this.appFontFamily).fontSize(11).fontColor(this.muted()).maxLines(1).width('100%').textOverflow({ overflow: TextOverflow.Ellipsis })
                if (!book.path) { Text(this.t('cloud_download')).fontFamily(this.appFontFamily).fontSize(11).fontColor(this.primary()).width('100%') }
                Row({ space: 8 }) {
                  Progress({ value: book.position.percentage * 100, total: 100, type: ProgressType.Linear }).color(this.muted()).backgroundColor(this.inset()).height(2).layoutWeight(1)
                  Text(`${Math.round(book.position.percentage * 100)}%`).fontFamily(this.appFontFamily).fontSize(10).fontColor(this.muted())
                }.width('100%')
              }.width('100%').alignItems(HorizontalAlign.Start)
            }
          }, (book: ShelfBook) => JSON.stringify([book.id, book.title, book.author, book.path, book.cover, book.position.revision, book.position.percentage]))
        }.columnsTemplate(this.columns()).columnsGap(24).rowsGap(28).layoutWeight(1).width('100%').padding({ left: 24, right: 24, bottom: 24 })
      } else {
        List({ space: 0 }) {
          ListItem() {
            Row({ space: 16 }) {
              Column() { this.importCover() }.width(56)
              Text(this.t('import')).fontFamily(this.appFontFamily).fontSize(15).fontColor(this.fg()).layoutWeight(1)
            }.width('100%').padding({ top: 14, bottom: 14 }).onClick(() => { if (this.initialized && !this.busy) this.run(() => this.app!.importBooks()); })
          }
          LazyForEach(this.shelfSource, (book: ShelfBook) => {
            ListItem() {
              Row({ space: 16 }) {
                if (book.cover) { Image(`file://${book.cover}`).width(56).height(82).objectFit(ImageFit.Cover).borderRadius(3) }
                else { Column() { this.icon('book', 24) }.width(56).height(82).justifyContent(FlexAlign.Center).backgroundColor(this.inset()).borderRadius(3) }
                Column({ space: 6 }) {
                  Text(book.title).fontFamily(this.appFontFamily).fontSize(15).fontColor(this.fg()).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(book.author || this.t('unknown_author')).fontFamily(this.appFontFamily).fontSize(12).fontColor(this.muted()).maxLines(1)
                  if (!book.path) { Text(this.t('cloud_download')).fontFamily(this.appFontFamily).fontSize(11).fontColor(this.primary()) }
                  Text(`${Math.round(book.position.percentage * 100)}%`).fontFamily(this.appFontFamily).fontSize(11).fontColor(this.muted())
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                this.iconButton('dots', this.t('remove'), () => { this.confirmRemove = book.id; })
              }.padding({ top: 14, bottom: 14 }).width('100%').onClick(() => this.selectBook(book))
            }
          }, (book: ShelfBook) => JSON.stringify([book.id, book.title, book.author, book.path, book.cover, book.position.revision, book.position.percentage]))
        }.divider({ strokeWidth: 0.5, color: this.dividerTone() }).layoutWeight(1).width('100%').padding({ left: 24, right: 24 })
      }
    }.width('100%').height('100%').padding({ top: this.safeTop, bottom: this.safeBottom }).backgroundColor(this.bg()).accessibilityLevel(this.settingsOpen || !!this.confirmRemove ? 'no-hide-descendants' : 'auto')
      .onAreaChange((oldArea: Area, area: Area) => { this.shelfWidth = Number(area.width); })
  }

  @Builder
  syncInfoRow(label: string, value: string) {
    Row({ space: 12 }) {
      Text(label).fontFamily(this.appFontFamily).fontSize(14).fontColor(this.fg()).layoutWeight(1)
      Text(value).fontFamily(this.appFontFamily).fontSize(13).fontColor(this.muted()).width('60%').textAlign(TextAlign.End).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
    }.constraintSize({ minHeight: 56 }).width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  @Builder
  koSyncSettings() {
    Column() {
      if (this.syncConfigured) {
        Row({ space: 12 }) {
          Text(this.t('auto_sync')).fontFamily(this.appFontFamily).fontSize(14).fontColor(this.fg()).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.syncEnabled }).selectedColor(this.primary()).enabled(!this.savingSyncOptions)
            .onChange((value: boolean) => { this.saveSyncOptions(value); })
        }.height(56).width('100%').padding({ left: 16, right: 16 })
        this.rule()
        this.syncInfoRow(this.t('server_url'), this.syncServer)
        this.rule()
        this.syncInfoRow(this.t('sync_strategy'), this.t('ask_on_conflict'))
        this.rule()
        this.syncInfoRow(this.t('checksum_method'), this.t('file_content'))
        this.rule()
        Row({ space: 12 }) {
          Text(this.t('device_name')).fontFamily(this.appFontFamily).fontSize(14).fontColor(this.fg()).layoutWeight(1)
          TextInput({ text: this.deviceName }).width('60%').height(36).textAlign(TextAlign.End).fontFamily(this.appFontFamily).fontSize(13)
            .fontColor(this.fg()).backgroundColor(Color.Transparent).enabled(!this.savingSyncOptions)
            .onChange((value: string) => { this.deviceName = value; })
            .onEditChange((editing: boolean) => { if (!editing && !this.savingSyncOptions) this.saveSyncOptions(this.syncEnabled); })
        }.height(56).width('100%').padding({ left: 16, right: 16 })
        this.rule()
        Column({ space: 12 }) {
          Text(this.t('kosync_description')).fontFamily(this.appFontFamily).fontSize(12).fontColor(this.muted()).width('100%')
          Row({ space: 12 }) {
            Text(`${this.t('sync_status')}: ${this.t(`status_${this.status}`)}`).fontFamily(this.appFontFamily).fontSize(12).fontColor(this.muted()).layoutWeight(1)
            Button(this.t('disconnect')).height(40).fontFamily(this.appFontFamily).fontSize(13).fontColor(this.activeDark() ? '#ff9393' : '#913d35')
              .backgroundColor(Color.Transparent).borderRadius(8).enabled(!this.savingSyncOptions).onClick(() => this.disconnectSync())
          }.width('100%')
        }.padding(16).width('100%')
      } else {
        Column({ space: 16 }) {
          Text(this.t('kosync_connect_description')).fontFamily(this.appFontFamily).fontSize(13).fontColor(this.muted()).width('100%')
          Column({ space: 8 }) {
            Text(this.t('server_url')).fontFamily(this.appFontFamily).fontSize(12).fontColor(this.muted()).width('100%')
            TextInput({ text: this.server, placeholder: 'https://sync.koreader.rocks' }).fontFamily(this.appFontFamily).fontSize(14).fontColor(this.fg())
              .backgroundColor(this.inset()).borderRadius(8).enabled(!this.connecting).onChange((value: string) => { this.server = value; })
          }.width('100%')
          Column({ space: 8 }) {
            Text(this.t('username')).fontFamily(this.appFontFamily).fontSize(12).fontColor(this.muted()).width('100%')
            TextInput({ text: this.username, placeholder: this.t('username') }).fontFamily(this.appFontFamily).fontSize(14).fontColor(this.fg())
              .backgroundColor(this.inset()).borderRadius(8).enabled(!this.connecting).onChange((value: string) => { this.username = value; })
          }.width('100%')
          Column({ space: 8 }) {
            Text(this.t('password')).fontFamily(this.appFontFamily).fontSize(12).fontColor(this.muted()).width('100%')
            TextInput({ text: this.password, placeholder: this.t('password') }).type(InputType.Password).fontFamily(this.appFontFamily).fontSize(14)
              .fontColor(this.fg()).backgroundColor(this.inset()).borderRadius(8).enabled(!this.connecting).onChange((value: string) => { this.password = value; })
          }.width('100%')
          Row() {
            Blank()
            if (this.connecting) { LoadingProgress().width(24).height(24).color(this.primary()).margin({ right: 12 }) }
            Button(this.t('connect_save')).height(40).fontFamily(this.appFontFamily).fontSize(14).backgroundColor(this.primary()).fontColor(this.primaryText()).borderRadius(8)
              .enabled(!this.connecting && !!this.server.trim() && !!this.username.trim() && !!this.password).onClick(() => this.connect())
          }.width('100%')
        }.padding(16).width('100%')
      }
    }.width('100%')
  }

  @Builder
  replicaSettings() {
    Column() {
      if (this.replicaConnected) {
        Row() {
          Text(this.t('enable_replica_sync')).fontFamily(this.appFontFamily).fontSize(14).fontColor(this.fg()).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.replicaEnabled }).selectedColor(this.primary()).enabled(!this.replicaConnecting)
            .onChange((value: boolean) => this.saveReplicaOptions(value, this.replicaFonts))
        }.width('100%').height(56).padding({ left: 16, right: 16 })
        this.rule()
        this.syncInfoRow(this.t('account'), this.replicaAccount)
        this.rule()
        this.syncInfoRow(this.t('replica_data'), this.t('replica_data_value'))
        this.rule()
        Row() {
          Column({ space: 4 }) {
            Text(this.t('fonts')).fontFamily(this.appFontFamily).fontSize(14).fontColor(this.fg())
            Text(this.t('replica_fonts_description')).fontFamily(this.appFontFamily).fontSize(12).fontColor(this.muted())
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Toggle({ type: ToggleType.Switch, isOn: this.replicaFonts }).selectedColor(this.primary()).enabled(!this.replicaConnecting)
            .onChange((value: boolean) => this.saveReplicaOptions(this.replicaEnabled, value))
        }.width('100%').padding(16)
        this.rule()
        this.syncInfoRow(this.t('last_synced'), this.replicaLastSynced)
        this.rule()
        Column({ space: 10 }) {
          Row() {
            Text(this.t('cloud_storage')).fontFamily(this.appFontFamily).fontSize(14).fontColor(this.fg()).layoutWeight(1)
            Button(this.t('refresh_storage')).fontFamily(this.appFontFamily).fontSize(12).fontColor(this.primary()).backgroundColor(Color.Transparent)
              .enabled(!this.storageBusy && !this.replicaConnecting).onClick(() => this.run(() => this.app!.replica.refreshStorage()))
          }.width('100%')
          if (this.storageUsage) {
            Text(this.storageUsage).fontFamily(this.appFontFamily).fontSize(14).fontColor(this.fg()).width('100%')
            Progress({ value: this.storagePercent, total: 100, type: ProgressType.Linear }).color(this.primary()).width('100%')
            Text(`${this.t('available_storage')}: ${this.storageAvailable} · ${this.storageFiles} ${this.t('storage_files')}`).fontFamily(this.appFontFamily).fontSize(12).fontColor(this.muted()).width('100%')
          } else { Text(this.t(this.storageBusy ? 'storage_loading' : 'storage_unavailable')).fontFamily(this.appFontFamily).fontSize(12).fontColor(this.muted()).width('100%') }
          if (this.storageError) { Text(this.localizedError(this.storageError)).fontFamily(this.appFontFamily).fontSize(12).fontColor(this.activeDark() ? '#ff9393' : '#913d35').width('100%') }
        }.padding(16).width('100%')
        this.rule()
        Column({ space: 8 }) {
          Text(this.t('replica_description')).fontFamily(this.appFontFamily).fontSize(12).fontColor(this.muted()).width('100%')
          Text(this.t(`replica_status_${this.replicaStatus}`)).fontFamily(this.appFontFamily).fontSize(12).fontColor(this.muted()).width('100%')
          if (this.pendingCloudProgress > 0) { Text(this.t('cloud_progress_pending').replace('{count}', `${this.pendingCloudProgress}`)).fontFamily(this.appFontFamily).fontSize(12).fontColor(this.muted()).width('100%') }
          Row({ space: 8 }) {
            Button(this.t('sync_replica_now')).height(40).fontFamily(this.appFontFamily).fontSize(13).fontColor(this.primaryText()).backgroundColor(this.primary()).borderRadius(8)
              .enabled(this.replicaEnabled && !this.replicaBusy && !this.replicaConnecting)
              .onClick(() => this.run(() => this.app!.replica.sync()))
            Blank()
            Button(this.t('disconnect')).height(40).fontFamily(this.appFontFamily).fontSize(13).fontColor(this.activeDark() ? '#ff9393' : '#913d35')
              .backgroundColor(Color.Transparent).borderRadius(8).enabled(!this.replicaConnecting)
              .onClick(() => {
                this.replicaConnecting = true;
                this.app!.replica.disconnect().catch((error: Error) => { this.app!.replica.error = errorMessage(error); })
                  .finally(() => { this.replicaConnecting = false; this.refresh(); });
              })
          }.width('100%')
        }.padding(16).width('100%')
      } else {
        Column({ space: 12 }) {
          Text(this.t('replica_connect_description')).fontFamily(this.appFontFamily).fontSize(13).fontColor(this.muted()).width('100%')
          TextInput({ text: this.replicaEmail, placeholder: this.t('email') }).type(InputType.Email).fontFamily(this.appFontFamily).fontSize(14).fontColor(this.fg())
            .backgroundColor(this.inset()).borderRadius(8).enabled(!this.replicaConnecting).onChange((value: string) => { this.replicaEmail = value; })
          TextInput({ text: this.replicaPassword, placeholder: this.t('password') }).type(InputType.Password).fontFamily(this.appFontFamily).fontSize(14).fontColor(this.fg())
            .backgroundColor(this.inset()).borderRadius(8).enabled(!this.replicaConnecting).onChange((value: string) => { this.replicaPassword = value; })
          Button(this.t(this.replicaConnecting ? 'connecting' : 'sign_in')).height(40).fontFamily(this.appFontFamily).fontSize(14).backgroundColor(this.primary()).fontColor(this.primaryText()).borderRadius(8)
            .enabled(!this.replicaConnecting && !!this.replicaEmail.trim() && !!this.replicaPassword).onClick(() => this.connectReplica())
        }.padding(16).width('100%')
      }
      if (this.replicaError) {
        Text(this.localizedError(this.replicaError)).fontFamily(this.appFontFamily).fontSize(12).fontColor(this.activeDark() ? '#ff9393' : '#913d35')
          .width('100%').padding({ left: 16, right: 16, bottom: 16 })
      }
    }.width('100%')
  }

  @Builder
  syncService(id: string, title: string, summary: string, icon: string) {
    Column() {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 12 }) {
          Stack() {
            if (id === 'readest') { Image($r('app.media.startIcon')).width(24).height(24).objectFit(ImageFit.Contain) }
            else { this.icon(icon, 20) }
          }.width(36).height(36).backgroundColor(this.inset()).borderRadius(18)
          Column({ space: 4 }) {
            Text(title).fontFamily(this.appFontFamily).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.fg()).width('100%')
            Text(summary).fontFamily(this.appFontFamily).fontSize(12).fontColor(this.muted()).width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Stack() { this.icon('back', 18) }.width(20).height(20).rotate({ angle: this.expandedSyncServices.includes(id) ? -90 : 180 })
        }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 }).constraintSize({ minHeight: 72 })
      }.width('100%').padding(0).backgroundColor(Color.Transparent).borderRadius(12)
        .accessibilityText(`${title}, ${summary}, ${this.t(this.expandedSyncServices.includes(id) ? 'collapse' : 'expand')}`).onClick(() => this.toggleSyncService(id))
      if (this.expandedSyncServices.includes(id)) {
        this.rule()
        if (id === 'kosync') { this.koSyncSettings() }
        if (id === 'readest') { this.replicaSettings() }
      }
    }.width('100%').backgroundColor(this.surface()).borderRadius(12).border({ width: 1, color: this.dividerTone() })
  }

  @Builder
  syncSettings() {
    this.sectionTitle(this.t('replica_syncing'))
    this.syncService('readest', this.t('readest_replica_sync'), this.replicaConnected ? this.t('connected_as').replace('{account}', this.replicaAccount) : this.t('not_connected'), 'integrations')
    this.sectionTitle(this.t('reading_sync'))
    this.syncService('kosync', this.t('kosync_title'), this.syncSummary(), 'book')
  }

  @Builder
  settingsPage() {
    Column() {
      Row() {
        Row().width(40)
        Text(this.t('settings')).fontFamily(this.appFontFamily).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.fg()).layoutWeight(1).textAlign(TextAlign.Center)
        this.iconButton('close', this.t('dismiss'), () => { this.settingsOpen = false; })
      }.width('100%').height(56).padding({ left: 12, right: 12 })
      Row({ space: 4 }) {
        ForEach(['font_layout', 'theme', 'integrations', 'about'], (tab: string) => {
          Button({ type: ButtonType.Normal }) {
            Row({ space: 6 }) {
              this.icon(tab, 18)
              if (this.shelfWidth > 500 || this.settingsTab === tab) { Text(this.t(tab)).fontFamily(this.appFontFamily).fontSize(12).fontColor(this.fg()) }
            }.padding({ left: 10, right: 10 })
          }.height(36).borderRadius(8).backgroundColor(this.settingsTab === tab ? this.inset() : Color.Transparent)
            .accessibilityText(this.t(tab)).onClick(() => { this.settingsTab = tab; })
        })
      }.width('100%').justifyContent(FlexAlign.Center).padding({ bottom: 12, left: 12, right: 12 })
      this.rule()
      Scroll() {
        Column() {
          this.notice()
          if (this.settingsTab === 'font_layout') {
            this.languageControls()
            this.sectionTitle(this.t('preview'))
            Column({ space: 16 }) {
              Text('Aa').fontSize(42).fontFamily(this.fontFamily(preferredFont(this.typography))).fontWeight(this.typography.fontWeight).fontColor(this.fg())
              Text(this.t('preview_text')).fontFamily(this.appFontFamily).fontSize(Math.min(36, this.fontSize)).lineHeight(Math.min(36, this.fontSize) * this.lineHeight)
                .fontFamily(this.appFontFamily)
                .fontWeight(this.typography.fontWeight).fontColor(this.fg()).textAlign(TextAlign.Center)
            }.padding(28).width('100%').backgroundColor(this.surface()).borderRadius(12).border({ width: 1, color: this.dividerTone() })
            this.sectionTitle(this.t('font_layout'))
            this.appearanceControls()
          } else if (this.settingsTab === 'theme') {
            this.sectionTitle(this.t('theme'))
            this.themeControls()
          } else if (this.settingsTab === 'integrations') {
            this.syncSettings()
          } else {
            this.sectionTitle(this.t('about'))
            Column({ space: 12 }) {
              Image($r('app.media.startIcon')).width(48).height(48).objectFit(ImageFit.Contain)
              Text('Readest').fontFamily(this.appFontFamily).fontSize(20).fontWeight(FontWeight.Medium).fontColor(this.fg())
              Text(this.t('about_description')).fontFamily(this.appFontFamily).fontSize(13).fontColor(this.muted()).textAlign(TextAlign.Center)
              Text(this.t('about_version')).fontFamily(this.appFontFamily).fontSize(12).fontColor(this.muted())
              Text(this.t('about_license')).fontFamily(this.appFontFamily).fontSize(11).fontColor(this.muted())
            }.padding(28).width('100%').backgroundColor(this.surface()).borderRadius(12).border({ width: 1, color: this.dividerTone() })
          }
        }.width('100%').constraintSize({ maxWidth: 640 }).padding({ left: 20, right: 20, bottom: 32 })
      }.layoutWeight(1).width('100%').align(Alignment.Top)
    }.width('92%').height('85%').constraintSize({ maxWidth: 720, maxHeight: 760 }).backgroundColor(this.bg()).borderRadius(16).clip(true)
      .border({ width: 1, color: this.dividerTone() }).shadow({ radius: 24, color: '#33000000' }).accessibilityText(this.t('settings'))
  }

  // Readest KOSyncResolver: source label and preview live inside the choice.
  @Builder
  syncSource(source: string, chapter: string, percentage: number, primary: boolean, action: () => void) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 4 }) {
        Text(source).fontFamily(this.appFontFamily).fontSize(12).fontWeight(FontWeight.Medium)
          .fontColor(primary ? this.primaryText() : this.muted()).opacity(primary ? 0.75 : 1).width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${chapter || this.t('reading')} · ${percentage.toFixed(1)}%`).fontFamily(this.appFontFamily).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(primary ? this.primaryText() : this.fg()).width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 16, right: 16, top: 14, bottom: 14 })
    }.width('100%').padding(0).borderRadius(12).backgroundColor(primary ? this.primary() : this.surface())
      .border({ width: primary ? 0 : 1, color: this.dividerTone() }).enabled(!this.busy)
      .accessibilityText(`${source}, ${chapter || this.t('reading')}, ${percentage.toFixed(1)}%`).onClick(action)
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        Web({ src: READER_URL, controller: this.web }).javaScriptAccess(true).domStorageAccess(false).fileAccess(false).onlineImageAccess(false)
        .javaScriptProxy({ object: this.receiver, name: 'HarmonyReader', methodList: ['post'], controller: this.web, permission: BRIDGE_PERMISSION })
        .onInterceptRequest((event) => this.gateway?.resource(event.request.getRequestUrl())!)
        .onLoadIntercept((event) => { const value = event.data.getRequestUrl(); return event.data.isMainFrame() && value !== READER_URL && value !== 'about:blank'; })
        .onConsole((event) => { hilog.info(0x0000, 'HarmonyReader', '%{public}s', event.message.getMessage().slice(0, 500)); return false; })
        .width('100%').layoutWeight(1).accessibilityLevel(this.settingsOpen || this.conflict ? 'no-hide-descendants' : 'auto')
      }.width('100%').height('100%')
      if (!this.reading) { this.library() }
      else {
        if (this.error) { Column() { this.notice() }.padding(16).align(Alignment.Top).margin({ top: 60 + this.safeTop }) }
        if (this.conflict) {
          Column().width('100%').height('100%').backgroundColor('#80000000')
          Column({ space: 10 }) {
            Text(this.t('conflict_title')).fontFamily(this.appFontFamily).fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.fg()).width('100%').textAlign(TextAlign.Center).margin({ bottom: 8 })
            Text(this.t('conflict_description')).fontFamily(this.appFontFamily).fontSize(14).fontColor(this.muted()).textAlign(TextAlign.Center).width('100%').margin({ bottom: 10 })
            this.syncSource(this.t('local'), this.chapter, this.progress, false, () => { this.run(() => this.app!.sync('keep-local')); })
            this.syncSource(this.remoteDevice, this.remoteChapter, this.remotePercent, true, () => { this.run(() => this.app!.sync('use-remote')); })
          }.padding(24).width('92%').constraintSize({ maxWidth: 560 }).backgroundColor(this.bg()).borderRadius(16).shadow({ radius: 24, color: '#33000000' })
        }
      }
      if (this.viewMenu && !this.reading) {
        Column({ space: 4 }) {
          Text(this.t('view_options')).fontFamily(this.appFontFamily).fontSize(12).fontColor(this.muted()).width('100%').padding({ left: 12, top: 8, bottom: 8 })
          ForEach(['grid', 'list'], (mode: string) => {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 12 }) {
                this.icon(mode, 18)
                Text(this.t(`view_${mode}`)).fontFamily(this.appFontFamily).fontSize(14).fontColor(this.fg()).layoutWeight(1)
                if (this.viewMode === mode) { Text('✓').fontFamily(this.appFontFamily).fontSize(14).fontColor(this.fg()) }
              }.width('100%').padding(12)
            }.width('100%').height(44).backgroundColor(this.viewMode === mode ? this.inset() : Color.Transparent).borderRadius(8)
              .onClick(() => { this.viewMode = mode; this.viewMenu = false; })
          })
          this.rule()
          ForEach(['recent', 'title'], (sort: string) => {
            Button({ type: ButtonType.Normal }) {
              Row() {
                Text(this.t(`sort_${sort}`)).fontFamily(this.appFontFamily).fontSize(14).fontColor(this.fg()).layoutWeight(1)
                if (this.sortBy === sort) { Text('✓').fontFamily(this.appFontFamily).fontSize(14).fontColor(this.fg()) }
              }.width('100%').padding(12)
            }.width('100%').height(44).backgroundColor(this.sortBy === sort ? this.inset() : Color.Transparent).borderRadius(8)
              .onClick(() => { this.sortBy = sort; this.updateShelf(); this.viewMenu = false; })
          })
        }.width(220).padding(8).backgroundColor(this.surface()).borderRadius(12).border({ width: 1, color: this.dividerTone() })
          .shadow({ radius: 12, color: '#20000000' }).align(Alignment.TopEnd).margin({ top: 56 + this.safeTop, right: 16 })
      }
      if (this.settingsOpen) {
        Column().width('100%').height('100%').backgroundColor('#80000000').onClick(() => { this.settingsOpen = false; })
        this.settingsPage()
      }
      if (this.fontPicker) {
        Column().width('100%').height('100%').backgroundColor('#80000000').onClick(() => { this.fontPicker = ''; })
        this.fontPickerPage()
      }
      if (this.confirmFontRemove) {
        Column().width('100%').height('100%').backgroundColor('#80000000').onClick(() => { this.confirmFontRemove = ''; })
        Column({ space: 18 }) {
          Text(this.t('remove_font_description')).fontFamily(this.appFontFamily).fontSize(16).fontColor(this.fg())
          Row({ space: 12 }) {
            Button(this.t('cancel')).onClick(() => { this.confirmFontRemove = ''; })
            Button(this.t('remove')).backgroundColor('#913d35').fontColor('#ffffff').onClick(() => {
              const id = this.confirmFontRemove; this.confirmFontRemove = ''; this.run(() => this.app!.removeFont(id));
            })
          }
        }.padding(24).width('90%').constraintSize({ maxWidth: 480 }).backgroundColor(this.bg()).borderRadius(16)
      }
      if (this.confirmRemove) {
        Column().width('100%').height('100%').backgroundColor('#80000000').onClick(() => { this.confirmRemove = ''; })
        Column({ space: 18 }) {
          Text(this.t('remove_description')).fontFamily(this.appFontFamily).fontSize(17).fontColor(this.fg())
          Row({ space: 12 }) { Button(this.t('cancel')).onClick(() => { this.confirmRemove = ''; })
            Button(this.t('remove')).backgroundColor('#913d35').onClick(() => { const book = this.app!.books.find((item: BookRecord) => item.id === this.confirmRemove);
              if (book) this.run(() => this.app!.remove(book)); this.confirmRemove = ''; }) }
          if (this.app?.cloudEnabled()) {
            Button(this.t('remove_cloud_book')).backgroundColor('#913d35').fontColor('#ffffff').onClick(() => {
              const book = this.app!.books.find((item: BookRecord) => item.id === this.confirmRemove);
              if (book) this.run(() => this.app!.removeCloud(book)); this.confirmRemove = '';
            })
            Text(this.t('remove_cloud_description')).fontFamily(this.appFontFamily).fontSize(12).fontColor(this.muted())
          }
        }.padding(24).width('90%').constraintSize({ maxWidth: 480 }).backgroundColor(this.bg()).borderRadius(16)
      }
      if (this.busy && this.reading) {
        Column({ space: 12 }) {
          LoadingProgress().width(32).height(32).color(this.fg())
          Text(this.t('opening')).fontFamily(this.appFontFamily).fontSize(13).fontColor(this.muted())
        }.padding(24).backgroundColor(this.surface()).borderRadius(12)
      }
    }.width(LayoutPolicy.matchParent).height(LayoutPolicy.matchParent).backgroundColor(this.bg()).ignoreLayoutSafeArea()
  }
}
