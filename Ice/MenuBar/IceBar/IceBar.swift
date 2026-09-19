//
//  IceBar.swift
//  Ice
//

import Combine
import OSLog
import SwiftUI

// MARK: - IceBarPanel

final class IceBarPanel: NSPanel {
    /// The shared app state.
    private weak var appState: AppState?

    /// Manager for the Ice Bar's color.
    private let colorManager = IceBarColorManager()

    /// The currently displayed section.
    private(set) var currentSection: MenuBarSection.Name?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// A passive monitor that closes the panel when the user clicks in
    /// another app, used on macOS 27 where Ice installs no event taps.
    private var outsideClickMonitor: Any?

    /// Creates a new Ice Bar panel.
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        self.title = "Ice Bar"
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = true
        self.allowsToolTipsWhenApplicationIsInactive = true
        self.isFloatingPanel = true
        self.animationBehavior = .none
        self.backgroundColor = .clear
        self.hasShadow = false
        self.level = .mainMenu + 1
        self.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .moveToActiveSpace]
    }

    /// Sets up the panel.
    func performSetup(with appState: AppState) {
        self.appState = appState
        configureCancellables()
        colorManager.performSetup(with: self)
    }

    /// Configures the internal observers.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        // Hide the panel when the active space or screen parameters change.
        Publishers.Merge(
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification),
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
        )
        .sink { [weak self] _ in
            self?.hide()
        }
        .store(in: &c)

        // Update the panel's origin whenever its size changes.
        publisher(for: \.frame).map(\.size)
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, let screen else {
                    return
                }
                updateOrigin(for: screen)
            }
            .store(in: &c)

        // On macOS 27, the hidden section's control item is never added to the
        // menu bar, so its missing frame says nothing about the menu bar.
        if #unavailable(macOS 27.0), let controlItem = appState?.menuBarManager.controlItem(withName: .hidden) {
            // Use the hidden control item's frame to determine if the menu bar
            // is hidden. Hide the panel if so.
            controlItem.$frame
                .combineLatest(controlItem.$screen)
                .throttle(for: 0.1, scheduler: DispatchQueue.main, latest: true)
                .sink { [weak self] (frame, screen) in
                    guard let self else {
                        return
                    }

                    guard let frame, let screen else {
                        hide()
                        return
                    }

                    // Icon is not vertically visible. We can infer that the
                    // menu bar is hidden.
                    if frame.maxY > screen.frame.maxY {
                        hide()
                    }
                }
                .store(in: &c)
        }

        cancellables = c
    }

    /// Updates the panel's frame origin for display on the given screen.
    private func updateOrigin(for screen: NSScreen) {
        guard let appState else {
            return
        }

        func getOrigin(for iceBarLocation: IceBarLocation) -> CGPoint {
            let menuBarHeight = screen.getMenuBarHeight()
                ?? max(screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness)
            let originY = ((screen.frame.maxY - 1) - menuBarHeight) - frame.height

            var originForRightOfScreen: CGPoint {
                CGPoint(x: screen.frame.maxX - frame.width, y: originY)
            }

            switch iceBarLocation {
            case .dynamic:
                if appState.hidEventManager.isMouseInsideEmptyMenuBarSpace(appState: appState, screen: screen) {
                    return getOrigin(for: .mousePointer)
                }
                return getOrigin(for: .iceIcon)
            case .mousePointer:
                guard let location = MouseHelpers.locationAppKit else {
                    return getOrigin(for: .iceIcon)
                }

                let lowerBound = screen.frame.minX
                let upperBound = screen.frame.maxX - frame.width

                guard lowerBound <= upperBound else {
                    return originForRightOfScreen
                }

                return CGPoint(x: (location.x - frame.width / 2).clamped(to: lowerBound...upperBound), y: originY)
            case .iceIcon:
                let lowerBound = screen.frame.minX
                let upperBound = screen.frame.maxX - frame.width

                if #available(macOS 27.0, *) {
                    guard
                        lowerBound <= upperBound,
                        let itemBounds = MacOS27MenuBarItemProvider.ownMenuBarItems()
                            .first(matching: .visibleControlItem)?.bounds
                    else {
                        return originForRightOfScreen
                    }
                    return CGPoint(x: (itemBounds.midX - frame.width / 2).clamped(to: lowerBound...upperBound), y: originY)
                }

                guard
                    lowerBound <= upperBound,
                    let controlItem = appState.itemManager.itemCache.managedItems.first(matching: .visibleControlItem),
                    // Bridging API is more reliable than controlItem.frame in some
                    // cases (like if the item is offscreen).
                    let itemBounds = Bridging.getWindowBounds(for: controlItem.windowID)
                else {
                    return originForRightOfScreen
                }

                return CGPoint(x: (itemBounds.midX - frame.width / 2).clamped(to: lowerBound...upperBound), y: originY)
            }
        }

        setFrameOrigin(getOrigin(for: appState.settings.general.iceBarLocation))
    }

    /// Shows the panel on the given screen, displaying the given
    /// menu bar section.
    func show(section: MenuBarSection.Name, on screen: NSScreen) async {
        guard let appState else {
            return
        }

        // IMPORTANT: We must set the navigation state and current section
        // before updating the caches.
        appState.navigationState.isIceBarPresented = true
        currentSection = section

        // On macOS 27, refreshing walks every running app's accessibility tree
        // and routinely hits the timeout, while concealed items can't be read or
        // captured anyway. Show the cached items at once; the periodic refresh
        // keeps them current.
        if #unavailable(macOS 27.0) {
            let cacheTask = Task(timeout: .seconds(1)) {
                await appState.itemManager.cacheItemsIfNeeded()
                await appState.imageCache.updateCache()
            }

            do {
                try await cacheTask.value
            } catch {
                Logger.default.error("Cache update failed when showing IceBarPanel - \(error)")
            }
        }

        contentView = IceBarHostingView(
            appState: appState,
            colorManager: colorManager,
            screen: screen,
            section: section
        )

        updateOrigin(for: screen)

        // Color manager must be updated after updating the panel's origin,
        // but before it is shown.
        //
        // Color manager handles frame changes automatically, but does so on
        // the main queue, so we need to update manually once before showing
        // the panel to prevent the color from flashing.
        colorManager.updateAllProperties(with: frame, screen: screen)

        orderFrontRegardless()

        if #available(macOS 27.0, *), outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                guard let self, isVisible, !frame.contains(NSEvent.mouseLocation) else {
                    return
                }
                // A mouse-down on Ice's own button must not close the bar
                // here: the button's action fires on mouse-up and would then
                // toggle the section back on, reopening the bar. Let the
                // button's toggle do the closing.
                if let iceButtonFrame = appState.menuBarManager.controlItem(withName: .visible)?.frame,
                   iceButtonFrame.contains(NSEvent.mouseLocation) {
                    return
                }
                hide()
            }
        }
    }

    /// Hides the panel.
    func hide() {
        if
            let name = currentSection,
            let section = appState?.menuBarManager.section(withName: name)
        {
            section.hide()
        }
        close()
    }

    override func close() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        super.close()
        contentView = nil
        currentSection = nil
        appState?.navigationState.isIceBarPresented = false
    }
}

