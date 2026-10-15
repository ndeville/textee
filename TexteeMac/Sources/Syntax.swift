import AppKit

enum Tok: UInt8 {
    case plain, comment, keyword, string, constant, entity, support, tag, punct
    case heading, bold, italic, code, link, url, listMarker, quote, variable
}

enum Language: String {
    case plain = "Plain Text", markdown = "Markdown", json = "JSON", yaml = "YAML", python = "Python", shell = "Shell"

    static func detect(_ url: URL, firstLine: String) -> Language {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "md", "markdown", "mdown", "mkd", "mdx": return .markdown
        case "json", "jsonc", "geojson": return .json
        case "yaml", "yml": return .yaml
        case "py", "pyw", "pyi": return .python
        case "sh", "bash", "zsh", "command", "ksh": return .shell
        default: break
        }
        let name = url.lastPathComponent.lowercased()
        if [".zshrc", ".bashrc", ".zprofile", ".bash_profile", ".profile", ".zshenv"].contains(name) { return .shell }
        if firstLine.hasPrefix("#!") {
            if firstLine.contains("python") { return .python }
            if firstLine.contains("sh") { return .shell }
        }
        return .plain
    }

    var lexer: Lexer? {
        switch self {
        case .plain: return nil
        case .markdown: return MarkdownLexer()
        case .json: return JSONLexer()
        case .yaml: return YAMLLexer()
        case .python: return PythonLexer()
        case .shell: return ShellLexer()
        }
    }
}

typealias Emit = (_ start: Int, _ length: Int, _ tok: Tok) -> Void

/// A line lexer: gets 1 line (no line break) and the state at its start, returns the state at its end.
protocol Lexer {
    func lex(_ u: UnsafeBufferPointer<unichar>, line: Int, state: UInt8, emit: Emit) -> UInt8
}

// MARK: Character helpers

@inline(__always) func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }
@inline(__always) func isAlpha(_ c: unichar) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c >= 128 }
@inline(__always) func isIdent(_ c: unichar) -> Bool { isAlpha(c) || isDigit(c) || c == 95 }
@inline(__always) func isSpace(_ c: unichar) -> Bool { c == 32 || c == 9 }

private func word(_ u: UnsafeBufferPointer<unichar>, _ start: Int, _ end: Int) -> String {
    String(utf16CodeUnits: u.baseAddress! + start, count: end - start)
}

private func matches(_ u: UnsafeBufferPointer<unichar>, _ at: Int, _ lit: String) -> Bool {
    var i = at
    for c in lit.utf16 {
        if i >= u.count || u[i] != c { return false }
        i += 1
    }
    return true
}

private func find(_ u: UnsafeBufferPointer<unichar>, _ from: Int, _ lit: String) -> Int? {
    guard let first = lit.utf16.first else { return nil }
    var i = from
    while i < u.count {
        if u[i] == first, matches(u, i, lit) { return i }
        i += 1
    }
    return nil
}

/// End (exclusive) of a quoted string that starts at `i` (the quote), honouring backslash escapes.
/// Returns nil when the line ends first.
private func stringEnd(_ u: UnsafeBufferPointer<unichar>, _ i: Int, quote: unichar, escapes: Bool = true) -> Int? {
    var j = i + 1
    while j < u.count {
        if escapes, u[j] == 92 { j += 2; continue }
        if u[j] == quote { return j + 1 }
        j += 1
    }
    return nil
}

private func numberEnd(_ u: UnsafeBufferPointer<unichar>, _ i: Int) -> Int {
    var j = i
    while j < u.count, isIdent(u[j]) || u[j] == 46 { j += 1 }
    return j
}

// MARK: Markdown

