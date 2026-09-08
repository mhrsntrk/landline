import Foundation

/// The icons a key bar cell can wear instead of a word.
///
/// Every one is a Nerd Font glyph out of the face this app already bundles for
/// the terminal, so the cell sets in the same metal the session does. That is
/// also why they are not drawn shapes and not SF Symbols: the font is already
/// in the bundle, it is the terminal's own, and a glyph costs nothing to add
/// where a drawn mark costs a hand and an opinion.
///
/// The chrome elsewhere sets in SF Mono, which has none of these codepoints,
/// so a cell wearing an icon asks for the bundled face by name. Rendering one
/// in the chrome font would draw a tofu box.
///
/// Every codepoint here was checked against
/// `Resources/Fonts/JetBrainsMonoNerdFontMono-Regular.ttf` rather than copied
/// out of a cheat sheet: Nerd Font patches vary by release, and a glyph that is
/// merely *documented* is not one this build can draw. `KeyBarIconTests` holds
/// that line.
struct KeyBarIcon: Identifiable, Hashable {
    /// The scalar, as stored in `settings.json`. Permanent: it is what a saved
    /// layout holds.
    let scalar: String
    /// The name a person would say, for the picker and for VoiceOver.
    let name: String

    var id: String { scalar }

    private init(_ codepoint: UInt32, _ name: String) {
        self.scalar = String(UnicodeScalar(codepoint)!)
        self.name = name
    }

    /// The picker's sections. Grouped by what someone is doing when they reach
    /// for the key, not by which upstream icon set the glyph came from, which
    /// is an implementation detail nobody holding a phone cares about.
    struct Group: Identifiable, Hashable {
        let id: String
        let icons: [KeyBarIcon]
    }

    static let groups: [Group] = [
        Group(id: "FILES", icons: [
            KeyBarIcon(0xF15B, "file"),
            KeyBarIcon(0xF07B, "folder"),
            KeyBarIcon(0xF0C6, "paperclip"),
            KeyBarIcon(0xF03E, "image"),
            KeyBarIcon(0xF0C7, "save"),
        ]),
        Group(id: "TRANSFER", icons: [
            KeyBarIcon(0xF019, "download"),
            KeyBarIcon(0xF093, "upload"),
        ]),
        Group(id: "SHELL", icons: [
            KeyBarIcon(0xF120, "terminal"),
            KeyBarIcon(0xF121, "code"),
            KeyBarIcon(0xF126, "branch"),
            KeyBarIcon(0xF233, "server"),
            KeyBarIcon(0xF1C0, "database"),
            KeyBarIcon(0xF188, "bug"),
        ]),
        Group(id: "EDITING", icons: [
            KeyBarIcon(0xF002, "search"),
            KeyBarIcon(0xF0C5, "copy"),
            KeyBarIcon(0xF0EA, "paste"),
            KeyBarIcon(0xF0C4, "cut"),
            KeyBarIcon(0xF0E2, "undo"),
            KeyBarIcon(0xF01E, "redo"),
        ]),
        Group(id: "RUNNING", icons: [
            KeyBarIcon(0xF04B, "play"),
            KeyBarIcon(0xF04D, "stop"),
            KeyBarIcon(0xF04C, "pause"),
            KeyBarIcon(0xF021, "refresh"),
            KeyBarIcon(0xF0E7, "bolt"),
        ]),
        Group(id: "STATE", icons: [
            KeyBarIcon(0xF00C, "check"),
            KeyBarIcon(0xF00D, "cross"),
            KeyBarIcon(0xF071, "warning"),
            KeyBarIcon(0xF023, "lock"),
            KeyBarIcon(0xF084, "key"),
            KeyBarIcon(0xF013, "cog"),
        ]),
    ]

    static let all: [KeyBarIcon] = groups.flatMap(\.icons)

    private static let index: [String: KeyBarIcon] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.scalar, $0) })

    /// The icon for a stored scalar, or nil for one this build does not offer.
    ///
    /// Tolerant for the same reason a catalog id is: a layout written by a
    /// newer build must not make this one refuse to draw the row.
    static func icon(scalar: String) -> KeyBarIcon? { index[scalar] }

    /// The file key wears one by default, because it is the one key in the bar
    /// that is not a key a keyboard has and so has no word that reads right.
    static let attachDefault = KeyBarIcon(0xF15B, "file").scalar
}
