# mindmap-ade

A native macOS agent IDE built around a mind-map workspace.

- Organize ideas and development tasks visually.
- Run different agent harnesses through terminal sessions.
- Follow native macOS interaction and design conventions.

The first version provides native text mind maps with multiple boards and root topics, automatic tree layout, zoom and pan, inline editing, branch folding and dragging, undo/redo, and automatic local saving. Requires macOS 26+ and Xcode 26+ with Swift 6.2 or later.

```sh
make run
```

`make check` checks formatting, builds the app, and runs the core and AppKit regression tests. `make app CONFIGURATION=release` creates a release bundle in `dist/`.

## Editing a map

- Double-click a topic or press F2 to edit. Return finishes editing, Option-Return inserts a newline, and Escape discards the current draft. Opening the same topic for editing in another window commits the first editor and continues with that text.
- With the canvas focused, Tab adds a child and Return adds a sibling. Shift-Command-R adds a root. Typing replaces the selected topic's text.
- Drag blank space to pan; pinch or Command-scroll to zoom. Command-plus/minus zoom, Command-0 restores actual size, and Shift-Command-0 fits content.
- Right-click blank canvas for Actual Size and Fit Content. The bottom bar displays the current zoom; the title bar keeps only the board name and native sidebar toggle.
- Drag a topic onto another topic to reparent its branch. Drop near a topic's upper or lower edge to reorder, or on blank space to make a root. Drag a selected topic to move the selection together; one undo restores the group. Drops onto a moved branch's descendants leave the map unchanged.
- Click the external minus control to fold a branch. A folded branch shows the total number of hidden descendants; click the number to expand. Arrow keys navigate, expand, and collapse. Command-click selects multiple topics; Shift-drag on blank space selects a region.
- Option-Command-Up/Down reorders a branch without dragging; the same commands are in the Node menu.
- Delete removes selected branches. Command-Z and Shift-Command-Z undo and redo. Copy and paste transfer plain text.
- Command-N creates a board. Rename, reorder, and delete boards in the sidebar. Deleting a board offers an Undo button.

Workspace data is stored in `~/Library/Application Support/MindmapADE/`. Saves use atomic replacement. The status bar reports failed writes and returns to Saved locally after a successful write. A second app instance opens the same data read-only. For isolated testing, launch the executable with `--data-directory <directory>`.

Debug builds also accept `--appearance light` or `--appearance dark`, and `--minimum-window`, for native visual verification without changing system preferences.

## Architecture

SwiftUI provides the native shell. An AppKit canvas owns high-frequency interaction and a culled Core Animation scene; a reusable TextKit 2 editor provides native text input. The independent `MindMapCore` target contains the tree model, reversible edits, layout, camera, and archive validation. A native view host is reserved for future embedded terminal nodes; this version implements text topics only.

Licensed under the [MIT License](LICENSE).
