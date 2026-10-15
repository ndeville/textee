# CLAUDE.md - Textee

Textee is Nic's native macOS text editor: it replaces TextMate, mainly as the clipboard scratchpad behind Alfred `ca`. `SPEC.md` is the source of truth for what it does and why. Read it before you change behaviour.

## Layout

```
TexteeMac/Sources/   AppKit app, 1 file per area:
  AppDelegate        menus (MenuBuilder), URL scheme, file opening, text-system warm-up
  MainWindowController  window, tabs, saving, disk checks, status counts, find and quick-open wiring
  Document           1 open file: text storage, undo manager, line index, highlighter, disk stamp
  EditorView         banner + gutter + scroll view, colours on the visible lines
  EditorTextView     NSTextView subclass: multi-cursor, line commands, plain copy/paste
  Syntax             line lexers (Markdown, JSON, YAML, Python, shell) and the Highlighter
  TextBuffer         LineIndex (line starts + words per line), Counter, TextFile (load in 1 MB pieces, save), DiskStamp
  Bars               TabBar, StatusBar, EmptyView
  FindBar, QuickOpen, State (paths, state.json), Theme (Blackboard + blue chrome)
  Settings           settings.json (windowCorners, cornerRadius), reloaded on save; WindowCorners, AppWindow, AppPanel
  QAHarness          JSON-scripted QA (TEXTEE_QA), Clip (pasteboard), Profile (launch marks)
project.yml          XcodeGen project. The .xcodeproj is generated: don't edit it.
qa.py                End-to-end QA on fixture copies in $TMPDIR/textee-qa
bench.py, bench/     Textee vs TextMate, CotEditor, Sublime Text, TextEdit from outside (appprobe.swift); bench/results.json
bench_chart.py       Draws bench/results.json as bench/editors.svg (NicAI heat map, fonts embedded)
screenshots.py       README screenshots (assets/screenshots/) from made-up files in /Users/Shared/Textee
```

## Commands

```bash
./build.sh               # Release build into build.noindex/Textee.app, signed with .private/signing.env (else ad hoc)
./build.sh --install     # also quit the running copy and install /Applications/Textee.app
./build.sh --icon        # redraw the icon (NicAI generator, blue gradient plate)
python3 qa.py            # every QA suite, about 30 s, in the background
python3 qa.py --only files --keep
python3 bench.py         # 5 editors, 7 rounds, about 20 min (quit CotEditor, Sublime Text, TextEdit first)
python3 bench.py --only Textee --textee build.noindex/Textee.app   # a build, before you install it
python3 bench_chart.py   # bench/editors.svg from the results
python3 screenshots.py   # README screenshots, about 5 s
```

## Git

Public repo: github.com/ndeville/textee (MIT). `.private/` (signing identity) and `CLAUDE.local.md` are git-ignored. Commit and push after each change that passes QA. `bench.py` rewrites `bench/results.json` even with `--only`: restore it before a commit unless the run is meant to replace the published numbers.

## Safety rules

- QA never touches `~/txt`, `~/.textee` or the clipboard: qa.py sets `TEXTEE_TXT_DIR`, `TEXTEE_HOME` and `TEXTEE_PASTEBOARD` to fixtures and a private pasteboard.
- `TEXTEE_READONLY=1` blocks every write, for timing runs on real files.
- Every save goes through `TextFile.write`: atomic replace, refuses when the file changed since load, and auto-save refuses to write an empty buffer over content (`⌘S` can).
- Use `Clip` for every pasteboard read or write, never `NSPasteboard.general` directly.

## Environment variables

