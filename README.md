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
- Drag blank space to pan while keeping your selection. Click blank space to clear it. Pinch or Command-scroll to zoom. Command-plus/minus zoom, Command-0 restores actual size, and Shift-Command-0 fits content.
- Right-click blank canvas for Fit Content. The bottom bar displays the current zoom; the title bar keeps only the board name and native sidebar toggle.
- Drag a topic onto another topic to reparent its branch. Drop near a topic's upper or lower edge to reorder, or on blank space to make a root. Drag a selected topic to move the selection together; one undo restores the group. Drops onto a moved branch's descendants leave the map unchanged.
- Click a topic to select it. Command-click adds or removes individual topics, and Shift-drag from blank canvas adds the topics inside the selection rectangle. Click the external minus control to fold a branch, and click the hidden descendant count to expand it. Arrow keys navigate, expand, and collapse.
- Option-Command-Up/Down reorders a branch without dragging; the same commands are in the Node menu.
- Delete removes selected branches. Command-Z and Shift-Command-Z undo and redo. Command-C copies complete branches, including folded descendants. Command-V pastes them under the selected topic or as separate roots on the canvas. Other apps receive an indented text outline. Copied Agents start as drafts, and bound worktrees link to the existing checkout.
- Use **Node → Group Under New Topic** (Option-Command-G) to name a group of selected branches. Option-Command-Left promotes topics one level, and Option-Command-Right makes them children of the preceding sibling.
- Command-N creates a board. Rename, reorder, and delete boards in the sidebar. Use Edit → Undo Delete Board (Command-Z) to restore a recently deleted board.

## Running an Agent

- Use **Add Project** to bind a folder. A bound Git project shows the current branch of that folder on its own card.
- Choose **Add Worktree** on a Git project or an existing Worktree to start a child checkout from its current commit. The child node opens with its name ready to edit. Type a branch name or press Tab to accept the suggestion, then press Return or click away to create it. An empty name uses the suggestion. Use **Link Existing Worktree** at project scope to organize another checkout already on disk.
- Choose **Add Agent** in the canvas context menu. On a text topic, choose **New Agent from Text** or press Command-Return to prefill the task. The Agent inherits the closest Worktree or offers to create or select one. If there is no project, choose a Git folder first.
- Enter an optional conversation name and task, choose **Command Code** or **Codex**, then click **Start**. The app finds the selected CLI automatically and connects it to the board's map tools. Codex uses its existing local setup. When creating a worktree for the Agent, **Options** contains the Git revision overrides.
- Click an Agent to select it. Double-click an Agent with a session, press F2, or choose **Open Terminal** in its context menu to open or switch to its terminal on the right. Keyboard focus stays on the canvas until you click the terminal. The pane stays open when you select another topic. Drag the divider to resize it. Switching boards and hiding the terminal preserve the process. Delete or undo removes map references while leaving the Git checkout on disk.
- Select topics beside the terminal and ask the Agent to read or edit them. You can also ask it to find a phrase or work under a specific branch. The Agent can read and edit nodes on its own board, and its edits appear in the canvas undo history.
- Topics added, edited, or moved by an Agent stay green for six seconds, then fade to their usual color over two seconds. Deletions appear in the status bar. Use Edit > Undo (Command-Z) to reverse the latest map edit.
- When you reopen the app, it restores the board, canvas view, selection, and terminal pane. Opening an interrupted Agent shows its saved output. Choose **Continue Conversation** to resume it. Use **Restart Terminal** after stopping the process yourself, or **Continue Conversation** after the CLI exits. The app asks before continuing on a different branch and keeps recent output available if the worktree or conversation is missing.

Workspace data is stored in `~/Library/Application Support/MindmapADE/`. Saves use atomic replacement. The status bar reports failed writes and returns to Saved locally after a successful write. A second app instance opens the same data read-only. For isolated testing, launch the executable with `--data-directory <directory>`.

Debug builds also accept `--appearance light` or `--appearance dark`, and `--minimum-window`, for native visual verification without changing system preferences.

## Architecture

SwiftUI provides the native shell. An AppKit canvas owns high-frequency interaction and a culled Core Animation scene; a reusable TextKit 2 editor provides native text input. The independent `MindMapCore` target contains the tree model, reversible edits, layout, camera, and archive validation. A Ghostty Metal surface hosts each interactive CLI session through a native PTY. Git preparation, run lifecycle, and the local MCP bridge live behind the workspace model.

Licensed under the [MIT License](LICENSE).
