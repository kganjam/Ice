//
//  MacOS27DynamicItemState.swift
//  Ice
//

import CoreGraphics
import Foundation

/// Runtime identities are deliberately not restored across Ice launches. An
/// unidentified AX item must be classified from the native bar again instead
/// of inheriting the assignment of an unrelated item with the same label.
/// Only per-app facts (`MacOS27VisibleApps`) and the Ice Bar's tile order
/// (`sessionIndependentKeys`) outlive them.
enum MacOS27RuntimeItemIdentity {
    static let prefix = "Ice.RuntimeItem."

    static func isStoredIdentifier(_ identifier: String) -> Bool {
        identifier.contains(":\(prefix)")
    }

    /// Keys that survive Ice launches, for orders Ice keeps across them. A
    /// runtime identity becomes its owner plus its ordinal among that owner's
    /// runtime items in `identifiers`; any other identifier is its own key.
    static func sessionIndependentKeys(_ identifiers: [String]) -> [String: String] {
        var ordinals = [Substring: Int]()
        var keys = [String: String]()
        for identifier in identifiers {
            guard let range = identifier.range(of: ":\(prefix)") else {
                keys[identifier] = identifier
                continue
            }
            let owner = identifier[..<range.lowerBound]
            let ordinal = ordinals[owner, default: 0]
            ordinals[owner] = ordinal + 1
            keys[identifier] = "\(owner):Ice.RuntimeItem@\(ordinal)"
        }
        return keys
    }
}

/// The apps that own an item in the visible section, remembered by bundle
/// identifier. While an assessment-mode assertion conceals the hidden
/// section, MenuBarAgent draws only allowed apps' items, and Ice can only
/// enumerate and classify an item that is drawn. An app restarted while
/// concealed comes back with a new runtime identity, so without this memory
/// it dropped out of the allow-list and never came back.
enum MacOS27VisibleApps {
    /// Folds one enumeration into the remembered set. `observed` maps each
    /// app seen in this pass to whether any of its items is in the visible
    /// section. Apps not seen (quit, or not drawn) keep their last state.
    static func updated(_ remembered: Set<String>, observed: [String: Bool]) -> Set<String> {
        var result = remembered
        for (app, isVisible) in observed {
            if isVisible {
                result.insert(app)
            } else {
                result.remove(app)
            }
        }
        return result
    }

    /// The same for apps whose items are all outside the visible section.
    /// Their items aren't drawn while concealed, so one that (re)started
    /// after the conceal is not enumerated until the items are revealed.
    static func updatedHidden(_ remembered: Set<String>, observed: [String: Bool]) -> Set<String> {
        updated(remembered, observed: observed.mapValues { !$0 })
    }
}

/// A small, bounded map of AX-object equality to identities. Labels and frames
/// are intentionally not inputs: both can change while the same item lives.
struct MacOS27RuntimeItemRegistry<Element> {
    private struct Entry {
        let element: Element
        let owner: String
        let identity: String
        var lastSeen: TimeInterval
    }

    private var entries = [Entry]()
    private let session = UUID().uuidString
    private var nextIdentity: UInt64 = 0
    private let capacity: Int

    var count: Int { entries.count }

    init(capacity: Int = 512) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    mutating func identity(
        for element: Element,
        owner: String,
        now: TimeInterval,
        equals: (Element, Element) -> Bool
    ) -> String {
        if let index = entries.firstIndex(where: { $0.owner == owner && equals($0.element, element) }) {
            entries[index].lastSeen = now
            return entries[index].identity
        }
        if entries.count >= capacity,
           let oldest = entries.indices.min(by: { entries[$0].lastSeen < entries[$1].lastSeen }) {
            entries.remove(at: oldest)
        }
        let identity = "\(MacOS27RuntimeItemIdentity.prefix)\(session).\(nextIdentity)"
        nextIdentity &+= 1
        entries.append(Entry(element: element, owner: owner, identity: identity, lastSeen: now))
        return identity
    }

    mutating func removeUnavailableOwners(_ owners: Set<String>) {
        entries.removeAll { !owners.contains($0.owner) }
    }
}

