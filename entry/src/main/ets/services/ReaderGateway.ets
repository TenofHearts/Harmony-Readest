import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BookRecord, CustomFont, ReaderCommand, ReaderEvent, ReaderSettings, ReadingPosition, RemoteProgress } from '../core/Models';
import { isCurrentSession } from '../core/SyncPolicy';

export const READER_ORIGIN: string = 'https://reader.harmonyreadest.invalid';
export const READER_URL: string = `${READER_ORIGIN}/reader/index.html`;
export const BRIDGE_PERMISSION: string = '{"javascriptProxyPermission":{"urlPermissionList":[{"scheme":"https","host":"reader.harmonyreadest.invalid","port":"","path":"/reader/index.html"}]}}';

class PendingRestore {
  id: string;
  session: string;
  resolve: (value: ReadingPosition) => void;
  reject: (reason: Error) => void;
  timer: number = -1;
  constructor(id: string, session: string, resolve: (value: ReadingPosition) => void, reject: (reason: Error) => void) {
    this.id = id; this.session = session; this.resolve = resolve; this.reject = reject;
  }
}

export class ReaderGateway {
  session: string = '';
  ready: boolean = false;
  fonts: CustomFont[] = [];
  private book?: BookRecord;
  private pending?: PendingRestore;
  onEvent: (event: ReaderEvent) => void = () => {};
  private context: common.UIAbilityContext;
  private controller: webview.WebviewController;
  constructor(context: common.UIAbilityContext, controller: webview.WebviewController) { this.context = context; this.controller = controller; }

  post(value: string): void {
    if (value.length > 6 * 1024 * 1024) return;
    try {
      const event = JSON.parse(value) as ReaderEvent;
      if (event.version !== 1 || typeof event.session !== 'string' || typeof event.type !== 'string') return;
      if (event.type === 'ready' && event.session === '') { this.ready = true; this.onEvent(event); return; }
      if (!isCurrentSession(this.session, event.session)) return;
      if (event.position && (!event.position.cfi?.startsWith('epubcfi(') ||
        !Number.isFinite(event.position.percentage) || event.position.percentage < 0 || event.position.percentage > 1)) return;
      if (event.requestId && this.pending?.id === event.requestId && this.pending.session === event.session) {
        clearTimeout(this.pending.timer);
        if ((event.type === 'restored' || event.type === 'inspected') && event.position) this.pending.resolve(event.position);
        else this.pending.reject(new Error('UNRESOLVED_POSITION'));
        this.pending = undefined;
        return;
      }
      this.onEvent(event);
    } catch {}
  }

  async send(command: ReaderCommand): Promise<void> {
    command.session = this.session;
    await this.controller.runJavaScript(`window.readerReceive(${JSON.stringify(command)})`);
  }

  async open(book: BookRecord, metadataOnly: boolean = false, settings?: ReaderSettings, systemDark?: boolean): Promise<void> {
    this.cancel();
    this.book = book; this.session = util.generateRandomUUID();
    const command = new ReaderCommand(); command.type = 'open'; command.cfi = book.position.cfi;
    command.metadataOnly = metadataOnly;
    command.annotations = book.annotations || [];
    command.settings = settings; command.systemDark = systemDark;
    command.url = `${READER_ORIGIN}/books/${book.id}.epub`;
    await this.send(command);
  }

  cancel(): void {
    if (this.pending) { clearTimeout(this.pending.timer); this.pending.reject(new Error('SESSION_CLOSED')); this.pending = undefined; }
    this.session = ''; this.book = undefined;
  }

  reset(): void {
    this.cancel(); this.ready = false;
    // A stuck renderer command must not hold subsequent imports in its queue.
    this.controller.loadUrl(READER_URL);
  }

