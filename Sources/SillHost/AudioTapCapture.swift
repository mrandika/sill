import Foundation
import AppKit
import CoreAudio
import AudioToolbox

/// What a tap takes: every app's sound but Sill's, or one app's (no availability limit, so the
/// coordinator can name it on any macOS).
enum AudioTapScope {
    case everyApp
    case app(pid: pid_t, name: String)
}

/// The Mac's sound from a Core Audio process tap (macOS 14.2 and later), for Settings › General's "Play
/// sound on the device only" (docs/audio-plan.md §14, "A quiet Mac"). Where AudioCapture copies the
/// sound with ScreenCaptureKit and the Mac keeps playing it, the tap is created with
/// `CATapMutedWhenTapped`: while it is being read, what it taps is not sent to the Mac's speakers, so a
/// device beside the Mac is the only one that plays it.
///
/// The mute lives exactly as long as the tap: `stop()`, the process ending or dying, the output device
/// changing (this class tears the tap down before it says so) all give the Mac its sound back.
///
/// What is tapped: every process but Sill's for the Desktop, or the streamed app's (its processes: the
/// pid itself, and any audio process whose bundle ID is the app's or starts with it plus a dot, which
/// is how Chrome's, Electron's and Safari's helpers play their sound). An app that has not played
/// anything has no audio process yet: the source then waits, with the Mac playing as usual, and taps it
/// when one appears (the process list is watched); a helper that comes later is added the same way
/// (the tap is made again, a gap of a fraction of a second). Needs "System Audio Recording" (macOS asks
/// the first time; `NSAudioCaptureUsageDescription`). Until it is granted the tap delivers silence and
/// mutes nothing; one line says so after 15 s of nothing but zeros.
///
/// The tap's own format becomes interleaved stereo Float32 for the pipeline (`PCMLayout`, as
/// AudioCapture does), stamped with the I/O cycle's host time. Not run by any test here: the tests
/// never tap a person's sound. The device tests are Noah's.
@available(macOS 14.2, *)
final class AudioTapCapture: AudioSource, @unchecked Sendable {
    typealias Scope = AudioTapScope

    var onPCM: ((PCMChunk) -> Void)?
    var onStopped: ((String) -> Void)?

    struct Failure: AudioSourceFailure {
        let description: String
    }

    private let scope: Scope
    private let queue: DispatchQueue
    /// Everything below, except what the I/O block reads on `queue` (`layout`, `rate`, `tally`).
    private let lock = NSLock()
    /// Building and tearing down run here, one at a time and never on the main actor or `queue`: the
    /// first tap makes macOS ask for System Audio Recording, and the call waits for the answer.
    private let work = DispatchQueue(label: "sill.audio.tap")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapped: Set<AudioObjectID> = []
    private var stopped = false

    /// The tap's format, set by `build` and read by the I/O block, under `lock`.
    private var format: (layout: PCMLayout, asbd: AudioStreamBasicDescription)?

    // On `queue`.
    private var firstLogged = false
    private var sawSound = false
    private var silentSince: Double?
    private var silenceSaid = false

    init(scope: Scope, queue: DispatchQueue) {
        self.scope = scope
        self.queue = queue
    }

    // MARK: Start and stop

