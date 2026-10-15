---
title: Can Textee win every benchmark row?
date: 2026-10-14
project: Textee
status: draft plan, nothing built
follows: ../261013-performance-plan/261013-performance-plan.md
---

# Can Textee win every benchmark row?

## Summary

- **Not with confidence.** Textee now wins or ties 14 of the 16 published rows. The 2 rows it still loses (memory with 1 small file and with the 2 MB Markdown file, both to TextEdit) sit on the memory floor of AppKit itself.
- I measured that floor today. In the same session, a bare TextKit 2 text view (what TextEdit uses) needs 10 to 13 MB less at settle than a bare TextKit 1 text view (what Textee uses) with a small file. No amount of trimming inside Textee closes that gap while Textee stays on TextKit 1.
- TextKit 2 everywhere isn't the answer either: a bare TextKit 2 view needs 319 MB for the 22 MB file, 3 times Textee's 107 MB. It would lose the 22 MB memory row that Textee won yesterday.
- A text view of my own on Core Text isn't lighter than TextKit 2 on small files (26 MB against 23 to 25 MB), so it doesn't help either.
- The only route that can win all rows is a **hybrid**: TextKit 2 for small files and TextKit 1 for big ones. It costs 1 to 2 weeks, doubles the editor code that touches layout, and still only ties the Markdown row at best.
- **My recommendation:** do Phase A (2 to 3 days). It confirms the standings, removes 6 to 10 MB that Textee keeps and a bare text view gives back, and makes the launch row safe. Then decide on the hybrid with real numbers. I would not build it: 2 rows aren't worth a second editor.

## Where Textee stands now

The published chart is from the morning of 13th October 2026, before the optimisation pass. Textee's figures here come from the A/B run of 13th October (launch times) and from today's runs at the benchmark's window size (memory). Rivals are from the published chart.

The chart's rule: the best value, or within 5% of it, counts as a win.

| Row                          | Textee now       | Best rival        | Status                          |
| -                            | -                | -                 | -                               |
| 2 KB file: window visible    | 1,307 ms         | TextEdit 1,267 ms | Tie, 3% behind (different runs) |
| Memory, 1 small file         | 49 MB            | TextEdit 27 MB    | Lost, 1.8x                      |
| Memory, 2 MB Markdown        | 47-53 MB         | TextEdit 29 MB    | Lost, 1.7x                      |
| Memory, 22 MB file           | 107 MB           | TextMate 162 MB   | Won, by 34% (was lost)          |
| 22 MB file: window visible   | 1,564 ms         | Sublime 1,665 ms  | Won, by 6%                      |
| App size                     | 0.74 MB          | TextEdit 1.09 MB  | Won, by 32%                     |
| 10 other rows                | -                | -                 | Won, clearly                    |
| 3 new rows: memory 2 s later | 37 / 41 / 102 MB | Not measured yet  | Unknown: no rival figures       |

The 3 "2 s later" rows came with yesterday's benchmark change. No rival has been measured on them yet, so the real count is 14 of 16 published rows, plus 3 open rows.

## What I measured today

I built 4 minimal apps, each 1 window of 1920 x 1080 with 1 view that shows the file, and ran them against Textee in the same session. 4 to 6 rounds each, medians without round 1. Nothing in Textee changed.

| App     | What it is                                                                |
| -       | -                                                                         |
| MiniTK1 | `NSTextView` on TextKit 1, as in Textee                                   |
| MiniTK2 | `NSTextView` on TextKit 2, as in TextEdit and CotEditor                   |
| MiniCT  | No `NSTextView`: a plain view that draws the visible lines with Core Text |
| Textee  | The installed build (Phase 1 done), as a bench copy                       |

The Mac was very busy (load average 18 to 78: another process used 9 cores), so the times in these runs are noise. Memory is steady from round to round within a session.

### Memory at settle and 2 s later (MB)

