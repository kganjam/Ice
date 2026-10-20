//
//  MacOS27AssessmentMode.swift
//  Ice
//
//  The assertion wrapper is adapted from Ice PR #995 (RabenkoYevhenii),
//  itself adapted from Barometer's MenuBarAssessmentAssertion.swift
//  (https://github.com/mackid1993/Barometer) and Thaw's PlatformRuntimeKit
//  (https://github.com/thaw-app/Thaw). All GPLv3, like Ice.
//

import Cocoa
import OSLog

/// Hides the hidden section on macOS 27 through MenuBarAgent's assessment
/// mode: an allow-list of applications whose items stay on the bar. Every
/// other app's items are removed from the layout live, with no restart, no
/// spacer, no « button and no blank stretch. This is what baaar, Hidden
/// and Bartender's macOS 27 builds use.
///
/// Opt-in: `defaults write com.jordanbaird.Ice MacOS27AssessmentMode -bool true`.
/// Notes (measured by those projects and PR #995): only a signed app bundle
/// can hold the assertion; MenuBarAgent keeps nine system items (battery,
/// Bluetooth, clock, displays, keyboard brightness, sound, Wi‑Fi, screen
/// mirroring, Control Center) and drops its other modules while an
/// assertion is live; Notification Center won't open while one is live,
/// so it is lifted while items are revealed; the assertion dies with Ice,
/// which brings every item back.
@available(macOS 27.0, *)
@MainActor
final class MacOS27AssessmentMode {
    static let flagKey = "MacOS27AssessmentMode"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: flagKey)
    }

    /// Bundle identifiers that stay on the bar whenever the hidden section is
    /// concealed, whatever the layout says. For apps Ice cannot enumerate
    /// (no `AXExtrasMenuBar`, e.g. Parallels Desktop, MacMixer): they can't
    /// be placed in the visible section, and an assertion would otherwise
    /// remove them. `defaults write com.jordanbaird.Ice
    /// MacOS27AssessmentAlwaysAllowed -array com.example.app …`
    static let alwaysAllowedKey = "MacOS27AssessmentAlwaysAllowed"

    static var alwaysAllowedBundleIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: alwaysAllowedKey) ?? [])
    }

    private let logger = Logger(category: "MacOS27AssessmentMode")

    private var assertion: AnyObject?
    private(set) var allowedBundleIDs: Set<String> = []
    private var activating = false
    /// Bumped by every reveal, so an activation that was still waiting for
    /// MenuBarAgent when the reveal came doesn't conceal afterwards.
    private var revealCount = 0
    /// LaunchServices answers per process, cached by pid and launch date.
    private var launchServicesCopies = [ProcessKey: URL?]()
    private var reportedCopies = Set<String>()

    private struct ProcessKey: Hashable {
        let pid: pid_t
        let launchDate: Date?
    }

    /// Whether an assertion is currently live.
    var isConcealing: Bool { assertion != nil }

    /// Keeps exactly `allowed` on the bar. Re-activates only when the set
    /// changes. Returns whether an assertion is live afterwards.
    @discardableResult
    func conceal(allowing allowed: Set<String>) async -> Bool {
        if assertion != nil, allowed == allowedBundleIDs { return true }
        guard !activating else { return assertion != nil }
        activating = true
        defer { activating = false }
        let revealsBefore = revealCount
        // MenuBarAgent applies the newest assertion; invalidate the old one
        // after the new one is live so the bar doesn't flash expanded.
        let previous = assertion
        do {
            let token = try await MenuBarAssessmentAssertion27.activate(allowedBundleIDs: allowed.sorted())
            guard revealCount == revealsBefore else {
                MenuBarAssessmentAssertion27.invalidate(token)
                logger.notice("Revealed while the assertion was activating; dropped it")
                return false
            }
            assertion = token
            allowedBundleIDs = allowed
            if let previous { MenuBarAssessmentAssertion27.invalidate(previous) }
            logger.notice("Concealing; allowed apps: \(allowed.sorted().joined(separator: ", "), privacy: .public)")
            return true
        } catch {
            logger.error("Assessment assertion failed: \(String(describing: error), privacy: .public)")
            return assertion != nil
        }
    }

    /// Lifts the assertion; every item returns to the bar.
    func reveal() {
        revealCount &+= 1
        guard let assertion else { return }
        MenuBarAssessmentAssertion27.invalidate(assertion)
        self.assertion = nil
        allowedBundleIDs = []
        logger.notice("Revealed (assertion invalidated)")
    }

    /// Whether MenuBarAgent can keep `app`'s items on the bar through the
    /// allow-list. It identifies a status item's app by bundle identifier
    /// only for the copy LaunchServices resolves that identifier to; any
    /// other copy (an Xcode DerivedData build of an app that is also in
    /// /Applications, for example) is tracked by its executable path, as an
    /// "adhocBinary" in Control Center's record, and an assertion removes it
    /// even though its bundle identifier is allowed. Logs each such copy once.
    func canKeepOnBar(_ app: NSRunningApplication) -> Bool {
        let key = ProcessKey(pid: app.processIdentifier, launchDate: app.launchDate)
        let resolved: URL?
        if let cached = launchServicesCopies[key] {
            resolved = cached
        } else {
            resolved = Self.otherLaunchServicesCopy(of: app)
            if launchServicesCopies.count > 256 { launchServicesCopies.removeAll() }
            launchServicesCopies[key] = resolved
        }
        guard let resolved else { return true }
        let running = app.bundleURL?.path ?? "?"
        if reportedCopies.insert("\(app.bundleIdentifier ?? "?")|\(running)").inserted {
            logger.warning("\(app.bundleIdentifier ?? "?", privacy: .public) runs from \(running, privacy: .public), but LaunchServices resolves it to \(resolved.path, privacy: .public). MenuBarAgent can't keep this copy on the bar while Ice hides items, so the Ice Bar lists its items. Run the copy LaunchServices resolves to keep it on the bar.")
        }
        return false
    }

    /// The copy LaunchServices resolves `app`'s bundle identifier to, when
    /// `app` is a different copy.
    private static func otherLaunchServicesCopy(of app: NSRunningApplication) -> URL? {
        guard
            let bundleID = app.bundleIdentifier,
            let running = app.bundleURL,
            let resolved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else {
            return nil
        }
        func canonical(_ url: URL) -> String {
            url.resolvingSymlinksInPath().standardizedFileURL.path
        }
        return canonical(running) == canonical(resolved) ? nil : resolved
    }
}

