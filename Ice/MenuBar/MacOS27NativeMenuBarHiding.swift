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
    /// The blank leading width currently requested for Ice's button.
    var buttonConcealment: CGFloat { extraConcealment }
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
        guard isConcealing(section) else { return 0 }
        let spacerLength: CGFloat
        if let spacer = spacers[section], spacer.item.isVisible, spacer.item.length > 1 {
            spacerLength = spacer.item.length
        } else {
            spacerLength = 0
        }
        return spacerLength + (section == .hidden ? extraConcealment : 0)
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

    /// An upper bound for one concealing item's length.
    ///
    /// The real limit is MenuBarAgent's fit rule (probe on 27.0, 2304-pt
    /// bar: an item is drawn only if menus + « + item + everything to its
    /// right fits, with 43–73 pt of overhead; wider items are dropped
    /// silently), which depends on the live layout. `concealingLength`
    /// already targets that, and `shrinkConcealingSpacer` backs off when a
    /// length is still refused, so this only guards against absurd values.
    static func maximumItemLength(on screen: NSScreen) -> CGFloat {
        // Half the bar, minus the item's own ~10 pt of internal padding and
        // slack: 1135 pt drawn and 1183 refused on a 2304-pt bar.
        (screen.frame.width / 2).rounded(.down) - 24
    }

    func isConcealing(_ section: MenuBarSection.Name) -> Bool {
        if section == .hidden, extraConcealment > 0 { return true }
        guard let spacer = spacers[section] else { return false }
        return spacer.item.isVisible && spacer.item.length > 1
    }

    /// Whether concealment on this screen is carried by Ice's button alone.
    ///
    /// MenuBarAgent overflows leftmost-first, live, from the total width
    /// (verified: items return the moment a probe item shrinks). A spacer
    /// therefore never pushes out an item that sorts between it and Ice's
    /// button, and an item whose owner has no AXExtrasMenuBar can sit there
    /// unseen. Ice's button is right of everything it hides, so on a bar
    /// without a notch the button's own leading padding is the concealer.
    /// A notch changes the rules (items that don't fit right of it move to
    /// its left), which the spacer logic handles; keep it there.
    ///
    /// Dormant: MenuBarAgent also caps any one item at half the bar width
    /// (padding included: 1135 pt drawn, 1183 refused on 2304 pt), so the
    /// button alone falls ~240 pt short under an app with short menus and
    /// six items stay visible. The spacer + button split covers the full
    /// length; the unseen-item ordering it depends on is fixed once by a
    /// Command-drag of that item to the left of Ice's boundary.
    static func usesButtonOnlyConcealment(on screen: NSScreen) -> Bool {
        false
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

    private var spacerGeneration = 0

    /// Re-creates a section's spacer so that MenuBarAgent inserts it
    /// immediately left of Ice's button, without any pointer input.
    ///
    /// Measured on 27.0: MenuBarAgent places a NEW status item by its
    /// app-declared preferred position relative to the values it holds for
    /// the existing items, monotonically (larger = further left), but the
    /// mapping to points is opaque (a probe at 552 landed three items left
    /// of Ice's button, 360 and 380 just right of it). Bisect the value
    /// until the spacer's frame sits directly left of the button. This also
    /// jumps over an item Ice cannot enumerate (no AXExtrasMenuBar), which a
    /// drag guided by the AX order never sees. The AX identifier stays
    /// constant so tags keep matching; only the autosave name changes,
    /// otherwise MenuBarAgent restores the old slot.
    @available(macOS 27.0, *)
    func reinsertSpacerAdjacent(
        section: MenuBarSection.Name,
        controlItemTag: MenuBarItemTag,
        screen: NSScreen
    ) async -> Bool {
        let base = "Ice.NativeBoundary.\(section.rawValue).v2"
        var low: CGFloat = 0
        var high: CGFloat = screen.frame.width
        var probe = (UserDefaults.standard.object(forKey: "NSStatusItem Preferred Position \(base)") as? Double)
            .map { CGFloat($0) } ?? 221
        for attempt in 0 ..< 12 {
            recreateSpacer(section: section, base: base, preferredPosition: probe)
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return false }
            let items = MacOS27MenuBarItemProvider.ownMenuBarItems()
            guard
                let spacer = items.first(matching: .nativeBoundary(for: section)),
                let ice = items.first(matching: controlItemTag),
                spacer.bounds.width > 0, ice.bounds.width > 0
            else {
                logger.notice("Reinsertion probe \(attempt) at \(probe): frames unavailable")
                continue
            }
            let gap = ice.bounds.minX - spacer.bounds.maxX
            if spacer.bounds.minX >= ice.bounds.minX - 1 {
                // Landed right of Ice's button: value too small.
                low = probe
            } else if gap <= 8 {
                logger.notice("Spacer reinserted beside Ice's button at preferred position \(probe) (attempt \(attempt))")
                showNarrow(spacers[section]!.item)
                return true
            } else {
                // Left of the button with something in between: too large.
                high = probe
            }
            logger.notice("Reinsertion probe \(attempt) at \(probe): spacer \(spacer.bounds.debugDescription, privacy: .public), Ice \(ice.bounds.debugDescription, privacy: .public), next range \(low)–\(high)")
            probe = ((low + high) / 2).rounded()
            if high - low < 1 { break }
        }
        logger.error("Could not place the spacer beside Ice's button by reinsertion")
        return false
    }

    /// Removes a section's spacer and creates a fresh one at `preferredPosition`.
    private func recreateSpacer(section: MenuBarSection.Name, base: String, preferredPosition: CGFloat) {
        if let old = spacers[section] {
            old.item.isVisible = false
            NSStatusBar.system.removeStatusItem(old.item)
            if let oldName = old.item.autosaveName {
                UserDefaults.standard.removeObject(forKey: "NSStatusItem Preferred Position \(oldName)")
                UserDefaults.standard.removeObject(forKey: "NSStatusItem Visible \(oldName)")
            }
        }
        spacerGeneration += 1
        let name = "\(base).g\(spacerGeneration)"
        UserDefaults.standard.set(preferredPosition, forKey: "NSStatusItem Preferred Position \(name)")
        // Remember the winning value under the base key for the next launch.
        UserDefaults.standard.set(preferredPosition, forKey: "NSStatusItem Preferred Position \(base)")
        let item = NSStatusBar.system.statusItem(withLength: 8)
        item.autosaveName = name
        item.button?.title = ""
        item.button?.image = nil
        item.button?.isEnabled = false
        item.button?.setAccessibilityIdentifier(base)
        item.isVisible = true
        spacers[section] = Spacer(item: item)
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

        let buttonOnly = section == .hidden && Self.usesButtonOnlyConcealment(on: screen)
        if buttonOnly {
            // The spacer would sort left of unseen items; keep it withdrawn.
            if let spacer = spacers[section] { withdraw(spacer.item) }
        } else {
            prepare(section: section, anchorPosition: anchorPosition)
        }
        guard buttonOnly || spacers[section] != nil else { return }

        let length: CGFloat
        if let controlFrame {
            length = Self.concealingLength(
                controlMinX: unpaddedControlMinX(controlFrame, section: section),
                screen: screen,
                applicationMenuMaxX: Self.applicationMenuMaxX(on: screen)
            )
        } else if isConcealing(section) {
            // Without a fresh frame, keep the length that is already concealing.
            length = concealingTotal(for: section)
        } else if buttonOnly {
            // No frame yet: start modestly; the re-fit corrects it.
            length = 32
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
        lastComputedLength[section] = total
        let cap = min(Self.maximumItemLength(on: screen), observedMaximumLength ?? .infinity)

        if section == .hidden, Self.usesButtonOnlyConcealment(on: screen) {
            logger.notice("Sizing button-only concealment to \(min(total, cap)) of \(total) needed, cap \(cap) (control frame: \(controlFrame?.debugDescription ?? "unknown", privacy: .public))")
            setExtraConcealment(max(0, min(total, cap)))
            return
        }

        guard let spacer = spacers[section] else { return }
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
        guard isConcealing(section) else { return false }
        // During an app switch the new frontmost app's menu bar can be
        // unreadable for a moment; sizing as if the menus had zero width
        // would demand ~1700 pt and thrash. Keep the current length instead.
        guard let applicationMenuMaxX = Self.applicationMenuMaxX(on: screen) else {
            logger.notice("Not re-fitting \(section.rawValue, privacy: .public): the app menu extent is unavailable")
            return false
        }
        let length = Self.concealingLength(
            controlMinX: unpaddedControlMinX(controlFrame, section: section),
            screen: screen,
            applicationMenuMaxX: applicationMenuMaxX
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
        if section == .hidden, extraConcealment > 0, spacers[section].map({ !$0.item.isVisible || $0.item.length <= 1 }) ?? true {
            // Button-only concealment: the padded button was not drawn.
            guard extraConcealment > minimum else { return nil }
            let padding = max(minimum, extraConcealment - step)
            logger.notice("Shrinking button-only concealment from \(self.extraConcealment) to \(padding): MenuBarAgent did not draw Ice's button")
            observedMaximumLength = padding
            setExtraConcealment(padding)
            return padding
        }
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