// MARK: - IceBarHostingView

private final class IceBarHostingView: NSHostingView<IceBarContentView> {
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }

    init(
        appState: AppState,
        colorManager: IceBarColorManager,
        screen: NSScreen,
        section: MenuBarSection.Name
    ) {
        let rootView = IceBarContentView(
            appState: appState,
            colorManager: colorManager,
            itemManager: appState.itemManager,
            imageCache: appState.imageCache,
            menuBarManager: appState.menuBarManager,
            screen: screen,
            section: section
        )
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @available(*, unavailable)
    required init(rootView: IceBarContentView) {
        fatalError("init(rootView:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

// MARK: - IceBarContentView

private struct IceBarContentView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var colorManager: IceBarColorManager
    @ObservedObject var itemManager: MenuBarItemManager
    @ObservedObject var imageCache: MenuBarItemImageCache
    @ObservedObject var menuBarManager: MenuBarManager
    @State private var frame = CGRect.zero
    @State private var scrollIndicatorsFlashTrigger = 0

    let screen: NSScreen
    let section: MenuBarSection.Name

    /// Bumped after a drag reorder so the sorted list is recomputed.
    @State private var orderVersion = 0

    private var items: [MenuBarItem] {
        let cached = itemManager.itemCache.managedItems(for: section)
        guard #available(macOS 27.0, *), section == .hidden else { return cached }
        _ = orderVersion
        return IceBarOrder.sorted(cached)
    }

    /// Moves the dragged tile in front of `target` and persists the order.
    @available(macOS 27.0, *)
    private func reorder(dragged draggedID: String, before target: MenuBarItem) {
        var ids = items.map(\.tag.persistentIdentifier)
        guard let from = ids.firstIndex(of: draggedID) else { return }
        ids.remove(at: from)
        let to = ids.firstIndex(of: target.tag.persistentIdentifier) ?? ids.count
        ids.insert(draggedID, at: to)
        IceBarOrder.save(ids)
        orderVersion += 1
    }

    /// Apps the disallowed-apps mode hid whose items are no longer
    /// enumerated (a disallowed item isn't laid out at all).
    @available(macOS 27.0, *)
    private var disallowedAppsNotListed: [String] {
        let listed = Set(items.compactMap { $0.sourceApplication?.bundleIdentifier })
        return menuBarManager.disallowedAppsMode.disallowedApps.subtracting(listed).sorted()
    }

    /// Whether items without a captured image show their app's icon instead.
    /// Concealed items aren't drawn at all on macOS 27, so an image can be
    /// missing even with screen recording permission.
    private static var usesApplicationIconFallback: Bool {
        if #available(macOS 27.0, *) {
            return true
        }
        return false
    }

    private var configuration: MenuBarAppearanceConfigurationV2 {
        appState.appearanceManager.configuration
    }

    private var horizontalPadding: CGFloat {
        if #available(macOS 26.0, *) {
            return 3
        }
        return configuration.hasRoundedShape ? 7 : 5
    }

    private var verticalPadding: CGFloat {
        if #available(macOS 26.0, *) {
            return screen.hasNotch && configuration.hasRoundedShape ? 2 : 0
        }
        return screen.hasNotch ? 0 : 2
    }

    private var contentHeight: CGFloat? {
        guard let menuBarHeight = screen.getMenuBarHeight() else {
            return nil
        }
        if configuration.shapeKind != .noShape && configuration.isInset && screen.hasNotch {
            return menuBarHeight - appState.appearanceManager.menuBarInsetAmount * 2
        }
        return menuBarHeight
    }

    private var clipShape: some InsettableShape {
        if configuration.hasRoundedShape {
            RoundedRectangle(cornerRadius: frame.height / 2, style: .circular)
        } else if #available(macOS 26.0, *) {
            RoundedRectangle(cornerRadius: frame.height / 4, style: .continuous)
        } else {
            RoundedRectangle(cornerRadius: frame.height / 5, style: .continuous)
        }
    }

    private var backgroundOpacity: Double {
        appState.settings.general.iceBarBackgroundOpacity
    }

    private var shadowOpacity: CGFloat {
        configuration.current.hasShadow ? 0.5 : 0.33
    }

    var body: some View {
        ZStack {
            content
                .frame(height: contentHeight)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .menuBarItemContainer(
                    appState: appState,
                    colorInfo: colorManager.colorInfo,
                    backgroundOpacity: backgroundOpacity
                )
                .foregroundStyle(colorManager.colorInfo?.color.brightness ?? 0 > 0.67 ? .black : .white)
                .clipShape(clipShape)
                .shadow(color: .black.opacity(shadowOpacity * backgroundOpacity), radius: 2.5)

            if configuration.current.hasBorder {
                clipShape
                    .inset(by: configuration.current.borderWidth / 2)
                    .stroke(lineWidth: configuration.current.borderWidth)
                    .foregroundStyle(Color(cgColor: configuration.current.borderColor))
                    .opacity(backgroundOpacity)
            }
        }
        .padding(5)
        .frame(maxWidth: screen.frame.width)
        .fixedSize()
        .onFrameChange(update: $frame)
    }

    @ViewBuilder
    private var content: some View {
        if !Self.usesApplicationIconFallback, !ScreenCapture.cachedCheckPermissions() {
            HStack {
                Text("The Ice Bar requires screen recording permissions.")

                Button {
                    menuBarManager.section(withName: section)?.hide()
                    appState.navigationState.settingsNavigationIdentifier = .advanced
                    appState.activate(withPolicy: .regular)
                    appState.openWindow(.settings)
                } label: {
                    Text("Open Ice Settings")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.link)
            }
            .padding(.horizontal, 10)
        } else if menuBarManager.isMenuBarHiddenBySystemUserDefaults {
            Text("Ice cannot display menu bar items for automatically hidden menu bars")
                .padding(.horizontal, 10)
        } else if itemManager.itemCache.managedItems.isEmpty {
            HStack {
                Text("Loading menu bar items…")
                ProgressView()
                    .controlSize(.small)
            }
            .padding(.horizontal, 10)
        } else if !Self.usesApplicationIconFallback, imageCache.cacheFailed(for: section) {
            Text("Unable to display menu bar items")
                .padding(.horizontal, 10)
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(items, id: \.windowID) { item in
                        IceBarItemView(
                            imageCache: imageCache,
                            itemManager: itemManager,
                            menuBarManager: menuBarManager,
                            item: item,
                            section: section,
                            onDrop: { draggedID in
                                if #available(macOS 27.0, *) { reorder(dragged: draggedID, before: item) }
                            }
                        )
                    }
                    if #available(macOS 27.0, *), section == .hidden {
                        // Apps hidden through "Allow in the Menu Bar" have no
                        // item to show; list them by app icon instead.
                        ForEach(disallowedAppsNotListed, id: \.self) { bundleID in
                            IceBarDisallowedAppView(bundleID: bundleID, menuBarManager: menuBarManager)
                        }
                    }
                }
            }
            .environment(\.isScrollEnabled, frame.width == screen.frame.width)
            .defaultScrollAnchor(.trailing)
            .scrollIndicatorsFlash(trigger: scrollIndicatorsFlashTrigger)
            .task {
                scrollIndicatorsFlashTrigger += 1
            }
        }
    }
}