/// Runtime binding to `MBAssessmentModeAssertion` in the private
/// MenuBarClientCore framework.
@available(macOS 27.0, *)
enum MenuBarAssessmentAssertion27 {
    enum Failure: Error, CustomStringConvertible {
        case unavailable
        case rejected(String)
        case timedOut

        var description: String {
            switch self {
            case .unavailable: "MenuBarClientCore is unavailable"
            case .rejected(let reason): "MenuBarAgent rejected the assertion: \(reason)"
            case .timedOut: "MenuBarAgent did not answer within 3 seconds"
            }
        }
    }

    private static let frameworkPath = "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore"
    private static let configureSelector = NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")
    private static let activateSelector = NSSelectorFromString("activateWithConfiguration:completionHandler:")
    private static let invalidateSelector = NSSelectorFromString("invalidate")

    /// MenuBarAgent numbers its system items 0 through 8 on macOS 27.0; keep all of them.
    private static let systemItems = (0...8).map { NSNumber(value: $0) } as NSArray

    private static let classes: (configuration: AnyClass, assertion: AnyClass)? = {
        guard
            dlopen(frameworkPath, RTLD_NOW) != nil,
            let configuration = NSClassFromString("MBAssessmentModeConfiguration"),
            let assertion = NSClassFromString("MBAssessmentModeAssertion"),
            configuration.instancesRespond(to: configureSelector),
            assertion.instancesRespond(to: activateSelector),
            assertion.instancesRespond(to: invalidateSelector)
        else {
            return nil
        }
        return (configuration, assertion)
    }()

    static var isAvailable: Bool { classes != nil }

    /// Guards a continuation shared by a completion handler and a timeout.
    private final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.withLock {
                defer { claimed = true }
                return !claimed
            }
        }
    }

    @MainActor
    static func activate(allowedBundleIDs: [String]) async throws -> AnyObject {
        guard
            let classes,
            let configuration = (classes.configuration.alloc() as AnyObject)
                .perform(configureSelector, with: systemItems, with: allowedBundleIDs as NSArray)?
                .takeUnretainedValue(),
            let assertion = (classes.assertion.alloc() as AnyObject)
                .perform(NSSelectorFromString("init"))?
                .takeUnretainedValue()
        else {
            throw Failure.unavailable
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let oneShot = OneShot()
                let completion: @convention(block) (Any?) -> Void = { error in
                    guard oneShot.claim() else { return }
                    if let error {
                        continuation.resume(throwing: Failure.rejected(String(describing: error)))
                    } else {
                        continuation.resume()
                    }
                }
                _ = assertion.perform(activateSelector, with: configuration, with: completion)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    guard oneShot.claim() else { return }
                    continuation.resume(throwing: Failure.timedOut)
                }
            }
        } catch {
            _ = assertion.perform(invalidateSelector)
            throw error
        }
        return assertion
    }

    static func invalidate(_ assertion: AnyObject) {
        _ = assertion.perform(invalidateSelector)
    }
}
