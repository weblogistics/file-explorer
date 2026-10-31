import AppKit
import Quartz
import UniformTypeIdentifiers

final class PaneSplitView: NSSplitView {
    override var dividerColor: NSColor { Theme.separator }
    override var dividerThickness: CGFloat { 1 }
}

/// One Explorer tab: navigation bar, command bar, navigation pane, content and status bar.
final class ExplorerViewController: NSViewController, NSSplitViewDelegate, NSMenuItemValidation {
    weak var host: ExplorerWindowController?
    private(set) var location: Location
    private var history: [Location] = []
    private var historyIndex = -1

    // Chrome
    private let navRow = ColorView(Theme.chrome)
    private let backButton = HoverButton(symbol: "arrow.left", size: 14, tip: "Back (⌘[)")
    private let forwardButton = HoverButton(symbol: "arrow.right", size: 14, tip: "Forward (⌘])")
    private let upButton = HoverButton(symbol: "arrow.up", size: 14, tip: "Up to parent folder (⌘↑)")
    private let refreshButton = HoverButton(symbol: "arrow.clockwise", size: 14, tip: "Refresh (⌘R)")
    private let addressBar = AddressBar()
    private let searchBox = SearchBox()
    private let commandBar = CommandBar()
    private let split = PaneSplitView()
    private let navPane = NavigationPane()
    private let contentArea = ColorView(Theme.content)
    private let sidePane = SidePane()
    private let statusBar = StatusBar()
    private let emptyLabel = makeLabel("", size: 12, color: Theme.secondaryText)

    // Content
    private var detailsView: DetailsListView?
    private var gridView: GridListView?
    private var tilesPage: TilesPageView?
    private var currentList: FileListView?
    private(set) var showingTiles = false

    // Data
    private var allItems: [FileItem] = []
    private var groups: [ItemGroup] = []
    private var state = FolderViewState()
    private let watcher = DirectoryWatcher()
    private var loadGeneration = 0
    private var searchTask: SearchTask?
    private var searchDone = true
    private var loading = false
    private var pendingSelect: Set<String>?
    private var pendingRename: String?
    private var renameGroup: [FileItem] = []
    private var didInitialLayout = false
    private var sideUpdateScheduled = false
    private var lastHidden = Settings.shared.showHidden
    private var lastCompact = Settings.shared.compactView
    private var qlItems: [URL] = []

    init(location: Location) {
        self.location = location
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - View setup

    override func loadView() {
        let root = ColorView(Theme.chrome)
        view = root

        // Navigation row: ← → ↑ ⟳ [address] [search]
        let navButtons = [backButton, forwardButton, upButton, refreshButton]
        for b in navButtons {
            b.fixedSize = NSSize(width: 34, height: 32)
            b.imageBox = 16
            navRow.addSubview(b)
        }
        navRow.addSubview(addressBar)
        navRow.addSubview(searchBox)
        navRow.translatesAutoresizingMaskIntoConstraints = false

        let topSep = ColorView(Theme.separator)
        topSep.translatesAutoresizingMaskIntoConstraints = false
        split.translatesAutoresizingMaskIntoConstraints = false
        for v in [navRow, commandBar, topSep, split, statusBar] as [NSView] { root.addSubview(v) }

        let searchWidth = searchBox.widthAnchor.constraint(equalTo: navRow.widthAnchor, multiplier: 0.24)
        searchWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            navRow.topAnchor.constraint(equalTo: root.topAnchor),
            navRow.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            navRow.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            navRow.heightAnchor.constraint(equalToConstant: 46),
            backButton.leadingAnchor.constraint(equalTo: navRow.leadingAnchor, constant: 8),
            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 2),
            upButton.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 2),
            refreshButton.leadingAnchor.constraint(equalTo: upButton.trailingAnchor, constant: 2),
            addressBar.leadingAnchor.constraint(equalTo: refreshButton.trailingAnchor, constant: 8),
            addressBar.heightAnchor.constraint(equalToConstant: 32),
            addressBar.centerYAnchor.constraint(equalTo: navRow.centerYAnchor),
            searchBox.leadingAnchor.constraint(equalTo: addressBar.trailingAnchor, constant: 8),
            searchBox.trailingAnchor.constraint(equalTo: navRow.trailingAnchor, constant: -12),
            searchBox.heightAnchor.constraint(equalToConstant: 32),
            searchBox.centerYAnchor.constraint(equalTo: navRow.centerYAnchor),
            searchWidth,
            searchBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            searchBox.widthAnchor.constraint(lessThanOrEqualToConstant: 360),

