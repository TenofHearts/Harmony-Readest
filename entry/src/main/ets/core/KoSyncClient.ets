import { KoSyncSettings, ProgressSyncProvider, ReadingPosition, RemoteProgress, SyncTransport, SyncResponse } from './Models';

export function normalizeServer(value: string): string {
  const url = value.trim().replace(/\/+$/, '');
  if (!/^https:\/\/[^/?#\s@]+(?::\d+)?(?:\/[^?#\s]*)?$/.test(url)) throw new Error('HTTPS_REQUIRED');
  return url;
}

export class KoSyncClient implements ProgressSyncProvider {
  private basic: boolean = false;
  private base: string;
  private config: KoSyncSettings;
  private transport: SyncTransport;
  constructor(config: KoSyncSettings, transport: SyncTransport) {
    this.config = config; this.transport = transport;
    this.base = normalizeServer(config.serverUrl);
  }

  private async request(endpoint: string, method: string = 'GET', body?: string): Promise<SyncResponse> {
    let headers: Record<string, string> = { 'Accept': 'application/vnd.koreader.v1+json',
      'Content-Type': 'application/json', 'X-Auth-User': this.config.username, 'X-Auth-Key': this.config.userkey };
    if (this.basic) headers = { 'Accept': 'application/vnd.koreader.v1+json', 'Content-Type': 'application/json',
      'Authorization': `Basic ${this.config.basicKey}` };
    let response = await this.transport.request(`${this.base}${endpoint}`, method, headers, body);
    if (!this.basic && (response.status === 400 || response.status === 401) && this.config.basicKey) {
      this.basic = true;
      response = await this.request(endpoint, method, body);
      if (response.status >= 400) this.basic = false;
    }
    return response;
  }

  async authenticate(): Promise<void> {
    const response = await this.request('/users/auth');
    this.check(response);
    const json = JSON.parse(response.body) as Record<string, string>;
    if (!json || typeof json !== 'object' || Array.isArray(json) || json.authorized !== 'OK') throw new Error('NOT_KOSYNC');
  }

  private check(response: SyncResponse): void {
    if (response.status === 401 || response.status === 403) throw new Error('AUTH_FAILED');
    if (response.status < 200 || response.status >= 300) throw new Error(`SERVER_ERROR:${response.status}`);
    try { JSON.parse(response.body); } catch { throw new Error('NOT_KOSYNC'); }
  }

  async pull(hash: string): Promise<RemoteProgress | null> {
    if (!/^[0-9a-f]{32}$/.test(hash)) throw new Error('INVALID_DOCUMENT_HASH');
    const response = await this.request(`/syncs/progress/${hash}`);
    if (response.status === 404) return null;
    this.check(response);
    const remote = JSON.parse(response.body) as RemoteProgress;
    if (!remote || typeof remote !== 'object' || Array.isArray(remote)) throw new Error('INVALID_PROGRESS');
    // Stock KoSync and CrossPoint use an empty successful response for a new book.
    if (Object.keys(remote).length === 0) return null;
    if (remote.document && remote.document !== hash) throw new Error('DOCUMENT_MISMATCH');
    const hasPointer = typeof remote.progress === 'string' && remote.progress.length > 0;
    const hasFraction = typeof remote.percentage === 'number' && Number.isFinite(remote.percentage) &&
      remote.percentage >= 0 && remote.percentage <= 1;
    if (remote.percentage !== undefined && !hasFraction) throw new Error('INVALID_PROGRESS');
    if (!hasPointer && !hasFraction) throw new Error('INVALID_PROGRESS');
    if (remote.timestamp !== undefined && (typeof remote.timestamp !== 'number' || !Number.isFinite(remote.timestamp))) {
      throw new Error('INVALID_TIMESTAMP');
    }
    return remote;
  }

  async push(hash: string, position: ReadingPosition): Promise<RemoteProgress | null> {
    if (!/^[0-9a-f]{32}$/.test(hash) || !position.xpointer.startsWith('/body/DocFragment') ||
      !Number.isFinite(position.percentage) || position.percentage < 0 || position.percentage > 1) {
      throw new Error('UNRESOLVED_POSITION');
    }
    const payload: RemoteProgress = { document: hash, progress: position.xpointer, percentage: position.percentage,
      device: this.config.deviceName, device_id: this.config.deviceId };
    const response = await this.request('/syncs/progress', 'PUT', JSON.stringify(payload));
    this.check(response);
    const ack = JSON.parse(response.body) as RemoteProgress;
    if (!ack || typeof ack !== 'object' || Array.isArray(ack)) throw new Error('INVALID_PROGRESS');
    if (ack.document && ack.document !== hash) throw new Error('DOCUMENT_MISMATCH');
    if (ack.timestamp !== undefined) {
      if (typeof ack.timestamp !== 'number' || !Number.isFinite(ack.timestamp) || ack.timestamp <= 0) throw new Error('INVALID_TIMESTAMP');
      payload.timestamp = ack.timestamp;
      return payload;
    }
    // Some stock-compatible servers acknowledge only with { updated: 'OK' }.
    return payload;
  }
}
