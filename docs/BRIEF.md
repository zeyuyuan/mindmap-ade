# Product Brief

A native macOS agent IDE organized around a mind map, with agent harnesses running through terminal sessions.

## Current Scope

A local text mind-map workspace: multiple boards and roots, ordered trees, zoom and pan, inline editing, branch folding and dragging, undo and redo, and automatic local saving. Project nodes, worktrees, agents, and terminals are deferred.

## Design Plan

- **Archetype:** A native sidebar window with a SwiftUI shell and an AppKit canvas.
- **Information architecture:** Boards in a one-level sidebar; the selected board owns a multi-root canvas. The title bar contains the board name and system sidebar toggle. The bottom bar shows editing hints, magnification, and save state. Map operations live on the canvas, in context menus, and in the standard menu bar rather than repeated toolbar buttons.
- **Command map:** Command-N creates a board; Shift-Command-N opens a window. On the canvas, Tab adds a child, Return adds a sibling, Shift-Command-R adds a root, arrows navigate, and Delete removes branches. Double-click or F2 edits text. While editing, Return commits, Option-Return inserts a newline, and Escape cancels. Blank-canvas context menus provide Actual Size and Fit Content. Standard copy, paste, undo, redo, zoom, and window commands remain available.
- **Empty state:** A new board has one empty topic. With no boards, show a native empty state with New Board. Opening a window does not force text editing.
- **Feeling:** Calm, direct, and predictable. Keep context stable while editing and use system controls around the canvas.

## Engineering Direction

- Swift 6 language mode, with main-actor isolation by default in the UI target.
- SwiftPM manages the executable; the bundle script produces a locally signed macOS `.app`.
- App entry and UI live in separate folders within one target.
- `MindMapCore` owns the tree model, reversible edits, iterative variable-size tree layout, camera mathematics, and archive validation. It maintains a derived parent index as links change, and records a group move as one reversible edit. It has no view dependencies.
- AppKit owns high-frequency canvas state. Core Animation retains visible topics and batches curved connectors by tree. It reuses unchanged paths as the camera moves. Subtree bounds cull offscreen content, while curves can remain visible even when their endpoint cards are outside the viewport. A separate native view host accommodates the inline TextKit 2 editor and future terminal nodes.
- Core Text measurement runs on a separate actor. Layout results carry the originating board revision; obsolete work is discarded. Views and layers remain on the main actor.
- A topic has one editor across windows. Editing it from a second window commits the previous draft and transfers ownership. Cancel discards only the current draft.
- Saves are debounced, serialized, and atomically replaced. The status reflects the latest write result. An advisory lock prevents two app instances from overwriting the same workspace. Use `--data-directory <path>` for isolated QA data.
- Swift Testing covers the model, layout, camera, archive, and AppKit regressions. Native interaction, appearance, and minimum-size checks also run against the bundled macOS app.
- Distribution signing, app capabilities, and resource packaging will be configured when needed.
