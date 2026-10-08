import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SyncResponse, SyncTransport } from '../core/Models';

export class NativeTransport implements SyncTransport {
  async request(url: string, method: string, headers: Record<string, string>, body?: string): Promise<SyncResponse> {
    const request = http.createHttp();
    try {
      const result = await request.request(url, { method: method === 'PUT' ? http.RequestMethod.PUT : http.RequestMethod.GET,
        header: headers, extraData: body || '', expectDataType: http.HttpDataType.STRING,
        connectTimeout: 10000, readTimeout: 15000, usingCache: false, usingProxy: true });
      return { status: result.responseCode, body: result.result as string };
    } catch (error) {
      const code = (error as BusinessError).code;
      if (code === 2300028) throw new Error('NETWORK_TIMEOUT');
      if (code === 2300005 || code === 2300006) throw new Error('NETWORK_DNS');
      if (code === 2300035 || code === 2300051 || code === 2300060) throw new Error('NETWORK_TLS');
      throw new Error('NETWORK_ERROR');
    } finally { request.destroy(); }
  }
}
