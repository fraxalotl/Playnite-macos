import AppKit
import LibraryCore
import Metadata
import SwiftUI
import ThumbnailKit

/// Edit one game. "Download Metadata" fills the form so you can review before saving.
struct EditGameSheet: View {
    let model: LibraryModel
    let gameID: Game.ID
    @Environment(\.dismiss) private var dismiss

    @State private var original: Game?
    @State private var draft = Draft()
    @State private var tab = Tab.general
    @State private var lookupState: LookupState = .idle

    enum Tab: Hashable { case general, media, launch }
    enum LookupState: Equatable { case idle, running, done(String), failed(String) }

    /// Editable copy. Lists are comma-separated text so they're quick to type.
    struct Draft: Equatable {
        var name = "", sortingName = "", releaseDate = "", description = "", notes = ""
        var platforms = "", genres = "", developers = "", publishers = "", series = "", features = "", tags = ""
        var criticScore = "", communityScore = "", userScore = ""
        var coverSource: MediaSource = .unchanged
        var backgroundSource: MediaSource = .unchanged
        var actionType: ActionKind = .none
        var actionPath = "", actionArguments = ""
        var trackingMode: TrackingMode = .default
        var trackingPath = ""
        var installDirectory = ""
        var links: [GameLink] = []
    }

    enum MediaSource: Equatable {
        case unchanged, removed
        case file(URL)
        case remote(URL)
    }

    enum ActionKind: String, CaseIterable, Identifiable {
        case none = "None", file = "App or Program", url = "Link"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $tab) {
                general.tabItem { Text("General") }.tag(Tab.general)
                media.tabItem { Text("Media") }.tag(Tab.media)
                launch.tabItem { Text("Launch") }.tag(Tab.launch)
            }
            .padding([.horizontal, .top], 16)

