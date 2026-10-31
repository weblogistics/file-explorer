# File Explorer (Windows 11 style) for macOS

A native Swift/AppKit file manager that recreates the look and behaviour of Windows 11 File Explorer on the Mac.
Runs on Apple Silicon and Intel Macs with macOS 13 Ventura or later.

## Install

1. Download [`dist/File-Explorer-1.0.dmg`](dist/File-Explorer-1.0.dmg) from this repo.
2. Open the DMG and drag **File Explorer** into **Applications**.
3. The app isn't signed with an Apple Developer ID, so macOS blocks the first launch:
   - Open it once (macOS will refuse), then go to **System Settings → Privacy & Security** and click **Open Anyway**.
   - Or remove the download quarantine in Terminal:
     ```
     xattr -dr com.apple.quarantine "/Applications/File Explorer.app"
     ```

The first time you browse Desktop, Documents or Downloads, macOS asks for permission. Browsing the Recycle Bin may need
**Full Disk Access** (System Settings → Privacy & Security).

## Build from source

Requires the Xcode command line tools (`xcode-select --install`); a full Xcode install isn't needed.

    ./build.sh       # builds a universal "File Explorer.app"
    ./make-dmg.sh    # builds the app and packages dist/File-Explorer-<version>.dmg
    open "File Explorer.app"

## Features

- **Window:** tabs in the title bar (new, close, duplicate, reorder, middle-click to close) and Windows caption buttons
- **Navigation:** Back / Forward / Up / Refresh, breadcrumb address bar with subfolder drop-downs, typed paths (Tab completes)
- **Search:** live results, wildcards (`*.pdf`) and a Folder column
- **Command bar:** New ▾, Cut, Copy, Paste, Rename, Share, Delete, Sort ▾, View ▾, ⋯, Details
- **Views:** Extra large / Large / Medium / Small icons, List, Details, Tiles and Content, with thumbnails
- **Sort and group:** by name, date, type or size (Windows-style date buckets); each folder remembers its view
- **Navigation pane:** Home, Gallery, pinned Quick access, This PC drive tree, Recycle Bin
- **Pages:** Home (Quick access and Recent files), This PC (drive capacity bars), Gallery (Pictures by month)
- **Panes:** Details pane, Preview pane, and Quick Look (Space)
- **File operations:**
  - Copy and move with a Windows progress dialog and "Replace or Skip" conflict handling
  - Pasting into the same folder makes "- Copy" duplicates
  - Delete to the Recycle Bin or permanently, with multi-step Undo / Redo
  - Inline rename (F2), including renaming several files at once
  - Drag and drop, including to and from Finder
  - Compress to ZIP, Extract All, Create shortcut, Copy as path
- **Menus and dialogs:** Win11 context menus, Open with, Open in Terminal, Properties (attributes, folder size, drive chart), Folder Options
- **Appearance:** light and dark mode

## Keyboard shortcuts

Windows **Ctrl** shortcuts use **⌘** on the Mac.

| Action | Keys |
| --- | --- |
| New window / tab / close tab | ⌘N / ⌘T / ⌘W |
| Next / previous tab | ⌃⇥ / ⌃⇧⇥ |
| New folder | ⇧⌘N |
| Rename | F2 |
| Cut / Copy / Paste | ⌘X / ⌘C / ⌘V |
| Undo / Redo | ⌘Z / ⇧⌘Z |
| Delete to Recycle Bin | ⌘⌫ or ⌦ |
| Delete permanently | ⌥⌘⌫ or ⇧⌦ |
| Open | ↩ |
| Properties | ⌥↩ or ⌘I |
| Quick Look | Space |
| Back / Forward | ⌫, ⌘[ / ⌘] (or ⌥← / ⌥→) |
| Up one level | ⌘↑ or ⌥↑ |
| Address bar | ⌘L or F6 |
| Search | ⌘F, ⌘E or F3 |
| Refresh | ⌘R or F5 |
| Change view | ⌘1 – ⌘8, or ⌘ + scroll |
| Show hidden items | ⇧⌘. |
| Preview pane / Details pane | ⌥P / ⌥⇧P |
| Copy as path | ⇧⌘C |

## Project layout

| Path | Contents |
| --- | --- |
| `Sources/FileExplorer/` | App source (AppKit, no storyboards) |
| `build.sh` | Builds the universal app bundle and its icon |
| `make-dmg.sh` | Packages the app into a DMG in `dist/` |
| `dist/` | Prebuilt DMG |
