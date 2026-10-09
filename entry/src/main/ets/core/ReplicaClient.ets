import { ReplicaSettings, CustomFont, SyncTransport } from './Models';
import { READEST_AUTH_URL, READEST_ANON_KEY } from './ReadestAuth';
import { MAX_FONT_BYTES } from './FontPolicy';

export interface ReplicaField { v: string | number | boolean; t: string; s: string; }
export interface ReplicaFile { filename: string; byteSize: number; partialMd5: string; }
export function supportedFontFile(file: ReplicaFile): boolean { return /\.(ttf|otf)$/i.test(file.filename) && file.byteSize <= MAX_FONT_BYTES; }
export interface ReplicaManifest { files: ReplicaFile[]; schemaVersion: number; }
export interface FontReplicaRow {
  user_id: string;
  kind: string;
  replica_id: string;
  fields_jsonb: Record<string, ReplicaField>;
  manifest_jsonb: ReplicaManifest | null;
  deleted_at_ts: string | null;
  reincarnation: string | null;
  updated_at_ts: string;
  schema_version: number;
}
interface ReplicaRows { rows: FontReplicaRow[]; }
interface SignedTransfer { uploadUrl?: string; downloadUrl?: string; }
interface AuthUser { id: string; email: string; }
interface AuthResponse { access_token: string; refresh_token: string; expires_in: number; user: AuthUser; }
interface UploadRequest { fileName: string; fileSize: number; replicaKind: string; replicaId: string; temp: boolean; }
function replicaField(value: string | number | boolean, stamp: string, deviceId: string): ReplicaField {
  return { v: value, t: stamp, s: deviceId };
}

export function isHlc(value: string): boolean { return typeof value === 'string' && /^[0-9a-f]{13}-[0-9a-f]{8}-[A-Za-z0-9_-]+$/.test(value); }

export function nextReplicaClock(previous: string, deviceId: string, now: number = Date.now()): string {
  const physical = isHlc(previous) ? parseInt(previous.slice(0, 13), 16) : 0;
  const time = Math.max(now, physical);
  const counter = time === physical ? parseInt(previous.slice(14, 22), 16) + 1 : 0;
  return `${(counter > 0xffffffff ? time + 1 : time).toString(16).padStart(13, '0')}-${(counter > 0xffffffff ? 0 : counter).toString(16).padStart(8, '0')}-${deviceId}`;
}

export function fontReplica(font: CustomFont, userId: string, stamp: string, deviceId: string): FontReplicaRow {
  const fields: Record<string, ReplicaField> = {
    'name': replicaField(font.name, stamp, deviceId), 'family': replicaField(font.family, stamp, deviceId),
    'style': replicaField(font.style, stamp, deviceId), 'weight': replicaField(font.weight, stamp, deviceId),
    'variable': replicaField(font.variable, stamp, deviceId), 'byteSize': replicaField(font.byteSize, stamp, deviceId),
    'downloadedAt': replicaField(font.downloadedAt, stamp, deviceId)
  };
  return { user_id: userId, kind: 'font', replica_id: font.id, fields_jsonb: fields,
    manifest_jsonb: { files: [{ filename: font.filename, byteSize: font.byteSize, partialMd5: font.partialMd5 }], schemaVersion: 1 },
    deleted_at_ts: null, reincarnation: font.reincarnation || null, updated_at_ts: stamp, schema_version: 1 };
}

export function validFontRow(row: FontReplicaRow, userId: string): boolean {
  if (!row || row.user_id !== userId || row.kind !== 'font' || !/^[a-f0-9]{32}$/.test(row.replica_id) ||
    row.schema_version !== 1 || !isHlc(row.updated_at_ts)) return false;
  if (row.deleted_at_ts) return isHlc(row.deleted_at_ts);
  if (!row.fields_jsonb || typeof row.fields_jsonb.name?.v !== 'string') return false;
  if (row.manifest_jsonb === null) return true;
  if (!row.manifest_jsonb || row.manifest_jsonb.schemaVersion !== 1 || !Array.isArray(row.manifest_jsonb.files) || row.manifest_jsonb.files.length !== 1) return false;
  const file = row.manifest_jsonb.files[0];
  return typeof file.filename === 'string' && !/[\\/\x00-\x1f\x7f]/.test(file.filename) && !file.filename.includes('..') &&
    file.filename.length <= 200 && Number.isSafeInteger(file.byteSize) &&
    file.byteSize > 0 && /^[a-f0-9]{32}$/.test(file.partialMd5);
}

