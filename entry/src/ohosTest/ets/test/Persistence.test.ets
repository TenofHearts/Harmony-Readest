import { describe, it, expect } from '@ohos/hypium';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { preferences } from '@kit.ArkData';
import { BookRecord, KoSyncSettings } from '../../../main/ets/core/Models';
import { Repository } from '../../../main/ets/services/Repository';
import { CredentialVault } from '../../../main/ets/services/CredentialVault';

export default function persistenceTest() {
  describe('NativePersistence', () => {
    it('reading_position_and_pending_change_survive_reopen', 0, async () => {
      const context = getContext() as common.UIAbilityContext;
      const store = new Repository(); await store.init(context);
      const book = new BookRecord(); book.id = `test-${util.generateRandomUUID()}`;
      book.path = `${store.directory}/${book.id}.epub`; book.position.cfi = 'epubcfi(/6/2!/4/2:12)';
      book.position.updatedAt = 20000; book.position.revision = 2; book.dirty = true; book.syncScope = 'test';
      await store.save(book);
      const reopened = new Repository(); await reopened.init(context);
      const result = (await reopened.list()).find((value: BookRecord) => value.id === book.id)!;
      expect(result.position.cfi).assertEqual(book.position.cfi); expect(result.dirty).assertTrue();
      expect(result.position.updatedAt).assertEqual(20000); await store.remove(book);
    });
    it('HUKS_credentials_round_trip_unicode_without_plaintext', 0, async () => {
      const context = getContext() as common.UIAbilityContext;
      const vault = new CredentialVault('harmonyreadest.kosync.test', 'kosync_secrets_test'); await vault.init(context);
      // Explicitly isolated namespace: running tests never replaces the user's credentials.
      const config = new KoSyncSettings(); config.username = '测试-reader'; config.password = '密码-🔐';
      await vault.prepare(config); await vault.save(config);
      const prefs = await preferences.getPreferences(context, { name: 'kosync_secrets_test' });
      const sealed = await prefs.get('sealed', '') as string;
      expect(sealed.includes(config.password)).assertFalse(); expect(sealed.includes(config.username)).assertFalse();
      const loaded = await vault.load(); expect(loaded.password).assertEqual(config.password);
      expect(loaded.userkey).assertEqual(config.userkey); await vault.clear();
    });
  });
}
