# HReadest Privacy Notice

Effective date: 14 October 2026

HReadest is an independent HarmonyOS EPUB reader developed by Jin Ye. It is not an official Readest release. This notice describes HReadest, not the separate services operated by Readest, KOReader, Huawei, or your chosen server provider.

## Offline reading and local storage

Without connecting a sync account, reading does not require sending your books to a server. HReadest stores imported EPUB copies, covers, reading positions, bookmarks, highlights, imported fonts, and preferences in app storage. Books and fonts are selected through HarmonyOS file pickers. System fonts are enumerated to offer font choices. HReadest has no advertising or analytics SDK and does not send usage analytics to the developer.

## Optional Readest sync

When you sign in, your email and password are sent over HTTPS to Readest's authentication service (`readest.supabase.co`). HReadest does not persist the Readest password. Account identifiers and access/refresh tokens are retained locally to maintain the connection; credentials are encrypted using a device-bound HarmonyOS HUKS key. Books, covers, library metadata, reading positions, per-book settings, bookmarks/highlights, and custom fonts can be exchanged with Readest's API (`web.readest.com`) and the storage services referenced by its signed URLs. Fonts and annotations have separate switches; disabling them does not disable book and reading-position sync. Enabled syncing can run automatically while the app is active, including when connectivity returns.

Readest and its infrastructure providers receive these requests and may process network information such as your IP address. Their storage locations, retention practices, account controls, and service terms are controlled by them. See https://readest.com/privacy-policy and https://readest.com/terms-of-service. HReadest does not promise end-to-end encryption of synced content; HTTPS protects transport, while the local credential vault protects credentials, not the entire book library.

## Optional KOReader progress sync

Connecting KoSync sends authentication information and reading progress to the HTTPS server you select (by default `sync.koreader.rocks`). Requests can include your username, a password-derived authentication value, book digest, reading location, percentage, device name/identifier, and timestamps. If required by the server, HTTP Basic authentication can be used over HTTPS. Authentication material is encrypted in the local credential vault. Optional document metadata and custom gateway headers are sent only according to your settings. KoSync does not upload EPUB files. Its Prompt, Always use latest, Send only, and Receive only options control progress exchange. Your server provider controls its own logs, retention, and account deletion.

## Sharing, links, and diagnostics

Sharing a book sends its file to the application you choose in the HarmonyOS share panel. Source, homepage, support, and other external links open through the system and are subject to the destination's policies. If you submit a public GitHub issue, its contents are public: do not include passwords, tokens, private books, or personal reading data. HReadest writes operational errors to system logs; these are not automatically uploaded to the developer. Inspect logs before choosing to share them. HarmonyOS may independently process system diagnostics under its own settings and policies.

## Your controls and deletion

Sync is optional. Pause a service to stop its automatic syncing; disconnect to remove its saved local connection credentials. Disconnecting does not delete your local library or your remote account/data. Removing a local book does not delete your original imported file or necessarily remove the cloud copy. The separate cloud-removal option sends a library deletion record; the Readest protocol retains uploaded files, so it is not a guarantee of permanent cloud erasure or reclaimed storage. Use the provider's account controls or contact the provider for remote account/data deletion.

Local data is retained until you remove it, clear app data, or uninstall the app, subject to platform behavior. Imported originals and shared/exported copies outside app storage remain under your control. The app's backup configuration currently disables HarmonyOS app backup/restore. You can review and share books through the app; this version does not provide a complete machine-readable export of every annotation and setting.

## Contact and changes

For HReadest privacy questions, contact Jin Ye through https://github.com/TenofHearts/Harmony-Readest/issues. Use that public channel to request a private contact method before disclosing sensitive information. For Readest or KoSync account requests, contact the relevant service operator. Material changes to HReadest's data handling will be described in an updated notice and release notes. The notice date identifies this version.

---

# HReadest 隐私说明

生效日期：2026 年 10 月 14 日

HReadest 是由 Jin Ye 开发的独立鸿蒙 EPUB 阅读器，非 Readest 官方发行版。本说明适用于 HReadest；Readest、KOReader、华为及自选服务器的服务由各自运营方负责。

## 本地阅读

未连接同步账户时，阅读无需向服务器发送书籍。本应用在应用存储中保存导入的 EPUB 副本、封面、阅读位置、书签、高亮、导入字体和设置；通过系统文件选择器选择书籍及字体，并枚举系统字体供选择。本应用不集成广告或分析 SDK，不向开发者发送使用统计。

## 可选的 Readest 同步

登录时，邮箱和密码通过 HTTPS 发送至 Readest 身份认证服务（readest.supabase.co），不持久保存 Readest 密码。为保持登录，应用在本地保存账户标识及访问/刷新令牌，凭据使用设备绑定的 HarmonyOS HUKS 密钥加密。书籍、封面、书架元数据、阅读位置、单书排版设置、书签/高亮及自定义字体可与 Readest API（web.readest.com）及其签名地址所指向的存储服务交换。字体与批注有独立开关；关闭这两项不会停止书籍及阅读位置同步。启用后，应用运行期间可自动同步，网络恢复后也可能重试。

服务运营方及其基础设施提供商会接收这些请求，并可能处理 IP 地址等网络信息。其存储地区、保留期限和账户管理由运营方决定，请查阅 https://readest.com/privacy-policy 及 https://readest.com/terms-of-service。本应用不承诺同步内容的端到端加密；HTTPS 保护传输，本地凭据加密不等于整个书库加密。

## 可选的 KOReader 进度同步

KoSync 向您选择的 HTTPS 服务器（默认为 sync.koreader.rocks）发送认证信息及阅读进度，可能包括用户名、由密码生成的认证值、书籍摘要、阅读位置、百分比、设备名称/标识和时间戳。服务器需要时，可通过 HTTPS 使用 HTTP Basic 认证。认证材料加密保存于本地凭据库。文档元数据与自定义网关请求头按您的设置发送。KoSync 不上传 EPUB 文件；提示、始终使用最新、仅发送、仅接收选项控制进度交换。日志保留和账户删除由服务器运营方负责。

## 分享、外部链接与诊断

分享书籍会将文件交给您在系统分享面板中选择的应用。源代码、主页及支持等外部链接由系统打开，适用目标网站的政策。GitHub 公开问题中的内容可被公众查看，请勿提交密码、令牌、私人书籍或个人阅读数据。本应用将运行错误写入系统日志，不会自动上传给开发者；分享前请自行检查。鸿蒙系统可能依据自身设置和政策处理系统诊断信息。

## 控制与删除

同步为可选功能。暂停服务可停止其自动同步；断开连接会清除本地保存的连接凭据，不会删除本地书库或远端账户及数据。删除本地书籍不会删除导入前的原始文件，也不一定删除云端副本。单独的云端移除操作会发送书架删除记录，但 Readest 协议保留已上传文件，不保证永久删除文件或释放云空间。远端账户和数据的删除请使用服务商账户功能或联系运营方。

本地数据保留至您删除、清除应用数据或卸载，具体受系统行为影响。应用存储外的原始文件及分享/导出的副本仍由您管理。当前应用配置禁用鸿蒙应用备份/恢复。应用可查看和分享书籍，但本版本没有全部批注和设置的完整机器可读导出功能。

## 联系与更新

HReadest 隐私问题请通过 https://github.com/TenofHearts/Harmony-Readest/issues 联系 Jin Ye。该渠道公开；披露敏感信息前，请先请求私下联系方法。Readest 或 KoSync 账户问题请联系相应运营方。数据处理发生重大变化时，将更新本说明及版本说明；生效日期用于识别本说明版本。