| File          | Textee       | MiniTK1          | MiniTK2          | MiniCT      |
| -             | -            | -                | -                | -           |
| 2 KB text     | 49.3 / 37.4  | 34.6 / 27.8      | 24.0 / 23.5      | 26.0 / 26.0 |
| 2 MB Markdown | 47-53 / 40.5 | 32.4-33.0 / 29.6 | 30.0-30.6 / 29.3 | 31.4 / 27.7 |
| 22 MB text    | 107 / 102    | 136 / 139        | 319 / 306        | 75 / 72     |

### What the numbers say

1. **TextKit 2 is cheaper on small files, by 10 to 13 MB.** TextKit 1 draws the text view into 1 or 2 window-sized buffers (`IOSurface`, 8 MB each at 1920 x 1049). TextKit 2 draws each paragraph into its own small layer, so a short file needs about 2 to 4 MB of buffers. This is the TextEdit advantage, and it's built into AppKit.
2. **TextKit 2 is 3 times heavier on the 22 MB file.** It holds 155 MB in large allocations for the long lines (each line of that file is about 20,000 characters). Textee holds 10 MB.
3. **A custom Core Text view doesn't beat TextKit 2 on small files.** A plain view still needs a window-sized buffer (7.7 MB). It does avoid the Metal context, and it's the lightest on the 22 MB file (75 MB), but it can't edit: input methods, selection, undo, accessibility and spelling would all be new code.
4. **Textee keeps 9 to 11 MB more than a bare TextKit 1 view, 2 s after launch.** The bare view gives back its Metal context. Textee keeps it: 4 MB of graphics memory and 1.2 to 2.3 MB of Metal buffers. On the Markdown file it also keeps 3 MB more window buffers. Its heap is 2 to 3 MB bigger. Yesterday I concluded that the Metal context is AppKit's and can't be removed. That's still true at launch. What's new is that a bare view releases it within 2 s, and Textee doesn't.
5. **The floor moves between sessions.** In a 3rd session, the same bare TextKit 1 view measured 49 MB, not 35 MB, and TextKit 2 36 MB, not 24 MB. The gap between them stayed at 13 MB. The benchmark measures memory at the moment CPU use settles, when some apps still hold a 2nd buffer. A 1-run comparison of memory at settle is partly luck.
6. **A text view only as tall as its text doesn't help.** I tried a TextKit 1 view that stops after the last line, with a coloured layer behind it. Same memory (49.3 against 49.4 MB): AppKit sizes the buffer to the visible area, not to the text.

### What it would take to win each lost row

| Row                   | Win needs (5% rule) | TextKit 1 floor | TextKit 2 floor | Verdict                                           |
| -                     | -                   | -               | -               | -                                                 |
| Memory, 1 small file  | 28.4 MB or less     | 34.6 MB         | 24.0 MB         | Only TextKit 2, with under 4 MB of Textee's own   |
| Memory, 2 MB Markdown | 30.5 MB or less     | 32.4 MB         | 30.0 MB         | Only TextKit 2, with under 0.5 MB of Textee's own |
| 2 KB file: window     | 1,330 ms or less    | -               | -               | Tie today; Phase A makes it safe                  |

The Markdown row is the hardest: even a bare TextKit 2 view only ties TextEdit there. Textee's colours, line index and menus add at least 1 to 2 MB, so a loss by a few percent is likely even after a hybrid.

## The plan

### Overview

| #  | Item                                          | Effort    | Gain                                              | Risk      | Recommend |
| -  | -                                             | -         | -                                                 | -         | -         |
| A1 | Rerun the 5-app benchmark on a quiet Mac      | 20 min    | The real standings, rival figures for 3 rows      | None      | Yes       |
| A2 | Find what keeps Textee's buffers and Metal    | 1 to 2 d  | 6 to 8 MB on every memory row at 2 s              | Low       | Yes       |
| A3 | Deferred window and Textee's own frame        | 0.5 d     | 30 to 120 ms on every launch row                  | Low       | Yes       |
| A4 | Smaller heap at launch                        | 0.5 d     | 1 to 3 MB on every memory row                     | Low       | Yes       |
| B1 | Hybrid: TextKit 2 below 5 MB, TextKit 1 above | 1 to 2 wk | Can win the small-file row; ties Markdown at best | High      | No        |
| X1 | TextKit 2 for every file                      | 1 to 2 wk | Same as B1 on small files                         | High      | No        |
| X2 | Own text view on Core Text                    | 4 to 8 wk | 22 MB memory only                                 | Very high | No        |
| X3 | Rust                                          | Months    | None (measured on 13th October)                   | Very high | No        |

