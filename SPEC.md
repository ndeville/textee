# Textee - specification and build plan (v1)

Status: v1 built and QA'ed, 12th October 2026. Installed at `/Applications/Textee.app`.

Textee is a native macOS text editor that replaces TextMate. Its main job is the clipboard scratchpad: Alfred `ca` puts the clipboard in a new `~/txt` file and shows it in a Textee tab. It also edits any text file, with tabs, line numbers, live counts and colours for Markdown, JSON, YAML, Python and shell.

The 2 design goals, in order:

1. **Speed.** Open, paste, type and close without a perceptible wait.
2. **Low memory.** Less than TextMate uses today for the same work.

---

## 1. How Nic used TextMate (12th October 2026)

- The Alfred keyword `ca` (workflow **Clipee Text**) wrote the clipboard to `~/txt/YYMMDD-HHMMSS.txt` and opened it in TextMate: 3,144 files since April 2025, about 8 a day, 95% never edited after the first hour.
- 24% of those `.txt` files hold Markdown (LLM answers). Sizes: median 492 bytes, 99th percentile 199 KB, largest 22 MB. All UTF-8, 191 with CRLF.
- TextMate settings: 14 pt, Blackboard, save on focus loss, no session restore, no new document at launch.
- Add-ons that Textee makes unnecessary: the `⌃⌘N` word count command and the Hammerspoon character-count overlay.
- TextMate used 92 MB with 3 small files open.

## 2. Decisions (Nic, 12th October 2026)

| #  | Question                     | Decision                                                                 |
| -  | -                            | -                                                                        |
| 1  | Relation to Notee            | Separate app                                                             |
| 2  | Code sharing with Notee      | None: Textee is optimised on its own for its sole purpose                |
| 3  | Tabs                         | Whatever is fastest: custom tab bar, 1 window, 1 editor view per tab     |
| 4  | Scratch flow                 | `textee://new-from-clipboard`: Textee writes the file itself             |
| 5  | `⌘N`                         | Empty timestamped file in `~/txt`, created at once                       |
| 6  | Markdown colours             | `.md` files only (Markdown inside `.txt` stays plain)                    |
| 7  | Other formats                | Colours for JSON, YAML, Python, shell, as long as speed doesn't suffer   |
| 8  | Keys                         | 1 set of keys, shared with Notee                                         |
| 9  | Text theme                   | Blackboard                                                               |
| 10 | Session restore              | Off                                                                      |
| 11 | Character count              | What LinkedIn counts (posts and invitations)                             |
| 12 | Quick open over `~/txt`      | Version 1                                                                |
| 13 | Preview                      | None: **Open in Notee** instead                                          |
| 14 | `.md` double-click           | Stays with Notee                                                         |
| 15 | Name and icon                | Textee, NicAI icon layout                                                |
| -  | Colour scheme                | Blue, icon included                                                      |

## 3. Technology

| Layer           | Choice                                                                 |
| -               | -                                                                      |
| Language and UI | Swift 6.3 (Swift 5 mode), AppKit, no third-party code                  |
| Text engine     | `NSTextView` on TextKit 1, non-contiguous layout                       |
| Tabs            | 1 window. Each tab keeps its own editor view: a switch swaps 2 views   |
| Line numbers    | `Gutter` view, draws the visible lines only, from `LineIndex`          |
| Line index      | UTF-16 offsets of every line start and the words on each line          |
| Loading         | 1 MB pieces straight into the text storage; lines, words in that pass  |
| Colours         | Line lexers + temporary attributes on the visible lines (no undo cost) |
| Counts          | Words and LinkedIn characters; an edit recounts only its own lines     |
| Saving          | Atomic replace, conflict check, line endings and BOM kept              |
| Config          | `~/.textee/state.json` (recent files, zoom, wrap, line numbers)        |
| Settings        | `~/.textee/settings.json`, Nic's own, read only (section 4.6)          |
| Build           | XcodeGen `project.yml`, Developer ID, `build.sh --install`             |

### 3.1 Character count

LinkedIn publishes no counting rule. Buffer's developer guide says LinkedIn counts UTF-16 code units, so Textee counts the same way: an emoji counts 2, a line break 1. Some sources say LinkedIn counts an emoji as 1; UTF-16 is the safe side, it never under-counts.