            commandBar.topAnchor.constraint(equalTo: navRow.bottomAnchor),
            commandBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            commandBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            commandBar.heightAnchor.constraint(equalToConstant: 48),
            topSep.topAnchor.constraint(equalTo: commandBar.bottomAnchor),
            topSep.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topSep.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topSep.heightAnchor.constraint(equalToConstant: 1),
            split.topAnchor.constraint(equalTo: topSep.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 26),
        ])
        for b in navButtons { b.centerYAnchor.constraint(equalTo: navRow.centerYAnchor).isActive = true }

        // Split: navigation pane | content | details/preview
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(navPane)
        split.addArrangedSubview(contentArea)
        split.addArrangedSubview(sidePane)
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        split.setHoldingPriority(NSLayoutConstraint.Priority(240), forSubviewAt: 1)
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 2)

        emptyLabel.alignment = .center
        contentArea.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: contentArea.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: contentArea.topAnchor, constant: 48),
        ])

        wireUp()
    }

    private func wireUp() {
        backButton.action = { [weak self] in self?.goBack(nil) }
        forwardButton.action = { [weak self] in self?.goForward(nil) }
        upButton.action = { [weak self] in self?.goUp(nil) }
        refreshButton.action = { [weak self] in self?.refreshAction(nil) }
        backButton.rightMenuProvider = { [weak self] in self?.historyMenu(back: true) }
        forwardButton.rightMenuProvider = { [weak self] in self?.historyMenu(back: false) }

        addressBar.onNavigate = { [weak self] loc in self?.navigate(to: loc) }
        addressBar.onSubmitText = { [weak self] text in self?.navigateText(text) }
        addressBar.onEndEditing = { [weak self] in self?.focusContent() }
        addressBar.rootMenuProvider = { [weak self] in self?.rootLocationItems() ?? [] }
        searchBox.onSearch = { [weak self] q in self?.performSearch(q) }
        searchBox.onClear = { [weak self] in self?.clearSearch() }

        let cb = commandBar
        cb.newButton.menuProvider = { [weak self] in self?.newMenu() }
        cb.cutButton.action = { [weak self] in self?.cut(nil) }
        cb.copyButton.action = { [weak self] in self?.copy(nil) }
        cb.pasteButton.action = { [weak self] in self?.paste(nil) }
        cb.renameButton.action = { [weak self] in self?.renameSelection(nil) }
        cb.shareButton.action = { [weak self] in self?.share(from: self?.commandBar.shareButton) }
        cb.deleteButton.action = { [weak self] in self?.delete(nil) }
        cb.sortButton.menuProvider = { [weak self] in self?.sortMenu() }
        cb.viewButton.menuProvider = { [weak self] in self?.viewMenu() }
        cb.moreButton.menuProvider = { [weak self] in self?.moreMenu() }
        cb.extractButton.action = { [weak self] in self?.extractSelection(nil) }
        cb.backgroundButton.action = { [weak self] in self?.setDesktopBackground() }
        cb.detailsButton.action = { [weak self] in self?.toggleDetailsPane(nil) }

        statusBar.detailsButton.action = { [weak self] in self?.setViewMode(.details) }
        statusBar.iconsButton.action = { [weak self] in self?.setViewMode(.large) }

        navPane.delegate = self
        watcher.onChange = { [weak self] in self?.refresh() }

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(settingsDidChange), name: .settingsChanged, object: nil)
        nc.addObserver(self, selector: #selector(clipboardDidChange), name: .clipboardChanged, object: nil)
        nc.addObserver(self, selector: #selector(pinsDidChange), name: .pinsChanged, object: nil)
        nc.addObserver(self, selector: #selector(recentDidChange), name: .recentChanged, object: nil)
        nc.addObserver(self, selector: #selector(volumesDidChange), name: .volumesChanged, object: nil)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigate(to: location)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if !didInitialLayout && split.bounds.width > 100 {
            didInitialLayout = true
            applyPanes()
        }
    }

    func prepareForClose() {
        searchTask?.cancel()
        watcher.stop()
        NotificationCenter.default.removeObserver(self)
    }

    func focusContent() {
        if showingTiles {
            view.window?.makeFirstResponder(tilesPage?.doc)
        } else {
            currentList?.focus()
        }
    }

    // MARK: - Panes

    private func applyPanes() {
        let s = Settings.shared
        navPane.isHidden = !s.showNavPane
        sidePane.isHidden = s.sidePane == .none
        split.adjustSubviews()
        let w = split.bounds.width
        if !navPane.isHidden { split.setPosition(min(s.navWidth, w * 0.4), ofDividerAt: 0) }
        if !sidePane.isHidden { split.setPosition(w - min(s.sideWidth, w * 0.4) - 1, ofDividerAt: 1) }
        commandBar.detailsButton.isToggled = s.sidePane == .details
        scheduleSideUpdate()
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        i == 0 ? 140 : max(proposed, splitView.bounds.width * 0.4)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        i == 0 ? min(480, splitView.bounds.width * 0.45) : splitView.bounds.width - 200
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard NSApp.currentEvent?.type == .leftMouseDragged else { return }
        if !navPane.isHidden && navPane.frame.width > 100 { Settings.shared.navWidth = navPane.frame.width }
        if !sidePane.isHidden && sidePane.frame.width > 100 { Settings.shared.sideWidth = sidePane.frame.width }
    }

    private func scheduleSideUpdate() {
        guard !sideUpdateScheduled else { return }
        sideUpdateScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            self.sideUpdateScheduled = false
            let mode = Settings.shared.sidePane
            guard mode != .none else { return }
            self.sidePane.show(mode: mode, items: self.selectedItems, location: self.location, total: self.itemCount)
        }
    }

    // MARK: - Navigation

    var currentFolder: URL? { location.folderURL }

    var parentLocation: Location? {
        switch location {
        case .folder(let u):
            if u.path == "/" || (try? u.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true { return .thisPC }
            if u.path == trashURL.path { return .home }
            return .dir(u.deletingLastPathComponent())
        case .search(let u, _): return .dir(u)
        case .gallery: return .home
        default: return nil
        }
    }

    func navigate(to loc: Location, record: Bool = true, select: Set<String>? = nil) {
        if case .folder(let u) = loc {
            guard u.isDirectoryOnDisk else {
                Alerts.show("Location is not available", "\"\(u.path)\" is unavailable. If the location is on this PC, make sure the device or drive is connected and then try again.")
                return
            }
            guard DirectoryLoader.canOpen(u) else {
                Alerts.show("Access denied", "You don't currently have permission to access this folder:\n\n\(u.path)\n\nTo allow access, open System Settings › Privacy & Security › Files and Folders (or Full Disk Access) and enable File Explorer.")
                return
            }
        }
        if !loc.isSearch {
            searchTask?.cancel()
            searchTask = nil
            addressBar.searching = false
            searchBox.setText("")
        }
        let previous = location.scopeURL?.path
        if record && (loc != location || history.isEmpty) {
            if historyIndex < history.count - 1 { history.removeSubrange((historyIndex + 1)...) }
            history.append(loc)
            historyIndex = history.count - 1
        }
        location = loc
        state = Settings.shared.folderState(for: loc)
        pendingSelect = select ?? previous.map { [$0] }
        renameGroup = []
        reloadContent(preserve: false)
        updateChrome()
        host?.tabUpdated(self)
        if view.window?.firstResponder === view.window || !(view.window?.firstResponder is NSTextView) { focusContent() }
    }

    private func updateChrome() {
        backButton.isEnabled = historyIndex > 0
        forwardButton.isEnabled = historyIndex < history.count - 1
        upButton.isEnabled = parentLocation != nil
        addressBar.setLocation(location)
        let scopeTitle: String
        switch location {
        case .search(let u, let q):
            scopeTitle = Location.displayName(for: u)
            if searchBox.field.currentEditor() == nil { searchBox.setText(q) }
        default: scopeTitle = location.title
        }
        searchBox.placeholder = "Search \(scopeTitle)"
        if case .search(let u, _) = location { navPane.select(.dir(u)) } else { navPane.select(location) }
        statusBar.setMode(showingTiles ? nil : state.mode)
        updateCommands()
    }

    @objc func goBack(_ sender: Any?) {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        navigate(to: history[historyIndex], record: false)
    }

    @objc func goForward(_ sender: Any?) {
        guard historyIndex < history.count - 1 else { return }
        historyIndex += 1
        navigate(to: history[historyIndex], record: false)
    }

    @objc func goUp(_ sender: Any?) {
        if let p = parentLocation { navigate(to: p) }
    }

    private func historyMenu(back: Bool) -> NSMenu {
        var items: [NSMenuItem] = []
        let range: [Int] = back ? Array((0..<historyIndex).reversed()) : Array((historyIndex + 1)..<history.count)
        for i in range.prefix(15) {
            let loc = history[i]
            items.append(ClosureMenuItem(loc.title, image: loc.icon) { [weak self] in
                self?.historyIndex = i
                self?.navigate(to: loc, record: false)
            })
        }
        return NSMenu(items: items)
    }

    func rootLocationItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = [
            ClosureMenuItem("Home", image: IconFactory.navIcon(.home)) { [weak self] in self?.navigate(to: .home) },
            ClosureMenuItem("Gallery", image: IconFactory.navIcon(.gallery)) { [weak self] in self?.navigate(to: .gallery) },
            .separator(),
        ]
        for k in KnownFolder.allCases {
            items.append(ClosureMenuItem(k.title, image: IconFactory.knownGlyph(k)) { [weak self] in self?.navigate(to: .dir(k.url)) })
        }
        items.append(.separator())
        items.append(ClosureMenuItem("This PC", image: IconFactory.navIcon(.thisPC)) { [weak self] in self?.navigate(to: .thisPC) })
        items.append(ClosureMenuItem("Recycle Bin", image: IconFactory.navIcon(.recycleBin)) { [weak self] in self?.navigate(to: .dir(trashURL)) })
        return items
    }

    /// Handles text typed into the address bar (paths, "Documents", "This PC", URLs...).
    private func navigateText(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        switch t.lowercased() {
        case "home", "quick access": navigate(to: .home); return
        case "this pc", "computer", "my computer": navigate(to: .thisPC); return
        case "gallery": navigate(to: .gallery); return
        case "recycle bin", "trash": navigate(to: .dir(trashURL)); return
        default: break
        }
        if let k = KnownFolder.allCases.first(where: { $0.title.lowercased() == t.lowercased() }) {
            navigate(to: .dir(k.url))
            return
        }
        if t.hasPrefix("http://") || t.hasPrefix("https://"), let u = URL(string: t) {
            NSWorkspace.shared.open(u)
            return
        }
        var path = (t as NSString).expandingTildeInPath
        if path.hasPrefix("file://"), let u = URL(string: path) { path = u.path }
        if !path.hasPrefix("/") {
            let base = location.scopeURL ?? homeURL
            path = base.appendingPathComponent(path).standardizedFileURL.path
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            let u = URL(fileURLWithPath: path)
            if isDir.boolValue && !u.isPackageOnDisk { navigate(to: .dir(u)) } else { openURLs([u]) }
        } else {
            Alerts.show("File Explorer", "File Explorer can't find '\(t)'. Check the spelling and try again.")
            addressBar.setLocation(location)
        }
    }

    // MARK: - Loading content

    private var itemCount: Int {
        if showingTiles { return tilesPage?.doc.sections.reduce(0) { $0 + $1.tiles.count } ?? 0 }
        return allItems.count
    }

    private func reloadContent(preserve: Bool) {
        loadGeneration += 1
        let gen = loadGeneration
        let keep: Set<String> = preserve ? Set(selectedItems.map(\.path)) : []
        switch location {
        case .home:
            watcher.watch(nil)
            showTilesPage()
            buildHome()
            if !preserve { RecentFiles.shared.refresh() }
        case .thisPC:
            watcher.watch(nil)
            showTilesPage()
            buildThisPC()
        case .gallery:
            watcher.watch(nil)
            showList()
            loadGallery(gen)
        case .folder(let u):
            watcher.watch(u)
            showList()
            loadFolder(u, gen, keep: keep)
        case .search(let scope, let q):
            watcher.watch(nil)
            showList()
            startSearch(scope, q)
        }
    }

    private func loadFolder(_ u: URL, _ gen: Int, keep: Set<String>) {
        let hidden = Settings.shared.showHidden
        loading = true
        if !keep.isEmpty || !allItems.isEmpty { } else { allItems = []; applyItems() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, gen == self.loadGeneration, self.loading else { return }
            self.emptyLabel.stringValue = "Working on it…"
            self.emptyLabel.isHidden = false
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let items = (try? DirectoryLoader.load(u, showHidden: hidden)) ?? []
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.loadGeneration else { return }
                self.loading = false
                self.allItems = items
                let sel = self.pendingSelect ?? keep
                self.pendingSelect = nil
                self.applyItems(select: sel)
            }
        }
    }

    private func loadGallery(_ gen: Int) {
        loading = true
        allItems = []
        applyItems()
        let hidden = Settings.shared.showHidden
        DispatchQueue.global(qos: .userInitiated).async {
            var items: [FileItem] = []
            var opts: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
            if !hidden { opts.insert(.skipsHiddenFiles) }
            let en = FileManager.default.enumerator(at: KnownFolder.pictures.url, includingPropertiesForKeys: FileItem.keys,
                                                    options: opts, errorHandler: { _, _ in true })
            while let u = en?.nextObject() as? URL {
                guard let t = UTType(filenameExtension: u.pathExtension), t.conforms(to: .image) || t.conforms(to: .movie) else { continue }
                items.append(FileItem(url: u))
                if items.count >= 5000 { break }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.loadGeneration else { return }
                self.loading = false
                self.allItems = items
                self.applyItems()
            }
        }
    }

    private func startSearch(_ scope: URL, _ q: String) {
        searchTask?.cancel()
        allItems = []
        searchDone = false
        loading = false
        applyItems()
        addressBar.searching = true
        let task = SearchTask(scope: scope, query: q, showHidden: Settings.shared.showHidden)
        task.onBatch = { [weak self, weak task] batch, done in
            guard let self, let task, self.searchTask === task else { return }
            self.allItems += batch
            if done {
                self.searchDone = true
                self.addressBar.searching = false
            }
            self.applyItems()
        }
        searchTask = task
        task.start()
    }

    private func applyItems(select: Set<String>? = nil) {
        guard !showingTiles else { return }
        groups = Arranger.arrange(allItems, state: state)
        guard let list = currentList else { return }
        list.reload(groups, state: state, search: location.isSearch)
        if let select, !select.isEmpty { list.select(paths: select, scroll: true) }
        if let r = pendingRename, allItems.contains(where: { $0.path == r }) {
            pendingRename = nil
            DispatchQueue.main.async { list.beginRename(path: r) }
        }
        updateEmptyLabel()
        selectionChanged()
    }

    private func updateEmptyLabel() {
        guard !showingTiles else { emptyLabel.isHidden = true; return }
        if !allItems.isEmpty { emptyLabel.isHidden = true; return }
        if loading { return }
        switch location {
        case .search: emptyLabel.stringValue = searchDone ? "No items match your search." : "Working on it…"
        case .gallery: emptyLabel.stringValue = "No photos or videos were found in your Pictures folder."
        default: emptyLabel.stringValue = "This folder is empty."
        }
        emptyLabel.isHidden = false
    }

    private func swapContent(to v: NSView) {
        guard v.superview !== contentArea else { return }
        contentArea.subviews.filter { $0 !== emptyLabel }.forEach { $0.removeFromSuperview() }
        contentArea.addSubview(v, positioned: .below, relativeTo: emptyLabel)
        v.pinEdges(to: contentArea)
    }

    private func showList() {
        showingTiles = false
        let list: FileListView
        if state.mode == .details {
            if detailsView == nil {
                let d = DetailsListView()
                d.delegate = self
                detailsView = d
            }
            list = detailsView!
        } else {
            if gridView == nil {
                let g = GridListView()
                g.delegate = self
                gridView = g
            }
            gridView!.setMode(state.mode)
            list = gridView!
        }
        currentList = list
        swapContent(to: list.view)
    }

    private func showTilesPage() {
        if tilesPage == nil {
            let t = TilesPageView()
            t.doc.delegate = self
            tilesPage = t
        }
        showingTiles = true
        currentList = nil
        emptyLabel.isHidden = true
        swapContent(to: tilesPage!)
        tilesPage?.doc.setSelection([])
    }

    private func buildHome() {
        let quick = Settings.shared.pinned.filter { FileManager.default.fileExists(atPath: $0.path) }.map { u -> Tile in
            let k = KnownFolder.match(u)
            return Tile(url: u, title: k?.title ?? Location.displayName(for: u), subtitle: "Stored locally",
                        icon: IconFactory.folder(size: 48, badge: k), kind: .folder, pinned: true)
        }
        let recent = RecentFiles.shared.items.map { (u, d) -> Tile in
            Tile(url: u, title: u.lastPathComponent,
                 icon: FileIcons.shared.fileIcon(url: u, ext: u.pathExtension.lowercased(), unique: u.pathExtension.isEmpty),
                 kind: .file, columns: [Fmt.date(d), Fmt.abbreviatePath(u.deletingLastPathComponent().path)])
        }
        tilesPage?.doc.sections = [
            TileSection(id: "quick", title: "Quick access", style: .tiles, tiles: quick,
                        emptyText: "Pin folders to Quick access and they'll show up here."),
            TileSection(id: "recent", title: "Recent", style: .rows, tiles: recent,
                        columnTitles: ["Date accessed", "File location"],
                        emptyText: Settings.shared.showRecent ? "After you've opened some files, we'll show the most recent ones here."
                                                              : "Showing recently used files is turned off in Folder Options."),
        ]
        selectionChanged()
    }

    private func buildThisPC() {
        let drives = VolumeInfo.list().map { v in
            Tile(url: v.url, title: v.name, subtitle: v.freeText, icon: IconFactory.drive(size: 48, kind: v.kind),
                 kind: .drive, capacity: (v.total - v.free, v.total))
        }
        let folders = KnownFolder.allCases.map { k in
            Tile(url: k.url, title: k.title, subtitle: "Stored locally", icon: IconFactory.folder(size: 48, badge: k), kind: .folder)
        }
        tilesPage?.doc.sections = [
            TileSection(id: "folders", title: "Folders", style: .tiles, tiles: folders),
            TileSection(id: "drives", title: "Devices and drives", style: .tiles, tiles: drives),
        ]
        selectionChanged()
    }

    /// Re-reads the current location, keeping the selection.
    func refresh(select: Set<String>? = nil) {
        if let select { pendingSelect = select }
        switch location {
        case .search:
            if let select { currentList?.select(paths: select, scroll: true) }
        default:
            reloadContent(preserve: true)
        }
    }

    @objc func refreshAction(_ sender: Any?) {
        if case .search(let s, let q) = location { startSearch(s, q); return }
        if location == .home { RecentFiles.shared.refresh() }
        navPane.refreshTree()
        navPane.select(location)
        reloadContent(preserve: true)
    }

    // MARK: - Search

    private func performSearch(_ q: String) {
        let scope: URL
        switch location {
        case .search(let s, _): scope = s
        case .folder(let u): scope = u
        case .thisPC: scope = URL(fileURLWithPath: "/")
        case .gallery: scope = KnownFolder.pictures.url
        case .home: scope = homeURL
        }
        let loc = Location.search(scope, q)
        if location.isSearch {
            guard loc != location else { return }
            history[historyIndex] = loc
            location = loc
            state = Settings.shared.folderState(for: loc)
            reloadContent(preserve: false)
            updateChrome()
            host?.tabUpdated(self)
        } else {
            navigate(to: loc)
        }
    }

    func debugSelect(_ name: String) {
        currentList?.select(paths: [location.scopeURL?.appendingPathComponent(name).path ?? ""], scroll: true)
        selectionChanged()
    }

    func debugSearch(_ q: String) {
        searchBox.setText(q)
        performSearch(q)
    }

    private func clearSearch() {
        guard case .search(let scope, _) = location else { return }
        if historyIndex > 0, history[historyIndex - 1].scopeURL?.path == scope.path || historyIndex > 0 && !history[historyIndex - 1].isSearch {
            goBack(nil)
        } else {
            navigate(to: .dir(scope))
        }
    }

    // MARK: - View state

    private func saveState() { Settings.shared.setFolderState(state, for: location) }

    func setViewMode(_ m: ViewMode) {
        guard !showingTiles else { return }
        let sel = Set(selectedItems.map(\.path))
        state.mode = m
        saveState()
        showList()
        applyItems(select: sel)
        statusBar.setMode(m)
        currentList?.focus()
    }

    func zoom(_ delta: Int) {
        let order: [ViewMode] = [.details, .list, .small, .medium, .large, .extraLarge]
        let cur = order.firstIndex(of: state.mode) ?? 3
        let next = max(0, min(order.count - 1, cur + delta))
        if order[next] != state.mode { setViewMode(order[next]) }
    }

    func sortBy(_ key: SortKey) {
        if state.sortKey == key { state.ascending.toggle() } else { state.sortKey = key; state.ascending = key.defaultAscending }
        saveState()
        applyItems()
    }

    func setSortDirection(_ asc: Bool) {
        state.ascending = asc
        saveState()
        applyItems()
    }

    func groupBy(_ g: GroupBy) {
        state.groupBy = g
        saveState()
        applyItems()
    }

    // MARK: - Selection & status

    var selectedItems: [FileItem] {
        if showingTiles { return tilesPage?.doc.selectedTiles.map { FileItem(url: $0.url) } ?? [] }
        return currentList?.selectedItems ?? []
    }

    var selectedURLs: [URL] { selectedItems.map(\.url) }

    private func selectionChanged() {
        updateStatus()
        updateCommands()
        scheduleSideUpdate()
        if QLPreviewPanel.sharedPreviewPanelExists(), let p = QLPreviewPanel.shared(), p.isVisible, p.dataSource === self {
            qlItems = selectedURLs
            p.reloadData()
        }
    }

    private func updateStatus() {
        var parts = [Fmt.count(itemCount, "item")]
        let sel = selectedItems
        if !sel.isEmpty {
            var s = "\(Fmt.count(sel.count, "item")) selected"
            let files = sel.filter { !$0.isDirectory }
            if !files.isEmpty && files.count == sel.count { s += "   \(Fmt.size(files.reduce(0) { $0 + $1.size }))" }
            parts.append(s)
        }
        if location.isSearch && !searchDone { parts.append("Searching…") }
        statusBar.update(parts)
    }

    private var folderWritable: Bool {
        guard let f = currentFolder else { return false }
        return FileManager.default.isWritableFile(atPath: f.path)
    }

    private func updateCommands() {
        let sel = selectedItems
        let has = !sel.isEmpty
        let cb = commandBar
        cb.newButton.isEnabled = folderWritable
        cb.cutButton.isEnabled = has
        cb.copyButton.isEnabled = has
        cb.renameButton.isEnabled = has
        cb.shareButton.isEnabled = has
        cb.deleteButton.isEnabled = has
        cb.pasteButton.isEnabled = Clipboard.hasFiles && (folderWritable || (sel.count == 1 && sel[0].isDirectory))
        cb.sortButton.isEnabled = !showingTiles
        cb.viewButton.isEnabled = !showingTiles
        cb.extractButton.isHidden = !(sel.count == 1 && sel[0].isZip)
        cb.backgroundButton.isHidden = !(sel.count == 1 && sel[0].isImage)
        cb.detailsButton.isToggled = Settings.shared.sidePane == .details
    }

    // MARK: - Notifications

    @objc private func settingsDidChange() {
        let s = Settings.shared
        applyPanes()
        if s.showHidden != lastHidden || s.compactView != lastCompact {
            lastHidden = s.showHidden
            lastCompact = s.compactView
            navPane.refreshTree()
            navPane.select(location)
        }
        if showingTiles {
            reloadContent(preserve: true)
        } else if case .search = location {
            applyItems()
        } else {
            reloadContent(preserve: true)
        }
    }

    @objc private func clipboardDidChange() {
        currentList?.refreshVisible()
        updateCommands()
    }

    @objc private func pinsDidChange() { if location == .home { buildHome() } }
    @objc private func recentDidChange() { if location == .home { buildHome() } }
    @objc private func volumesDidChange() { if location == .thisPC { buildThisPC() } }

    // MARK: - Opening

    func openItems(_ items: [FileItem], newTab: Bool = false, newWindow: Bool = false) {
        var folders: [URL] = []
        var files: [URL] = []
        for it in items {
            if it.isDirectory {
                folders.append(it.url)
            } else if it.isAlias, let r = try? URL(resolvingAliasFileAt: it.url), r.isDirectoryOnDisk, !r.isPackageOnDisk {
                folders.append(r)
            } else {
                files.append(it.url)
            }
        }
        for (i, f) in folders.enumerated() {
            if newWindow {
                AppDelegate.shared.newWindow(.dir(f))
            } else if newTab {
                host?.addTab(.dir(f), activate: i == 0)
            } else if i == 0 {
                navigate(to: .dir(f))
            } else {
                host?.addTab(.dir(f), activate: false)
            }
        }
        openURLs(files)
    }

    func openURLs(_ urls: [URL]) {
        for f in urls {
            if NSWorkspace.shared.urlForApplication(toOpen: f) == nil && !f.isPackageOnDisk {
                chooseApp(for: [f])
                continue
            }
            if NSWorkspace.shared.open(f) { Settings.shared.addRecent(f) }
        }
    }

    private func chooseApp(for urls: [URL]) {
        let p = NSOpenPanel()
        p.title = "How do you want to open this file?"
        p.message = "Choose an app to open \"\(urls.first?.lastPathComponent ?? "")\""
        p.prompt = "Open"
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowedContentTypes = [.application]
        p.canChooseDirectories = false
        if p.runModal() == .OK, let app = p.url {
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            urls.forEach { Settings.shared.addRecent($0) }
        }
    }

    @objc func openSelection(_ sender: Any?) { openItems(selectedItems) }
    @objc func openInNewTab(_ sender: Any?) { openItems(selectedItems.filter(\.isDirectory), newTab: true) }
    @objc func openInNewWindow(_ sender: Any?) {
        let dirs = selectedItems.filter(\.isDirectory)
        if dirs.isEmpty { AppDelegate.shared.newWindow(location) } else { openItems(dirs, newWindow: true) }
    }

    // MARK: - Commands

    @objc func newFolder(_ sender: Any?) {
        guard let dir = currentFolder, let u = FileOperations.shared.newFolder(in: dir) else { NSSound.beep(); return }
        pendingRename = u.path
        refresh(select: [u.path])
    }

    func newFile(named name: String, contents: Data = Data()) {
        guard let dir = currentFolder, let u = FileOperations.shared.newFile(in: dir, name: name, contents: contents) else {
            NSSound.beep()
            return
        }
        pendingRename = u.path
        refresh(select: [u.path])
    }

    @objc func newTextDocument(_ sender: Any?) { newFile(named: "New Text Document.txt") }

    @objc func cut(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        Clipboard.put(urls, cut: true)
    }

    @objc func copy(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        Clipboard.put(urls, cut: false)
    }

    @objc func paste(_ sender: Any?) {
        let sel = selectedItems
        let dest = (sender as? URL) ?? (currentFolder == nil && sel.count == 1 && sel[0].isDirectory ? sel[0].url : currentFolder)
        paste(into: dest)
    }

    func paste(into dest: URL?) {
        guard let dest else { NSSound.beep(); return }
        let urls = Clipboard.urls
        guard !urls.isEmpty else { return }
        let cut = Clipboard.isCut
        FileOperations.shared.transfer(urls, to: dest, kind: cut ? .move : .copy) { [weak self] results in
            if cut {
                Clipboard.clearCut()
                NSPasteboard.general.clearContents()
                NotificationCenter.default.post(name: .clipboardChanged, object: nil)
            }
            guard let self else { return }
            if dest.path == self.currentFolder?.path { self.refresh(select: Set(results.map(\.path))) } else { self.refresh() }
        }
    }

    @objc func renameSelection(_ sender: Any?) {
        let sel = selectedItems
        guard let first = sel.first else { return }
        if showingTiles {
            promptRename(first)
            return
        }
        renameGroup = sel.count > 1 ? sel : []
        currentList?.beginRename(path: first.path)
    }

    private func promptRename(_ item: FileItem) {
        let a = NSAlert()
        a.messageText = "Rename"
        a.informativeText = "Enter a new name for \"\(item.name)\":"
        let f = NSTextField(string: item.name)
        f.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        a.accessoryView = f
        a.addButton(withTitle: "Rename")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        if a.runModal() == .alertFirstButtonReturn {
            FileOperations.shared.rename(item.url, to: f.stringValue)
            reloadContent(preserve: true)
        }
    }

    @objc func delete(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        if currentFolder?.path == trashURL.path || NSEvent.modifierFlags.contains(.shift) {
            FileOperations.shared.deletePermanently(urls)
        } else {
            FileOperations.shared.recycle(urls)
        }
        refresh()
    }

    @objc func deletePermanently(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        FileOperations.shared.deletePermanently(urls)
        refresh()
    }

    @objc func undo(_ sender: Any?) {
        UndoStack.shared.undo()
        refresh()
    }

    @objc func redo(_ sender: Any?) {
        UndoStack.shared.redo()
        refresh()
    }

    @objc func copyAsPath(_ sender: Any?) {
        let urls = selectedURLs.isEmpty ? (location.scopeURL.map { [$0] } ?? []) : selectedURLs
        guard !urls.isEmpty else { return }
        Clipboard.putText(urls.map { "\"\($0.path)\"" }.joined(separator: "\n"))
    }

    override func selectAll(_ sender: Any?) {
        if showingTiles {
            var all = Set<[Int]>()
            for (si, s) in (tilesPage?.doc.sections ?? []).enumerated() { for ti in s.tiles.indices { all.insert([si, ti]) } }
            tilesPage?.doc.setSelection(all)
        } else {
            currentList?.selectAllItems()
        }
    }

    @objc func selectNone(_ sender: Any?) {
        if showingTiles { tilesPage?.doc.setSelection([]) } else { currentList?.selectNone() }
    }

    @objc func invertSelection(_ sender: Any?) { currentList?.invertSelection() }

    @objc func showProperties(_ sender: Any?) {
        var urls = selectedURLs
        if urls.isEmpty, let u = location.scopeURL { urls = [u] }
        guard !urls.isEmpty else { return }
        PropertiesWindowController.show(for: urls)
    }

    @objc func compressSelection(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        FileOperations.shared.compress(urls) { [weak self] u in
            guard let self, let u else { return }
            if u.deletingLastPathComponent().path == self.currentFolder?.path {
                self.pendingRename = u.path
                self.refresh(select: [u.path])
            }
        }
    }

    @objc func extractSelection(_ sender: Any?) {
        guard let zip = selectedItems.first(where: \.isZip)?.url else { return }
        let suggested = FileOperations.uniqueURL(zip.deletingPathExtension().lastPathComponent, in: zip.deletingLastPathComponent(), style: .number)
        let a = NSAlert()
        a.messageText = "Extract Compressed (Zipped) Folders"
        a.informativeText = "Select a Destination and Extract Files.\nFiles will be extracted to this folder:"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 56))
        let field = NSTextField(string: suggested.path)
        field.frame = NSRect(x: 0, y: 30, width: 290, height: 24)
        let browse = NSButton(title: "Browse…", target: nil, action: nil)
        browse.frame = NSRect(x: 296, y: 27, width: 84, height: 30)
        let handler = ButtonHandler {
            let p = NSOpenPanel()
            p.canChooseDirectories = true
            p.canChooseFiles = false
            p.canCreateDirectories = true
            p.directoryURL = zip.deletingLastPathComponent()
            if p.runModal() == .OK, let u = p.url { field.stringValue = u.path }
        }
        browse.target = handler
        browse.action = #selector(ButtonHandler.fire)
        let show = NSButton(checkboxWithTitle: "Show extracted files when complete", target: nil, action: nil)
        show.state = .on
        show.frame = NSRect(x: 0, y: 0, width: 380, height: 20)
        [field, browse, show].forEach { box.addSubview($0) }
        a.accessoryView = box
        a.addButton(withTitle: "Extract")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        _ = handler
        let dest = URL(fileURLWithPath: (field.stringValue as NSString).expandingTildeInPath, isDirectory: true)
        let showWhenDone = show.state == .on
        FileOperations.shared.extract(zip, to: dest) { [weak self] out in
            guard let self, let out else { return }
            if showWhenDone { self.navigate(to: .dir(out)) } else { self.refresh(select: [out.path]) }
        }
    }

    func share(from v: NSView?, at point: NSPoint? = nil) {
        let urls = selectedURLs
        guard !urls.isEmpty, let v = v ?? currentList?.view ?? tilesPage else { return }
        let picker = NSSharingServicePicker(items: urls)
        if let point {
            picker.show(relativeTo: NSRect(origin: point, size: NSSize(width: 1, height: 1)), of: v, preferredEdge: .maxY)
        } else {
            picker.show(relativeTo: v.bounds, of: v, preferredEdge: .minY)
        }
    }

    private func setDesktopBackground() {
        guard let img = selectedItems.first(where: \.isImage)?.url else { return }
        for s in NSScreen.screens { try? NSWorkspace.shared.setDesktopImageURL(img, for: s, options: [:]) }
    }

    @objc func openInTerminal(_ sender: Any?) {
        let sel = selectedItems
        let dir = (sel.count == 1 && sel[0].isDirectory) ? sel[0].url : (location.scopeURL ?? homeURL)
        NSWorkspace.shared.open([dir], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func revealInFinder(_ sender: Any?) {
        let urls = selectedURLs
        if urls.isEmpty, let u = location.scopeURL { NSWorkspace.shared.open(u) } else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    private func createShortcut(_ items: [FileItem]) {
        var made: [String] = []
        for it in items {
            let dir = (currentFolder ?? it.parent)
            let base = it.isDirectory ? it.name : (it.name as NSString).deletingPathExtension
            let dest = FileOperations.uniqueURL("\(base) - Shortcut", in: dir, style: .number)
            do {
                let data = try it.url.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
                try URL.writeBookmarkData(data, to: dest)
                made.append(dest.path)
            } catch {
                Alerts.show("Couldn't create shortcut", error.localizedDescription)
            }
        }
        if !made.isEmpty { refresh(select: Set(made)) }
    }

    @objc func togglePin(_ sender: Any?) {
        let dirs = selectedItems.filter(\.isDirectory)
        let targets = dirs.isEmpty ? (currentFolder.map { [$0] } ?? []) : dirs.map(\.url)
        for u in targets { Settings.shared.isPinned(u) ? Settings.shared.unpin(u) : Settings.shared.pin(u) }
    }

    @objc func focusSearch(_ sender: Any?) { searchBox.focus() }
    @objc func focusAddressBar(_ sender: Any?) { addressBar.beginEditing() }

    @objc func setViewModeAction(_ sender: Any?) {
        if let m = (sender as? NSMenuItem).flatMap({ ViewMode(rawValue: $0.tag) }) { setViewMode(m) }
    }

    @objc func sortByAction(_ sender: Any?) {
        if let i = (sender as? NSMenuItem)?.tag, let k = SortKey.allCases[safe: i] { sortBy(k) }
    }

    @objc func groupByAction(_ sender: Any?) {
        if let i = (sender as? NSMenuItem)?.tag, let g = GroupBy.allCases[safe: i] { groupBy(g) }
    }

    @objc func toggleCompact(_ sender: Any?) { Settings.shared.compactView.toggle() }
    @objc func toggleNavPane(_ sender: Any?) { Settings.shared.showNavPane.toggle() }
    @objc func toggleExtensions(_ sender: Any?) { Settings.shared.showExtensions.toggle() }
    @objc func toggleHidden(_ sender: Any?) { Settings.shared.showHidden.toggle() }
    @objc func toggleDetailsPane(_ sender: Any?) {
        Settings.shared.sidePane = Settings.shared.sidePane == .details ? .none : .details
    }
    @objc func togglePreviewPane(_ sender: Any?) {
        Settings.shared.sidePane = Settings.shared.sidePane == .preview ? .none : .preview
    }

    @objc func goHome(_ sender: Any?) { navigate(to: .home) }
    @objc func goThisPC(_ sender: Any?) { navigate(to: .thisPC) }
    @objc func goGallery(_ sender: Any?) { navigate(to: .gallery) }
    @objc func goRecycleBin(_ sender: Any?) { navigate(to: .dir(trashURL)) }
    @objc func goUserFolder(_ sender: Any?) { navigate(to: .dir(homeURL)) }
    @objc func goKnownFolder(_ sender: Any?) {
        if let i = (sender as? NSMenuItem)?.tag, let k = KnownFolder.allCases[safe: i] { navigate(to: .dir(k.url)) }
    }

    @objc func quickLook(_ sender: Any?) {
        guard let p = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && p.isVisible {
            p.orderOut(nil)
        } else if !selectedURLs.isEmpty {
            p.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Keyboard

    func handleKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .shift, .control])
        switch e.keyCode {
        case 36, 76: // Return / Enter
            if mods == .option { showProperties(nil); return true }
            if mods.isEmpty { openSelection(nil); return true }
        case 51: // Backspace → Back (Windows)
            if mods.isEmpty { goBack(nil); return true }
        case 117: // Forward delete
            if mods.contains(.shift) { deletePermanently(nil) } else { delete(nil) }
            return true
        case 123 where mods == .option: goBack(nil); return true
        case 124 where mods == .option: goForward(nil); return true
        case 126 where mods == .option: goUp(nil); return true
        case 125 where mods == .command: openSelection(nil); return true
        case 120: renameSelection(nil); return true          // F2
        case 96: refreshAction(nil); return true              // F5
        case 99: focusSearch(nil); return true                // F3
        case 97: focusAddressBar(nil); return true            // F6
        case 49 where mods.isEmpty: quickLook(nil); return true // Space
        case 53: // Esc
            if Clipboard.isCut { Clipboard.clearCut(); return true }
        default: break
        }
        return false
    }

    // MARK: - Menus

    func newMenu() -> NSMenu {
        let writable = folderWritable
        return NSMenu(items: [
            ClosureMenuItem("Folder", image: IconFactory.folder(size: 16), key: "n", modifiers: [.command, .shift], enabled: writable) { [weak self] in
                self?.newFolder(nil)
            },
            ClosureMenuItem("Shortcut", symbol: "arrowshape.turn.up.right", enabled: writable && !selectedItems.isEmpty) { [weak self] in
                guard let self else { return }
                self.createShortcut(self.selectedItems)
            },
            .separator(),
            ClosureMenuItem("Text Document", symbol: "doc.text", enabled: writable) { [weak self] in
                self?.newFile(named: "New Text Document.txt")
            },
            ClosureMenuItem("Rich Text Document", symbol: "doc.richtext", enabled: writable) { [weak self] in
                let rtf = "{\\rtf1\\ansi\\deff0 {\\fonttbl {\\f0 Helvetica;}}\\f0\\fs24 }"
                self?.newFile(named: "New Rich Text Document.rtf", contents: Data(rtf.utf8))
            },
            ClosureMenuItem("Markdown Document", symbol: "doc.plaintext", enabled: writable) { [weak self] in
                self?.newFile(named: "New Markdown Document.md")
            },
            ClosureMenuItem("Compressed (zipped) Folder", symbol: "doc.zipper", enabled: writable) { [weak self] in
                let empty = Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))
                self?.newFile(named: "New Compressed (zipped) Folder.zip", contents: empty)
            },
        ])
    }

    func viewMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = ViewMode.allCases.map { m in
            ClosureMenuItem(m.title, symbol: m.symbol, key: "\(m.rawValue + 1)", checked: state.mode == m && !showingTiles,
                            enabled: !showingTiles) { [weak self] in self?.setViewMode(m) }
        }
        items.append(.separator())
        items.append(ClosureMenuItem("Compact view", symbol: "rectangle.compress.vertical", checked: Settings.shared.compactView) {
            Settings.shared.compactView.toggle()
        })
        let s = Settings.shared
        items.append(NSMenu.sub("Show", symbol: "checkmark.rectangle", [
            ClosureMenuItem("Navigation pane", checked: s.showNavPane) { s.showNavPane.toggle() },
            ClosureMenuItem("Details pane", key: "p", modifiers: [.option, .shift], checked: s.sidePane == .details) {
                s.sidePane = s.sidePane == .details ? .none : .details
            },
            ClosureMenuItem("Preview pane", key: "p", modifiers: [.option], checked: s.sidePane == .preview) {
                s.sidePane = s.sidePane == .preview ? .none : .preview
            },
            .separator(),
            ClosureMenuItem("File name extensions", checked: s.showExtensions) { s.showExtensions.toggle() },
            ClosureMenuItem("Hidden items", key: ".", modifiers: [.command, .shift], checked: s.showHidden) { s.showHidden.toggle() },
        ]))
        return items
    }

    func viewMenu() -> NSMenu { NSMenu(items: viewMenuItems()) }

    func sortMenuItems() -> [NSMenuItem] {
        var keys: [SortKey] = [.name, .modified, .type, .size, .created]
        if location.isSearch { keys.append(.folder) }
        var items: [NSMenuItem] = keys.map { k in
            ClosureMenuItem(k.title, checked: state.sortKey == k) { [weak self] in
                guard let self else { return }
                if self.state.sortKey != k { self.sortBy(k) }
            }
        }
        items.append(.separator())
        items.append(ClosureMenuItem("Ascending", symbol: "arrow.up", checked: state.ascending) { [weak self] in self?.setSortDirection(true) })
        items.append(ClosureMenuItem("Descending", symbol: "arrow.down", checked: !state.ascending) { [weak self] in self?.setSortDirection(false) })
        items.append(.separator())
        items.append(NSMenu.sub("Group by", symbol: "square.stack.3d.up", groupMenuItems()))
        return items
    }

    func groupMenuItems() -> [NSMenuItem] {
        var opts: [GroupBy] = [.name, .modified, .type, .size]
        if location == .gallery { opts.append(.month) }
        var items: [NSMenuItem] = opts.map { g in
            ClosureMenuItem(g.title, checked: state.groupBy == g) { [weak self] in self?.groupBy(g) }
        }
        items.append(.separator())
        items.append(ClosureMenuItem("(None)", checked: state.groupBy == .none) { [weak self] in self?.groupBy(.none) })
        return items
    }

    func sortMenu() -> NSMenu { NSMenu(items: sortMenuItems()) }

    func moreMenu() -> NSMenu {
        let sel = selectedItems
        let pinTargets = sel.filter(\.isDirectory)
        let pinURL = pinTargets.first?.url ?? currentFolder
        let pinned = pinURL.map { Settings.shared.isPinned($0) } ?? false
        return NSMenu(items: [
            ClosureMenuItem(UndoStack.shared.undoName.map { "Undo \($0)" } ?? "Undo", symbol: "arrow.uturn.backward", key: "z",
                            enabled: UndoStack.shared.undoName != nil) { [weak self] in self?.undo(nil) },
            ClosureMenuItem(pinned ? "Unpin from Quick access" : "Pin to Quick access", symbol: pinned ? "pin.slash" : "pin",
                            enabled: pinURL != nil) { [weak self] in self?.togglePin(nil) },
            .separator(),
            ClosureMenuItem("Select all", symbol: "checklist", key: "a") { [weak self] in self?.selectAll(nil) },
            ClosureMenuItem("Select none", symbol: "square.dashed") { [weak self] in self?.selectNone(nil) },
            ClosureMenuItem("Invert selection", symbol: "checklist.unchecked", enabled: !showingTiles) { [weak self] in self?.invertSelection(nil) },
            .separator(),
            ClosureMenuItem("Copy as path", symbol: "link", key: "c", modifiers: [.command, .shift]) { [weak self] in self?.copyAsPath(nil) },
            ClosureMenuItem("Open in Terminal", symbol: "terminal") { [weak self] in self?.openInTerminal(nil) },
            ClosureMenuItem("Properties", symbol: "info.circle", key: "i") { [weak self] in self?.showProperties(nil) },
            ClosureMenuItem("Options", symbol: "gearshape") { AppDelegate.shared.showFolderOptions(nil) },
        ])
    }

    private func openWithItem(_ items: [FileItem]) -> NSMenuItem? {
        guard let f = items.first, !f.isDirectory else { return nil }
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: f.url)
        let def = NSWorkspace.shared.urlForApplication(toOpen: f.url)
        var mi: [NSMenuItem] = []
        let urls = items.map(\.url)
        for app in apps.prefix(20) {
            let icon = (NSWorkspace.shared.icon(forFile: app.path).copy() as? NSImage) ?? NSImage()
            icon.size = NSSize(width: 16, height: 16)
            let name = FileManager.default.displayName(atPath: app.path)
            mi.append(ClosureMenuItem(app == def ? "\(name) (default)" : name, image: icon) {
                NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                urls.forEach { Settings.shared.addRecent($0) }
            })
        }
        if !mi.isEmpty { mi.append(.separator()) }
        mi.append(ClosureMenuItem("Choose another app…") { [weak self] in self?.chooseApp(for: urls) })
        return NSMenu.sub("Open with", symbol: "arrow.up.forward.app", mi)
    }

    func itemMenu(_ items: [FileItem], at point: NSPoint? = nil, in v: NSView? = nil) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let quick = NSMenuItem()
        quick.view = QuickActionsView(actions: [
            .init(symbol: "scissors", tip: "Cut") { [weak self] in self?.cut(nil) },
            .init(symbol: "doc.on.doc", tip: "Copy") { [weak self] in self?.copy(nil) },
            .init(symbol: "character.cursor.ibeam", tip: "Rename") { [weak self] in self?.renameSelection(nil) },
            .init(symbol: "square.and.arrow.up", tip: "Share") { [weak self] in self?.share(from: v, at: point) },
            .init(symbol: "trash", tip: "Delete") { [weak self] in self?.delete(nil) },
        ])
        m.addItem(quick)
        m.addItem(.separator())

        let allDirs = items.allSatisfy(\.isDirectory)
        let open = ClosureMenuItem("Open", symbol: "arrow.up.forward.square", key: "\r", modifiers: []) { [weak self] in self?.openItems(items) }
        open.attributedTitle = NSAttributedString(string: "Open", attributes: [.font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)])
        m.addItem(open)
        if allDirs {
            m.addItem(ClosureMenuItem("Open in new tab", symbol: "plus.square.on.square") { [weak self] in self?.openItems(items, newTab: true) })
            m.addItem(ClosureMenuItem("Open in new window", symbol: "macwindow.badge.plus") { [weak self] in self?.openItems(items, newWindow: true) })
            if items.count == 1 {
                let pinned = Settings.shared.isPinned(items[0].url)
                m.addItem(ClosureMenuItem(pinned ? "Unpin from Quick access" : "Pin to Quick access", symbol: pinned ? "pin.slash" : "pin") {
                    pinned ? Settings.shared.unpin(items[0].url) : Settings.shared.pin(items[0].url)
                })
            }
        } else if let ow = openWithItem(items) {
            m.addItem(ow)
        }
        if items.count == 1 && items[0].isZip {
            m.addItem(ClosureMenuItem("Extract All…", symbol: "archivebox") { [weak self] in self?.extractSelection(nil) })
        }
        if items.count == 1 && items[0].isImage {
            m.addItem(ClosureMenuItem("Set as desktop background", symbol: "photo") { [weak self] in self?.setDesktopBackground() })
        }
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Compress to ZIP file", symbol: "doc.zipper") { [weak self] in self?.compressSelection(nil) })
        m.addItem(ClosureMenuItem("Copy as path", symbol: "link", key: "c", modifiers: [.command, .shift]) { [weak self] in self?.copyAsPath(nil) })
        if items.count == 1 && items[0].isDirectory && Clipboard.hasFiles {
            m.addItem(ClosureMenuItem("Paste into folder", symbol: "doc.on.clipboard") { [weak self] in self?.paste(into: items[0].url) })
        }
        m.addItem(ClosureMenuItem("Create shortcut", symbol: "arrowshape.turn.up.right", enabled: folderWritable) { [weak self] in
            self?.createShortcut(items)
        })
        m.addItem(ClosureMenuItem("Properties", symbol: "info.circle", key: "i") { [weak self] in self?.showProperties(nil) })
        m.addItem(.separator())
        if items.count == 1 && items[0].isDirectory {
            m.addItem(ClosureMenuItem("Open in Terminal", symbol: "terminal") { [weak self] in self?.openInTerminal(nil) })
        }
        if location.isSearch || location == .home {
            m.addItem(ClosureMenuItem("Open file location", symbol: "folder") { [weak self] in
                guard let first = items.first else { return }
                self?.navigate(to: .dir(first.parent), select: Set(items.map(\.path)))
            })
        }
        m.addItem(ClosureMenuItem("Show in Finder", symbol: "magnifyingglass") { NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url)) })
        return m
    }

    func backgroundMenu() -> NSMenu {
        let undoName = UndoStack.shared.undoName
        return NSMenu(items: [
            NSMenu.sub("View", symbol: "rectangle.grid.1x2", viewMenuItems()),
            NSMenu.sub("Sort by", symbol: "arrow.up.arrow.down", sortMenuItems()),
            NSMenu.sub("Group by", symbol: "square.stack.3d.up", groupMenuItems()),
            .separator(),
            ClosureMenuItem("Refresh", symbol: "arrow.clockwise", key: "r") { [weak self] in self?.refreshAction(nil) },
            .separator(),
            ClosureMenuItem("Paste", symbol: "doc.on.clipboard", key: "v", enabled: Clipboard.hasFiles && folderWritable) { [weak self] in
                self?.paste(into: self?.currentFolder)
            },
            ClosureMenuItem(undoName.map { "Undo \($0)" } ?? "Undo", symbol: "arrow.uturn.backward", key: "z", enabled: undoName != nil) { [weak self] in
                self?.undo(nil)
            },
            .separator(),
            ClosureMenuItem("Open in Terminal", symbol: "terminal") { [weak self] in self?.openInTerminal(nil) },
            .separator(),
            NSMenu.sub("New", symbol: "plus.circle", newMenu().items.map { $0.copy() as! NSMenuItem }),
            .separator(),
            ClosureMenuItem("Properties", symbol: "info.circle", key: "i") { [weak self] in self?.showProperties(nil) },
        ])
    }

    // MARK: - Menu validation

    private var isEditingText: Bool { view.window?.firstResponder is NSTextView }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let has = !selectedItems.isEmpty
        switch item.action {
        case #selector(cut(_:)), #selector(copy(_:)), #selector(delete(_:)), #selector(deletePermanently(_:)),
             #selector(compressSelection(_:)), #selector(openSelection(_:)), #selector(quickLook(_:)):
            return has
        case #selector(renameSelection(_:)):
            return has && !isEditingText
        case #selector(paste(_:)):
            return Clipboard.hasFiles && (folderWritable || selectedItems.first?.isDirectory == true)
        case #selector(newFolder(_:)), #selector(newTextDocument(_:)):
            return folderWritable
        case #selector(undo(_:)):
            item.title = UndoStack.shared.undoName.map { "Undo \($0)" } ?? "Undo"
            return UndoStack.shared.undoName != nil
        case #selector(redo(_:)):
            item.title = UndoStack.shared.redoName.map { "Redo \($0)" } ?? "Redo"
            return UndoStack.shared.redoName != nil
        case #selector(goBack(_:)): return historyIndex > 0
        case #selector(goForward(_:)): return historyIndex < history.count - 1
        case #selector(goUp(_:)): return parentLocation != nil
        case #selector(openInNewTab(_:)): return selectedItems.contains { $0.isDirectory }
        case #selector(extractSelection(_:)): return selectedItems.count == 1 && selectedItems[0].isZip
        case #selector(invertSelection(_:)): return !showingTiles
        case #selector(setViewModeAction(_:)):
            item.state = (!showingTiles && state.mode.rawValue == item.tag) ? .on : .off
            return !showingTiles
        case #selector(sortByAction(_:)):
            item.state = SortKey.allCases[safe: item.tag] == state.sortKey ? .on : .off
            return !showingTiles
        case #selector(groupByAction(_:)):
            item.state = GroupBy.allCases[safe: item.tag] == state.groupBy ? .on : .off
            return !showingTiles
        case #selector(toggleCompact(_:)): item.state = Settings.shared.compactView ? .on : .off
        case #selector(toggleNavPane(_:)): item.state = Settings.shared.showNavPane ? .on : .off
        case #selector(toggleDetailsPane(_:)): item.state = Settings.shared.sidePane == .details ? .on : .off
        case #selector(togglePreviewPane(_:)): item.state = Settings.shared.sidePane == .preview ? .on : .off
        case #selector(toggleExtensions(_:)): item.state = Settings.shared.showExtensions ? .on : .off
        case #selector(toggleHidden(_:)): item.state = Settings.shared.showHidden ? .on : .off
        case #selector(togglePin(_:)):
            let u = selectedItems.first(where: \.isDirectory)?.url ?? currentFolder
            item.title = (u.map { Settings.shared.isPinned($0) } ?? false) ? "Unpin from Quick access" : "Pin to Quick access"
            return u != nil
        default: break
        }
        return true
    }

    // MARK: - Quick Look

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        qlItems = selectedURLs
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

