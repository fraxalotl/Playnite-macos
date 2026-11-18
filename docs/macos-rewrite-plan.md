# Playnite for macOS: Architecture Review & Native Rewrite Plan

*Based on Playnite 10.64 (`master` @ e2e6efcd). MIT-licensed, so a derivative rewrite is fine as long as the copyright notice stays.*

> **Revision 2 (2026-11-18): scope decisions**
> - **Personal use only** (two users) until upstream ships a Mac build. That cuts: localisation, notarisation/Sparkle, the add-on browser, the extension host, and public-scale rate limiting. Ad-hoc code signing is enough.
> - **Different name.** The working codename is **GameShelf** (`macos/`). The name is set in one place, so renaming is cheap.
> - **No user-supplied IGDB credentials.** A private Cloudflare Worker (`igdb-proxy/`) holds the Twitch secret (§4.1).
> - **Cover grid uses the efficient pipeline** in §5.1: ImageIO downsampling, disk and memory thumbnail caches, `NSCollectionView` cell reuse, prefetching and cancellation.
> - **Community extensions:** no binary compatibility. Native versions of the few that matter, built as first-party features.
>
> **Revision 3: Liquid Glass.** Minimum is now **macOS 26**. The sidebar, toolbar and inspector use system glass; the inspector buttons use `.glass` / `.glassProminent` styles inside a `GlassEffectContainer`. The cover grid scrolls under the toolbar, and a blurred backdrop of the selected cover tints the window. Covers stay as plain content: Apple reserves glass for controls and navigation.

---

## 1. What exists today

### 1.1 Solution layout (~131k lines C#, 260 XAML files)

| Project | Role | Size |
|---|---|---|
| `PlayniteSDK` | Public API for extensions: models, plugin base classes, API interfaces | 83 files / 15k lines |
| `Playnite` | Shared core: database, launching, emulation, metadata, extensions, scripting, web views, Win32 interop, shared WPF controls | 300 files / 78k lines |
| `Playnite.DesktopApp` | Desktop (mouse/keyboard) UI: WPF windows, view models, default theme | 150 cs + 154 xaml / 28k lines |
| `Playnite.FullscreenApp` | "Big picture" controller-first UI, a separate executable | 71 cs + 66 xaml / 10k lines |
| `Playnite.BrowserProcess` | CefSharp sub-process host | trivial |
| `Tools/*` | Installer, Toolbox (addon scaffolding/packing), utilities | — |

Stack: **.NET Framework 4.6.2, WPF, MVVM (Prism-style)**, LiteDB 4.1.4, CefSharp (Chromium), NLog, Newtonsoft.Json, YamlDotNet, Magick.NET, SDL2 (controllers and audio), PowerShell hosting, Win32 P/Invoke (17 `Native/*.cs` files, registry access in 8 files).

**Important:** the built-in library integrations (Steam, Epic, GOG, Battle.net, EA, Ubisoft, Xbox, itch, Humble, Amazon, PSN) and the IGDB metadata provider are **not in this repo**. They live in the separate `PlayniteExtensions` repo and ship as plugins. Only their IDs (`PlayniteSDK/BuiltInExtensions.cs`) are here.

### 1.2 Domain model (`PlayniteSDK/Models`)

All entities derive from `DatabaseObject` (`Guid Id`, `Name`). A normalised model:

- **Game**: name/sorting name, description (HTML), notes, cover/icon/background (paths into the DB file store), install dir/state/size, `GameId` plus `PluginId` (the owning library), `GameActions[]`, `Roms[]`, `Links[]`, playtime/play count/last activity/added/modified, user/critic/community score, version, manual, pre/post/started scripts plus "use global script" flags, HDR flag, hidden/favourite.
- **Relations by ID list**: Platforms, Genres, Developers/Publishers (Company), Categories, Tags, Features, Series, AgeRatings, Regions; single Source and CompletionStatus.
- **Others**: `Emulator` (with profiles), `GameScannerConfig` (emulated-ROM import), `FilterPreset`, `ImportExclusionList`, `AppSoftware` (tools menu).
- Derived/grouping values: `ReleaseYear`, `ScoreGroup`, `PastTimeSegment`, `PlaytimeCategory`, `InstallSizeGroup`, `InstallationStatus`.

