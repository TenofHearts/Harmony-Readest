import { BookAnnotation } from './Models';

export const HIGHLIGHT_COLORS: string[] = ['#fff176', '#a5d6a7', '#90caf9', '#f48fb1', '#ce93d8'];

// Keep untrusted renderer messages bounded before writing a book record.
export function validAnnotations(items: BookAnnotation[]): boolean {
  if (!Array.isArray(items) || items.length > 2000) return false;
  const ids: string[] = [];
  for (const item of items) {
    if (!item || typeof item.id !== 'string' || !item.id || item.id.length > 128 || ids.includes(item.id) ||
      !['bookmark', 'highlight'].includes(item.kind) || typeof item.cfi !== 'string' ||
      !item.cfi.startsWith('epubcfi(') || !item.cfi.endsWith(')') || item.cfi.length > 8192 ||
      typeof item.text !== 'string' || item.text.length > 16384 || typeof item.chapter !== 'string' || item.chapter.length > 1024 ||
      !Number.isFinite(item.percentage) || item.percentage < 0 || item.percentage > 1 ||
      !Number.isFinite(item.createdAt) || item.createdAt <= 0 || (!HIGHLIGHT_COLORS.includes(item.color) && !/^#[0-9a-f]{6}$/i.test(item.color))) return false;
    ids.push(item.id);
  }
  return true;
}
