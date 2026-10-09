import { BookRecord, ReaderSettings, ReadingPosition, RemoteProgress, ReplicaSettings, SyncTransport } from './Models';
import { migrateAppearance, StoredAppearance } from './ThemePolicy';
import { CloudNote, validCloudNote } from './CloudAnnotations';

export interface CloudBook {
  user_id: string; book_hash: string; format: string; title: string; author: string;
  meta_hash?: string; source_title?: string; metadata?: string; metadata_updated_at?: string;
  group_id?: string; group_name?: string; group_updated_at?: string; tags?: string[];
  progress?: number[]; reading_status?: string; reading_status_updated_at?: string;
  cover_hash?: string; cover_updated_at?: string;
  created_at?: string; updated_at?: string; uploaded_at?: string; deleted_at?: string; synced_at?: string;
}
export interface CloudConfig {
  user_id: string; book_hash: string; meta_hash?: string; location?: string; xpointer?: string;
  progress?: string; view_settings?: string; search_config?: string; rsvp_position?: string;
  updated_at?: string; deleted_at?: string;
}
export interface CloudResult { books?: CloudBook[]; configs?: CloudConfig[]; notes?: CloudNote[]; }
export class StorageCondition {
  usage: number = 0; quota: number = 0; totalFiles: number = 0; totalSize: number = 0;
  usagePercentage: number = 0;
}
interface TransferURL { uploadUrl?: string; downloadUrl?: string; }
export function cloudTime(value?: string): number { const n = value ? Date.parse(value) : 0; return Number.isFinite(n) ? n : 0; }
export function cloudProgress(row: CloudConfig): RemoteProgress | null {
  if (row.deleted_at || (!row.location?.startsWith('epubcfi(') && !row.xpointer)) return null;
  let percentage: number | undefined;
  if (row.progress) {
    const p = JSON.parse(row.progress) as number[];
    if (!Array.isArray(p) || p.length !== 2 || !p.every((n: number) => Number.isFinite(n)) || p[1] <= 0 || p[0] < 0 || p[0] > p[1]) throw new Error('INVALID_PROGRESS');
    percentage = p[0] / p[1];
  }
  return { document: row.book_hash, cfi: row.location, progress: row.xpointer, percentage: percentage, timestamp: cloudTime(row.updated_at) / 1000 };
}

// Ordinary font/layout preferences travel in book configs, not the settings CRDT whitelist.
export function cloudStyle(row: CloudConfig, defaults: ReaderSettings): ReaderSettings {
  if (!row.view_settings) return defaults;
  const values = JSON.parse(row.view_settings) as Record<string, Object>;
  const source = JSON.parse(JSON.stringify(defaults)) as Record<string, Object>;
  const keys = Object.keys(source);
  for (const key of keys) {
    const remoteKey = key === 'fontSize' ? 'defaultFontSize' : key;
    if (key !== 'themeMode' && key !== 'themeColor' && values[remoteKey] !== undefined) source[key] = values[remoteKey];
  }
  return migrateAppearance(JSON.parse(JSON.stringify(source)) as StoredAppearance);
}
export function configPayload(book: BookRecord, position?: ReadingPosition): Record<string, Object> {
  const old: CloudConfig = book.cloudConfig ? JSON.parse(book.cloudConfig) as CloudConfig : { user_id: '', book_hash: book.hash };
  const payload: Record<string, Object> = {};
  payload['bookHash'] = book.hash; payload['updatedAt'] = Math.max(book.styleUpdatedAt || 0, position?.updatedAt || 0, cloudTime(old.updated_at), Date.now()) + 1;
  if (old.meta_hash) payload['metaHash'] = old.meta_hash;
  const view: Record<string, Object> = old.view_settings ? JSON.parse(old.view_settings) as Record<string, Object> : {};
  if (book.style && book.styleDirty) {
    const style = JSON.parse(JSON.stringify(book.style)) as Record<string, Object>;
    for (const key of Object.keys(style)) {
      if (key !== 'themeMode' && key !== 'themeColor') view[key === 'fontSize' ? 'defaultFontSize' : key] = style[key];
    }
  }
  if (book.styleDirty && Object.keys(view).length) payload['viewSettings'] = view;
  if (position) {
    payload['location'] = position.cfi; payload['xpointer'] = position.xpointer;
    // Readest serializes [current,total]. Keep exact fractional progress independent of device pagination.
    payload['progress'] = [Math.round(position.percentage * 1000000), 1000000];
  }
  return payload;
}
export function bookPayload(book: BookRecord, uploaded: boolean = false, deleted: boolean = false): Record<string, Object> {
  const row: CloudBook = book.cloudBook ? JSON.parse(book.cloudBook) as CloudBook : { user_id: '', book_hash: book.hash, format: 'EPUB', title: book.title, author: book.author };
  const result: Record<string, Object> = {};
  result['hash'] = book.hash; result['format'] = 'EPUB'; result['title'] = row.title; result['author'] = row.author;
  result['sourceTitle'] = row.source_title || book.title; result['createdAt'] = cloudTime(row.created_at) || book.importedAt; result['updatedAt'] = Math.max(Date.now(), cloudTime(row.updated_at)) + 1;
  if (row.meta_hash) result['metaHash'] = row.meta_hash;
  if (row.metadata) result['metadata'] = JSON.parse(row.metadata) as Object;
  else if (book.metadataJSON) { result['metadata'] = JSON.parse(book.metadataJSON) as Object; result['metadataUpdatedAt'] = book.importedAt; }
  if (row.metadata_updated_at) result['metadataUpdatedAt'] = cloudTime(row.metadata_updated_at);
  if (row.group_id) result['groupId'] = row.group_id;
  if (row.group_name) result['groupName'] = row.group_name;
  if (row.group_updated_at) result['groupUpdatedAt'] = cloudTime(row.group_updated_at);
  if (row.tags) result['tags'] = row.tags;
  if (row.progress) result['progress'] = row.progress;
  if (row.reading_status) result['readingStatus'] = row.reading_status;
  if (row.reading_status_updated_at) result['readingStatusUpdatedAt'] = cloudTime(row.reading_status_updated_at);
  if (row.cover_hash) result['coverHash'] = row.cover_hash;
  if (row.cover_updated_at) result['coverUpdatedAt'] = cloudTime(row.cover_updated_at);
  if (uploaded || row.uploaded_at) result['uploadedAt'] = uploaded ? Date.now() : cloudTime(row.uploaded_at);
  if (deleted) result['deletedAt'] = Date.now();
  return result;
}