### 1.3 Persistence (`Playnite/Database`)

- One LiteDB 4 file per collection (`library/games.db`, `platforms.db`, ...), opened in exclusive mode. Each collection is held fully in memory (`ItemCollection<T>`) with change events (`ItemUpdated`, `ItemCollectionChanged`) and event buffering for bulk edits.
- Media lives in `library/files/{gameId}/` and is referenced by relative path.
- Migrations: `GameDatabaseMigration.cs` and `OldModels/`.
- Filtering, sorting and grouping run in memory (`GameDatabase_Filters.cs`, `GamesCollectionView.cs`): **27 groupable fields, 30+ sort orders**, rich filter presets.

### 1.4 Game lifecycle

- **Actions** (`GameAction`): `File | URL | Emulator | Script`, with variable expansion (`{InstallDir}`, `{ImagePath}`, `{EmulatorDir}`, `{Name}`, `{Platform}`, `{GameId}`, ...).
- **Controllers** (`PlayniteSDK/Plugins/Actions.cs`): `PlayController`, `InstallController`, `UninstallController`, and `AutomaticPlayController`. Plugins supply them via `GetPlayActions/GetInstallActions/GetUninstallActions`. `GenericPlayController` handles built-in actions.
- **Tracking modes**: `Default | Process | Directory | OriginalProcess | ProcessName`. Playtime comes from process-tree or directory-based process monitoring.
- **Events**: OnGameStarting/Started/Stopped/StartupCancelled/Installed/Uninstalled/Selected, OnApplicationStarted/Stopped, OnLibraryUpdated, controller events.

### 1.5 Emulation (`Playnite/Emulation`, `Playnite/Emulators`)

- `Platforms.yaml`, `Regions.yaml`, and **96 emulator definitions** in YAML: profiles, supported platforms, ROM extensions, and executable regexes, which are **Windows `.exe`-specific**.
- `Scanner.cs` scans folders against DAT databases using CRC32 and serial matching, then auto-assigns platform, region and name.
- Users can define custom emulators and profiles.

### 1.6 Extensibility

- **Plugin types**: `LibraryPlugin` (import games and supply controllers), `MetadataPlugin` (on-demand per-field metadata), `GenericPlugin` (hooks, menus, sidebar and top-panel items, global search commands, custom game-view controls, settings views).
- Loaded from `.dll` with an `extension.yaml` manifest. PowerShell script extensions are also supported. Plugins return **WPF `UserControl`s** for settings and custom views.
- **Themes**: full XAML replacement of named views (`Themes/Desktop/Default/Views/*.xaml`: Library, Grid/Details/List views, Sidebar, TopPanel, FilterPanel, ...) for both Desktop and Fullscreen.
- Online add-on browser and updater (`ServicesClient` → playnite.link `/addons`).

### 1.7 Cross-cutting features

Metadata downloader (per-field source priority, bulk download, comparison UI), Google image search, library statistics, backup/restore, diagnostics package, tray icon, `playnite://` URI handler and named-pipe single instance, Discord presence, HDR toggling, EasyAntiCheat detection, auto-update, first-run wizard, **40 languages / 1,134 strings** (Crowdin), CefSharp web views for store logins.

---

## 2. Portability assessment

