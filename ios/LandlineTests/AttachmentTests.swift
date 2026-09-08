import UniformTypeIdentifiers
import XCTest
@testable import Landline

/// What is sent to a host's inbox, and what is typed once it lands.
final class AttachmentTests: XCTestCase {

    // MARK: Preparing what gets sent

    /// The single most likely thing anyone sends through this: a screenshot,
    /// taken because of the text in it. Downscaling one would blur the reason
    /// it was taken, so it has to survive untouched.
    func testAnIPhoneScreenshotIsSentUntouched() {
        let screenshot = Self.png(width: 1290, height: 2796)
        let prepared = AttachmentPrep.prepare(data: screenshot, filename: "shot.png", type: .png)
        XCTAssertEqual(prepared.data, screenshot, "a screenshot must go as-is")
        XCTAssertEqual(prepared.filename, "shot.png")
    }

    /// HEIC is what a phone camera writes and what most things on the far end
    /// cannot open, so it becomes JPEG and says so in its name.
    func testHeicBecomesJpeg() {
        let heic = Self.png(width: 640, height: 480)
        let prepared = AttachmentPrep.prepare(data: heic, filename: "IMG_4821.HEIC", type: .heic)
        XCTAssertEqual(prepared.filename, "IMG_4821.jpg")
        XCTAssertNotEqual(prepared.data, heic)
        XCTAssertNotNil(UIImage(data: prepared.data), "the transcoded bytes must still be an image")
    }

    /// Anything that is not an image is somebody's deliberate choice and is
    /// passed through, whatever it is.
    func testNonImagesArePassedThrough() {
        let pdfish = Data("%PDF-1.7 not really".utf8)
        let prepared = AttachmentPrep.prepare(data: pdfish, filename: "report.pdf", type: .pdf)
        XCTAssertEqual(prepared.data, pdfish)
        XCTAssertEqual(prepared.filename, "report.pdf")
    }

    func testOnlyOversizedImagesAreScaled() {
        // An iPad Pro screenshot, and every phone screenshot, sit under the
        // ceiling. A 48 megapixel camera photo does not.
        XCTAssertNil(AttachmentPrep.scaledSize(for: CGSize(width: 2048, height: 2732)))
        XCTAssertNil(AttachmentPrep.scaledSize(for: CGSize(width: 1290, height: 2796)))
        let scaled = AttachmentPrep.scaledSize(for: CGSize(width: 8064, height: 6048))
        XCTAssertEqual(scaled?.width, 4096)
        XCTAssertEqual(scaled?.height, 3072, "aspect ratio must survive")
    }

    func testPassthroughIsOnlyThePairEverythingReads() {
        XCTAssertTrue(AttachmentPrep.isPassthrough(.png))
        XCTAssertTrue(AttachmentPrep.isPassthrough(.jpeg))
        XCTAssertFalse(AttachmentPrep.isPassthrough(.heic))
        XCTAssertFalse(AttachmentPrep.isPassthrough(.gif))
        XCTAssertFalse(AttachmentPrep.isPassthrough(nil))
    }

    func testRenamingKeepsTheStem() {
        XCTAssertEqual(AttachmentPrep.renamed("IMG_4821.HEIC", toExtension: "jpg"), "IMG_4821.jpg")
        XCTAssertEqual(AttachmentPrep.renamed("no-extension", toExtension: "jpg"), "no-extension.jpg")
        XCTAssertEqual(AttachmentPrep.renamed(".heic", toExtension: "jpg"), "heic.jpg",
                       "a leading dot must not survive into a hidden file name")
        XCTAssertEqual(AttachmentPrep.renamed("", toExtension: "jpg"), "image.jpg")
    }

    // MARK: The name that goes in the URL

    func testPathSegmentIsAlwaysOneSegment() {
        for raw in ["../../etc/passwd", "/etc/shadow", "a/b/c.txt", "", "..."] {
            let segment = HostAPI.pathSegment(for: raw)
            XCTAssertFalse(segment.contains("/"), "\(raw) produced \(segment)")
            XCTAssertFalse(segment.isEmpty, "\(raw) produced an empty segment")
        }
        XCTAssertEqual(HostAPI.pathSegment(for: "IMG_4821.HEIC"), "IMG_4821.HEIC")
        XCTAssertEqual(HostAPI.pathSegment(for: "a/b/c.txt"), "c.txt")
        XCTAssertEqual(HostAPI.pathSegment(for: "..."), "file")
        // Spaces and anything else non-ASCII become a hyphen, so the request
        // line is well formed without percent-encoding games.
        XCTAssertEqual(HostAPI.pathSegment(for: "my notes.txt"), "my-notes.txt")
        // Leading and trailing punctuation is trimmed, so nothing arrives named
        // like a hidden file.
        XCTAssertEqual(HostAPI.pathSegment(for: "ünïcode.png"), "n-code.png")
    }

    // MARK: Typing the path

    /// Bracketed paste is what tells an agent prompt that this arrived as a
    /// paste rather than as typing, which is the difference between the path
    /// appearing and the prompt submitting.
    func testBracketedPasteWrapsThePath() {
        let bytes = PathInsertion.bytes(for: "/Users/x/.landline/inbox/shot-ab12cd34.png",
                                        bracketedPaste: true)
        XCTAssertEqual(Array(bytes.prefix(6)), [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e])
        XCTAssertEqual(Array(bytes.suffix(6)), [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e])
        let inner = String(decoding: bytes.dropFirst(6).dropLast(6), as: UTF8.self)
        XCTAssertEqual(inner, "/Users/x/.landline/inbox/shot-ab12cd34.png ",
                       "a trailing space separates the path from what is typed next")
    }

    func testAPlainTerminalGetsThePathWithoutMarkers() {
        let bytes = PathInsertion.bytes(for: "/tmp/a.png", bracketedPaste: false)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "/tmp/a.png ")
    }

    /// Nothing here may execute. A path that somehow carried a newline would
    /// submit whatever line it landed on, so control bytes are dropped rather
    /// than sent.
    func testControlBytesNeverReachTheSession() {
        let bytes = PathInsertion.bytes(for: "/tmp/a.png\nrm -rf ~\u{07}", bracketedPaste: false)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(text.contains("\n"))
        XCTAssertFalse(text.contains("\u{07}"))
        XCTAssertEqual(text, "/tmp/a.pngrm -rf ~ ")
        XCTAssertTrue(PathInsertion.bytes(for: "", bracketedPaste: true).isEmpty,
                      "an empty path sends nothing at all")
    }

    // MARK: Error copy

    /// Every failure has to say what to do about it, because "upload failed" on
    /// a phone is not something anyone can act on.
    func testEveryFailureSaysSomethingSpecific() {
        let cases: [UploadError] = [
            .unauthorized,
            .badSecret(attemptsLeft: 3),
            .lockedOut,
            .disabled,
            .tooLarge(maxBytes: 26_214_400),
            .server(status: 500),
            .transport("no network"),
            .empty,
        ]
        for error in cases {
            XCTAssertFalse(error.message.isEmpty, "\(error) has no message")
            XCTAssertFalse(error.message.contains("\u{2014}"), "no em-dashes in user-facing copy")
        }
        XCTAssertEqual(UploadError.tooLarge(maxBytes: 26_214_400).message,
                       "too big, the host takes 25 MB")
        XCTAssertEqual(UploadError.badSecret(attemptsLeft: 3).message,
                       "wrong unlock secret, 3 tries left")
    }

    // MARK: Helpers

    /// A PNG of exactly `width` by `height` pixels.
    private static func png(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let size = CGSize(width: width, height: height)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.pngData() ?? Data()
    }
}