/// States: 0 text, 1 ``` fence, 2 ~~~ fence, 3 front matter, 4 HTML comment.
struct MarkdownLexer: Lexer {
    func lex(_ u: UnsafeBufferPointer<unichar>, line: Int, state: UInt8, emit: Emit) -> UInt8 {
        let n = u.count
        var indent = 0
        while indent < n, indent < 4, u[indent] == 32 { indent += 1 }
        func fence(_ ch: unichar) -> Bool { indent + 2 < n && u[indent] == ch && u[indent + 1] == ch && u[indent + 2] == ch }
        func only(_ lit: String) -> Bool { n == lit.utf16.count && matches(u, 0, lit) }

        switch state {
        case 1, 2:
            emit(0, n, .code)
            return fence(state == 1 ? 96 : 126) ? 0 : state
        case 3:
            if only("---") || only("...") { emit(0, n, .punct); return 0 }
            if let colon = find(u, 0, ":") { emit(0, colon, .keyword); emit(colon + 1, n - colon - 1, .string) } else { emit(0, n, .string) }
            return 3
        case 4:
            if let end = find(u, 0, "-->") {
                emit(0, end + 3, .comment)
                return inline(u, from: end + 3, emit: emit)
            }
            emit(0, n, .comment)
            return 4
        default: break
        }
        if line == 0, only("---") { emit(0, n, .punct); return 3 }
        if fence(96) { emit(0, n, .code); return 1 }
        if fence(126) { emit(0, n, .code); return 2 }
        guard indent < n else { return 0 }
        if u[indent] == 35 { // #
            var h = indent
            while h < n, u[h] == 35 { h += 1 }
            if h - indent <= 6, h == n || u[h] == 32 { emit(0, n, .heading); return 0 }
        }
        if u[indent] == 62 { emit(0, n, .quote); return 0 } // >
        if isRule(u) { emit(0, n, .comment); return 0 }
        var j = 0
        while j < n, isSpace(u[j]) { j += 1 }
        if j < n {
            let c = u[j]
            if (c == 45 || c == 42 || c == 43), j + 1 < n, u[j + 1] == 32 { // - * +
                emit(j, 1, .listMarker)
                j += 2
            } else if isDigit(c) {
                var k = j
                while k < n, isDigit(u[k]) { k += 1 }
                if k < n - 1, u[k] == 46 || u[k] == 41, u[k + 1] == 32 { emit(j, k - j + 1, .listMarker); j = k + 2 }
            }
            if j + 2 < n, u[j] == 91, u[j + 2] == 93, u[j + 1] == 32 || u[j + 1] == 120 || u[j + 1] == 88 {
                emit(j, 3, .constant)
                j += 3
            }
        }
        return inline(u, from: indent, emit: emit)
    }

    private func isRule(_ u: UnsafeBufferPointer<unichar>) -> Bool {
        var ch: unichar = 0
        var count = 0
        for c in u {
            if c == 32 { continue }
            if c != 45 && c != 42 && c != 95 { return false }
            if ch == 0 { ch = c } else if c != ch { return false }
            count += 1
        }
        return count >= 3
    }

    /// Inline spans. Returns 4 when an HTML comment stays open at the end of the line.
    private func inline(_ u: UnsafeBufferPointer<unichar>, from: Int, emit: Emit) -> UInt8 {
        let n = u.count
        var i = from
        while i < n {
            let c = u[i]
            switch c {
            case 96: // `
                var k = i
                while k < n, u[k] == 96 { k += 1 }
                let run = k - i
                var j = k
                var close: Int?
                while j < n {
                    if u[j] == 96 {
                        var m = j
                        while m < n, u[m] == 96 { m += 1 }
                        if m - j == run { close = m; break }
                        j = m
                    } else { j += 1 }
                }
                if let close { emit(i, close - i, .code); i = close } else { i = k }
            case 42, 95: // * _
                var k = i
                while k < n, u[k] == c { k += 1 }
                let run = min(k - i, 3)
                let leftOK = c == 42 || i == 0 || !isIdent(u[i - 1])
                if leftOK, k < n, !isSpace(u[k]), let close = closing(u, from: k, ch: c, run: run) {
                    emit(i, close - i, run >= 2 ? .bold : .italic)
                    i = close
                } else { i = k }
            case 126 where i + 1 < n && u[i + 1] == 126: // ~~
                if let end = find(u, i + 2, "~~") { emit(i, end + 2 - i, .comment); i = end + 2 } else { i += 2 }
            case 91, 33: // [ or ![
                let open = c == 33 ? i + 1 : i
                guard open < n, u[open] == 91, let close = find(u, open + 1, "]") else { i += 1; continue }
                if close + 1 < n, u[close + 1] == 40, let paren = find(u, close + 2, ")") {
                    emit(i, close + 1 - i, .link)
                    emit(close + 1, paren + 1 - close - 1, .url)
                    i = paren + 1
                } else { i += 1 }
            case 60: // <
                if matches(u, i, "<!--") {
                    if let end = find(u, i + 4, "-->") { emit(i, end + 3 - i, .comment); i = end + 3 }
                    else { emit(i, n - i, .comment); return 4 }
                } else if i + 1 < n, isAlpha(u[i + 1]) || u[i + 1] == 47, let end = find(u, i + 1, ">") {
                    let isURL = matches(u, i + 1, "http")
                    emit(i, end + 1 - i, isURL ? .url : .tag)
                    i = end + 1
                } else { i += 1 }
            case 104: // h
                if (i == 0 || !isIdent(u[i - 1])), matches(u, i, "http://") || matches(u, i, "https://") {
                    var j = i
                    while j < n, !isSpace(u[j]), u[j] != 41, u[j] != 62, u[j] != 34 { j += 1 }
                    emit(i, j - i, .url)
                    i = j
                } else { i += 1 }
            case 124: // |
                emit(i, 1, .punct)
                i += 1
            default:
                i += 1
            }
        }
        return 0
    }

