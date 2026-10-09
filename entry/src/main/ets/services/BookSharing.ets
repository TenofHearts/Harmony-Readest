import { common } from '@kit.AbilityKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { systemShare } from '@kit.ShareKit';
import { BookRecord } from '../core/Models';

export async function shareBook(context: common.UIAbilityContext, book: BookRecord): Promise<void> {
  if (!book.path || !fs.accessSync(book.path)) throw new Error('BOOK_NOT_FOUND');
  const data = new systemShare.SharedData({
    utd: uniformTypeDescriptor.UniformDataType.EPUB,
    uri: fileUri.getUriFromPath(book.path),
    title: book.title,
    description: book.author
  });
  await new systemShare.ShareController(data).show(context, { previewMode: systemShare.SharePreviewMode.DETAIL });
}
