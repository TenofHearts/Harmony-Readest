import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { ReplicaSettings, CustomFont } from '../core/Models';
import { FontReplicaRow, ReplicaClient, nextReplicaClock, fontReplica, supportedFontFile } from '../core/ReplicaClient';
import { MAX_FONT_BYTES } from '../core/FontPolicy';
import { CredentialVault } from './CredentialVault';
import { NativeTransport } from './NativeTransport';
import { FontLibrary } from './FontLibrary';
import { errorMessage } from '../core/Errors';
import { CloudClient, StorageCondition } from '../core/CloudClient';

export class ReplicaService {
  config: ReplicaSettings = new ReplicaSettings();
  busy: boolean = false;
  status: string = 'idle';
  error: string = '';
  changed: () => void = () => {};
  fontsChanged: () => Promise<void> = async () => {};
  cloudSync: (config: ReplicaSettings) => Promise<void> = async () => {};
  afterSync: () => Promise<void> = async () => {};
  storage: StorageCondition | null = null;
  storageBusy: boolean = false;
  storageError: string = '';
  pendingProgress: number = 0;
  private cloud: CloudClient = new CloudClient(new NativeTransport());
  private refresh?: Promise<void>;
  private vault: CredentialVault = new CredentialVault('harmonyreadest.replica.v1', 'replica_secrets');
  private client: ReplicaClient = new ReplicaClient(new NativeTransport());
  private fonts: FontLibrary;
  private deviceId: string = '';
  private epoch: number = 0;
  private inflight?: Promise<void>;
  private timer: number = -1;

  constructor(fonts: FontLibrary) { this.fonts = fonts; }

  async init(context: common.UIAbilityContext, deviceId: string): Promise<void> {
    await this.vault.init(context); this.deviceId = deviceId;
    try { const saved = await this.vault.loadText(); if (saved) this.config = JSON.parse(saved) as ReplicaSettings; }
    catch { this.error = 'CREDENTIALS_UNAVAILABLE'; }
    this.config.pendingDeletes = this.config.pendingDeletes || [];
    this.timer = setInterval(() => { this.sync().catch(() => {}); }, 60000);
  }

  private async stop(): Promise<void> { this.epoch++; await this.inflight?.catch(() => {}); }
  private async save(): Promise<void> { await this.vault.saveText(JSON.stringify(this.config)); }

  validSession(config: ReplicaSettings): boolean { return config.userId === this.config.userId && config.sessionEpoch === this.epoch; }
  async session(): Promise<ReplicaSettings> {
    if (!this.config.userId) throw new Error('AUTH_FAILED');
    if (this.config.expiresAt < Date.now() + 60000) {
      if (!this.refresh) {
        const epoch = this.epoch;
        this.refresh = this.client.signIn('', '', this.config.refreshToken).then(async (refreshed: ReplicaSettings) => {
          this.active(epoch); if (refreshed.userId !== this.config.userId) throw new Error('AUTH_FAILED');
          this.config.accessToken = refreshed.accessToken; this.config.refreshToken = refreshed.refreshToken; this.config.expiresAt = refreshed.expiresAt;
          await this.save();
        }).finally(() => { this.refresh = undefined; });
      }
      await this.refresh;
    }
    const config = JSON.parse(JSON.stringify(this.config)) as ReplicaSettings; config.sessionEpoch = this.epoch; return config;
  }
  async refreshStorage(): Promise<void> {
    if (!this.config.userId || this.storageBusy) return;
    const epoch = this.epoch; this.storageBusy = true; this.storageError = ''; this.changed();
    try { const config = await this.session(); const storage = await this.cloud.storage(config); this.active(epoch); this.storage = storage; }
    catch (error) { if (epoch === this.epoch) this.storageError = errorMessage(error as Error); }
    finally { this.storageBusy = false; this.changed(); }
  }

  async connect(email: string, password: string): Promise<void> {
    if (!email.trim() || !password) throw new Error('CREDENTIALS_REQUIRED');
    const authenticated = await this.client.signIn(email.trim(), password);
    await this.stop(); await this.vault.saveText(JSON.stringify(authenticated)); this.config = authenticated;
    this.storage = null; this.storageError = '';
    this.error = ''; this.status = 'connected'; this.changed(); await this.sync();
  }

  async disconnect(): Promise<void> {
    await this.stop(); await this.vault.clear(); this.config = new ReplicaSettings(); this.status = 'idle'; this.error = ''; this.changed();
    this.storage = null; this.storageError = ''; this.pendingProgress = 0; this.changed();
  }

  async options(enabled: boolean, syncFonts: boolean): Promise<void> {
    await this.stop(); const previous = this.config;
    const updated = JSON.parse(JSON.stringify(previous)) as ReplicaSettings; updated.enabled = enabled; updated.syncFonts = syncFonts;
    await this.vault.saveText(JSON.stringify(updated)); this.config = updated; this.changed();
    if (enabled) await this.sync();
  }

  async removeFont(id: string): Promise<void> {
    await this.stop();
    if (this.config.userId && this.config.enabled && this.config.syncFonts && !this.config.pendingDeletes.includes(id)) {
      this.config.pendingDeletes.push(id); await this.save();
    }
    await this.fonts.remove(id); await this.fontsChanged(); this.changed(); this.sync().catch(() => {});
  }

  sync(): Promise<void> {
    if (this.inflight) return this.inflight;
    if (!this.config.userId || !this.config.enabled) return Promise.resolve();
    const epoch = this.epoch;
    this.inflight = this.perform(epoch).catch((error: Error) => {
      if (epoch === this.epoch) { this.error = errorMessage(error); this.status = 'error'; } throw error;
    }).finally(async () => { await this.refreshStorage(); this.inflight = undefined; this.busy = false; this.changed(); });
    return this.inflight;
  }

