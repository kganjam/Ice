//
//  ControlItemImage.swift
//  Ice
//

import Cocoa

/// A Codable image for a control item.
enum ControlItemImage: Codable, Hashable {
    /// An image created from drawing code built into the app.
    case builtin(_ name: ImageBuiltinName)
    /// A system symbol image.
    case symbol(_ name: String)
    /// An image in an asset catalog.
    case catalog(_ name: String)
    /// An image stored as data.
    case data(_ data: Data)

    /// A Cocoa representation of this image.
    @MainActor
    func nsImage(for appState: AppState) -> NSImage? {
        switch self {
        case .builtin(let name):
            return switch name {
            case .chevronLarge: StaticBuiltins.Chevron.large
            case .chevronSmall: StaticBuiltins.Chevron.small
            }
        case .symbol(let name):
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            image?.isTemplate = true
            return image
        case .catalog(let name):
            guard let originalImage = NSImage(named: name) else {
                return nil
            }
            return Self.fitted(catalogImage: originalImage, name: name)
        case .data(let data):
            let image = NSImage(data: data)
            image?.isTemplate = appState.settings.general.customIceIconIsTemplate
            return image
        }
    }
}

extension ControlItemImage {
    /// Catalog images fitted into the 25×17 button box, keyed by name.
    @MainActor
    private static var fittedCatalogImages = [String: NSImage]()

    /// Fits a catalog image into the 25×17 button box. Its transparent
    /// padding is cropped first, so the glyph draws at the same size as
    /// before but the image is no larger than the glyph: the status bar
    /// button scales down any image taller than itself, which would cap
    /// the icon size setting for a padded glyph like the Dot (18 px of 40).
    @MainActor
    private static func fitted(catalogImage original: NSImage, name: String) -> NSImage {
        if let cached = fittedCatalogImages[name] {
            return cached
        }
        let ratio = max(original.size.width / 25, original.size.height / 17)
        // Keep one source pixel of margin around the opaque pixels: the
        // anti-aliased rim of a round glyph sits below the crop's alpha
        // threshold, and cropping it off left the Dot with a flat, clipped
        // top edge once the icon size slider scaled it up.
        let pixelsPerPoint = max(1, CGFloat(original.cgImage(forProposedRect: nil, context: nil, hints: nil)?.height ?? 1) / max(1, original.size.height))
        let margin = 1 / pixelsPerPoint
        let glyphBounds = (original.opaqueBounds ?? CGRect(origin: .zero, size: original.size))
            .insetBy(dx: -margin, dy: -margin)
            .intersection(CGRect(origin: .zero, size: original.size))
        let size = CGSize(
            width: (glyphBounds.width / ratio).rounded(.up),
            height: (glyphBounds.height / ratio).rounded(.up)
        )
        let image = NSImage(size: size, flipped: false) { bounds in
            original.draw(in: bounds, from: glyphBounds, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = original.isTemplate
        fittedCatalogImages[name] = image
        return image
    }

    /// A name for an image that is created from drawing code in the app.
    enum ImageBuiltinName: Codable, Hashable {
        /// A large chevron.
        case chevronLarge
        /// A small chevron.
        case chevronSmall
    }
}

extension ControlItemImage {
    /// A namespace for static builtin images.
    ///
    /// - Note: We use the static properties `large` and `small` to avoid repeatedly
    ///   executing code every time ``nsImage(for:)`` is called.
    private enum StaticBuiltins {
        /// A namespace for static builtin chevron images.
        enum Chevron {
            /// Creates a chevron image with the given size and line width.
            private static func chevron(size: CGSize, lineWidth: CGFloat) -> NSImage {
                let image = NSImage(size: size, flipped: false) { bounds in
                    let insetBounds = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
                    let path = NSBezierPath()
                    path.move(to: CGPoint(x: (insetBounds.midX + insetBounds.maxX) / 2, y: insetBounds.maxY))
                    path.line(to: CGPoint(x: (insetBounds.minX + insetBounds.midX) / 2, y: insetBounds.midY))
                    path.line(to: CGPoint(x: (insetBounds.midX + insetBounds.maxX) / 2, y: insetBounds.minY))
                    path.lineWidth = lineWidth
                    path.lineCapStyle = .butt
                    NSColor.black.setStroke()
                    path.stroke()
                    return true
                }
                image.isTemplate = true
                return image
            }

            /// A large chevron.
            static let large = chevron(size: CGSize(width: 12, height: 12), lineWidth: 2)

            /// A small chevron.
            static let small = chevron(size: CGSize(width: 9, height: 9), lineWidth: 2)
        }
    }
}
