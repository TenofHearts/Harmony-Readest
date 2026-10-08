import { BookRecord, RemoteProgress } from './Models';

export type SyncDecision = 'none' | 'pull' | 'push' | 'conflict';

export function remoteToken(remote: RemoteProgress): string {
  return `${remote.progress || ''}|${remote.percentage ?? ''}|${remote.timestamp ?? ''}|${remote.device_id || ''}`;
}

export function uploadedToken(position: string, percentage: number, deviceId: string): string {
  return `upload:${position}|${percentage}|${deviceId}`;
}

export function decideSync(book: BookRecord, remote: RemoteProgress | null): SyncDecision {
  if (!remote) return book.position.cfi && book.position.xpointer ? 'push' : 'none';
  if (!book.position.cfi) return 'pull';
  if (remote.progress === book.position.xpointer && !!remote.progress) return book.dirty ? 'push' : 'none';
  // Acknowledged or explicitly chosen reports do not prompt again unchanged.
  if (remoteToken(remote) === book.remoteToken ||
    uploadedToken(remote.progress || '', remote.percentage ?? -1, remote.device_id || '') === book.remoteToken) {
    return book.dirty ? 'push' : 'none';
  }
  return 'conflict';
}

export function isCurrentSession(expected: string, received: string): boolean {
  return expected.length > 0 && expected === received;
}

export function canAcknowledge(sentRevision: number, currentRevision: number): boolean {
  return sentRevision === currentRevision;
}
