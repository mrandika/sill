import SwiftUI
import Security
import LocalAuthentication
import StreamProtocol

/// The Mac's password, kept in this device's Keychain per saved Mac behind Face ID, Touch ID or the
/// passcode (`userPresence`), and read only after the person passes the check
/// (docs/unlock-biometric-plan.md). This device only; the item never syncs or leaves it.
enum UnlockPasswordStore {
    static let service = "me.saffer.sill.unlock"

    enum Failure: Error, Equatable {
        case notValid
        case keychain(OSStatus)
        case canceled
        case missing
    }

    /// The check this device offers: Face ID, Touch ID or Optic ID, else its passcode.
    static func method() -> UnlockPolicy.Method {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default: return .passcode
        }
    }

    private static func base(_ macID: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: macID]
    }

    /// Whether a password is kept for this Mac. Attributes only, with no interaction allowed: never a prompt.
    static func isSaved(macID: String) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = base(macID)
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext] = context
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    static func save(_ password: String, macID: String) throws {
        guard UnlockPolicy.isValid(password) else { throw Failure.notValid }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                           .userPresence, &error) else {
            throw Failure.keychain(errSecParam)
        }
        SecItemDelete(base(macID) as CFDictionary)
        var item = base(macID)
        item[kSecAttrAccessControl] = access
        item[kSecValueData] = Data(password.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    static func remove(macID: String) {
        SecItemDelete(base(macID) as CFDictionary)
    }

    /// The password, after the system's check. Off the main thread (the read waits for the person); the
    /// completion runs on the main thread.
    static func read(macID: String, reason: String, completion: @escaping (Result<String, Failure>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let context = LAContext()
            context.localizedReason = reason
            var query = base(macID)
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
            query[kSecUseAuthenticationContext] = context
            var out: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &out)
            let result: Result<String, Failure>
            switch status {
            case errSecSuccess:
                if let data = out as? Data, let text = String(data: data, encoding: .utf8) {
                    result = .success(text)
                } else {
                    result = .failure(.missing)
                }
            case errSecUserCanceled, errSecAuthFailed:
                result = .failure(.canceled)
            case errSecItemNotFound:
                result = .failure(.missing)
            default:
                result = .failure(.keychain(status))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

/// What the unlock chip remembers across the stream screen's life: whether a password is kept for the
/// Mac in front, what was typed when, a note, and a dismissal. One per stream screen.
@MainActor
final class UnlockModel: ObservableObject {
    @Published private(set) var saved = false
    @Published private(set) var phase: UnlockPolicy.Phase = .idle
    @Published private(set) var note: String?
    @Published private(set) var dismissed = false
    /// Bumped when the retry wait ends, so the chip looks again.
    @Published private(set) var tick = 0
    private var busy = false

    func refresh(macID: String?) {
        saved = macID.map { UnlockPasswordStore.isSaved(macID: $0) } ?? false
    }

    /// The Mac's screen reads unlocked (or off console): the next lock starts afresh.
    func screenChanged(locked: Bool) {
        phase = UnlockPolicy.phaseAfterUnlock(phase, screenLocked: locked)
        if !locked { dismissed = false; note = nil }
    }

    func dismiss() { dismissed = true }

    /// The person tapped Unlock: the check, then the password as typing and Return. `stillLocked` is asked
    /// again once the check has passed.
    func unlock(client: StreamClient, macID: String, mac: String) {
        guard !busy else { return }
        busy = true
        note = nil
        UnlockPasswordStore.read(macID: macID, reason: UnlockPolicy.Copy.reason(mac: mac)) { [weak self, weak client] result in
            guard let self else { return }
            self.busy = false
            switch result {
            case .failure(.canceled):
                return
            case .failure(.missing):
                self.saved = false
                self.note = UnlockPolicy.Copy.gone
            case .failure:
                self.note = UnlockPolicy.Copy.couldNotSave
            case .success(let password):
                guard let client,
                      UnlockPolicy.mayType(screenLocked: client.lockWhy == .screenLocked,
                                           sessionPaired: client.settings.host?.sessionPaired) else { return }
                for step in UnlockPolicy.steps(for: password) {
                    switch step {
                    case .text(let text): client.sendInput(.text(text))
                    case .key(let usage, let down): client.sendInput(.key(hidUsage: usage, down: down, modifiers: 0))
                    }
                }
                self.phase = .typed(at: ProcessInfo.processInfo.systemUptime)
                DispatchQueue.main.asyncAfter(deadline: .now() + UnlockPolicy.retryAfter + 0.1) { [weak self] in
                    self?.tick += 1
                }
            }
        }
    }
}

/// The small chip over the stream's corner at a locked Mac: "Unlock with Face ID", with an Unlock button and
/// Dismiss. Placed and hidden by StreamScreen like the clipboard's chip; takes no touch outside itself.
struct UnlockChip: View {
    @ObservedObject var client: StreamClient
    @ObservedObject var model: UnlockModel

    private var macID: String? { client.session?.macID }
    private var screenLocked: Bool { client.lockWhy == .screenLocked }

    private var offer: UnlockPolicy.Offer? {
        _ = model.tick
        guard !model.dismissed else { return nil }
        return UnlockPolicy.offer(screenLocked: screenLocked, sessionPaired: client.settings.host?.sessionPaired,
                                  saved: model.saved, phase: model.phase,
                                  now: ProcessInfo.processInfo.systemUptime)
    }

    var body: some View {
        ZStack {
            if let offer { chip(offer).transition(.opacity) }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .animation(.easeOut(duration: 0.2), value: offer)
        .onChange(of: client.lockWhy, initial: true) { _, why in
            model.screenChanged(locked: why == .screenLocked)
            model.refresh(macID: macID)
        }
    }

    var isShowing: Bool { offer != nil }

    private func chip(_ offer: UnlockPolicy.Offer) -> some View {
        let mac = client.macName
        let method = UnlockPasswordStore.method()
        return HStack(spacing: 10) {
            Image(systemName: method == .touchID ? "touchid" : method == .passcode ? "lock.open.fill" : "faceid")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.muted)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(UnlockPolicy.Copy.chipTitle(offer: offer, method: method))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                Text(model.note ?? UnlockPolicy.Copy.chipSubtitle(offer: offer, mac: mac))
                    .font(.caption)
                    .foregroundStyle(model.note == nil ? Palette.muted : Color.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .layoutPriority(-1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(UnlockPolicy.Copy.spoken(offer: offer, mac: mac, method: method))
            .accessibilityAddTraits(.isStaticText)
            Button(offer == .tryAgain ? UnlockPolicy.Copy.chipButtonAgain : UnlockPolicy.Copy.chipButton) {
                guard let macID else { return }
                model.unlock(client: client, macID: macID, mac: mac)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(Palette.accent)
            .font(.footnote.weight(.semibold))
            Button(action: { model.dismiss() }) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(UnlockPolicy.Copy.dismiss)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Capsule(style: .continuous).fill(Palette.bar))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 8)
        .accessibilityElement(children: .contain)
    }
}

/// Settings › This iPad / This iPhone: "Unlock ‹Mac› with Face ID", On or Off. A tap asks for the password
/// (a secure field in an alert), Save keeps it behind the check, Remove deletes it. Shown by the panel only
/// for a saved Mac (a session with a Mac ID) whose session the Mac says is paired.
struct UnlockPasswordRow: View {
    @ObservedObject var client: StreamClient
    let macID: String
    let mac: String
    @State private var saved = false
    @State private var asking = false
    @State private var password = ""
    @State private var problem: String?
    private let method = UnlockPasswordStore.method()

    var body: some View {
        Button(action: { password = ""; problem = nil; asking = true }) {
            HStack(spacing: 8) {
                Text(UnlockPolicy.Copy.rowTitle(mac: mac, method: method))
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(saved ? UnlockPolicy.Copy.rowOn : UnlockPolicy.Copy.rowOff)
                    .foregroundStyle(Palette.muted)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.muted)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 14)
        .accessibilityValue(saved ? UnlockPolicy.Copy.rowOn : UnlockPolicy.Copy.rowOff)
        .onAppear { saved = UnlockPasswordStore.isSaved(macID: macID) }
        .alert(UnlockPolicy.Copy.alertTitle(mac: mac), isPresented: $asking) {
            SecureField(UnlockPolicy.Copy.fieldTitle, text: $password)
            Button(UnlockPolicy.Copy.save) { save() }
            if saved {
                Button(UnlockPolicy.Copy.remove, role: .destructive) {
                    UnlockPasswordStore.remove(macID: macID)
                    saved = false
                    password = ""
                }
            }
            Button(UnlockPolicy.Copy.cancel, role: .cancel) { password = "" }
        } message: {
            Text(problem ?? UnlockPolicy.Copy.alertMessage)
        }
    }

    private func save() {
        defer { password = "" }
        do {
            try UnlockPasswordStore.save(password, macID: macID)
            saved = true
        } catch UnlockPasswordStore.Failure.notValid {
            problem = UnlockPolicy.Copy.notValid
            asking = true
        } catch {
            problem = UnlockPolicy.Copy.couldNotSave
            asking = true
        }
    }
}