The status bar shows the count in green up to 300 (fits an invitation note) and in amber over 3,000 (the post limit).

## 4. Features

### 4.1 Files

- **New Scratch File** (`⌘N`): creates `~/txt/YYMMDD-HHMMSS.txt` (`-2`, `-3` when the second is taken) and opens it. A file that is still empty when its tab closes is deleted.
- **New from Clipboard** (`⇧⌘N`, `textee://new-from-clipboard`): the same, with the clipboard text, written at once.
- **Auto-save** 1 s after the last keystroke, on tab switch, when Textee loses focus, on close and on quit.
- **Atomic write** with the original's metadata. Line endings: a CRLF-only file is edited as LF and saved as CRLF; a mixed file is saved exactly as it is. A BOM stays; Textee never adds one.
- **Changes on disk** (checked every 2 s while Textee is active, and on activation): no unsaved edits, reload in place; unsaved edits, a banner with **Take Disk Version** and **Keep Mine**. A deleted file gets **Save Again** and **Close**.
- Auto-save never writes over a conflict, and never writes an empty buffer over a file with content (`⌘S` does).
- A file that isn't valid UTF-8 opens read-only, with a banner.

### 4.2 Editor

- Blackboard colours, with a stronger blue selection (`#1D4ED8`, the status bar blue). SF Mono 14 pt, zoom with `⌘=` / `⌘-` / `⌘0`.
- Line numbers, current line band, soft wrap (`⌥Z` toggles).
- Return keeps the indentation. Tab inserts 4 spaces, or indents the selected lines.
- Multi-cursor: `⌥↩` adds the next match, `⇧⌘A` selects every match, `⌥`-click adds a cursor, `Esc` goes back to 1.
- Copy and paste are plain text. With several cursors and as many clipboard lines, each cursor gets 1 line.

### 4.3 Colours

| Format     | Detected by                                                | Coloured                                                       |
| -          | -                                                          | -                                                              |
| Markdown   | `.md`, `.markdown`, `.mdown`, `.mkd`, `.mdx`               | Front matter, headings, bold, italic, code, fences, links, ... |
| JSON       | `.json`, `.jsonc`, `.geojson`                              | Keys, strings, numbers, `true`/`false`/`null`, comments        |
| YAML       | `.yaml`, `.yml`                                            | Keys, strings, scalars, anchors, comments                      |
| Python     | `.py`, `.pyw`, `.pyi`, or a `python` shebang               | Keywords, strings (triple too), decorators, def/class names    |
| Shell      | `.sh`, `.zsh`, `.bash`, `.command`, rc files, a shebang    | Keywords, builtins, strings, variables, comments               |
| Plain text | Everything else                                            | Nothing                                                        |

Files over 5 MB are never coloured.

### 4.4 Quick open (`⌘P`, also `⌘H`)

Recent files first, then every file in `~/txt`, newest first. Each row shows the first line of the file, its name and age. Typing searches names, first lines and content (files up to 512 KB; every word must match). A preview on the right shows the selected file. The content index exists only while the panel is open.

### 4.5 Find (`⇧⌘F`)

Find and replace in the current file: case on or off, regex with `$0` / `$1` templates, every match coloured, "n of m". `↩` next, `⇧↩` previous, **Replace**, **All** (1 undo step), `⌃F` or `Esc` closes.

### 4.6 Settings (`~/.textee/settings.json`)

Nic edits this file; Textee only reads it. A save applies at once, without a restart, and keeps the tabs and the selection. The same 2 keys exist in each of Nic's apps (Filee first, 14th October 2026), so he can compare square and rounded corners.

| Key             | Values                    | Default     | Sets                                                    |
| -               | -                         | -           | -                                                       |
| `windowCorners` | `"rounded"` or `"square"` | `"rounded"` | The window corners and shadow                           |
| `cornerRadius`  | 0 (square) to 10          | 4           | The tab highlights, the tab close button and quick open |

An unknown `windowCorners` reads as `"rounded"`, and `cornerRadius` stays inside 0 to 10. Each radius scales from its design value (`base * cornerRadius / 4`), so 4 changes nothing. Nic's file holds `"square"` and 0.

