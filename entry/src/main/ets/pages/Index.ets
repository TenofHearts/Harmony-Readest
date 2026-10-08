import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { BookRecord, KoSyncSettings, ReaderSettings, TocEntry } from '../core/Models';
import { AppController } from '../services/AppController';
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

  aboutToAppear(): void {
    this.app = new AppController(this.getUIContext().getHostContext() as common.UIAbilityContext);
    this.gateway = this.app.attach(this.web); this.app.changed = () => this.refresh();
    this.app.init().then(() => {
      this.server = this.app!.config.serverUrl; this.username = this.app!.config.username;
      this.deviceName = this.app!.config.deviceName; this.syncEnabled = this.app!.config.enabled || !this.username;
      this.fontSize = this.app!.appearance.fontSize; this.lineHeight = this.app!.appearance.lineHeight;
      this.theme = this.app!.appearance.theme; this.refresh();
    }).catch((error: Error) => { this.error = error.message; });
  }

  aboutToDisappear(): void { this.app?.dispose(); }
  onBackPress(): boolean {
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
    this.conflict = !!this.app.conflict; this.remotePercent = (this.app.conflict?.percentage || 0) * 100;
    this.initialized = this.app.initialized && !!this.gateway?.ready;
  }

  private t(key: string): string { return this.getUIContext().getHostContext()!.resourceManager.getStringByNameSync(key); }
  private bg(): string { return this.theme === 'dark' ? '#192321' : this.theme === 'sepia' ? '#f1e5cf' : '#faf8f2'; }
  private fg(): string { return this.theme === 'dark' ? '#e3e8df' : '#252b29'; }
  private muted(): string { return this.theme === 'dark' ? '#b1bdb2' : '#718078'; }
  private run(action: () => Promise<void>): void { action().catch((error: Error) => { if (this.app) this.app.error = error.message; this.error = error.message; }); }
  private action(type: string): void { if (!this.busy) this.run(() => this.gateway!.send(this.app!.command(type))); }
  private changeAppearance(): void {
    const settings = new ReaderSettings(); settings.fontSize = this.fontSize; settings.lineHeight = this.lineHeight; settings.theme = this.theme;
    this.run(() => this.app!.setAppearance(settings));
  }
  private connect(): void {
    const config = new KoSyncSettings(); config.serverUrl = this.server; config.username = this.username;
    config.password = this.password || this.app!.config.password; config.enabled = this.syncEnabled; config.deviceName = this.deviceName;
    this.busy = true;
    this.app!.saveConfig(config).then(() => { this.password = ''; }).catch((error: Error) => { this.app!.error = error.message; })
      .finally(() => { this.busy = false; this.refresh(); });
  }
  private errorText(): string {
    const key = this.error.split(':')[0];
    const keys: string[] = ['AUTH_FAILED', 'HTTPS_REQUIRED', 'NOT_KOSYNC', 'CREDENTIALS_REQUIRED', 'CREDENTIALS_UNAVAILABLE',
      'DUPLICATE_BOOK', 'INVALID_EPUB', 'DRM_OR_ENCRYPTED', 'FIXED_LAYOUT_UNSUPPORTED', 'BOOK_TOO_LARGE', 'UNRESOLVED_POSITION',
      'IMPORT_TIMEOUT', 'READER_TIMEOUT', 'SERVER_ERROR', 'INVALID_PROGRESS'];
    return keys.includes(key) ? this.t(`error_${key.toLowerCase()}`) : this.t('error_generic');
  }

  @Builder
  notice() {
    if (this.error) {
      Row({ space: 12 }) {
        Text(this.errorText()).fontSize(13).fontColor('#913d35').layoutWeight(1)
        Button('×').backgroundColor(Color.Transparent).fontColor('#913d35').onClick(() => { this.error = ''; this.app!.error = ''; })
      }.padding(12).backgroundColor('#f8e4dd').borderRadius(12).width('100%')
    }
  }

  @Builder
  appearanceControls() {
    Column({ space: 16 }) {
      Row() {
        Text(`${this.t('font_size')} · ${this.fontSize}`).fontColor(this.fg()).layoutWeight(1)
        Button('A−').backgroundColor(Color.Transparent).fontColor(this.fg()).onClick(() => { this.fontSize = Math.max(12, this.fontSize - 2); this.changeAppearance(); })
        Button('A+').backgroundColor(Color.Transparent).fontColor(this.fg()).onClick(() => { this.fontSize = Math.min(40, this.fontSize + 2); this.changeAppearance(); })
      }.width('100%')
      Text(`${this.t('line_height')} · ${this.lineHeight.toFixed(1)}`).fontColor(this.fg()).width('100%')
      Slider({ value: this.lineHeight, min: 1.2, max: 2.4, step: 0.1 }).selectedColor('#356553')
        .onChange((value: number, mode: SliderChangeMode) => { this.lineHeight = value; if (mode === SliderChangeMode.End) this.changeAppearance(); })
      Row({ space: 8 }) {
        ForEach(['light', 'sepia', 'dark'], (value: string) => {
          Button(this.t(`theme_${value}`)).layoutWeight(1).backgroundColor(this.theme === value ? '#356553' : '#e3e8df')
            .fontColor(this.theme === value ? '#ffffff' : '#252b29').onClick(() => { this.theme = value; this.changeAppearance(); })
        })
      }.width('100%')
    }.width('100%')
  }

  @Builder
  library() {
    Column({ space: 20 }) {
      Row() {
        Column({ space: 4 }) {
          Text('HarmonyReadest').fontSize(26).fontWeight(FontWeight.Bold).fontColor(this.fg())
          Text(this.t('library_subtitle')).fontSize(13).fontColor(this.muted())
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button(this.t('settings')).backgroundColor(Color.Transparent).fontColor(this.fg()).onClick(() => { this.screen = 'settings'; })
      }.width('100%')
      Row() {
        Text(this.t('library')).fontSize(20).fontWeight(FontWeight.Medium).fontColor(this.fg()).layoutWeight(1)
        Text(`${this.books.length} ${this.t('books')}`).fontSize(13).fontColor(this.muted()).margin({ right: 12 })
        Button(this.t('import')).backgroundColor('#356553').enabled(this.initialized && !this.busy).onClick(() => { this.run(() => this.app!.importBooks()); })
      }.width('100%')
      this.notice()
      if (this.busy) { Row({ space: 12 }) { LoadingProgress().width(24).height(24); Text(this.t('importing')).fontColor(this.muted()) } }
      if (!this.books.length && !this.busy) {
        Column({ space: 18 }) {
          Text('▤').fontSize(68).fontColor('#356553')
          Text(this.t('empty_title')).fontSize(22).fontWeight(FontWeight.Medium).fontColor(this.fg())
          Text(this.t('empty_description')).fontSize(15).fontColor(this.muted()).textAlign(TextAlign.Center)
          Button(this.t('import_first')).backgroundColor('#356553').enabled(this.initialized).onClick(() => { this.run(() => this.app!.importBooks()); })
        }.layoutWeight(1).justifyContent(FlexAlign.Center).padding(28)
      } else {
        List({ space: 12 }) {
          ForEach(this.books, (book: BookRecord) => {
            ListItem() {
              Row({ space: 16 }) {
                if (book.cover) { Image(`file://${book.cover}`).width(68).height(94).objectFit(ImageFit.Cover).borderRadius(5) }
                else { Column() { Text('▤').fontSize(28).fontColor('#faf8f2') }.width(68).height(94).justifyContent(FlexAlign.Center).backgroundColor('#356553').borderRadius(5) }
                Column({ space: 7 }) {
                  Text(book.title).fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.fg()).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(book.author || this.t('unknown_author')).fontSize(13).fontColor(this.muted()).maxLines(1)
                  Progress({ value: book.position.percentage * 100, total: 100, type: ProgressType.Linear }).color('#356553').height(3).width('100%')
                  Text(`${Math.round(book.position.percentage * 100)}% · EPUB`).fontSize(11).fontColor(this.muted())
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                Button('⋯').backgroundColor(Color.Transparent).fontColor(this.fg()).width(36).onClick(() => { this.confirmRemove = book.id; })
              }.padding(14).width('100%').backgroundColor(this.theme === 'dark' ? '#23332c' : '#f0f1e9').borderRadius(14)
                .onClick(() => { const selected = this.app!.books.find((item: BookRecord) => item.id === book.id); if (selected) this.run(() => this.app!.open(selected)); })
            }
          }, (book: BookRecord) => `${book.id}:${book.lastOpenedAt}:${book.position.revision}:${book.cover}`)
        }.layoutWeight(1).width('100%')
      }
      Text(this.t('offline_footer')).fontSize(12).fontColor(this.muted())
    }.padding(24).width('100%').height('100%').backgroundColor(this.bg())
  }

  @Builder
  settingsPage() {
    Column({ space: 18 }) {
      Row({ space: 12 }) {
        Button('‹').fontSize(26).backgroundColor(Color.Transparent).fontColor(this.fg()).onClick(() => { this.screen = 'library'; })
        Text(this.t('settings')).fontSize(24).fontWeight(FontWeight.Bold).fontColor(this.fg())
      }.width('100%')
      Scroll() {
        Column({ space: 16 }) {
          this.notice()
          Text(this.t('kosync_title')).fontSize(21).fontWeight(FontWeight.Medium).fontColor(this.fg()).width('100%')
          Text(this.t('kosync_description')).fontSize(14).fontColor(this.muted()).width('100%')
          Text(this.t('server_url')).fontSize(13).fontColor(this.muted()).width('100%')
          TextInput({ text: this.server, placeholder: 'https://sync.koreader.rocks' }).onChange((value: string) => { this.server = value; })
          TextInput({ text: this.username, placeholder: this.t('username') }).onChange((value: string) => { this.username = value; })
          TextInput({ text: this.password, placeholder: this.t(this.app?.config.userkey ? 'password_unchanged' : 'password') })
            .type(InputType.Password).onChange((value: string) => { this.password = value; })
          TextInput({ text: this.deviceName, placeholder: this.t('device_name') }).onChange((value: string) => { this.deviceName = value; })
          Row() { Text(this.t('auto_sync')).fontColor(this.fg()).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.syncEnabled }).selectedColor('#356553').onChange((value: boolean) => { this.syncEnabled = value; }) }.width('100%')
          Text(this.t('newer_wins')).fontSize(13).fontColor(this.muted()).width('100%')
          Button(this.t('connect_save')).width('100%').backgroundColor('#356553').enabled(!this.busy).onClick(() => this.connect())
          if (this.busy) { LoadingProgress().width(28).height(28) }
          Text(`${this.t('sync_status')}: ${this.t(`status_${this.status}`)}`).fontSize(13).fontColor(this.muted())
          if (this.app?.config.userkey) { Button(this.t('disconnect')).backgroundColor(Color.Transparent).fontColor(this.fg()).onClick(() => { this.run(() => this.app!.disconnect()); this.password = ''; }) }
          Divider()
          Text(this.t('appearance')).fontSize(21).fontWeight(FontWeight.Medium).fontColor(this.fg()).width('100%')
          this.appearanceControls()
          Text(this.t('about_description')).fontSize(12).fontColor(this.muted()).width('100%')
        }.width('100%').padding({ bottom: 24 })
      }.layoutWeight(1).width('100%')
    }.padding(24).width('100%').height('100%').backgroundColor(this.bg())
  }

  @Builder
  readerControls() {
    Column() {
      Row({ space: 6 }) {
        Button('‹').fontSize(26).backgroundColor(Color.Transparent).fontColor(this.fg()).onClick(() => { this.panel = ''; this.run(() => this.app!.close()); })
        Text(this.title).fontSize(16).fontColor(this.fg()).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        Button(this.t('contents')).fontSize(12).backgroundColor(Color.Transparent).fontColor(this.fg()).onClick(() => { this.panel = this.panel === 'toc' ? '' : 'toc'; })
        Button('Aa').backgroundColor(Color.Transparent).fontColor(this.fg()).onClick(() => { this.panel = this.panel === 'appearance' ? '' : 'appearance'; })
      }.height(56).width('100%').backgroundColor(this.bg())
      Blank().layoutWeight(1)
      Column({ space: 6 }) {
        Row() { Text(this.chapter || this.t('reading')).fontSize(11).fontColor(this.muted()).layoutWeight(1).maxLines(1)
          Text(`${Math.round(this.progress)}%`).fontSize(12).fontColor(this.muted()) }.width('100%')
        Slider({ value: this.progress, min: 0, max: 100, step: .1 }).selectedColor('#356553')
          .onChange((value: number, mode: SliderChangeMode) => { if (mode === SliderChangeMode.End) {
            const command = this.app!.command('fraction'); command.percentage = value / 100; this.run(() => this.gateway!.send(command)); } })
        Row({ space: 8 }) {
          Button('‹').backgroundColor(Color.Transparent).fontColor(this.fg()).onClick(() => this.action('previous'))
          Text(this.t(`status_${this.status}`)).fontSize(11).fontColor(this.muted()).layoutWeight(1).textAlign(TextAlign.Center)
          Button(this.t('pull')).fontSize(12).backgroundColor(Color.Transparent).fontColor(this.fg()).enabled(!!this.app?.config.enabled).onClick(() => { this.run(() => this.app!.sync('pull')); })
          Button(this.t('push')).fontSize(12).backgroundColor(Color.Transparent).fontColor(this.fg()).enabled(!!this.app?.config.enabled).onClick(() => { this.run(() => this.app!.sync('push')); })
          Button('›').backgroundColor(Color.Transparent).fontColor(this.fg()).onClick(() => this.action('next'))
        }.height(36).width('100%')
      }.padding({ left: 20, right: 20, top: 8, bottom: 12 }).width('100%').backgroundColor(this.bg())
    }.width('100%').height('100%').hitTestBehavior(HitTestMode.Transparent)
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Web({ src: READER_URL, controller: this.web }).javaScriptAccess(true).domStorageAccess(false).fileAccess(false).onlineImageAccess(false)
        .javaScriptProxy({ object: this.receiver, name: 'HarmonyReader', methodList: ['post'], controller: this.web, permission: BRIDGE_PERMISSION })
        .onInterceptRequest((event) => this.gateway?.resource(event.request.getRequestUrl())!)
        .onLoadIntercept((event) => { const value = event.data.getRequestUrl(); return event.data.isMainFrame() && value !== READER_URL && value !== 'about:blank'; })
        .width('100%').height('100%')
        .padding({ top: this.reading && this.controls ? 56 : 0, bottom: this.reading && this.controls ? 132 : 0 })
      if (!this.reading) { if (this.screen === 'library') { this.library() } else { this.settingsPage() } }
      else {
        if (this.controls) { this.readerControls() }
        if (this.error) { Column() { this.notice() }.padding(16).align(Alignment.Top).margin({ top: 60 }) }
        if (this.panel) {
          Column({ space: 16 }) {
            Row() { Text(this.t(this.panel === 'toc' ? 'contents' : 'appearance')).fontSize(20).fontColor(this.fg()).layoutWeight(1)
              Button('×').backgroundColor(Color.Transparent).fontColor(this.fg()).onClick(() => { this.panel = ''; }) }.width('100%')
            if (this.panel === 'appearance') { this.appearanceControls() }
            else { List({ space: 8 }) {
              ForEach(this.toc, (item: TocEntry, index: number) => { ListItem() {
                Text(item.label).fontSize(15).fontColor(this.fg()).padding({ left: item.depth * 16, top: 12, bottom: 12 }).width('100%')
                  .onClick(() => { const command = this.app!.command('navigate'); command.href = item.href; this.run(() => this.gateway!.send(command)); this.panel = ''; })
              } }, (item: TocEntry, index: number) => `${index}:${item.href}`)
            }.height(320).width('100%') }
          }.padding(24).width('94%').constraintSize({ maxWidth: 560 }).backgroundColor(this.bg()).borderRadius(20).shadow({ radius: 24, color: '#33000000' })
        }
        if (this.conflict) {
          Column({ space: 16 }) {
            Text(this.t('conflict_title')).fontSize(20).fontWeight(FontWeight.Medium).fontColor(this.fg())
            Text(this.t('conflict_description')).fontSize(14).fontColor(this.muted())
            Text(`${this.t('local')}: ${Math.round(this.progress)}% · ${this.t('remote')}: ${Math.round(this.remotePercent)}%`).fontColor(this.fg())
            Row({ space: 12 }) { Button(this.t('keep_local')).onClick(() => { this.run(() => this.app!.sync('push')); })
              Button(this.t('use_remote')).backgroundColor('#356553').onClick(() => { this.run(() => this.app!.sync('pull')); }) }
          }.padding(24).width('94%').constraintSize({ maxWidth: 560 }).backgroundColor(this.bg()).borderRadius(20)
        }
      }
      if (this.confirmRemove) {
        Column({ space: 18 }) {
          Text(this.t('remove_description')).fontSize(17).fontColor(this.fg())
          Row({ space: 12 }) { Button(this.t('cancel')).onClick(() => { this.confirmRemove = ''; })
            Button(this.t('remove')).backgroundColor('#913d35').onClick(() => { const book = this.app!.books.find((item: BookRecord) => item.id === this.confirmRemove);
              if (book) this.run(() => this.app!.remove(book)); this.confirmRemove = ''; }) }
        }.padding(24).width('90%').constraintSize({ maxWidth: 480 }).backgroundColor(this.bg()).borderRadius(20)
      }
      if (this.busy && this.reading) { LoadingProgress().width(48).height(48) }
    }.width('100%').height('100%').backgroundColor(this.bg())
  }
}