extension ExplorerViewController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { qlItems.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { qlItems[index] as NSURL }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown, let list = currentList?.view {
            list.window?.makeFirstResponder(list)
            (currentList as? DetailsListView)?.table.keyDown(with: event)
            (currentList as? GridListView)?.collection.keyDown(with: event)
            return true
        }
        return false
    }
}

// MARK: - Delegates

extension ExplorerViewController: FileListDelegate {
    var listCurrentFolder: URL? { currentFolder }

    func listOpen(_ items: [FileItem]) { openItems(items) }
    func listSelectionChanged() { selectionChanged() }
    func listKeyDown(_ event: NSEvent) -> Bool { handleKey(event) }
    func listSortClicked(_ key: SortKey) { sortBy(key) }
    func listZoom(_ delta: Int) { zoom(delta) }

    func listMenu(for items: [FileItem]) -> NSMenu? {
        let point = view.window.map { contentArea.convert($0.mouseLocationOutsideOfEventStream, from: nil) }
        return items.isEmpty ? backgroundMenu() : itemMenu(items, at: point, in: contentArea)
    }

    func listRename(_ item: FileItem, to name: String) {
        var newName = name
        if !Settings.shared.showExtensions && !item.isDirectory && !item.ext.isEmpty && !item.name.hasPrefix(".") {
            newName += "." + (item.name as NSString).pathExtension
        }
        let group = renameGroup
        renameGroup = []
        if group.count > 1 {
            // Windows renames a multi-selection to "Name (1)", "Name (2)", ...
            let ns = newName as NSString
            let base = item.isDirectory ? newName : ns.deletingPathExtension
            var paths: Set<String> = []
            var n = 1
            for it in [item] + group.filter({ $0 != item }) {
                let ext = it.isDirectory ? "" : (it.name as NSString).pathExtension
                var candidate = "\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")
                while FileManager.default.fileExists(atPath: it.parent.appendingPathComponent(candidate).path) {
                    n += 1
                    candidate = "\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")
                }
                if let u = FileOperations.shared.rename(it.url, to: candidate, registerUndo: true) { paths.insert(u.path) }
                n += 1
            }
            refresh(select: paths)
            return
        }
        if let u = FileOperations.shared.rename(item.url, to: newName) {
            refresh(select: [u.path])
        } else {
            currentList?.refreshVisible()
            applyItems()
        }
    }

    func listDrop(_ urls: [URL], into folder: URL, copy: Bool) -> Bool {
        if folder.path == trashURL.path {
            FileOperations.shared.recycle(urls)
            refresh()
            return true
        }
        FileOperations.shared.transfer(urls, to: folder, kind: copy ? .copy : .move) { [weak self] results in
            guard let self else { return }
            if folder.path == self.currentFolder?.path { self.refresh(select: Set(results.map(\.path))) } else { self.refresh() }
        }
        return true
    }
}

