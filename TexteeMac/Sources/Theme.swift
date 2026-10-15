import AppKit

/// Blackboard (TextMate's theme) for the text, blue for the window chrome.
enum Theme {
    static func hex(_ s: String) -> NSColor {
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let hasAlpha = s.count == 8
        let r = CGFloat((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(v & 0xFF) / 255 : 1
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    // Blackboard, from TextMate's Themes bundle.
    static let background = hex("0C1021")
    static let foreground = hex("F8F8F8")
    static let caret = hex("FFFFFFA6")
    static let selection = hex("1D4ED8")  // Stronger than Blackboard's 253B76, which matched the find-match colour
    static let lineHighlight = hex("FFFFFF0F")
    static let comment = hex("AEAEAE")
    static let constant = hex("D8FA3C")
    static let entity = hex("FF6400")
    static let keyword = hex("FBDE2D")
    static let string = hex("61CE3C")
    static let support = hex("8DA6CE")
    static let tag = hex("7F90AA")
    static let invalid = hex("9D1E15")

    // Blue chrome.
    static let chrome = hex("0A1532")
    static let chromeRaised = hex("12204A")
    static let chromeLine = hex("1D2F66")
    static let statusBackground = hex("1D4ED8")
    static let statusText = hex("FFFFFF")
    static let statusMuted = hex("C7D6FF")
    static let statusGood = hex("B9F5A0")
    static let statusWarn = hex("FFD27A")
    static let accent = hex("3D7BFF")
    static let accentDim = hex("2A4FA8")
    static let chromeText = hex("C9D6F8")
    static let chromeMuted = hex("8A9CCB")
    static let gutterBackground = hex("0A0E1E")
    static let gutterText = hex("46557F")
    static let gutterCurrent = hex("C9D6F8")
    static let findMatch = hex("3D7BFF59")
    static let findCurrent = hex("FBDE2D80")
    static let ok = hex("61CE3C")
    static let warn = hex("FF6400")
    static let banner = hex("1E3A8A")

    static let baseFontSize: CGFloat = 14

    static func editorFont(size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static let uiFont = NSFont.systemFont(ofSize: 12)
    static let uiFontSmall = NSFont.systemFont(ofSize: 11)

    /// Colour of each token kind.
    static func color(_ t: Tok) -> NSColor {
        switch t {
        case .plain: return foreground
        case .comment: return comment
        case .keyword: return keyword
        case .string: return string
        case .constant: return constant
        case .entity: return entity
        case .support: return support
        case .tag: return tag
        case .punct: return tag
        case .heading: return entity
        case .bold: return keyword
        case .italic: return support
        case .code: return string
        case .link: return support
        case .url: return tag
        case .listMarker: return constant
        case .quote: return comment
        case .variable: return entity
        }
    }
}

/// Number with thousands separators: 1,234.
func grouped(_ n: Int) -> String {
    let s = String(n)
    guard n >= 1000 || n <= -1000 else { return s }
    var out = ""
    for (i, ch) in s.reversed().enumerated() {
        if i > 0, i % 3 == 0, ch != "-" { out.append(",") }
        out.append(ch)
    }
    return String(out.reversed())
}

/// "1 word", "2 words", "1,234 chars".
func plural(_ n: Int, _ noun: String) -> String { "\(grouped(n)) \(noun)\(n == 1 ? "" : "s")" }
