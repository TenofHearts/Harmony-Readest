import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { removeLocalFile } from './LocalFiles';

export const MAX_BOOK_BYTES: number = 128 * 1024 * 1024;
export class CloudFiles {
  exists(path: string): boolean { try { return !!path && fs.accessSync(path); } catch { return false; } }
  size(path: string, limit: number = MAX_BOOK_BYTES): number {
    const size = fs.statSync(path).size; if (size <= 0 || size > limit) throw new Error('BOOK_TOO_LARGE'); return size;
  }
  async bytes(path: string, limit: number = MAX_BOOK_BYTES): Promise<ArrayBuffer> {
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const size = fs.statSync(file.fd).size; if (size <= 0 || size > limit) throw new Error('BOOK_TOO_LARGE');
      const bytes = new Uint8Array(size); let offset = 0;
      while (offset < size) {
        const chunk = new ArrayBuffer(Math.min(256 * 1024, size - offset)); const count = await fs.read(file.fd, chunk);
        if (count <= 0) throw new Error('IMPORT_READ_FAILED'); bytes.set(new Uint8Array(chunk, 0, count), offset); offset += count;
      }
      return bytes.buffer;
    } finally { fs.closeSync(file); }
  }
  async digest(path: string): Promise<string> {
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY); const md = cryptoFramework.createMd('MD5');
    try {
      const size = fs.statSync(file.fd).size;
      for (let i = -1; i <= 10; i++) {
        const start = Math.min(size, 1024 << (2 * i)); if (start >= size) break;
        fs.lseek(file.fd, start, fs.WhenceType.SEEK_SET);
        const chunk = new ArrayBuffer(Math.min(1024, size - start)); let offset = 0;
        while (offset < chunk.byteLength) {
          const part = new ArrayBuffer(chunk.byteLength - offset);
          const count = await fs.read(file.fd, part);
          if (count <= 0) throw new Error('IMPORT_READ_FAILED'); new Uint8Array(chunk).set(new Uint8Array(part, 0, count), offset); offset += count;
        }
        await md.update({ data: new Uint8Array(chunk) });
      }
      return Array.from((await md.digest()).data).map((n: number) => n.toString(16).padStart(2, '0')).join('');
    } finally { fs.closeSync(file); }
  }
  async upload(url: string, path: string): Promise<void> {
    if (!url.startsWith('https://')) throw new Error('HTTPS_REQUIRED');
    const bytes = await this.bytes(path); const request = http.createHttp();
    try {
      const response = await request.request(url, { method: http.RequestMethod.PUT, extraData: bytes,
        connectTimeout: 10000, readTimeout: 120000, usingCache: false, usingProxy: true });
      if (response.responseCode < 200 || response.responseCode >= 300) throw new Error('SERVER_ERROR');
    } finally { request.destroy(); }
  }
  async download(url: string, path: string, expectedHash: string = '', limit: number = MAX_BOOK_BYTES): Promise<void> {
    if (!url.startsWith('https://')) throw new Error('HTTPS_REQUIRED');
    const temporary = `${path}.download`; const file = fs.openSync(temporary, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    const request = http.createHttp(); let size = 0; let failure: Error | undefined;
    let completed: () => void = () => {};
    const end = new Promise<void>((resolve: () => void) => { completed = resolve; });
    request.on('dataEnd', () => completed());
    request.on('dataReceive', (chunk: ArrayBuffer) => {
      if (failure) return;
      try {
        size += chunk.byteLength; if (size > limit) throw new Error('BOOK_TOO_LARGE');
        let offset = 0;
        while (offset < chunk.byteLength) {
          const n = fs.writeSync(file.fd, chunk.slice(offset)); if (n <= 0) throw new Error('IMPORT_WRITE_FAILED'); offset += n;
        }
      } catch (error) { failure = error as Error; completed(); request.destroy(); }
    });
    try {
      const code = await request.requestInStream(url, { method: http.RequestMethod.GET, connectTimeout: 10000,
        readTimeout: 120000, usingProxy: true, usingCache: false });
      await end;
      if (failure) throw failure;
      if (code < 200 || code >= 300 || size === 0) throw new Error('CLOUD_FILE_MISSING');
    } catch (error) { removeLocalFile(temporary); throw failure || error as Error; }
    finally { request.destroy(); fs.closeSync(file); }
    try {
      if (expectedHash && await this.digest(temporary) !== expectedHash) throw new Error('CLOUD_CHECKSUM');
      fs.renameSync(temporary, path);
    } catch (error) { removeLocalFile(temporary); throw error as Error; }
  }
}
