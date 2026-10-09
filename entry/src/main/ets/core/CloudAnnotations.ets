import { BookRecord, BookAnnotation, AnnotationSyncRecord } from './Models';
import { validAnnotations } from './AnnotationPolicy';

export interface CloudNote {
  user_id: string; book_hash: string; id: string; type?: string; cfi?: string;
  meta_hash?: string; xpointer0?: string; xpointer1?: string; page?: number;
  text?: string; style?: string; color?: string; note?: string; global?: boolean;
  created_at?: string; updated_at?: string; deleted_at?: string;
}
function time(value?: string): number { const result = value ? Date.parse(value) : 0; return Number.isFinite(result) ? result : 0; }
export function noteChange(row: CloudNote): number { return Math.max(time(row.updated_at), time(row.deleted_at)); }
export function validCloudNote(row: CloudNote, account: string): boolean {
  return !!row && row.user_id === account && /^[a-f0-9]{32}$/.test(row.book_hash) &&
    typeof row.id === 'string' && !!row.id && row.id.length <= 128 && noteChange(row) > 0 &&
    (row.cfi === undefined || (typeof row.cfi === 'string' && row.cfi.length <= 8192)) &&
    (row.text === undefined || row.text === null || (typeof row.text === 'string' && row.text.length <= 16384));
}

// Every future persistent user feature must be added to the Readest sync model,
// payload, merge/deletion rules and round-trip tests. KoSync only transports progress.
// Preserve unsupported Readest note fields so editing a highlight never erases a note.
export function prepareAnnotations(book: BookRecord, account: string): void {
  book.annotationSync = book.annotationSync || [];
  if (book.annotationsAccount && book.annotationsAccount !== account) book.annotationSync = [];
  book.annotationsAccount = account;
  for (const annotation of book.annotations) {
    if (!book.annotationSync.some((state: AnnotationSyncRecord) => state.id === annotation.id)) {
      const state = new AnnotationSyncRecord(); state.id = annotation.id; state.updatedAt = annotation.createdAt;
      book.annotationSync.push(state);
    }
  }
}

export function recordAnnotations(book: BookRecord, incoming: BookAnnotation[], now: number = Date.now()): void {
  book.annotations = book.annotations || [];
  book.annotationSync = book.annotationSync || [];
  for (const item of incoming) {
    const previous = book.annotations.find((old: BookAnnotation) => old.id === item.id);
    if (previous && JSON.stringify(previous) === JSON.stringify(item)) continue;
    let state = book.annotationSync.find((old: AnnotationSyncRecord) => old.id === item.id);
    if (!state) { state = new AnnotationSyncRecord(); state.id = item.id; book.annotationSync.push(state); }
    state.updatedAt = Math.max(now, state.updatedAt + 1, state.deletedAt + 1); state.deletedAt = 0; state.dirty = true;
  }
  for (const item of book.annotations) {
    if (incoming.some((annotation: BookAnnotation) => annotation.id === item.id)) continue;
    let state = book.annotationSync.find((old: AnnotationSyncRecord) => old.id === item.id);
    if (!state) { state = new AnnotationSyncRecord(); state.id = item.id; book.annotationSync.push(state); }
    state.deletedAt = Math.max(now, state.updatedAt + 1); state.dirty = true;
  }
  book.annotations = incoming;
}

export function applyCloudNote(book: BookRecord, row: CloudNote): boolean {
  let state = book.annotationSync.find((item: AnnotationSyncRecord) => item.id === row.id);
  const incoming = noteChange(row);
  if (state && (incoming < Math.max(state.updatedAt, state.deletedAt) ||
    (incoming === Math.max(state.updatedAt, state.deletedAt) && state.deletedAt && !row.deleted_at))) return false;
  const previous = JSON.stringify(book.annotations);
  const old = book.annotations.find((item: BookAnnotation) => item.id === row.id);
  if (row.deleted_at) book.annotations = book.annotations.filter((item: BookAnnotation) => item.id !== row.id);
  else if ((row.type === 'bookmark' || (row.type === 'annotation' && (!row.style || row.style === 'highlight'))) && row.cfi) {
    const colors: Record<string, string> = {};
    colors['yellow'] = '#fff176'; colors['green'] = '#a5d6a7'; colors['blue'] = '#90caf9';
    colors['red'] = '#f48fb1'; colors['violet'] = '#ce93d8';
    const item = new BookAnnotation(); item.id = row.id; item.kind = row.type === 'bookmark' ? 'bookmark' : 'highlight';
    item.cfi = row.cfi; item.text = row.text || ''; item.color = colors[row.color || ''] || row.color || '#fff176';
    item.createdAt = time(row.created_at) || incoming; item.chapter = old?.chapter || ''; item.percentage = old?.percentage || 0;
    if (validAnnotations([item])) {
      const annotations = book.annotations.filter((annotation: BookAnnotation) => annotation.id !== row.id).concat(item);
      if (annotations.length > 2000) throw new Error('ANNOTATIONS_LIMIT');
      book.annotations = annotations;
    }
  }
  // Commit the acknowledgment only after validation/limits succeed; a failed
  // batch must retain the pending local state and replay from the same cursor.
  if (!state) { state = new AnnotationSyncRecord(); state.id = row.id; book.annotationSync.push(state); }
  state.updatedAt = time(row.updated_at); state.deletedAt = time(row.deleted_at); state.dirty = false; state.cloudJSON = JSON.stringify(row);
  return previous !== JSON.stringify(book.annotations);
}

export function notePayload(book: BookRecord, state: AnnotationSyncRecord): Record<string, Object> {
  const row: CloudNote | null = state.cloudJSON ? JSON.parse(state.cloudJSON) as CloudNote : null;
  const item = book.annotations.find((annotation: BookAnnotation) => annotation.id === state.id);
  const result: Record<string, Object> = {};
  result['id'] = state.id; result['bookHash'] = book.hash; result['createdAt'] = row ? time(row.created_at) : item?.createdAt || state.updatedAt;
  result['updatedAt'] = state.updatedAt; result['deletedAt'] = state.deletedAt;
  if (row) {
    if (row.meta_hash) result['metaHash'] = row.meta_hash;
    for (const key of ['type', 'cfi', 'xpointer0', 'xpointer1', 'page', 'text', 'style', 'color', 'note', 'global']) {
      const fields = JSON.parse(state.cloudJSON) as Record<string, Object>;
      if (fields[key] !== undefined) result[key] = fields[key];
    }
  }
  if (item && !state.deletedAt) {
    result['type'] = item.kind === 'bookmark' ? 'bookmark' : 'annotation'; result['cfi'] = item.cfi;
    result['text'] = item.text; result['color'] = item.color;
    if (item.kind === 'highlight') result['style'] = 'highlight';
  }
  if (result['note'] === undefined) result['note'] = '';
  return result;
}