// MARK: - IceBarItemView

/// The Ice Bar's own tile order for the hidden section on macOS 27, kept
/// in defaults. Items not in the list keep their menu bar order after the
/// listed ones... in front, so a fresh item appears where it is.
@available(macOS 27.0, *)
enum IceBarOrder {
    private static let key = "MacOS27IceBarOrder"

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func save(_ ids: [String]) {
        UserDefaults.standard.set(ids, forKey: key)
    }

    /// Stable sort: listed items in list order, the rest keep their order.
    static func sorted(_ items: [MenuBarItem]) -> [MenuBarItem] {
        let order = load()
        guard !order.isEmpty else { return items }
        let index = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return items.enumerated().sorted { lhs, rhs in
            let l = index[lhs.element.tag.persistentIdentifier]
            let r = index[rhs.element.tag.persistentIdentifier]
            switch (l, r) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}

private struct IceBarItemView: View {
    @ObservedObject var imageCache: MenuBarItemImageCache
    @ObservedObject var itemManager: MenuBarItemManager
    @ObservedObject var menuBarManager: MenuBarManager

    let item: MenuBarItem
    let section: MenuBarSection.Name
    /// Called with the dragged tile's identifier when another tile is
    /// dropped onto this one (macOS 27 Ice Bar reordering).
    var onDrop: ((String) -> Void)?

    private var leftClickAction: () -> Void {
        return { [weak itemManager, weak menuBarManager] in
            guard let itemManager, let menuBarManager else {
                return
            }
            menuBarManager.section(withName: section)?.hide()
            if #available(macOS 27.0, *) {
                if MacOS27DisallowedAppsMode.isEnabled {
                    // A disallowed item is not laid out and cannot be clicked;
                    // the reveal path would re-allow everything (two agent
                    // restarts, ~20 s). Open the app instead.
                    let app = item.sourceApplication ?? NSRunningApplication(processIdentifier: item.ownerPID)
                    if let bundleID = app?.bundleIdentifier {
                        menuBarManager.openDisallowedApp(bundleID: bundleID)
                    } else {
                        app?.activate()
                    }
                    return
                }
                Task {
                    await itemManager.clickConcealedItem(item, with: .left)
                }
                return
            }
            Task {
                try await Task.sleep(for: .milliseconds(25))
                if Bridging.isWindowOnScreen(item.windowID) {
                    try await itemManager.click(item: item, with: .left)
                } else {
                    await itemManager.temporarilyShow(item: item, clickingWith: .left)
                }
            }
        }
    }

    private var rightClickAction: () -> Void {
        return { [weak itemManager, weak menuBarManager] in
            guard let itemManager, let menuBarManager else {
                return
            }
            menuBarManager.section(withName: section)?.hide()
            if #available(macOS 27.0, *) {
                Task {
                    await itemManager.clickConcealedItem(item, with: .right)
                }
                return
            }
            Task {
                try await Task.sleep(for: .milliseconds(25))
                if Bridging.isWindowOnScreen(item.windowID) {
                    try await itemManager.click(item: item, with: .right)
                } else {
                    await itemManager.temporarilyShow(item: item, clickingWith: .right)
                }
            }
        }
    }

