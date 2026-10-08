import { BookRecord, RemoteProgress } from './Models';

export type SyncDecision = 'none' | 'pull' | 'push' | 'conflict';

export function remoteToken(remote: RemoteProgress): string {
  return `${remote.progress || ''}|${remote.percentage ?? ''}|${remote.timestamp ?? ''}|${remote.device_id || ''}`;
}

export function decideSync(book: BookRecord, remote: RemoteProgress | null): SyncDecision {
  if (!remote) return book.dirty && !!book.position.xpointer ? 'push' : 'none';
  if (remote.progress === book.position.xpointer && !!remote.progress) return book.dirty ? 'push' : 'none';
  // A server's echo of our acknowledged upload is a baseline, not a new reading event.
  if (remoteToken(remote) === book.remoteToken) return book.dirty ? 'push' : 'none';
  if (!book.position.updatedAt || !book.position.cfi) return 'pull';
  if (!remote.timestamp || !Number.isFinite(remote.timestamp) || remote.timestamp <= 0) return 'conflict';
  const remoteTime = Math.floor(remote.timestamp * 1000);
  const localTime = Math.floor(book.position.updatedAt / 1000) * 1000;
  if (remoteTime === localTime) return 'conflict';
  return remoteTime > localTime ? 'pull' : 'push';
}

export function isCurrentSession(expected: string, received: string): boolean {
  return expected.length > 0 && expected === received;
}

export function canAcknowledge(sentRevision: number, currentRevision: number): boolean {
  return sentRevision === currentRevision;
}