enum MacOS27ItemSnapshotGeometry {
    /// An off-bar child is not actionable, but its published AX identity still
    /// proves existence. Missing-item confirmation must not filter it out.
    static func includes(
        frame: CGRect,
        menuBarFrames: [CGRect],
        maxItemHeight: CGFloat,
        includingOffscreenItems: Bool
    ) -> Bool {
        includingOffscreenItems || (
            frame.width > 0 && frame.height > 0 && frame.height <= maxItemHeight &&
            menuBarFrames.contains { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) }
        )
    }
}

/// Missing expanded snapshots receive a short grace period. Expiry merely
/// requests a successful owner reread; it is not proof of item withdrawal.
struct MacOS27MissingItemGrace {
    private var firstMissingAt = [String: TimeInterval]()

    mutating func saw(_ identifier: String) {
        firstMissingAt.removeValue(forKey: identifier)
    }

    mutating func needsVerification(_ identifier: String, canObserve: Bool, now: TimeInterval) -> Bool {
        guard canObserve else {
            saw(identifier)
            return false
        }
        guard let first = firstMissingAt[identifier] else {
            firstMissingAt[identifier] = now
            return false
        }
        return now - first >= 2
    }
}

/// Layout's refresh scope belongs to the editor session, not to its current
/// tiles. A living host with zero items must remain eligible to republish one.
struct MacOS27LayoutOwnerRegistry<Namespace: Hashable> {
    struct Owner: Hashable {
        let pid: Int32
        let namespace: Namespace
        let launchTime: TimeInterval?
    }

    private var isActive = false
    private var owners = Set<Owner>()
    private var namespaces = Set<Namespace>()
    private var previousRunningOwners = Set<Owner>()

    mutating func begin(knownOwners: Set<Owner>, runningOwners: Set<Owner>) {
        guard !isActive else { return }
        isActive = true
        previousRunningOwners = runningOwners
        observe(knownOwners.intersection(runningOwners))
    }

    mutating func end() {
        isActive = false
        owners.removeAll()
        namespaces.removeAll()
        previousRunningOwners.removeAll()
    }

    mutating func observe(_ publishedOwners: Set<Owner>) {
        guard isActive else { return }
        owners.formUnion(publishedOwners)
        namespaces.formUnion(publishedOwners.map(\.namespace))
    }

    mutating func runningApplicationsChanged(_ runningOwners: Set<Owner>) {
        guard isActive else { return }
        let launched = runningOwners.subtracting(previousRunningOwners)
        previousRunningOwners = runningOwners
        owners.formIntersection(runningOwners)
        observe(launched)
    }

    func targets(runningOwners: Set<Owner>) -> (sourcePIDs: Set<Int32>, namespaces: Set<Namespace>) {
        guard isActive else { return ([], []) }
        // Verify the process lifetime, not just the recycled numeric PID.
        // Namespaces also let the provider resolve an observed owner's restart.
        return (Set(owners.intersection(runningOwners).map(\.pid)), namespaces)
    }
}

/// MenuBarAgent's own items (namespace `com.apple.controlcenter`) under an
/// assessment-mode assertion. MenuBarClientCore's `MBSystemItemIdentifier`
/// has exactly nine cases on 27.0 (battery, bluetooth, keyboardBrightness,
/// clock, displays, screenMirroring, volume, wifi, controlCenter); the
/// assertion keeps those and removes every other MenuBarAgent item, such as
/// Now Playing, user switching or Focus, whatever Ice's layout says.
enum MacOS27SystemItems {
    /// The kept items' accessibility identifiers.
    static let keptWhileConcealed: Set<String> = [
        "com.apple.menuextra.battery",
        "com.apple.menuextra.bluetooth",
        "com.apple.menuextra.keyboard-brightness",
        "com.apple.menuextra.clock",
        "com.apple.menuextra.display",
        "com.apple.menuextra.displays",
        "com.apple.menuextra.screen-mirroring",
        "com.apple.menuextra.sound",
        "com.apple.menuextra.wifi",
        "com.apple.menuextra.controlcenter",
    ]

    /// The kept items as the Layout editor names them.
    static let keptWhileConcealedNames =
        "battery, Bluetooth, clock, displays, keyboard brightness, sound, Wi‑Fi, screen mirroring and Control Center"

    /// Whether the MenuBarAgent item with this accessibility identifier stays
    /// on the bar while an assertion is live.
    static func isKeptWhileConcealed(_ identifier: String) -> Bool {
        keptWhileConcealed.contains(identifier) || identifier.hasPrefix("BentoBox")
    }
}
