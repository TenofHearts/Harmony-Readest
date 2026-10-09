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
  metadataJSON: string = '';
  title: string = '';
  author: string = '';
  hash: string = '';
  toc: TocEntry[] = [];
}

export class BookRecord {
  annotations: BookAnnotation[] = [];
  metadataJSON: string = '';
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
  cloudAccount: string = '';
  cloudBook: string = '';
  cloudConfig: string = '';
  cloudUploaded: boolean = false;
  cloudDeleted: boolean = false;
  style: ReaderSettings | null = null;
  styleUpdatedAt: number = 0;
  styleDirty: boolean = false;
}

export class BookAnnotation {
  id: string = '';
  kind: string = 'bookmark';
  cfi: string = '';
  text: string = '';
  chapter: string = '';
  percentage: number = 0;
  color: string = '#fff176';
  createdAt: number = 0;
}

export class ThemeSettings {
  themeMode: string = 'auto';
  themeColor: string = 'default';
}

export class ReaderSettings extends ThemeSettings {
  fontSize: number = 20;
  lineHeight: number = 1.7;
  minimumFontSize: number = 8;
  fontWeight: number = 400;
  overrideFont: boolean = false;
  defaultFont: string = 'serif';
  serifFont: string = 'serif';
  sansSerifFont: string = 'sans-serif';
  monospaceFont: string = 'monospace';
  defaultCJKFont: string = '';
  useBookLayout: boolean = false;
  paragraphMargin: number = 1;
  wordSpacing: number = 0;
  letterSpacing: number = 0;
  textIndent: number = 0;
  fullJustification: boolean = false;
  hyphenation: boolean = true;
  marginTopPx: number = 12;
  marginBottomPx: number = 12;
  marginLeftPx: number = 24;
  marginRightPx: number = 24;
  gapPercent: number = 4;
  columnGapPx: number = 32;
  maxColumnCount: number = 2;
  maxInlineSize: number = 720;
  maxBlockSize: number = 9999;
  scrolled: boolean = false;
}

export class CustomFont {
  id: string = '';
  filename: string = '';
  name: string = '';
  family: string = '';
  style: string = 'normal';
  weight: number = 400;
  variable: boolean = false;
  path: string = '';
  byteSize: number = 0;
  partialMd5: string = '';
  downloadedAt: number = 0;
  publishedFor: string = '';
  reincarnation: string = '';
}

export class ReaderFont {
  family: string = '';
  style: string = 'normal';
  weight: string = '400';
  url: string = '';
}

export class ReplicaSettings {
  sessionEpoch: number = -1;
  accessToken: string = '';
  refreshToken: string = '';
  expiresAt: number = 0;
  userId: string = '';
  email: string = '';
  enabled: boolean = true;
  syncFonts: boolean = true;
  cursor: string = '';
  clock: string = '';
  lastSyncedAt: number = 0;
  pendingDeletes: string[] = [];
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
  cfi?: string;
  document?: string;
  progress?: string;
  percentage?: number;
  timestamp?: number;
  device?: string;
  device_id?: string;
}

export class ReaderCommand {
  annotations?: BookAnnotation[];
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
  fonts?: ReaderFont[];
}

export class ReaderChromeState {
  controls: boolean = false;
  syncEnabled: boolean = false;
  busy: boolean = false;
  status: string = '';
  labels: Record<string, string> = {};
  safeTop: number = 0;
  safeBottom: number = 0;
}

export interface ReaderEvent {
  annotations?: BookAnnotation[];
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
  acceptRemote?(hash: string, position: ReadingPosition): Promise<void>;
}
