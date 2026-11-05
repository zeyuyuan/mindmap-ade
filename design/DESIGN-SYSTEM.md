# Design System

This document is the source of truth for app-owned design tokens. The Swift declarations mirror the values defined here.

## System Appearance

- Use standard macOS window chrome, system typography, controls, materials, and semantic colors.
- The blank root uses `NSColor.windowBackgroundColor` and follows the system appearance automatically.
- Follow the system accent color. Custom colors, themes, and typography are deferred until needed.
- Use native control sizing rather than iOS typography or touch-target dimensions.

## Layout Tokens

Defined in `Sources/MindmapADE/UI/WindowLayout.swift`:

| Token | Value | Use |
| --- | --- | --- |
| `defaultWidth` | 1000 pt | Initial window width |
| `defaultHeight` | 680 pt | Initial window height |
| `minimumWidth` | 640 pt | Minimum usable window width |
| `minimumHeight` | 440 pt | Minimum usable window height |

The window can grow freely and uses the system's window restoration behavior.

## Spacing

Use the BAMA 4 pt spacing system. Standard window margins are 20 pt, spacing between related controls is 8 pt, and spacing between groups is 20 pt. Add named spacing tokens when content first needs them; do not create a separate 8 pt grid.

## Validation

Review UI changes in a running macOS app in light and dark appearance, including the window's minimum size. Preserve native keyboard navigation, window controls, and accessibility behavior.