    func start() async throws {
        lock.withLock { stopped = false }
        listenForProcesses()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            work.async {
                do {
                    switch self.scope {
                    case .everyApp:
                        try self.build()
                    case .app(_, let name):
                        if !self.candidates().isEmpty {
                            try self.build()
                        } else {
                            print("Audio: \(name) has no audio process yet (nothing played); the Mac plays as usual until it does.")
                        }
                    }
                    c.resume()
                } catch {
                    self.stopListening()
                    c.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        lock.withLock { stopped = true }
        stopListening()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            work.async { self.teardown(); c.resume() }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in queue.async { c.resume() } }
    }

    /// The tap, the aggregate device that reads it, and the I/O block. Throws with the system's words.
    private func build() throws {
        let processes = candidates()
        let description: CATapDescription
        switch scope {
        case .everyApp:
            var excluded: [AudioObjectID] = []
            if let own = Self.processObject(pid: getpid()) { excluded.append(own) }
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        case .app:
            guard !processes.isEmpty else { return }
            description = CATapDescription(stereoMixdownOfProcesses: Array(processes))
        }
        description.name = "Sill sound"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw Failure(description: "the system refused the sound tap (\(Self.code(status)))") }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            throw Failure(description: "the sound tap's format could not be read (\(Self.code(status)))")
        }
        guard let layout = PCMLayout.from(formatID: format.mFormatID, flags: format.mFormatFlags,
                                          bitsPerChannel: format.mBitsPerChannel, channels: format.mChannelsPerFrame) else {
            AudioHardwareDestroyProcessTap(tap)
            throw Failure(description: "the sound tap is in a layout Sill does not read (format \(format.mFormatID), \(format.mBitsPerChannel) bits, \(format.mChannelsPerFrame) channels)")
        }