    private var image: NSImage? {
        if let cachedImage = imageCache.images[item.tag] {
            if #available(macOS 27.0, *) {
                return IceBarGlyphImages.image(for: cachedImage, tag: item.tag)
            }
            return cachedImage.nsImage
        }
        if #available(macOS 27.0, *) {
            return applicationIcon
        }
        return nil
    }

    /// The icon of the app that owns the item, sized like a menu bar item.
    private var applicationIcon: NSImage? {
        guard
            let application = NSRunningApplication(processIdentifier: item.sourcePID ?? item.ownerPID),
            let icon = application.icon?.copy() as? NSImage
        else {
            return nil
        }
        // Same slot metrics as extracted glyphs (IceBarGlyphImages), so app
        // icons and glyphs get the same size and gap.
        if #available(macOS 27.0, *) {
            icon.size = CGSize(width: IceBarGlyphImages.appIconSize, height: IceBarGlyphImages.appIconSize)
        } else {
            icon.size = CGSize(width: 18, height: 18)
        }
        let slot = if #available(macOS 27.0, *) { IceBarGlyphImages.tileSlot } else { CGSize(width: 32, height: 22) }
        let image = NSImage(size: slot, flipped: false) { bounds in
            icon.draw(in: CGRect(
                x: (bounds.width - icon.size.width) / 2,
                y: (bounds.height - icon.size.height) / 2,
                width: icon.size.width,
                height: icon.size.height
            ))
            return true
        }
        return image
    }

    var body: some View {
        if let image {
            Image(nsImage: image)
                .renderingMode(image.isTemplate ? .template : .original)
                .contentShape(Rectangle())
                .overlay {
                    IceBarItemClickView(
                        item: item,
                        leftClickAction: leftClickAction,
                        rightClickAction: rightClickAction,
                        dropAction: onDrop
                    )
                }
                .accessibilityLabel(item.displayName)
                .accessibilityAction(named: "left click", leftClickAction)
                .accessibilityAction(named: "right click", rightClickAction)
        }
    }
}

