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

export class ThemeSettings {
  themeMode: string = 'auto';
  themeColor: string = 'default';
}

export class ReaderSettings extends ThemeSettings {
  fontSize: number = 20;
  lineHeight: number = 1.7;
}

export class KoSyncSettings {
  serverUrl: string = 'https://sync.koreader.rocks';
  username: string = '';
  password: string = '';
  userkey: string = '';
  basicKey: string = '';
  enabled: boolean = false;
  deviceName: string = 'Readest';
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
  metadataOnly?: boolean;
  chrome?: ReaderChromeState;
  systemDark?: boolean;
}

export class ReaderChromeState {
  controls: boolean = true;
  syncEnabled: boolean = false;
  busy: boolean = false;
  status: string = '';
  labels: Record<string, string> = {};
  safeTop: number = 0;
  safeBottom: number = 0;
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
  action?: string;
  settings?: ReaderSettings;
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
  push(hash: string, position: ReadingPosition): Promise<RemoteProgress | null>;
}
