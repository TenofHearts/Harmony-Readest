export class ReadingPosition {
  cfi: string = '';
  xpointer: string = '';
  percentage: number = 0;
  chapter: string = '';
  updatedAt: number = 0;
  revision: number = 0;
}

export class TocEntry {
  label: string = '';
  href: string = '';
  depth: number = 0;
}

export class BookMetadata {
  title: string = '';
  author: string = '';
  hash: string = '';
  toc: TocEntry[] = [];
}

export class BookRecord {
  id: string = '';
  title: string = '';
  author: string = '';
  filename: string = '';
  hash: string = '';
  path: string = '';
  cover: string = '';
  importedAt: number = 0;
  lastOpenedAt: number = 0;
  position: ReadingPosition = new ReadingPosition();
  dirty: boolean = false;
  syncScope: string = '';
  remoteToken: string = '';
  toc: TocEntry[] = [];
}

export class ReaderSettings {
  fontSize: number = 20;
  lineHeight: number = 1.7;
  theme: string = 'light';
}

export class KoSyncSettings {
  serverUrl: string = 'https://sync.koreader.rocks';
  username: string = '';
  password: string = '';
  userkey: string = '';
  basicKey: string = '';
  enabled: boolean = false;
  deviceName: string = 'HarmonyReadest';
  deviceId: string = '';
}

export interface RemoteProgress {
  document?: string;
  progress?: string;
  percentage?: number;
  timestamp?: number;
  device?: string;
  device_id?: string;
}

export class ReaderCommand {
  version: number = 1;
  session: string = '';
  type: string = '';
  url?: string;
  cfi?: string;
  xpointer?: string;
  href?: string;
  percentage?: number;
  settings?: ReaderSettings;
  requestId?: string;
}

export interface ReaderEvent {
  version: number;
  session: string;
  type: string;
  metadata?: BookMetadata;
  position?: ReadingPosition;
  cover?: string;
  restored?: boolean;
  message?: string;
  requestId?: string;
}

export interface SyncResponse {
  status: number;
  body: string;
}

export interface SyncTransport {
  request(url: string, method: string, headers: Record<string, string>, body?: string): Promise<SyncResponse>;
}

export interface ProgressSyncProvider {
  authenticate(): Promise<void>;
  pull(hash: string): Promise<RemoteProgress | null>;
  push(hash: string, position: ReadingPosition): Promise<void>;
}
