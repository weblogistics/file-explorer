# File Explorer (Windows 11 style) for macOS

A native Swift/AppKit file manager that recreates the look and behaviour of Windows 11 File Explorer.

## Build & run
    ./build.sh            # produces "File Explorer.app"
    open "File Explorer.app"

Requires macOS 13+ and the Xcode command line tools (no Xcode project needed).

## Features
- Tabs in the title bar (new/close/duplicate/reorder/middle-click), Windows caption buttons
- Back / Forward / Up / Refresh, breadcrumb address bar with folder drop-downs, typed paths (Tab completes)
- Live search with wildcards (`*.pdf`) and a "Folder" column in results
- Command bar: New ▾, Cut, Copy, Paste, Rename, Share, Delete, Sort ▾, View ▾, ⋯, Details
- Views: Extra large / Large / Medium / Small icons, List, Details, Tiles, Content (⌘1–⌘8, ⌘+scroll)
- Sort, Group by (date buckets, size, type, name), per-folder view memory, compact view
- Navigation pane: Home, Gallery, pinned Quick access, This PC drive tree, Recycle Bin
- Home (Quick access + Recent files), This PC (drive capacity bars), Gallery (Pictures by month)
- Details pane and Preview pane, Quick Look (Space)
- Copy/move with Windows progress dialog and "Replace or Skip" conflicts; "- Copy" duplicates
- Recycle Bin delete, permanent delete, multi-step Undo/Redo, inline rename (F2, multi-rename)
- Drag & drop (to/from Finder too), compress to ZIP, Extract All, Create shortcut, Copy as path
- Win11 context menus, Open with, Open in Terminal, Properties (attributes, folder size, drive pie chart)
- Folder Options, hidden items, file name extensions, light and dark mode

Protected folders (Desktop, Documents, Downloads) trigger the usual macOS permission prompt the first time.
