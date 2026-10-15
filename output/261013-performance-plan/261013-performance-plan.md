---
title: Textee performance plan
date: 2026-10-13
project: textee
status: Analysis only. No Textee code changed.
---

# Textee performance plan

Analysis of 13th October 2026: how Textee can win every row of the 5-editor benchmark, what else to optimise, and whether a rebuild in Rust is a good idea.

## Summary

- Textee wins 12 of 16 rows today. It loses 3 rows to TextEdit and 1 to TextMate.
- All 4 losses have measured causes in Textee's own code or in how it uses AppKit. The Swift language isn't one of them.
- Phase 1 (about 1 day, low risk) wins the TextMate row and makes the 2 narrow wins safe: 14 of 16 rows with high confidence.
- The 2 small-file memory rows against TextEdit can be closed only partly. Textee is already within about 7 MB of a bare AppKit text view 2 s after launch.
- A rebuild in Rust gives no gain if it keeps AppKit: I built the same minimal editor window in Swift and in Rust, and they measured the same. Rust helps only with a custom text engine, and that engine is a rewrite of months that would put 10 of the 12 wins at risk. My recommendation: don't rebuild in Rust.

## Where Textee stands

Benchmark of 13th October 2026, 7 rounds, every window at 1920 x 1080. Full results: `bench/results.json` and `bench/editors.svg`.

| Row                        | Textee   | Best rival        | Status       |
| -                          | -        | -                 | -            |
| 2 KB file: window visible  | 1,474 ms | TextEdit 1,267 ms | Lost, 16%    |
| Memory, 1 small file       | 47 MB    | TextEdit 27 MB    | Lost, 74%    |
| Memory, 2 MB Markdown      | 58 MB    | TextEdit 29 MB    | Lost, 2x     |
| Memory, 22 MB file         | 174 MB   | TextMate 162 MB   | Lost, 8%     |
| 22 MB file: window visible | 1,610 ms | Sublime 1,665 ms  | Won, by 3%   |
| App size                   | 1.0 MB   | TextEdit 1.1 MB   | Won, by 11%  |
| 10 other rows              | -        | -                 | Won, clearly |

## What I measured

I built an instrumented copy of Textee in the scratchpad, read its memory with `footprint` and `malloc_history`, and logged the time of each launch step. I also built 2 minimal apps (an `NSWindow` with a plain `NSTextView`, 1 in Swift and 1 in Rust) to find the AppKit floor. All copies are deleted. The Textee project is unchanged.

### 1. On small files, the extra memory is drawing buffers, not text

- Of Textee's 47 MB, about 25 MB is graphics: 7 to 15 MB of window drawing buffers (IOSurface) and 4 to 9 MB for a Metal context.
- Textee's heap (13 MB) is smaller than TextEdit's (16 to 17 MB).
- TextEdit releases almost all of its graphics memory about 1 s after launch. Textee keeps more of it.
- The same Textee launch varies by up to 10 MB from run to run, depending on whether a 2nd drawing buffer is still held when the probe measures.
- The Metal context comes from accelerated drawing (`CA::CG::AccelRenderer`). A layer in Textee's view tree turns it on. I haven't found which layer yet.
- 2 likely causes were tested and rejected: the multi-cursor overlay view (`CaretOverlay`), and `canDrawSubviewsIntoLayer` on the root view. Neither changed the memory.

The same-session comparison with the minimal apps (2 KB file, 7 rounds each, load average 12 to 15):

| App                 | Window visible | CPU    | Memory at settle | Memory 2 s later |
| -                   | -              | -      | -                | -                |
| Textee (bench copy) | 1,775 ms       | 388 ms | 49.1 MB          | 37.3 MB          |
| Minimal app, Swift  | 1,329 ms       | 285 ms | 21.4 MB          | 30.3 MB          |
| Minimal app, Rust   | 1,288 ms       | 287 ms | 21.7 MB          | 30.4 MB          |

2 things follow:

- The AppKit floor for 1 window with 1 text view is about 21 MB at settle and 30 MB 2 s later. TextEdit (27 MB) sits on that floor.
- Textee's own cost is about 28 MB at settle but only about 7 MB 2 s later. The benchmark measures at settle, when Textee still holds its extra buffers.

### 2. The 22 MB file holds 67 MB of freed memory that macOS doesn't get back

