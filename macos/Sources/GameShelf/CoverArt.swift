import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Makes 2:3 covers for games that only have an app icon: the icon over a blurred,
/// saturated wash of itself, with the title underneath.
enum CoverArt {
    static let size = CGSize(width: 600, height: 900)
    /// File name for icon-generated covers, so metadata downloads know to replace them.
    static let generatedName = "cover-generated.jpg"
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func cover(fromIcon icon: NSImage, title: String) -> CGImage? {
        var rect = CGRect(x: 0, y: 0, width: 512, height: 512)
        guard let iconImage = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }

        let width = Int(size.width), height = Int(size.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        // Background: the icon scaled to fill, blurred and darkened.
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        let ci = CIImage(cgImage: iconImage)
        let scale = size.height / ci.extent.height * 1.2
        let wash = ci.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .applyingGaussianBlur(sigma: 60)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.5, kCIInputBrightnessKey: -0.18])
        let offsetX = (ci.extent.width * scale - size.width) / 2
        if let bg = ciContext.createCGImage(wash, from: CGRect(x: offsetX, y: 0, width: size.width, height: size.height)) {
            ctx.draw(bg, in: CGRect(origin: .zero, size: size))
        }

        // Icon with a soft shadow, in the upper part.
        let iconSide: CGFloat = 360
        let iconRect = CGRect(x: (size.width - iconSide) / 2, y: size.height - 140 - iconSide, width: iconSide, height: iconSide)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: CGColor(gray: 0, alpha: 0.5))
        ctx.draw(iconImage, in: iconRect)
        ctx.restoreGState()

        // Title, centred below.
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 52, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        NSAttributedString(string: title, attributes: attrs)
            .draw(with: CGRect(x: 40, y: 70, width: size.width - 80, height: 260), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        NSGraphicsContext.restoreGraphicsState()

        return ctx.makeImage()
    }

    @discardableResult
    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.88) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    @discardableResult
    static func writePNG(_ image: NSImage, side: CGFloat, to url: URL) -> Bool {
        var rect = CGRect(x: 0, y: 0, width: side, height: side)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest)
    }
}
