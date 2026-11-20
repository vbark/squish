import AppKit
import CoreServices

/// The files selected in Finder, read with Apple Events. macOS asks once for permission to control Finder.
enum FinderSelection {
    nonisolated static let finderID = "com.apple.finder"

    enum Failure: Error {
        /// Another app is in front, so there is no Finder selection the user is looking at.
        case finderNotInFront
        /// The user turned off Squish's access to Finder in Privacy & Security › Automation.
        case notPermitted
        case scriptError(String)
    }

    /// Selected items in the frontmost Finder window or on the desktop. Main thread only (NSAppleScript).
    static func current() -> Result<[URL], Failure> {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == finderID else {
            return .failure(.finderNotInFront)
        }
        var error: NSDictionary?
        let script = NSAppleScript(source: "tell application id \"\(finderID)\" to return selection as alias list")
        guard let list = script?.executeAndReturnError(&error) else {
            let code = error?[NSAppleScript.errorNumber] as? Int
            if code == Int(errAEEventNotPermitted) { return .failure(.notPermitted) }
            return .failure(.scriptError(error?[NSAppleScript.errorMessage] as? String ?? "Finder did not answer."))
        }
        guard list.numberOfItems > 0 else { return .success([]) }
        return .success((1...list.numberOfItems).compactMap { list.atIndex($0)?.fileURLValue })
    }

    enum Access {
        case allowed, notAsked, denied, unknown
    }

    /// Whether Squish may control Finder. With `ask`, shows the system prompt if the user hasn't decided yet.
    /// Blocks while the prompt is up, so call it off the main actor.
    @concurrent
    static func access(ask: Bool) async -> Access {
        if NSRunningApplication.runningApplications(withBundleIdentifier: finderID).isEmpty { return .unknown }
        let target = NSAppleEventDescriptor(bundleIdentifier: finderID)
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
        switch status {
        case noErr: return .allowed
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .unknown
        }
    }

    static func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }
}