The 22 MB test file has 1,125 lines of about 20,000 characters each. 503 lines contain non-ASCII characters, so AppKit stores the text in UTF-16.

| Item                       | Size   | Cause                                                             |
| -                          | -      | -                                                                 |
| The text in UTF-16         | 52 MB  | AppKit's `NSTextStorage`: needed                                  |
| Freed memory still counted | 67 MB  | Temporary copies during the load: avoidable                       |
| Copy for the word count    | 45 MB  | `countInBackground` copies the whole text after 0.3 s: avoidable  |
| Glyph storage              | 10 MB  | TextKit 1 lays out very long paragraphs                           |
| Line index                 | 4.4 MB | `reserveCapacity(length / 40)`: room for 562,000 lines, not 1,125 |
| Drawing buffers            | 15 MB  | 2 IOSurfaces                                                      |

- The 67 MB is the 22 MB Swift `String` from `TextFile.load` plus a 45 MB conversion buffer that `NSTextStorage(string:)` makes.
- `malloc_zone_pressure_relief` after the load gave back only about 10 MB.
- TextMate wins this row with 162 MB. It holds 55 MB in large allocations.

### 3. About 450 ms of the launch is Textee's own work

The minimal apps show their window about 450 ms before Textee in the same conditions. Textee's launch, from the instrumented copy (typical values over 5 launches):

| Step                                                   | Time          | Textee's work |
| -                                                      | -             | -             |
| macOS loads the program                                | 60 ms         | No            |
| AppKit starts (`NSApplication.shared`)                 | 270 to 610 ms | No            |
| Create the window                                      | 70 to 140 ms  | Yes           |
| Restore the saved window frame (`setFrameUsingName`)   | 25 to 90 ms   | Yes           |
| Build the menus                                        | 25 to 80 ms   | Yes           |
| AppKit finishes launching, the open-file event arrives | 95 to 190 ms  | Mostly no     |
| Open the file                                          | 20 to 58 ms   | Yes           |
| Draw the first frame, including the Metal context      | 90 to 120 ms  | Partly        |

The minimal apps order their window front before `app.run()`, so they don't wait for AppKit to finish launching. Textee shows its window only when the open-file event arrives, after `finishLaunching`. That wait is the largest single difference that isn't AppKit's own start-up.

### 4. The program file is half symbols

- The Textee binary is 765 KB. Its code (`__TEXT`) is 377 KB. Most of the rest is 3,106 symbols and the code signature.
- The icon (`AppIcon.icns`) is 236 KB.
- `project.yml` already sets `-O` and `DEAD_CODE_STRIPPING`, but the release build doesn't strip symbols.

## The plan

### Overview

| #  | Change                                            | Rows it moves                    | Effort  | Risk   |
| -  | -                                                 | -                                | -       | -      |
| 1  | Stream the file into the text storage, 1 pass     | 22 MB memory, Markdown memory    | 0.5 day | Low    |
| 2  | Exact line index                                  | 22 MB memory                     | 10 min  | None   |
| 3  | Incremental word count, no snapshot               | 22 MB memory, CPU after edits    | 2 h     | Low    |
| 4  | Minimal menu at launch, full menu after 1st frame | 2 KB window visible              | 1 h     | Low    |
| 5  | Strip symbols, smaller icon                       | App size                         | 30 min  | Low    |
| 6  | Find and remove the accelerated-drawing layer     | Every memory row, window visible | 0.5 day | Medium |
| 7  | Release drawing buffers when idle or hidden       | Small and Markdown memory        | 1 day   | Medium |
| 8  | Deferred window, frame from `state.json`          | 2 KB window visible              | 2 h     | Medium |
| 9  | Show big files after the 1st screenful            | 22 MB window visible             | 1 day   | Medium |
| 10 | TextKit 2                                         | Small-file memory, maybe         | Weeks   | High   |
| 11 | UTF-8 text storage                                | 22 MB memory                     | Weeks   | High   |

Items 1 to 5 are Phase 1. Items 6 to 9 are Phase 2. Items 10 and 11 are Phase 3, which I don't recommend.

### Phase 1: low risk, high certainty

#### 1. Stream the file into the text storage in 1 pass

Read the memory-mapped file in 1 MB pieces. Decode each piece, append it to `NSTextStorage` inside 1 `beginEditing` / `endEditing` pair, and in the same pass find the line starts, count the words, and detect CRLF. Cut each piece at a line end so a multi-byte character and a CRLF pair are never split.

