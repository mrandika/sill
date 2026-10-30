import Foundation
import AppKit
import StreamProtocol

/// Streams the Mac's current cursor shape to the clients, so the pointer they draw themselves
/// turns into an I-beam over text, a hand over a link, a resize arrow at an edge, exactly as on
/// the Mac. `NSCursor.currentSystem` is the cursor the window server is showing, whichever app
/// owns it. Polled at 20 Hz only while a source is streaming.
///
/// The poll runs on a queue of its own, never the main thread: `currentSystem` asks the window
/// server for the registered cursor images (SkyLight's SLSCopyRegisteredCursorImages), and while the
/// pointer moves that answer takes tens to hundreds of milliseconds. On the main thread it held up
/// every device's pointer input behind it (a sample of Sill.app while a device moved the pointer:
/// 79 % of the main thread in this call, `in.hop>100ms` in the `[1s]` lines). Only a changed shape
/// comes back to the main thread.
///
/// Cost matters here too: the poll runs beside the pipeline. The first version
/// fingerprinted a TIFF of every representation (the arrow's is 583 KB across four sizes up to
/// 280×400) at ~1.4 ms per poll, about as much CPU as the whole streaming pipeline. Now the
/// fingerprint is the hotspot, the point size and the pixels of the smallest bitmap (a few KB);
/// the PNG is only made when the shape actually changes, from the representation nearest 2×.
@MainActor
final class CursorShapeWatcher {
    /// A new shape, already encoded. Main thread.
    var onChange: ((Data) -> Void)?
    /// The last blob sent, for a client that just connected.
    private(set) var current: Data?

    var running = false {
        didSet {
            guard running != oldValue else { return }
            if running { start() } else { stop() }
        }
    }

    /// The poll's own queue: `timer`'s handler and everything `poll` touches run here.
    private let queue = DispatchQueue(label: "sill.cursor", qos: .utility)
    private var timer: DispatchSourceTimer?
    // `queue` only.
    nonisolated(unsafe) private var lastHash: Int?
    nonisolated(unsafe) private var sent = 0
    /// Main thread: the newest shape handed over, so a late hop never puts an older one back.
    private var applied = 0

    private func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(10))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    private func stop() {
        timer?.cancel(); timer = nil
        queue.async { [weak self] in self?.lastHash = nil }
    }

    /// `queue` only: where the pointer was and when `currentSystem` was last asked.
    nonisolated(unsafe) private var lastLocation: CGPoint?
    nonisolated(unsafe) private var lastAsked = -Double.infinity

    /// On `queue`. The timer ticks every 50 ms, but a shape only changes under a moving pointer or
    /// when an app sets one, and each question costs the window server a copy of its cursor images
    /// (1.75 ms at the median, 340 ms at the worst on this Mac): a moving pointer is asked 10 times a
    /// second, a still one 4.
    nonisolated private func poll() {
        let here = CGEvent(source: nil)?.location
        let moving = here != lastLocation
        lastLocation = here
        let now = CACurrentMediaTime()
        guard now - lastAsked >= (moving ? 0.09 : 0.24) else { return }
        lastAsked = now
        guard let cursor = NSCursor.currentSystem else { return }
        let image = cursor.image
        let hash = Self.fingerprint(of: image, hotspot: cursor.hotSpot)
        guard hash != lastHash else { return }
        // The representation nearest 2× the point size: what a Retina device draws, without the
        // 5× and 10× assets some system cursors carry.
        let wanted = image.size.width * 2
        guard let rep = image.representations.min(by: { abs(CGFloat($0.pixelsWide) - wanted) < abs(CGFloat($1.pixelsWide) - wanted) }),
              let png = Self.png(of: rep) else { return }
        lastHash = hash   // only once the PNG exists, so a failed encode is retried next poll
        let blob = CursorShapeBlob.encode(hotspot: cursor.hotSpot, size: image.size, png: png)
        sent += 1
        let n = sent
        Stats.shared.bump("cursor.shape")
        Task { @MainActor [weak self] in
            guard let self, n > self.applied else { return }
            self.applied = n
            self.current = blob
            self.onChange?(blob)
        }
    }

    nonisolated private static func fingerprint(of image: NSImage, hotspot: NSPoint) -> Int {
        var hasher = Hasher()
        hasher.combine(hotspot.x); hasher.combine(hotspot.y)
        hasher.combine(image.size.width); hasher.combine(image.size.height)
        let bitmaps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        if let small = bitmaps.min(by: { $0.pixelsWide < $1.pixelsWide }), let bytes = small.bitmapData {
            hasher.combine(bytes: UnsafeRawBufferPointer(start: bytes, count: small.bytesPerRow * small.pixelsHigh))
        } else if let tiff = image.tiffRepresentation {
            hasher.combine(tiff)   // no bitmap representation: fall back to the expensive way
        }
        return hasher.finalize()
    }

    nonisolated private static func png(of rep: NSImageRep) -> Data? {
        if let bitmap = rep as? NSBitmapImageRep { return bitmap.representation(using: .png, properties: [:]) }
        guard let cg = rep.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}
