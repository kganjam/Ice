//
//  MacOS27LayoutRequests.swift
//  Ice
//

import Cocoa
import OSLog

/// One-shot Layout moves requested through defaults, for scripts and agents
/// that can't drive the Settings window (they have no Accessibility
/// permission of their own). Shortly after launch Ice removes the key and
/// performs each move exactly as a drag in Settings › Menu Bar Layout would:
///
///     defaults write com.jordanbaird.Ice MacOS27LayoutRequests -array \
///       '{ item = "ru.keepcoder.Telegram"; section = hidden; }' \
///       '{ item = "com.kganjam.gestalt"; leftOf = "com.parallels.desktop.console"; }'
///
/// `item`, `leftOf` and `rightOf` name an item by its owner's bundle
/// identifier (that app's first item in menu bar order) or by its persistent
/// identifier (`<namespace>:<title>#<n>`). `section` is `visible`, `hidden`
/// or `alwaysHidden`; with `leftOf`/`rightOf` it defaults to the target's.
/// Items macOS draws itself can't be moved this way either.
@available(macOS 27.0, *)
@MainActor
enum MacOS27LayoutRequests {
    static let key = "MacOS27LayoutRequests"

    private static let logger = Logger(category: "MacOS27LayoutRequests")

    struct Request: CustomStringConvertible {
        let item: String
        let section: MenuBarSection.Name?
        let leftOf: String?
        let rightOf: String?

        var description: String {
            var parts = ["item=\(item)"]
            if let section { parts.append("section=\(section.logString)") }
            if let leftOf { parts.append("leftOf=\(leftOf)") }
            if let rightOf { parts.append("rightOf=\(rightOf)") }
            return parts.joined(separator: " ")
        }
    }

    static func pending() -> [Request] {
        let entries = UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            guard let item = entry["item"] as? String else { return nil }
            let section: MenuBarSection.Name? = switch (entry["section"] as? String)?.lowercased() {
            case "visible": .visible
            case "hidden": .hidden
            case "alwayshidden", "always-hidden", "always hidden": .alwaysHidden
            default: nil
            }
            return Request(
                item: item,
                section: section,
                leftOf: entry["leftOf"] as? String,
                rightOf: entry["rightOf"] as? String
            )
        }
    }

    /// Applies and clears the pending requests, one at a time, inside a
    /// Layout editing session (every item is shown meanwhile).
    static func applyPending(appState: AppState) async {
        let requests = pending()
        guard UserDefaults.standard.object(forKey: key) != nil else { return }
        // One-shot: never retry a request on every launch.
        UserDefaults.standard.removeObject(forKey: key)
        guard !requests.isEmpty else {
            logger.error("Ignoring unreadable \(key, privacy: .public)")
            return
        }
        let itemManager = appState.itemManager
        let controller = appState.menuBarManager.macOS27Controller
        controller.beginLayoutEditing()
        defer { controller.endLayoutEditing() }
        await refresh(itemManager)

        for request in requests {
            guard let item = find(request.item, in: itemManager.itemCache) else {
                logger.error("Layout request \(request, privacy: .public): no such item")
                continue
            }
            do {
                if let name = request.leftOf ?? request.rightOf {
                    guard let target = find(name, in: itemManager.itemCache) else {
                        logger.error("Layout request \(request, privacy: .public): no item \(name, privacy: .public)")
                        continue
                    }
                    let destination: MenuBarItemManager.MoveDestination = request.leftOf != nil
                        ? .leftOfItem(target)
                        : .rightOfItem(target)
                    let section = request.section ?? itemManager.itemCache.address(for: target.tag)?.section
                    try await itemManager.move(item: item, to: destination, requiredSection: section)
                } else if let section = request.section {
                    try await itemManager.move(item: item, toSection: section)
                } else {
                    logger.error("Layout request \(request, privacy: .public): needs section, leftOf or rightOf")
                    continue
                }
            } catch {
                logger.error("Layout request \(request, privacy: .public) failed: \(error, privacy: .public)")
                continue
            }
            await waitForReorder(controller)
            await refresh(itemManager)
            logger.notice("Layout request \(request, privacy: .public): now \(placement(of: item.tag, in: itemManager.itemCache), privacy: .public)")
        }
    }

    private static func refresh(_ itemManager: MenuBarItemManager) async {
        try? await Task.sleep(for: .milliseconds(500))
        await itemManager.cacheItemsRegardless(ignoringRecentMovement: true, refreshingAllOwners: true)
    }

    private static func waitForReorder(_ controller: MacOS27MenuBarController) async {
        let deadline = ContinuousClock.now + .seconds(30)
        try? await Task.sleep(for: .milliseconds(300))
        while controller.isReorderInProgress, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private static func find(_ name: String, in cache: MenuBarItemManager.ItemCache) -> MenuBarItem? {
        let items = MenuBarSection.Name.allCases.reversed().flatMap { cache[$0] }
        if let item = items.first(where: { $0.tag.persistentIdentifier == name }) {
            return item
        }
        return items.first { item in
            !item.isControlItem && (
                item.tag.namespace.description == name ||
                    item.sourceApplication?.bundleIdentifier == name ||
                    item.owningApplication?.bundleIdentifier == name
            )
        }
    }

    private static func placement(of tag: MenuBarItemTag, in cache: MenuBarItemManager.ItemCache) -> String {
        guard let address = cache.address(for: tag) else { return "not found" }
        let items = cache[address.section]
        let left = address.index > 0 ? items[address.index - 1].displayName : "-"
        let right = address.index + 1 < items.count ? items[address.index + 1].displayName : "-"
        return "\(address.section.logString) #\(address.index) between \(left) and \(right)"
    }
}
