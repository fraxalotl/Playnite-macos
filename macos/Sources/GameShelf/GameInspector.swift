import LibraryCore
import SwiftUI
import ThumbnailKit

struct GameInspector: View {
    let model: LibraryModel

    var body: some View {
        if let id = model.selectedGameID, let summary = model.summaries[id] {
            GameDetails(model: model, id: id, summary: summary)
                .id(id)
        } else {
            ContentUnavailableView(
                model.selection.isEmpty ? "No Selection" : "\(model.selection.count) Games Selected",
                systemImage: "gamecontroller"
            )
        }
    }
}

private struct GameDetails: View {
    let model: LibraryModel
    let id: Game.ID
    /// Changes whenever the game's row changes, which triggers a reload of the full record.
    let summary: GameSummary

    @State private var game: Game?
    @State private var terms: [TermField: [Term]] = [:]
    @State private var cover: CGImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.name).font(.title2.bold()).textSelection(.enabled)
                    if let platforms = terms[.platform], !platforms.isEmpty {
                        Text(platforms.map(\.name).joined(separator: ", ")).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                actions.padding(.horizontal, 16)
                facts.padding(.horizontal, 16)
                if let text = game?.gameDescription, !text.isEmpty {
                    Text(text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 16)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .task(id: summary) { await load() }
    }

    /// The cover floats over a mirrored, blurred extension of itself that fills the panel's
    /// width and runs up under the toolbar (Liquid Glass "background extension").
    private var hero: some View {
        ZStack {
            Group {
                if let cover {
                    Image(decorative: cover, scale: 2).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 300)
            .clipped()
            .backgroundExtensionEffect()
            .blur(radius: 30, opaque: true)
            .opacity(0.8)

            Group {
                if let cover {
                    Image(decorative: cover, scale: 2).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 180, height: 270)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
        }
        .frame(height: 300)
        .animation(.smooth, value: cover.map(ObjectIdentifier.init))
    }

    private var actions: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    model.play(id)
                } label: {
                    playLabel.frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(model.sessions[id] == nil ? nil : .green)
                .disabled(model.sessions[id] != nil || !(game?.actions.contains(where: \.isPlayAction) ?? false))

                Button {
                    model.toggleFavorite(id)
                } label: {
                    Image(systemName: summary.favorite ? "star.fill" : "star")
                        .foregroundStyle(summary.favorite ? .yellow : .primary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.glass)
                .help(summary.favorite ? "Remove from Favourites" : "Add to Favourites")

                Button {
                    model.toggleHidden(id)
                } label: {
                    Image(systemName: summary.hidden ? "eye" : "eye.slash")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.glass)
                .help(summary.hidden ? "Unhide" : "Hide")
            }
            .controlSize(.extraLarge)
        }
    }

    @ViewBuilder
    private var playLabel: some View {
        switch model.sessions[id]?.phase {
        case .starting:
            Label {
                Text("Starting…")
            } icon: {
                ProgressView().controlSize(.small)
            }
        case .running(let since):
            TimelineView(.periodic(from: since, by: 1)) { context in
                Label("Playing · \(Self.formatElapsed(context.date.timeIntervalSince(since)))", systemImage: "gamecontroller.fill")
                    .monospacedDigit()
            }
        case nil:
            Label(game?.actions.contains(where: \.isPlayAction) == false ? "No Play Action" : "Play", systemImage: "play.fill")
        }
    }

    static func formatElapsed(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            row("Time played", summary.playtime > 0 ? Self.formatPlaytime(summary.playtime) : "Never played")
            if let last = summary.lastActivity { row("Last played", last.formatted(.relative(presentation: .named))) }
            if let release = summary.releaseDate { row("Released", release.description) }
            if let source = summary.libraryId { row("Source", LibraryNames.display(source)) }
            if let genres = terms[.genre], !genres.isEmpty { row("Genres", genres.map(\.name).joined(separator: ", ")) }
            if let devs = terms[.developer], !devs.isEmpty { row("Developer", devs.map(\.name).joined(separator: ", ")) }
            if let added = summary.added { row("Added", added.formatted(date: .abbreviated, time: .omitted)) }
        }
        .font(.callout)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value)
        }
    }

    private func load() async {
        let db = model.db
        let id = self.id
        let loaded = await Task.detached { (try? db.game(id: id), (try? db.terms(for: id)) ?? [:]) }.value
        game = loaded.0
        terms = loaded.1
        if let url = model.coverURL(for: id) {
            // A larger bucket than the grid, from the same pipeline and caches.
            cover = try? await model.thumbnails.image(for: ThumbnailRequest(url: url, pointSize: CGSize(width: 300, height: 450), scale: 2))
        } else {
            cover = nil
        }
    }

    static func formatPlaytime(_ seconds: Int64) -> String {
        let hours = Double(seconds) / 3600
        if hours < 1 { return "\(seconds / 60) min" }
        return "\(hours.formatted(.number.precision(.fractionLength(1)))) h"
    }
}
