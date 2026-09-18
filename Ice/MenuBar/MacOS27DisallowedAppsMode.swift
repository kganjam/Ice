//
//  MacOS27DisallowedAppsMode.swift
//  Ice
//

import Cocoa
import OSLog

/// Hides the hidden section on macOS 27 by turning the owning apps'
/// "Allow in the Menu Bar" switch off, instead of pushing their items into
/// MenuBarAgent's overflow behind a blank spacer.
///
/// System Settings › Menu Bar keeps that switch per app in Control Center's
/// group-container preferences (`trackedApplications`, an array of
/// dictionaries with `isAllowed`). MenuBarAgent honours it when it starts:
/// neither the pane, a relaunch of the app, nor a Control Center restart
/// applied a change live (measured on 27.0), but `launchctl kickstart -k`
/// of `com.apple.MenuBarAgent` did, in a one-to-two-second menu bar blink.
/// A disallowed item is not laid out at all, so there is no spacer, no
/// « button and no blank stretch left of Ice's button.
///
/// Off by default. Enable with
/// `defaults write com.jordanbaird.Ice MacOS27DisallowHiddenApps -bool true`
/// and relaunch Ice. Only apps present in the record can be disallowed;
/// MenuBarAgent's own modules (Clock, Control Center, Wi‑Fi…) and apps that
/// never registered there stay managed by the spacer path or stay visible.
@MainActor
final class MacOS27DisallowedAppsMode: ObservableObject {
    static let flagKey = "MacOS27DisallowHiddenApps"
    private static let disallowedKey = "MacOS27DisallowedByIce"
    private static let recordDomain = (
        "~/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter" as NSString
    ).expandingTildeInPath

    private let logger = Logger(category: "MacOS27DisallowedAppsMode")