  private active(epoch: number): void { if (epoch !== this.epoch) throw new Error('SESSION_CLOSED'); }
  private async stamp(): Promise<string> { this.config.clock = nextReplicaClock(this.config.clock, this.deviceId); await this.save(); return this.config.clock; }

  private async transfer(url: string, bytes?: ArrayBuffer): Promise<ArrayBuffer> {
    if (!url.startsWith('https://')) throw new Error('HTTPS_REQUIRED');
    const request = http.createHttp();
    try {
      // Signed object URLs receive no account authorization headers.
      const response = await request.request(url, { method: bytes ? http.RequestMethod.PUT : http.RequestMethod.GET,
        extraData: bytes || '', expectDataType: http.HttpDataType.ARRAY_BUFFER, connectTimeout: 10000, readTimeout: 60000,
        usingCache: false, usingProxy: true, maxLimit: MAX_FONT_BYTES });
      if (response.responseCode < 200 || response.responseCode >= 300) throw new Error('SERVER_ERROR');
      return response.result as ArrayBuffer;
    } finally { request.destroy(); }
  }

  private async apply(row: FontReplicaRow, epoch: number): Promise<void> {
    this.active(epoch);
    if (row.updated_at_ts > this.config.clock) this.config.clock = row.updated_at_ts;
    const existing = this.fonts.fonts.find((font: CustomFont) => font.id === row.replica_id);
    if (row.deleted_at_ts) {
      // An explicit import after the deletion may reincarnate the content id.
      if (existing && !existing.publishedFor && existing.downloadedAt > parseInt(row.deleted_at_ts.slice(0, 13), 16)) return;
      await this.fonts.remove(row.replica_id); return;
    }
    if (this.config.pendingDeletes.includes(row.replica_id)) return;
    if (!row.manifest_jsonb) return;
    if (existing) { existing.publishedFor = this.config.userId; existing.reincarnation = row.reincarnation || ''; await this.fonts.save(); return; }
    const file = row.manifest_jsonb.files[0];
    if (!supportedFontFile(file)) return;
    const url = await this.client.downloadURL(this.config, row.replica_id, file.filename); this.active(epoch);
    const bytes = await this.transfer(url); this.active(epoch);
    if (bytes.byteLength !== file.byteSize) throw new Error('INVALID_FONT');
    const installed = await this.fonts.install(bytes, file.filename, row.replica_id, file.partialMd5); this.active(epoch);
    installed.publishedFor = this.config.userId; installed.reincarnation = row.reincarnation || ''; await this.fonts.save();
  }

  private async perform(epoch: number): Promise<void> {
    this.busy = true; this.status = 'syncing'; this.error = ''; this.changed();
    const session = await this.session(); this.active(epoch);
    let failure: Error | undefined;
    try { await this.cloudSync(session); this.active(epoch); } catch (error) { failure = error as Error; }
    try {
    if (this.config.syncFonts) {
    // Pull before upload so an old local file cannot resurrect a remote deletion.
    let rows: FontReplicaRow[];
    do {
      rows = await this.client.pull(this.config); this.active(epoch);
      let cursor = this.config.cursor;
      for (const row of rows) {
        await this.apply(row, epoch); this.active(epoch);
        if (row.updated_at_ts > cursor) cursor = row.updated_at_ts;
      }
      this.config.cursor = cursor; await this.save();
    } while (rows.length === 1000);
    for (const id of [...this.config.pendingDeletes]) {
      this.active(epoch); const stamp = await this.stamp();
      const tombstone: FontReplicaRow = { user_id: this.config.userId, kind: 'font', replica_id: id, fields_jsonb: {},
        manifest_jsonb: null, deleted_at_ts: stamp, reincarnation: null, updated_at_ts: stamp, schema_version: 1 };
      await this.client.push(this.config, tombstone); this.active(epoch);
      this.config.pendingDeletes = this.config.pendingDeletes.filter((value: string) => value !== id); await this.save();
    }
    for (const font of [...this.fonts.fonts]) {
      this.active(epoch); if (font.publishedFor === this.config.userId) continue;
      const initial = fontReplicaMetadata(font, this.config.userId, await this.stamp(), this.deviceId);
      const accepted = await this.client.push(this.config, initial); this.active(epoch);
      if (accepted.deleted_at_ts) { await this.apply(accepted, epoch); continue; }
      const url = await this.client.uploadURL(this.config, font); this.active(epoch);
      const bytes = await this.fonts.bytes(font.path); this.active(epoch); await this.transfer(url, bytes); this.active(epoch);
      const complete = fontReplicaMetadata(font, this.config.userId, await this.stamp(), this.deviceId);
      complete.fields_jsonb = {}; complete.manifest_jsonb = { files: [{ filename: font.filename, byteSize: font.byteSize, partialMd5: font.partialMd5 }], schemaVersion: 1 };
      const merged = await this.client.push(this.config, complete); this.active(epoch);
      await this.apply(merged, epoch);
    }
    await this.fontsChanged();
    }
    } catch (error) { if (!failure) failure = error as Error; }
    this.active(epoch);
    if (failure) throw failure;
    await this.afterSync(); this.active(epoch);
    this.config.lastSyncedAt = Date.now(); await this.save(); this.status = 'synced'; this.changed();
  }

  dispose(): void { this.epoch++; clearInterval(this.timer); this.changed = () => {}; }
}

function fontReplicaMetadata(font: CustomFont, userId: string, stamp: string, deviceId: string): FontReplicaRow {
  const row = fontReplica(font, userId, stamp, deviceId); row.manifest_jsonb = null;
  return row;
}
