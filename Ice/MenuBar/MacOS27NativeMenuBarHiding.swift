//
//  MacOS27NativeMenuBarHiding.swift
//  Ice
//

import Cocoa
import OSLog

/// Hides a contiguous section by resizing an Ice-owned blank status item.
/// macOS lays out and handles every other item, including overflow and clicks.
@MainActor
final class MacOS27NativeMenuBarHiding {
    private struct Spacer {
        let item: NSStatusItem
    }

    private let logger = Logger(category: "MacOS27NativeMenuBarHiding")

    private var spacers = [MenuBarSection.Name: Spacer]()
    /// Concealment that doesn't fit on the hidden section's spacer is added
    /// as blank leading width on Ice's visible button, which already sits
    /// immediately right of the spacer. A second status item would land
    /// wherever MenuBarAgent inserts new items (observed: between the battery
    /// and Control Center), leaving a visible hole there instead.
    var extraConcealmentHandler: ((CGFloat) -> Void)?
    /// The extra width currently requested through `extraConcealmentHandler`.
    private var extraConcealment: CGFloat = 0
    /// A length MenuBarAgent refused to draw on this machine, learned from
    /// `shrinkConcealingSpacer`. Caps later sizing so the spacer isn't
    /// re-grown past it on the next refresh.
    private var observedMaximumLength: CGFloat?
    /// The concealing length last computed for a section's geometry. A
    /// re-fit compares against this, not the published total, so the extra
    /// padding added by `closeStragglerGap` isn't taken back on every sync.
    private var lastComputedLength = [MenuBarSection.Name: CGFloat]()

    isolated deinit {
        removeAll()
    }

    /// A short description of a section's spacer, for logging.
    func debugDescription(for section: MenuBarSection.Name) -> String {
        guard let spacer = spacers[section] else { return "no spacer" }
        var description = "spacer visible=\(spacer.item.isVisible) length=\(spacer.item.length)"
        if section == .hidden, extraConcealment > 0 {
            description += " + button padding \(extraConcealment)"
        }
        return description
    }

    /// The total concealing length a section currently publishes.
    private func concealingTotal(for section: MenuBarSection.Name) -> CGFloat {
        guard let spacer = spacers[section], isConcealing(section) else { return 0 }
        return spacer.item.length + (section == .hidden ? extraConcealment : 0)
    }

    /// The left edge Ice's button would have without its concealment padding.
    /// Sizing has to start from there, or the padding would be subtracted
    /// from the next computed length and the concealment would oscillate.
    private func unpaddedControlMinX(_ controlFrame: CGRect, section: MenuBarSection.Name) -> CGFloat {
        controlFrame.minX + (section == .hidden ? extraConcealment : 0)
    }

    private func setExtraConcealment(_ extra: CGFloat) {
        guard extra != extraConcealment else { return }
        logger.notice("Setting Ice button concealment padding to \(extra)")
        extraConcealment = extra
        extraConcealmentHandler?(extra)
    }

    /// The widest status item MenuBarAgent draws on macOS 27.
    ///
    /// Measured with a probe item on 27.0: on a 2304-pt bar, 1130 pt was
    /// drawn and 1153 pt discarded, in two different layouts (738 pt and
    /// 551 pt of items to the probe's right), so the limit is half the bar
    /// width rather than the free space. A wider item is dropped silently.
    static func maximumItemLength(on screen: NSScreen) -> CGFloat {
        (screen.frame.width / 2).rounded(.down) - 8
    }

    func isConcealing(_ section: MenuBarSection.Name) -> Bool {
        guard let spacer = spacers[section] else { return false }
        return spacer.item.isVisible && spacer.item.length > 1
    }