// MARK: - IceBarDisallowedAppView

/// A tile for an app hidden through "Allow in the Menu Bar": its item is
/// not laid out, so it cannot be clicked. Clicking the tile activates the
/// app (launching it if needed).
@available(macOS 27.0, *)
private struct IceBarDisallowedAppView: View {
    let bundleID: String
    @ObservedObject var menuBarManager: MenuBarManager

    private var image: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = CGSize(width: IceBarGlyphImages.appIconSize, height: IceBarGlyphImages.appIconSize)
        return NSImage(size: IceBarGlyphImages.tileSlot, flipped: false) { bounds in
            icon.draw(in: CGRect(
                x: (bounds.width - icon.size.width) / 2,
                y: (bounds.height - icon.size.height) / 2,
                width: icon.size.width,
                height: icon.size.height
            ))
            return true
        }
    }

    private var name: String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
    }

    var body: some View {
        if let image {
            Image(nsImage: image)
                .renderingMode(.original)
                .contentShape(Rectangle())
                .onTapGesture {
                    menuBarManager.section(withName: .hidden)?.hide()
                    menuBarManager.openDisallowedApp(bundleID: bundleID)
                }
                .help(name)
                .accessibilityLabel(name)
        }
    }
}

// MARK: - IceBarGlyphImages