Square window corners use `_cornerMask`, a private AppKit method: if a later macOS stops calling it, the window stays rounded and nothing else breaks. A Mac App Store build would have to leave it out.

## 5. Keys

Menu titles are the standard ones (Copy, Paste, Find…), so Nic's global App Shortcuts apply. The same keys are also set in the menus, as in Notee.

| Key           | Command                          | Key           | Command                       |
| -             | -                                | -             | -                             |
| `⌘N`          | New scratch file                 | `⌘D`          | Copy                          |
| `⇧⌘N`         | New from clipboard               | `⌘F`          | Paste                         |
| `⌘O`          | Open…                            | `⌥F`          | Paste and Match Style         |
| `⌘P` / `⌘H`   | Quick open / recent files        | `⇧⌘F`         | Find…                         |
| `⌘S`          | Save now                         | `⌃F`          | Hide the find bar             |
| `⌥⌘S`         | Save As…                         | `⌘T`          | Duplicate line or selection   |
| `⌘W` / `⇧⌘W`  | Close tab                        | `⌥D`          | Delete line                   |
| `⌃⌘W`         | Close window (every tab)         | `⌥↑` / `⌥↓`   | Move line                     |
| `⌥⌘O`         | Open in Notee                    | `⌘]` / `⌘[`   | Indent / outdent              |
| `⌥⌘R`         | Reveal in Finder                 | `⌥↩`          | Add next match                |
| `⇧⌘D`         | Copy the path as `<path>`        | `⇧⌘A`         | Select all matches            |
| `⇧⌘]` / `⇧⌘[` | Next / previous tab              | `⇧⌘B`         | Markdown bold                 |
| `⌥Z`          | Soft wrap                        | `⌘=` `⌘-` `⌘0`| Zoom                          |

`⌘C`, `⌘V` and `⌘G` stay unbound, as in Notee.

## 6. Integration (done 12th October 2026)

- **Alfred `ca`**: the Clipee Text workflow now runs `open 'textee://new-from-clipboard'`. Backup: `~/ai/me/kb/261012-alfred-clipee-text-backup.plist`.
- **Default app** for `public.plain-text` and `.txt`: set with `duti`, confirmed by Nic in the macOS prompt (checked 12th October 2026: `duti -d public.plain-text` gives `com.nicolasdeville.textee`).
- TextMate stays installed. Not changed: Hammerspoon (`MONITOR_APPS`, the TextMate character-count overlay) and Amethyst's float list.

## 7. Measured (QA, 12th October 2026)

`python3 qa.py`: 7 suites, 193 checks, all passed. The Mac's load average was about 15 during the runs, so launch is measured against an empty AppKit app launched just before each suite.

| Metric                                         | Budget    | Measured |
| -                                              | -         | -        |
| Launch, minus an empty AppKit app (own work)   | < 150 ms  | 74 ms    |
| Launch, whole (load average about 15)          | -         | 361 ms   |
| `ca` with Textee running: URL to text in a tab | < 300 ms  | 13 ms    |
| Open a typical file                            | < 20 ms   | 7 ms     |
| Open the 22 MB file                            | < 1.5 s   | 258 ms   |
| Keystroke, with a full editor redraw           | < 5 ms    | 2.6 ms   |
| Keystroke in the 22 MB file                    | < 10 ms   | 3.1 ms   |
| Keystroke in a 2 MB Markdown file              | < 10 ms   | 6.4 ms   |
| Scroll the 22 MB file, per page                | < 16.7 ms | 0.5 ms   |
| Quick open: search 3,180 files by content      | -         | 31 ms    |
| Memory: 10 tabs                                | < 60 MB   | 41 MB    |
| Memory: 12 tabs + 22 MB + 2 MB files           | -         | 304 MB   |

The 1st launch after a build takes about 1 s: macOS checks the new code signature once.

## 8. Compared with other editors

### 8.1 Against TextMate (12th October 2026)

`python3 bench.py` measures both apps from outside, the same way, with `bench/appprobe` (no special permission):

- **Window on screen:** the first normal window of the new process appears.
- **Work done:** the process CPU time stops growing (under 2 ms in 300 ms).
- **CPU used** and **memory** (physical footprint) from `proc_pid_rusage`.