| Layer | Portable? | Notes |
|---|---|---|
| Domain model, filter/sort/group logic | ✅ Concepts port 1:1 | Rewrite in Swift. The logic is plain C# and easy to translate. |
| `Platforms.yaml`, `Regions.yaml`, DAT scanner | ✅ Data reusable | Emulator YAMLs need macOS profiles (`.app` bundles). |
| LiteDB data | ⚠️ One-time import | No Swift LiteDB reader. Use a small .NET 8 CLI (LiteDB 4.1.4 targets netstandard) to dump to JSON. |
| WPF UI, XAML themes, CefSharp, SDL2, PowerShell, Win32 interop, registry | ❌ Replace | Rebuild natively. |
| .NET plugin ecosystem (hundreds of community add-ons) | ❌ Not loadable | net462 plus WPF types in the SDK surface. **This is the biggest loss** and needs a new extension model. |
| Built-in library integrations | ❌ Rewrite per launcher | Windows paths and registry. macOS launchers keep their data elsewhere, and several launchers have no Mac client. |

Conclusion: this is a **re-implementation**, not a port. Keep the domain model and feature set as the spec, reuse the data files, and rebuild everything else natively.

---

## 3. Target architecture

### 3.1 Platform choices

| Concern | Choice | Why |
|---|---|---|
| Language | Swift 6 (strict concurrency) | Native, safe, modern concurrency for scanners and trackers |
| UI | SwiftUI shell, with AppKit for the cover grid | SwiftUI for most screens. The cover grid is an `NSCollectionView` wrapped for SwiftUI (§5.1). |
| Min OS | **macOS 26+** | Required for the Liquid Glass design system (Revision 3) |
| Build | SwiftPM package + `scripts/build-app.sh` to assemble the `.app` | No hand-maintained `.xcodeproj`. Opens directly in Xcode. |
| Persistence | **GRDB (SQLite)** | Explicit schema, FTS5 search, fast filtered queries, `ValueObservation` for reactive UI, predictable migrations. Preferred over SwiftData for many-to-many relations at scale. |
| Images | ImageIO + Core Image, `NSCache` + disk thumbnail cache | Replaces Magick.NET and MagicScaler |
| Web login | `WKWebView` + `WKHTTPCookieStore`; `ASWebAuthenticationSession` for OAuth | Replaces CefSharp |
| Controllers | **GameController.framework** | Replaces SDL2 and the gamepad DB; supports Xbox, PlayStation and Switch pads natively |
| Audio | AVFoundation | Fullscreen-mode UI sounds and background music |
| Scripting | `/bin/zsh` scripts with env vars for game scripts; JavaScriptCore for lightweight extensions | Replaces PowerShell |
| Logging | `os.Logger` (+ file export for diagnostics) | Replaces NLog |
| Updates | None (rebuild from source) | Personal use |
| Distribution | **Ad-hoc signed, not sandboxed** | The App Sandbox forbids launching arbitrary executables and reading other launchers' data. Copy the built `.app` to your brother's Mac; right-click → Open the first time. |
| Localisation | English only | Personal use |

### 3.2 Module layout (Swift Package, local packages in one Xcode workspace)

```
PlayniteMac.xcworkspace
├─ App/                       macOS app target (Desktop + Fullscreen scenes, one binary)
├─ Packages/
│  ├─ PlayniteModels          Pure value types: Game, Platform, Emulator, GameAction, enums
│  ├─ PlayniteStore           GRDB schema, migrations, repositories, file store, FTS, observation
│  ├─ PlayniteLibrary         Filtering/sorting/grouping engine, filter presets, search
│  ├─ PlayniteLaunch          Action execution, variable expansion, process/dir tracking, playtime
│  ├─ PlayniteEmulation       Emulator definitions, profiles, ROM scanner, DAT/CRC matching
│  ├─ PlayniteMetadata        MetadataProvider protocol, downloader, field priority, image pipeline
│  ├─ PlayniteIntegrations    LibraryProvider protocol and built-in providers (Steam, GOG, ...)
│  ├─ PlayniteExtensionKit    Out-of-process extension host and protocol (phase 4)
│  └─ PlayniteImporter        Windows Playnite library importer (JSON dump → GRDB)
└─ Tools/
   ├─ litedb-export/          .NET 8 console app: LiteDB 4 → JSON (run once, cross-platform)
   └─ loc-convert/            LocSource.xaml + translations → Localizable.xcstrings
```

