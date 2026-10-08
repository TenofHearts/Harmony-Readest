import { common } from '@kit.AbilityKit';
import { relationalStore, preferences } from '@kit.ArkData';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BookRecord, ReaderSettings } from '../core/Models';

export class Repository {
  private db?: relationalStore.RdbStore;
  private prefs?: preferences.Preferences;
  private writes: Promise<void> = Promise.resolve();
  directory: string = '';

  async init(context: common.UIAbilityContext): Promise<void> {
    this.directory = `${context.filesDir}/books`;
    if (!fs.accessSync(this.directory)) fs.mkdirSync(this.directory);
    this.db = await relationalStore.getRdbStore(context, { name: 'library.db', securityLevel: relationalStore.SecurityLevel.S1 });
    await this.db.executeSql('CREATE TABLE IF NOT EXISTS books (id TEXT PRIMARY KEY, record TEXT NOT NULL, opened INTEGER NOT NULL)');
    this.prefs = await preferences.getPreferences(context, { name: 'reader_settings' });
  }

  async list(): Promise<BookRecord[]> {
    const rows = await this.db!.querySql('SELECT record FROM books ORDER BY opened DESC');
    const books: BookRecord[] = [];
    try { while (rows.goToNextRow()) books.push(JSON.parse(rows.getString(0)) as BookRecord); }
    finally { rows.close(); }
    return books;
  }

  save(book: BookRecord): Promise<void> {
    const record = JSON.stringify(book);
    const id = book.id, opened = book.lastOpenedAt;
    const operation = this.writes.then(async () => {
      await this.db!.executeSql('INSERT OR REPLACE INTO books (id, record, opened) VALUES (?, ?, ?)', [id, record, opened]);
    });
    this.writes = operation.catch(() => {});
    return operation;
  }

  async remove(book: BookRecord): Promise<void> {
    await this.writes;
    await this.db!.executeSql('DELETE FROM books WHERE id = ?', [book.id]);
    if (fs.accessSync(book.path)) fs.unlinkSync(book.path);
    if (book.cover && fs.accessSync(book.cover)) fs.unlinkSync(book.cover);
  }

  async settings(): Promise<ReaderSettings> {
    const text = await this.prefs!.get('appearance', '') as string;
    return text ? JSON.parse(text) as ReaderSettings : new ReaderSettings();
  }

  async saveSettings(settings: ReaderSettings): Promise<void> {
    await this.prefs!.put('appearance', JSON.stringify(settings)); await this.prefs!.flush();
  }

  async deviceId(): Promise<string> {
    let value = await this.prefs!.get('deviceId', '') as string;
    if (!value) { value = util.generateRandomUUID(); await this.prefs!.put('deviceId', value); await this.prefs!.flush(); }
    return value;
  }

  async importFile(uri: string, name: string): Promise<BookRecord> {
    const id = util.generateRandomUUID();
    const path = `${this.directory}/${id}.epub`;
    const source = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    let output: fs.File | undefined;
    try {
      const size = fs.statSync(source.fd).size;
      if (size === 0 || size > 128 * 1024 * 1024) throw new Error('BOOK_TOO_LARGE');
      output = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
      const chunk = new ArrayBuffer(256 * 1024);
      let read = 0;
      while ((read = await fs.read(source.fd, chunk)) > 0) {
        let written = 0;
        while (written < read) {
          const count = await fs.write(output.fd, chunk.slice(written, read));
          if (count <= 0) throw new Error('IMPORT_WRITE_FAILED');
          written += count;
        }
      }
    } catch (error) {
      if (output) { fs.closeSync(output); output = undefined; }
      if (fs.accessSync(path)) fs.unlinkSync(path);
      throw error as Error;
    } finally { fs.closeSync(source); if (output) fs.closeSync(output); }
    const book = new BookRecord();
    book.id = id; book.filename = name; book.title = name.replace(/\.epub$/i, '');
    book.path = path; book.importedAt = Date.now(); book.lastOpenedAt = book.importedAt;
    return book;
  }

  async cover(book: BookRecord, data: string): Promise<void> {
    const match = /^data:image\/(png|jpeg|webp|gif);base64,([A-Za-z0-9+/=]+)$/.exec(data);
    if (!match) return;
    const bytes = new util.Base64Helper().decodeSync(match[2]);
    if (bytes.length > 4 * 1024 * 1024) return;
    const path = `${this.directory}/${book.id}.cover`;
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try { await fs.write(file.fd, bytes.buffer); } finally { fs.closeSync(file); }
    book.cover = path;
  }
}
