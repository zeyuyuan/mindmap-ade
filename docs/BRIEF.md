# Product Brief

A native macOS agent IDE organized around a mind map, with agent harnesses running through terminal sessions.

## Current Scope

A local mind-map workspace for turning a text task into an Agent conversation. Boards organize text, projects, worktrees, and Agents in the same tree. Each bound Git project shows the current branch of its own directory. A derived Worktree starts from its enclosing Project or parent Worktree. A conversation inherits its project and closest worktree and runs in a terminal inside the board window.

## Design Plan

- **Archetype.** A SwiftUI sidebar window with an AppKit canvas. Starting a conversation or opening its Agent node places the terminal to the right of the canvas. The two panes start at equal widths and share a draggable divider.
- **Information architecture.** The sidebar lists boards. Resource cards show their type and state. A native popover anchored to the card holds its fields at a readable size at any zoom. The Agent form shows the optional conversation name and task, the selected CLI, and its worktree. Command Code and Codex are detected automatically. When creating a worktree for the Agent, Options contains the Git revision overrides. Closing a new card's form keeps its draft. Delete an unused Agent draft from the canvas.
- **Command map.** The Node menu and canvas context menu offer Project, Worktree, and Agent. Add Worktree on a bound Git Project or Worktree derives from its live HEAD. Link Existing Worktree is available at project scope. Tab and Return retain their text node shortcuts. Command-Return on a nonempty text topic opens an Agent draft with a task snapshot. Double-click or F2 opens a card. Show in Finder reveals a bound directory. Stop ends a conversation. Hide Terminal closes its pane.
- **Empty and blocked states.** New boards start with an editable text root. Missing context has an action to choose a Git project or configure its ancestor. Non-Git folders can be organized as projects. A new Worktree focuses its name directly on the canvas. Tab accepts the suggested name. Return or leaving the field creates the checkout. Linking an existing checkout has its own entry point.
- **Interaction.** Save Project and Link Worktree bind existing directories. Create Worktree writes Git state. Start validates and saves the Agent binding before launching. A new worktree uses the suggested name when the name field is blank and becomes the Agent's immediate parent. A running conversation stays active when switching boards or closing a pane. Moving or undoing its branch is allowed when it remains bound to its working directory.

## Engineering Direction

- Swift 6 language mode, with main-actor isolation by default in the UI target.
- SwiftPM manages the executable; the bundle script produces a locally signed macOS `.app`.
- App entry and UI live in separate folders within one target.
- `MindMapCore` owns the tree model, reversible edits, iterative variable-size tree layout, camera mathematics, and archive validation. It maintains a derived parent index as links change, and records a group move as one reversible edit. It has no view dependencies.
- AppKit owns high-frequency canvas state. Core Animation retains visible topics and batches curved connectors by tree. It reuses unchanged paths as the camera moves. Subtree bounds cull offscreen content, while curves can remain visible even when their endpoint cards are outside the viewport. A native view host accommodates inline TextKit 2 editing. The terminal has its own resizable native pane and a session-owned view.
- Core Text measurement runs on a separate actor. Layout results carry the originating board revision; obsolete work is discarded. Views and layers remain on the main actor.
- A topic has one editor across windows. Opening a form in another window transfers ownership of the draft. One window hosts each live terminal surface.
- Saves are debounced, serialized, and atomically replaced. The status reflects the latest write result. An advisory lock prevents two app instances from overwriting the same workspace. Use `--data-directory <path>` for isolated QA data.
- Swift Testing covers the model, layout, camera, archive, and AppKit regressions. Native interaction, appearance, and minimum-size checks also run against the bundled macOS app.
- Git uses argument vectors and porcelain output. Repository identity comes from the canonical Git common directory. The saved creation plan allows an exact worktree to be reused after an interrupted operation.
- Command Code and Codex receive a literal initial task in a native PTY. Codex receives its map server configuration for the current process. SwiftTerm supplies the terminal view behind the session boundary.
- A stdio MCP bridge connects to a private Unix socket. Session-scoped tools read context, change text topics in the Agent branch, and register Git worktrees. Registration creates a reference and can create a follow-up draft. A running process keeps its verified launch directory.
- Workspace archives still load version 1 text boards, version 2 resource boards, and version 3 boards with Git ref nodes. Version 6 lifts the children of automatically generated project checkouts to their Project. Branches with Agents that inherited the checkout keep an explicit Worktree binding. The latest run state survives restart and active records become interrupted. The terminal scrollback belongs to the current app session.
