import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { preferences } from '@kit.ArkData';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { font as uiFont } from '@kit.ArkUI';
import { CustomFont, ReaderFont } from '../core/Models';
import { MAX_FONT_BYTES, parseFont } from '../core/FontPolicy';
import { removeLocalFile } from './LocalFiles';

export class FontLibrary {
  fonts: CustomFont[] = [];
  systemFonts: string[] = [];
  private prefs?: preferences.Preferences;
  private directory: string = '';
  private context?: common.UIAbilityContext;

  async init(context: common.UIAbilityContext): Promise<void> {
    this.context = context; this.directory = `${context.filesDir}/fonts`;
    try { this.systemFonts = uiFont.getSystemFontList().filter((name: string) => name.length <= 128 && !/[\x00-\x1f]/.test(name)); } catch {}
    if (!this.exists(this.directory)) fs.mkdirSync(this.directory);
    this.prefs = await preferences.getPreferences(context, { name: 'custom_fonts' });
    this.fonts = JSON.parse(await this.prefs.get('fonts', '[]') as string) as CustomFont[];
    this.fonts = this.fonts.filter((font: CustomFont) => /^[a-f0-9]{32}$/.test(font.id) &&
      font.path === `${this.directory}/${font.id}.${font.filename.toLowerCase().endsWith('.otf') ? 'otf' : 'ttf'}` && this.exists(font.path));
    for (const font of this.fonts) this.register(font);
  }

  private register(font: CustomFont): void {
    try { uiFont.registerFont({ familyName: font.family, familySrc: `file://${font.path}` }); } catch {}
  }

  private exists(path: string): boolean { try { return fs.accessSync(path); } catch { return false; } }

  async save(): Promise<void> { await this.prefs!.put('fonts', JSON.stringify(this.fonts)); await this.prefs!.flush(); }

  async bytes(path: string): Promise<ArrayBuffer> {
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const size = fs.statSync(file.fd).size;
      if (size <= 0 || size > MAX_FONT_BYTES) throw new Error('INVALID_FONT');
      const bytes = new Uint8Array(size); let offset = 0;
      while (offset < size) {
        const chunk = new ArrayBuffer(Math.min(256 * 1024, size - offset));
        const count = await fs.read(file.fd, chunk);
        if (count <= 0) throw new Error('IMPORT_READ_FAILED');
        bytes.set(new Uint8Array(chunk, 0, count), offset); offset += count;
      }
      return bytes.buffer;
    } finally { fs.closeSync(file); }
  }

  private async digest(bytes: Uint8Array): Promise<string> {
    const md = cryptoFramework.createMd('MD5'); await md.update({ data: bytes });
    return Array.from((await md.digest()).data).map((n: number) => n.toString(16).padStart(2, '0')).join('');
  }

  async identify(bytes: ArrayBuffer, filename: string): Promise<CustomFont> {
    const font = parseFont(bytes, filename); const chunks: Uint8Array[] = [];
    for (let i = -1; i <= 10; i++) {
      const start = Math.min(bytes.byteLength, 1024 << (2 * i));
      if (start >= bytes.byteLength) break;
      chunks.push(new Uint8Array(bytes.slice(start, Math.min(start + 1024, bytes.byteLength))));
    }
    const all = new Uint8Array(chunks.reduce((n: number, chunk: Uint8Array) => n + chunk.length, 0)); let offset = 0;
    for (const chunk of chunks) { all.set(chunk, offset); offset += chunk.length; }
    font.partialMd5 = await this.digest(all);
    font.id = await this.digest(new util.TextEncoder().encodeInto(`${font.partialMd5}|${bytes.byteLength}|${filename}`));
    return font;
  }

  async install(bytes: ArrayBuffer, filename: string, expectedId: string = '', expectedDigest: string = ''): Promise<CustomFont> {
    const font = await this.identify(bytes, filename);
    if ((expectedId && font.id !== expectedId) || (expectedDigest && font.partialMd5 !== expectedDigest)) throw new Error('INVALID_FONT');
    const existing = this.fonts.find((item: CustomFont) => item.id === font.id);
    if (existing) return existing;
    font.reincarnation = util.generateRandomUUID();
    font.path = `${this.directory}/${font.id}.${filename.toLowerCase().endsWith('.otf') ? 'otf' : 'ttf'}`;
    const file = fs.openSync(font.path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try { let offset = 0; while (offset < bytes.byteLength) {
      const count = await fs.write(file.fd, bytes.slice(offset)); if (count <= 0) throw new Error('IMPORT_WRITE_FAILED'); offset += count;
    } } catch (error) { removeLocalFile(font.path); throw error as Error; } finally { fs.closeSync(file); }
    this.fonts.push(font);
    try { await this.save(); } catch (error) { this.fonts.pop(); removeLocalFile(font.path); throw error as Error; }
    this.register(font); return font;
  }

  async importFonts(): Promise<void> {
    const paths = await new picker.DocumentViewPicker(this.context!).select({ maxSelectNumber: 10, fileSuffixFilters: ['Fonts|.ttf,.otf'] });
    for (const path of paths) {
      const filename = decodeURIComponent(path.split('/').pop() || 'font.ttf');
      await this.install(await this.bytes(path), filename);
    }
  }

  async remove(id: string): Promise<void> {
    const font = this.fonts.find((item: CustomFont) => item.id === id); if (!font) return;
    const previous = this.fonts; this.fonts = this.fonts.filter((item: CustomFont) => item.id !== id);
    try { await this.save(); } catch (error) { this.fonts = previous; throw error as Error; }
    removeLocalFile(font.path);
  }

  readerFonts(origin: string): ReaderFont[] {
    return this.fonts.map((font: CustomFont): ReaderFont => {
      const result = new ReaderFont(); result.family = font.family; result.style = font.style;
      result.weight = font.variable ? '100 900' : `${font.weight}`; result.url = `${origin}/fonts/${font.id}`; return result;
    });
  }
}
