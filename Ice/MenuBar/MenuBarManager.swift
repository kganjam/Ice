//
//  MenuBarManager.swift
//  Ice
//

import Combine
import OSLog
import SwiftUI

/// Manager for the state of the menu bar.
@MainActor
final class MenuBarManager: ObservableObject {
    /// Information for the menu bar's average color.
    @Published private(set) var averageColorInfo: MenuBarAverageColorInfo?

    /// A Boolean value that indicates whether the menu bar is either always hidden
    /// by the system, or automatically hidden and shown by the system based on the
    /// location of the mouse.
    @Published private(set) var isMenuBarHiddenBySystem = false

    /// A Boolean value that indicates whether the menu bar is hidden by the system
    /// according to a value stored in UserDefaults.
    @Published private(set) var isMenuBarHiddenBySystemUserDefaults = false

    /// A Boolean value that indicates whether the "ShowOnHover" feature is allowed.
    @Published var showOnHoverAllowed = true

    /// Reference to the settings window.
    @Published private var settingsWindow: NSWindow?

    /// Logger for the menu bar manager.
    private let logger = Logger(category: "MenuBarManager")

    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// A Boolean value that indicates whether the application menus are hidden.
    private var isHidingApplicationMenus = false

    /// The panel that contains the Ice Bar interface.
    let iceBarPanel = IceBarPanel()

    /// The panel that contains the menu bar search interface.
    let searchPanel = MenuBarSearchPanel()

    /// The panel that contains a portable version of the menu bar
    /// appearance editor interface
    let appearanceEditorPanel = MenuBarAppearanceEditorPanel()

    /// macOS 27's assignment-backed menu bar compatibility controller.
    let macOS27Controller = MacOS27MenuBarController()
    private let nativeHiding = MacOS27NativeMenuBarHiding()
    /// macOS 27 "Allow in the Menu Bar" based hiding (opt-in flag).
    let disallowedAppsMode = MacOS27DisallowedAppsMode()
    /// macOS 27 assessment-mode hiding: live, no restart (opt-in flag).
    private var _assessmentMode: Any?
    @available(macOS 27.0, *)
    private var assessmentMode: MacOS27AssessmentMode {
        if let mode = _assessmentMode as? MacOS27AssessmentMode { return mode }
        let mode = MacOS27AssessmentMode()
        _assessmentMode = mode
        return mode
    }
    private var nativeConcealmentTask: Task<Void, Never>?
    private var nativeConcealmentCheckTask: Task<Void, Never>?
    private var stragglerCheckTask: Task<Void, Never>?
    private var lastNativeVisibilityDecision: String?
    /// The time of the last change to which items the spacers conceal.
    private var lastNativeConcealmentChange: ContinuousClock.Instant?
    private var deferredNativeVisibilityTask: Task<Void, Never>?
    /// The minimum time between concealment changes, long enough for
    /// MenuBarAgent's overflow animation to finish.
    private static let nativeConcealmentChangeInterval = Duration.milliseconds(400)
    private var nativeVisibilityGeneration: UInt64 = 0
    private var nativeDragVisibility = MacOS27NativeDragVisibilityState()
    /// The time of the user's most recent explicit section toggle. Ice only
    /// sends a native drag to align its boundary shortly after one.
    private var lastUserToggleTimestamp: ContinuousClock.Instant?
    /// Whether an automatic hide couldn't align Ice's boundary without a drag.
    private var needsUserActionToAlignBoundary = false
    /// The number of active temporary reveals of items concealed for the Ice Bar.
    private var iceBarRevealDepth = 0

    /// The managed sections in the menu bar.
    let sections = [
        MenuBarSection(name: .visible),
        MenuBarSection(name: .hidden),
        MenuBarSection(name: .alwaysHidden),
    ]

    /// A Boolean value that indicates whether at least one of the manager's
    /// sections is visible.
    var hasVisibleSection: Bool {
        sections.contains { !$0.isHidden }
    }