  private async bookBytes(path: string): Promise<ArrayBuffer> {
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const size = fs.statSync(file.fd).size;
      if (size <= 0 || size > 128 * 1024 * 1024) throw new Error('BOOK_TOO_LARGE');
      const bytes = new Uint8Array(size);
      const chunk = new ArrayBuffer(256 * 1024);
      let offset = 0;
      while (offset < size) {
        const count = await fs.read(file.fd, chunk, { length: Math.min(chunk.byteLength, size - offset) });
        if (count <= 0) throw new Error('IMPORT_READ_FAILED');
        bytes.set(new Uint8Array(chunk, 0, count), offset); offset += count;
      }
      return bytes.buffer;
    } finally { fs.closeSync(file); }
  }

  restore(remote: RemoteProgress): Promise<ReadingPosition> {
    return this.locate(remote, 'restore');
  }

  inspect(remote: RemoteProgress): Promise<ReadingPosition> {
    return this.locate(remote, 'inspect');
  }

  private locate(remote: RemoteProgress, type: string): Promise<ReadingPosition> {
    if (!remote.cfi?.startsWith('epubcfi(') && !remote.progress?.startsWith('/body/DocFragment')) return Promise.reject(new Error('UNRESOLVED_POSITION'));
    return new Promise((resolve: (position: ReadingPosition) => void, reject: (error: Error) => void) => {
      const pending = new PendingRestore(util.generateRandomUUID(), this.session, resolve, reject);
      this.pending = pending;
      pending.timer = setTimeout(() => {
        if (this.pending === pending) { this.pending = undefined; reject(new Error('READER_TIMEOUT')); }
      }, 15000);
      const command = new ReaderCommand(); command.type = type; command.cfi = remote.cfi;
      command.xpointer = remote.cfi ? undefined : remote.progress; command.requestId = pending.id;
      this.send(command).catch(() => { clearTimeout(pending.timer); this.pending = undefined; reject(new Error('READER_ERROR')); });
    });
  }

  resource(value: string): WebResourceResponse | null {
    if (value.startsWith('blob:') || value === 'about:blank' || value.startsWith('data:')) return null;
    const response = new WebResourceResponse();
    response.setResponseEncoding('utf-8'); response.setResponseIsReady(true);
    response.setResponseCode(404); response.setReasonMessage('Not Found'); response.setResponseData('');
    if (!value.startsWith(`${READER_ORIGIN}/`)) return response;
    const name = value.slice(READER_ORIGIN.length);
    const font = this.fonts.find((item: CustomFont) => name === `/fonts/${item.id}`);
    if (font) {
      response.setResponseCode(200); response.setReasonMessage('OK'); response.setResponseMimeType('font/ttf');
      response.setResponseIsReady(false);
      this.bookBytes(font.path).then((bytes: ArrayBuffer) => {
        response.setResponseData(bytes); response.setResponseIsReady(true);
      }).catch(() => { response.setResponseCode(404); response.setResponseIsReady(true); });
      return response;
    }
    if (this.book && name === `/books/${this.book.id}.epub`) {
      response.setResponseCode(200); response.setReasonMessage('OK'); response.setResponseMimeType('application/epub+zip');
      response.setResponseIsReady(false);
      // Send binary data with descriptor lifetime entirely in native code.
      this.bookBytes(this.book.path).then((bytes: ArrayBuffer) => {
        response.setResponseData(bytes); response.setResponseIsReady(true);
      }).catch(() => { response.setResponseCode(404); response.setResponseIsReady(true); });
      return response;
    }
    if (!/^\/reader\/(index\.html|reader\.js|provenance\.json)$/.test(name)) return response;
    response.setResponseCode(200); response.setReasonMessage('OK');
    response.setResponseMimeType(name.endsWith('.html') ? 'text/html' : name.endsWith('.js') ? 'text/javascript' : 'application/json');
    response.setResponseIsReady(false);
    this.context.resourceManager.getRawFileContent(name.slice(1)).then((bytes: Uint8Array) => {
      response.setResponseData(bytes.buffer); response.setResponseIsReady(true);
    }).catch(() => { response.setResponseCode(404); response.setResponseIsReady(true); });
    return response;
  }
}
