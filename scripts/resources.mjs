import { mkdir, writeFile } from 'node:fs/promises';
const strings = {
  module_desc: ['HarmonyOS EPUB reader', '鸿蒙 EPUB 阅读器'], EntryAbility_desc: ['Read and sync EPUB books', '阅读 EPUB 电子书并同步进度'], EntryAbility_label: ['HarmonyReadest', 'HarmonyReadest'],
  library_subtitle: ['Your books, at your own pace.', '随时翻开，自在阅读。'], library: ['Your library', '我的书架'], books: ['books', '本书'], import: ['Import EPUB', '导入 EPUB'],
  settings: ['Settings', '设置'], importing: ['Importing and checking EPUB…', '正在导入并检查 EPUB…'], empty_title: ['A new chapter starts here', '从这里翻开新的一页'],
  empty_description: ['Import an EPUB from your device. Your library and reading position are saved offline.', '从设备导入 EPUB。书架和阅读位置会保存在本地，离线也能阅读。'],
  import_first: ['Import your first book', '导入第一本书'], unknown_author: ['Unknown author', '未知作者'], offline_footer: ['Offline first · EPUB · KoSync', '离线优先 · EPUB · KoSync'],
  kosync_title: ['KOReader progress sync', 'KOReader 进度同步'], kosync_description: ['Use the same server, account, and EPUB in Readest. KoSync shares reading positions; import books separately.', '请在 Readest 中使用相同的服务器、账号和 EPUB 文件。KoSync 只同步阅读位置，书籍需分别导入。'],
  server_url: ['Server URL (HTTPS)', '服务器地址（HTTPS）'], username: ['Username', '用户名'], password: ['Password', '密码'], password_unchanged: ['Leave empty to keep saved password', '留空以保留已保存的密码'],
  device_name: ['Device name', '设备名称'], auto_sync: ['Enable progress sync', '启用进度同步'], newer_wins: ['The newer position wins. Missing or tied timestamps require a choice. Keep device clocks accurate.', '默认采用时间较新的位置。时间缺失或相同时会询问保留哪一个，请保持设备时间准确。'],
  connect_save: ['Test connection & save', '测试连接并保存'], sync_status: ['Sync status', '同步状态'], disconnect: ['Disconnect and forget credentials', '断开连接并清除凭据'],
  appearance: ['Reading appearance', '阅读样式'], font_size: ['Font size', '字号'], line_height: ['Line spacing', '行距'], theme_light: ['Light', '浅色'], theme_sepia: ['Sepia', '护眼'], theme_dark: ['Dark', '深色'],
  about_description: ['HarmonyReadest 0.1 · Built for HarmonyOS with the Readest/Foliate reader engine. AGPL-3.0-or-later. Official Readest cloud sync is planned for a later release.', 'HarmonyReadest 0.1 · 基于 Readest/Foliate 引擎的鸿蒙阅读器。AGPL-3.0-or-later。官方 Readest 云同步将在后续版本加入。'],
  contents: ['Contents', '目录'], reading: ['Reading', '阅读中'], pull: ['Pull', '拉取'], push: ['Push', '推送'], conflict_title: ['Choose a reading position', '选择阅读位置'],
  conflict_description: ['These positions differ and their times cannot be ordered. Automatic upload is paused until you choose.', '两个位置不同，且无法按时间确定先后。请选择要保留的位置，自动上传已暂停。'], local: ['Local', '本地'], remote: ['Server', '服务器'], keep_local: ['Keep local', '保留本地'], use_remote: ['Use server', '采用服务器'],
  remove_description: ['Remove this book and its local reading data?', '移除此书和本地阅读记录？'], cancel: ['Cancel', '取消'], remove: ['Remove', '移除'],
  status_idle: ['Offline ready', '离线就绪'], status_connected: ['Connected', '已连接'], status_checking: ['Checking progress…', '正在检查进度…'], status_conflict: ['Choose a position', '请选择位置'], status_synced: ['Progress synced', '进度已同步'], status_pending: ['Progress saved locally', '进度已保存到本地'], status_error: ['Sync needs attention', '同步需处理'],
  error_auth_failed: ['Check your username and password.', '请检查用户名和密码。'], error_https_required: ['Enter a valid HTTPS server URL.', '请输入有效的 HTTPS 服务器地址。'], error_not_kosync: ['This URL did not return a KoSync JSON response.', '该地址未返回 KoSync JSON 响应。'],
  error_credentials_required: ['Enter a username and password.', '请输入用户名和密码。'], error_credentials_unavailable: ['Saved credentials could not be decrypted. Connect again.', '无法解密已保存的凭据，请重新连接。'], error_duplicate_book: ['This EPUB is already in your library.', '此 EPUB 已在书架中。'],
  error_invalid_epub: ['This file is not a valid EPUB.', '该文件不是有效的 EPUB。'], error_drm_or_encrypted: ['Encrypted or DRM-protected EPUBs are not supported.', '暂不支持加密或受 DRM 保护的 EPUB。'], error_fixed_layout_unsupported: ['Fixed-layout EPUBs are not supported in this release.', '此版本暂不支持固定布局的 EPUB。'],
  error_book_too_large: ['The book is empty or exceeds the supported size (128 MB compressed / 512 MB expanded).', '书籍为空或超过支持大小（压缩后 128 MB / 解压后 512 MB）。'],
  error_unresolved_position: ['The server position could not be restored. Automatic upload is paused. Check that both apps use the same EPUB, or explicitly push your local position.', '无法恢复服务器位置，已暂停自动上传。请检查两端是否使用相同 EPUB，或手动推送本地位置。'],
  error_import_timeout: ['Import timed out. Try a smaller EPUB.', '导入超时，请尝试较小的 EPUB。'], error_reader_timeout: ['The reader did not restore the position in time.', '阅读器恢复位置超时。'], error_server_error: ['The sync server returned an error. Retry later.', '同步服务器返回错误，请稍后重试。'], error_invalid_progress: ['The server returned an invalid reading position.', '服务器返回的阅读位置无效。'],
  error_generic: ['The operation failed. Your saved reading data is retained. Retry or check the connection.', '操作失败，已保存的阅读记录仍然保留。请重试或检查网络连接。']
};
for (const [locale, index] of [['base', 0], ['zh_CN', 1]]) {
  const dir = `entry/src/main/resources/${locale}/element`;
  await mkdir(dir, { recursive: true });
  await writeFile(`${dir}/string.json`, JSON.stringify({ string: Object.entries(strings).map(([name, values]) => ({ name, value: values[index] })) }, null, 2) + '\n');
}
await writeFile('AppScope/resources/base/element/string.json', JSON.stringify({ string: [{ name: 'app_name', value: 'HarmonyReadest' }] }, null, 2) + '\n');