    /// Performs the initial setup of the menu bar manager.
    func performSetup(with appState: AppState) {
        self.appState = appState
        macOS27Controller.onEditingChanged = { [weak self] in
            self?.syncNativeVisibility()
        }
        configureCancellables()
        iceBarPanel.performSetup(with: appState)
        searchPanel.performSetup(with: appState)
        appearanceEditorPanel.performSetup(with: appState)
        for section in sections {
            section.performSetup(with: appState)
        }
        if #available(macOS 27.0, *) {
            nativeHiding.prepare(section: .hidden, anchorPosition: controlItem(withName: .visible)?.preferredPosition ?? 0)
            nativeHiding.extraConcealmentHandler = { [weak self] extra in
                self?.controlItem(withName: .visible)?.leadingConcealmentPadding = extra
            }
            // The mode was turned off while apps were disallowed: give them back.
            if !MacOS27DisallowedAppsMode.isEnabled, !disallowedAppsMode.disallowedApps.isEmpty {
                logger.notice("Disallowed-apps mode is off; re-allowing what Ice had disallowed")
                disallowedAppsMode.restoreAll()
            }
        }
    }

    /// Opens a disallowed app from the Ice Bar. Apps with windows are just
    /// activated. A menu-bar-only app (accessory or background activation
    /// policy) has nothing to activate: re-allow it, restart the agent,
    /// click its item once it is laid out, and let the next sync disallow
    /// it again after its menu closes.
    @available(macOS 27.0, *)
    func openDisallowedApp(bundleID: String) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard let app = running.first else {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
            return
        }
        // A menu bar helper is often a separate process; treat the app as
        // menu-bar-only if none of its processes can come to the front.
        let hasFrontableProcess = running.contains { $0.activationPolicy == .regular }
        guard !hasFrontableProcess, let appState else {
            app.activate()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            defer { disallowedAppsMode.endTemporaryAllow(bundleID) }
            if disallowedAppsMode.allowTemporarily(bundleID) {
                // MenuBarAgent relaunches and every app re-registers.
                try? await Task.sleep(for: .milliseconds(1200))
            }
            let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
            await appState.itemManager.clickFirstItem(ownedBy: pids)
        }
    }

    /// The assessment mode's replacement for the spacer logic: keep Ice and
    /// the visible section's apps on the bar; MenuBarAgent removes the rest
    /// live. An Ice Bar reveal lifts the assertion (also live).
    @available(macOS 27.0, *)
    private func applyAssessmentMode(hideHidden: Bool, screen: NSScreen, controlPosition: CGFloat, cache: MenuBarItemManager.ItemCache) {
        nativeHiding.setHidden(false, section: .hidden, anchorPosition: controlPosition, screen: screen)
        nativeHiding.setHidden(false, section: .alwaysHidden, anchorPosition: controlPosition, screen: screen)
        let hidden = hideHidden && !macOS27Controller.isLayoutEditing
        macOS27Controller.isConcealingItems = hidden
        guard hidden else {
            assessmentMode.reveal()
            logNativeVisibilityDecision("assessment mode: revealed")
            return
        }
        var allowed: Set<String> = [Constants.bundleIdentifier]
        allowed.formUnion(MacOS27AssessmentMode.alwaysAllowedBundleIDs)
        for item in cache[.visible] where !item.isControlItem {
            let app = item.sourceApplication ?? NSRunningApplication(processIdentifier: item.ownerPID)
            if let id = app?.bundleIdentifier { allowed.insert(id) }
        }
        logNativeVisibilityDecision("assessment mode: concealing all but \(allowed.sorted().joined(separator: ","))")
        Task { [weak self] in
            await self?.assessmentMode.conceal(allowing: allowed)
        }
    }

    /// Re-allows everything the disallowed-apps mode hid. Called on quit.
    func restoreDisallowedAppsOnQuit() {
        guard #available(macOS 27.0, *), !disallowedAppsMode.disallowedApps.isEmpty else { return }
        disallowedAppsMode.restoreAll()
    }

    /// The disallowed-apps mode's replacement for the spacer logic: exactly
    /// the apps owning the hidden section's items are set to not allowed.
    @available(macOS 27.0, *)
    private func applyDisallowedAppsMode(hideHidden: Bool, screen: NSScreen, controlPosition: CGFloat, cache: MenuBarItemManager.ItemCache) {
        // Nothing else conceals in this mode.
        nativeHiding.setHidden(false, section: .hidden, anchorPosition: controlPosition, screen: screen)
        nativeHiding.setHidden(false, section: .alwaysHidden, anchorPosition: controlPosition, screen: screen)
        // An Ice Bar reveal must not re-allow apps (that costs two agent
        // restarts); only the section's own state counts here.
        let hidden = section(withName: .hidden)?.isHidden == true && !macOS27Controller.isLayoutEditing
        var apps = Set<String>()
        if hidden {
            func bundleID(of item: MenuBarItem) -> String? {
                let app = item.sourceApplication ?? NSRunningApplication(processIdentifier: item.ownerPID)
                guard let id = app?.bundleIdentifier, id != Constants.bundleIdentifier else { return nil }
                return id
            }
            // Everything in the visible section stays allowed.
            let visibleApps = Set(cache[.visible].compactMap(bundleID))
            // Enumerated hidden items, apps already disallowed (no longer
            // enumerated), and every running app the record knows about
            // whose item Ice cannot enumerate (Passwords, helpers): if it is
            // not in the visible section, the user put it left of the dot.
            apps.formUnion(cache[.hidden].compactMap(bundleID))
            apps.formUnion(disallowedAppsMode.disallowedApps)
            apps.formUnion(disallowedAppsMode.runningTrackedApps())
            apps.subtract(visibleApps)
            apps.subtract(disallowedAppsMode.temporarilyAllowed)
            apps.remove(Constants.bundleIdentifier)
        }
        macOS27Controller.isConcealingItems = hidden
        logNativeVisibilityDecision("disallowed-apps mode: hidden=\(hidden), apps=\(apps.sorted().joined(separator: ","))")
        disallowedAppsMode.apply(hiddenApps: apps)
    }

    /// Applies only Ice-owned spacer state. Other status items receive native input.
    func syncNativeVisibility() {
        guard #available(macOS 27.0, *), let appState else { return }
        guard nativeDragVisibility.shouldApplyVisibilityUpdate() else {
            logNativeVisibilityDecision("deferred until a native drag ends")
            return
        }
        guard let screen = controlItem(withName: .visible)?.screen ?? NSScreen.main else {
            logNativeVisibilityDecision("no screen for Ice's button")
            return
        }
        let cache = appState.itemManager.itemCache
        let controlPosition = controlItem(withName: .visible)?.preferredPosition ?? 0
        // Physical position, not the previous cache's membership, determines
        // what gets hidden. The first item can have just been dragged left.
        // With the Ice Bar, hidden items stay concealed in the menu bar while
        // the bar displays them, except while one is being clicked.
        let usesIceBar = appState.settings.general.useIceBar
        let hideHidden = usesIceBar
            ? iceBarRevealDepth == 0
            : section(withName: .hidden)?.isHidden == true
        let hideAlwaysHidden = !usesIceBar && !hideHidden && !cache[.alwaysHidden].isEmpty &&
            section(withName: .alwaysHidden)?.isEnabled == true &&
            section(withName: .alwaysHidden)?.isHidden == true
        let iceBounds = macOS27Controller.knownItemsForReordering()
            .first(matching: .visibleControlItem)?.bounds
        let alwaysAnchor = if let leftmostHidden = cache[.hidden].first, let iceBounds {
            controlPosition + max(0, iceBounds.minX - leftmostHidden.bounds.minX)
        } else {
            controlPosition
        }

        if MacOS27AssessmentMode.isEnabled, MenuBarAssessmentAssertion27.isAvailable {
            applyAssessmentMode(hideHidden: hideHidden, screen: screen, controlPosition: controlPosition, cache: cache)
            return
        }

        if MacOS27DisallowedAppsMode.isEnabled {
            applyDisallowedAppsMode(hideHidden: hideHidden, screen: screen, controlPosition: controlPosition, cache: cache)
            return
        }

        if macOS27Controller.isLayoutEditing {
            logNativeVisibilityDecision("showing all items while Layout is editing (reordering: \(macOS27Controller.isReorderInProgress))")
            cancelNativeConcealment()
            if macOS27Controller.isReorderInProgress {
                nativeHiding.showForLayout(
                    anchorPosition: controlPosition,
                    alwaysHiddenAnchor: section(withName: .alwaysHidden)?.isEnabled == true ? alwaysAnchor : nil
                )
            } else {
                nativeHiding.setHidden(false, section: .hidden, anchorPosition: controlPosition, screen: screen)
                nativeHiding.setHidden(false, section: .alwaysHidden, anchorPosition: alwaysAnchor, screen: screen)
            }
            macOS27Controller.isConcealingItems = false
            return
        }

        // Coalesce rapid toggles. MenuBarAgent animates every overflow change,
        // and starting another one mid-animation leaves items flashing. The
        // control item's state still updates immediately; the latest requested
        // state is applied once the previous change has finished animating.
        let changesConcealment = hideHidden != nativeHiding.isConcealing(.hidden) ||
            hideAlwaysHidden != nativeHiding.isConcealing(.alwaysHidden)
        if changesConcealment, let lastChange = lastNativeConcealmentChange {
            let elapsed = lastChange.duration(to: .now)
            if elapsed < Self.nativeConcealmentChangeInterval {
                logNativeVisibilityDecision("waiting for the previous change to finish animating")
                scheduleDeferredNativeVisibilitySync(after: Self.nativeConcealmentChangeInterval - elapsed)
                return
            }
        }

        if hideHidden, !nativeHiding.isConcealing(.hidden) {
            guard nativeConcealmentTask == nil else {
                logNativeVisibilityDecision("hide already in progress")
                return
            }
            let generation = nativeVisibilityGeneration
            let isUserInitiated = lastUserToggleTimestamp.map { $0.duration(to: .now) < .seconds(3) } ?? false
            // Without a notch, Ice's button carries the concealment itself and
            // no boundary needs aligning (see usesButtonOnlyConcealment).
            let buttonOnly = MacOS27NativeMenuBarHiding.usesButtonOnlyConcealment(on: screen)
            // After an automatic attempt couldn't align the boundary without a
            // drag, wait for the user instead of republishing the handle on
            // every cache refresh.
            guard buttonOnly || isUserInitiated || !needsUserActionToAlignBoundary else {
                logNativeVisibilityDecision("waiting for a user action to align Ice's boundary")
                return
            }
            if !buttonOnly { nativeHiding.prepareForHiding(anchorPosition: controlPosition) }
            logNativeVisibilityDecision(buttonOnly
                ? "hiding: button-only concealment (no notch)"
                : "hiding: checking Ice's boundary (user initiated: \(isUserInitiated))")
            nativeConcealmentTask = Task { [weak self] in
                guard let self else { return }
                // No mouse monitor: only an explicit request to hide reaches
                // this check. Moving our blank boundary leaves every other
                // app's native input and the user's new order untouched.
                let aligned = buttonOnly ? true : await appState.itemManager.alignNativeHidingBoundary(
                    updatingCache: true,
                    displayID: screen.displayID,
                    allowingDrag: isUserInitiated
                )
                guard !Task.isCancelled, generation == nativeVisibilityGeneration else {
                    logNativeVisibilityDecision("hide cancelled by a newer request")
                    return
                }
                nativeConcealmentTask = nil
                guard aligned else {
                    logger.error("Keeping items expanded because Ice's boundary could not be verified")
                    needsUserActionToAlignBoundary = !isUserInitiated
                    // The failed attempt published a narrow drag handle. A
                    // logical state reset alone leaves that empty native slot
                    // behind; withdraw both handles before reporting expanded.
                    nativeHiding.setHidden(false, section: .hidden, anchorPosition: controlPosition, screen: screen)
                    nativeHiding.setHidden(false, section: .alwaysHidden, anchorPosition: alwaysAnchor, screen: screen)
                    macOS27Controller.isConcealingItems = false
                    for section in sections { section.controlItem.state = .showSection }
                    return
                }
                needsUserActionToAlignBoundary = false
                if usesIceBar {
                    // Concealed items aren't drawn, so the Ice Bar can only show
                    // images captured while they're still in the menu bar.
                    await appState.imageCache.captureMacOS27Images(for: .hidden, onlyIfMissing: true)
                    guard !Task.isCancelled, generation == nativeVisibilityGeneration else { return }
                }
                nativeHiding.setHidden(false, section: .alwaysHidden, anchorPosition: alwaysAnchor, screen: screen)
                nativeHiding.setHidden(
                    true,
                    section: .hidden,
                    anchorPosition: controlPosition,
                    screen: screen,
                    controlFrame: currentIceButtonFrame()
                )
                lastNativeConcealmentChange = .now
                macOS27Controller.isConcealingItems = true
                logNativeVisibilityDecision("hidden: \(nativeHiding.debugDescription(for: .hidden))")
                scheduleNativeConcealmentCheck(screen: screen)
            }
            return
        }

        if !hideHidden { cancelNativeConcealment() }
        let wasConcealing = nativeHiding.isConcealing(.hidden) || nativeHiding.isConcealing(.alwaysHidden)
        nativeHiding.setHidden(hideAlwaysHidden, section: .alwaysHidden, anchorPosition: alwaysAnchor, screen: screen)
        // Keep an already-concealing spacer at its current length. Resizing it
        // after Ice's button moves makes the whole bar reflow again.
        nativeHiding.setHidden(hideHidden, section: .hidden, anchorPosition: controlPosition, screen: screen)
        if changesConcealment {
            lastNativeConcealmentChange = .now
        }
        macOS27Controller.isConcealingItems = hideHidden || hideAlwaysHidden
        logNativeVisibilityDecision(
            "applied: hidden=\(hideHidden), alwaysHidden=\(hideAlwaysHidden), " +
            "\(nativeHiding.debugDescription(for: .hidden)), always \(nativeHiding.debugDescription(for: .alwaysHidden))"
        )
        if macOS27Controller.isConcealingItems, !wasConcealing {
            scheduleNativeConcealmentCheck(screen: screen)
        } else if macOS27Controller.isConcealingItems, nativeConcealmentCheckTask == nil {
            scheduleStragglerCheck(screen: screen)
        }
    }

    /// Confirms that Ice's own button is still on the bar after a spacer was
    /// widened. The always-hidden spacer's position is a guess, and a spacer
    /// that lands to the right of Ice pushes Ice's button into the overflow,
    /// leaving no way to click it. Withdraw the spacers if that happens.
    @available(macOS 27.0, *)
    private func scheduleNativeConcealmentCheck(screen: NSScreen) {
        nativeConcealmentCheckTask?.cancel()
        nativeConcealmentCheckTask = Task { [weak self] in
            // Accessibility can briefly report no settled frame while hosted
            // variants update, so only a repeated miss counts as a failure.
            let buttonOnly = MacOS27NativeMenuBarHiding.usesButtonOnlyConcealment(on: screen)
            for attempt in 0 ..< (buttonOnly ? 12 : 4) {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, macOS27Controller.isConcealingItems else { return }
                if isIceButtonOnBar(screen: screen) {
                    await shrinkConcealingSpacerUntilDrawn(screen: screen)
                    return
                }
                // Button-only: a padded button MenuBarAgent won't fit is
                // discarded, and with it the only way to click Ice. Narrow
                // the padding before giving up.
                if buttonOnly, attempt >= 2, attempt % 2 == 0 {
                    guard nativeHiding.shrinkConcealingSpacer(section: .hidden) != nil else { break }
                    lastNativeConcealmentChange = .now
                }
            }
            guard let self, !Task.isCancelled, macOS27Controller.isConcealingItems else { return }
            logger.error("Ice's button left the menu bar after hiding; showing all items")
            let controlPosition = controlItem(withName: .visible)?.preferredPosition ?? 0
            cancelNativeConcealment()
            nativeHiding.setHidden(false, section: .alwaysHidden, anchorPosition: controlPosition, screen: screen)
            nativeHiding.setHidden(false, section: .hidden, anchorPosition: controlPosition, screen: screen)
            macOS27Controller.isConcealingItems = false
            for section in sections { section.controlItem.state = .showSection }
        }
    }

    /// A spacer wider than MenuBarAgent can fit (after overflowing everything
    /// to its left) is discarded rather than drawn, and then conceals nothing.
    /// The computed length already leaves a margin for the « button, but the
    /// exact limit isn't published, so verify through Accessibility that the
    /// spacer is actually on the bar and narrow it in steps until it is.
    @available(macOS 27.0, *)
    private func shrinkConcealingSpacerUntilDrawn(screen: NSScreen) async {
        var didShrink = false
        defer {
            // A shrink shortens the primary item; re-fit so the extension
            // item picks up what was removed and the gap stays covered.
            if didShrink { refreshNativeConcealmentLength() }
        }
        for _ in 0 ..< 8 {
            guard macOS27Controller.isConcealingItems, !Task.isCancelled else { return }
            // MenuBarAgent animates the reflow; a frame can be missing for a
            // moment after a resize. Only a repeated miss means "discarded".
            var drawn = false
            for _ in 0 ..< 3 {
                if isConcealingSpacerDrawn(screen: screen) { drawn = true; break }
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                guard macOS27Controller.isConcealingItems, !Task.isCancelled else { return }
            }
            if drawn {
                scheduleStragglerCheck(screen: screen)
                return
            }
            guard nativeHiding.shrinkConcealingSpacer(section: .hidden) != nil else {
                logger.error("The concealing spacer is at its minimum length and still not drawn")
                return
            }
            didShrink = true
            lastNativeConcealmentChange = .now
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
        }
    }

    /// Re-creates the hidden section's spacer so MenuBarAgent inserts it
    /// beside Ice's button (see `MacOS27NativeMenuBarHiding.reinsertSpacerAdjacent`).
    @available(macOS 27.0, *)
    func reinsertNativeBoundaryAdjacent(displayID: CGDirectDisplayID?) async -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID })
            ?? controlItem(withName: .visible)?.screen ?? NSScreen.main else { return false }
        return await nativeHiding.reinsertSpacerAdjacent(section: .hidden, controlItemTag: .visibleControlItem, screen: screen)
    }

    /// Runs the straggler check in its own task, so a concurrent visibility
    /// sync that restarts the concealment check doesn't cancel it midway.
    @available(macOS 27.0, *)
    private func scheduleStragglerCheck(screen: NSScreen) {
        // Superseded by spacer reinsertion (reinsertNativeBoundaryAdjacent):
        // with the spacer directly beside Ice's button nothing can sort
        // between them, and growing the button off a « frame read during a
        // reflow (observed: a 303-pt "gap" right after reinsertion) only
        // caused churn. Kept for diagnosis; enable by removing this return.
        return
        // Button-only concealment has no spacer and nothing can sort between
        // Ice's button and what it hides.
        guard !MacOS27NativeMenuBarHiding.usesButtonOnlyConcealment(on: screen) else { return }
        stragglerCheckTask?.cancel()
        stragglerCheckTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            guard let self, macOS27Controller.isConcealingItems, isConcealingSpacerDrawn(screen: screen) else { return }
            await closeStragglerGapIfAny(screen: screen)
        }
    }

    /// After the spacer is drawn, overflow whatever is still drawn between
    /// the « button and the spacer by growing Ice's button (see
    /// `MacOS27NativeMenuBarHiding.closeStragglerGap`).
    @available(macOS 27.0, *)
    private func closeStragglerGapIfAny(screen: NSScreen) async {
        logger.notice("Straggler check: refreshing MenuBarAgent frames")
        // Refresh MenuBarAgent's « frame; the targeted read updates it.
        _ = await Task.detached(priority: .userInitiated) {
            MacOS27MenuBarItemProvider.menuBarItems(sourcePIDs: [], namespaces: [.controlCenter])
        }.value
        guard macOS27Controller.isConcealingItems, !Task.isCancelled else {
            logger.notice("Straggler check: abandoned (concealing \(self.macOS27Controller.isConcealingItems), cancelled \(Task.isCancelled))")
            return
        }
        let spacer = MacOS27MenuBarItemProvider.ownMenuBarItems().first(matching: .nativeBoundary(for: .hidden))
        let overflowFrames = MacOS27MenuBarItemProvider.overflowControlFrames
        logger.notice("Straggler check: spacer \(spacer?.bounds.debugDescription ?? "none", privacy: .public), overflow control frames \(overflowFrames.map(\.debugDescription).joined(separator: " "), privacy: .public)")
        guard
            let spacer,
            let overflow = overflowFrames
                .filter({ $0.maxX < spacer.bounds.minX })
                .max(by: { $0.maxX < $1.maxX })
        else {
            return
        }
        // A hole between the spacer and Ice's (padded) button holds an item
        // Ice cannot enumerate; it sorts between them and never overflows
        // while the spacer is left of it. Only a native drag of the boundary
        // (a user toggle allows one) fixes the order, so ask for that.
        if let ice = MacOS27MenuBarItemProvider.ownMenuBarItems().first(matching: .visibleControlItem) {
            let hole = ice.bounds.minX - spacer.bounds.maxX
            if hole > 8, !needsUserActionToAlignBoundary {
                logger.error("An unenumerated item occupies \(hole) pt between the spacer and Ice's button; toggle Ice once to let it re-align the boundary, or Command-drag that item left of «")
                needsUserActionToAlignBoundary = true
            }
        }
        if nativeHiding.closeStragglerGap(spacerFrame: spacer.bounds, overflowControlMaxX: overflow.maxX, screen: screen) {
            lastNativeConcealmentChange = .now
            // The wider button must still fit; if MenuBarAgent dropped the
            // spacer instead, the regular check below shows everything.
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            if !isConcealingSpacerDrawn(screen: screen) {
                logger.error("Closing the straggler gap displaced the spacer; showing all items")
                let controlPosition = controlItem(withName: .visible)?.preferredPosition ?? 0
                cancelNativeConcealment()
                nativeHiding.setHidden(false, section: .hidden, anchorPosition: controlPosition, screen: screen)
                macOS27Controller.isConcealingItems = false
                for section in sections { section.controlItem.state = .showSection }
            }
        }
    }

    /// Whether the hidden section's concealing spacer has a frame on the
    /// menu bar strip, i.e. MenuBarAgent accepted its length.
    @available(macOS 27.0, *)
    private func isConcealingSpacerDrawn(screen: NSScreen) -> Bool {
        guard nativeHiding.isConcealing(.hidden) else { return true }
        let display = CGDisplayBounds(screen.displayID)
        let strip = CGRect(x: display.minX, y: display.minY, width: display.width, height: 40)
        let items = MacOS27MenuBarItemProvider.ownMenuBarItems()
        if MacOS27NativeMenuBarHiding.usesButtonOnlyConcealment(on: screen) {
            // The padded button reports its full width through Accessibility.
            guard let ice = items.first(matching: .visibleControlItem) else { return false }
            return strip.contains(ice.bounds) && ice.bounds.width >= nativeHiding.buttonConcealment + 20
        }
        guard let spacer = items.first(matching: .nativeBoundary(for: .hidden)) else { return false }
        return strip.contains(spacer.bounds) && spacer.bounds.width > 8
    }

    /// Returns whether Ice's visible control item is on the menu bar strip of
    /// the given screen and to the right of every widened spacer.
    @available(macOS 27.0, *)
    private func isIceButtonOnBar(screen: NSScreen) -> Bool {
        let display = CGDisplayBounds(screen.displayID)
        let strip = CGRect(x: display.minX, y: display.minY, width: display.width, height: 40)
        let items = MacOS27MenuBarItemProvider.ownMenuBarItems()
        guard let ice = items.first(matching: .visibleControlItem), strip.contains(ice.bounds) else {
            return false
        }
        for section in [MenuBarSection.Name.hidden, .alwaysHidden] where nativeHiding.isConcealing(section) {
            if let spacer = items.first(matching: .nativeBoundary(for: section)),
               strip.contains(spacer.bounds),
               spacer.bounds.minX >= ice.bounds.minX {
                return false
            }
        }
        return true
    }

    /// Re-fits the concealing spacer after the geometry it was sized for
    /// changed: a display was added, removed or resized, or the frontmost app
    /// (and so the width of the app menus) changed.
    @available(macOS 27.0, *)
    private func refreshNativeConcealmentLength() {
        guard
            nativeHiding.isConcealing(.hidden),
            !macOS27Controller.isLayoutEditing,
            nativeConcealmentTask == nil,
            nativeDragVisibility.shouldApplyVisibilityUpdate(),
            let screen = controlItem(withName: .visible)?.screen ?? NSScreen.main,
            let controlFrame = currentIceButtonFrame()
        else {
            return
        }
        if nativeHiding.resizeConcealingSpacerIfNeeded(section: .hidden, screen: screen, controlFrame: controlFrame) {
            lastNativeConcealmentChange = .now
            scheduleNativeConcealmentCheck(screen: screen)
        } else {
            scheduleStragglerCheck(screen: screen)
        }
    }

    /// Returns the current frame of Ice's visible control item, read through
    /// Accessibility from Ice's own process.
    @available(macOS 27.0, *)
    private func currentIceButtonFrame() -> CGRect? {
        MacOS27MenuBarItemProvider.ownMenuBarItems().first(matching: .visibleControlItem)?.bounds
    }

    /// Applies the latest requested visibility once the given delay has passed.
    @available(macOS 27.0, *)
    private func scheduleDeferredNativeVisibilitySync(after delay: Duration) {
        guard deferredNativeVisibilityTask == nil else { return }
        deferredNativeVisibilityTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            deferredNativeVisibilityTask = nil
            syncNativeVisibility()
        }
    }

    /// Logs a macOS 27 visibility decision when it differs from the last one,
    /// so the periodic cache refresh doesn't repeat it every five seconds.
    private func logNativeVisibilityDecision(_ decision: String) {
        guard decision != lastNativeVisibilityDecision else { return }
        lastNativeVisibilityDecision = decision
        logger.notice("macOS 27 visibility: \(decision, privacy: .public)")
    }

    private func cancelNativeConcealment() {
        guard nativeConcealmentTask != nil else { return }
        nativeVisibilityGeneration &+= 1
        nativeConcealmentTask?.cancel()
        nativeConcealmentTask = nil
    }

    /// Even a third-party-to-third-party drag depends on the current native
    /// row: withdrawing or resizing Ice's boundary would move its endpoints.
    /// Pin only the event sequence, not the asynchronous result verification.
    func beginNativeDrag() {
        nativeDragVisibility.beginDrag()
    }

    func endNativeDrag() {
        if nativeDragVisibility.endDrag() {
            syncNativeVisibility()
        }
    }

    /// Temporarily reveals items concealed for the Ice Bar, so one of them
    /// can be clicked where MenuBarAgent draws it.
    @available(macOS 27.0, *)
    func beginIceBarReveal() {
        iceBarRevealDepth += 1
        syncNativeVisibility()
    }

    /// Ends a temporary reveal started by `beginIceBarReveal()`.
    @available(macOS 27.0, *)
    func endIceBarReveal() {
        iceBarRevealDepth = max(0, iceBarRevealDepth - 1)
        syncNativeVisibility()
    }

    /// Whether an Ice Bar click-through currently keeps the items revealed.
    @available(macOS 27.0, *)
    var isIceBarRevealActive: Bool { iceBarRevealDepth > 0 }

    /// Cancels an Ice Bar click-through: closes what the clicked item
    /// opened (by hiding its app) and conceals the items again. Clicking
    /// Ice's button while another item's menu or window is open does this
    /// instead of toggling the section.
    @available(macOS 27.0, *)
    func cancelIceBarReveal() {
        appState?.itemManager.cancelConcealedClick()
        iceBarRevealDepth = 0
        syncNativeVisibility()
    }

    /// Closes whatever the last Ice Bar click-through left open (a status
    /// item's window that outlived the reveal). Returns whether it did.
    @available(macOS 27.0, *)
    func closeClickThroughWindows() async -> Bool {
        await appState?.itemManager.closeClickThroughWindows() ?? false
    }

    /// A click after Layout toggles the actual, currently expanded bar.
    func prepareForControlToggle() {
        guard #available(macOS 27.0, *) else { return }
        lastUserToggleTimestamp = .now
        needsUserActionToAlignBoundary = false
        guard macOS27Controller.isLayoutEditing else { return }
        for section in sections { section.controlItem.state = .showSection }
        macOS27Controller.endLayoutEditing()
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        // The Ice Bar lists disallowed apps through this manager.
        disallowedAppsMode.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &c)

        NSApp.publisher(for: \.currentSystemPresentationOptions)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] options in
                guard let self else {
                    return
                }
                let hidden = options.contains(.hideMenuBar) || options.contains(.autoHideMenuBar)
                isMenuBarHiddenBySystem = hidden
            }
            .store(in: &c)

        if
            let hiddenSection = section(withName: .alwaysHidden),
            let window = hiddenSection.controlItem.window
        {
            window.publisher(for: \.frame)
                .map { $0.origin.y }
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard
                        let self,
                        let isMenuBarHidden = Defaults.globalDomain["_HIHideMenuBar"] as? Bool
                    else {
                        return
                    }
                    isMenuBarHiddenBySystemUserDefaults = isMenuBarHidden
                }
                .store(in: &c)
        }

        // Handle the `focusedApp` rehide strategy.
        NSWorkspace.shared.publisher(for: \.frontmostApplication)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard #unavailable(macOS 27.0) else { return }
                if
                    let self,
                    let appState,
                    case .focusedApp = appState.settings.general.rehideStrategy,
                    let hiddenSection = section(withName: .hidden),
                    let screen = appState.hidEventManager.bestScreen(appState: appState),
                    !appState.hidEventManager.isMouseInsideMenuBar(appState: appState, screen: screen)
                {
                    Task {
                        try await Task.sleep(for: .seconds(0.1))
                        hiddenSection.hide()
                    }
                }
            }
            .store(in: &c)

        // macOS 27: the concealing spacer is sized for one display and one
        // app-menu width. Re-fit it when either changes, once the bar and the
        // new app's menus have settled.
        if #available(macOS 27.0, *) {
            Publishers.Merge3(
                NSWorkspace.shared.publisher(for: \.frontmostApplication)
                    .map { $0?.processIdentifier ?? 0 }
                    .removeDuplicates()
                    .replace(with: ()),
                NotificationCenter.default
                    .publisher(for: NSApplication.didChangeScreenParametersNotification)
                    .replace(with: ()),
                NSWorkspace.shared.notificationCenter
                    .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
                    .replace(with: ())
            )
            .debounce(for: .milliseconds(600), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                self?.refreshNativeConcealmentLength()
            }
            .store(in: &c)
        }

        appState?.publisherForWindow(.settings)
            .sink { [weak self] window in
                self?.settingsWindow = window
            }
            .store(in: &c)

        // SwiftUI does not reliably send `onDisappear` when the Settings
        // window is merely ordered out. End Layout's temporary reveal from the
        // window lifecycle as well, so closing Layout cannot leave every item
        // exposed and consume the next Ice click as a state correction.
        $settingsWindow
            .removeNil()
            .flatMap { $0.publisher(for: \.isVisible) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isVisible in
                guard let self, !isVisible else { return }
                if #available(macOS 27.0, *), macOS27Controller.isLayoutEditing {
                    macOS27Controller.endLayoutEditing()
                }
            }
            .store(in: &c)

        $settingsWindow
            .removeNil()
            .flatMap { $0.publisher(for: \.isVisible) }
            .discardMerge(Timer.publish(every: 5, on: .main, in: .default).autoconnect())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.updateAverageColorInfo()
            }
            .store(in: &c)

        // Hide application menus when a section is shown (if applicable).
        Publishers.MergeMany(sections.map { $0.controlItem.$state })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard #unavailable(macOS 27.0) else { return }
                guard let self, let appState else {
                    return
                }

                // Don't continue if:
                //   * The "HideApplicationMenus" setting isn't enabled.
                //   * Using the Ice Bar.
                //   * The menu bar is hidden by the system.
                //   * The active space is fullscreen.
                //   * The settings window is visible.
                guard
                    appState.settings.advanced.hideApplicationMenus,
                    !appState.settings.general.useIceBar,
                    !isMenuBarHiddenBySystem,
                    !appState.activeSpace.isFullscreen,
                    !appState.navigationState.isSettingsPresented
                else {
                    return
                }

                if sections.contains(where: { $0.controlItem.state == .showSection }) {
                    guard let screen = NSScreen.main else {
                        return
                    }

                    // Get the application menu frame for the display.
                    guard let applicationMenuFrame = screen.getApplicationMenuFrame() else {
                        return
                    }

                    Task {
                        // Get all items.
                        var items = await MenuBarItem.getMenuBarItems(on: screen.displayID, option: .activeSpace)

                        // Filter the items down according to the currently enabled/shown sections.
                        if
                            let alwaysHiddenSection = self.section(withName: .alwaysHidden),
                            alwaysHiddenSection.isEnabled
                        {
                            if alwaysHiddenSection.controlItem.state == .hideSection {
                                if let alwaysHiddenControlItem = items.firstIndex(matching: .alwaysHiddenControlItem).map({ items.remove(at: $0) }) {
                                    items.trimPrefix { $0.bounds.maxX <= alwaysHiddenControlItem.bounds.minX }
                                }
                            }
                        } else {
                            if let hiddenControlItem = items.firstIndex(matching: .hiddenControlItem).map({ items.remove(at: $0) }) {
                                items.trimPrefix { $0.bounds.maxX <= hiddenControlItem.bounds.minX }
                            }
                        }

                        // Get the leftmost item on the screen.
                        guard let leftmostItem = items.min(by: { $0.bounds.minX < $1.bounds.minX }) else {
                            return
                        }

                        // If the minX of the item is less than or equal to the maxX of the
                        // application menu frame, activate the app to hide the menu.
                        if leftmostItem.bounds.minX <= applicationMenuFrame.maxX {
                            self.hideApplicationMenus()
                        }
                    }
                } else if isHidingApplicationMenus {
                    showApplicationMenus()
                }
            }
            .store(in: &c)

        cancellables = c
    }

    /// Updates the ``averageColorInfo`` property with the current average color
    /// of the menu bar.
    func updateAverageColorInfo() {
        guard
            let settingsWindow,
            settingsWindow.isVisible,
            let screen = settingsWindow.screen
        else {
            return
        }

        let windows = WindowInfo.createWindows(option: .onScreen)
        let displayID = screen.displayID

        guard
            let menuBarWindow = WindowInfo.menuBarWindow(from: windows, for: displayID),
            let wallpaperWindow = WindowInfo.wallpaperWindow(from: windows, for: displayID)
        else {
            return
        }

        guard
            let image = ScreenCapture.captureWindows(
                with: [menuBarWindow.windowID, wallpaperWindow.windowID],
                screenBounds: withMutableCopy(of: wallpaperWindow.bounds) { $0.size.height = 1 },
                option: .nominalResolution
            ),
            let color = image.averageColor(option: .ignoreAlpha)
        else {
            return
        }

        let info = MenuBarAverageColorInfo(color: color, source: .menuBarWindow)

        if averageColorInfo != info {
            averageColorInfo = info
        }
    }

    /// Returns a Boolean value that indicates whether the given display
    /// has a valid menu bar.
    func hasValidMenuBar(in windows: [WindowInfo], for display: CGDirectDisplayID) -> Bool {
        guard
            let window = WindowInfo.menuBarWindow(from: windows, for: display),
            let element = AXHelpers.element(at: window.bounds.origin)
        else {
            return false
        }
        return AXHelpers.role(for: element) == .menuBar
    }

    /// Shows the secondary context menu.
    func showSecondaryContextMenu(at point: CGPoint) {
        let menu = NSMenu(title: "Ice")

        let editAppearanceItem = NSMenuItem(
            title: "Edit Menu Bar Appearance…",
            action: #selector(showAppearanceEditorPanel),
            keyEquivalent: ""
        )
        editAppearanceItem.target = self
        menu.addItem(editAppearanceItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Ice Settings…",
            action: #selector(AppDelegate.openSettingsWindow),
            keyEquivalent: ","
        )
        menu.addItem(settingsItem)

        menu.popUp(positioning: nil, at: point, in: nil)
    }

    /// Hides the application menus.
    func hideApplicationMenus() {
        guard let appState else {
            logger.error("Error hiding application menus: Missing app state")
            return
        }
        logger.info("Hiding application menus")
        appState.activate(withPolicy: .regular)
        isHidingApplicationMenus = true
    }

    /// Shows the application menus.
    func showApplicationMenus() {
        guard let appState else {
            logger.error("Error showing application menus: Missing app state")
            return
        }
        logger.info("Showing application menus")
        appState.deactivate(withPolicy: .accessory)
        isHidingApplicationMenus = false
    }

    /// Toggles the visibility of the application menus.
    func toggleApplicationMenus() {
        if isHidingApplicationMenus {
            showApplicationMenus()
        } else {
            hideApplicationMenus()
        }
    }

    /// Shows the appearance editor panel.
    @objc private func showAppearanceEditorPanel() {
        guard let screen = MenuBarAppearanceEditorPanel.defaultScreen else {
            return
        }
        appearanceEditorPanel.show(on: screen)
    }

    /// Returns the menu bar section with the given name.
    func section(withName name: MenuBarSection.Name) -> MenuBarSection? {
        sections.first { $0.name == name }
    }

    /// Returns the control item for the menu bar section with the given name.
    func controlItem(withName name: MenuBarSection.Name) -> ControlItem? {
        section(withName: name)?.controlItem
    }
}

// MARK: - MenuBarAverageColorInfo

/// Information for the average color of the menu bar.
struct MenuBarAverageColorInfo: Hashable {
    /// Sources used to compute the average color of the menu bar.
    enum Source: Hashable {
        case menuBarWindow
        case desktopWallpaper
    }

    /// The average color of the menu bar
    var color: CGColor

    /// The source used to compute the color.
    var source: Source

    /// The brightness of the menu bar's color.
    var brightness: CGFloat { color.brightness ?? 0 }

    /// A Boolean value that indicates whether the menu bar has a
    /// bright color.
    ///
    /// This value is `true` if ``brightness`` is above `0.67`. At
    /// the time of writing, if this value is `true`, the menu bar
    /// draws its items with a darker appearance.
    var isBright: Bool { brightness > 0.67 }
}