### Phase A: low risk, 2 to 3 days

#### A1. Rerun the 5-app benchmark on a quiet Mac

Quit TextEdit, CotEditor and Sublime Text, then run `python3 bench.py` when the load average is under 10.

- **Gain:** Confirmed standings after Phase 1, and the first rival figures for the 3 "2 s later" rows. The 2 KB launch tie gets a real answer.
- **Pros:** No code change. It also refreshes the chart in the Textee note.
- **Cons:** About 20 minutes with 5 editors opening on the 3rd display.

#### A2. Find what keeps Textee's window buffers and Metal context

A bare TextKit 1 view gives back its 2nd buffer and its Metal context within 2 s. Textee keeps both. Something in Textee draws again after the first frame, or keeps a layer busy. Candidates, to test 1 at a time with the floors runner:

- The 2 s disk check and the status bar: a redraw every 2 s keeps the 2nd buffer alive.
- The gutter, which redraws on every bounds change.
- The banner view, the only Textee view that sets `wantsLayer` and a layer colour.
- The colour pass on the visible lines just after the file opens (Markdown).
- The caret overlay and the current-line highlight in `drawBackground`.

- **Gain:** 6 MB (small file) to 8 MB (Markdown) on the memory rows 2 s after launch, and part of it at settle. With A4, Textee reaches the bare TextKit 1 view: about 28 MB small and 30 MB Markdown, 2 s after launch.
- **Pros:** Every user of Textee keeps less memory, not only the benchmark. It brings the Markdown row at 2 s level with a bare text view.
- **Cons:** It doesn't win the 2 rows at settle on its own: the TextKit 1 floor is still above TextEdit. If the cause is AppKit timing and not Textee, the fix may not exist.
- **Risk:** Low. Each test is a launch and a `footprint` reading.

#### A3. Deferred window and Textee's own frame

Item 8 of yesterday's plan. Create the window with `defer: true` and read its frame from `state.json` instead of `setFrameUsingName`, which costs 25 to 90 ms.

- **Gain:** 30 to 120 ms on every launch row. The 2 KB launch goes from a 3% tie to a clear win, if A1 confirms 1,307 ms.
- **Pros:** Small change. It also helps every launch from Alfred.
- **Cons:** Textee must move a window that is off screen (after a display is unplugged) back onto a visible screen itself. AppKit does this today.

#### A4. Smaller heap at launch

Textee's heap is 1 to 3 MB bigger than a bare text view: the full menu bar, the theme, the 5 lexers and the quick-open state. Build each of them only when it's first used.

- **Gain:** 1 to 3 MB on every memory row.
- **Pros:** Low risk. It also makes launch a little faster.
- **Cons:** The first use of quick open or of a colour-coded file pays the cost instead, about 1 to 5 ms.

### Phase B: the only route to every row, not recommended

#### B1. Hybrid: TextKit 2 for small files, TextKit 1 for big ones

Open files under about 5 MB in a TextKit 2 text view and bigger files in today's TextKit 1 view.

- **Gain:** The small-file memory row moves from 49 to about 24 to 28 MB: a win or a tie with TextEdit. The Markdown row moves to about 30 to 32 MB: a tie at best. The 22 MB rows stay on TextKit 1 and keep their wins.
- **Pros:** The only measured way to win the 2 TextEdit rows. TextKit 2 is where Apple puts its new work.
- **Cons:**
  - About 35 places in 5 files depend on TextKit 1 today: the colours (temporary attributes on the layout manager), the gutter's line positions, the extra carets, the current-line highlight, find, and the quick-open preview. Each needs a TextKit 2 version beside the TextKit 1 one.
  - 2 editors to test forever. QA needs every editing suite twice.
  - TextKit 2 has known weak spots in editors: the scroll bar jumps on long files, and layout of very long lines is slow. The 2 MB Markdown file needs a keystroke timing before and after (today 7 to 9 ms against a 10 ms budget).
  - A file that grows past the limit while you type stays in the view it opened in.