export class CloudClient {
  private transport: SyncTransport;
  private base: string;
  constructor(transport: SyncTransport, base: string = 'https://web.readest.com/api') { this.transport = transport; this.base = base; }
  private async request(config: ReplicaSettings, path: string, method: string = 'GET', body?: string): Promise<string> {
    if (!config.accessToken || !config.userId) throw new Error('AUTH_FAILED');
    const response = await this.transport.request(`${this.base}${path}`, method, { 'Authorization': `Bearer ${config.accessToken}`, 'Content-Type': 'application/json' }, body);
    if (response.status === 403 && response.body.includes('Insufficient storage')) throw new Error('SYNC_QUOTA');
    if (response.status === 401 || response.status === 403) throw new Error('AUTH_FAILED');
    if (response.status === 402 || response.status === 507) throw new Error('SYNC_QUOTA');
    if (response.status === 404) throw new Error('CLOUD_FILE_MISSING');
    if (response.status < 200 || response.status >= 300) throw new Error('SERVER_ERROR');
    return response.body;
  }
  private validate(result: CloudResult, account: string): CloudResult {
    if (!result || (result.books === undefined && result.configs === undefined && result.notes === undefined)) throw new Error('INVALID_CLOUD');
    if (result.books && (!Array.isArray(result.books) || !result.books.every((b: CloudBook) => b.user_id === account && /^[a-f0-9]{32}$/.test(b.book_hash) && typeof b.title === 'string' && typeof b.author === 'string'))) throw new Error('INVALID_CLOUD');
    if (result.configs && (!Array.isArray(result.configs) || !result.configs.every((c: CloudConfig) => c.user_id === account && /^[a-f0-9]{32}$/.test(c.book_hash)))) throw new Error('INVALID_CLOUD');
    if (result.notes && (!Array.isArray(result.notes) || !result.notes.every((note: CloudNote) => validCloudNote(note, account)))) throw new Error('INVALID_CLOUD');
    return result;
  }
  async pull(config: ReplicaSettings, type: string, since: number = 0, hash: string = ''): Promise<CloudResult> {
    const suffix = hash ? `&book=${encodeURIComponent(hash)}` : '';
    return this.validate(JSON.parse(await this.request(config, `/sync?type=${type}&since=${since}${suffix}`)) as CloudResult, config.userId);
  }
  async push(config: ReplicaSettings, type: string, row: Record<string, Object>): Promise<CloudResult> {
    const body: Record<string, Object> = {}; body[type] = [row];
    return this.validate(JSON.parse(await this.request(config, '/sync', 'POST', JSON.stringify(body))) as CloudResult, config.userId);
  }
  async storage(config: ReplicaSettings): Promise<StorageCondition> {
    const data = JSON.parse(await this.request(config, '/storage/stats')) as StorageCondition;
    if (![data.usage, data.quota, data.totalFiles, data.totalSize].every((n: number) => Number.isSafeInteger(n) && n >= 0)) throw new Error('INVALID_CLOUD');
    data.usagePercentage = data.quota > 0 ? data.usage / data.quota * 100 : data.usage > 0 ? 100 : 0; return data;
  }
  async uploadURL(config: ReplicaSettings, hash: string, size: number, cover: boolean = false): Promise<string> {
    const payload: Record<string, Object> = {};
    payload['fileName'] = `Readest/Books/${hash}/${cover ? 'cover.png' : `${hash}.epub`}`;
    payload['fileSize'] = size; payload['bookHash'] = hash; payload['temp'] = false;
    const data = JSON.parse(await this.request(config, '/storage/upload', 'POST', JSON.stringify(payload))) as TransferURL;
    if (!data.uploadUrl?.startsWith('https://')) throw new Error('INVALID_CLOUD'); return data.uploadUrl;
  }
  async downloadURL(config: ReplicaSettings, hash: string, cover: boolean = false): Promise<string> {
    const key = `${config.userId}/Readest/Books/${hash}/${cover ? 'cover.png' : `${hash}.epub`}`;
    const data = JSON.parse(await this.request(config, `/storage/download?fileKey=${encodeURIComponent(key)}`)) as TransferURL;
    if (!data.downloadUrl?.startsWith('https://')) throw new Error('INVALID_CLOUD'); return data.downloadUrl;
  }
}