extension ExplorerViewController: NavigationPaneDelegate {
    func navPaneNavigate(_ location: Location) {
        if location != self.location { navigate(to: location) }
    }

    func navPaneKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 96, 120, 123, 124, 126, 51, 99, 97: return handleKey(event)
        default: return false
        }
    }

    func navPaneDrop(_ urls: [URL], into folder: URL, copy: Bool) -> Bool { listDrop(urls, into: folder, copy: copy) }

    func navPaneMenu(for node: NavNode) -> NSMenu? {
        guard let loc = node.location else { return nil }
        var items: [NSMenuItem] = []
        if node.expandable || node.kind == .thisPC {
            let expanded = navPane.outline.isItemExpanded(node)
            items.append(ClosureMenuItem(expanded ? "Collapse" : "Expand") { [weak self] in
                expanded ? self?.navPane.outline.collapseItem(node) : self?.navPane.outline.expandItem(node)
            })
            items.append(.separator())
        }
        items.append(ClosureMenuItem("Open in new tab", symbol: "plus.square.on.square") { [weak self] in self?.host?.addTab(loc) })
        items.append(ClosureMenuItem("Open in new window", symbol: "macwindow.badge.plus") { AppDelegate.shared.newWindow(loc) })
        if let u = node.url {
            if node.kind == .recycleBin {
                items.append(.separator())
                items.append(ClosureMenuItem("Empty Recycle Bin", symbol: "trash.slash") { FileOperations.shared.emptyRecycleBin() })
            } else {
                let pinned = Settings.shared.isPinned(u)
                items.append(ClosureMenuItem(pinned ? "Unpin from Quick access" : "Pin to Quick access", symbol: pinned ? "pin.slash" : "pin") {
                    pinned ? Settings.shared.unpin(u) : Settings.shared.pin(u)
                })
                items.append(.separator())
                if Clipboard.hasFiles {
                    items.append(ClosureMenuItem("Paste", symbol: "doc.on.clipboard") { [weak self] in self?.paste(into: u) })
                }
                items.append(ClosureMenuItem("Copy as path", symbol: "link") { Clipboard.putText("\"\(u.path)\"") })
                items.append(ClosureMenuItem("Open in Terminal", symbol: "terminal") {
                    NSWorkspace.shared.open([u], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                            configuration: NSWorkspace.OpenConfiguration())
                })
                if node.kind == .drive, VolumeInfo.info(for: u)?.ejectable == true {
                    items.append(ClosureMenuItem("Eject", symbol: "eject") { ExplorerViewController.eject(u) })
                }
            }
            items.append(.separator())
            items.append(ClosureMenuItem("Properties", symbol: "info.circle") { PropertiesWindowController.show(for: [u]) })
        }
        return NSMenu(items: items)
    }

    static func eject(_ u: URL) {
        do { try NSWorkspace.shared.unmountAndEjectDevice(at: u) } catch {
            Alerts.show("Problem Ejecting Device", "This device is currently in use. Close any programs or windows that might be using the device, and then try again.\n\n\(error.localizedDescription)")
        }
    }
}

