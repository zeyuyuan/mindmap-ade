# Design System

This document is the source of truth for app-owned design tokens. The Swift declarations mirror the values defined here.

## System Appearance

- Use standard macOS window chrome, system typography, controls, materials, and semantic colors.
- The canvas uses `NSColor.textBackgroundColor`; topic cards use `controlBackgroundColor`, text uses `labelColor` or `secondaryLabelColor`, and connectors use `separatorColor`.
- Follow the system accent color. Custom colors, themes, and typography are deferred until needed.
- Use native control sizing rather than iOS typography or touch-target dimensions.
- Keep the title bar limited to the board name and system sidebar toggle. Canvas gestures, inline branch controls, context menus, and standard menu commands own map editing and viewport actions. Show magnification as read-only text in the bottom status bar.

## Layout Tokens

Defined in `Sources/MindmapADE/UI/WindowLayout.swift`:

| Token | Value | Use |
| --- | --- | --- |
| `defaultWidth` | 1000 pt | Initial window width |
| `defaultHeight` | 680 pt | Initial window height |
| `minimumWidth` | 640 pt | Minimum usable window width |
| `minimumHeight` | 440 pt | Minimum usable window height |

The window can grow freely and uses the system's window restoration behavior.

## Topic and Tree Tokens

Defined in `Sources/MindMapCore/Layout.swift`, in `MapMetrics`. Sizes are world-coordinate points and do not change when the camera zooms.

| Token | Value | Use |
| --- | --- | --- |
| `fontSize` | 13 pt | System body text; semibold for roots |
| `minimumNodeWidth` | 96 pt | Minimum topic width |
| `maximumTextWidth` | 220 pt | Text wrapping width |
| `minimumNodeHeight` | 36 pt | Minimum text topic height |
| `resourceMinimumWidth` / `resourceHeight` | 204 / 52 pt | Resource cards with an icon, title, and type or status |
| `resourceDetailHeight` | 16 pt | Secondary line for a resource card |
| `resourceIconSize` / `resourceIconGap` | 28 / 8 pt | Leading resource icon tile and space between the tile and the text |
| `maximumTextHeight` | 144 pt | Maximum nonediting text preview height |
| `horizontalPadding` / `verticalPadding` | 12 / 8 pt | Topic content insets |
| `horizontalGap` / `verticalGap` | 64 / 16 pt | Parent-to-child and sibling-subtree separation |
| `rootGap` | 64 pt | Separation when adding a root after an existing tree |

Empty text displays the secondary placeholder “New topic”. Content remains plain text. Center the visible text block vertically using its glyph bounds, including fallback fonts and multiline text. Complete text is retained even when the preview is clipped. Topic width depends only on text; adding or folding children does not reserve space inside the card.

## Canvas and Chrome Tokens

Defined in `Sources/MindmapADE/UI/Canvas/CanvasStyle.swift`.

