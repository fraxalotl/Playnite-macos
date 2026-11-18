import AppKit
import GameLaunch
import LibraryCore
import SwiftUI
import UniformTypeIdentifiers

/// Manually add a game: a Mac app, a program/script, or a link (e.g. `steam://rungameid/...`).
struct AddGameSheet: View {
    enum Kind: String, CaseIterable, Identifiable {
        case app = "Mac App", program = "Program", link = "Link"
        var id: Self { self }
    }

    let model: LibraryModel
    @Environment(\.dismiss) private var dismiss

    @State private var kind: Kind = .app
    @State private var name = ""
    @State private var path = ""
    @State private var arguments = ""
    @State private var link = ""
    @State private var coverPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Picker("Type", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                switch kind {
                case .app, .program:
                    LabeledContent(kind == .app ? "App" : "Program") {
                        HStack {
                            Text(path.isEmpty ? "None chosen" : (path as NSString).lastPathComponent)
                                .foregroundStyle(path.isEmpty ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Choose…", action: choosePath).buttonStyle(.glass)
                        }
                    }
                    if kind == .program {
                        TextField("Arguments", text: $arguments, prompt: Text("Optional"))
                    }
                case .link:
                    TextField("Link", text: $link, prompt: Text("steam://rungameid/504230"))
                }

                TextField("Name", text: $name, prompt: Text("Game name"))

                LabeledContent("Cover") {
                    HStack {
                        Text(coverPath.map { ($0 as NSString).lastPathComponent } ?? (kind == .app ? "Made from the app icon" : "None"))
                            .foregroundStyle(coverPath == nil ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…", action: chooseCover).buttonStyle(.glass)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Game", action: add)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 480)
        .onChange(of: kind) { path = ""; if coverPath == nil { name = "" } }
    }

    private var canAdd: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch kind {
        case .app, .program: return !path.isEmpty
        case .link: return URL(string: link)?.scheme != nil
        }
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: kind == .app ? "/Applications" : NSHomeDirectory())
        panel.allowedContentTypes = kind == .app ? [.application] : [.unixExecutable, .shellScript, .item]
        panel.treatsFilePackagesAsDirectories = kind == .program
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = url.path
        if name.isEmpty {
            name = kind == .app ? (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
                : url.deletingPathExtension().lastPathComponent
        }
    }

    private func chooseCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        coverPath = url.path
    }

    private func add() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let action: GameAction
        var installDir: String?
        switch kind {
        case .app:
            action = GameAction(name: "Play", type: .file, path: path)
            installDir = path
        case .program:
            action = GameAction(name: "Play", type: .file, path: path, arguments: arguments.isEmpty ? nil : arguments)
            installDir = (path as NSString).deletingLastPathComponent
        case .link:
            action = GameAction(name: "Play", type: .url, path: link)
        }
        model.addGame(name: trimmed, action: action, installDirectory: installDir, coverSource: coverPath, appPathForIcon: kind == .app ? path : nil)
        dismiss()
    }
}

extension LibraryModel {
    func addGame(name: String, action: GameAction, installDirectory: String?, coverSource: String?, appPathForIcon: String?) {
        let db = self.db
        Task.detached(priority: .userInitiated) { [weak self] in
            var game = Game(
                name: name,
                installDirectory: installDirectory,
                isInstalled: action.type == .file,
                actions: [action]
            )
            if let appPathForIcon {
                Self.writeArtwork(for: &game, appPath: appPathForIcon, db: db)
            }
            if let coverSource {
                let ext = (coverSource as NSString).pathExtension.lowercased()
                let dest = db.mediaDirectory(for: game.id).appending(path: "cover.\(ext.isEmpty ? "jpg" : ext)")
                try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: dest)
                if (try? FileManager.default.copyItem(at: URL(filePath: coverSource), to: dest)) != nil {
                    game.coverImage = "\(dest.deletingLastPathComponent().lastPathComponent)/\(dest.lastPathComponent)"
                }
            }
            let platform = appPathForIcon != nil ? ["macOS"] : []
            try? db.save(game, terms: platform.isEmpty ? [:] : [.platform: platform])
            let id = game.id
            await MainActor.run { self?.selection = [id] }
        }
    }

    /// Adds dropped `.app` bundles, skipping ones already in the library.
    @discardableResult
    func addDroppedApps(_ urls: [URL]) -> Bool {
        let apps = urls.filter { $0.pathExtension.lowercased() == "app" }
        guard !apps.isEmpty else { return false }
        for url in apps where (try? db.containsGame(installDirectory: url.path)) != true {
            let name = (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            addGame(name: name, action: GameAction(name: "Play", type: .file, path: url.path),
                    installDirectory: url.path, coverSource: nil, appPathForIcon: url.path)
        }
        return true
    }
}
