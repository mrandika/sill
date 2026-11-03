#!/bin/bash
# UnlockPolicy (iOSClient/UnlockPolicy.swift) on its own: when the Face ID / Touch ID unlock chip shows at a
# locked Mac, what may be kept as a password, what is typed, and every word (docs/unlock-biometric-plan.md).
#   Tests/checks/unlock-policy/run.sh             compile and run the check
#   Tests/checks/unlock-policy/run.sh --mutants   one-line mutants of UnlockPolicy.swift; each must fail it
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
if [ "${1:-}" = "--mutants" ]; then run_mutants python3 "$here/mutants.py"; exit; fi
swiftc -O iOSClient/UnlockPolicy.swift "$here/main.swift" -o "$out/check"
"$out/check"