- **Gain:** 22 MB file from 174 MB to about 105 to 115 MB. About 6 MB less on the Markdown file. The load gets faster because it reads the text once instead of several times.
- **Pros:** Wins the TextMate row by about 30%. The word count is ready at once, with no background pass.
- **Cons:** About 80 lines change in `TextFile.load`, `Document.init`, and `Counter`. The QA suite needs new cases: a multi-byte character at a piece boundary, CRLF at a boundary, an invalid UTF-8 file, an empty file.
- **Risk:** Low. The QA suite already covers loading and saving end to end.

#### 2. Exact line index

Count the line ends first, or grow the array as needed. Optionally store `UInt32` offsets, which halves the index for any file under 4 GB.

- **Gain:** 4.4 MB on the 22 MB file. Nothing on normal files.
- **Pros:** 1 line of code.
- **Cons:** None.

#### 3. Incremental word count

Keep a word count per line and update only the lines that an edit touches. Remove the 0.3 s background recount that copies the whole text.

- **Gain:** No 45 MB peak after each edit of a big file. Less CPU after each edit.
- **Pros:** The status bar is right at once, on every file size.
- **Cons:** A word that spans an edit boundary needs care. The QA suite needs a test that compares the incremental count with a full count after random edits.

#### 4. Minimal menu at launch

At launch, set a main menu with only the items whose key equivalents must work at once (`⌘Q`, `⌘S`, `⌘W`, `⌘N`, `⌘O`, `⌘V`). Build the full menu bar after the first frame.

- **Gain:** 25 to 80 ms to the window.
- **Pros:** Simple. Nothing changes after the first 0.1 s.
- **Cons:** For about 0.1 s after launch, the other shortcuts don't work.

#### 5. Strip symbols and shrink the icon

Set `DEPLOYMENT_POSTPROCESSING` and `STRIP_INSTALLED_PRODUCT` for Release, or run `strip -x` in `build.sh` before signing. Keep the dSYM. Rebuild the icon set without the sizes macOS doesn't use.

- **Gain:** App from 1.0 MB to about 0.6 to 0.7 MB.
- **Pros:** Turns the narrow size win into a clear one.
- **Cons:** Crash logs need the dSYM to show function names. Keep it next to each build.

### Phase 2: measure first, medium risk

#### 6. Remove accelerated drawing

Find the layer that creates the Metal context. Candidates: the banner, which sets `wantsLayer` and a layer `backgroundColor`, the gutter, and the tab bar. Draw that view in `draw(_:)` instead, or set `canDrawConcurrently` and `drawsAsynchronously` to off.

- **Gain:** 4 to 9 MB on every memory row, and 30 to 60 ms to the first frame.
- **Pros:** The only change that helps the window-visible row and all 4 memory rows.
- **Cons:** Scrolling of very large files can get slower without GPU drawing. Time a scroll through the 22 MB file before and after.
- **Risk:** Medium, until the layer is found.

#### 7. Release drawing buffers when idle or hidden

When the window is in the background, or has been idle for some seconds, let AppKit drop its backing stores. Options to test: hide and show the content view's layer, or set the layer contents to `nil` and mark the view for display when it comes back.

- **Gain:** Up to 15 MB on the small-file and Markdown rows, if the benchmark measures after idle.
- **Pros:** The only way I see to reach TextEdit's small-file memory without TextKit 2.
- **Cons:** AppKit has no public setting for this, so the code relies on observed behaviour that a macOS update can change. A short redraw follows when you come back to the window.
- **Risk:** Medium. Test after each macOS update.

#### 8. Deferred window and Textee's own frame

Create the window with `defer: true`, and read its frame from `state.json` instead of `setFrameUsingName`. Investigate whether the open-documents event can be handled before `finishLaunching` ends.

- **Gain:** 30 to 120 ms to the window.
- **Pros:** Fewer round trips to the window server during launch.
- **Cons:** Textee must then move a window that is off screen (for example after a display is unplugged) back onto a visible screen. AppKit does this today.

An option I don't recommend: show the window before the file arrives, as the minimal apps do. It would win the window-visible row, but you would see an empty window for about 150 ms first. That improves the metric, not the experience.

#### 9. Show big files after the 1st screenful

For files over 1 MB, show the window after the 1st piece from item 1, and append the rest after it is visible.