| Variable              | Effect                                                 |
| -                     | -                                                      |
| `TEXTEE_HOME`         | Config folder instead of `~/.textee`                   |
| `TEXTEE_TXT_DIR`      | Scratch folder instead of `~/txt`                      |
| `TEXTEE_PASTEBOARD`   | Named pasteboard instead of the general one            |
| `TEXTEE_READONLY`     | `1` blocks every write                                 |
| `TEXTEE_QA`           | Path to a QA script (JSON steps); see QAHarness        |
| `TEXTEE_QA_OUT`       | QA report, screenshots and launch profile folder       |
| `TEXTEE_QA_KEEP_OPEN` | `1` keeps Textee open after the QA script              |

## AppKit lessons (don't undo these)

- Views don't clip to their bounds since macOS 14: the editor painted over the tab bar. `clipsToBounds = true` on the editor, gutter and bars, and the editor view sits at the bottom of the z-order.
- Map text positions with `textView.visibleRect` and `convert(_:from:)`, never with the clip view's bounds: the text view's frame origin isn't always 0 in its clip view, and the gutter drew its numbers 500 pt too high.
- Call `breakUndoCoalescing()` before `shouldChangeText`, not after: NSTextView registers the undo there and merges it with the previous edit.
- AppKit closes an event's undo group when it finishes dispatching the event. QA steps aren't events, so QAHarness posts an application-defined event after each step; without it, every command after the first landed in 1 undo group.
- Colours are temporary attributes on the layout manager: no text-storage edits, so no undo entries and no fight with the emoji fallback font.
- `cacheDisplay` screenshots work in the background. `screencapture` needs Screen Recording, which the shell doesn't have.
- Don't call `NSApp.activate()` per opened file: LaunchServices activates the app already, and 1 activation per file made a 9-file open take 1.3 s. Only `textee://` URLs activate.
- `build.sh --install` quits a running Textee: Nic's open tabs close (they're saved, and there's no session restore).
- Memory and layout work grow with the window: Textee used 124 MB in a 2160 x 3809 window and 45 MB in 1200 x 900 for the same file. Amethyst tiles editor windows to any size, so `bench.py` pins every app to 1920 x 1080 before each launch and floats the editors in Amethyst during the run.
- Every `NSTextView` (TextKit 1 and 2) has a content layer that draws asynchronously, so AppKit creates a Metal context (`CA::CG::AccelRenderer`) in any editor app. Clearing `drawsAsynchronously` changes nothing in memory. The context itself isn't Textee's code: don't hunt for its creation again (checked 13th October 2026). What is open: a bare text view releases it within 2 s, and Textee keeps it (14th October, `output/261014-win-every-row/`).
- The full menu bar is built 0.1 s after launch (`MenuBuilder.installFullMenu`), not before the window: it cost 25 to 80 ms. QA builds it at once, because QAHarness presses keys through `NSApp.mainMenu`.
- Files load in 1 MB pieces straight into the `NSTextStorage` (`TextFile.decodeUTF8`). A Swift `String` of the whole file and `NSTextStorage(string:)` left 67 MB of freed but dirty memory on the 22 MB file. Keep the pieces.
- The word count lives in `LineIndex` (words per line, a line break ends a word), so an edit recounts only its own lines. `assertLineIndex` in QA checks it against a full recount.
- AppKit doesn't offer ⌥ + letter key presses to the menu: ⌥D typed ∂ while the Delete Line menu item showed ⌥D (found 14th October 2026). `EditorTextView.keyDown` finds the ⌥ menu item and sends its action itself. QA's `key` op calls the menu directly and missed this; the `keyEvent` op hands a real key event to the text view.
- Square window corners: AppKit asks the window for `_cornerMask` (private) and uses the answer only when the window's own class overrides it. Every window must be an `AppWindow` and every panel an `AppPanel`: a plain `NSWindow(` or `NSPanel(` stays rounded. Rounded returns `nil`, never AppKit's own mask (its radius is smaller). Swizzling `NSWindow` does nothing. Tested in Filee, 14th October 2026; QA's `corners` suite checks it.
- macOS 26 asks the user to confirm a default-app change: `duti -s` and `NSWorkspace.setDefaultApplication` return success and change nothing until Nic clicks the prompt.