Nic's own TextMate keeps running untouched: the benchmark runs a copy, "TextMate Bench", with its own bundle id, ad hoc signed, and Nic's TextMate preferences copied in. Each app is launched with `open -n -g` and killed after each scenario. 5 rounds, alternating which app goes first; round 1 is a warm-up; the table shows the medians of rounds 2 to 5. Load average 11.6 to 12.6 during the run.

| Measure                                   | Textee   | TextMate | Ratio |
| -                                         | -        | -        | -     |
| Launch with a 2 KB file: window on screen | 1,273 ms | 1,707 ms | 1.3x  |
| Launch with a 2 KB file: work done        | 1,800 ms | 2,389 ms | 1.3x  |
| Launch with a 2 KB file: CPU used         | 370 ms   | 587 ms   | 1.6x  |
| Memory after launch, 1 file               | 49 MB    | 72 MB    | 1.5x  |
| Open 1 file in the running app: work done | 244 ms   | 707 ms   | 2.9x  |
| Open 1 file in the running app: CPU used  | 31 ms    | 153 ms   | 4.9x  |
| Open 9 more files: work done              | 327 ms   | 799 ms   | 2.4x  |
| Memory with 11 files open                 | 51 MB    | 75 MB    | 1.5x  |
| Idle 15 s with 11 files: CPU used         | 9 ms     | 13 ms    | 1.4x  |
| Idle: wake-ups per second                 | 0.7      | 0.8      | 1.1x  |
| Launch with the 22 MB file: window        | 1,703 ms | 1,580 ms | 0.9x  |
| Launch with the 22 MB file: work done     | 2,209 ms | 3,885 ms | 1.8x  |
| Launch with the 22 MB file: CPU used      | 669 ms   | 1,982 ms | 3.0x  |
| Memory with the 22 MB file                | 177 MB   | 178 MB   | 1.0x  |
| Launch with a 2 MB Markdown file: done    | 1,768 ms | 9,327 ms | 5.3x  |
| Launch with a 2 MB Markdown file: CPU     | 365 ms   | 8,207 ms | 22.5x |
| Memory with the 2 MB Markdown file        | 60 MB    | 196 MB   | 3.3x  |
| App size on disk                          | 1.0 MB   | 37.6 MB  | 38x   |

How to read it:

- Wall-clock times include about 1 s of macOS work for `open -n` on a loaded Mac, the same for both apps. CPU time is the steadier measure.
- TextMate shows the window of a 22 MB file sooner, then keeps loading and parsing in the background. Textee shows the window once the file is in it.
- TextMate parses the whole Markdown file for its grammar; Textee colours only the lines on screen. That's the 22x.
- Not compared: typing latency. Sending key presses to TextMate needs the Accessibility permission, which the shell doesn't have. Textee's own QA measures 2.6 ms per keystroke with a full redraw.
- The first run of the benchmark found a Textee bug: it activated itself once per opened file, and 9 files took 1.3 s. Fixed the same day (files no longer activate; only `textee://` does).

### 8.2 Against CotEditor, Sublime Text and TextEdit too (13th October 2026)

`python3 bench.py` now runs 5 apps, 7 rounds, every app in every slot in turn; the table shows the medians of rounds 2 to 7. `python3 bench_chart.py` draws the same data as `bench/editors.svg` (the chart in the Textee note). Load average 13 to 9.

