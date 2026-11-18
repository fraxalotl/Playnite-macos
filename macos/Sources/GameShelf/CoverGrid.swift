import AppKit
import LibraryCore
import SwiftUI
import ThumbnailKit

/// The cover grid: an `NSCollectionView` with cell reuse, diffable updates and
/// thumbnail prefetching, wrapped for SwiftUI.
struct CoverGrid: NSViewRepresentable {
    let model: LibraryModel
    var ids: [Game.ID]
    var coverWidth: Double
    /// Games starting or running; drives the "Playing" badge.
    var activeIDs: Set<Game.ID>
    @Binding var selection: Set<Game.ID>

    static let coverAspect: CGFloat = 1.5   // 2:3 portrait, like Steam/Playnite covers
    static let titleHeight: CGFloat = 34

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 18
        layout.sectionInset = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let collectionView = GridCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(CoverItem.self, forItemWithIdentifier: CoverItem.identifier)

        let coordinator = context.coordinator
        coordinator.collectionView = collectionView
        coordinator.layout = layout
        collectionView.delegate = coordinator
        collectionView.prefetchDataSource = coordinator
        collectionView.onActivate = { [weak coordinator] indexPath in coordinator?.activate(indexPath) }
        collectionView.menuProvider = { [weak coordinator] in coordinator?.contextMenu() }
        coordinator.makeDataSource()

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let c = context.coordinator
        c.selectionBinding = $selection
        c.activeIDs = activeIDs
        c.setCoverWidth(coverWidth)
        c.apply(ids: ids)
        c.reconfigureVisibleItems()
        c.syncSelection(selection)
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDelegate, NSCollectionViewPrefetching {
        let model: LibraryModel
        weak var collectionView: NSCollectionView?
        weak var layout: NSCollectionViewFlowLayout?
        var selectionBinding: Binding<Set<Game.ID>>?
        var activeIDs: Set<Game.ID> = []

        private var dataSource: NSCollectionViewDiffableDataSource<Int, Game.ID>?
        private var currentIDs: [Game.ID] = []
        private var coverWidth: CGFloat = 0
        private var prefetches: [Game.ID: Task<Void, Never>] = [:]
        private var isSyncingSelection = false

        init(model: LibraryModel) { self.model = model }

        func makeDataSource() {
            guard let collectionView else { return }
            dataSource = NSCollectionViewDiffableDataSource<Int, Game.ID>(collectionView: collectionView) {
                [weak self] collectionView, indexPath, id in
                let item = collectionView.makeItem(withIdentifier: CoverItem.identifier, for: indexPath)
                if let self, let cover = item as? CoverItem { self.configure(cover, id: id) }
                return item
            }
        }

        var coverSize: CGSize { CGSize(width: coverWidth, height: (coverWidth * CoverGrid.coverAspect).rounded()) }
        var scale: CGFloat { collectionView?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

        func request(for id: Game.ID) -> ThumbnailRequest? {
            model.coverURL(for: id).map { ThumbnailRequest(url: $0, pointSize: coverSize, scale: scale) }
        }

        func configure(_ item: CoverItem, id: Game.ID) {
            guard let summary = model.summaries[id] else { return }
            item.configure(summary: summary, request: request(for: id), pipeline: model.thumbnails, isActive: activeIDs.contains(id))
        }

        func setCoverWidth(_ width: Double) {
            let width = CGFloat(width).rounded()
            guard width != coverWidth, let layout else { return }
            coverWidth = width
            layout.itemSize = NSSize(width: width, height: coverSize.height + CoverGrid.titleHeight)
            layout.invalidateLayout()
        }

        func apply(ids: [Game.ID]) {
            guard ids != currentIDs, let dataSource else { return }
            // Animating very large diffs costs more than it's worth.
            let animate = !currentIDs.isEmpty && abs(ids.count - currentIDs.count) < 500 && ids.count < 5_000
            currentIDs = ids
            var snapshot = NSDiffableDataSourceSnapshot<Int, Game.ID>()
            snapshot.appendSections([0])
            snapshot.appendItems(ids, toSection: 0)
            dataSource.apply(snapshot, animatingDifferences: animate)
        }

        /// Refreshes visible cells after a data change (e.g. favourite toggled, cover replaced)
        /// without touching the layout. Requests resolve from the memory cache when unchanged.
        func reconfigureVisibleItems() {
            guard let collectionView, let dataSource else { return }
            for indexPath in collectionView.indexPathsForVisibleItems() {
                guard let id = dataSource.itemIdentifier(for: indexPath),
                      let item = collectionView.item(at: indexPath) as? CoverItem else { continue }
                configure(item, id: id)
            }
        }

        func syncSelection(_ selection: Set<Game.ID>) {
            guard let collectionView, let dataSource else { return }
            let current = Set(collectionView.selectionIndexPaths.compactMap { dataSource.itemIdentifier(for: $0) })
            guard current != selection else { return }
            isSyncingSelection = true
            defer { isSyncingSelection = false }
            collectionView.deselectAll(nil)
            let paths = Set(selection.compactMap { dataSource.indexPath(for: $0) })
            collectionView.selectItems(at: paths, scrollPosition: [])
        }

        private func publishSelection() {
            guard !isSyncingSelection, let collectionView, let dataSource else { return }
            let ids = Set(collectionView.selectionIndexPaths.compactMap { dataSource.itemIdentifier(for: $0) })
            if selectionBinding?.wrappedValue != ids { selectionBinding?.wrappedValue = ids }
        }

        /// Right-click menu for the current selection (the grid selects the clicked item first).
        func contextMenu() -> NSMenu? {
            let ids = selectionBinding?.wrappedValue ?? []
            guard !ids.isEmpty else { return nil }
            let model = self.model
            let menu = NSMenu()
            if ids.count == 1, let id = ids.first {
                let running = model.sessions[id] != nil
                menu.addItem(ClosureMenuItem(running ? "Playing…" : "Play", enabled: !running) { model.play(id) })
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem("Edit…") { model.editingGameID = id })
                menu.addItem(ClosureMenuItem("Show in Finder") { model.showInFinder(id) })
            }
            menu.addItem(ClosureMenuItem("Download Metadata") { model.downloadMetadata(for: Array(ids), mode: .fillMissing) })
            menu.addItem(.separator())
            let allFavorite = ids.allSatisfy { model.summaries[$0]?.favorite == true }
            menu.addItem(ClosureMenuItem(allFavorite ? "Remove from Favourites" : "Add to Favourites") { model.toggleFavorite(ids) })
            let allHidden = ids.allSatisfy { model.summaries[$0]?.hidden == true }
            menu.addItem(ClosureMenuItem(allHidden ? "Unhide" : "Hide") { model.setHidden(ids, !allHidden) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(ids.count == 1 ? "Remove from Library…" : "Remove \(ids.count) Games from Library…") { model.removeGames(ids) })
            return menu
        }

        func activate(_ indexPath: IndexPath) {
            guard let id = dataSource?.itemIdentifier(for: indexPath) else { return }
            model.play(id)
        }

        // MARK: NSCollectionViewDelegate

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            publishSelection()
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            publishSelection()
        }

        func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
            (item as? CoverItem)?.cancelLoad()
        }

