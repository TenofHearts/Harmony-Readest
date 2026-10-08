import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BookRecord, KoSyncSettings, ReaderSettings, TocEntry } from '../core/Models';
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
  @State screen: string = 'library';
  @State panel: string = '';
  @State title: string = '';
  @State chapter: string = '';
  @State progress: number = 0;
  @State status: string = 'idle';
  @State error: string = '';
  @State conflict: boolean = false;
  @State remotePercent: number = 0;
  @State remoteDevice: string = '';
  @State remoteChapter: string = '';
  @State toc: TocEntry[] = [];
  @State server: string = 'https://sync.koreader.rocks';
  @State username: string = '';
  @State password: string = '';
  @State syncEnabled: boolean = true;
  @State deviceName: string = 'HarmonyReadest';
  @State fontSize: number = 20;
  @State lineHeight: number = 1.7;
  @State theme: string = 'light';
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
    this.app.init().then(() => {
      this.server = this.app!.config.serverUrl; this.username = this.app!.config.username;
      this.deviceName = this.app!.config.deviceName; this.syncEnabled = this.app!.config.enabled || !this.username;
      this.fontSize = this.app!.appearance.fontSize; this.lineHeight = this.app!.appearance.lineHeight;
      this.theme = this.app!.appearance.theme; this.refresh();
    }).catch((error: Error) => { this.error = errorMessage(error); });
  }

  aboutToDisappear(): void { this.app?.dispose(); }
  onBackPress(): boolean {
    if (this.viewMenu) { this.viewMenu = false; return true; }
    if (this.panel) { this.panel = ''; return true; }
    if (this.reading) { this.run(() => this.app!.close()); return true; }
    if (this.screen !== 'library') { this.screen = 'library'; return true; }
    return false;
  }

  private refresh(): void {
    if (!this.app) return;
    this.books = this.app.books.map((book: BookRecord) => JSON.parse(JSON.stringify(book)) as BookRecord);
    this.reading = !!this.app.activeBook && !this.app.importing; this.busy = this.app.busy;
    this.controls = this.app.controls; this.title = this.app.activeBook?.title || '';
    this.chapter = this.app.activeBook?.position.chapter || ''; this.progress = (this.app.activeBook?.position.percentage || 0) * 100;
    this.toc = this.app.activeBook?.toc || []; this.status = this.app.status; this.error = this.app.error;
    this.conflict = !!this.app.conflict; this.remotePercent = (this.app.conflictPreview?.percentage ?? this.app.conflict?.percentage ?? 0) * 100;
    this.remoteDevice = this.app.conflict?.device || this.t('remote'); this.remoteChapter = this.app.conflictPreview?.chapter || '';
    this.initialized = this.app.initialized && !!this.gateway?.ready;
  }

  private t(key: string): string { return this.getUIContext().getHostContext()!.resourceManager.getStringByNameSync(key); }
  private bg(): string { return this.theme === 'dark' ? '#202020' : this.theme === 'sepia' ? '#f4ecd8' : '#f6f6f6'; }
  private fg(): string { return this.theme === 'dark' ? '#eeeeee' : '#242424'; }
  private muted(): string { return this.theme === 'dark' ? '#a8a8a8' : '#777777'; }
  private surface(): string { return this.theme === 'dark' ? '#2c2c2c' : this.theme === 'sepia' ? '#fff8e8' : '#ffffff'; }
  private inset(): string { return this.theme === 'dark' ? '#3c3c3c' : this.theme === 'sepia' ? '#e8dfcc' : '#e8e8e8'; }
  private dividerTone(): string { return this.theme === 'dark' ? '#383838' : this.theme === 'sepia' ? '#e5dcc9' : '#e5e5e5'; }
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
  private action(type: string): void { if (!this.busy) this.run(() => this.gateway!.send(this.app!.command(type))); }
  private changeAppearance(): void {
    const settings = new ReaderSettings(); settings.fontSize = this.fontSize; settings.lineHeight = this.lineHeight; settings.theme = this.theme;
    this.run(() => this.app!.setAppearance(settings));
  }
  private connect(): void {
    const config = new KoSyncSettings(); config.serverUrl = this.server; config.username = this.username;
    config.password = this.password || this.app!.config.password; config.enabled = this.syncEnabled; config.deviceName = this.deviceName;
    this.busy = true;
    this.app!.saveConfig(config).then(() => { this.password = ''; }).catch((error: Error) => { this.app!.error = errorMessage(error); })
      .finally(() => { this.busy = false; this.refresh(); });
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
    Row({ space: 12 }) {
      ForEach(['light', 'sepia', 'dark'], (value: string) => {
        Column({ space: 10 }) {
          Button({ type: ButtonType.Normal }) {
            Stack({ alignContent: Alignment.BottomEnd }) {
              Column({ space: 5 }) {
                Text('Aa').fontFamily('HarmonyOS Sans').fontSize(28).fontFamily('serif').fontColor(value === 'dark' ? '#eeeeee' : '#242424')
                Row().height(2).width(34).backgroundColor(value === 'dark' ? '#777777' : '#b0b0b0')
                Row().height(2).width(28).backgroundColor(value === 'dark' ? '#777777' : '#b0b0b0')
              }.width('100%').height('100%').justifyContent(FlexAlign.Center)
              if (this.theme === value) { Text('✓').fontFamily('HarmonyOS Sans').fontSize(12).fontColor(value === 'dark' ? '#eeeeee' : '#242424').margin(7) }
            }.width('100%').height(90)
          }.width('100%').padding(0).borderRadius(10).backgroundColor(value === 'dark' ? '#202020' : value === 'sepia' ? '#f4ecd8' : '#ffffff')
            .border({ width: this.theme === value ? 2 : 1, color: this.theme === value ? this.fg() : this.dividerTone() })
            .accessibilityText(this.t(`theme_${value}`)).onClick(() => { this.theme = value; this.changeAppearance(); })
          Text(this.t(`theme_${value}`)).fontFamily('HarmonyOS Sans').fontSize(13).fontColor(this.fg())
        }.layoutWeight(1)
      })
    }.width('100%').padding(16).backgroundColor(this.surface()).borderRadius(12).border({ width: 1, color: this.dividerTone() })
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
          Divider().vertical(true).height(16).color(this.muted()).margin({ left: 4, right: 4 })
          this.iconButton('plus', this.t('import'), () => { this.run(() => this.app!.importBooks()); }, this.initialized && !this.busy)
        }.layoutWeight(1).height(38).padding({ left: 12, right: 2 }).backgroundColor(this.inset()).borderRadius(24)
        this.iconButton('view', this.t('view_options'), () => { this.viewMenu = !this.viewMenu; })
        this.iconButton('menu', this.t('settings'), () => { this.viewMenu = false; this.screen = 'settings'; })
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
        Column({ space: 14 }) {
          this.icon('book', 56)
          Text(this.t('empty_title')).fontFamily('HarmonyOS Sans').fontSize(20).fontWeight(FontWeight.Medium).fontColor(this.fg())
          Text(this.t('empty_description')).fontFamily('HarmonyOS Sans').fontSize(14).fontColor(this.muted()).textAlign(TextAlign.Center).constraintSize({ maxWidth: 320 })
          Button(this.t('import_first')).fontFamily('HarmonyOS Sans').fontSize(14).height(40).backgroundColor(this.fg()).fontColor(this.surface())
            .margin({ top: 8 }).enabled(this.initialized && !this.busy).onClick(() => { this.run(() => this.app!.importBooks()); })
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center).padding({ left: 24, right: 24, bottom: 80 })
      } else if (!this.visibleBooks().length) {
        Column({ space: 12 }) {
          this.icon('search', 40)
          Text(this.t('no_results')).fontFamily('HarmonyOS Sans').fontSize(16).fontColor(this.muted())
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else if (this.viewMode === 'grid') {
        Grid() {
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
    }.width('100%').height('100%').backgroundColor(this.bg()).onAreaChange((oldArea: Area, area: Area) => { this.shelfWidth = Number(area.width); })
  }

  @Builder
  settingsPage() {
    Column() {
      Row() {
        this.iconButton('back', this.t('library'), () => { this.screen = 'library'; })
        Text(this.t('settings')).fontFamily('HarmonyOS Sans').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.fg()).layoutWeight(1).textAlign(TextAlign.Center)
        Row().width(40)
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
            this.sectionTitle(this.t('kosync_title'))
            Column() {
              Row({ space: 12 }) {
                this.icon('integrations')
                Text(this.t('auto_sync')).fontFamily('HarmonyOS Sans').fontSize(14).fontColor(this.fg()).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.syncEnabled }).selectedColor(this.fg()).onChange((value: boolean) => { this.syncEnabled = value; })
              }.height(60).width('100%').padding({ left: 16, right: 16 })
              this.rule()
              Column({ space: 8 }) {
                Text(this.t('server_url')).fontFamily('HarmonyOS Sans').fontSize(12).fontColor(this.muted()).width('100%')
                TextInput({ text: this.server, placeholder: 'https://sync.koreader.rocks' }).fontFamily('HarmonyOS Sans').fontSize(14).fontColor(this.fg()).backgroundColor(this.inset()).borderRadius(8)
                  .onChange((value: string) => { this.server = value; })
              }.padding(16).width('100%')
              this.rule()
              Column({ space: 8 }) {
                Text(this.t('username')).fontFamily('HarmonyOS Sans').fontSize(12).fontColor(this.muted()).width('100%')
                TextInput({ text: this.username, placeholder: this.t('username') }).fontFamily('HarmonyOS Sans').fontSize(14).fontColor(this.fg()).backgroundColor(this.inset()).borderRadius(8)
                  .onChange((value: string) => { this.username = value; })
              }.padding(16).width('100%')
              this.rule()
              Column({ space: 8 }) {
                Text(this.t('password')).fontFamily('HarmonyOS Sans').fontSize(12).fontColor(this.muted()).width('100%')
                TextInput({ text: this.password, placeholder: this.t(this.app?.config.userkey ? 'password_unchanged' : 'password') }).type(InputType.Password)
                  .fontFamily('HarmonyOS Sans').fontSize(14).fontColor(this.fg()).backgroundColor(this.inset()).borderRadius(8).onChange((value: string) => { this.password = value; })
              }.padding(16).width('100%')
              this.rule()
              Column({ space: 8 }) {
                Text(this.t('device_name')).fontFamily('HarmonyOS Sans').fontSize(12).fontColor(this.muted()).width('100%')
                TextInput({ text: this.deviceName }).fontFamily('HarmonyOS Sans').fontSize(14).fontColor(this.fg()).backgroundColor(this.inset()).borderRadius(8)
                  .onChange((value: string) => { this.deviceName = value; })
              }.padding(16).width('100%')
            }.width('100%').backgroundColor(this.surface()).borderRadius(12).border({ width: 1, color: this.dividerTone() })
            Text(this.t('kosync_description')).fontFamily('HarmonyOS Sans').fontSize(12).fontColor(this.muted()).width('100%').padding({ left: 4, right: 4, top: 12, bottom: 16 })
            Button(this.t('connect_save')).height(40).fontFamily('HarmonyOS Sans').fontSize(14).backgroundColor(this.fg()).fontColor(this.surface()).enabled(!this.busy).onClick(() => this.connect())
            if (this.busy) { LoadingProgress().width(24).height(24).margin({ top: 12 }) }
            Text(`${this.t('sync_status')}: ${this.t(`status_${this.status}`)}`).fontFamily('HarmonyOS Sans').fontSize(12).fontColor(this.muted()).margin({ top: 12 })
            if (this.app?.config.userkey) { Button(this.t('disconnect')).fontFamily('HarmonyOS Sans').fontSize(12).backgroundColor(Color.Transparent).fontColor(this.fg()).margin({ top: 8 })
              .onClick(() => { this.run(() => this.app!.disconnect()); this.password = ''; }) }
          } else {
            this.sectionTitle(this.t('about'))
            Column({ space: 12 }) {
              this.icon('book', 36)
              Text('HarmonyReadest').fontFamily('HarmonyOS Sans').fontSize(20).fontWeight(FontWeight.Medium).fontColor(this.fg())
              Text(this.t('about_description')).fontFamily('HarmonyOS Sans').fontSize(13).fontColor(this.muted()).textAlign(TextAlign.Center)
              Text(this.t('offline_footer')).fontFamily('HarmonyOS Sans').fontSize(12).fontColor(this.muted())
            }.padding(28).width('100%').backgroundColor(this.surface()).borderRadius(12).border({ width: 1, color: this.dividerTone() })
          }
        }.width('100%').constraintSize({ maxWidth: 640 }).padding({ left: 20, right: 20, bottom: 32 })
      }.layoutWeight(1).width('100%').align(Alignment.Top)
    }.width('100%').height('100%').backgroundColor(this.bg())
  }

  @Builder
  readerControls() {
    Column() {
      Row({ space: 6 }) {
        Button('‹').fontFamily('HarmonyOS Sans').fontSize(26).backgroundColor(Color.Transparent).fontColor(this.fg()).onClick(() => { this.panel = ''; this.run(() => this.app!.close()); })
        Text(this.title).fontFamily('HarmonyOS Sans').fontSize(16).fontColor(this.fg()).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        Button(this.t('contents')).fontFamily('HarmonyOS Sans').fontSize(12).backgroundColor(Color.Transparent).fontColor(this.fg()).onClick(() => { this.panel = this.panel === 'toc' ? '' : 'toc'; })
        Button('Aa').backgroundColor(Color.Transparent).fontColor(this.fg()).onClick(() => { this.panel = this.panel === 'appearance' ? '' : 'appearance'; })
      }.height(56).width('100%').backgroundColor(this.bg())
      Blank().layoutWeight(1).hitTestBehavior(HitTestMode.None)
      Column({ space: 6 }) {
        Row() { Text(this.chapter || this.t('reading')).fontFamily('HarmonyOS Sans').fontSize(11).fontColor(this.muted()).layoutWeight(1).maxLines(1)
          Text(`${Math.round(this.progress)}%`).fontFamily('HarmonyOS Sans').fontSize(12).fontColor(this.muted()) }.width('100%')
        Slider({ value: this.progress, min: 0, max: 100, step: .1 }).selectedColor('#356553')
          .onChange((value: number, mode: SliderChangeMode) => { if (mode === SliderChangeMode.End) {
            const command = this.app!.command('fraction'); command.percentage = value / 100; this.run(() => this.gateway!.send(command)); } })
        Row({ space: 8 }) {
          Button('‹').backgroundColor(Color.Transparent).fontColor(this.fg()).onClick(() => this.action('previous'))
          Text(this.t(`status_${this.status}`)).fontFamily('HarmonyOS Sans').fontSize(11).fontColor(this.muted()).layoutWeight(1).textAlign(TextAlign.Center)
          Button(this.t('sync_now')).fontFamily('HarmonyOS Sans').fontSize(12).backgroundColor(Color.Transparent).fontColor(this.fg()).enabled(!!this.app?.config.enabled).onClick(() => { this.run(() => this.app!.sync('manual-upload')); })
          Button(this.t('check_remote')).fontFamily('HarmonyOS Sans').fontSize(12).backgroundColor(Color.Transparent).fontColor(this.fg()).enabled(!!this.app?.config.enabled).onClick(() => { this.run(() => this.app!.sync('reconcile')); })
          Button('›').backgroundColor(Color.Transparent).fontColor(this.fg()).onClick(() => this.action('next'))
        }.height(36).width('100%')
      }.padding({ left: 20, right: 20, top: 8, bottom: 12 }).width('100%').backgroundColor(this.bg())
    }.width('100%').height('100%').hitTestBehavior(HitTestMode.Transparent)
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        Web({ src: READER_URL, controller: this.web }).javaScriptAccess(true).domStorageAccess(false).fileAccess(false).onlineImageAccess(false)
        .javaScriptProxy({ object: this.receiver, name: 'HarmonyReader', methodList: ['post'], controller: this.web, permission: BRIDGE_PERMISSION })
        .onInterceptRequest((event) => this.gateway?.resource(event.request.getRequestUrl())!)
        .onLoadIntercept((event) => { const value = event.data.getRequestUrl(); return event.data.isMainFrame() && value !== READER_URL && value !== 'about:blank'; })
        .onConsole((event) => { hilog.info(0x0000, 'HarmonyReader', '%{public}s', event.message.getMessage().slice(0, 500)); return false; })
        .width('100%').layoutWeight(1)
      }.width('100%').height('100%')
      if (!this.reading) { if (this.screen === 'library') { this.library() } else { this.settingsPage() } }
      else {
        if (this.controls) { this.readerControls() }
        if (this.error) { Column() { this.notice() }.padding(16).align(Alignment.Top).margin({ top: 60 }) }
        if (this.panel) {
          Column({ space: 16 }) {
            Row() { Text(this.t(this.panel === 'toc' ? 'contents' : 'appearance')).fontFamily('HarmonyOS Sans').fontSize(20).fontColor(this.fg()).layoutWeight(1)
              Button('×').backgroundColor(Color.Transparent).fontColor(this.fg()).onClick(() => { this.panel = ''; }) }.width('100%')
            if (this.panel === 'appearance') { this.appearanceControls(); this.themeControls() }
            else { List({ space: 8 }) {
              ForEach(this.toc, (item: TocEntry, index: number) => { ListItem() {
                Text(item.label).fontFamily('HarmonyOS Sans').fontSize(15).fontColor(this.fg()).padding({ left: item.depth * 16, top: 12, bottom: 12 }).width('100%')
                  .onClick(() => { const command = this.app!.command('navigate'); command.href = item.href; this.run(() => this.gateway!.send(command)); this.panel = ''; })
              } }, (item: TocEntry, index: number) => `${index}:${item.href}`)
            }.height(320).width('100%') }
          }.padding(24).width('94%').constraintSize({ maxWidth: 560 }).backgroundColor(this.bg()).borderRadius(20).shadow({ radius: 24, color: '#33000000' })
        }
        if (this.conflict) {
          Column({ space: 16 }) {
            Text(this.t('conflict_title')).fontFamily('HarmonyOS Sans').fontSize(20).fontWeight(FontWeight.Medium).fontColor(this.fg())
            Text(this.t('conflict_description')).fontFamily('HarmonyOS Sans').fontSize(14).fontColor(this.muted())
            Text(`${this.t('local')}: ${this.chapter} · ${this.progress.toFixed(1)}%`).fontColor(this.fg())
            Text(`${this.remoteDevice}: ${this.remoteChapter} · ${this.remotePercent.toFixed(1)}%`).fontColor(this.fg())
            Row({ space: 12 }) { Button(this.t('keep_local')).onClick(() => { this.run(() => this.app!.sync('keep-local')); })
              Button(this.t('use_remote')).backgroundColor('#356553').onClick(() => { this.run(() => this.app!.sync('use-remote')); }) }
          }.padding(24).width('94%').constraintSize({ maxWidth: 560 }).backgroundColor(this.bg()).borderRadius(20)
        }
      }
      if (this.viewMenu && !this.reading && this.screen === 'library') {
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
          .shadow({ radius: 12, color: '#20000000' }).align(Alignment.TopEnd).margin({ top: 56, right: 16 })
      }
      if (this.confirmRemove) {
        Column({ space: 18 }) {
          Text(this.t('remove_description')).fontFamily('HarmonyOS Sans').fontSize(17).fontColor(this.fg())
          Row({ space: 12 }) { Button(this.t('cancel')).onClick(() => { this.confirmRemove = ''; })
            Button(this.t('remove')).backgroundColor('#913d35').onClick(() => { const book = this.app!.books.find((item: BookRecord) => item.id === this.confirmRemove);
              if (book) this.run(() => this.app!.remove(book)); this.confirmRemove = ''; }) }
        }.padding(24).width('90%').constraintSize({ maxWidth: 480 }).backgroundColor(this.bg()).borderRadius(20)
      }
      if (this.busy && this.reading) {
        Column({ space: 12 }) {
          LoadingProgress().width(32).height(32).color(this.fg())
          Text(this.t('opening')).fontFamily('HarmonyOS Sans').fontSize(13).fontColor(this.muted())
        }.padding(24).backgroundColor(this.surface()).borderRadius(12)
      }
    }.width('100%').height('100%').backgroundColor(this.bg())
  }
}