    func prepare(section: MenuBarSection.Name, anchorPosition: CGFloat) {
        guard spacers[section] == nil else { return }
        let name = "Ice.NativeBoundary.\(section.rawValue).v2"
        // Equal preferred positions have unstable ordering after a relaunch.
        // The spacer must sort strictly to the left of the visible Ice item.
        let key = "NSStatusItem Preferred Position \(name)"
        if UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(anchorPosition + 1, forKey: key)
        }
        let item = NSStatusBar.system.statusItem(withLength: 1)
        item.autosaveName = name
        item.button?.title = ""
        item.button?.image = nil
        item.button?.isEnabled = false
        item.button?.setAccessibilityIdentifier(name)
        spacers[section] = Spacer(item: item)
        withdraw(item)
    }

    /// AppKit reserves a real slot even for a one-point item. Publish the
    /// narrow boundary only while an explicit operation needs a drag handle.
    func prepareForHiding(anchorPosition: CGFloat) {
        prepare(section: .hidden, anchorPosition: anchorPosition)
        if let spacer = spacers[.hidden] { showNarrow(spacer.item) }
    }

    func showForLayout(anchorPosition: CGFloat, alwaysHiddenAnchor: CGFloat?) {
        prepare(section: .hidden, anchorPosition: anchorPosition)
        if let alwaysHiddenAnchor {
            prepare(section: .alwaysHidden, anchorPosition: alwaysHiddenAnchor)
        }
        for (section, spacer) in spacers {
            if section == .hidden || alwaysHiddenAnchor != nil {
                showNarrow(spacer.item)
            } else {
                withdraw(spacer.item)
            }
        }
        // Layout shows every item; the button padding conceals nothing meanwhile.
        setExtraConcealment(0)
    }

    private func showNarrow(_ item: NSStatusItem) {
        if item.length != 1 { item.length = 1 }
        if item.button?.isEnabled == false { item.button?.isEnabled = true }
        if !item.isVisible { item.isVisible = true }
    }

    private func withdraw(_ item: NSStatusItem) {
        guard item.isVisible else { return }
        logger.notice("Withdrawing \(item.autosaveName ?? "spacer", privacy: .public) (length \(item.length))")
        // Hiding an NSStatusItem clears its saved position. Preserve only our
        // own position; the pre-hide check reconciles native user reordering.
        let key = "NSStatusItem Preferred Position \(item.autosaveName ?? "")"
        let position = UserDefaults.standard.object(forKey: key)
        item.isVisible = false
        if let position { UserDefaults.standard.set(position, forKey: key) }
        if item.button?.isEnabled == true { item.button?.isEnabled = false }
    }

    /// Sets whether a section's spacer conceals the items to its left.
    ///
    /// - Parameter controlFrame: The current frame of the item immediately to
    ///   the right of the spacer, in global display coordinates. When known,
    ///   the spacer is sized to the space actually available to its left.
    @available(macOS 27.0, *)
    func setHidden(
        _ hidden: Bool,
        section: MenuBarSection.Name,
        anchorPosition: CGFloat,
        screen: NSScreen,
        controlFrame: CGRect? = nil
    ) {
        guard hidden else {
            if section == .hidden { setExtraConcealment(0) }
            guard let spacer = spacers[section] else { return }
            withdraw(spacer.item)
            return
        }

        prepare(section: section, anchorPosition: anchorPosition)
        guard let spacer = spacers[section] else { return }

        let length: CGFloat
        if let controlFrame {
            length = Self.concealingLength(
                controlMinX: unpaddedControlMinX(controlFrame, section: section),
                screen: screen,
                applicationMenuMaxX: Self.applicationMenuMaxX(on: screen)
            )
        } else if spacer.item.isVisible, spacer.item.length > 1 {
            // Without a fresh frame, keep the length that is already concealing.
            length = concealingTotal(for: section)
        } else {
            // An item wider than the entire native status region is discarded on
            // macOS 27. A width within that region makes its left neighbors overflow.
            let regionWidth = screen.auxiliaryTopRightArea?.width
                ?? (screen.frame.width - (screen.getApplicationMenuFrame()?.width ?? 300))
            length = max(32, regionWidth - 32)
        }

        applyConcealingLength(length, section: section, screen: screen, controlFrame: controlFrame)
    }

    /// Publishes `total` points of concealment for a section: as much as
    /// MenuBarAgent accepts on the section's spacer, and for the hidden
    /// section the rest as blank leading width on Ice's button. Both are
    /// needed on a wide bar under an app with short menus (2304-pt Dell,
    /// Outlook: 1297 needed, 1144 the most one item may be).
    private func applyConcealingLength(
        _ total: CGFloat,
        section: MenuBarSection.Name,
        screen: NSScreen,
        controlFrame: CGRect?
    ) {
        guard let spacer = spacers[section] else { return }
        lastComputedLength[section] = total
        let cap = min(Self.maximumItemLength(on: screen), observedMaximumLength ?? .infinity)
        let primary = max(1, min(total, cap))
        let remainder = total - primary

        if spacer.item.button?.isEnabled == true { spacer.item.button?.isEnabled = false }
        if spacer.item.length != primary {
            logger.notice("Sizing \(section.rawValue, privacy: .public) spacer to \(primary) of \(total) needed, cap \(cap) (control frame: \(controlFrame?.debugDescription ?? "unknown", privacy: .public))")
            spacer.item.length = primary
        }
        if !spacer.item.isVisible { spacer.item.isVisible = true }

        if section == .hidden {
            // The button itself is subject to the same per-item cap.
            setExtraConcealment(remainder > 8 ? min(remainder, cap - 64) : 0)
        }
    }

    /// Re-sizes a concealing spacer when the space it has to fill changed.
    ///
    /// The concealing length depends on the display (notch or not, width) and
    /// on the frontmost app's menu width, but `setHidden` keeps an existing
    /// length on later syncs to avoid needless reflows. Once the geometry does
    /// change, a stale length leaves a gap left of the spacer and MenuBarAgent
    /// draws the "hidden" items there (observed after switching from the
    /// notch display to a 2304-pt external one, and after activating an app
    /// with short menus). Returns whether the spacer was re-sized.
    @available(macOS 27.0, *)
    @discardableResult
    func resizeConcealingSpacerIfNeeded(
        section: MenuBarSection.Name,
        screen: NSScreen,
        controlFrame: CGRect,
        tolerance: CGFloat = 4
    ) -> Bool {
        guard spacers[section] != nil, isConcealing(section) else { return false }
        let length = Self.concealingLength(
            controlMinX: unpaddedControlMinX(controlFrame, section: section),
            screen: screen,
            applicationMenuMaxX: Self.applicationMenuMaxX(on: screen)
        )
        let current = lastComputedLength[section] ?? concealingTotal(for: section)
        guard abs(length - current) > tolerance else { return false }
        logger.notice("Re-fitting \(section.rawValue, privacy: .public) concealment from \(current) to \(length) (control frame: \(controlFrame.debugDescription, privacy: .public))")
        applyConcealingLength(length, section: section, screen: screen, controlFrame: controlFrame)
        return true
    }

    /// Overflows the items still drawn between the « button and the spacer.
    ///
    /// MenuBarAgent accepts a widened item only if the bar fits after
    /// overflowing everything to its left, and that check leaves « plus a
    /// little slack free, enough for one narrow item to stay drawn beside «.
    /// Growing Ice's button by the width of that gap once the spacer is in
    /// place makes MenuBarAgent overflow the leftmost drawn items, the
    /// stragglers, while the spacer (further right) stays. Returns whether
    /// the padding was grown.
    @available(macOS 27.0, *)
    @discardableResult
    func closeStragglerGap(spacerFrame: CGRect, overflowControlMaxX: CGFloat, screen: NSScreen) -> Bool {
        let gap = spacerFrame.minX - overflowControlMaxX
        // Below this nothing fits between « and the spacer anyway.
        guard gap > 24 else { return false }
        let cap = min(Self.maximumItemLength(on: screen), observedMaximumLength ?? .infinity) - 64
        let grown = min(extraConcealment + (gap - 8), cap)
        guard grown - extraConcealment > 8 else { return false }
        logger.notice("Closing a \(gap)-pt straggler gap between « and the spacer: button padding \(self.extraConcealment) → \(grown)")
        setExtraConcealment(grown)
        return true
    }

    /// Narrows a concealing spacer that MenuBarAgent discarded as too wide.
    /// Returns the new length, or `nil` once it is already at `minimum`.
    @available(macOS 27.0, *)
    func shrinkConcealingSpacer(section: MenuBarSection.Name, by step: CGFloat = 48, minimum: CGFloat = 32) -> CGFloat? {
        guard let spacer = spacers[section], isConcealing(section), spacer.item.length > minimum else { return nil }
        let length = max(minimum, spacer.item.length - step)
        logger.notice("Shrinking \(section.rawValue, privacy: .public) spacer from \(spacer.item.length) to \(length): MenuBarAgent did not draw it")
        spacer.item.length = length
        observedMaximumLength = length
        return length
    }

    /// The right edge of the frontmost app's menu titles.
    ///
    /// Read from the frontmost app's `AXMenuBar`. `getApplicationMenuFrame()`
    /// hit-tests the display origin instead, and on a display whose corner is
    /// not rounded away (an external monitor) that point is the Apple menu
    /// *item*, not the menu bar, so it returned nil there and the spacer was
    /// sized as if the menus had zero width (1721 pt on a 2304-pt bar, which
    /// MenuBarAgent then discarded, hiding nothing).
    @available(macOS 27.0, *)
    static func applicationMenuMaxX(on screen: NSScreen) -> CGFloat? {
        MacOS27MenuBarItemProvider.frontmostAppMenuExtent()?.maxX
            ?? screen.getApplicationMenuFrame()?.maxX
    }

    /// Returns a spacer length that fills the space available to the left of
    /// the item at `controlMinX`, so every item to the spacer's left overflows.
    ///
    /// On macOS 27, a status item that doesn't fit is discarded, and items
    /// that don't fit right of the notch move to its left. A spacer beside an
    /// item right of the notch must therefore be wider than the remaining gap
    /// there, so that it moves left of the notch and fills that side instead.
    ///
    /// Measured on 27.0 with a probe item on a 2304-pt bar without a notch:
    /// MenuBarAgent accepts a widened item only if it fits once every item to
    /// its left has been overflowed (menus + « + item + everything to its
    /// right ≤ bar width) and then overflows those items; a wider one is
    /// discarded outright. With 738 pt to the probe's right and menus ending
    /// at 363 pt, 1130 was accepted and 1160 discarded, so the « button and
    /// its padding cost 43–73 pt. The margin has to cover that, or the length
    /// lands past the limit and hides nothing (1337 with a 40-pt margin did).
    static func concealingLength(
        controlMinX: CGFloat,
        screen: NSScreen,
        applicationMenuMaxX: CGFloat?
    ) -> CGFloat {
        // Leave room for the native overflow indicator (≈32 pt) plus a little
        // slack, but not enough for a narrow item to fit: with an 80-pt margin
        // a 35-pt item stayed drawn next to «. The per-item cap is handled
        // separately (`maximumItemLength`, `shrinkConcealingSpacer`).
        let margin: CGFloat = 40
        let minimumLength: CGFloat = 32
        let menusMaxX = max(screen.frame.minX, applicationMenuMaxX ?? screen.frame.minX)

        guard
            let leftArea = screen.auxiliaryTopLeftArea,
            let rightArea = screen.auxiliaryTopRightArea
        else {
            return max(minimumLength, controlMinX - menusMaxX - margin)
        }

        let notchMinX = leftArea.maxX
        let notchMaxX = rightArea.minX
        guard controlMinX >= notchMaxX else {
            return max(minimumLength, min(controlMinX, notchMinX) - menusMaxX - margin)
        }

        let rightGap = controlMinX - notchMaxX
        let leftSegment = notchMinX - menusMaxX - margin
        if leftSegment > rightGap {
            return leftSegment
        }
        // The left side is too small to hold a spacer wider than the right
        // gap. Fill the right gap; items can still show left of the notch.
        return max(minimumLength, rightGap - margin)
    }

    func removeAll() {
        for spacer in spacers.values {
            spacer.item.isVisible = false
            NSStatusBar.system.removeStatusItem(spacer.item)
        }
        spacers.removeAll()
        setExtraConcealment(0)
    }
}
