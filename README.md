# mindmap-ade

A native macOS agent IDE built around a mind-map workspace.

- Organize ideas and development tasks visually.
- Run different agent harnesses through terminal sessions.
- Follow native macOS interaction and design conventions.

Currently a minimal app shell. Requires macOS 26+ and Xcode 26+.

```sh
make run
```

`make check` checks formatting and builds the app. `make app CONFIGURATION=release` creates a release bundle in `dist/`.