Rule: everything below `App/` is UI-free and unit-tested with Swift Testing. Fullscreen mode becomes a **second scene/window in the same app**, not a separate executable.

### 3.3 Core abstractions (mirrors of the SDK, made Swift-native)

```swift
protocol LibraryProvider: Sendable {
    var id: UUID { get }; var name: String { get }
    func fetchGames(context: LibraryContext) async throws -> [GameMetadata]
    func playController(for game: Game) -> PlayController?
    func installController(for game: Game) -> InstallController?
    func uninstallController(for game: Game) -> UninstallController?
    func metadataProvider() -> MetadataProvider?
}

protocol MetadataProvider: Sendable {
    var supportedFields: Set<MetadataField> { get }
    func lookup(_ game: Game) async throws -> MetadataResult   // per-field, lazily resolved
}

protocol PlayController { func play() async throws -> AsyncStream<PlaySessionEvent> } // started/stopped(elapsed)
```

### 3.4 Launching and tracking on macOS

| Windows mechanism | macOS replacement |
|---|---|
| `Process.Start(exe)` | `NSWorkspace.openApplication(at:configuration:)` for `.app` bundles; `Process` for CLI binaries |
| URL actions (`steam://...`) | `NSWorkspace.open(url)` |
| Process-tree tracking | Root PID plus descendants via `proc_listchildpids` / `sysctl(KERN_PROC_ALL)` polling |
| Directory tracking | Enumerate processes with `proc_pidpath` and match the install-dir prefix (also covers apps inside a bundle) |
| ProcessName tracking | Match `NSRunningApplication.bundleIdentifier` or executable name |
| App lifecycle hooks | `NSWorkspace.didLaunchApplicationNotification` / `didTerminateApplicationNotification` for instant stop detection |
| Wine-based games | "Runner" actions for CrossOver, Whisky, Game Porting Toolkit and Heroic: launch via the runner's CLI and track by bottle path |

Variable expansion keeps the same tokens, so existing emulator argument strings keep working.

### 3.5 Windows features → Mac equivalents

| Playnite (Windows) | macOS |
|---|---|
| Tray icon | `MenuBarExtra` (recent and favourite games, quick launch) |
| `playnite://` handler + named pipe | `CFBundleURLTypes` + `onOpenURL`; the system enforces a single instance |
| Start with Windows | `SMAppService.mainApp` |
| Desktop shortcuts | Create tiny `.app` stubs or `.webloc` (`playnite://play/{id}`) files; add App Intents / Shortcuts actions |
| Global search | In-app ⌘K palette plus **Core Spotlight** indexing of games |
| Notifications panel | In-app panel plus `UserNotifications` |
| HDR toggle, EAC detection | Drop (not applicable) |
| Discord presence | Optional, via Discord IPC socket (later) |
| Dock | Dock menu with recent games; badge while a game runs |

---

## 4. Library integrations for Mac

Rewrite per launcher. Paths below must be **verified on real installs** before implementation.

