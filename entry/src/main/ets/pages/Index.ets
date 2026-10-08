import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BookRecord, KoSyncSettings, ReaderSettings, ReaderChromeState, ThemeSettings } from '../core/Models';
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

@Entry
@Component
struct Index {
  private web: webview.WebviewController = new webview.WebviewController();
  private app?: AppController;
  private gateway?: ReaderGateway;
  private receiver: BridgeReceiver = new BridgeReceiver((value: string) => this.gateway?.post(value));
  @State books: BookRecord[] = [];
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
    if (this.confirmRemove) { this.confirmRemove = ''; return true; }
    if (this.conflict) return true;
    if (this.settingsOpen) { this.settingsOpen = false; return true; }
    if (this.viewMenu) { this.viewMenu = false; return true; }
    if (this.reading) { this.run(() => this.gateway!.send(this.app!.command('back'))); return true; }
    return false;
  }

  private refresh(): void {
    if (!this.app) return;
    this.books = this.app.books.map((book: BookRecord) => JSON.parse(JSON.stringify(book)) as BookRecord);
    this.reading = !!this.app.activeBook && !this.app.importing; this.busy = this.app.busy;
    this.controls = this.app.controls;
    this.chapter = this.app.activeBook?.position.chapter || ''; this.progress = (this.app.activeBook?.position.percentage || 0) * 100;
    this.status = this.app.status; this.error = this.app.error;
    this.syncConfigured = !!this.app.config.userkey;
    this.syncAccount = this.app.config.username; this.syncServer = this.app.config.serverUrl;
    if (this.syncConfigured) this.syncEnabled = this.app.config.enabled;
    this.conflict = !!this.app.conflict; this.remotePercent = (this.app.conflictPreview?.percentage ?? this.app.conflict?.percentage ?? 0) * 100;
    this.remoteDevice = this.app.conflict?.device || this.t('remote'); this.remoteChapter = this.app.conflictPreview?.chapter || '';
    this.initialized = this.app.initialized && !!this.gateway?.ready;
    this.fontSize = this.app.appearance.fontSize; this.lineHeight = this.app.appearance.lineHeight;
    this.libraryThemeMode = this.app.libraryTheme.themeMode; this.libraryThemeColor = this.app.libraryTheme.themeColor;
    this.readerThemeMode = this.app.appearance.themeMode; this.readerThemeColor = this.app.appearance.themeColor;
    this.systemDark = this.app.systemDark; this.theme = this.activeDark() ? 'dark' : 'light';
    this.safeTop = this.getUIContext().px2vp(AppWindow.topPx); this.safeBottom = this.getUIContext().px2vp(AppWindow.bottomPx);
    AppWindow.apply(this.bg(), this.fg(), this.activeDark());
    if (this.conflict) this.settingsOpen = false;
    if (this.reading && this.gateway?.ready) {
      const chrome = new ReaderChromeState(); chrome.controls = this.controls; chrome.syncEnabled = this.app.config.enabled;
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
      chrome.safeTop = this.safeTop; chrome.safeBottom = this.safeBottom;
      const command = this.app.command('chrome'); command.chrome = chrome; command.systemDark = this.systemDark;
      this.gateway.send(command).catch(() => {});
    }
  }

  private t(key: string): string { return this.getUIContext().getHostContext()!.resourceManager.getStringByNameSync(key); }
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
  private visibleBooks(): BookRecord[] {
    const query = this.query.trim().toLocaleLowerCase();
    return this.books.filter((book: BookRecord) => `${book.title} ${book.author} ${book.filename}`.toLocaleLowerCase().includes(query))
      .sort((a: BookRecord, b: BookRecord) => this.sortBy === 'title' ? a.title.localeCompare(b.title) : b.lastOpenedAt - a.lastOpenedAt);
  }
  private selectBook(book: BookRecord): void {
    const selected = this.app!.books.find((item: BookRecord) => item.id === book.id);
    if (selected && !this.busy) this.run(() => this.app!.open(selected));
  }
  private run(action: () => Promise<void>): void { action().catch((error: Error) => { if (this.app) this.app.error = errorMessage(error); this.error = errorMessage(error); }); }
  private changeAppearance(): void {
    const settings = new ReaderSettings(); settings.fontSize = this.fontSize; settings.lineHeight = this.lineHeight;
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
  private errorText(): string {
    const key = this.error.split(':')[0];
    const keys: string[] = ['AUTH_FAILED', 'HTTPS_REQUIRED', 'NOT_KOSYNC', 'CREDENTIALS_REQUIRED', 'CREDENTIALS_UNAVAILABLE',
      'DUPLICATE_BOOK', 'INVALID_EPUB', 'DRM_OR_ENCRYPTED', 'FIXED_LAYOUT_UNSUPPORTED', 'BOOK_TOO_LARGE', 'UNRESOLVED_POSITION',
      'IMPORT_TIMEOUT', 'READER_TIMEOUT', 'SERVER_ERROR', 'INVALID_PROGRESS', 'IMPORT_READ_FAILED', 'IMPORT_WRITE_FAILED', 'BOOK_NOT_FOUND',
      'NETWORK_TIMEOUT', 'NETWORK_DNS', 'NETWORK_TLS', 'NETWORK_ERROR'];
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
    Text(label).fontFamily('HarmonyOS Sans').fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.muted()).width('100%').margin({ bottom: 8, top: 20 })
  }

  @Builder
  rule() { Divider().color(this.dividerTone()).strokeWidth(0.5) }

  @Builder
  notice() {
    if (this.error) {
      Row({ space: 12 }) {
        Text(this.errorText()).fontFamily('HarmonyOS Sans').fontSize(13).fontColor('#913d35').layoutWeight(1)
        this.iconButton('close', this.t('dismiss'), () => { this.error = ''; this.app!.error = ''; })
      }.padding({ left: 16, right: 8, top: 4, bottom: 4 }).backgroundColor(this.theme === 'dark' ? '#4a2926' : '#f8e4dd').borderRadius(8).width('100%')
    }
  }

  @Builder
  appearanceControls() {
    Column() {
      Row({ space: 12 }) {
        Text(this.t('font_size')).fontFamily('HarmonyOS Sans').fontSize(14).fontColor(this.fg()).layoutWeight(1)
        Row({ space: 2 }) {
          Button('−').width(36).height(32).fontFamily('HarmonyOS Sans').fontSize(20).fontColor(this.fg()).backgroundColor(Color.Transparent)
            .accessibilityText(this.t('decrease_font')).enabled(this.fontSize > 12).onClick(() => { this.fontSize -= 2; this.changeAppearance(); })
          Text(`${this.fontSize}`).width(32).fontFamily('HarmonyOS Sans').fontSize(14).fontColor(this.fg()).textAlign(TextAlign.Center)
          Button('+').width(36).height(32).fontFamily('HarmonyOS Sans').fontSize(20).fontColor(this.fg()).backgroundColor(Color.Transparent)
            .accessibilityText(this.t('increase_font')).enabled(this.fontSize < 40).onClick(() => { this.fontSize += 2; this.changeAppearance(); })
        }.backgroundColor(this.inset()).borderRadius(8)
      }.width('100%').height(58).padding({ left: 16, right: 16 })
      this.rule()
      Column({ space: 4 }) {
        Row() { Text(this.t('line_height')).fontFamily('HarmonyOS Sans').fontSize(14).fontColor(this.fg()).layoutWeight(1)
          Text(this.lineHeight.toFixed(1)).fontFamily('HarmonyOS Sans').fontSize(14).fontColor(this.muted()) }.width('100%')
        Slider({ value: this.lineHeight, min: 1.2, max: 2.4, step: 0.1 }).selectedColor(this.fg()).trackColor(this.inset())
          .onChange((value: number, mode: SliderChangeMode) => { this.lineHeight = value; if (mode === SliderChangeMode.End) this.changeAppearance(); })
      }.padding(16).width('100%')
    }.width('100%').backgroundColor(this.surface()).borderRadius(12).border({ width: 1, color: this.dividerTone() })
  }

  @Builder
  themeControls() {
    Column({ space: 16 }) {
      Row() {
        ForEach(['library', 'reader'], (scope: string) => {
          Button(this.t(scope === 'library' ? 'library' : 'theme_reader')).layoutWeight(1).height(36).fontSize(13).fontColor(this.fg())
            .borderRadius(20).backgroundColor(this.themeScope === scope ? this.inset() : Color.Transparent).onClick(() => { this.themeScope = scope; })
        })
      }.width('100%').padding(2).backgroundColor(this.surface()).borderRadius(24)
      Row({ space: 8 }) {
        Text(this.t('theme_mode')).fontFamily('HarmonyOS Sans').fontSize(14).fontColor(this.fg()).layoutWeight(1)
        Row() {
          ForEach(['auto', 'light', 'dark'], (mode: string) => {
            Button(this.t(mode === 'auto' ? 'theme_system' : `theme_${mode}`)).height(36).fontSize(12).fontColor(this.fg()).padding({ left: 12, right: 12 })
              .borderRadius(20).backgroundColor(this.editedMode() === mode ? this.inset() : Color.Transparent)
              .onClick(() => { this.setTheme(mode, this.editedColor()); })
          })
        }.padding(2).backgroundColor(this.surface()).borderRadius(24)
      }.width('100%')
      Text(this.t('theme_color')).fontFamily('HarmonyOS Sans').fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.muted()).width('100%')
      ForEach([0, 3, 6, 9], (start: number) => {
        Row({ space: 16 }) {
          ForEach(BUILTIN_THEMES.slice(start, start + 3), (scheme: ThemeDefinition) => {
            Button({ type: ButtonType.Normal }) {
              Column({ space: 6 }) {
                Text('Aa').fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.previewColors(scheme.name).fg)
                Text(this.t(`scheme_${scheme.name}`)).fontFamily('HarmonyOS Sans').fontSize(12).fontWeight(FontWeight.Medium)
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
        Text(this.t('add_book')).fontFamily('HarmonyOS Sans').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.fg()).textAlign(TextAlign.Center)
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
            .fontFamily('HarmonyOS Sans').fontSize(14).fontColor(this.fg()).placeholderColor(this.muted()).backgroundColor(Color.Transparent)
            .onChange((value: string) => { this.query = value; })
          if (this.query) { this.iconButton('close', this.t('clear_search'), () => { this.query = ''; }) }
        }.layoutWeight(1).height(38).padding({ left: 12, right: 2 }).backgroundColor(this.inset()).borderRadius(24)
        this.iconButton('view', this.t('view_options'), () => { this.viewMenu = !this.viewMenu; })
        this.iconButton('menu', this.t('settings'), () => { this.viewMenu = false; this.openSettings(); })
      }.height(60).width('100%').padding({ left: 16, right: 12 })
      this.rule()
      Row() {
        Text(this.t('library')).fontFamily('HarmonyOS Sans').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.fg()).layoutWeight(1)
        Text(`${this.visibleBooks().length} ${this.t('books')}`).fontFamily('HarmonyOS Sans').fontSize(12).fontColor(this.muted())
      }.height(48).width('100%').padding({ left: 24, right: 24 })
      if (this.error) { Column() { this.notice() }.padding({ left: 16, right: 16, bottom: 12 }).width('100%') }
      if (this.busy) {
        Row({ space: 10 }) { LoadingProgress().width(20).height(20).color(this.fg())
          Text(this.t('importing')).fontFamily('HarmonyOS Sans').fontSize(13).fontColor(this.muted()) }.height(44).width('100%').justifyContent(FlexAlign.Center)
      }
      if (!this.books.length) {
        Text(this.t('empty_description')).fontFamily('HarmonyOS Sans').fontSize(14).fontColor(this.muted()).width('100%').padding({ left: 24, right: 24, bottom: 20 })
      } else if (!this.visibleBooks().length) {
        Text(this.t('no_results')).fontFamily('HarmonyOS Sans').fontSize(14).fontColor(this.muted()).width('100%').padding({ left: 24, right: 24, bottom: 20 })
      }
      if (this.viewMode === 'grid') {
        Grid() {
          GridItem() { Column({ space: 8 }) { this.importCover(); Text(this.t('import')).fontFamily('HarmonyOS Sans').fontSize(13).fontColor(this.muted()).width('100%') }.width('100%') }
          ForEach(this.visibleBooks(), (book: BookRecord) => {
            GridItem() {
              Column({ space: 8 }) {
                Stack({ alignContent: Alignment.TopEnd }) {
                  if (book.cover) { Image(`file://${book.cover}`).width('100%').height('100%').objectFit(ImageFit.Cover) }
                  else {
                    Column({ space: 14 }) {
                      this.icon('book', 28)
                      Text(book.title).fontFamily('HarmonyOS Sans').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.fg()).textAlign(TextAlign.Center).maxLines(4)
                      Text(book.author || this.t('unknown_author')).fontFamily('HarmonyOS Sans').fontSize(11).fontColor(this.muted()).textAlign(TextAlign.Center).maxLines(2)
                    }.padding(14).width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor(this.inset())
                  }
                }.width('100%').aspectRatio(28 / 41).borderRadius(3).clip(true)
                  .shadow({ radius: 4, offsetY: 2, color: '#20000000' }).onClick(() => this.selectBook(book))
                Row({ space: 4 }) {
                  Text(book.title).fontFamily('HarmonyOS Sans').fontSize(13).fontColor(this.fg()).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Button({ type: ButtonType.Circle }) { this.icon('dots', 16) }.width(24).height(24).padding(4).backgroundColor(Color.Transparent)
                    .accessibilityText(this.t('remove')).onClick(() => { this.confirmRemove = book.id; })
                }.width('100%')
                Text(book.author || this.t('unknown_author')).fontFamily('HarmonyOS Sans').fontSize(11).fontColor(this.muted()).maxLines(1).width('100%').textOverflow({ overflow: TextOverflow.Ellipsis })
                Row({ space: 8 }) {
                  Progress({ value: book.position.percentage * 100, total: 100, type: ProgressType.Linear }).color(this.muted()).backgroundColor(this.inset()).height(2).layoutWeight(1)
                  Text(`${Math.round(book.position.percentage * 100)}%`).fontFamily('HarmonyOS Sans').fontSize(10).fontColor(this.muted())
                }.width('100%')
              }.width('100%').alignItems(HorizontalAlign.Start)
            }
          }, (book: BookRecord) => `${book.id}:${book.position.revision}:${book.cover}`)
        }.columnsTemplate(this.columns()).columnsGap(24).rowsGap(28).layoutWeight(1).width('100%').padding({ left: 24, right: 24, bottom: 24 })
      } else {
        List({ space: 0 }) {
          ListItem() {
            Row({ space: 16 }) {
              Column() { this.importCover() }.width(56)
              Text(this.t('import')).fontFamily('HarmonyOS Sans').fontSize(15).fontColor(this.fg()).layoutWeight(1)
            }.width('100%').padding({ top: 14, bottom: 14 }).onClick(() => { if (this.initialized && !this.busy) this.run(() => this.app!.importBooks()); })
          }
          ForEach(this.visibleBooks(), (book: BookRecord) => {
            ListItem() {
              Row({ space: 16 }) {
                if (book.cover) { Image(`file://${book.cover}`).width(56).height(82).objectFit(ImageFit.Cover).borderRadius(3) }
                else { Column() { this.icon('book', 24) }.width(56).height(82).justifyContent(FlexAlign.Center).backgroundColor(this.inset()).borderRadius(3) }
                Column({ space: 6 }) {
                  Text(book.title).fontFamily('HarmonyOS Sans').fontSize(15).fontColor(this.fg()).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(book.author || this.t('unknown_author')).fontFamily('HarmonyOS Sans').fontSize(12).fontColor(this.muted()).maxLines(1)
                  Text(`${Math.round(book.position.percentage * 100)}%`).fontFamily('HarmonyOS Sans').fontSize(11).fontColor(this.muted())
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                this.iconButton('dots', this.t('remove'), () => { this.confirmRemove = book.id; })
              }.padding({ top: 14, bottom: 14 }).width('100%').onClick(() => this.selectBook(book))
            }
          }, (book: BookRecord) => `${book.id}:${book.position.revision}:${book.cover}`)
        }.divider({ strokeWidth: 0.5, color: this.dividerTone() }).layoutWeight(1).width('100%').padding({ left: 24, right: 24 })
      }
    }.width('100%').height('100%').padding({ top: this.safeTop, bottom: this.safeBottom }).backgroundColor(this.bg()).accessibilityLevel(this.settingsOpen || !!this.confirmRemove ? 'no-hide-descendants' : 'auto')
      .onAreaChange((oldArea: Area, area: Area) => { this.shelfWidth = Number(area.width); })
  }

  @Builder
  syncInfoRow(label: string, value: string) {
    Row({ space: 12 }) {
      Text(label).fontFamily('HarmonyOS Sans').fontSize(14).fontColor(this.fg()).layoutWeight(1)
      Text(value).fontFamily('HarmonyOS Sans').fontSize(13).fontColor(this.muted()).width('60%').textAlign(TextAlign.End).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
    }.constraintSize({ minHeight: 56 }).width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  @Builder
  koSyncSettings() {
    Column() {
      if (this.syncConfigured) {
        Row({ space: 12 }) {
          Text(this.t('auto_sync')).fontFamily('HarmonyOS Sans').fontSize(14).fontColor(this.fg()).layoutWeight(1)
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
          Text(this.t('device_name')).fontFamily('HarmonyOS Sans').fontSize(14).fontColor(this.fg()).layoutWeight(1)
          TextInput({ text: this.deviceName }).width('60%').height(36).textAlign(TextAlign.End).fontFamily('HarmonyOS Sans').fontSize(13)
            .fontColor(this.fg()).backgroundColor(Color.Transparent).enabled(!this.savingSyncOptions)
            .onChange((value: string) => { this.deviceName = value; })
            .onEditChange((editing: boolean) => { if (!editing && !this.savingSyncOptions) this.saveSyncOptions(this.syncEnabled); })
        }.height(56).width('100%').padding({ left: 16, right: 16 })
        this.rule()
        Column({ space: 12 }) {
          Text(this.t('kosync_description')).fontFamily('HarmonyOS Sans').fontSize(12).fontColor(this.muted()).width('100%')
          Row({ space: 12 }) {
            Text(`${this.t('sync_status')}: ${this.t(`status_${this.status}`)}`).fontFamily('HarmonyOS Sans').fontSize(12).fontColor(this.muted()).layoutWeight(1)
            Button(this.t('disconnect')).height(40).fontFamily('HarmonyOS Sans').fontSize(13).fontColor(this.activeDark() ? '#ff9393' : '#913d35')
              .backgroundColor(Color.Transparent).borderRadius(8).enabled(!this.savingSyncOptions).onClick(() => this.disconnectSync())
          }.width('100%')
        }.padding(16).width('100%')
      } else {
        Column({ space: 16 }) {
          Text(this.t('kosync_connect_description')).fontFamily('HarmonyOS Sans').fontSize(13).fontColor(this.muted()).width('100%')
          Column({ space: 8 }) {
            Text(this.t('server_url')).fontFamily('HarmonyOS Sans').fontSize(12).fontColor(this.muted()).width('100%')
            TextInput({ text: this.server, placeholder: 'https://sync.koreader.rocks' }).fontFamily('HarmonyOS Sans').fontSize(14).fontColor(this.fg())
              .backgroundColor(this.inset()).borderRadius(8).enabled(!this.connecting).onChange((value: string) => { this.server = value; })
          }.width('100%')
          Column({ space: 8 }) {
            Text(this.t('username')).fontFamily('HarmonyOS Sans').fontSize(12).fontColor(this.muted()).width('100%')
            TextInput({ text: this.username, placeholder: this.t('username') }).fontFamily('HarmonyOS Sans').fontSize(14).fontColor(this.fg())
              .backgroundColor(this.inset()).borderRadius(8).enabled(!this.connecting).onChange((value: string) => { this.username = value; })
          }.width('100%')
          Column({ space: 8 }) {
            Text(this.t('password')).fontFamily('HarmonyOS Sans').fontSize(12).fontColor(this.muted()).width('100%')
            TextInput({ text: this.password, placeholder: this.t('password') }).type(InputType.Password).fontFamily('HarmonyOS Sans').fontSize(14)
              .fontColor(this.fg()).backgroundColor(this.inset()).borderRadius(8).enabled(!this.connecting).onChange((value: string) => { this.password = value; })
          }.width('100%')
          Row() {
            Blank()
            if (this.connecting) { LoadingProgress().width(24).height(24).color(this.primary()).margin({ right: 12 }) }
            Button(this.t('connect_save')).height(40).fontFamily('HarmonyOS Sans').fontSize(14).backgroundColor(this.primary()).fontColor(this.primaryText()).borderRadius(8)
              .enabled(!this.connecting && !!this.server.trim() && !!this.username.trim() && !!this.password).onClick(() => this.connect())
          }.width('100%')
        }.padding(16).width('100%')
      }
    }.width('100%')
  }

  @Builder
  syncService(id: string, title: string, summary: string, icon: string) {
    Column() {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 12 }) {
          Stack() { this.icon(icon, 20) }.width(36).height(36).backgroundColor(this.inset()).borderRadius(18)
          Column({ space: 4 }) {
            Text(title).fontFamily('HarmonyOS Sans').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.fg()).width('100%')
            Text(summary).fontFamily('HarmonyOS Sans').fontSize(12).fontColor(this.muted()).width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Stack() { this.icon('back', 18) }.width(20).height(20).rotate({ angle: this.expandedSyncServices.includes(id) ? -90 : 180 })
        }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 }).constraintSize({ minHeight: 72 })
      }.width('100%').padding(0).backgroundColor(Color.Transparent).borderRadius(12)
        .accessibilityText(`${title}, ${summary}, ${this.t(this.expandedSyncServices.includes(id) ? 'collapse' : 'expand')}`).onClick(() => this.toggleSyncService(id))
      if (this.expandedSyncServices.includes(id)) {
        this.rule()
        if (id === 'kosync') { this.koSyncSettings() }
      }
    }.width('100%').backgroundColor(this.surface()).borderRadius(12).border({ width: 1, color: this.dividerTone() })
  }

  @Builder
  syncSettings() {
    this.sectionTitle(this.t('reading_sync'))
    this.syncService('kosync', this.t('kosync_title'), this.syncSummary(), 'book')
  }

  @Builder
  settingsPage() {
    Column() {
      Row() {
        Row().width(40)
        Text(this.t('settings')).fontFamily('HarmonyOS Sans').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.fg()).layoutWeight(1).textAlign(TextAlign.Center)
        this.iconButton('close', this.t('dismiss'), () => { this.settingsOpen = false; })
      }.width('100%').height(56).padding({ left: 12, right: 12 })
      Row({ space: 4 }) {
        ForEach(['font_layout', 'theme', 'integrations', 'about'], (tab: string) => {
          Button({ type: ButtonType.Normal }) {
            Row({ space: 6 }) {
              this.icon(tab, 18)
              if (this.shelfWidth > 500 || this.settingsTab === tab) { Text(this.t(tab)).fontFamily('HarmonyOS Sans').fontSize(12).fontColor(this.fg()) }
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
            this.sectionTitle(this.t('preview'))
            Column({ space: 16 }) {
              Text('Aa').fontFamily('HarmonyOS Sans').fontSize(42).fontFamily('serif').fontColor(this.fg())
              Text(this.t('preview_text')).fontFamily('HarmonyOS Sans').fontSize(this.fontSize).lineHeight(this.fontSize * this.lineHeight).fontFamily('serif').fontColor(this.fg()).textAlign(TextAlign.Center)
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
              Text('Readest').fontFamily('HarmonyOS Sans').fontSize(20).fontWeight(FontWeight.Medium).fontColor(this.fg())
              Text(this.t('about_description')).fontFamily('HarmonyOS Sans').fontSize(13).fontColor(this.muted()).textAlign(TextAlign.Center)
              Text(this.t('about_version')).fontFamily('HarmonyOS Sans').fontSize(12).fontColor(this.muted())
              Text(this.t('about_license')).fontFamily('HarmonyOS Sans').fontSize(11).fontColor(this.muted())
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
        Text(source).fontFamily('HarmonyOS Sans').fontSize(12).fontWeight(FontWeight.Medium)
          .fontColor(primary ? this.primaryText() : this.muted()).opacity(primary ? 0.75 : 1).width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${chapter || this.t('reading')} · ${percentage.toFixed(1)}%`).fontFamily('HarmonyOS Sans').fontSize(14).fontWeight(FontWeight.Medium)
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
            Text(this.t('conflict_title')).fontFamily('HarmonyOS Sans').fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.fg()).width('100%').textAlign(TextAlign.Center).margin({ bottom: 8 })
            Text(this.t('conflict_description')).fontFamily('HarmonyOS Sans').fontSize(14).fontColor(this.muted()).textAlign(TextAlign.Center).width('100%').margin({ bottom: 10 })
            this.syncSource(this.t('local'), this.chapter, this.progress, false, () => { this.run(() => this.app!.sync('keep-local')); })
            this.syncSource(this.remoteDevice, this.remoteChapter, this.remotePercent, true, () => { this.run(() => this.app!.sync('use-remote')); })
          }.padding(24).width('92%').constraintSize({ maxWidth: 560 }).backgroundColor(this.bg()).borderRadius(16).shadow({ radius: 24, color: '#33000000' })
        }
      }
      if (this.viewMenu && !this.reading) {
        Column({ space: 4 }) {
          Text(this.t('view_options')).fontFamily('HarmonyOS Sans').fontSize(12).fontColor(this.muted()).width('100%').padding({ left: 12, top: 8, bottom: 8 })
          ForEach(['grid', 'list'], (mode: string) => {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 12 }) {
                this.icon(mode, 18)
                Text(this.t(`view_${mode}`)).fontFamily('HarmonyOS Sans').fontSize(14).fontColor(this.fg()).layoutWeight(1)
                if (this.viewMode === mode) { Text('✓').fontFamily('HarmonyOS Sans').fontSize(14).fontColor(this.fg()) }
              }.width('100%').padding(12)
            }.width('100%').height(44).backgroundColor(this.viewMode === mode ? this.inset() : Color.Transparent).borderRadius(8)
              .onClick(() => { this.viewMode = mode; this.viewMenu = false; })
          })
          this.rule()
          ForEach(['recent', 'title'], (sort: string) => {
            Button({ type: ButtonType.Normal }) {
              Row() {
                Text(this.t(`sort_${sort}`)).fontFamily('HarmonyOS Sans').fontSize(14).fontColor(this.fg()).layoutWeight(1)
                if (this.sortBy === sort) { Text('✓').fontFamily('HarmonyOS Sans').fontSize(14).fontColor(this.fg()) }
              }.width('100%').padding(12)
            }.width('100%').height(44).backgroundColor(this.sortBy === sort ? this.inset() : Color.Transparent).borderRadius(8)
              .onClick(() => { this.sortBy = sort; this.viewMenu = false; })
          })
        }.width(220).padding(8).backgroundColor(this.surface()).borderRadius(12).border({ width: 1, color: this.dividerTone() })
          .shadow({ radius: 12, color: '#20000000' }).align(Alignment.TopEnd).margin({ top: 56 + this.safeTop, right: 16 })
      }
      if (this.settingsOpen) {
        Column().width('100%').height('100%').backgroundColor('#80000000').onClick(() => { this.settingsOpen = false; })
        this.settingsPage()
      }
      if (this.confirmRemove) {
        Column().width('100%').height('100%').backgroundColor('#80000000').onClick(() => { this.confirmRemove = ''; })
        Column({ space: 18 }) {
          Text(this.t('remove_description')).fontFamily('HarmonyOS Sans').fontSize(17).fontColor(this.fg())
          Row({ space: 12 }) { Button(this.t('cancel')).onClick(() => { this.confirmRemove = ''; })
            Button(this.t('remove')).backgroundColor('#913d35').onClick(() => { const book = this.app!.books.find((item: BookRecord) => item.id === this.confirmRemove);
              if (book) this.run(() => this.app!.remove(book)); this.confirmRemove = ''; }) }
        }.padding(24).width('90%').constraintSize({ maxWidth: 480 }).backgroundColor(this.bg()).borderRadius(16)
      }
      if (this.busy && this.reading) {
        Column({ space: 12 }) {
          LoadingProgress().width(32).height(32).color(this.fg())
          Text(this.t('opening')).fontFamily('HarmonyOS Sans').fontSize(13).fontColor(this.muted())
        }.padding(24).backgroundColor(this.surface()).borderRadius(12)
      }
    }.width(LayoutPolicy.matchParent).height(LayoutPolicy.matchParent).backgroundColor(this.bg()).ignoreLayoutSafeArea()
  }
}
