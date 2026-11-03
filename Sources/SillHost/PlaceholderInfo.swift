import AppKit
import CoreImage
import CoreVideo
import UniformTypeIdentifiers
import StreamProtocol

/// What the placeholder shows while this Mac's display is asleep or its screen is locked and nothing
/// of the Mac can be captured: the Mac's own icon (the model's, as About This Mac draws it), "‹Mac› is
/// locked" and how to wake it. Drawn here, on the host, so a device from before this change shows it
/// too. Another user's console keeps the black frame: the device covers the stream itself then.
enum PlaceholderInfo {
    /// The icon, carried to the placeholder's queue (an immutable image).
    struct IconBox: @unchecked Sendable { let image: CGImage? }

    /// The icon of this Mac's model, as a CGImage. Main thread (NSWorkspace). Nil if nothing is found.
    @MainActor static func modelIcon() -> CGImage? {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        let model = String(cString: buffer)
        var image: NSImage?
        if let id = UTTypeCreatePreferredIdentifierForTag("com.apple.device-model-code" as CFString, model as CFString, nil)?
            .takeRetainedValue() as String?, let type = UTType(id) {
            image = NSWorkspace.shared.icon(for: type)
        }
        image = image ?? NSImage(named: NSImage.computerName)
        var rect = CGRect(x: 0, y: 0, width: 512, height: 512)
        return image?.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// The words at this reading: nil for another user's console. The title is the device's own for a
    /// locked Mac (`LockedMac.title`); an unlocked Mac whose display sleeps (its password asked later) is
    /// "asleep".
    static func words(mac: String, reading: LockPolicy.Reading) -> (title: String, detail: String)? {
        switch reading {
        case .offConsole:
            return nil
        case .screenLocked:
            return (LockedMac.title(mac: mac, shade: .locked(.screenLocked)),
                    "Tap or press any key to wake it, then type its password and press Return.")
        case .unlocked:
            return ((mac.isEmpty ? "The Mac" : mac) + " is asleep", "Tap or press any key to wake it.")
        }
    }

    /// The frame, full-range 4:2:0 like the black one, `width`×`height`: black, the icon above the title
    /// and the line, all centred and sized by the frame's height.
    static func frame(width: Int, height: Int, icon: CGImage?, mac: String, reading: LockPolicy.Reading) -> CVPixelBuffer? {
        guard let words = words(mac: mac, reading: reading), width > 0, height > 0 else { return nil }
        let unit = CGFloat(height) / 700 * 0.8     // 1 at a 700-pixel-tall frame, less a fifth
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }

        let textWidth = min(CGFloat(width) * 0.8, 520 * unit)
        func paragraph(_ text: String, size: CGFloat, weight: NSFont.Weight, white: CGFloat) -> NSAttributedString {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byWordWrapping
            return NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: size * unit, weight: weight),
                .foregroundColor: NSColor(white: white, alpha: 1),
                .paragraphStyle: style,
            ])
        }
        let title = paragraph(words.title, size: 30, weight: .semibold, white: 0.95)
        let detail = paragraph(words.detail, size: 17, weight: .regular, white: 0.6)
        func textHeight(_ s: NSAttributedString) -> CGFloat {
            ceil(s.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                                options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        }
        let iconSide: CGFloat = icon == nil ? 0 : 300 * unit
        let gap1: CGFloat = icon == nil ? 0 : -18 * unit, gap2: CGFloat = 10 * unit
        let titleHeight = textHeight(title), detailHeight = textHeight(detail)
        let total = iconSide + gap1 + titleHeight + gap2 + detailHeight
        // Drawing space has its origin at the bottom: the block is centred, a little above the middle.
        var top = (CGFloat(height) + total) / 2 + 10 * unit
        let centreX = CGFloat(width) / 2
        if let icon {
            top -= iconSide
            context.draw(icon, in: CGRect(x: centreX - iconSide / 2, y: top, width: iconSide, height: iconSide))
            top -= gap1
        }
        top -= titleHeight
        title.draw(with: CGRect(x: centreX - textWidth / 2, y: top, width: textWidth, height: titleHeight),
                   options: [.usesLineFragmentOrigin, .usesFontLeading])
        top -= gap2 + detailHeight
        detail.draw(with: CGRect(x: centreX - textWidth / 2, y: top, width: textWidth, height: detailHeight),
                    options: [.usesLineFragmentOrigin, .usesFontLeading])

        guard let drawn = context.makeImage() else { return nil }
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var out: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs as CFDictionary, &out) == kCVReturnSuccess,
              let out else { return nil }
        CIContext().render(CIImage(cgImage: drawn), to: out)
        return out
    }
}
