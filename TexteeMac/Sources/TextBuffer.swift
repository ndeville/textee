import AppKit

/// Reads an NSString in chunks of UTF-16 units: one call per 64K units instead of one per character.
@inline(__always)
func scanUnits(_ s: NSString, _ range: NSRange, _ body: (UnsafeBufferPointer<unichar>, Int) -> Void) {
    let chunk = 65_536
    var loc = range.location
    let end = NSMaxRange(range)
    guard loc < end else { return }
    let buf = UnsafeMutablePointer<unichar>.allocate(capacity: min(chunk, end - loc))
    defer { buf.deallocate() }
    while loc < end {
        let n = min(chunk, end - loc)
        s.getCharacters(buf, range: NSRange(location: loc, length: n))
        body(UnsafeBufferPointer(start: buf, count: n), loc)
        loc += n
    }
}

/// Start offset (UTF-16) of every line, and the words on each line. Updated per edit, never rebuilt while typing.
/// A line break ends a word, so the word count is the sum over the lines: an edit recounts only its own lines.
struct LineIndex {
    private(set) var starts: [Int] = [0]
    private(set) var lineWords: [Int32] = [0]
    private(set) var wordCount = 0

    init() {}

    init(_ s: NSString) {
        var lines = 1
        scanUnits(s, NSRange(location: 0, length: s.length)) { buf, _ in
            for u in buf where u == 10 { lines += 1 }
        }
        var b = Builder(capacity: lines)
        b.feed(s, at: 0)
        self = b.finish()
    }

    /// Builds the index in 1 pass over the text, piece by piece. `capacity` is the exact line count when the
    /// caller knows it, so the arrays hold no spare room.
    struct Builder {
        private var starts: [Int] = [0]
        private var lineWords: [Int32] = []
        private var current: Int32 = 0
        private var inWord = false
        private var total = 0

        init(capacity: Int) {
            starts.reserveCapacity(capacity)
            lineWords.reserveCapacity(capacity)
        }

        /// `s` is the next piece of the text; `at` is its offset in the whole text.
        mutating func feed(_ s: NSString, at: Int) {
            scanUnits(s, NSRange(location: 0, length: s.length)) { buf, base in
                for i in 0..<buf.count {
                    let u = buf[i]
                    if u == 10 {
                        lineWords.append(current)
                        total += Int(current)
                        current = 0
                        inWord = false
                        starts.append(at + base + i + 1)
                    } else if Counter.isSpace(u) {
                        inWord = false
                    } else if !inWord {
                        inWord = true
                        current += 1
                    }
                }
            }
        }

        mutating func finish() -> LineIndex {
            lineWords.append(current)
            var index = LineIndex()
            index.starts = starts
            index.lineWords = lineWords
            index.wordCount = total + Int(current)
            return index
        }
    }

    var count: Int { starts.count }