/// Converts captured menu bar crops into glyphs for the Ice Bar on macOS 27.
///
/// Other apps' status item images aren't available through any API, so the
/// crops come from a capture of the menu bar. Removing the bar's background
/// lets monochrome glyphs take the Ice Bar's foreground color, and colored
/// glyphs keep their colors on a transparent background.
@available(macOS 27.0, *)
@MainActor
private enum IceBarGlyphImages {
    private static let cache = NSCache<AnyObject, NSImage>()

    static func image(for capturedImage: MenuBarItemImageCache.CapturedImage, tag: MenuBarItemTag) -> NSImage {
        let key = capturedImage.cgImage as AnyObject
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let image: NSImage
        let glyph = MenuBarGlyphImage.make(from: capturedImage.cgImage)
        let trimmed = glyph.flatMap { trimmedToVisiblePixels($0.image) }
        if let glyph, let trimmed {
            image = centeredImage(trimmed, scale: capturedImage.scale)
            image.isTemplate = glyph.isTemplate
        } else {
            image = capturedImage.nsImage
        }
        if MacOS27GlyphDebug.isEnabled {
            if let glyph {
                MacOS27GlyphDebug.write(glyph.image, name: "\(tag)-glyph")
            }
            if let trimmed {
                MacOS27GlyphDebug.write(trimmed, name: "\(tag)-trimmed")
            }
            let captureSize = "\(capturedImage.cgImage.width)x\(capturedImage.cgImage.height)"
            let trimmedSize = trimmed.map { "\($0.width)x\($0.height)" } ?? "none"
            MacOS27GlyphDebug.log("Ice Bar \(tag): capture \(captureSize) at \(capturedImage.scale)x, extracted \(glyph != nil) template \(glyph?.isTemplate ?? false), trimmed \(trimmedSize)")
        }
        cache.setObject(image, forKey: key)
        return image
    }

    /// Draws a glyph centered in a slot of uniform height. Apps report status
    /// item frames with different vertical offsets, so crops taken from those
    /// frames place their glyphs at different heights.
    /// Menu bar glyphs are drawn at this multiple of their bar size.
    static let tileScale: CGFloat = 1.2
    /// The minimum tile, shared with the app-icon tiles.
    static let tileSlot = CGSize(width: 36, height: 24)
    /// App icons in tiles are drawn this large.
    static let appIconSize: CGFloat = 20

    private static func centeredImage(_ glyph: CGImage, scale: CGFloat) -> NSImage {
        // Drawn a little larger than in the menu bar (captures are 2x, so
        // this stays sharp), matching the 20-pt app-icon tiles.
        let glyphSize = CGSize(
            width: CGFloat(glyph.width) / scale * Self.tileScale,
            height: CGFloat(glyph.height) / scale * Self.tileScale
        )
        let horizontalPadding: CGFloat = 8
        // Never narrower than an app-icon slot, so narrow glyphs don't
        // bunch up next to wider ones or the app-icon fallbacks.
        let slotSize = CGSize(
            width: max(Self.tileSlot.width, (glyphSize.width + horizontalPadding * 2).rounded(.up)),
            height: max(Self.tileSlot.height, glyphSize.height.rounded(.up))
        )
        return NSImage(size: slotSize, flipped: false) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else {
                return false
            }
            context.interpolationQuality = .high
            context.draw(glyph, in: CGRect(
                x: ((bounds.width - glyphSize.width) / 2).rounded(),
                y: ((bounds.height - glyphSize.height) / 2).rounded(),
                width: glyphSize.width,
                height: glyphSize.height
            ))
            return true
        }
    }

    /// Crops an image with transparency to the bounds of its visible pixels.
    private static func trimmedToVisiblePixels(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            return nil
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            return nil
        }
        // Bitmap context rows run top to bottom, matching `cropping(to:)`.
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0 ..< height {
            for x in 0 ..< width where pixels[(y * width + x) * 4 + 3] > 12 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else {
            return nil
        }
        return image.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    }
}

