import { describe, it, expect } from '@ohos/hypium';
import { BookRecord, RemoteProgress } from '../main/ets/core/Models';
import { decideSync, remoteToken, isCurrentSession, canAcknowledge } from '../main/ets/core/SyncPolicy';

export default function syncPolicyTest() {
  describe('SyncPolicy', () => {
    it('newer_server_wins', 0, () => {
      const book = new BookRecord(); book.position.cfi = 'epubcfi(/6/2!/4/2:0)'; book.position.updatedAt = 20000;
      const remote: RemoteProgress = { progress: '/body/DocFragment[2]/body/p', timestamp: 30 };
      expect(decideSync(book, remote)).assertEqual('pull');
      remote.timestamp = 10; expect(decideSync(book, remote)).assertEqual('push');
    });
    it('ambiguous_times_require_choice', 0, () => {
      const book = new BookRecord(); book.position.cfi = 'epubcfi(/6/2!/4/2:0)'; book.position.updatedAt = 20000;
      const remote: RemoteProgress = { progress: '/body/DocFragment[2]/body/p', timestamp: 20 };
      expect(decideSync(book, remote)).assertEqual('conflict');
      remote.timestamp = undefined; expect(decideSync(book, remote)).assertEqual('conflict');
    });
    it('server_echo_preserves_pending_offline_change', 0, () => {
      const book = new BookRecord(); book.dirty = true; book.position.xpointer = '/body/DocFragment[3]/body/p';
      const remote: RemoteProgress = { progress: '/body/DocFragment[2]/body/p', timestamp: 20 };
      book.remoteToken = remoteToken(remote); expect(decideSync(book, remote)).assertEqual('push');
    });
    it('stale_session_and_ack_are_rejected', 0, () => {
      expect(isCurrentSession('current', 'previous')).assertFalse(); expect(isCurrentSession('', '')).assertFalse();
      expect(canAcknowledge(1, 2)).assertFalse(); expect(canAcknowledge(2, 2)).assertTrue();
    });
  });
}