    private func closing(_ u: UnsafeBufferPointer<unichar>, from: Int, ch: unichar, run: Int) -> Int? {
        var j = from
        let n = u.count
        while j < n {
            if u[j] == 96 { // skip code spans
                if let end = find(u, j + 1, "`") { j = end + 1; continue }
            }
            if u[j] == ch {
                var k = j
                while k < n, u[k] == ch { k += 1 }
                let rightOK = !isSpace(u[j - 1]) && (ch == 42 || k == n || !isIdent(u[k]))
                if rightOK, k - j >= run { return j + run }
                j = k
            } else { j += 1 }
        }
        return nil
    }
}

// MARK: JSON

/// States: 0 normal, 1 block comment.
struct JSONLexer: Lexer {
    func lex(_ u: UnsafeBufferPointer<unichar>, line: Int, state: UInt8, emit: Emit) -> UInt8 {
        let n = u.count
        var i = 0
        if state == 1 {
            guard let end = find(u, 0, "*/") else { emit(0, n, .comment); return 1 }
            emit(0, end + 2, .comment)
            i = end + 2
        }
        while i < n {
            let c = u[i]
            if c == 34 {
                let end = stringEnd(u, i, quote: 34) ?? n
                var k = end
                while k < n, isSpace(u[k]) { k += 1 }
                emit(i, end - i, k < n && u[k] == 58 ? .support : .string)
                i = end
            } else if isDigit(c) || (c == 45 && i + 1 < n && isDigit(u[i + 1])) {
                let end = numberEnd(u, i + 1)
                emit(i, end - i, .constant)
                i = end
            } else if isAlpha(c) {
                var end = i
                while end < n, isIdent(u[end]) { end += 1 }
                let w = word(u, i, end)
                if w == "true" || w == "false" || w == "null" { emit(i, end - i, .constant) }
                i = end
            } else if c == 47, i + 1 < n, u[i + 1] == 47 {
                emit(i, n - i, .comment)
                return 0
            } else if c == 47, i + 1 < n, u[i + 1] == 42 {
                guard let end = find(u, i + 2, "*/") else { emit(i, n - i, .comment); return 1 }
                emit(i, end + 2 - i, .comment)
                i = end + 2
            } else {
                i += 1
            }
        }
        return 0
    }
}

// MARK: YAML

