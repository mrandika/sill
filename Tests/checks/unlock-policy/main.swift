// UnlockPolicy (iOSClient/UnlockPolicy.swift) on its own (docs/unlock-biometric-plan.md):
//   - The offer: only this session's own locked screen, only a session the Mac says is paired (nil from a
//     host from before it counts as not), only with a password kept; after a typing, not again for
//     `retryAfter`, then "try again"; every combination of the five inputs against an oracle.
//   - mayType: asked again after the check, true only for a locked screen and a paired session.
//   - phaseAfterUnlock: an unlocked screen forgets the typing, a locked one keeps it.
//   - What may be kept: not empty, at most 256 characters (counted as characters, not bytes), no control
//     character; what is typed: the text, then Return down and up, nothing for an invalid password.
//   - Every word, and the method names.
//   swiftc -O iOSClient/UnlockPolicy.swift Tests/checks/unlock-policy/main.swift -o .build/checks/unlock-policy/check && .build/checks/unlock-policy/check
import Foundation

typealias U = UnlockPolicy
var checks = 0
var failures = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !ok { failures += 1; print("FAIL (line \(line)): \(what())") }
}

// Constants.
check(U.maxLength == 256, "max length")
check(U.retryAfter == 5, "retry after 5 s")
check(U.returnUsage == 40, "Return is HID usage 40")

// The offer, over every combination against an oracle.
let phases: [U.Phase] = [.idle, .typed(at: 100)]
let nows: [TimeInterval] = [100, 102, 104.999, 105, 105.001, 500]
for locked in [false, true] {
    for paired in [nil, false, true] as [Bool?] {
        for saved in [false, true] {
            for phase in phases {
                for now in nows {
                    let got = U.offer(screenLocked: locked, sessionPaired: paired, saved: saved, phase: phase, now: now)
                    var want: U.Offer?
                    if locked, paired == true, saved {
                        switch phase {
                        case .idle: want = .unlock
                        case .typed(let at): want = now - at >= 5 ? .tryAgain : nil
                        }
                    }
                    check(got == want, "offer locked \(locked) paired \(String(describing: paired)) saved \(saved) \(phase) now \(now): \(String(describing: got)) wanted \(String(describing: want))")
                }
            }
        }
    }
}
check(U.offer(screenLocked: true, sessionPaired: true, saved: true, phase: .typed(at: 100), now: 104.9) == nil, "not again within 5 s")
check(U.offer(screenLocked: true, sessionPaired: true, saved: true, phase: .typed(at: 100), now: 105) == .tryAgain, "again at exactly 5 s")
check(U.offer(screenLocked: true, sessionPaired: nil, saved: true, phase: .idle, now: 0) == nil, "a host from before says nothing: no chip")

// mayType.
for locked in [false, true] {
    for paired in [nil, false, true] as [Bool?] {
        check(U.mayType(screenLocked: locked, sessionPaired: paired) == (locked && paired == true), "mayType \(locked) \(String(describing: paired))")
    }
}

// The phase after the screen's reading.
check(U.phaseAfterUnlock(.typed(at: 5), screenLocked: false) == .idle, "unlocked forgets the typing")
check(U.phaseAfterUnlock(.typed(at: 5), screenLocked: true) == .typed(at: 5), "locked keeps it")
check(U.phaseAfterUnlock(.idle, screenLocked: true) == .idle, "idle stays idle")

// What may be kept.
check(!U.isValid(""), "empty")
check(U.isValid("a"), "one character")
check(U.isValid(String(repeating: "x", count: 256)), "256 characters")
check(!U.isValid(String(repeating: "x", count: 257)), "257 characters")
check(U.isValid(String(repeating: "é", count: 256)), "256 two-byte characters (counted as characters)")
check(U.isValid(String(repeating: "👩‍👩‍👧", count: 256)), "256 emoji clusters")
check(!U.isValid(String(repeating: "👩‍👩‍👧", count: 257)), "257 emoji clusters")
check(U.isValid("pass word"), "a space")
check(U.isValid("päss wörd ✓ 密码"), "unicode")
check(!U.isValid("abc\n"), "newline")
check(!U.isValid("abc\r"), "carriage return")
check(!U.isValid("a\tb"), "tab")
check(!U.isValid("a\u{7F}b"), "delete")
check(!U.isValid("\u{0}"), "nul")
check(U.isValid("\u{20}x"), "0x20 is allowed")

// What is typed.
check(U.steps(for: "") == [], "nothing for an empty password")
check(U.steps(for: "a\nb") == [], "nothing for a line break")
check(U.steps(for: "hunter2") == [.text("hunter2"), .key(hidUsage: 40, down: true), .key(hidUsage: 40, down: false)], "text, Return down, Return up")
check(U.steps(for: String(repeating: "x", count: 257)) == [], "nothing for too long")

// The methods and the words.
check(U.Method.faceID.name == "Face ID", "Face ID")
check(U.Method.touchID.name == "Touch ID", "Touch ID")
check(U.Method.opticID.name == "Optic ID", "Optic ID")
check(U.Method.passcode.name == "your passcode", "passcode")
check(U.Copy.mac("") == "the Mac" && U.Copy.mac("Studio") == "Studio", "the Mac's name")
check(U.Copy.rowTitle(mac: "Studio", method: .faceID) == "Unlock Studio with Face ID", "row title")
check(U.Copy.rowTitle(mac: "", method: .passcode) == "Unlock the Mac with your passcode", "row title, no name, passcode")
check(U.Copy.chipTitle(offer: .unlock, method: .touchID) == "Unlock with Touch ID", "chip title")
check(U.Copy.chipTitle(offer: .tryAgain, method: .touchID) == "Still locked", "chip title again")
check(U.Copy.chipSubtitle(offer: .unlock, mac: "Studio") == "Types Studio’s password.", "chip subtitle")
check(U.Copy.chipSubtitle(offer: .tryAgain, mac: "Studio") == "Try again?", "chip subtitle again")
check(U.Copy.chipButton == "Unlock" && U.Copy.chipButtonAgain == "Try Again", "buttons")
check(U.Copy.reason(mac: "Studio") == "Unlock Studio", "reason")
check(U.Copy.spoken(offer: .unlock, mac: "Studio", method: .faceID) == "Studio is locked. Unlock it with Face ID.", "spoken")
check(U.Copy.spoken(offer: .tryAgain, mac: "", method: .faceID) == "the Mac is still locked. Try again with Face ID.", "spoken again")
let foot = U.Copy.footnote(mac: "Studio", method: .faceID)
check(foot.contains("Keychain") && foot.contains("Face ID") && foot.contains("Anyone who can pass Face ID here can unlock Studio."), "footnote names the risk: \(foot)")
check(U.Copy.alertTitle(mac: "Studio") == "Studio’s Password", "alert title")

print("unlock-policy: \(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
