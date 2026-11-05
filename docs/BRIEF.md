# Product Brief

A native macOS agent IDE organized around a mind map, with agent harnesses running through terminal sessions.

## Current Scope

A runnable empty application shell. Agent execution, terminal rendering, mind-map editing, persistence, and settings will be designed when their implementation begins.

## Design Plan

- **Archetype:** A native resizable window, using SwiftUI `WindowGroup` and standard macOS chrome.
- **Information architecture:** One blank root view. Navigation will follow actual product needs.
- **Command map:** System-provided app, new window, close, minimize, fullscreen, and quit commands.
- **Empty state:** An empty system window background with no placeholder controls or initial input focus.
- **Feeling:** Calm and native, leaving space for future content.

## Engineering Direction

- Swift 6 language mode, with main-actor isolation by default in the UI target.
- SwiftPM manages the executable; the bundle script produces a locally signed macOS `.app`.
- App entry and UI live in separate folders within one target.
- Add domain and infrastructure modules when real dependencies justify them.
- Introduce tests with the first testable behavior; build, formatting, packaging, and native launch checks validate the empty shell.
- Distribution signing, app capabilities, and resource packaging will be configured when needed.