// MARK: - IceBarItemClickView

private extension NSView {
    /// A bitmap of this view's contents within `rect` (in its own coordinates).
    func snapshotImage(of rect: CGRect) -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }
}

private struct IceBarItemClickView: NSViewRepresentable {
    /// Pasteboard type carrying a dragged tile's persistent identifier.
    static let dragType = NSPasteboard.PasteboardType("com.jordanbaird.Ice.bar-item")

    private final class Represented: NSView, NSDraggingSource {
        let item: MenuBarItem

        let leftClickAction: () -> Void
        let rightClickAction: () -> Void
        let dropAction: ((String) -> Void)?

        private var lastLeftMouseDownDate = Date.now
        private var lastRightMouseDownDate = Date.now

        private var lastLeftMouseDownLocation = CGPoint.zero
        private var lastRightMouseDownLocation = CGPoint.zero
        private var isDragging = false

        init(
            item: MenuBarItem,
            leftClickAction: @escaping () -> Void,
            rightClickAction: @escaping () -> Void,
            dropAction: ((String) -> Void)?
        ) {
            self.item = item
            self.leftClickAction = leftClickAction
            self.rightClickAction = rightClickAction
            self.dropAction = dropAction
            super.init(frame: .zero)
            self.toolTip = item.displayName
            if dropAction != nil {
                registerForDraggedTypes([IceBarItemClickView.dragType])
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            lastLeftMouseDownDate = .now
            lastLeftMouseDownLocation = NSEvent.mouseLocation
            isDragging = false
        }

        // MARK: Reordering by drag (macOS 27 Ice Bar)

        override func mouseDragged(with event: NSEvent) {
            super.mouseDragged(with: event)
            guard dropAction != nil, !isDragging,
                  lastLeftMouseDownLocation.distance(to: NSEvent.mouseLocation) >= 5 else { return }
            isDragging = true
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(item.tag.persistentIdentifier, forType: IceBarItemClickView.dragType)
            let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
            // The tile's image lives in the SwiftUI view underneath; snapshot
            // the superview region so the drag shows the icon, not a blank.
            let image = superview.flatMap { $0.snapshotImage(of: frame) } ?? NSImage(size: bounds.size)
            draggingItem.setDraggingFrame(bounds, contents: image)
            beginDraggingSession(with: [draggingItem], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            sender.draggingPasteboard.string(forType: IceBarItemClickView.dragType) == nil ? [] : .move
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard let id = sender.draggingPasteboard.string(forType: IceBarItemClickView.dragType),
                  id != item.tag.persistentIdentifier, let dropAction else { return false }
            dropAction(id)
            return true
        }

        override func rightMouseDown(with event: NSEvent) {
            super.rightMouseDown(with: event)
            lastRightMouseDownDate = .now
            lastRightMouseDownLocation = NSEvent.mouseLocation
        }

        override func mouseUp(with event: NSEvent) {
            super.mouseUp(with: event)
            guard
                Date.now.timeIntervalSince(lastLeftMouseDownDate) < 0.5,
                lastLeftMouseDownLocation.distance(to: NSEvent.mouseLocation) < 5
            else {
                return
            }
            leftClickAction()
        }

        override func rightMouseUp(with event: NSEvent) {
            super.rightMouseUp(with: event)
            guard
                Date.now.timeIntervalSince(lastRightMouseDownDate) < 0.5,
                lastRightMouseDownLocation.distance(to: NSEvent.mouseLocation) < 5
            else {
                return
            }
            rightClickAction()
        }
    }

    let item: MenuBarItem

    let leftClickAction: () -> Void
    let rightClickAction: () -> Void
    var dropAction: ((String) -> Void)?

    func makeNSView(context: Context) -> NSView {
        Represented(
            item: item,
            leftClickAction: leftClickAction,
            rightClickAction: rightClickAction,
            dropAction: dropAction
        )
    }

    func updateNSView(_ nsView: NSView, context: Context) { }
}