- **Gain:** 22 MB file window from 1,610 ms to about 1,400 ms.
- **Pros:** The narrow win over Sublime Text becomes clear.
- **Cons:** The editor must be read-only, and find and save must wait, until the load ends (about 0.5 s). The gutter and scroll bar change size while the rest arrives.

### Phase 3: not recommended

#### 10. TextKit 2

TextEdit uses TextKit 2 and is the reason the small-file memory rows are hard.

- **Gain:** Possibly TextEdit's small-file memory.
- **Cons:** CotEditor uses TextKit 2 and was the slowest app on big files (22 MB file: 2,844 ms to the window, 290 MB). The move would put 10 of Textee's wins at risk to gain 2 rows. It rewrites the editor, gutter, colouring, and multi-cursor code.

#### 11. UTF-8 text storage

Subclass `NSTextStorage` with a UTF-8 store and a map from UTF-16 offsets to bytes.

- **Gain:** About 25 MB on the 22 MB file.
- **Cons:** AppKit asks for UTF-16 characters many times per keystroke. Each lookup then goes through the map, so typing gets slower. Bugs in the map corrupt text.

## Expected result

| Row                        | Now      | After Phase 1 | After Phase 2     | Confidence |
| -                          | -        | -             | -                 | -          |
| Memory, 22 MB file         | 174 MB   | 105 to 115 MB | 95 to 110 MB      | High       |
| App size                   | 1.0 MB   | 0.6 to 0.7 MB | 0.6 to 0.7 MB     | High       |
| 22 MB file: window visible | 1,610 ms | 1,550 ms      | about 1,400 ms    | Medium     |
| 2 KB file: window visible  | 1,474 ms | 1,420 ms      | 1,250 to 1,350 ms | Medium-low |
| Memory, 2 MB Markdown      | 58 MB    | 52 MB         | 35 to 45 MB       | Low        |
| Memory, 1 small file       | 47 MB    | 47 MB         | 30 to 38 MB       | Low        |

With Phase 1, Textee wins 14 of 16 rows with high confidence. Phase 2 can win the launch row. The 2 small-file memory rows depend on item 7, and TextEdit is already at the AppKit floor, so a win there isn't certain.

## Improvements to the benchmark

- Measure memory twice: at settle, and 2 s later. Textee drops from 49 to 37 MB in those 2 s. The current result depends on when the probe looks.
- Add a "text visible" time next to "window visible", so a blank window can't win the launch rows. This needs Screen Recording permission for the probe.
- Run on a quiet Mac. The load average was 9 to 15 during today's runs.
- Measure typing latency, the number that matters most in daily use. It needs Accessibility permission for the probe.
- State in the chart that TextEdit doesn't colour syntax and that its plain-text mode does less work per line.

## Other improvements

These don't show in the benchmark:

- Replace the 2 s disk check with a file watcher (`DispatchSource` on a kqueue). This removes the remaining wake-ups while Textee is active. Set the watcher again after each atomic save, because the save replaces the file.
- Release the editor views of tabs you haven't used for some minutes, and keep their text. This saves memory with many tabs open. A return to such a tab costs about 15 to 20 ms.
- Run `malloc_zone_pressure_relief` after a big file closes, so macOS gets the memory back at once.

## Would a rebuild in Rust help?

Short answer: no. Rust is a good language for an editor, but Textee's losses don't come from Swift.

### The experiment

I wrote the same minimal app twice: an `NSApplication`, a 1920 x 1080 `NSWindow`, and an `NSTextView` that shows the 2 KB test file. The Swift version uses AppKit directly. The Rust version uses the `objc2`, `objc2-foundation`, and `objc2-app-kit` crates (0.6 and 0.3), built with LTO and stripped. The sources are in `build/` next to this file.

| Measure (2 KB file, 7 rounds) | Swift    | Rust     |
| -                             | -        | -        |
| Window visible                | 1,329 ms | 1,288 ms |
| CPU to settle                 | 285 ms   | 287 ms   |
| Memory at settle              | 21.4 MB  | 21.7 MB  |
| Memory 2 s later              | 30.3 MB  | 30.4 MB  |
| Program file                  | 55 KB    | 336 KB   |

The difference in launch time is within the noise of the run. The memory is the same. The cost is AppKit's, and the language that calls AppKit doesn't change it.

