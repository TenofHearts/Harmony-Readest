import { http } from '@kit.NetworkKit';
import { SyncResponse, SyncTransport } from '../core/Models';

export class NativeTransport implements SyncTransport {
  async request(url: string, method: string, headers: Record<string, string>, body?: string): Promise<SyncResponse> {
    const request = http.createHttp();
    try {
      const result = await request.request(url, { method: method === 'PUT' ? http.RequestMethod.PUT : http.RequestMethod.GET,
        header: headers, extraData: body || '', expectDataType: http.HttpDataType.STRING,
        connectTimeout: 10000, readTimeout: 15000, usingCache: false });
      return { status: result.responseCode, body: result.result as string };
    } finally { request.destroy(); }
  }
}
