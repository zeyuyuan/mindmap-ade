# GhosttyTerminal

This directory contains the two Swift targets and runtime resources used from
[Lakr233/libghostty-spm 2.2.2026110702](https://github.com/Lakr233/libghostty-spm/tree/2.2.2026110702)
at `1d84cf66fe29abd1f24f10b88dcfc25882cf68ee`. The manifest pins the upstream
XCFramework checksum and uses the original library at Ghostty commit
`042b16b6146ada29877dfeeea9f286889e4adeb1`.

Mindmap ADE adds a bounded scrollback read to the host-managed session for its
plain-text run snapshots. The adapter exposes it under the same surface lifetime
lock as the upstream viewport read.

The resource locator also uses the signed host's Resources directory, including
for localized AppKit menu strings. Development executables use SwiftPM's bundle.