- Textee and TextMate run as bench copies, so Nic's running apps stay open. CotEditor, Sublime Text and TextEdit run from where they're installed and must be closed. Sublime Text gets a copy of Nic's data folder with an empty session; the original is put back at the end.
- Every app opens a 1920 × 1080 window. The first 5-app run didn't pin the windows: Amethyst had left them between 673 × 439 (TextEdit) and 2160 × 3809 (CotEditor), and memory grows with the window. That run was thrown away.
- CPU, memory and threads include child processes (Sublime Text's plugin hosts). Bold = best, or within 5% of the best.

| Measure                        | Textee       | TextMate   | CotEditor | Sublime Text | TextEdit     |
| -                              | -            | -          | -         | -            | -            |
| Open 1 file in the running app | **200 ms**   | 1,140 ms   | 840 ms    | 577 ms       | 383 ms       |
| CPU for that open              | **30 ms**    | 160 ms     | 347 ms    | 108 ms       | 84 ms        |
| Open 9 more files              | **275 ms**   | 740 ms     | 3,729 ms  | 748 ms       | 835 ms       |
| 2 KB file: window visible      | 1,474 ms     | 1,828 ms   | 1,784 ms  | 1,754 ms     | **1,267 ms** |
| 2 KB file: CPU                 | **331 ms**   | 590 ms     | 741 ms    | 845 ms       | 375 ms       |
| 22 MB file: window visible     | **1,610 ms** | 1,852 ms   | 2,844 ms  | **1,665 ms** | 2,211 ms     |
| 22 MB file: work done          | **1,891 ms** | 3,689 ms   | 5,181 ms  | 2,371 ms     | 2,602 ms     |
| 22 MB file: CPU                | **643 ms**   | 1,885 ms   | 4,828 ms  | 1,256 ms     | 1,366 ms     |
| 2 MB Markdown: work done       | **1,609 ms** | 10,316 ms  | 6,152 ms  | 2,303 ms     | 1,803 ms     |
| 2 MB Markdown: CPU             | **366 ms**   | 9,182 ms   | 7,154 ms  | 1,275 ms     | 427 ms       |
| Memory, 1 small file           | 47 MB        | 55 MB      | 53 MB     | 208 MB       | **27 MB**    |
| Memory, 11 files               | **50 MB**    | 73 MB      | 249 MB    | 231 MB       | 62 MB        |
| Memory, 2 MB Markdown          | 58 MB        | 183 MB     | 252 MB    | 237 MB       | **29 MB**    |
| Memory, 22 MB file             | 174 MB       | **162 MB** | 290 MB    | 242 MB       | 193 MB       |
| CPU at idle, 15 s, 11 files    | **12 ms**    | 86 ms      | 166 ms    | 86 ms        | 521 ms       |
| App size                       | **1.0 MB**   | 38 MB      | 122 MB    | 112 MB       | 1.1 MB       |

Textee wins 12 of 16 rows; average distance from the best (geometric mean of value / best) 1.1x, TextEdit 1.7x, Sublime Text 3.5x, TextMate 3.7x, CotEditor 5.8x. TextEdit doesn't colour Markdown or code.

### 8.3 After the optimisation pass (13th October 2026)

The 1st phase of the plan in `output/261013-performance-plan/`: files load in 1 MB pieces, the word count lives in the line index, the full menu bar is built after launch, and the release binary is stripped. `bench.py --only Textee` ran the installed build and the new build back to back, 7 rounds each, load average 8 to 10. Both runs had a 1920 x 2129 window (Amethyst tiled it), so the memory numbers are higher than in 8.2 for both builds. Results: `bench/results-261013-textee-old.json` and `-new.json`.

| Measure                            | Before   | After    | Change |
| -                                  | -        | -        | -      |
| 2 KB file: window visible          | 1,460 ms | 1,307 ms | -10%   |
| 2 KB file: work done               | 1,874 ms | 1,720 ms | -8%    |
| 22 MB file: window visible         | 1,637 ms | 1,564 ms | -4%    |
| 22 MB file: work done              | 2,156 ms | 2,011 ms | -7%    |
| 2 MB Markdown file: work done      | 1,705 ms | 1,516 ms | -11%   |
| Memory, 22 MB file                 | 190 MB   | 124 MB   | -35%   |
| Memory, 22 MB file, 2 s later      | 171 MB   | 105 MB   | -39%   |
| Memory, 2 MB Markdown file         | 68 MB    | 60 MB    | -12%   |
| Memory, 2 MB Markdown, 2 s later   | 54 MB    | 47 MB    | -15%   |
| Memory, 1 small file               | 57 MB    | 57 MB    | 0%     |
| App size                           | 0.97 MB  | 0.74 MB  | -24%   |

Opening files, idle CPU and wake-ups didn't change. Small-file memory is AppKit's: every `NSTextView` creates a Metal context for its asynchronous content layer, and turning that off changes nothing.

## 9. Not built

- Spell check, snippets, folding, file tree, preview (Notee has them).
- Session restore (Nic's choice).
- Drag of a file onto the tab bar.