        // MARK: NSCollectionViewPrefetching

        func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            for indexPath in indexPaths {
                guard let id = dataSource?.itemIdentifier(for: indexPath), prefetches[id] == nil,
                      let request = request(for: id), model.thumbnails.cachedImage(for: request) == nil else { continue }
                let pipeline = model.thumbnails
                prefetches[id] = Task(priority: .utility) { [weak self] in
                    _ = try? await pipeline.image(for: request)
                    self?.prefetches[id] = nil
                }
            }
        }

        func collectionView(_ collectionView: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
            for indexPath in indexPaths {
                guard let id = dataSource?.itemIdentifier(for: indexPath) else { continue }
                prefetches.removeValue(forKey: id)?.cancel()
            }
        }
    }
}

/// Adds double-click and Return to activate (play) an item, and a context menu.
final class GridCollectionView: NSCollectionView {
    var onActivate: ((IndexPath) -> Void)?
    var menuProvider: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return nil }
        if !selectionIndexPaths.contains(indexPath) {
            deselectAll(nil)
            let paths: Set<IndexPath> = [indexPath]
            selectItems(at: paths, scrollPosition: [])
            delegate?.collectionView?(self, didSelectItemsAt: paths)
        }
        return menuProvider?()
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2 else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point) { onActivate?(indexPath) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, selectionIndexPaths.count == 1, let indexPath = selectionIndexPaths.first {
            onActivate?(indexPath)
        } else {
            super.keyDown(with: event)
        }
    }
}

/// An `NSMenuItem` that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
