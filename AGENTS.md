# Project Instructions

## Project Context

Build a native macOS agent IDE with a mind map as its main workspace. Run different agent harnesses through terminal sessions.

## Commit Messages

Follow Conventional Commits:

```text
<type>(<scope>): <summary>
```

- The scope is optional; use `<type>: <summary>` when no scope is needed.
- Use one of these types: `feat`, `fix`, `refactor`, `docs`, `test`, `build`, `ci`, or `chore`.
- Use an imperative summary, such as `add`, `fix`, or `remove`.
- Keep the full title at 72 characters or fewer, without a trailing period.
- Keep each commit focused on one clear purpose.
- For complex changes, add a body explaining the reason for the change, separated from the title by a blank line.
- Mark breaking changes with `!` before the colon or a `BREAKING CHANGE:` footer explaining the impact.

Example:

```text
build(app): scaffold native macOS application
```

## Skill Collaboration Rules

Design tokens and usage rules: `design/DESIGN-SYSTEM.md`. Keep its documented values and the Swift token declarations in sync.

### Priority

Apple HIG > mac-design > DESIGN-SYSTEM.md > SwiftUI Design

1. **mac-design** governs native interactions, typography, control sizes, and layout.
2. **DESIGN-SYSTEM.md** is the sole source of design tokens.
3. **SwiftUI Expert** is responsible for implementation correctness and performance.
4. **SwiftUI Design** is responsible only for visual exploration and aesthetic recommendations.
5. Use the **BAMA 4pt spacing system**. Do not introduce a separate 8pt grid.
6. Do not apply iOS-style oversized typography or touch-target guidelines.
7. Prefer system controls and system materials.
8. After any UI change, visually validate the result in a real macOS environment.

When rules conflict, follow the rule with the highest priority.

## Development

- Requires macOS 26+ and Xcode 26+ with Swift 6.2 or later.
- `make run` builds, bundles, and launches a fresh app instance.
- `make check` validates first-party Swift formatting and builds the executable.
- `make app CONFIGURATION=release` produces `dist/MindmapADE.app`.
- `make format` formats first-party Swift files. Preserve upstream skill formatting.
- Keep app lifecycle code in `Sources/MindmapADE/App/` and UI in `Sources/MindmapADE/UI/`.
- Introduce feature modules, dependencies, and tests when real behavior requires them.