struct YAMLLexer: Lexer {
    func lex(_ u: UnsafeBufferPointer<unichar>, line: Int, state: UInt8, emit: Emit) -> UInt8 {
        let n = u.count
        var i = 0
        while i < n, isSpace(u[i]) { i += 1 }
        guard i < n else { return 0 }
        if u[i] == 35 { emit(i, n - i, .comment); return 0 }
        if i == 0, (matches(u, 0, "---") || matches(u, 0, "...")) { emit(0, min(3, n), .punct); i = 3 }
        while i + 1 < n, u[i] == 45, u[i + 1] == 32 { emit(i, 1, .listMarker); i += 2; while i < n, isSpace(u[i]) { i += 1 } }
        // Key: plain or quoted text before ": " or a final ":".
        var k = i
        var keyEnd: Int?
        if k < n, u[k] == 34 || u[k] == 39, let end = stringEnd(u, k, quote: u[k]) {
            if end < n, u[end] == 58, end + 1 == n || isSpace(u[end + 1]) { keyEnd = end }
        } else {
            while k < n {
                if u[k] == 58, k + 1 == n || isSpace(u[k + 1]) { keyEnd = k; break }
                if u[k] == 35, k > 0, isSpace(u[k - 1]) { break }
                if u[k] == 34 || u[k] == 39 || u[k] == 123 || u[k] == 91 { break }
                k += 1
            }
        }
        if let keyEnd, keyEnd > i {
            emit(i, keyEnd - i, .support)
            i = keyEnd + 1
        }
        value(u, from: i, emit: emit)
        return 0
    }

    private func value(_ u: UnsafeBufferPointer<unichar>, from: Int, emit: Emit) {
        let n = u.count
        var i = from
        while i < n, isSpace(u[i]) { i += 1 }
        guard i < n else { return }
        let c = u[i]
        if c == 34 || c == 39 {
            let end = stringEnd(u, i, quote: c, escapes: c == 34) ?? n
            emit(i, end - i, .string)
            comment(u, from: end, emit: emit)
            return
        }
        if c == 38 || c == 42 { // & anchor, * alias
            var end = i + 1
            while end < n, !isSpace(u[end]) { end += 1 }
            emit(i, end - i, .variable)
            value(u, from: end, emit: emit)
            return
        }
        if c == 124 || c == 62 { emit(i, 1, .punct); comment(u, from: i + 1, emit: emit); return }
        // Plain scalar up to a comment.
        var end = i
        while end < n, !(u[end] == 35 && end > 0 && isSpace(u[end - 1])) { end += 1 }
        var trimmed = end
        while trimmed > i, isSpace(u[trimmed - 1]) { trimmed -= 1 }
        let w = word(u, i, trimmed)
        let constants: Set<String> = ["true", "false", "null", "~", "yes", "no", "True", "False", "Null", "on", "off"]
        if constants.contains(w) || Double(w) != nil { emit(i, trimmed - i, .constant) }
        else if c != 123 && c != 91 { emit(i, trimmed - i, .string) }
        if end < n { emit(end, n - end, .comment) }
    }

    private func comment(_ u: UnsafeBufferPointer<unichar>, from: Int, emit: Emit) {
        guard let hash = find(u, from, "#") else { return }
        emit(hash, u.count - hash, .comment)
    }
}

// MARK: Python

private let pyKeywords: Set<String> = [
    "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except",
    "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass",
    "raise", "return", "try", "while", "with", "yield", "match", "case",
]
private let pyBuiltins: Set<String> = [
    "print", "len", "range", "str", "int", "float", "bool", "dict", "list", "set", "tuple", "open", "enumerate",
    "zip", "map", "filter", "sorted", "reversed", "sum", "min", "max", "abs", "any", "all", "isinstance", "type",
    "super", "object", "Exception", "ValueError", "KeyError", "TypeError", "OSError", "RuntimeError", "getattr",
    "setattr", "hasattr", "iter", "next", "repr", "round", "input", "format", "bytes", "property", "staticmethod",
    "classmethod",
]