    /// Index of the line that holds `loc`.
    func line(at loc: Int) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= loc { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Range of line `i` without its line break.
    func range(ofLine i: Int, in s: NSString) -> NSRange {
        let start = starts[i]
        var end = i + 1 < starts.count ? starts[i + 1] - 1 : s.length
        if end > start, s.character(at: end - 1) == 13 { end -= 1 }
        return NSRange(location: start, length: max(0, end - start))
    }

    /// First index whose start is greater than `loc`.
    private func upperBound(_ loc: Int) -> Int {
        var lo = 0, hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= loc { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// `edited` is in new coordinates, `delta` the change in length.
    mutating func update(edited: NSRange, delta: Int, in s: NSString) {
        let oldEnd = NSMaxRange(edited) - delta
        let lo = upperBound(edited.location)
        let hi = max(lo, upperBound(oldEnd))
        var fresh: [Int] = []
        scanUnits(s, edited) { buf, base in
            for i in 0..<buf.count where buf[i] == 10 { fresh.append(base + i + 1) }
        }
        // Lines first..<hi held the edit before it; first...first + fresh.count hold it now.
        let first = lo - 1
        var removed = 0
        for i in first..<hi { removed += Int(lineWords[i]) }
        starts.replaceSubrange(lo..<hi, with: fresh)
        if delta != 0 {
            var i = lo + fresh.count
            let n = starts.count
            starts.withUnsafeMutableBufferPointer { p in
                while i < n { p[i] += delta; i += 1 }
            }
        }
        var counted: [Int32] = []
        counted.reserveCapacity(fresh.count + 1)
        var added = 0
        for i in first...(first + fresh.count) {
            let end = i + 1 < starts.count ? starts[i + 1] : s.length
            let w = Counter.words(s, NSRange(location: starts[i], length: end - starts[i]))
            counted.append(Int32(w))
            added += w
        }
        lineWords.replaceSubrange(first..<hi, with: counted)
        wordCount += added - removed
    }
}

/// Word and character counts. Characters follow LinkedIn: UTF-16 units, so an emoji counts 2
/// (Buffer's developer guide; LinkedIn publishes no rule).
enum Counter {
    @inline(__always)
    static func isSpace(_ u: unichar) -> Bool {
        u == 32 || u == 10 || u == 9 || u == 13 || u == 0xA0 || u == 0x2028 || u == 0x2029
            || u == 0x3000 || u == 0x202F || (u >= 0x2000 && u <= 0x200B) || u == 11 || u == 12
    }

    static func words(_ s: NSString, _ range: NSRange) -> Int {
        var count = 0
        var inWord = false
        scanUnits(s, range) { buf, _ in
            for u in buf {
                if isSpace(u) {
                    inWord = false
                } else if !inWord {
                    inWord = true
                    count += 1
                }
            }
        }
        return count
    }
}

enum LineEnding: String {
    case lf = "LF", crlf = "CRLF", mixed = "Mixed"
}

/// A file read into a text storage, with its line index and word count from the same pass.
struct LoadedText {
    var storage: NSTextStorage
    var lines: LineIndex
    var lineEnding: LineEnding = .lf
    var hasBOM = false
    var readOnlyReason: String?
    var stamp: DiskStamp?

    init(storage: NSTextStorage, lines: LineIndex) {
        self.storage = storage
        self.lines = lines
    }

    /// Text that doesn't come from a UTF-8 file: the warm-up, a file in another encoding.
    init(string: String, attributes: [NSAttributedString.Key: Any] = Document.baseAttributes) {
        storage = NSTextStorage(string: string, attributes: attributes)
        lines = LineIndex(storage.string as NSString)
    }
}

/// Modification date and size at the last load or save.
struct DiskStamp: Equatable {
    var mtime: TimeInterval
    var size: Int

    static func of(_ url: URL) -> DiskStamp? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        let t = TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9
        return DiskStamp(mtime: t, size: Int(st.st_size))
    }
}

enum TextFileError: LocalizedError {
    case changedOnDisk
    case readOnly(String)
    case blockedByEnvironment

    var errorDescription: String? {
        switch self {
        case .changedOnDisk: return "The file changed on disk since Textee loaded it."
        case .readOnly(let why): return why
        case .blockedByEnvironment: return "TEXTEE_READONLY=1 blocks every write."
        }
    }
}

enum TextFile {
    static var readOnlyMode: Bool { ProcessInfo.processInfo.environment["TEXTEE_READONLY"] == "1" }

    /// Real path, symlinks resolved, so a symlinked file saves to its target.
    static func canonical(_ url: URL) -> URL {
        guard let p = realpath(url.path, nil) else { return url.standardizedFileURL }
        defer { free(p) }
        return URL(fileURLWithPath: String(cString: p))
    }

    /// Pieces of about 1 MB: the decode never holds a 2nd copy of the whole file.
    static let pieceSize = 1 << 20

    static func load(_ url: URL, attributes: [NSAttributedString.Key: Any] = Document.baseAttributes) throws -> LoadedText {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let stamp = DiskStamp.of(url)
        var loaded = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> LoadedText in
            let all = raw.bindMemory(to: UInt8.self)
            let hasBOM = all.count >= 3 && all[0] == 0xEF && all[1] == 0xBB && all[2] == 0xBF
            let bytes = UnsafeBufferPointer(rebasing: all[(hasBOM ? 3 : 0)...])
            var crlf = 0, lf = 0
            if let base = bytes.baseAddress {
                for i in 0..<bytes.count where base[i] == 10 {
                    if i > 0, base[i - 1] == 13 { crlf += 1 } else { lf += 1 }
                }
            }
            let ending: LineEnding = crlf > 0 ? (lf > 0 ? .mixed : .crlf) : .lf
            // A file with only CRLF is edited as LF and saved back as CRLF. Mixed files stay as they are.
            var out: LoadedText
            if let utf8 = decodeUTF8(bytes, dropCR: ending == .crlf, lines: crlf + lf + 1, attributes: attributes) {
                out = utf8
            } else {
                let d = Data(buffer: bytes)
                let text = String(data: d, encoding: .windowsCP1252) ?? String(decoding: d, as: UTF8.self)
                out = LoadedText(string: text, attributes: attributes)
                out.readOnlyReason = "Not UTF-8: opened read-only"
            }
            out.lineEnding = ending
            out.hasBOM = hasBOM
            return out
        }
        loaded.stamp = stamp
        return loaded
    }

    /// Decodes the file piece by piece straight into a text storage and indexes lines and words on the way.
    /// Returns nil when the bytes aren't valid UTF-8.
    private static func decodeUTF8(_ bytes: UnsafeBufferPointer<UInt8>, dropCR: Bool, lines: Int,
                                   attributes: [NSAttributedString.Key: Any]) -> LoadedText? {
        let storage = NSTextStorage()
        var builder = LineIndex.Builder(capacity: lines)
        let n = bytes.count
        guard let base = bytes.baseAddress, n > 0 else {
            return LoadedText(storage: NSTextStorage(string: "", attributes: attributes), lines: builder.finish())
        }
        storage.beginEditing()
        defer { storage.endEditing() }
        var start = 0
        while start < n {
            let end = pieceEnd(base, from: start, count: n)
            let ok = autoreleasepool { () -> Bool in
                let length = end - start
                let enc = String.Encoding.utf8.rawValue
                let piece: NSString?
                if dropCR, let m = NSMutableString(bytes: base + start, length: length, encoding: enc) {
                    m.replaceOccurrences(of: "\r\n", with: "\n", options: .literal, range: NSRange(location: 0, length: m.length))
                    piece = m
                } else {
                    piece = dropCR ? nil : NSString(bytes: base + start, length: length, encoding: enc)
                }
                guard let piece else { return false }
                let at = storage.length
                builder.feed(piece, at: at)
                storage.replaceCharacters(in: NSRange(location: at, length: 0), with: piece as String)
                return true
            }
            if !ok { return nil }
            start = end
        }
        storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        return LoadedText(storage: storage, lines: builder.finish())
    }

    /// End of the piece that starts at `start`: just after a line break, or else on a UTF-8 character
    /// boundary that doesn't split a CR from its LF.
    private static func pieceEnd(_ base: UnsafePointer<UInt8>, from start: Int, count n: Int) -> Int {
        let limit = start + pieceSize
        guard limit < n else { return n }
        var cut = limit
        while cut > start, base[cut - 1] != 10 { cut -= 1 }
        if cut > start { return cut }
        cut = limit
        while cut > start, base[cut] & 0xC0 == 0x80 { cut -= 1 }
        if cut > start, base[cut - 1] == 13 { cut -= 1 }
        // No boundary in 1 MB means invalid UTF-8: the decode of this piece fails.
        return cut > start ? cut : limit
    }

    /// Atomic write: temp file in the same folder, then swapped in with the original's metadata.
    /// Refuses when the file changed on disk since `expected` (pass nil to skip the check).
    @discardableResult
    static func write(_ text: String, to url: URL, lineEnding: LineEnding, hasBOM: Bool,
                      expected: DiskStamp?, checkConflict: Bool) throws -> DiskStamp? {
        if readOnlyMode { throw TextFileError.blockedByEnvironment }
        if checkConflict, let expected, let now = DiskStamp.of(url), now != expected {
            throw TextFileError.changedOnDisk
        }
        var out = text
        if lineEnding == .crlf { out = out.replacingOccurrences(of: "\n", with: "\r\n") }
        var data = Data()
        if hasBOM { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        data.append(contentsOf: Array(out.utf8))
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try data.write(to: url)
            chmod(url.path, 0o644)
            return DiskStamp.of(url)
        }
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).textee-\(UUID().uuidString.prefix(8)).tmp")
        do {
            try data.write(to: tmp)
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        return DiskStamp.of(url)
    }
}
