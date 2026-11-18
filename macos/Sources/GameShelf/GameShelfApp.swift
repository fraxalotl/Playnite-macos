import AppKit
import LibraryCore
import SwiftUI
import ThumbnailKit

@main
struct GameShelfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        let model = appDelegate.model
        WindowGroup(AppIdentity.name, id: "library") {
            LibraryView(model: model)
                .frame(minWidth: 900, minHeight: 560)
                .sheet(isPresented: Binding(get: { model.showAddGame }, set: { model.showAddGame = $0 })) {
                    AddGameSheet(model: model)
                }
                .sheet(item: Binding(get: { model.editingGameID.map(EditingID.init) }, set: { model.editingGameID = $0?.id })) { item in
                    EditGameSheet(model: model, gameID: item.id)
                }
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Game…") { model.showAddGame = true }
                    .keyboardShortcut("n")
                Button("Update Library") { model.updateLibrary(userInitiated: true) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Import from Playnite…") { model.importFromPlaynite() }
            }
            CommandMenu("Game") {
                Button("Play") { model.selectedGameID.map(model.play) }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(model.selectedGameID == nil)
                Button("Edit…") { model.editingGameID = model.selectedGameID }
                    .keyboardShortcut("e")
                    .disabled(model.selectedGameID == nil)
                Divider()
                Button("Download Metadata") { model.downloadMetadata(for: Array(model.selection), mode: .fillMissing) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(model.selection.isEmpty)
                Button("Replace Metadata…") { model.confirmReplaceMetadata(Array(model.selection)) }
                    .disabled(model.selection.isEmpty)
                Divider()
                Button("Download Missing Metadata for All Games") { model.downloadMetadata(for: model.gamesMissingMetadata(), mode: .fillMissing) }
            }
            SidebarCommands()
            InspectorCommands()
            CommandMenu("Debug") {
                Button("Generate 1,000 Sample Games") { model.generateSampleGames(count: 1_000) }
                Button("Generate 10,000 Sample Games") { model.generateSampleGames(count: 10_000) }
                Divider()
                Button("Clear Thumbnail Caches") { model.clearThumbnailCaches() }
                Button("Remove All Games…") { model.removeAllGames() }
            }
        }

        Settings {
            SettingsView()
        }
    }
}

struct EditingID: Identifiable { let id: Game.ID }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = LibraryModel.makeDefault()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when run unbundled via `swift run`; harmless inside an .app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        Task.detached(priority: .background) { ThumbnailPipeline.shared.trimDiskCache() }
        let env = ProcessInfo.processInfo.environment
        if env["GAMESHELF_SNAPSHOT_DIR"] == nil && env["GAMESHELF_E2E_APP"] == nil && env["GAMESHELF_E2E_STEAM"] == nil && env["GAMESHELF_E2E_METADATA"] == nil {
            model.updateLibrary(userInitiated: false)
        }
        DebugAutomation.startIfRequested(model: model)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.checkpointPlaytime()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running (and tracking) while a game is open.
        model.sessions.isEmpty
    }
}
