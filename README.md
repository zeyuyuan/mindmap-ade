# mindmap-ade

A native macOS agent IDE built around a mind-map workspace.

- Organize ideas and development tasks visually.
- Run different agent harnesses through terminal sessions.
- Follow native macOS interaction and design conventions.

Mindmap ADE organizes text topics, projects, Git worktrees, and local Agent conversations in native mind maps. It includes multiple boards and roots, automatic layout, zoom and pan, branch folding and dragging, undo and redo, and local saving. Requires macOS 26+ and Xcode 26+ with Swift 6.2 or later.

```sh
make run
```

`make check` checks formatting, builds the app, and runs the core and AppKit regression tests. `make app CONFIGURATION=release` creates a release bundle in `dist/`.

## Editing a map

- Double-click a topic or press F2 to edit. Return finishes editing, Option-Return inserts a newline, and Escape discards the current draft. Opening the same topic for editing in another window commits the first editor and continues with that text.
- With the canvas focused, Tab adds a child and Return adds a sibling. Shift-Command-R adds a root. Typing replaces the selected topic's text.
- Drag blank space to pan; pinch or Command-scroll to zoom. Command-plus/minus zoom, Command-0 restores actual size, and Shift-Command-0 fits content.
- Right-click blank canvas for Fit Content. The bottom bar displays the current zoom; the title bar keeps only the board name and native sidebar toggle.
- Drag a topic onto another topic to reparent its branch. Drop near a topic's upper or lower edge to reorder, or on blank space to make a root. Drag a selected topic to move the selection together; one undo restores the group. Drops onto a moved branch's descendants leave the map unchanged.
- Click the external minus control to fold a branch. A folded branch shows the total number of hidden descendants; click the number to expand. Arrow keys navigate, expand, and collapse. Command-click selects multiple topics; Shift-drag on blank space selects a region.
- Option-Command-Up/Down reorders a branch without dragging; the same commands are in the Node menu.
- Delete removes selected branches. Command-Z and Shift-Command-Z undo and redo. Copy and paste transfer plain text.
- Command-N creates a board. Rename, reorder, and delete boards in the sidebar. Use Edit → Undo Delete Board (Command-Z) to restore a recently deleted board.

## Running an Agent

- Use **Add Project** to bind a folder. A bound Git project shows the current branch of that folder on its own card.
- Choose **Add Worktree** on a Git project or an existing Worktree to start a child checkout from its current commit. The child node opens with its name ready to edit. Type a branch name or press Tab to accept the suggestion, then press Return or click away to create it. An empty name uses the suggestion. Use **Link Existing Worktree** at project scope to organize another checkout already on disk.
- Choose **Add Agent** in the canvas context menu. On a text topic, choose **New Agent from Text** or press Command-Return to prefill the task. The Agent inherits the closest Worktree or offers to create or select one. If there is no project, choose a Git folder first.
- Enter an optional conversation name and task, choose **Command Code** or **Codex**, then click **Start**. The app finds the selected CLI automatically and connects it to the branch's map tools. Codex uses its existing local setup. When creating a worktree for the Agent, **Options** contains the Git revision overrides.
- Double-click an Agent with a session to open its terminal in the right half of the board. Drag the divider to resize it. Switching boards and hiding the terminal preserve the process. Stop ends the conversation. Delete or undo removes map references while leaving the Git checkout on disk.

Workspace data is stored in `~/Library/Application Support/MindmapADE/`. Saves use atomic replacement. The status bar reports failed writes and returns to Saved locally after a successful write. A second app instance opens the same data read-only. For isolated testing, launch the executable with `--data-directory <directory>`.

Debug builds also accept `--appearance light` or `--appearance dark`, and `--minimum-window`, for native visual verification without changing system preferences.

## Architecture

SwiftUI provides the native shell. An AppKit canvas owns high-frequency interaction and a culled Core Animation scene; a reusable TextKit 2 editor provides native text input. The independent `MindMapCore` target contains the tree model, reversible edits, layout, camera, and archive validation. A native SwiftTerm pane hosts interactive CLI sessions. Git preparation, run lifecycle, and the local MCP bridge live behind the workspace model.

Licensed under the [MIT License](LICENSE).
