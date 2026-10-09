import { BookRecord } from './Models';

function metadataText(value: Object): string {
  if (typeof value === 'string') return value;
  if (Array.isArray(value)) return value.map((item: Object) => metadataText(item)).filter((item: string) => !!item).join(', ');
  if (value && typeof value === 'object') {
    const record = value as Record<string, Object>;
    return metadataText(record['name'] || record['value'] || '');
  }
  return '';
}

export class BookDetails {
  title: string = '';
  author: string = '';
  cover: string = '';
  filename: string = '';
  publisher: string = '';
  language: string = '';
  published: string = '';
  identifier: string = '';
  description: string = '';
  imported: string = '';
  progress: string = '';
}

export function bookDetails(book: BookRecord): BookDetails {
  const details = new BookDetails();
  details.title = book.title; details.author = book.author; details.cover = book.cover; details.filename = book.filename;
  details.imported = book.importedAt ? new Date(book.importedAt).toLocaleDateString() : '';
  details.progress = `${Math.round(book.position.percentage * 100)}%`;
  try {
    const metadata = JSON.parse(book.metadataJSON || '{}') as Record<string, Object>;
    details.publisher = metadataText(metadata['publisher']); details.language = metadataText(metadata['language']);
    details.published = metadataText(metadata['published'] || metadata['date']); details.identifier = metadataText(metadata['identifier']);
    details.description = metadataText(metadata['description'])
      .replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1>/gi, '')
      .replace(/<\/?(?:p|div|br|li)\b[^>]*>/gi, '\n').replace(/<[^>]*>/g, '')
      .replace(/&nbsp;/g, ' ').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, '&').trim();
  } catch {}
  return details;
}