            HStack(spacing: 10) {
                Button {
                    Task { await downloadMetadata() }
                } label: {
                    Label("Download Metadata", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.glass)
                .disabled(lookupState == .running || draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                lookupStatus
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 640, height: 600)
        .task { load() }
    }

    // MARK: Tabs

    private var general: some View {
        Form {
            TextField("Name", text: $draft.name)
            TextField("Sorting name", text: $draft.sortingName, prompt: Text("Optional, e.g. “Witcher 3”"))
            TextField("Release date", text: $draft.releaseDate, prompt: Text("YYYY, YYYY-MM or YYYY-MM-DD"))
            TextField("Platforms", text: $draft.platforms, prompt: Text("Comma-separated"))
            TextField("Genres", text: $draft.genres, prompt: Text("Comma-separated"))
            TextField("Developers", text: $draft.developers)
            TextField("Publishers", text: $draft.publishers)
            TextField("Series", text: $draft.series)
            TextField("Features", text: $draft.features)
            TextField("Tags", text: $draft.tags)
            HStack {
                TextField("Critic score", text: $draft.criticScore)
                TextField("Community", text: $draft.communityScore)
                TextField("Yours", text: $draft.userScore)
            }
            Section("Description") {
                TextEditor(text: $draft.description).frame(minHeight: 90).font(.callout)
            }
            Section("Notes") {
                TextEditor(text: $draft.notes).frame(minHeight: 60).font(.callout)
            }
        }
        .formStyle(.grouped)
    }

    private var media: some View {
        Form {
            mediaRow("Cover", source: $draft.coverSource, current: original?.coverImage, aspect: 2.0 / 3.0)
            mediaRow("Background", source: $draft.backgroundSource, current: original?.backgroundImage, aspect: 16.0 / 9.0)
        }
        .formStyle(.grouped)
    }

    private func mediaRow(_ title: String, source: Binding<MediaSource>, current: String?, aspect: CGFloat) -> some View {
        LabeledContent(title) {
            HStack(alignment: .top, spacing: 12) {
                MediaPreview(model: model, source: source.wrappedValue, currentPath: current)
                    .aspectRatio(aspect, contentMode: .fit)
                    .frame(height: 150)
                VStack(alignment: .leading) {
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.image]
                        if panel.runModal() == .OK, let url = panel.url { source.wrappedValue = .file(url) }
                    }
                    Button("Remove") { source.wrappedValue = .removed }
                        .disabled(source.wrappedValue == .removed || (current == nil && source.wrappedValue == .unchanged))
                }
                .buttonStyle(.glass)
            }
        }
    }

    private var launch: some View {
        Form {
            Picker("Play action", selection: $draft.actionType) {
                ForEach(ActionKind.allCases) { Text($0.rawValue).tag($0) }
            }
            switch draft.actionType {
            case .none:
                Text("Without a play action, this game can't be started from GameShelf.").foregroundStyle(.secondary)
            case .file:
                LabeledContent("Path") {
                    HStack {
                        TextField("", text: $draft.actionPath, prompt: Text("/Applications/Game.app"))
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.treatsFilePackagesAsDirectories = false
                            if panel.runModal() == .OK, let url = panel.url { draft.actionPath = url.path }
                        }
                    }
                }
                TextField("Arguments", text: $draft.actionArguments)
            case .url:
                TextField("Link", text: $draft.actionPath, prompt: Text("steam://rungameid/{GameId}"))
            }
            if draft.actionType != .none {
                Picker("Track playtime by", selection: $draft.trackingMode) {
                    Text("Automatic").tag(TrackingMode.default)
                    Text("Launched process and children").tag(TrackingMode.process)
                    Text("Original process only").tag(TrackingMode.originalProcess)
                    Text("Anything in a folder").tag(TrackingMode.directory)
                    Text("Process name").tag(TrackingMode.processName)
                }
                if draft.trackingMode == .directory || draft.trackingMode == .processName {
                    TextField(draft.trackingMode == .directory ? "Folder" : "Process name", text: $draft.trackingPath,
                              prompt: Text(draft.trackingMode == .directory ? "Defaults to the install folder" : "e.g. Celeste"))
                }
            }
            Section {
                TextField("Install folder", text: $draft.installDirectory, prompt: Text("Used for {InstallDir} and folder tracking"))
            } footer: {
                Text("Variables: {InstallDir}, {InstallDirName}, {Name}, {GameId}, {DatabaseId}, {Version}").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var lookupStatus: some View {
        switch lookupState {
        case .idle: EmptyView()
        case .running: ProgressView().controlSize(.small)
        case .done(let text): Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        case .failed(let text): Label(text, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange).lineLimit(1)
        }
    }

    // MARK: Load / save

    private func load() {
        guard let game = try? model.db.game(id: gameID) else { dismiss(); return }
        original = game
        let terms = ((try? model.db.terms(for: gameID)) ?? [:]).mapValues { $0.map(\.name).joined(separator: ", ") }
        var d = Draft()
        d.name = game.name
        d.sortingName = game.sortingName ?? ""
        d.releaseDate = game.releaseDate?.description ?? ""
        d.description = game.gameDescription ?? ""
        d.notes = game.notes ?? ""
        d.platforms = terms[.platform] ?? ""
        d.genres = terms[.genre] ?? ""
        d.developers = terms[.developer] ?? ""
        d.publishers = terms[.publisher] ?? ""
        d.series = terms[.series] ?? ""
        d.features = terms[.feature] ?? ""
        d.tags = terms[.tag] ?? ""
        d.criticScore = game.criticScore.map(String.init) ?? ""
        d.communityScore = game.communityScore.map(String.init) ?? ""
        d.userScore = game.userScore.map(String.init) ?? ""
        d.installDirectory = game.installDirectory ?? ""
        d.links = game.links
        if let action = game.actions.first(where: \.isPlayAction) {
            d.actionType = action.type == .url ? .url : .file
            d.actionPath = action.path ?? ""
            d.actionArguments = action.arguments ?? ""
            d.trackingMode = action.trackingMode
            d.trackingPath = action.trackingPath ?? ""
        }
        draft = d
    }

    private func downloadMetadata() async {
        guard let original else { return }
        lookupState = .running
        var probe = original
        probe.name = draft.name
        probe.releaseDate = PartialDate(string: draft.releaseDate)
        do {
            let result = try await LibraryModel.lookup(MetadataQuery(game: probe), steam: SteamStoreProvider(), igdb: IGDBSettings.provider())
            guard let r = result else {
                lookupState = .failed("No exact match for “\(draft.name)”")
                return
            }
            // Fill empty fields only; the user can still change anything before saving.
            func fill(_ field: inout String, _ value: String?) { if field.trimmingCharacters(in: .whitespaces).isEmpty, let value { field = value } }
            fill(&draft.description, r.description)
            fill(&draft.releaseDate, r.releaseDate?.description)
            fill(&draft.genres, r.genres.isEmpty ? nil : r.genres.joined(separator: ", "))
            fill(&draft.developers, r.developers.isEmpty ? nil : r.developers.joined(separator: ", "))
            fill(&draft.publishers, r.publishers.isEmpty ? nil : r.publishers.joined(separator: ", "))
            fill(&draft.series, r.series.isEmpty ? nil : r.series.joined(separator: ", "))
            fill(&draft.features, r.features.isEmpty ? nil : r.features.joined(separator: ", "))
            fill(&draft.criticScore, r.criticScore.map(String.init))
            fill(&draft.communityScore, r.communityScore.map(String.init))
            let ownCover = original.coverImage != nil && !LibraryModel.isGeneratedCover(original.coverImage)
            if let url = r.coverURL, draft.coverSource == .unchanged, !ownCover { draft.coverSource = .remote(url) }
            if let url = r.backgroundURL, draft.backgroundSource == .unchanged, original.backgroundImage == nil { draft.backgroundSource = .remote(url) }
            let known = Set(draft.links.map(\.url))
            draft.links += r.links.filter { !known.contains($0.url) }
            lookupState = .done("Filled from \(r.source). Review, then Save.")
        } catch {
            lookupState = .failed(error.localizedDescription)
        }
    }

    private func save() {
        guard var game = original else { return }
        let d = draft
        game.name = d.name.trimmingCharacters(in: .whitespaces)
        game.sortingName = d.sortingName.nilIfBlank
        game.releaseDate = PartialDate(string: d.releaseDate.trimmingCharacters(in: .whitespaces))
        game.gameDescription = d.description.nilIfBlank
        game.notes = d.notes.nilIfBlank
        game.criticScore = Int(d.criticScore)
        game.communityScore = Int(d.communityScore)
        game.userScore = Int(d.userScore)
        game.installDirectory = d.installDirectory.nilIfBlank
        game.links = d.links

        var actions = game.actions.filter { !$0.isPlayAction }
        if d.actionType != .none, let path = d.actionPath.nilIfBlank {
            actions.insert(GameAction(name: "Play", type: d.actionType == .url ? .url : .file, path: path,
                                      arguments: d.actionArguments.nilIfBlank, trackingMode: d.trackingMode,
                                      trackingPath: d.trackingPath.nilIfBlank), at: 0)
        }
        game.actions = actions

        let terms: [TermField: [String]] = [
            .platform: d.platforms.commaList, .genre: d.genres.commaList, .developer: d.developers.commaList,
            .publisher: d.publishers.commaList, .series: d.series.commaList, .feature: d.features.commaList, .tag: d.tags.commaList,
        ]
        let db = model.db
        let saved = game
        dismiss()
        Task.detached(priority: .userInitiated) {
            var game = saved
            let dir = db.mediaDirectory(for: game.id)
            game.coverImage = await Self.resolve(d.coverSource, current: saved.coverImage, prefix: "cover", dir: dir, db: db)
            game.backgroundImage = await Self.resolve(d.backgroundSource, current: saved.backgroundImage, prefix: "background", dir: dir, db: db)
            try? db.save(game, terms: terms)
        }
    }

    nonisolated private static func resolve(_ source: MediaSource, current: String?, prefix: String, dir: URL, db: LibraryDatabase) async -> String? {
        switch source {
        case .unchanged:
            return current
        case .removed:
            LibraryModel.removeOwnedMedia(current, db: db)
            return nil
        case .remote(let url):
            guard let path = await LibraryModel.download(url, into: dir, prefix: prefix, db: db) else { return current }
            LibraryModel.removeOwnedMedia(current, db: db)
            return path
        case .file(let url):
            let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension.lowercased()
            let name = "\(prefix)-\(UUID().uuidString.prefix(8).lowercased()).\(ext)"
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: dir.appending(path: name))
            } catch {
                return current
            }
            LibraryModel.removeOwnedMedia(current, db: db)
            return "\(dir.lastPathComponent)/\(name)"
        }
    }
}

/// Shows the current, chosen or downloaded image.
private struct MediaPreview: View {
    let model: LibraryModel
    let source: EditGameSheet.MediaSource
    let currentPath: String?
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary)
            if let image {
                Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: source) { await load() }
    }

    private func load() async {
        let url: URL?
        switch source {
        case .unchanged: url = model.db.mediaURL(currentPath)
        case .removed: url = nil
        case .file(let u): url = u
        case .remote(let remote):
            image = await Task.detached {
                guard let (data, _) = try? await URLSession.shared.data(from: remote),
                      let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil as CGImage? }
                return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: 600] as CFDictionary)
            }.value
            return
        }
        guard let url else { image = nil; return }
        image = try? await model.thumbnails.image(for: ThumbnailRequest(url: url, maxPixelSize: 600))
    }
}

private extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    var commaList: [String] {
        split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
