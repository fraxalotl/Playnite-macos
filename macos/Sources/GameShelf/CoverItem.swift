import AppKit
import LibraryCore
import ThumbnailKit

/// One cover cell. Reused by the collection view; never holds more than one load at a time.
final class CoverItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("CoverItem")

    private let cover = CoverImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let badge = NSImageView()
    /// Created only while a game is active: a glass view in every reused cell costs ~7 ms
    /// of main-thread time per scroll step, even when hidden.
    private var playing: PlayingBadge?
    private var loadTask: Task<Void, Never>?
    private var currentRequest: ThumbnailRequest?

    override func loadView() {
        let root = NSView()
        cover.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        badge.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.alignment = .center
        titleLabel.textColor = .labelColor

        badge.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Favourite")
        badge.contentTintColor = .systemYellow
        badge.symbolConfiguration = .init(pointSize: 13, weight: .bold)
        badge.shadow = {
            let s = NSShadow()
            s.shadowBlurRadius = 3
            s.shadowColor = .black.withAlphaComponent(0.6)
            return s
        }()

        root.addSubview(cover)
        root.addSubview(titleLabel)
        root.addSubview(badge)
        NSLayoutConstraint.activate([
            cover.topAnchor.constraint(equalTo: root.topAnchor),
            cover.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            cover.bottomAnchor.constraint(equalTo: titleLabel.topAnchor, constant: -6),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -2),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
            titleLabel.heightAnchor.constraint(equalToConstant: 16),
            badge.topAnchor.constraint(equalTo: cover.topAnchor, constant: 6),
            badge.trailingAnchor.constraint(equalTo: cover.trailingAnchor, constant: -6),
        ])
        view = root
    }

    override var isSelected: Bool {
        didSet { cover.isSelected = isSelected }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelLoad()
        currentRequest = nil
        cover.image = nil
    }

    private func setPlaying(_ active: Bool) {
        if active, playing == nil {
            let badge = PlayingBadge()
            badge.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.leadingAnchor.constraint(equalTo: cover.leadingAnchor, constant: 8),
                badge.bottomAnchor.constraint(equalTo: cover.bottomAnchor, constant: -8),
            ])
            playing = badge
        } else if !active, let badge = playing {
            badge.removeFromSuperview()
            playing = nil
        }
    }

    func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
    }

    func configure(summary: GameSummary, request: ThumbnailRequest?, pipeline: ThumbnailPipeline, isActive: Bool) {
        titleLabel.stringValue = summary.name
        setPlaying(isActive)
        view.toolTip = summary.name
        badge.isHidden = !summary.favorite
        cover.dimmed = !summary.isInstalled
        cover.placeholderText = summary.name

        guard request != currentRequest || cover.image == nil else { return }
        cancelLoad()
        currentRequest = request
        guard let request else {
            cover.image = nil
            return
        }
        if let cached = pipeline.cachedImage(for: request) {
            cover.setImage(cached, animated: false)
            return
        }
        cover.image = nil
        loadTask = Task { [weak self] in
            guard let image = try? await pipeline.image(for: request), !Task.isCancelled else { return }
            guard let self, self.currentRequest == request else { return }
            self.cover.setImage(image, animated: true)
        }
    }
}

/// A small glass capsule shown on covers of games that are starting or running.
final class PlayingBadge: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        let glass = NSGlassEffectView()
        glass.cornerRadius = 11
        glass.tintColor = NSColor.systemGreen.withAlphaComponent(0.35)
        let label = NSTextField(labelWithString: "Playing")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        let dot = NSImageView(image: NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)!)
        dot.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        dot.contentTintColor = .white
        let stack = NSStackView(views: [dot, label])
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 9)
        glass.contentView = stack
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityLabel("Playing")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// Draws a `CGImage` straight into its layer: no `NSImage`, no redraws while scrolling.
final class CoverImageView: NSView {
    var image: CGImage? {
        didSet { if image !== oldValue { needsDisplay = true } }
    }
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    var dimmed = false { didSet { if dimmed != oldValue { needsDisplay = true } } }
    var placeholderText = "" {
        didSet { placeholder.string = placeholderText }
    }

    private let placeholder = CATextLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        placeholder.alignmentMode = .center
        placeholder.isWrapped = true
        placeholder.fontSize = 13
        placeholder.foregroundColor = NSColor.secondaryLabelColor.cgColor
        placeholder.contentsScale = 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override var isFlipped: Bool { true }

    func setImage(_ image: CGImage, animated: Bool) {
        if animated {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.15
            layer?.add(fade, forKey: "contents")
        }
        self.image = image
    }

    override func updateLayer() {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        layer.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        layer.borderWidth = isSelected ? 3 : 0
        layer.borderColor = NSColor.controlAccentColor.cgColor
        layer.opacity = dimmed ? 0.55 : 1

        if image == nil {
            if placeholder.superlayer == nil { layer.addSublayer(placeholder) }
            placeholder.contentsScale = window?.backingScaleFactor ?? 2
            placeholder.frame = layer.bounds.insetBy(dx: 10, dy: layer.bounds.height * 0.4)
        } else {
            placeholder.removeFromSuperlayer()
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        if image == nil { needsDisplay = true }
    }
}
