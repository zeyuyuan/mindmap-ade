# Text Mind Map Validation

Validated on November 6, 2026, on an Apple Silicon Mac running macOS 27.0.1, Xcode 26.6, and Swift 6.3.3. The deployment target remains macOS 26.

## Automated Checks

- `make check`: first-party Swift formatting, debug build, and all nine Swift Testing tests passed.
- `make app CONFIGURATION=release`: release app bundle built and locally signed.
- `xcrun swift test --configuration release`: all nine tests passed.
- Core coverage includes reversible edits, subtree deletion and reparenting, cycle prevention, variable-size layout, folding, viewport culling, anchored zoom, fitting large content, and archive validation.
- A 10,000-node chain lays out and deletes without recursive stack growth. The release geometry-only layout measurement was approximately 7 ms on this machine. This excludes text measurement, rendering, and input handling; it is not a frame-rate benchmark.

## Native Window Checks

Test workspaces used isolated data directories.

- Light and dark appearance; a 640 × 440 pt minimum content area; native toolbar percentage visibility.
- Multiple boards, immediate keyboard input after creation, renaming, deletion, and deletion recovery.
- Multiple roots, child and sibling creation, Unicode text, multiline editing, and a long scrolling inline editor.
- Root movement, subtree reparenting, detaching to a new root, folding, and undo/redo.
- Pan, zoom, Fit Content, numeric zoom presets, and fractional magnification.
- Save and reopen; in-progress text draft saving; Escape restores the original saved text.
- Release builds loaded balanced 1,000- and 10,000-node fixtures. Switching boards and immediately invoking Fit Content worked. The 10,000-node overview used 0.20% magnification and exposed 157 representative topics in the observed viewport, with the complete document retained. This checks viewport culling and overview detail reduction, not sustained frame rate.

## Text Alignment and External Branch Controls

Validated on November 7, 2026:

- Text previews center their visible glyph bounds within the card, covering single-line text, mixed Chinese/English, emoji, multiple lines, and truncated long text.
- Circular minus/plus controls sit outside the card. Parent cards no longer reserve internal disclosure space.
- Physical pointer clicks at 127% and 60% magnification fold and expand branches; undo restores them. Double-clicking the card's right-hand text area starts editing.
- Independent accessibility buttons expose the external controls with matching frames and expand/collapse labels.
- Light appearance at 50%, 127%, and 150%, and dark appearance at the minimum window size, were visually checked in the native app. QA used a copy of the user's saved map and a separate typography fixture.
- `make check` passed all nine existing core tests after the change.

## Inline Editing Alignment

Validated on November 7, 2026:

- A newly created topic centers its live native text input and empty insertion point. The editor's 36 pt minimum height matches a topic at actual size.
- TextKit 2 line fragments determine the text-container origin, including mixed scripts, emoji, and trailing empty lines. Native caret and selection geometry use the same origin.
- A 30-line input scrolls to the insertion point. Replacing it with a short line removes the scrollbar, clears the old scroll offset, and restores centered text without accidental wrapping.
- Option-Return grows the editor to include an empty final line. Immediate typing after Tab creates a child remains centered. Clicking between characters inserts at the expected position, and editing undo works.
- Native input was visually checked at 100% in light appearance and 119% in dark appearance, including the minimum window size.

## Minimal Title Bar

Validated on November 7, 2026:

- Removed the duplicate Add Topic, Fold Branch, zoom picker, and Fit Content toolbar items. The title bar retains the board name and the system sidebar toggle.
- Magnification is read-only in the bottom status bar. The blank-canvas context menu exposes Actual Size and Fit Content; both updated the camera and status display correctly.
- Dark appearance at the minimum window size was checked with the sidebar shown and hidden. Standard menu commands and keyboard shortcuts remain available.
- `make check` passed all nine existing core tests.

## Collapsed Descendant Counts

Validated on November 7, 2026:

- Collapsed controls display exact hidden-descendant totals outside the topic card. A 1,257-topic fixture covered counts of 3, 12, 1,234, and 2; nested folded branches contributed to their ancestors' totals.
- Count badges widen for multiple digits. A physical click on the trailing side of the four-digit badge expanded the branch; undo restored the collapsed badge and count.
- Adding a descendant updated a folded child's total from 2 to 3 and its folded parent's total from 4 to 5. Accessibility labels and hit frames followed the same counts and geometry.
- Dark appearance at minimum window size was checked. `make check` passed all nine existing core tests, including the 10,000-deep iterative layout case. Totals are computed during layout, not during camera movement.

## Review Fixes

Validated on November 7, 2026:

- `make check` passed 19 tests, including AppKit regressions for editing ownership, stale drafts, undo, save failure and recovery, group dragging, and invalid drops. The release bundle built and passed local signature verification.
- In two native windows, the second editor opened with the first window's draft. After the second window committed, Escape in the first window did not change the committed text.
- Command-click selected two roots. Dragging either root translated both by the same distance, and one undo restored both positions. Dropping a branch on its descendant left its parent and children intact.
- The minimum-size dark window displayed both Save Failed and the error notice when an isolated workspace directory rejected writes. The notice left the sidebar controls and status bar visible. After restoring permission, the next save persisted the pending edit and cleared the error.
- The light release window displayed the external count of six hidden topics. Clicking the badge expanded the branch, and undo restored the count.
- The 10,000-topic star retains all 9,999 curves in 40 connector layers, down from 9,999 individual layers. Panning reuses paths when their segments are unchanged. Connectors crossing the viewport survive when both endpoint cards are culled. The layer count is a renderer regression check, not a frame-rate benchmark.
- Group moves and their inverses preserve the parent index. Loading an archive rebuilds the index without changing the archive format.

## Deferred Validation

Real IME composition, VoiceOver navigation, and sustained GPU/frame-time profiling need dedicated testing before broader distribution.

## Resource Nodes and Agent Sessions

Validated November 7–9, 2026, with macOS 27.0.1 and Xcode 26.6. Native checks used a separate workspace and scratch Git repositories.

- `make check` passed 38 tests. Coverage includes legacy workspace loading, resource placement during moves, Worktree creation and recovery after a failed save, command deadlines, PTY working directories, and child process shutdown.
- The native Project form bound a linked checkout. The Worktree picker listed linked and detached checkouts and could reuse an existing directory. Command-Return on a text topic opened an Agent draft with the text as its task. Starting an Agent without an inherited Worktree inserted one Worktree node above it.
- Command Code and Codex started in their bound Worktrees and discovered the map tools. The integration tests cover branch permissions, duplicate operation IDs, registering another Worktree, and revoking map access after Stop.
- The Agent form kept the conversation name visible and the focus rings intact. Its CLI selection survived restart. The terminal opened to the right of the canvas; hiding it or switching boards preserved a live conversation.

The terminal backend uses Ghostty with a host-managed PTY. The workspace keeps the latest run record and a bounded plain-text terminal snapshot for recovery.

## Ghostty and Native PTY

Validated November 11, 2026, on Apple Silicon with macOS 27.0.1 and Xcode 26.6.

- Both SwiftPM build systems passed all 45 tests. The concurrent PTY regression also passed eight repeated 12-session runs. Coverage includes launch errors, controlling terminals, separate job groups, output backpressure, rapid exits, hidden scrollback, cross-window attachment, and final snapshot writes.
- A temporary workspace exercised the native pane with a deterministic CLI. Unicode paste, divider resize, hide and reopen after 20,000 output lines, switching between two Agents, Stop, exit status, and saved output worked.
- The signed universal Release app launched after being moved outside the checkout. It restored the interrupted test session, accepted terminal input, and quit normally with Command-Q while the terminal was focused.
