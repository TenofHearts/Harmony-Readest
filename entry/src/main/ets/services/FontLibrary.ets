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
  private systemFaces: CustomFont[] = [];
  private builtinFaces: CustomFont[] = [];
  private prefs?: preferences.Preferences;
  private directory: string = '';
  private context?: common.UIAbilityContext;

  async init(context: common.UIAbilityContext): Promise<void> {
    this.context = context; this.directory = `${context.filesDir}/fonts`;
    this.systemFaces = [];
    try {
      for (const name of uiFont.getSystemFontList()) {
        if (name.length > 128 || /[\x00-\x1f]/.test(name)) continue;
        try {
          const info = uiFont.getFontByName(name);
          if (!info.path || !this.exists(info.path)) continue;
          const face = new CustomFont(); face.id = `system-${this.systemFaces.length}`;
          face.family = name; face.path = info.path; face.weight = info.weight || 400;
          face.style = info.italic ? 'italic' : 'normal';
          this.systemFaces.push(face);
        } catch {}
      }
    } catch {}
    this.systemFonts = this.systemFaces.map((face: CustomFont) => face.family);
    this.builtinFaces = [];
    this.addBuiltin('Readest Serif', 'serif', ['NotoSerifCJK', 'NotoSerif'], ['NotoSerifCJK-Regular.ttc', 'NotoSerif[wdth,wght].ttf']);
    this.addBuiltin('Readest Sans', 'sans-serif', ['HarmonyOS_Sans_SC', 'NotoSansCJK', 'HarmonyOS_Sans.ttf', 'NotoSans['], ['HarmonyOS_Sans_SC.ttf', 'NotoSansCJK-Regular.ttc', 'HarmonyOS_Sans.ttf']);
    this.addBuiltin('Readest Mono', 'monospace', ['NotoSansMono'], ['NotoSansMono[wdth,wght].ttf']);
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

  private addBuiltin(family: string, id: string, files: string[], fallbacks: string[]): void {
    let source: CustomFont | undefined;
    for (const file of files) {
      source = this.systemFaces.find((face: CustomFont) => face.path.split('/').pop()!.startsWith(file));
      if (source) break;
    }
    if (!source) {
      // HarmonyOS can enumerate only theme fonts while keeping bundled fonts readable.
      for (const file of fallbacks) {
        const path = `/system/fonts/${file}`;
        if (!this.exists(path)) continue;
        source = new CustomFont(); source.path = path; break;
      }
    }
    if (!source) return;
    const face = new CustomFont(); face.id = `builtin-${id}`; face.family = family; face.path = source.path;
    face.weight = source.weight; face.style = source.style; this.builtinFaces.push(face);
    // Native generic names and ArkWeb generic names can resolve differently.
    this.register(face);
  }

  nativeFamily(value: string): string {
    const id = `builtin-${value}`;
    return this.builtinFaces.find((face: CustomFont) => face.id === id)?.family || value;
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

  readerFontFiles(): CustomFont[] {
    return this.fonts.concat(this.systemFaces.filter((face: CustomFont) => !this.fonts.some((font: CustomFont) => font.family === face.family))).concat(this.builtinFaces);
  }

  readerFonts(origin: string): ReaderFont[] {
    return this.readerFontFiles().map((font: CustomFont): ReaderFont => {
      const result = new ReaderFont(); result.family = font.family; result.style = font.style;
      result.weight = font.variable ? '100 900' : `${font.weight}`; result.url = `${origin}/fonts/${font.id}`; return result;
    });
  }
}