A 2nd run with the 22 MB file showed the same pattern, plus 1 trap: the Rust version used 16 MB more, because the `String` it read stayed alive for the whole run. Rust frees memory when the owner goes out of scope, and `main` never ends in an AppKit app. Rust prevents some bugs, not this kind of waste.

### 3 ways to use Rust

#### A. Rewrite Textee in Rust on AppKit (`objc2`)

- **Effect on the benchmark:** None measurable, per the experiment. App size gets worse: the Rust standard library adds about 300 KB before any Textee code, so I estimate 1 to 2 MB, and the size row is lost.
- **Effort:** Textee is 4,191 lines of Swift in 14 files. In Rust, every AppKit call is `unsafe`, and each subclass (`EditorTextView`, the delegates) needs the `define_class!` macro. Expect about 1.5x the code and 1 to 2 weeks of work.
- **Verdict:** All cost, no gain.

#### B. Keep Swift and AppKit, and move the core to a Rust library

The line index, the lexers, the word count, and the search would move to Rust, and Swift would call them through a C interface.

- **Effect on the benchmark:** None. Textee already wins every CPU row, by 13% (2 KB launch) to 7x (idle). The memory losses are in `NSTextStorage` and the graphics buffers, which stay in AppKit.
- **Cons:** 2 build systems (Cargo and XcodeGen), a C interface to maintain, and text copies at each call between the 2 languages, which cost memory.
- **Verdict:** No gain.

#### C. Rewrite in Rust with its own text engine and renderer

