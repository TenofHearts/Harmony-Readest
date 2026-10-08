import { describe, it, expect } from '@ohos/hypium';
import { BookRecord, RemoteProgress } from '../main/ets/core/Models';
import { decideSync, remoteToken, isCurrentSession, canAcknowledge } from '../main/ets/core/SyncPolicy';

export default function syncPolicyTest() {
  describe('SyncPolicy', () => {
    it('different_positions_require_choice_independently_of_time', 0, () => {
      const book = new BookRecord(); book.position.cfi = 'epubcfi(/6/2!/4/2:0)'; book.position.updatedAt = 20000;
      book.position.percentage = .4;
      const remote: RemoteProgress = { progress: '/body/DocFragment[2]/body/p', percentage: .6, timestamp: 10 };
      expect(decideSync(book, remote)).assertEqual('conflict');
      remote.timestamp = 30; remote.percentage = .2; expect(decideSync(book, remote)).assertEqual('conflict');
    });
    it('equal_percentages_alone_cannot_establish_a_match', 0, () => {
      const book = new BookRecord(); book.position.cfi = 'epubcfi(/6/2!/4/2:0)'; book.position.updatedAt = 20000;
      book.position.percentage = .4;
      const remote: RemoteProgress = { progress: '/body/DocFragment[2]/body/p' };
      expect(decideSync(book, remote)).assertEqual('conflict');
      remote.percentage = .4; expect(decideSync(book, remote)).assertEqual('conflict');
    });
    it('acknowledged_server_echo_preserves_backwards_edits', 0, () => {
      const book = new BookRecord(); book.dirty = true; book.position.xpointer = '/body/DocFragment[3]/body/p';
      book.position.cfi = 'epubcfi(/6/2!/4/2:0)'; book.position.percentage = .2;
      const remote: RemoteProgress = { progress: '/body/DocFragment[4]/body/p', percentage: .6, timestamp: 20 };
      book.remoteToken = remoteToken(remote); expect(decideSync(book, remote)).assertEqual('push');
    });
    it('stale_session_and_ack_are_rejected', 0, () => {
      expect(isCurrentSession('current', 'previous')).assertFalse(); expect(isCurrentSession('', '')).assertFalse();
      expect(canAcknowledge(1, 2)).assertFalse(); expect(canAcknowledge(2, 2)).assertTrue();
    });
  });
}