        var aggregate = AudioObjectID(kAudioObjectUnknown)
        var devices: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Sill sound",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        if let output = Self.defaultOutputUID() {
            devices[kAudioAggregateDeviceMainSubDeviceKey] = output
            devices[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: output]]
        }
        status = AudioHardwareCreateAggregateDevice(devices as CFDictionary, &aggregate)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            throw Failure(description: "the sound tap's device could not be made (\(Self.code(status)))")
        }

        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) { [weak self] _, input, inputTime, _, _ in
            self?.deliver(input, time: inputTime)
        }
        guard status == noErr, let proc else {
            AudioHardwareDestroyAggregateDevice(aggregate)
            AudioHardwareDestroyProcessTap(tap)
            throw Failure(description: "the sound tap's reader could not be made (\(Self.code(status)))")
        }
        lock.withLock { self.format = (layout, format) }
        status = AudioDeviceStart(aggregate, proc)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(aggregate, proc)
            AudioHardwareDestroyAggregateDevice(aggregate)
            AudioHardwareDestroyProcessTap(tap)
            throw Failure(description: "the sound tap did not start (\(Self.code(status)))")
        }
        let wasStopped = lock.withLock { () -> Bool in
            tapID = tap
            aggregateID = aggregate
            procID = proc
            tapped = processes
            return stopped
        }
        // Stopped while it was being made (the permission prompt took its time): given back at once.
        if wasStopped { teardown() }
    }

    /// Stops reading and destroys the tap (the Mac plays again), the device and the block. Idempotent.
    private func teardown() {
        let (tap, aggregate, proc) = lock.withLock { () -> (AudioObjectID, AudioObjectID, AudioDeviceIOProcID?) in
            let r = (tapID, aggregateID, procID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            procID = nil
            tapped = []
            return r
        }
        if aggregate != kAudioObjectUnknown, let proc {
            AudioDeviceStop(aggregate, proc)
            AudioDeviceDestroyIOProcID(aggregate, proc)
        }
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
    }

    // MARK: Buffers (on `queue`)

    private func deliver(_ input: UnsafePointer<AudioBufferList>, time: UnsafePointer<AudioTimeStamp>) {
        guard let (layout, asbd) = lock.withLock({ format }) else { return }
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = list.first, first.mData != nil, first.mDataByteSize > 0 else { return }
        let bytes = layout.sample == .int16 ? 2 : 4
        let frames = layout.interleaved ? Int(first.mDataByteSize) / (bytes * layout.channels) : Int(first.mDataByteSize) / bytes
        guard frames > 0 else { return }
        let buffers = list.map { UnsafeRawBufferPointer(start: $0.mData, count: $0.mData == nil ? 0 : Int($0.mDataByteSize)) }
        guard let samples = layout.stereo(frames: frames, buffers: buffers) else { return }
        let now = HostClock.now()
        var at = now - Double(frames) / asbd.mSampleRate
        if time.pointee.mFlags.contains(.hostTimeValid) {
            let t = HostClock.seconds(ticks: time.pointee.mHostTime)
            if abs(now - t) < 1 { at = t }
        }
        if !firstLogged {
            firstLogged = true
            print("Audio: tap's first buffer \(frames) frames, \(Int(asbd.mSampleRate)) Hz, \(asbd.mChannelsPerFrame) channels, \(layout); the Mac is silent for what it taps.")
        }
        if !sawSound {
            if samples.contains(where: { $0 != 0 }) {
                sawSound = true
            } else {
                let since = silentSince ?? now
                silentSince = since
                if !silenceSaid, now - since >= 15 {
                    silenceSaid = true
                    print("Audio: the tap has delivered silence for 15 s. If something is playing, Sill may not have System Audio Recording yet (System Settings › Privacy & Security).")
                }
            }
        }
        onPCM?(PCMChunk(samples: samples, channels: 2, sampleRate: asbd.mSampleRate, hostTime: at))
    }

    // MARK: Which processes, and when they change

    /// The audio processes to tap for an app: its pid's, and every process with its bundle ID or one
    /// under it. Empty for the Desktop.
    private func candidates() -> Set<AudioObjectID> {
        guard case .app(let pid, _) = scope else { return [] }
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        var found: Set<AudioObjectID> = []
        if let own = Self.processObject(pid: pid) { found.insert(own) }
        guard let bundle else { return found }
        for object in Self.processObjects() {
            if let id = Self.bundleID(of: object), id == bundle || id.hasPrefix(bundle + ".") { found.insert(object) }
        }
        return found
    }

    private var listBlock: AudioObjectPropertyListenerBlock?

    /// The process list changed: an app's first audio process taps it, a new helper of a tapped app
    /// is added by making the tap again. Never for the Desktop (a global tap takes every process).
    private func listenForProcesses() {
        if case .app = scope {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.processesChanged() }
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block) == noErr {
                lock.withLock { listBlock = block }
            }
        }
        // The output device changing ends the tap, whatever it taps: the aggregate was made with the
        // output of the time.
        var out = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let outBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.outputChanged() }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &out, queue, outBlock) == noErr {
            lock.withLock { outputBlock = outBlock }
        }
    }

    private var outputBlock: AudioObjectPropertyListenerBlock?

    private func stopListening() {
        let (list, out) = lock.withLock { () -> (AudioObjectPropertyListenerBlock?, AudioObjectPropertyListenerBlock?) in
            let r = (listBlock, outputBlock)
            listBlock = nil
            outputBlock = nil
            return r
        }
        if let block = list {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        }
        if let block = out {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        }
    }

    private func processesChanged() {
        work.async {
            let (isStopped, current) = self.lock.withLock { (self.stopped, self.tapped) }
            guard !isStopped else { return }
            let wanted = self.candidates()
            guard !wanted.isEmpty, !wanted.isSubset(of: current) else { return }
            self.teardown()
            do {
                try self.build()
            } catch {
                self.finish("\(error)")
            }
        }
    }

    private func outputChanged() {
        work.async {
            let live = self.lock.withLock { !self.stopped && self.tapID != kAudioObjectUnknown }
            guard live else { return }
            self.finish("the Mac's sound output changed, so the Mac plays its own sound again")
        }
    }

    /// The tap ends by itself (on `work`): the Mac's sound is given back first, then the pipeline is told.
    private func finish(_ why: String) {
        lock.withLock { stopped = true }
        stopListening()
        teardown()
        onStopped?(why)
    }

    // MARK: Core Audio, plainly

    private static func code(_ status: OSStatus) -> String {
        let n = UInt32(bitPattern: status)
        let chars = [24, 16, 8, 0].map { UInt8((n >> UInt32($0)) & 0xFF) }
        if chars.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) { return "'\(String(decoding: chars, as: UTF8.self))'" }
        return "OSStatus \(status)"
    }

    static func processObject(pid: pid_t) -> AudioObjectID? {
        var pidIn = pid
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pidIn, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    static func bundleID(of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        let s = value.takeRetainedValue() as String
        return s.isEmpty ? nil : s
    }

    static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}
