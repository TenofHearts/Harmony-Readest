import { CustomFont } from './Models';

export const MAX_FONT_BYTES: number = 32 * 1024 * 1024;

// Only single-face OpenType/TrueType files are offered by the picker.
export function parseFont(bytes: ArrayBuffer, filename: string): CustomFont {
  if (bytes.byteLength < 12 || bytes.byteLength > MAX_FONT_BYTES || !/\.(ttf|otf)$/i.test(filename) ||
    /[\\/\x00-\x1f]/.test(filename) || filename.length > 200) throw new Error('INVALID_FONT');
  const view = new DataView(bytes);
  const signature = view.getUint32(0);
  if (signature !== 0x00010000 && signature !== 0x4f54544f && signature !== 0x74727565) throw new Error('INVALID_FONT');
  const font = new CustomFont(); font.filename = filename; font.byteSize = bytes.byteLength;
  let nameOffset = 0, nameLength = 0, score = -1;
  const count = view.getUint16(4);
  if (12 + count * 16 > bytes.byteLength) throw new Error('INVALID_FONT');
  for (let i = 0; i < count; i++) {
    const entry = 12 + i * 16, tag = view.getUint32(entry), offset = view.getUint32(entry + 8), length = view.getUint32(entry + 12);
    if (offset + length > bytes.byteLength) throw new Error('INVALID_FONT');
    if (tag === 0x6e616d65) { nameOffset = offset; nameLength = length; }
    if (tag === 0x4f532f32 && length >= 64) {
      font.weight = Math.max(100, Math.min(900, view.getUint16(offset + 4)));
      const flags = view.getUint16(offset + 62); font.style = flags & 512 ? 'oblique' : flags & 1 ? 'italic' : 'normal';
    }
    if (tag === 0x66766172) font.variable = true;
  }
  if (!nameOffset || nameLength < 6) throw new Error('INVALID_FONT');
  const names = view.getUint16(nameOffset + 2), strings = nameOffset + view.getUint16(nameOffset + 4);
  if (6 + names * 12 > nameLength) throw new Error('INVALID_FONT');
  for (let i = 0; i < names; i++) {
    const entry = nameOffset + 6 + i * 12, platform = view.getUint16(entry), language = view.getUint16(entry + 4), id = view.getUint16(entry + 6);
    if (id !== 1 && id !== 16) continue;
    const length = view.getUint16(entry + 8), start = strings + view.getUint16(entry + 10);
    if (start + length > nameOffset + nameLength) throw new Error('INVALID_FONT');
    const priority = (id === 16 ? 200 : 0) + (platform === 3 ? 90 : platform === 0 ? 100 : 0) + (language === 0x409 ? 10 : 0);
    if (priority <= score || (platform !== 0 && platform !== 3 && platform !== 1)) continue;
    let value = '';
    if (platform === 0 || platform === 3) {
      if (length % 2) throw new Error('INVALID_FONT');
      for (let n = 0; n < length; n += 2) value += String.fromCharCode(view.getUint16(start + n));
    } else { for (let n = 0; n < length; n++) value += String.fromCharCode(view.getUint8(start + n)); }
    if (value.trim() && value.length <= 128 && !/[\x00-\x1f]/.test(value)) { font.family = value.trim(); score = priority; }
  }
  if (!font.family) throw new Error('INVALID_FONT');
  font.name = font.family; font.downloadedAt = Date.now(); return font;
}