extension ExplorerViewController: TilesPageDelegate {
    func tilesOpen(_ tile: Tile) {
        switch tile.kind {
        case .folder, .drive: navigate(to: .dir(tile.url))
        case .file: openURLs([tile.url])
        }
    }

    func tilesSelectionChanged() { selectionChanged() }
    func tilesKeyDown(_ e: NSEvent) -> Bool { handleKey(e) }

    func tilesMenu(_ tiles: [Tile]) -> NSMenu? {
        guard let t = tiles.first else {
            return NSMenu(items: [ClosureMenuItem("Refresh", symbol: "arrow.clockwise") { [weak self] in self?.refreshAction(nil) }])
        }
        var items: [NSMenuItem] = []
        let open = ClosureMenuItem("Open", symbol: "arrow.up.forward.square") { [weak self] in self?.tilesOpen(t) }
        open.attributedTitle = NSAttributedString(string: "Open", attributes: [.font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)])
        items.append(open)
        switch t.kind {
        case .folder, .drive:
            items.append(ClosureMenuItem("Open in new tab", symbol: "plus.square.on.square") { [weak self] in self?.host?.addTab(.dir(t.url)) })
            items.append(ClosureMenuItem("Open in new window", symbol: "macwindow.badge.plus") { AppDelegate.shared.newWindow(.dir(t.url)) })
            if t.kind == .folder {
                let pinned = Settings.shared.isPinned(t.url)
                items.append(ClosureMenuItem(pinned ? "Unpin from Quick access" : "Pin to Quick access", symbol: pinned ? "pin.slash" : "pin") {
                    pinned ? Settings.shared.unpin(t.url) : Settings.shared.pin(t.url)
                })
            }
            if t.kind == .drive, VolumeInfo.info(for: t.url)?.ejectable == true {
                items.append(ClosureMenuItem("Eject", symbol: "eject") { ExplorerViewController.eject(t.url) })
            }
        case .file:
            if let ow = openWithItem([FileItem(url: t.url)]) { items.append(ow) }
            items.append(ClosureMenuItem("Open file location", symbol: "folder") { [weak self] in
                self?.navigate(to: .dir(t.url.deletingLastPathComponent()), select: [t.url.path])
            })
        }
        items.append(.separator())
        if t.kind != .drive {
            items.append(ClosureMenuItem("Cut", symbol: "scissors", key: "x") { [weak self] in self?.cut(nil) })
            items.append(ClosureMenuItem("Copy", symbol: "doc.on.doc", key: "c") { [weak self] in self?.copy(nil) })
        }
        items.append(ClosureMenuItem("Copy as path", symbol: "link") { Clipboard.putText(tiles.map { "\"\($0.url.path)\"" }.joined(separator: "\n")) })
        items.append(.separator())
        items.append(ClosureMenuItem("Properties", symbol: "info.circle", key: "i") { PropertiesWindowController.show(for: tiles.map(\.url)) })
        return NSMenu(items: items)
    }
}

