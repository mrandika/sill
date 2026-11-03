# Unlocking a locked Mac with Face ID or Touch ID (2026-11-03)

Noah's wish: a small pop-up in the stream's corner that unlocks the Mac with the device's Face ID or Touch ID
instead of typing its password. Scope taken (his yes, 2026-11-03): the lock screen only; no manual "type password"
button for other fields.

## What it does
- Settings › This iPad (or iPhone), after the clipboard group: **Unlock ‹Mac› with Face ID** (On/Off). Tap, type the
  Mac's password once into the alert's secure field, Save (or Remove).
- It is kept in this device's Keychain (`UnlockPasswordStore`: a generic password, service `me.saffer.sill.unlock`,
  account the saved Mac's ID, `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`, access control `.userPresence`,
  so Face ID/Touch ID with the passcode as the fallback; never synced). Only a saved Mac (a session with a Mac ID)
  whose session the Mac says is paired (`sessionPaired`) shows the row.
- While the Mac says its own screen is locked (`lockWhy == .screenLocked`) and a password is kept, a chip in the
  corner where the clipboard's goes: "Unlock with Face ID — Types ‹Mac›’s password." with Unlock and Dismiss. Unlock
  asks the system for the check, then (asking again that the Mac is still locked and the session paired) sends the
  password as typed text and Return down/up through `sendInput`: the typing a paired session may already do at a
  locked screen. After a typing the chip waits 5 s; a Mac still locked then gets "Still locked — Try again?".
  One try per tap, no automatic retry (macOS counts wrong passwords).
- Never off console (another user): nothing typed reaches the Mac there.
- No wire change, nothing on the Mac. `NSFaceIDUsageDescription` in Info.plist and Info-Debug.plist.

## Files
`iOSClient/UnlockPolicy.swift` (pure: offer, mayType, validity, steps, words; `Tests/checks/unlock-policy`),
`iOSClient/UnlockChip.swift` (the store, `UnlockModel`, `UnlockChip`, `UnlockPasswordRow`), StreamScreen (the chip's
placement and the model), HostSettingsPanel (the row and its footnote). pbxproj AE01/AE02, FE01/FE02.

## Risks and open
1. **Unverified: macOS's password field may refuse posted keys** (locked-mac-plan, open question 2, never tried).
   If it does, the chip types and nothing happens; it offers "Try again" after 5 s. Test by typing the password by
   hand from the iPad first.
2. The Mac's lock is as strong as the device's check: anyone who passes Face ID (or the passcode fallback) on that
   device unlocks the Mac. The footnote says so. Alternative: biometry only (`.biometryCurrentSet`), no passcode
   fallback, invalidated when a face/finger is added.
3. Simulator: the Keychain item with a user-presence ACL needs a passcode set and enrolled Face ID (Features ›
   Face ID › Enrolled) to be saved.
4. Public words (support, README, What's New) wait for Noah's device test (decision D3 of the 0.6.0 release).

## Untested, for Noah
On the iPhone/iPad with a Debug build against Sill.app: save the password in Settings; lock the Mac (⌃⌘Q); the chip
shows in the corner; Unlock → Face ID → the Mac unlocks ("Unlocking…" then the window back); a wrong password shows
"Still locked" after 5 s; Remove clears the row; Face ID cancelled types nothing; VoiceOver reads the chip; the chip
is hidden under the Settings panel, the drawer and the tour; an unpaired device (Require pairing off) sees no row and
no chip; another user at the login screen: no chip.
