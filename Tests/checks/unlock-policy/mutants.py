"""Mutants of UnlockPolicy.swift (iOSClient): each changes it in one place and must make the check (main.swift)
fail. usage: mutants.py"""
import os, subprocess, sys
SP = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(SP, "..", "..", ".."))   # the repository
OUT = os.path.join(ROOT, ".build", "checks", "unlock-policy")
os.makedirs(OUT, exist_ok=True)
SRC = os.path.join(ROOT, "iOSClient/UnlockPolicy.swift")
orig = open(SRC).read()
MUTANTS = [
    ("U1 max length 255", "static let maxLength = 256", "static let maxLength = 255"),
    ("U2 max length 257", "static let maxLength = 256", "static let maxLength = 257"),
    ("U3 retry after 3 s", "static let retryAfter: TimeInterval = 5", "static let retryAfter: TimeInterval = 3"),
    ("U4 retry after 10 s", "static let retryAfter: TimeInterval = 5", "static let retryAfter: TimeInterval = 10"),
    ("U5 offered off this session's own locked screen", "guard screenLocked, sessionPaired == true, saved else { return nil }", "guard sessionPaired == true, saved else { return nil }"),
    ("U6 offered to an unpaired session", "guard screenLocked, sessionPaired == true, saved else { return nil }", "guard screenLocked, sessionPaired != false, saved else { return nil }"),
    ("U7 offered with no password kept", "guard screenLocked, sessionPaired == true, saved else { return nil }", "guard screenLocked, sessionPaired == true else { return nil }"),
    ("U8 again strictly after the wait", "now - at >= retryAfter ? .tryAgain : nil", "now - at > retryAfter ? .tryAgain : nil"),
    ("U9 never again after typing", "now - at >= retryAfter ? .tryAgain : nil", "nil"),
    ("U10 the wait forgotten", "now - at >= retryAfter ? .tryAgain : nil", ".tryAgain"),
    ("U11 mayType without the pairing", "screenLocked && sessionPaired == true", "screenLocked && sessionPaired != false"),
    ("U12 mayType without the lock", "screenLocked && sessionPaired == true", "sessionPaired == true"),
    ("U13 the typing kept after an unlock", "screenLocked ? phase : .idle", "phase"),
    ("U14 the typing forgotten while locked", "screenLocked ? phase : .idle", ".idle"),
    ("U15 empty password valid", "guard !password.isEmpty, password.count <= maxLength else { return false }", "guard password.count <= maxLength else { return false }"),
    ("U16 length in bytes", "password.count <= maxLength", "password.utf8.count <= maxLength"),
    ("U17 no length limit", "guard !password.isEmpty, password.count <= maxLength else { return false }", "guard !password.isEmpty else { return false }"),
    ("U18 control characters allowed", "$0.value < 0x20 || $0.value == 0x7F", "$0.value > 0x10FFFF"),
    ("U19 delete allowed", "$0.value < 0x20 || $0.value == 0x7F", "$0.value < 0x20"),
    ("U20 a space refused", "$0.value < 0x20 || $0.value == 0x7F", "$0.value <= 0x20 || $0.value == 0x7F"),
    ("U21 Return not sent", ".key(hidUsage: returnUsage, down: true), .key(hidUsage: returnUsage, down: false)]", ".key(hidUsage: returnUsage, down: false)]"),
    ("U22 Return's up first", "[.text(password), .key(hidUsage: returnUsage, down: true), .key(hidUsage: returnUsage, down: false)]", "[.text(password), .key(hidUsage: returnUsage, down: false), .key(hidUsage: returnUsage, down: true)]"),
    ("U23 the wrong key", "static let returnUsage: UInt16 = 40", "static let returnUsage: UInt16 = 41"),
    ("U24 typed even when invalid", "guard isValid(password) else { return [] }", ""),
    ("U25 Return before the text", "[.text(password), .key(hidUsage: returnUsage, down: true), .key(hidUsage: returnUsage, down: false)]", "[.key(hidUsage: returnUsage, down: true), .key(hidUsage: returnUsage, down: false), .text(password)]"),
    ("W1 Touch ID's name", "case .touchID: return \"Touch ID\"", "case .touchID: return \"Face ID\""),
    ("W2 the footnote without the risk", " Anyone who can pass \\(method.name) here can unlock \\(m).", ""),
    ("W3 the footnote without the Keychain", "in this device’s Keychain, protected by", "protected by"),
    ("W4 no name falls to empty", "name.isEmpty ? \"the Mac\" : name", "name"),
    ("W5 the chip's retry title", "offer == .tryAgain ? \"Still locked\" : \"Unlock with \\(method.name)\"", "\"Unlock with \\(method.name)\""),
    ("W6 the row title in title case", "\"Unlock \\(Copy.mac(mac)) with \\(method.name)\"", "\"Unlock \\(Copy.mac(mac)) With \\(method.name)\""),
]
caught = 0
for name, old, new in MUTANTS:
    if orig.count(old) != 1:
        print(f"{name}: NOT APPLIED (pattern found {orig.count(old)} times)"); continue
    src = os.path.join(OUT, "UnlockPolicy.swift")
    open(src, "w").write(orig.replace(old, new, 1))
    exe = os.path.join(OUT, "mutant")
    if os.path.exists(exe): os.remove(exe)
    c = subprocess.run(["swiftc", "-O", src, os.path.join(SP, "main.swift"), "-o", exe], capture_output=True, text=True)
    if c.returncode != 0:
        print(f"{name}: did not compile: {c.stderr.strip().splitlines()[0] if c.stderr.strip() else ''}"); continue
    r = subprocess.run([exe], capture_output=True, text=True, timeout=600)
    failed = [l for l in r.stdout.splitlines() if l.startswith("FAIL")]
    if r.returncode != 0:
        caught += 1
        print(f"{name}: caught ({len(failed)} FAIL lines; first: {failed[0][:150] if failed else 'exit ' + str(r.returncode)})")
    else:
        print(f"{name}: SURVIVED")
print(f"{caught} of {len(MUTANTS)} mutants caught")
sys.exit(0 if caught == len(MUTANTS) else 1)