export class ReplicaClient {
  private transport: SyncTransport;
  private base: string;
  constructor(transport: SyncTransport, base: string = 'https://web.readest.com/api') { this.transport = transport; this.base = base; }

  private check(status: number): void {
    if (status === 401 || status === 403) throw new Error('AUTH_FAILED');
    if (status === 402 || status === 507) throw new Error('SYNC_QUOTA');
    if (status === 409) throw new Error('SYNC_CLOCK');
    if (status < 200 || status >= 300) throw new Error('SERVER_ERROR');
  }

  async signIn(email: string, password: string, refreshToken: string = ''): Promise<ReplicaSettings> {
    const refresh = !!refreshToken;
    const headers: Record<string, string> = { 'apikey': READEST_ANON_KEY, 'Content-Type': 'application/json' };
    const payload: Record<string, string> = refresh ? { 'refresh_token': refreshToken } : { 'email': email, 'password': password };
    const response = await this.transport.request(`${READEST_AUTH_URL}/auth/v1/token?grant_type=${refresh ? 'refresh_token' : 'password'}`, 'POST',
      headers, JSON.stringify(payload));
    if (response.status === 400) throw new Error('AUTH_FAILED'); this.check(response.status);
    const auth = JSON.parse(response.body) as AuthResponse;
    if (!auth.access_token || !auth.refresh_token || !auth.user?.id || !Number.isFinite(auth.expires_in) || auth.expires_in <= 0) throw new Error('AUTH_FAILED');
    const settings = new ReplicaSettings(); settings.accessToken = auth.access_token; settings.refreshToken = auth.refresh_token;
    settings.userId = auth.user.id; settings.email = auth.user.email; settings.expiresAt = Date.now() + auth.expires_in * 1000; return settings;
  }

  private async request(config: ReplicaSettings, endpoint: string, method: string = 'GET', body?: string): Promise<string> {
    if (!config.accessToken || !config.userId) throw new Error('AUTH_FAILED');
    const headers: Record<string, string> = { 'Authorization': `Bearer ${config.accessToken}`, 'Content-Type': 'application/json' };
    const response = await this.transport.request(`${this.base}${endpoint}`, method,
      headers, body);
    if (response.status === 403 && response.body.includes('Insufficient storage')) throw new Error('SYNC_QUOTA');
    this.check(response.status); return response.body;
  }

  async pull(config: ReplicaSettings): Promise<FontReplicaRow[]> {
    const suffix = config.cursor ? `&since=${encodeURIComponent(config.cursor)}` : '';
    const data = JSON.parse(await this.request(config, `/sync/replicas?kind=font${suffix}`)) as ReplicaRows;
    if (!Array.isArray(data.rows) || data.rows.length > 1000 || !data.rows.every((row: FontReplicaRow) => validFontRow(row, config.userId))) throw new Error('INVALID_REPLICA');
    return data.rows;
  }

  async push(config: ReplicaSettings, row: FontReplicaRow): Promise<FontReplicaRow> {
    const payload: ReplicaRows = { rows: [row] };
    const data = JSON.parse(await this.request(config, '/sync/replicas', 'POST', JSON.stringify(payload))) as ReplicaRows;
    if (!Array.isArray(data.rows) || data.rows.length !== 1 || data.rows[0].replica_id !== row.replica_id || !validFontRow(data.rows[0], config.userId)) throw new Error('INVALID_REPLICA');
    return data.rows[0];
  }

  async uploadURL(config: ReplicaSettings, font: CustomFont): Promise<string> {
    const payload: UploadRequest = {
      fileName: `Readest/Replicas/font/${font.id}/${font.filename}`, fileSize: font.byteSize, replicaKind: 'font', replicaId: font.id, temp: false
    };
    const data = JSON.parse(await this.request(config, '/storage/upload', 'POST', JSON.stringify(payload))) as SignedTransfer;
    if (typeof data.uploadUrl !== 'string' || !data.uploadUrl.startsWith('https://')) throw new Error('INVALID_REPLICA'); return data.uploadUrl;
  }

  async downloadURL(config: ReplicaSettings, id: string, filename: string): Promise<string> {
    const key = `${config.userId}/Readest/Replicas/font/${id}/${filename}`;
    const data = JSON.parse(await this.request(config, `/storage/download?fileKey=${encodeURIComponent(key)}`)) as SignedTransfer;
    if (typeof data.downloadUrl !== 'string' || !data.downloadUrl.startsWith('https://')) throw new Error('INVALID_REPLICA'); return data.downloadUrl;
  }
}
