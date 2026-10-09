export const KOSYNC_STRATEGIES: string[] = ['prompt', 'silent', 'send', 'receive'];

export function parseCustomHeaders(input: string): Record<string, string> {
  const headers: Record<string, string> = {};
  if (input.length > 8192) throw new Error('INVALID_HEADERS');
  for (const line of input.split('\n')) {
    if (!line.trim()) continue;
    const split = line.indexOf(':');
    const name = line.slice(0, split).trim(), value = line.slice(split + 1).trim();
    if (split < 1 || !/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(name) || !value || /[\x00-\x1f\x7f]/.test(value) ||
      ['host', 'content-length', 'authorization', 'x-auth-user', 'x-auth-key'].includes(name.toLowerCase())) throw new Error('INVALID_HEADERS');
    headers[name] = value;
  }
  return headers;
}

export function formatCustomHeaders(headers: Record<string, string>): string {
  const values: Record<string, string> = headers || {};
  return Object.keys(values).map((key: string) => `${key}: ${values[key]}`).join('\n');
}