This is the only option where Rust could change the numbers. Textee would keep the text in a UTF-8 rope (the `ropey` crate), lay out only the visible lines, and draw with Metal through a toolkit such as GPUI (Zed's framework), Floem (Lapce), or a custom renderer.

| Row                        | Expected effect                                                        |
| -                          | -                                                                      |
| Memory, 22 MB file         | About 60 to 80 MB. A clear win: no UTF-16 copy, no TextKit glyph store |
| 22 MB file: window visible | Faster: no TextKit layout of 20,000-character lines                    |
| Memory, 1 small file       | Likely worse: 3 Metal drawables of 8.3 MB each, plus a glyph atlas     |
| 2 KB file: window visible  | Same or worse: AppKit still starts, and Metal adds a device setup      |
| Idle CPU and wake-ups      | At risk: a render loop must sleep fully when nothing changes           |
| App size                   | Worse: several MB for the toolkit, the shaper, and the font code       |
| CPU rows                   | Same. Textee already wins them                                         |

Sublime Text draws its own UI in the same way. In the benchmark it used 208 MB on the 2 KB file (with its plugin host processes) and 242 MB on the 22 MB file. A custom renderer doesn't make an editor small by itself.

What Textee would have to rebuild, because `NSTextView` gives it today:

- Text input methods: dead keys and press-and-hold for French accents, the emoji picker, and dictation (`NSTextInputClient`).
- Font fallback for emoji and other scripts, and right-to-left text.
- Selection, the mouse, scrolling, and the caret.
- Undo grouping, spell check, the Services menu, and VoiceOver.

The toolkits named here support these to different degrees, and their support is younger than AppKit's. Text input for accented characters must be perfect for your daily use.

- **Effort:** Months, not weeks. Zed's text and UI layer is the work of a full team over years.
- **Gain:** 1 row (22 MB memory) clearly, 1 row (22 MB window) more clearly. Possible losses on the small-file rows, idle, and size.
- **Note:** A custom engine in Swift would give the same memory gains. The engine makes the difference, not the language.

### When Rust would make sense

- Textee must run on Linux or Windows too.
- Textee must open files of 100s of MB, for example as a log viewer, where only a rope and visible-line layout keep memory flat.
- You want to share the text core with a command-line tool.

None of these is a goal today. The plan in the previous sections closes the gaps that matter, in Swift, in about 3 to 4 days.

## Implemented (13th October 2026, evening)

Nic asked for the recommended changes: Phase 1, the investigation of item 6, and the benchmark change.

| #  | Change                                     | Result                                                                  |
| -  | -                                          | -                                                                       |
| 1  | Stream the file into the text storage      | Done: `TextFile.decodeUTF8`, 1 MB pieces, lines and words in that pass  |
| 2  | Exact line index                           | Done: the load counts the line breaks first and reserves exactly that   |
| 3  | Incremental word count                     | Done: words per line in `LineIndex`, no background copy                 |
| 4  | Minimal menu at launch                     | Done: the full menu bar is built 0.1 s after launch                     |
| 5  | Strip symbols                              | Done: binary 765 KB to 520 KB. The icon was left: its PNGs are compact  |
| 6  | Remove accelerated drawing                 | Dropped: AppKit's, not Textee's (details below)                         |
| -  | Benchmark: memory at settle and 2 s later  | Done: 3 new rows in `bench.py` and `bench_chart.py`                     |
| -  | Benchmark: measure a build before install  | Done: `bench.py --textee <app>`                                         |

QA: 213 checks, 212 passed. The 1 failure is the launch budget (own work 186 ms against 150 ms) at a load average of 12 to 16. 3 repeats gave 128, 249 and -17 ms, so this is load noise, not a regression. New checks cover a character split by a piece boundary, a CR and LF split by a boundary, an invalid byte after 2 MB, an empty file, and the word count after an edit and an undo in a 2.6 MB file.

### Item 6: what I found

- Every `NSTextView`, TextKit 1 and TextKit 2, has an internal content layer with `drawsAsynchronously` on. That layer is why AppKit creates the Metal context, in a minimal 15-line app as much as in Textee.
- Turning the flag off on that layer changed nothing: the same IOSurface, IOAccelerator, and graphics memory, in 4 runs.
- Textee's own layer (the banner) isn't involved. Items 7 and 8 stay open, but I expect little from them: Textee drops to within about 7 MB of a bare AppKit text view 2 s after launch.

### Before and after

`bench.py --only Textee`, installed build against the new build, back to back, 7 rounds each, load average 8 to 10. Both runs had a 1920 x 2129 window (Amethyst tiled it), so memory is higher than in the morning run for both builds.

| Measure                          | Before   | After    | Change | Best rival, morning run |
| -                                | -        | -        | -      | -                       |
| 2 KB file: window visible        | 1,460 ms | 1,307 ms | -10%   | TextEdit 1,267 ms       |
| 22 MB file: window visible       | 1,637 ms | 1,564 ms | -4%    | Sublime Text 1,665 ms   |
| 2 MB Markdown file: work done    | 1,705 ms | 1,516 ms | -11%   | TextEdit 1,803 ms       |
| Memory, 22 MB file               | 190 MB   | 124 MB   | -35%   | TextMate 162 MB         |
| Memory, 22 MB file, 2 s later    | 171 MB   | 105 MB   | -39%   | -                       |
| Memory, 2 MB Markdown file       | 68 MB    | 60 MB    | -12%   | TextEdit 29 MB          |
| Memory, 1 small file             | 57 MB    | 57 MB    | 0%     | TextEdit 27 MB          |
| App size                         | 0.97 MB  | 0.74 MB  | -24%   | TextEdit 1.09 MB        |

What this means for the 16 rows:

- **Now clear wins:** memory with the 22 MB file (124 MB in a taller window against TextMate's 162 MB), app size (0.74 against 1.09 MB), and the 22 MB window (6% ahead instead of 3%).
- **Too close to call:** the 2 KB launch, 1,307 ms against TextEdit's 1,267 ms from another run. Only a 5-app run under the same load can settle it.
- **Still lost:** memory with 1 small file and with the 2 MB Markdown file. Both are AppKit's drawing buffers.

A full 5-app run needs TextEdit closed: it had 3 documents open, so I didn't quit it.

## Recommendation

1. Do Phase 1 now (about 1 day). It wins the TextMate memory row and makes both narrow wins clear.
2. Spend half a day on item 6 (accelerated drawing). Its result decides whether items 7 and 8 are worth doing.
3. Change the benchmark to measure memory at settle and 2 s later before the next published run.
4. Leave Phase 3 and the Rust rebuild alone.

## Method and files

- Benchmark: `bench.py` and `bench/appprobe.swift` in the Textee project. Results of 13th October 2026 in `bench/results.json`.
- Instrumented Textee copy: built in the scratchpad from the current sources, with launch marks and memory dumps. Deleted after use.
- Minimal apps: `build/minisw.swift`, `build/minirust/`, and the runner `build/compare.py`, next to this file. The runner needs the bench fixtures in `$TMPDIR/textee-bench/files` and the Textee bench copy, which `bench.py` creates.
- All runs: Mac Studio, macOS 26, displays at 1x scale, load average 9 to 15.