| Token | Value | Use |
| --- | --- | --- |
| `nodeRadius` | 8 pt | Topic and inline-editor corners |
| `borderWidth` / `selectedBorderWidth` | 1 / 2 pt | Normal and selected topic outlines |
| `edgeWidth` | 1.5 pt | Simple curved connectors and disclosure strokes |
| `viewportOverscan` | 160 pt | Preload margin outside the visible canvas |
| `fitPadding` | 64 pt | Space around content when fitting or revealing a topic |
| `dragThreshold` | 4 pt | Pointer travel before starting a drag |
| `selectionOpacity` | 0.08 | Accent fill for selection and drop overlays |
| `resourceIconPointSize` | 16 pt | Symbol inside the resource icon tile |
| `activeAgentTintFraction` | 0.18 | System accent blended into the active Agent card background |
| `formWidth` / `formMaximumBodyHeight` | 384 / 344 pt | Native node popover and its scrollable form body |
| `formPadding` / `formSpacing` / `formGroupSpacing` | 16 / 8 / 16 pt | Node form insets, related controls, and group spacing |
| `formFocusInset` | 8 pt | Room for system focus rings inside the form scroll clip |
| `formCompactSpacing` | 4 pt | Space between a label and its supporting text |
| `canvasMinimumWidth` / `terminalMinimumWidth` | 160 / 192 pt | Minimum pane widths when the board has room for both |
| `terminalResizeHandleWidth` / `terminalResizeStep` | 8 / 32 pt | Divider drag area and accessibility adjustment step |
| `editorMinimumHeight` / `editorMaximumHeight` | 36 / 240 pt | Inline text editor height range; the minimum matches a topic at actual size |
| `sidebarMinimumWidth` / `sidebarIdealWidth` / `sidebarMaximumWidth` | 180 / 208 / 280 pt | Native board sidebar sizing |
| `statusHorizontalPadding` / `statusVerticalPadding` | 16 / 8 pt | Bottom status and save feedback |
| `textDetailScale` / `overviewBranchExtent` | 0.22 / 8 pt | Hide unreadably small text and simplify subtrees whose projected bounds are tiny |
| `disclosureDiameter` / `disclosureGap` | 16 / 8 pt | External circular branch control on the outgoing connector, measured from the card's right edge |
| `disclosureHitPadding` / `disclosureGlyphRadius` | 4 / 4 pt | Extra pointer hit area and minus half-stroke length |
| `disclosureCountFontSize` / `disclosureCountPadding` | 10 / 4 pt | Monospaced medium-weight hidden-topic count and horizontal badge padding |
| `disclosureMaximumWidth` | 48 pt | Maximum count-badge width, derived from the parent-to-child gap minus the control gap and both hit insets |

`MapCamera.minimumScale` is 0.000001 and `maximumScale` is 4, allowing Fit Content to include very large maps. Sub-percent magnification displays fractional percentages. Editing below 75% aims for 100%; editing is capped at 150% and reduced as needed to fit the topic's width. Fit Content enlarges no further than 150%. Camera changes preserve their anchor. Native sidebar controls use system sizing.

Selection uses the system accent outline. The Agent whose terminal pane is open has a tinted card and the `terminal.fill` symbol. Its highlight follows the pane independently of canvas selection and process status. Do not add custom glass or shadows to map content. Disable implicit layer animations during pointer manipulation.

The status bar distinguishes loading, saving, saved, failed, and read-only states. Place workspace errors below the split view so they do not cover the canvas status or sidebar controls. Undo a board deletion from the Edit menu without adding a footer.

Branch controls sit outside the card: minus collapses, a numeric badge expands. A collapsed branch shows its total descendants, including descendants below other folded nodes, and excludes the topic itself. The badge widens for multiple digits without changing card width. Counts are derived once per layout snapshot and reused during camera movement. Hide controls below `textDetailScale`, matching the text detail level. Use the same geometry for drawing, pointer hit testing, and accessibility frames.

Resource cards use a leading SF Symbol on a tertiary system fill. Use the folder, branching arrows, and terminal symbols for projects, worktrees, and agents. A Git Project shows its current branch beneath its name. A bound folder without Git shows its name centered beside the icon. An unbound Project keeps its Draft label. Worktree cards show their branch and directory name. The enclosing Project or parent Worktree identifies a new checkout’s source. Hide the symbols with the text at overview zoom. Keep the popover anchored to the node at system control size. Close or Keep Draft keeps a new draft available to complete later. A new Worktree has a focused name field inside its card, with the generated branch name as the placeholder. Tab accepts the name. Return or leaving the field creates the checkout. Keep the terminal at its own text size inside the board window.

The native text editor centers its text container using the laid-out glyph bounds. Empty and trailing lines retain space for the insertion point. Once the text requires scrolling, use normal top and bottom padding. Keep native caret, selection, and input-method geometry in the same text-container coordinate system.

The Agent terminal opens to the right of the canvas at half the board width. Keep its controls in the pane header, with icon buttons and help labels so they fit at the minimum window size. The divider adjusts the two pane widths without changing the terminal font size.

## Spacing

Use the BAMA 4 pt spacing system. Standard window margins are 20 pt, spacing between related controls is 8 pt, and spacing between groups is 20 pt. Add named spacing tokens when content first needs them; do not create a separate 8 pt grid.

## Validation

Review UI changes in a running macOS app in light and dark appearance, including the window's minimum size. Preserve native keyboard navigation, window controls, and accessibility behavior.
