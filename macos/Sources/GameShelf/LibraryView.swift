import LibraryCore
import SwiftUI
import ThumbnailKit

/// Liquid Glass layout:
/// - The sidebar and toolbar float as system glass over the content (automatic on macOS 26).
/// - The cover grid scrolls underneath the toolbar, with the system scroll-edge effect.
/// - A heavily blurred backdrop of the selected game's cover tints the window,
///   so the glass layers pick up colour from what you're looking at.
/// - Covers themselves are content, not glass, per Apple's guidance; glass is kept for
///   controls and navigation.
struct LibraryView: View {
    @Bindable var model: LibraryModel
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
        } detail: {
            CoverGrid(model: model, ids: model.visibleIDs, coverWidth: model.coverWidth,
                      activeIDs: Set(model.sessions.keys), selection: $model.selection)
                .ignoresSafeArea(.container, edges: .top)
                .dropDestination(for: URL.self) { urls, _ in model.addDroppedApps(urls) }
                .background { AmbientBackdrop(model: model) }
                .overlay {
                    if model.visibleIDs.isEmpty && model.busy == nil {
                        EmptyLibraryView(model: model)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let busy = model.busy {
                        BusyBanner(message: busy.message, fraction: busy.fraction)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.smooth, value: model.busy == nil)
                .navigationTitle(title)
                .navigationSubtitle(subtitle)
                .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search games")
                .toolbar { toolbar }
                .inspector(isPresented: $showInspector) {
                    GameInspector(model: model)
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 440)
                }
        }
    }

    private var title: String {
        switch model.sidebar ?? .all {
        case .all: "All Games"
        case .installed: "Installed"
        case .favorites: "Favourites"
        case .hidden: "Hidden"
        case .library(let id): LibraryNames.display(id)
        case .platform(let id): model.platforms.first { $0.id == id }?.name ?? "Platform"
        }
    }

    private var subtitle: String {
        let count = model.visibleIDs.count
        return "\(count.formatted()) game\(count == 1 ? "" : "s")"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Button {
                model.showAddGame = true
            } label: {
                Label("Add Game", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
            }
            .help("Add a game (⌘N)")
        }

        ToolbarSpacer(.fixed)

        ToolbarItem {
            Menu {
                Picker("Sort By", selection: $model.sort) {
                    ForEach(SortField.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort by \(model.sort.title)")
        }

        ToolbarSpacer(.fixed)

        ToolbarItem {
            HStack(spacing: 8) {
                Image(systemName: "photo").imageScale(.small).foregroundStyle(.secondary)
                Slider(value: $model.coverWidth, in: 90...280)
                    .frame(width: 110)
                Image(systemName: "photo").imageScale(.large).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .help("Cover size")
        }

        ToolbarSpacer(.fixed)

        ToolbarItem {
            Button {
                withAnimation(.smooth) { showInspector.toggle() }
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help(showInspector ? "Hide Details" : "Show Details")
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Bindable var model: LibraryModel

    var body: some View {
        List(selection: $model.sidebar) {
            Section("Library") {
                Label("All Games", systemImage: "square.grid.2x2").tag(SidebarItem.all)
                Label("Installed", systemImage: "internaldrive").tag(SidebarItem.installed)
                Label("Favourites", systemImage: "star").tag(SidebarItem.favorites)
                Label("Hidden", systemImage: "eye.slash").tag(SidebarItem.hidden)
            }
            if !model.libraries.isEmpty {
                Section("Sources") {
                    ForEach(model.libraries, id: \.self) { id in
                        Label(LibraryNames.display(id), systemImage: LibraryNames.symbol(id)).tag(SidebarItem.library(id))
                    }
                }
            }
            if !model.platforms.isEmpty {
                Section("Platforms") {
                    ForEach(model.platforms) { term in
                        Label(term.name, systemImage: "gamecontroller").tag(SidebarItem.platform(term.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

enum LibraryNames {
    static func display(_ id: String) -> String {
        switch id {
        case "steam": "Steam"
        case "gog": "GOG"
        case "epic": "Epic Games"
        case "mac": "Mac Apps"
        case "emulated": "Emulated"
        default: id.capitalized
        }
    }

    static func symbol(_ id: String) -> String {
        switch id {
        case "mac": "macwindow"
        case "emulated": "arcade.stick"
        default: "shippingbox"
        }
    }
}

// MARK: - Ambient backdrop

/// A tiny, heavily blurred copy of the selected cover behind the grid. Costs one 128 px
/// thumbnail from the shared pipeline; cross-fades when the selection changes.
private struct AmbientBackdrop: View {
    let model: LibraryModel
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 80, opaque: true)
                    .saturation(1.4)
                    .opacity(0.35)
                    .transition(.opacity)
                    .id(ObjectIdentifier(image))
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: image.map(ObjectIdentifier.init))
        .task(id: model.selectedGameID) {
            guard let id = model.selectedGameID, let url = model.coverURL(for: id) else {
                image = nil
                return
            }
            if let next = try? await model.thumbnails.image(for: ThumbnailRequest(url: url, maxPixelSize: 128)) {
                image = next
            }
        }
    }
}

// MARK: - Overlays

private struct EmptyLibraryView: View {
    let model: LibraryModel

    var body: some View {
        if model.summaries.isEmpty {
            ContentUnavailableView {
                Label("No Games Yet", systemImage: "gamecontroller")
            } description: {
                Text("Add a game with ⌘N, drag an app here, or or find the Mac and Steam games already installed.")
            } actions: {
                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 12) {
                        Button("Add Game…") { model.showAddGame = true }
                            .buttonStyle(.glass)
                        Button("Find My Games") { model.updateLibrary(userInitiated: true) }
                            .buttonStyle(.glassProminent)
                    }
                    .controlSize(.large)
                }
            }
        } else {
            ContentUnavailableView.search(text: model.searchText)
        }
    }
}

private struct BusyBanner: View {
    let message: String
    let fraction: Double?

    var body: some View {
        HStack(spacing: 12) {
            if let fraction {
                ProgressView(value: fraction).frame(width: 160)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(message).font(.callout)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .padding(.bottom, 24)
    }
}
