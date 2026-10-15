import AppKit

/// 1 open file: its text, undo history, disk state and editor view.
final class Document: NSObject, NSTextStorageDelegate {
    private(set) var url: URL
    let storage: NSTextStorage
    let undo = UndoManager()
    var lineEnding: LineEnding
    var hasBOM: Bool
    var readOnlyReason: String?
    var stamp: DiskStamp?
    private(set) var language: Language
    private(set) var lines: LineIndex
    private(set) var highlighter: Highlighter?
    var isDirty = false
    /// Created by New (⌘N): deleted on close while it's still empty.
    var isNewScratch = false
    var conflict = false
    var deletedOnDisk = false
    /// Called after every text change, with the first changed line.
    var onEdit: ((Int) -> Void)?

    lazy var editor: EditorView = EditorView(document: self)
    var hasEditor: Bool { _editorLoaded }
    private var _editorLoaded = false

    static let highlightLimit = 5_000_000

    var name: String { url.lastPathComponent }
    var isReadOnly: Bool { readOnlyReason != nil }

    init(url: URL, loaded: LoadedText) {
        self.url = url
        lineEnding = loaded.lineEnding
        hasBOM = loaded.hasBOM
        readOnlyReason = loaded.readOnlyReason
        stamp = loaded.stamp
        storage = loaded.storage
        lines = loaded.lines
        language = Language.detect(url, firstLine: Document.firstLine(of: loaded.storage))
        super.init()
        storage.delegate = self
        undo.levelsOfUndo = 0
        resetHighlighter()
    }

    static var fontSize: CGFloat = Theme.baseFontSize
    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: Theme.editorFont(size: fontSize), .foregroundColor: Theme.foreground]
    }

    func editorDidLoad() { _editorLoaded = true }

    /// The first non-empty line, from the first 200 characters: enough for a shebang.
    private static func firstLine(of storage: NSTextStorage) -> String {
        let head = (storage.string as NSString).substring(to: min(200, storage.length))
        return head.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
    }

    private func resetHighlighter() {
        if storage.length <= Document.highlightLimit, let lexer = language.lexer {
            highlighter = Highlighter(lexer: lexer)
        } else {
            highlighter = nil
        }
    }

    func rename(to newURL: URL) {
        url = newURL
        language = Language.detect(newURL, firstLine: Document.firstLine(of: storage))
        resetHighlighter()
    }

    // MARK: NSTextStorageDelegate

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        let s = textStorage.string as NSString
        lines.update(edited: editedRange, delta: delta, in: s)
        let line = lines.line(at: editedRange.location)
        highlighter?.invalidate(fromLine: line)
        if highlighter == nil, textStorage.length <= Document.highlightLimit, language.lexer != nil { resetHighlighter() }
        onEdit?(line)
    }

    /// Replaces the whole text (reload from disk). Clears the undo history, which no longer matches.
    func replaceAll(with loaded: LoadedText) {
        lineEnding = loaded.lineEnding
        hasBOM = loaded.hasBOM
        readOnlyReason = loaded.readOnlyReason
        stamp = loaded.stamp
        storage.setAttributedString(loaded.storage)
        lines = loaded.lines
        highlighter?.reset()
        undo.removeAllActions()
        isDirty = false
        conflict = false
        deletedOnDisk = false
    }

    func applyFont() {
        storage.beginEditing()
        storage.addAttribute(.font, value: Theme.editorFont(size: Document.fontSize), range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
    }
}
