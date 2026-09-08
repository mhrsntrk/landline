import UIKit
import UniformTypeIdentifiers

/// One file, ready to send: the bytes that go on the wire and the name that
/// goes in the URL.
struct Attachment: Equatable {
    let data: Data
    let filename: String
}

/// Turns whatever a picker hands over into something worth sending to a host.
///
/// Two things happen here and nothing else. HEIC becomes JPEG, because a phone
/// photo is HEIC and most of what reads a file on the far end cannot open one.
/// A photograph larger than any screen is scaled down, because those megabytes
/// buy nothing at the other end and cost a phone link. Everything else, from a
/// PDF to a log file, is passed through untouched: this is not the place to
/// have opinions about a file somebody deliberately picked.
enum AttachmentPrep {
    /// Longest edge that is sent untouched.
    ///
    /// An iPhone screenshot is 1290 by 2796, and a screenshot is the single
    /// most likely thing to be sent through here. Downscaling one blurs exactly
    /// what it was taken for, which is the text in it, so the ceiling sits well
    /// above every screen this app runs on and only catches camera photos,
    /// where a 8064 pixel edge is bytes nothing downstream will read.
    static let maxPixels: CGFloat = 4096
    static let jpegQuality: CGFloat = 0.9

    /// Whether `type` goes as-is. PNG and JPEG are what everything reads.
    static func isPassthrough(_ type: UTType?) -> Bool {
        guard let type else { return false }
        return type.conforms(to: .png) || type.conforms(to: .jpeg)
    }

    /// The size `size` should be drawn at, or nil when it already fits.
    ///
    /// Pure and separate from the drawing so the arithmetic that decides
    /// whether a screenshot survives intact can be asserted without a bitmap.
    static func scaledSize(for size: CGSize, maxPixels: CGFloat = maxPixels) -> CGSize? {
        let longest = max(size.width, size.height)
        guard longest > maxPixels, longest > 0 else { return nil }
        let factor = maxPixels / longest
        return CGSize(
            width: max(1, (size.width * factor).rounded()),
            height: max(1, (size.height * factor).rounded())
        )
    }

    /// `filename` with its extension replaced.
    ///
    /// Leading dots go with it. A name that starts with one is a hidden file on
    /// the far end, and nothing sent from a phone picker should quietly become
    /// one.
    static func renamed(_ filename: String, toExtension ext: String) -> String {
        let stem = String((filename as NSString).deletingPathExtension.drop(while: { $0 == "." }))
        let base = stem.isEmpty ? "image" : stem
        return "\(base).\(ext)"
    }

    /// The attachment to send for a picked item.
    static func prepare(data: Data, filename: String, type: UTType?) -> Attachment {
        let original = Attachment(data: data, filename: filename)
        // Not an image: nothing here has anything to say about it.
        guard let image = UIImage(data: data), let bitmap = image.cgImage else { return original }

        let pixels = CGSize(width: bitmap.width, height: bitmap.height)
        let target = scaledSize(for: pixels)
        if isPassthrough(type), target == nil { return original }

        let renderer = UIGraphicsImageRenderer(
            size: target ?? pixels,
            format: {
                let format = UIGraphicsImageRendererFormat.default()
                // Pixels, not points: the target above is already in pixels, and
                // letting the renderer apply the screen scale would produce a
                // 3x image of the thing that was being made smaller.
                format.scale = 1
                format.opaque = false
                return format
            }()
        )
        let redrawn = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target ?? pixels))
        }
        guard let encoded = redrawn.jpegData(compressionQuality: jpegQuality) else { return original }
        return Attachment(data: encoded, filename: renamed(filename, toExtension: "jpg"))
    }
}

/// The bytes that put a path into the running session.
///
/// A path is typed, not executed: it lands at whatever prompt is there, and
/// what happens next is the person's business. That is the whole point of
/// handing back a path rather than doing something clever with it, since the
/// thing on the far end may be a shell, an editor, or an agent, and only the
/// person holding the phone knows which.
enum PathInsertion {
    /// Wraps `path` for the terminal.
    ///
    /// Bracketed paste is used when the far end asked for it, which every
    /// modern shell and every agent prompt does. It is what tells the reader
    /// that this arrived as a paste rather than as keystrokes, so a prompt with
    /// a submit-on-enter binding does not run it, and a multi-line paste stays
    /// one paste. A trailing space separates the path from whatever is typed
    /// next.
    ///
    /// Control bytes are dropped rather than escaped. The daemon's own naming
    /// rules mean a path cannot contain one, so anything that did would be a
    /// bug or an attack, and neither is worth typing into a live prompt.
    static func bytes(for path: String, bracketedPaste: Bool) -> [UInt8] {
        let body = Array(path.utf8).filter { $0 >= 0x20 && $0 != 0x7f }
        guard !body.isEmpty else { return [] }
        let payload = body + [UInt8(0x20)]
        guard bracketedPaste else { return payload }
        let start: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e] // ESC [ 200 ~
        let end: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]   // ESC [ 201 ~
        return start + payload + end
    }
}