| Priority | Source | Installed detection | Owned/uninstalled games | Launch |
|---|---|---|---|---|
| P0 | **Steam** | `~/Library/Application Support/Steam/steamapps/libraryfolders.vdf` → `appmanifest_*.acf` (VDF parser needed) | Steam Web API (user API key + SteamID) | `steam://rungameid/{id}` |
| P0 | **Local Mac apps / App Store / Apple Arcade** | Scan `/Applications` and `~/Applications` for `LSApplicationCategoryType = public.app-category.*games` | n/a | `NSWorkspace` |
| P0 | **Emulated ROMs** | Scanner (§1.5) | n/a | Emulator profiles |
| P1 | GOG Galaxy | Galaxy 2.0 SQLite DB (shared storage on Mac) | Same DB / GOG API | Galaxy CLI or direct `.app` |
| P1 | Epic Games | Launcher install manifests (`*.item` JSON) | Epic API via web login | `com.epicgames.launcher://apps/...` |
| P1 | **Heroic** (Epic/GOG/Amazon) | Heroic JSON config/library cache | Same | `heroic://launch/...` |
| P1 | Battle.net | Product DB / install folders | — | Battle.net URI |
| P2 | itch.io | itch app SQLite (butler DB) | itch API | `itch://` or direct |
| P2 | CrossOver / Whisky / GPTK bottles | Scan bottles' `drive_c` for shortcuts / `.exe` | n/a | Runner CLI |
| P2 | Humble, EA App | Web API only (EA's Mac support is limited) | API | URL |
| ✗ | Ubisoft, Xbox, Amazon (native), PSN | No Mac client. Optional "owned games, cloud/stream link only" import later. | | |

Metadata: Steam Store API (free, no key), **IGDB via our own Cloudflare proxy** (§4.1), SteamGridDB (covers, heroes, icons; one key, which could also live in the proxy), plus each library's own metadata.

### 4.1 IGDB proxy (`igdb-proxy/`)

- A Cloudflare Worker holds `TWITCH_CLIENT_ID` and `TWITCH_CLIENT_SECRET` as secrets, gets an app access token (client-credentials grant), and caches it in KV until shortly before it expires.
- The app calls `POST /v4/{endpoint}` with an IGDB query body and `Authorization: Bearer <APP_KEY>`. The Worker checks the shared key, checks the endpoint against an allow-list, forwards the request to `api.igdb.com`, and retries on 429 with backoff. If IGDB rejects the token with a 401, it refreshes the token once and retries.
- Successful responses are cached for 7 days (best-effort Cache API). Images load straight from `images.igdb.com` and don't go through the Worker.
- There's no per-user rate limiting: only two users. The app limits itself to about 4 requests in flight.

---

## 5. UI plan

### Desktop mode (SwiftUI `NavigationSplitView`)
- **Sidebar**: libraries, platforms, categories, saved filter presets, "Explorer"-style grouping (replaces `ExplorerPanel.xaml`).
- **Content**: three views matching Playnite's `DesktopView`: **Grid** (cover art, adjustable size), **List** (`Table` with configurable columns and sorting), **Details** (list plus large detail pane).
- **Inspector**: game details, backdrop, actions (Play / Install), playtime, links, notes.
- **Toolbar**: search, sort, group-by (all 27 groupable fields), filter popover (port of the filter panel), view switcher.
- **Windows/sheets**: Game edit (tabbed, with metadata download and diff/compare), Settings (`Settings` scene), Library integrations, Emulators, ROM import wizard, Metadata bulk download, Statistics (Swift Charts), Add-ons, First-run onboarding, Database fields manager.
- Context menus and keyboard shortcuts throughout, plus multi-select bulk edit.

### 5.1 Cover grid and thumbnail pipeline

Goal: smooth scrolling at 60–120 fps through 50k covers, with memory bounded at a few hundred MB.

1. **Data:** the grid receives an array of `Game.ID`s, already filtered and sorted off the main thread. Updates go through `NSCollectionViewDiffableDataSource`, so changing a filter animates instead of rebuilding the whole grid.
2. **Cells:** an `NSCollectionView` with flow layout reuses cells. Each cell is layer-backed and shows the image by setting `layer.contents` to a `CGImage`, which skips `NSImage` overhead.
3. **Loading** (`ThumbnailKit`):
   - The request key is the source path, its modification date and file size, and the requested pixel size (cover width × screen scale, rounded up to 64 px).
   - **Memory cache:** an `NSCache` limited by byte cost (default 256 MB).
   - **Disk cache:** small JPEGs in `~/Library/Caches/<app>/thumbs/`, named by a SHA-256 of the key.
   - **On a miss:** downsample with `CGImageSourceCreateThumbnailAtIndex` so the full image is never decoded, decode immediately, write to the disk cache, and keep it in memory.
   - Identical requests in flight are merged. Work runs on a thread pool limited to the number of CPU cores.
4. **Scrolling:** the `prefetchDataSource` warms caches for cells about to appear, and cancels when they're no longer needed. Reused cells cancel their pending load. The memory cache serves fast scroll-back.
5. **Resizing:** the size slider changes only the layout's `itemSize`. Thumbnails re-request at the new size bucket, so small changes in size don't trigger reloads.
6. **Test harness:** *Debug → Generate sample library* writes 1k / 10k unique synthetic 600×900 covers so the pipeline can be measured honestly.

### Fullscreen mode
- Separate `Window` scene that takes over the display, driven entirely by **GameController.framework** (focus engine + `.focusable()`; D-pad and stick navigation).
- Horizontal or grid browsing, game details, filters, game and main menus, background music and sounds, "random game", notifications. Mirrors the `Playnite.FullscreenApp` windows list.
- Open from the menu bar, a keyboard shortcut or a controller "guide" button combination.

### Theming
XAML themes cannot be carried over. Ship native styling: accent colour, light/dark, density, cover aspect ratio, background blur/backdrop options, and per-view layout toggles. Defer "full themes" to the extension system (phase 4) if ever.

---

## 6. Extension strategy

> **Revision 2:** for personal use, skip both stages below. Instead, build native first-party versions of the handful of extensions you and your brother actually use, such as HowLongToBeat times or achievements. The rest of this section is kept for reference.

The .NET add-on ecosystem cannot run on macOS as-is. Plan in two stages:

1. **Phases 1–3: compiled-in providers only.** `LibraryProvider` and `MetadataProvider` protocols, all first-party. This keeps the API flexible while it settles.
2. **Phase 4: out-of-process extensions.**
   - Extensions are folders with a `manifest.json` and an executable (any language), run by an extension host that talks **JSON-RPC over stdio**. This mirrors LSP and gives crash isolation, matching Playnite's existing extension crash handling.
   - The capability surface mirrors the SDK: `library.getGames`, `metadata.getField`, `game.onStarted/onStopped/...`, `menus.game/main`, `search.commands`, plus read/write database APIs.
   - Settings UI is **declarative JSON schema** rendered natively, replacing WPF `UserControl`s.
   - Lightweight script extensions run in **JavaScriptCore** with the same API, replacing PowerShell scripts.
   - Optional later: a .NET 8 shim SDK so plugin authors can port non-UI library and metadata plugins with modest changes.

---

## 7. Data migration from Windows Playnite

1. `Tools/litedb-export`: a .NET 8 CLI that references LiteDB 4.1.4 and the model classes, and dumps each collection to JSON (preserving GUIDs).
2. The user copies the Playnite `library/` folder to the Mac, or points the importer at a network share.
3. `PlayniteImporter` maps JSON to the GRDB schema, copies `files/{gameId}` media, and keeps playtime, play count, dates, scores, notes and categories.
4. Rewrite or flag non-portable data: Windows paths in `InstallDirectory` and actions are marked uninstalled and kept for reference; scripts are kept as text but disabled; emulator references are remapped by emulator ID to Mac profiles.
5. Re-run the Mac library integrations to re-link installed games (match by `PluginId` + `GameId`).

---

## 8. Phased roadmap

| Phase | Scope | Exit criteria |
|---|---|---|
| **0. Foundations** (2–3 wk) | Workspace, packages, CI (xcodebuild + Swift Testing), GRDB schema v1 + migrations, models, loc-convert script, logging, crash/diagnostics export | Empty app runs; DB round-trips all entity types |
| **1. Library MVP** (6–8 wk) | Desktop UI: grid, list and details views, sidebar, search, sort, group, filter + presets; game edit; manual "add game" (.app / binary / URL); launching + tracking + playtime; local Mac apps scanner; **Steam integration**; media store + thumbnail cache; **Windows library importer** | Daily-driver for Steam and native games with an imported Windows library |
| **2. Metadata & emulation** (5–7 wk) | Metadata framework + Steam Store, IGDB, SteamGridDB; bulk download + compare UI; emulator definitions with Mac profiles for top ~25 emulators (RetroArch, Dolphin, PCSX2, DuckStation, PPSSPP, Cemu, RPCS3, mGBA, melonDS, Azahar, xemu, Flycast, ...); ROM scanner with DAT matching; custom emulators | ROM collections import cleanly with art |
| **3. More libraries + polish** (6–8 wk) | GOG, Epic, Heroic, Battle.net, itch, Wine runners; install/uninstall controllers where launchers support it; menu bar extra; Spotlight + App Intents; statistics; backup/restore; Sparkle; first-run wizard; full localisation | Public beta |
| **4. Fullscreen mode** (4–6 wk) | Controller-driven fullscreen scene, sounds/music, focus navigation, all fullscreen menus | Couch-usable with a controller |
| **5. Extensions** (6–10 wk) | Extension host + JSON-RPC protocol, JS script runtime, declarative settings, add-on browser/updater, SDK docs + sample extensions | Third-party library plugin works end to end |

Rough total: **~8–11 months for one experienced Swift developer** to reach parity with core Playnite, excluding the community add-on catalogue.

**Revision 2 (personal use) order of work:**

| Step | Scope | Status |
|---|---|---|
| A | SwiftPM workspace, GRDB schema v1, models, `ThumbnailKit`, `NSCollectionView` cover grid, sidebar/search/sort, sample-library generator, app bundling script | **Done** |
| B | IGDB proxy Worker | **Written, not deployed** |
| C | Launching + process tracking + playtime; manual "Add game"; local Mac apps scanner | **Done** |
| D | Steam integration (installed games, playtime, art); Windows Playnite library importer (`litedb-export`) | **Done** (importer untested on a real Playnite library) |
| E | Metadata: IGDB client (via proxy), Steam Store, SteamGridDB; game edit window | **Done** except SteamGridDB; IGDB untested live (proxy not deployed) |
| F | Emulators + ROM scanner; GOG/Epic/Heroic; fullscreen controller mode | Later |

Localisation, notarisation, Sparkle, the add-on browser and the extension host are out of scope.

---

## 9. Key risks & decisions

1. **Upstream is mid-rewrite (Playnite 11).** The README says most of the codebase is being rewritten, so data models and the SDK may change. Treat P10 as the functional spec. Don't aim for plugin binary compatibility.
2. **Extension ecosystem loss.** This is the main reason people choose Playnite. Mitigate with a strong first-party integration set and a well-documented, language-agnostic extension protocol.
3. **Launcher data formats are undocumented** (Galaxy DB, Epic manifests, Battle.net product DB) and change without notice. Isolate each provider, cover it with fixture-based tests, and fail soft.
4. **Grid performance at scale** (10k+ games with covers): prototype `LazyVGrid` vs `NSCollectionView` early in phase 1 and decide with data. Use downsampled thumbnails via ImageIO.
5. **No sandbox means no Mac App Store.** Accept this. Distribute via notarised DMG plus Sparkle (and optionally Homebrew cask).
6. **Naming and branding.** "Playnite" and its logo belong to the upstream project. Use a distinct name and icon unless the maintainer agrees otherwise, and keep the MIT notice.
7. **IGDB access.** Playnite's hosted proxy is not ours to use. **Resolved:** we run our own private Cloudflare Worker proxy (§4.1).

---

## 10. Immediate next steps

1. Confirm the decisions in §9 (name, macOS 15 minimum, GRDB, no sandbox).
2. Spike (1 week): GRDB schema + 10k synthetic games, rendered in `LazyVGrid` and `NSCollectionView`, with search, filter and group, to settle the UI tech choice.
3. Spike: `litedb-export` against a real Windows Playnite library.
4. Spike: Steam VDF parsing + `steam://` launch + process tracking of a real Mac Steam game, to prove the playtime loop.
5. Then start Phase 0.