/// States: 0 normal, 1 inside ''' string, 2 inside """ string.
struct PythonLexer: Lexer {
    func lex(_ u: UnsafeBufferPointer<unichar>, line: Int, state: UInt8, emit: Emit) -> UInt8 {
        let n = u.count
        var i = 0
        if state == 1 || state == 2 {
            let close = state == 1 ? "'''" : "\"\"\""
            guard let end = find(u, 0, close) else { emit(0, n, .string); return state }
            emit(0, end + 3, .string)
            i = end + 3
        }
        var afterDefOrClass = false
        while i < n {
            let c = u[i]
            if c == 35 { emit(i, n - i, .comment); return 0 }
            if c == 34 || c == 39 {
                let triple = i + 2 < n && u[i + 1] == c && u[i + 2] == c
                if triple {
                    let lit = c == 39 ? "'''" : "\"\"\""
                    guard let end = find(u, i + 3, lit) else { emit(i, n - i, .string); return c == 39 ? 1 : 2 }
                    emit(i, end + 3 - i, .string)
                    i = end + 3
                } else {
                    let end = stringEnd(u, i, quote: c) ?? n
                    emit(i, end - i, .string)
                    i = end
                }
                continue
            }
            if c == 64, (0..<i).allSatisfy({ isSpace(u[$0]) }) { // decorator
                var end = i + 1
                while end < n, isIdent(u[end]) || u[end] == 46 { end += 1 }
                emit(i, end - i, .entity)
                i = end
                continue
            }
            if isDigit(c), i == 0 || !isIdent(u[i - 1]) {
                let end = numberEnd(u, i)
                emit(i, end - i, .constant)
                i = end
                continue
            }
            if isAlpha(c) || c == 95 {
                var end = i
                while end < n, isIdent(u[end]) { end += 1 }
                // String prefixes: r"", f"", b"", rb"" ...
                if end < n, u[end] == 34 || u[end] == 39, end - i <= 2 {
                    let p = word(u, i, end).lowercased()
                    if ["r", "f", "b", "u", "rb", "br", "fr", "rf"].contains(p) {
                        let q = u[end]
                        let triple = end + 2 < n && u[end + 1] == q && u[end + 2] == q
                        if triple {
                            let lit = q == 39 ? "'''" : "\"\"\""
                            guard let close = find(u, end + 3, lit) else { emit(i, n - i, .string); return q == 39 ? 1 : 2 }
                            emit(i, close + 3 - i, .string)
                            i = close + 3
                        } else {
                            let close = stringEnd(u, end, quote: q) ?? n
                            emit(i, close - i, .string)
                            i = close
                        }
                        continue
                    }
                }
                let w = word(u, i, end)
                if afterDefOrClass {
                    emit(i, end - i, .entity)
                    afterDefOrClass = false
                } else if pyKeywords.contains(w) {
                    emit(i, end - i, .keyword)
                    afterDefOrClass = w == "def" || w == "class"
                } else if w == "True" || w == "False" || w == "None" {
                    emit(i, end - i, .constant)
                } else if w == "self" || w == "cls" {
                    emit(i, end - i, .variable)
                } else if pyBuiltins.contains(w) {
                    emit(i, end - i, .support)
                }
                i = end
                continue
            }
            i += 1
        }
        return 0
    }
}

// MARK: Shell

private let shKeywords: Set<String> = [
    "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function",
    "select", "return", "break", "continue",
]
private let shBuiltins: Set<String> = [
    "echo", "cd", "export", "local", "source", "read", "printf", "test", "set", "unset", "exit", "alias", "eval",
    "exec", "shift", "trap", "declare", "typeset", "readonly", "pushd", "popd", "true", "false",
]

/// States: 0 normal, 1 inside a double-quoted string, 2 inside a single-quoted string.
struct ShellLexer: Lexer {
    func lex(_ u: UnsafeBufferPointer<unichar>, line: Int, state: UInt8, emit: Emit) -> UInt8 {
        let n = u.count
        var i = 0
        if state == 1 || state == 2 {
            let q: unichar = state == 1 ? 34 : 39
            var j = 0
            var closed = false
            while j < n {
                if q == 34, u[j] == 92 { j += 2; continue }
                if u[j] == q { closed = true; j += 1; break }
                j += 1
            }
            emit(0, min(j, n), .string)
            if q == 34 { variables(u, 0, min(j, n), emit) }
            if !closed { return state }
            i = j
        }
        var commandPosition = true
        while i < n {
            let c = u[i]
            if c == 35, i == 0 || isSpace(u[i - 1]) { emit(i, n - i, .comment); return 0 }
            if c == 34 || c == 39 {
                guard let end = stringEnd(u, i, quote: c, escapes: c == 34) else {
                    emit(i, n - i, .string)
                    if c == 34 { variables(u, i, n, emit) }
                    return c == 34 ? 1 : 2
                }
                emit(i, end - i, .string)
                if c == 34 { variables(u, i, end, emit) }
                i = end
                commandPosition = false
                continue
            }
            if c == 36 { // $
                var end = i + 1
                if end < n, u[end] == 123, let close = find(u, end, "}") { end = close + 1 }
                else if end < n, u[end] == 40 { end += 1 }
                else { while end < n, isIdent(u[end]) { end += 1 }; if end == i + 1, end < n { end += 1 } }
                emit(i, end - i, .variable)
                i = end
                continue
            }
            if isAlpha(c) || c == 95 {
                var end = i
                while end < n, isIdent(u[end]) || u[end] == 45 { end += 1 }
                let w = word(u, i, end)
                if shKeywords.contains(w) { emit(i, end - i, .keyword); commandPosition = true }
                else if commandPosition, shBuiltins.contains(w) { emit(i, end - i, .support); commandPosition = false }
                else if end < n, u[end] == 61, commandPosition { emit(i, end - i, .variable) }
                else { commandPosition = false }
                i = end
                continue
            }
            if c == 59 || c == 124 || c == 38 || c == 40 || c == 123 { commandPosition = true } // ; | & ( {
            if isDigit(c), i == 0 || !isIdent(u[i - 1]) {
                let end = numberEnd(u, i)
                emit(i, end - i, .constant)
                i = end
                continue
            }
            i += 1
        }
        return 0
    }
}

