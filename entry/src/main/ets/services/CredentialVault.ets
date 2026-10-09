import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { huks } from '@kit.UniversalKeystoreKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { KoSyncSettings } from '../core/Models';

interface SealedCredentials { nonce: string; ciphertext: string; }

export class CredentialVault {
  private prefs?: preferences.Preferences;
  private alias: string = 'harmonyreadest.kosync.v1';
  private preferenceName: string = 'kosync_secrets';
  private base64: util.Base64Helper = new util.Base64Helper();

  constructor(alias: string = 'harmonyreadest.kosync.v1', preferenceName: string = 'kosync_secrets') {
    this.alias = alias; this.preferenceName = preferenceName;
  }

  async init(context: common.UIAbilityContext): Promise<void> {
    this.prefs = await preferences.getPreferences(context, { name: this.preferenceName });
  }

  private properties(purpose: number, nonce?: Uint8Array, tag?: Uint8Array): huks.HuksParam[] {
    const params: huks.HuksParam[] = [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: purpose },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE }
    ];
    if (nonce) params.push({ tag: huks.HuksTag.HUKS_TAG_NONCE, value: nonce });
    if (tag) params.push({ tag: huks.HuksTag.HUKS_TAG_AE_TAG, value: tag });
    return params;
  }

  private async crypt(data: Uint8Array, nonce: Uint8Array, decrypt: boolean): Promise<Uint8Array> {
    const props = this.properties(decrypt ? huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT :
      huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT, nonce, decrypt ? data.slice(-16) : undefined);
    const options: huks.HuksOptions = { properties: props, inData: decrypt ? data.slice(0, -16) : data };
    const handle = await huks.initSession(this.alias, options);
    try {
      const result = await huks.finishSession(handle.handle, options);
      if (!result.outData) throw new Error('CREDENTIAL_STORAGE_FAILED');
      return result.outData;
    } catch (error) {
      try { await huks.abortSession(handle.handle, { properties: [] }); } catch {}
      throw error as Error;
    }
  }

  async load(): Promise<KoSyncSettings> {
    const value = await this.loadText();
    if (!value) return new KoSyncSettings();
    const saved = JSON.parse(value) as KoSyncSettings;
    saved.strategy = saved.strategy || 'prompt'; saved.customHeaders = saved.customHeaders || {};
    saved.sendMetadata = saved.sendMetadata || false; saved.lastSyncedAt = saved.lastSyncedAt || 0; return saved;
  }

  async loadText(): Promise<string> {
    const value = await this.prefs!.get('sealed', '') as string;
    if (!value) return '';
    const sealed = JSON.parse(value) as SealedCredentials;
    const plain = await this.crypt(this.base64.decodeSync(sealed.ciphertext), this.base64.decodeSync(sealed.nonce), true);
    return util.TextDecoder.create('utf-8').decodeToString(plain);
  }

  async save(settings: KoSyncSettings): Promise<void> {
    await this.saveText(JSON.stringify(settings));
  }

  async saveText(value: string): Promise<void> {
    // isKeyItemExist rejects when the key is absent; hasKeyItem returns false.
    if (!await huks.hasKeyItem(this.alias, { properties: [] })) {
      await huks.generateKeyItem(this.alias, { properties: this.properties(
        huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT) });
    }
    const nonce = cryptoFramework.createRandom().generateRandomSync(12).data;
    const bytes = new util.TextEncoder().encodeInto(value);
    const ciphertext = await this.crypt(bytes, nonce, false);
    const sealed: SealedCredentials = { nonce: this.base64.encodeToStringSync(nonce), ciphertext: this.base64.encodeToStringSync(ciphertext) };
    await this.prefs!.put('sealed', JSON.stringify(sealed)); await this.prefs!.flush();
  }

  async clear(): Promise<void> { await this.prefs!.delete('sealed'); await this.prefs!.flush(); }

  async prepare(settings: KoSyncSettings): Promise<void> {
    const encoder = new util.TextEncoder();
    const md = cryptoFramework.createMd('MD5');
    await md.update({ data: encoder.encodeInto(settings.password) });
    const digest = await md.digest();
    settings.userkey = Array.from(digest.data).map((n: number) => n.toString(16).padStart(2, '0')).join('');
    settings.basicKey = this.base64.encodeToStringSync(encoder.encodeInto(`${settings.username}:${settings.password}`));
  }
}