- **Effort:** 1 to 2 weeks, plus QA.
- **Risk:** High. It can lose typing speed, which matters more every day than 20 MB of memory.

### Rejected, with the data

#### X1. TextKit 2 for every file

- **Gain:** Same as B1 on small files, with 1 editor instead of 2.
- **Cons:** The 22 MB file needs about 319 MB, against 107 MB today and TextMate's 162 MB. Textee loses the 22 MB memory row it won yesterday, and CotEditor (TextKit 2) shows what happens to big-file speed: 2,844 ms to the window, last of 5.

#### X2. Own text view on Core Text

- **Gain:** The lightest on the 22 MB file (75 MB, with no editing).
- **Cons:** Not lighter than TextKit 2 on small files (26 MB), so it doesn't win the TextEdit rows. All editing would be new code: input methods (French accents, emoji picker), selection, undo, accessibility, spelling, drag and drop. 4 to 8 weeks, with a high risk of bugs in the thing Textee exists for.

#### X3. Rust

Measured on 13th October: the same window in Rust and in Swift used the same memory and time. The floor is AppKit, not the language.

## Expected result

| Row                       | Now        | After Phase A        | After Phase B (hybrid)     | Confidence |
| -                         | -          | -                    | -                          | -          |
| 2 KB file: window visible | Tie, 3%    | Win                  | Win                        | Medium     |
| Memory, 1 small file      | Lost, 1.8x | Lost, about 1.3x     | Win or tie                 | Low        |
| Memory, 2 MB Markdown     | Lost, 1.7x | Lost, about 1.1-1.2x | Tie or small loss          | Low        |
| Memory 2 s later, 3 rows  | Unknown    | Better by 7 to 11 MB | Better again on small      | Medium     |
| 13 other published rows   | Won        | Won                  | Won, if typing speed holds | High       |

With Phase A, Textee wins 14 or 15 of 16 published rows, and is close to TextEdit on the 2 memory rows. Only Phase B can reach 16 of 16, and only the small-file row is likely; the Markdown row stays a coin toss.

## A note on the benchmark itself

The memory rows read the footprint at the moment the app's CPU use settles. At that moment, AppKit may or may not still hold a 2nd window buffer, worth about 8 MB. Today the same bare text view measured 35 MB in 1 session and 49 MB in another. 2 changes would make the memory rows fairer to every app, Textee included:

- Report the median of 3 readings (at settle, 1 s and 2 s later) instead of 1 reading.
- Run every app in the same rounds, in a rotating order, as today's floors runner does.

Both change how the rows are measured, not what Textee does. I list them because a row decided by 8 MB of AppKit timing isn't a fair test of any editor, not to tilt the result: the 2 TextEdit rows stay lost either way.

## Recommendation

1. Run A1 when the Mac is quiet. It costs 20 minutes and replaces 3 "unknown" rows with numbers.
2. Do A2, A3 and A4 (2 to 3 days). They help daily use, not only the chart.
3. Don't build the hybrid (B1). It doubles the editor code for 2 memory rows, and puts typing speed at risk. Revisit it only if Apple fixes TextKit 2's big-file memory, which would make X1 (TextKit 2 for every file) the simpler route.

## Method and files

- `build/mini.swift`: the 4 minimal apps (`MINI_MODE` = `tk1`, `tk1short`, `tk2` or `ct`).
- `build/floors.py`: the runner. It uses `bench.py`'s probe, fixtures, bench copy and Amethyst settings. Options: `APPS`, `ONLY`, `ROUNDS`, `OUT`.
- `data/floors*.json`: the 3 runs. `data/fp-*.txt`: `footprint` by category for each app and file, 2 s after settle (and at settle and 8 s for the small file).
- All runs: 14th October 2026, Mac Studio, macOS 26, window 1920 x 1080, load average 18 to 78.