/// `$VAR`, `${VAR}` and `$(` inside a double-quoted shell string.
private func variables(_ u: UnsafeBufferPointer<unichar>, _ from: Int, _ to: Int, _ emit: Emit) {
    var i = from
    while i < to {
        guard u[i] == 36, i + 1 < to else { i += 1; continue }
        var end = i + 1
        if u[end] == 123 { while end < to, u[end] != 125 { end += 1 }; end = min(to, end + 1) }
        else { while end < to, isIdent(u[end]) { end += 1 } }
        if end > i + 1 { emit(i, end - i, .variable) }
        i = end
    }
}

// MARK: Highlighter

/// Colours the visible lines with temporary attributes: no change to the text storage, no undo entries.
/// Keeps the lexer state at the start of each line up to the furthest line coloured so far.
final class Highlighter {
    let lexer: Lexer
    private var states: [UInt8] = [0]
    private var buf: [unichar] = []

    init(lexer: Lexer) { self.lexer = lexer }

    func invalidate(fromLine l: Int) {
        if states.count > l + 1 { states.removeSubrange((l + 1)...) }
    }

    func reset() { states = [0] }

    private func lexLine(_ i: Int, _ s: NSString, _ lines: LineIndex, emit: Emit) -> UInt8 {
        let r = lines.range(ofLine: i, in: s)
        if buf.count < r.length { buf = [unichar](repeating: 0, count: max(r.length, 256)) }
        return buf.withUnsafeMutableBufferPointer { p -> UInt8 in
            if r.length > 0 { s.getCharacters(p.baseAddress!, range: r) }
            return lexer.lex(UnsafeBufferPointer(start: p.baseAddress, count: r.length), line: i, state: states[i], emit: emit)
        }
    }

    func apply(_ lm: NSLayoutManager, _ s: NSString, _ lines: LineIndex, visible: NSRange) {
        guard s.length > 0 else { return }
        let first = lines.line(at: visible.location)
        let last = min(lines.count - 1, lines.line(at: max(visible.location, NSMaxRange(visible) - 1)))
        // Bring the line states up to the first visible line.
        while states.count <= first {
            let i = states.count - 1
            states.append(lexLine(i, s, lines) { _, _, _ in })
        }
        let start = lines.starts[first]
        let endLine = lines.range(ofLine: last, in: s)
        let whole = NSRange(location: start, length: NSMaxRange(endLine) - start)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
        for i in first...last {
            let lineStart = lines.starts[i]
            let next = lexLine(i, s, lines) { st, len, tok in
                guard len > 0, tok != .plain else { return }
                lm.addTemporaryAttribute(.foregroundColor, value: Theme.color(tok), forCharacterRange: NSRange(location: lineStart + st, length: len))
            }
            if i + 1 == states.count {
                states.append(next)
            } else if states[i + 1] != next {
                states[i + 1] = next
                if states.count > i + 2 { states.removeSubrange((i + 2)...) }
            }
        }
    }
}