extension NSFont {
    func withWeight(_ w: NSFont.Weight) -> NSFont { .systemFont(ofSize: pointSize, weight: w) }
}

// MARK: - Windows 11 style quick action row at the top of context menus

final class QuickActionsView: NSView {
    struct Action {
        let symbol: String
        let tip: String
        let handler: () -> Void
    }
    private let actions: [Action]
    private var hovered: Int?
    private var tracking: NSTrackingArea?
    private let slot: CGFloat = 40

    init(actions: [Action]) {
        self.actions = actions
        super.init(frame: NSRect(x: 0, y: 0, width: 16 + CGFloat(actions.count) * 44, height: 40))
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private func rect(_ i: Int) -> NSRect { NSRect(x: 10 + CGFloat(i) * 44, y: 3, width: slot, height: 34) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    private func index(at e: NSEvent) -> Int? {
        let p = convert(e.locationInWindow, from: nil)
        return actions.indices.first { rect($0).contains(p) }
    }

    override func mouseMoved(with event: NSEvent) {
        let i = index(at: event)
        if i != hovered {
            hovered = i
            toolTip = i.map { actions[$0].tip }
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) { hovered = nil; needsDisplay = true }

    override func mouseUp(with event: NSEvent) {
        guard let i = index(at: event) else { return }
        let a = actions[i]
        enclosingMenuItem?.menu?.cancelTracking()
        DispatchQueue.main.async { a.handler() }
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, a) in actions.enumerated() {
            let r = rect(i)
            if hovered == i { Draw.rounded(r, 5, fill: Theme.buttonHover) }
            Draw.symbol(Sym.image(a.symbol, size: 15), in: r, color: NSColor.labelColor)
        }
    }
}
