<p align="center">
  <img src="entry/src/main/resources/base/media/startIcon.png" alt="墨契 Attune app icon: an open book" width="128" height="128">
</p>

<h1 align="center">墨契 Attune</h1>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-HarmonyOS-007DFF?style=flat-square" alt="Platform: HarmonyOS">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-AGPL--3.0--or--later-blue?style=flat-square" alt="License: AGPL-3.0-or-later"></a>
  <a href="https://github.com/TenofHearts/Harmony-Readest"><img src="https://img.shields.io/github/stars/TenofHearts/Harmony-Readest?style=flat-square&amp;logo=github&amp;label=Stars" alt="GitHub repository stars"></a>
  <a href="https://github.com/TenofHearts"><img src="https://img.shields.io/badge/GitHub-TenofHearts-181717?style=flat-square&amp;logo=github" alt="TenofHearts on GitHub"></a>
</p>

墨契 Attune is an independent EPUB reader for phones and tablets, with offline reading, a personal bookshelf, bookmarks and highlights, customizable typography and themes, Readest cloud sync, and KOReader progress sync.

## Reading and bookshelf

Import EPUB books from your device, browse covers and book details, and pick up where you left off. Books and saved reading positions are available offline. Navigate with the table of contents, tap or swipe to turn pages, jump with the progress slider, and choose paginated or scrolling reading. Tap a reference or footnote to read it in a floating preview without losing your place. The toolbar and progress bar stay hidden when you open a book; tap the center of the page to show or hide them. Share books through the HarmonyOS share panel.

## Bookmarks and highlights

Bookmark pages and highlight selected text in five colors. The Annotations panel lets you browse, revisit, and remove saved bookmarks and highlights. Annotations are stored locally and can optionally sync with Readest.

## Fonts, layout and themes

Adjust font size, weight, paragraph spacing, margins, indentation, alignment, and reading columns. Use built-in fonts or import your own TTF/OTF fonts. Choose from 11 color schemes, with separate Light, Dark, or System settings for the bookshelf and reader. Reading layouts adapt to phone and tablet screens.

## Cross-device sync

Connect an existing Readest account to synchronize EPUB books, covers, reading positions, per-book typography and layout, bookmarks, highlights, and custom fonts. Cloud books download when opened and remain available offline. Fonts and annotations have independent sync switches.

KOReader Sync (KoSync) synchronizes reading positions using the same EPUB, account, and server on each device. Choose Prompt, Always use latest, Send only, or Receive only; sign in or create an account, and configure gateway headers or optional document metadata. Both services work independently and can be connected together. The Syncing page groups Cloud Sync and Reading Sync with separate service settings and status.

## App language and supported books

Choose English, Simplified Chinese, or the system language. The reader supports reflowable, DRM-free EPUB books; PDF and fixed-layout EPUB are currently unsupported.

## Source, licensing, privacy and support

Developed by Jin Ye. 墨契 Attune is an independent project, not an official Readest release. Adapted Readest and Foliate components retain their upstream copyrights. See [LICENSE](LICENSE), [third-party credits](THIRD_PARTY_NOTICES.md), and the [墨契 Attune privacy notice](PRIVACY.md) (English and 简体中文). The privacy notice and full license texts are also available offline in Settings → About.

[Project source](https://github.com/TenofHearts/Harmony-Readest) · [墨契 Attune support](https://github.com/TenofHearts/Harmony-Readest/issues). Do not put credentials or private books in public issues. Readest is a separate service; compatibility does not imply endorsement.

Before publishing a release, complete the [release checklist](docs/RELEASE_CHECKLIST.md), including release-specific source links and live sync acceptance. Existing automated sync fixtures do not establish full live cross-client compatibility.