    /// Whether the mode is enabled (read once at launch).
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: flagKey)
    }

    /// Bundle identifiers Ice has set to not allowed, persisted so a later
    /// launch can restore them and the Ice Bar can list them.
    @Published private(set) var disallowedApps: Set<String>

    /// Set once the record could not be read; the mode then stays inert
    /// until the next launch.
    @Published private(set) var recordUnavailable = false

    init() {
        disallowedApps = Set(UserDefaults.standard.stringArray(forKey: Self.disallowedKey) ?? [])
    }

    private func persist() {
        UserDefaults.standard.set(Array(disallowedApps).sorted(), forKey: Self.disallowedKey)
    }

    // MARK: Record access

    /// The parsed `trackedApplications` record and the raw outer plist.
    private func readRecord() throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: Self.recordDomain + ".plist")
        let data = try Data(contentsOf: url)
        guard
            let outer = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let blob = outer["trackedApplications"] as? Data,
            let entries = try PropertyListSerialization.propertyList(from: blob, format: nil) as? [[String: Any]]
        else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return entries
    }

    /// Apps in the record that are currently running, keyed by the record's
    /// bundle identifier. An app's item may be published by a helper with
    /// its own bundle id (`menuItemLocations`), so those are matched too.
    func runningTrackedApps() -> Set<String> {
        guard let entries = try? readRecord() else { return [] }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var result = Set<String>()
        var index = 0
        while index < entries.count {
            defer { index += 1 }
            guard let bundle = entries[index]["bundle"] as? [String: Any],
                  let id = bundle["_0"] as? String, entries[index].count == 1 else { continue }
            var candidates: Set<String> = [id]
            if index + 1 < entries.count,
               let locations = entries[index + 1]["menuItemLocations"] as? [[String: Any]] {
                for location in locations {
                    if let bundle = location["bundle"] as? [String: Any], let helper = bundle["_0"] as? String {
                        candidates.insert(helper)
                    }
                }
            }
            if !candidates.isDisjoint(with: running) { result.insert(id) }
        }
        return result
    }

    /// Bundle identifiers the record knows about.
    func trackedBundleIdentifiers() -> Set<String> {
        let entries: [[String: Any]]
        do {
            entries = try readRecord()
        } catch {
            logger.error("Could not read the Allow in the Menu Bar record at \(Self.recordDomain, privacy: .public).plist: \(error)")
            return []
        }
        var ids = Set<String>()
        for entry in entries {
            if let bundle = entry["bundle"] as? [String: Any], let id = bundle["_0"] as? String {
                ids.insert(id)
            }
        }
        return ids
    }

    /// Sets `isAllowed` for the given apps. Returns the apps whose value
    /// actually changed. The record is written back through `defaults`, so
    /// cfprefsd sees the change (a direct file write is served stale).
    private func setAllowed(_ allowed: Bool, for bundleIDs: Set<String>) throws -> Set<String> {
        guard !bundleIDs.isEmpty else { return [] }
        var entries = try readRecord()
        var changed = Set<String>()
        var index = 0
        while index < entries.count {
            // Entries come in pairs: {bundle: {_0: id}} then the settings
            // dictionary ({location…, menuItemLocations, isAllowed}).
            if let bundle = entries[index]["bundle"] as? [String: Any],
               let id = bundle["_0"] as? String,
               entries[index].count == 1,
               index + 1 < entries.count,
               entries[index + 1]["isAllowed"] != nil || entries[index + 1]["location"] != nil {
                if bundleIDs.contains(id) {
                    let current = entries[index + 1]["isAllowed"] as? Bool ?? true
                    if current != allowed {
                        entries[index + 1]["isAllowed"] = allowed
                        changed.insert(id)
                    }
                }
                index += 2
            } else {
                index += 1
            }
        }
        guard !changed.isEmpty else { return [] }
        let blob = try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
        let hex = blob.map { String(format: "%02x", $0) }.joined()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["write", Self.recordDomain, "trackedApplications", "-data", hex]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        return changed
    }

    /// Restarts MenuBarAgent so it re-reads the record. launchd brings it
    /// back on its own; every app re-registers its item (~1–2 s blink).
    private func restartMenuBarAgent() {
        // `launchctl kickstart -k` is the clean way; it has answered 150 from
        // Ice's context, so fall back to a plain termination, which launchd
        // also answers by relaunching the agent.
        let attempts: [(String, [String])] = [
            ("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/com.apple.MenuBarAgent"]),
            ("/usr/bin/killall", ["MenuBarAgent"]),
        ]
        for (path, arguments) in attempts {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            do {
                try process.run()
                process.waitUntilExit()
                logger.notice("\(path, privacy: .public) \(arguments.joined(separator: " "), privacy: .public) exited \(process.terminationStatus)")
                if process.terminationStatus == 0 { return }
            } catch {
                logger.error("Could not run \(path, privacy: .public): \(error)")
            }
        }
        logger.error("Could not restart MenuBarAgent; the Allow in the Menu Bar change applies at its next start")
    }

    // MARK: Applying a hidden set

    /// Makes exactly `hiddenApps` disallowed (re-allowing anything else Ice
    /// disallowed before). Restarts MenuBarAgent only if something changed.
    /// Returns whether a restart happened.
    @discardableResult
    func apply(hiddenApps: Set<String>) -> Bool {
        guard !recordUnavailable else { return false }
        // The user may have flipped switches in System Settings since the
        // last restart; those only take effect when MenuBarAgent starts, so
        // restart for them too (ChatGPT stayed visible after being turned
        // off there).
        let recordNotAllowed = notAllowedInRecord()
        var externalChange = false
        if let applied = notAllowedAtLastRestart, applied != recordNotAllowed {
            externalChange = true
        }
        let tracked = trackedBundleIdentifiers()
        if tracked.isEmpty {
            // Reading another app's group container is "app data" access;
            // without Full Disk Access (or the "access data from other apps"
            // approval) macOS answers EPERM. Don't retry every sync.
            recordUnavailable = true
            logger.error("The Allow in the Menu Bar record is unreadable; grant Ice Full Disk Access (System Settings › Privacy & Security) and relaunch. Falling back to no hiding until then.")
            return false
        }
        let wanted = hiddenApps.intersection(tracked)
        let toDisallow = wanted.subtracting(disallowedApps)
        let toAllow = disallowedApps.subtracting(wanted)
        guard !toDisallow.isEmpty || !toAllow.isEmpty || externalChange else {
            if notAllowedAtLastRestart == nil { notAllowedAtLastRestart = recordNotAllowed }
            return false
        }
        var changed = externalChange
        if externalChange {
            logger.notice("Allow in the Menu Bar switches changed outside Ice; restarting MenuBarAgent to apply them")
        }
        do {
            if !toAllow.isEmpty {
                let done = try setAllowed(true, for: toAllow)
                changed = changed || !done.isEmpty
                disallowedApps.subtract(toAllow)
            }
            if !toDisallow.isEmpty {
                let done = try setAllowed(false, for: toDisallow)
                changed = changed || !done.isEmpty
                disallowedApps.formUnion(done)
            }
        } catch {
            logger.error("Could not update the Allow in the Menu Bar record: \(error)")
        }
        persist()
        let skipped = hiddenApps.subtracting(tracked)
        if !skipped.isEmpty {
            logger.notice("Not in the Allow in the Menu Bar record, left visible: \(skipped.sorted().joined(separator: ", "), privacy: .public)")
        }
        logger.notice("Disallowed apps now: \(self.disallowedApps.sorted().joined(separator: ", "), privacy: .public)")
        if changed {
            restartMenuBarAgent()
            notAllowedAtLastRestart = notAllowedInRecord()
        }
        return changed
    }

    /// What MenuBarAgent applied at its last restart (all not-allowed apps
    /// in the record, Ice's and the user's), to notice outside changes.
    private var notAllowedAtLastRestart: Set<String>?

    /// Every app the record currently marks as not allowed.
    private func notAllowedInRecord() -> Set<String> {
        guard let entries = try? readRecord() else { return [] }
        var result = Set<String>()
        var index = 0
        while index + 1 < entries.count {
            if let bundle = entries[index]["bundle"] as? [String: Any],
               let id = bundle["_0"] as? String, entries[index].count == 1,
               entries[index + 1]["isAllowed"] as? Bool == false {
                result.insert(id)
            }
            index += 1
        }
        return result
    }

    /// Re-allows everything Ice disallowed. Used when the mode is turned
    /// off and when Ice quits, so no item stays hidden without Ice.
    @discardableResult
    func restoreAll() -> Bool {
        apply(hiddenApps: [])
    }

    /// Apps re-allowed for one click on their menu bar item. The sync that
    /// computes the hidden set leaves these alone until `endTemporaryAllow`.
    @Published private(set) var temporarilyAllowed = Set<String>()

    /// Re-allows one app so its item is laid out and can be clicked.
    /// Returns whether MenuBarAgent was restarted (the item appears after).
    func allowTemporarily(_ bundleID: String) -> Bool {
        temporarilyAllowed.insert(bundleID)
        guard disallowedApps.contains(bundleID) else { return false }
        do {
            let done = try setAllowed(true, for: [bundleID])
            disallowedApps.remove(bundleID)
            persist()
            guard !done.isEmpty else { return false }
            logger.notice("Temporarily re-allowed \(bundleID, privacy: .public)")
            restartMenuBarAgent()
            notAllowedAtLastRestart = notAllowedInRecord()
            return true
        } catch {
            logger.error("Could not re-allow \(bundleID, privacy: .public): \(error)")
            return false
        }
    }

    /// Ends a temporary allow; the next sync disallows the app again.
    func endTemporaryAllow(_ bundleID: String) {
        temporarilyAllowed.remove(bundleID)
    }
}
