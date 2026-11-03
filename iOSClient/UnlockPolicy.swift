import Foundation

/// Unlocking a locked Mac with this device's Face ID or Touch ID (docs/unlock-biometric-plan.md): the
/// Mac's password is kept once in this device's Keychain, and a small chip over the stream types it at the
/// Mac's lock screen after the person passes the check. Device only: the password travels as the typing
/// every paired session may already do at a locked screen (docs/locked-mac-plan.md), nothing is new on the
/// wire. Pure, so `Tests/checks/unlock-policy` can check every rule and word.
enum UnlockPolicy {
    /// The longest password kept (characters). macOS takes far longer ones; a field this size is a typo.
    static let maxLength = 256

    /// How long after typing a Mac still locked is asked about again: a wrong password, or a field that
    /// did not take the keys, shows the chip again with "Try again" rather than typing at once.
    static let retryAfter: TimeInterval = 5

    /// What this device has done at the lock screen. Uptime stamps, which a sleep does not skip.
    enum Phase: Equatable {
        case idle
        case typed(at: TimeInterval)
    }

    enum Offer: Equatable {
        case unlock
        case tryAgain
    }

    /// Whether the chip shows, and with which words. Only this session's own locked screen (the Mac
    /// streams its lock screen; off console nothing typed reaches it), only a session the Mac says is
    /// paired (`sessionPaired`: it takes keys at a locked screen from no other, and a host from before it
    /// says nothing), only with a password kept for this Mac. After a typing, not again for `retryAfter`.
    static func offer(screenLocked: Bool, sessionPaired: Bool?, saved: Bool, phase: Phase, now: TimeInterval) -> Offer? {
        guard screenLocked, sessionPaired == true, saved else { return nil }
        switch phase {
        case .idle: return .unlock
        case .typed(let at): return now - at >= retryAfter ? .tryAgain : nil
        }
    }

    /// Whether the password may be typed now, asked again once the check has passed (it can take a while,
    /// and the Mac may have unlocked meanwhile: the keys would land in whatever has the focus).
    static func mayType(screenLocked: Bool, sessionPaired: Bool?) -> Bool {
        screenLocked && sessionPaired == true
    }

    /// The phase after the Mac's screen reads unlocked (or off console): a new lock starts afresh.
    static func phaseAfterUnlock(_ phase: Phase, screenLocked: Bool) -> Phase {
        screenLocked ? phase : .idle
    }

    /// A password worth keeping: not empty, `maxLength` characters at most, no control character (a Return
    /// or a Tab typed into it would end or leave the field before the end; the Return is sent by itself).
    static func isValid(_ password: String) -> Bool {
        guard !password.isEmpty, password.count <= maxLength else { return false }
        return !password.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// One piece of what is sent, in order.
    enum Step: Equatable {
        case text(String)
        case key(hidUsage: UInt16, down: Bool)
    }

    /// HID usage of the Return key (keyboard page, 0x28).
    static let returnUsage: UInt16 = 40

    /// What goes to the Mac: the password as text, then Return down and up. Nothing for a password that
    /// is not valid.
    static func steps(for password: String) -> [Step] {
        guard isValid(password) else { return [] }
        return [.text(password), .key(hidUsage: returnUsage, down: true), .key(hidUsage: returnUsage, down: false)]
    }

    /// The check this device offers, for the words.
    enum Method: Equatable {
        case faceID, touchID, opticID, passcode

        var name: String {
            switch self {
            case .faceID: return "Face ID"
            case .touchID: return "Touch ID"
            case .opticID: return "Optic ID"
            case .passcode: return "your passcode"
            }
        }
    }

    /// Every word the feature shows.
    enum Copy {
        static func mac(_ name: String) -> String { name.isEmpty ? "the Mac" : name }

        static func rowTitle(mac: String, method: Method) -> String {
            "Unlock \(Copy.mac(mac)) with \(method.name)"
        }
        static let rowOn = "On"
        static let rowOff = "Off"

        static func chipTitle(offer: Offer, method: Method) -> String {
            offer == .tryAgain ? "Still locked" : "Unlock with \(method.name)"
        }
        static func chipSubtitle(offer: Offer, mac: String) -> String {
            offer == .tryAgain ? "Try again?" : "Types \(Copy.mac(mac))’s password."
        }
        static let chipButton = "Unlock"
        static let chipButtonAgain = "Try Again"
        static let dismiss = "Dismiss"

        /// The system prompt's reason line.
        static func reason(mac: String) -> String { "Unlock \(Copy.mac(mac))" }

        static func spoken(offer: Offer, mac: String, method: Method) -> String {
            switch offer {
            case .unlock: return "\(Copy.mac(mac)) is locked. Unlock it with \(method.name)."
            case .tryAgain: return "\(Copy.mac(mac)) is still locked. Try again with \(method.name)."
            }
        }

        static func footnote(mac: String, method: Method) -> String {
            let m = Copy.mac(mac)
            return "Keeps \(m)’s password in this device’s Keychain, protected by \(method.name), and types it on \(m)’s lock screen when you tap Unlock. It is never sent any other way. Anyone who can pass \(method.name) here can unlock \(m)."
        }

        static let fieldTitle = "Mac Password"
        static func alertTitle(mac: String) -> String { "\(Copy.mac(mac))’s Password" }
        static let alertMessage = "It is kept in this device’s Keychain and typed on the lock screen after you pass the check."
        static let save = "Save"
        static let cancel = "Cancel"
        static let remove = "Remove"

        static let notValid = "That password can’t be kept: it is empty, too long, or has a line break in it."
        static let couldNotSave = "This device couldn’t keep the password (the Keychain didn’t take it)."
        static let canceled = "Not unlocked."
        static let gone = "The kept password is gone. Add it again in Settings."
    }
}
