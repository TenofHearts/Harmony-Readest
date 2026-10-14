// Native rendering model for bundled legal Markdown. Never execute embedded HTML.
export class LegalSpan {
  text: string = '';
  url: string = '';
  bold: boolean = false;
  code: boolean = false;
}

export class LegalBlock {
  kind: string = 'paragraph';
  level: number = 0;
  spans: LegalSpan[] = [];
}

export function legalSpans(text: string): LegalSpan[] {
  const spans: LegalSpan[] = [];
  const pattern = /\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)|`([^`]+)`|\*\*([^*]+)\*\*|https?:\/\/[^\s<>`]+/g;
  let offset = 0;
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(text)) !== null) {
    if (match.index > offset) { const plain = new LegalSpan(); plain.text = text.slice(offset, match.index); spans.push(plain); }
    const span = new LegalSpan();
    span.text = match[1] || match[3] || match[4] || match[0];
    span.url = match[2] || (match[0].startsWith('http') ? match[0] : '');
    span.code = !!match[3]; span.bold = !!match[4]; spans.push(span);
    offset = match.index + match[0].length;
  }
  if (offset < text.length) { const plain = new LegalSpan(); plain.text = text.slice(offset); spans.push(plain); }
  return spans;
}

export function legalBlocks(markdown: string): LegalBlock[] {
  const blocks: LegalBlock[] = [];
  const lines = markdown.replace(/\r/g, '').split('\n');
  let paragraph: string[] = [];
  let headers: string[] = [];
  const flush = (): void => {
    if (!paragraph.length) return;
    const block = new LegalBlock(); block.spans = legalSpans(paragraph.join('\n')); blocks.push(block); paragraph = [];
  };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) { flush(); headers = []; continue; }
    if (/^\|.*\|$/.test(line)) {
      flush();
      if (/^\|[\s:|\-]+\|$/.test(line)) continue;
      const cells = line.slice(1, -1).split('|').map((cell: string) => cell.trim());
      if (!headers.length) { headers = cells; continue; }
      // Table entries become readable stacked cards on narrow phone screens.
      const block = new LegalBlock(); block.kind = 'table';
      block.spans = legalSpans(cells.map((cell: string, index: number) => `**${headers[index] || ''}:** ${cell}`).join('\n'));
      blocks.push(block); continue;
    }
    headers = [];
    const heading = /^(#{1,6})\s+(.+)$/.exec(line);
    if (heading) {
      flush(); const block = new LegalBlock(); block.kind = 'heading'; block.level = heading[1].length;
      block.spans = legalSpans(heading[2]); blocks.push(block);
    } else if (/^([-*_])\1\1+$/.test(line)) {
      flush(); const block = new LegalBlock(); block.kind = 'rule'; blocks.push(block);
    } else if (/^[-*]\s+/.test(line)) {
      flush(); const block = new LegalBlock(); block.spans = legalSpans('• ' + line.slice(2)); blocks.push(block);
    } else paragraph.push(lines[i]);
  }
  flush(); return blocks;
}
