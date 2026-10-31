import AppKit

final class ExplorerWindowController: NSWindowController, NSWindowDelegate, TabStripDelegate {
    let tabStrip = TabStripView()
    private let host = ColorView(Theme.chrome)
    private(set) var tabs: [ExplorerViewController] = []
    private(set) var activeTab: ExplorerViewController?
    private static var autosaveUsed = false

    init(location: Location) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        for b: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            w.standardWindowButton(b)?.isHidden = true
        }
        w.minSize = NSSize(width: 620, height: 400)
        w.tabbingMode = .disallowed
        w.backgroundColor = Theme.content
        w.isReleasedWhenClosed = false
        w.collectionBehavior.insert(.fullScreenPrimary)
        super.init(window: w)
        w.delegate = self

        let root = ColorView(Theme.content)
        tabStrip.delegate = self
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        host.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabStrip)
        root.addSubview(host)
        NSLayoutConstraint.activate([
            tabStrip.topAnchor.constraint(equalTo: root.topAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabStrip.heightAnchor.constraint(equalToConstant: 42),
            host.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        w.contentView = root

        if !Self.autosaveUsed {
            Self.autosaveUsed = true
            if !w.setFrameUsingName("ExplorerMainWindow") { w.center() }
            w.setFrameAutosaveName("ExplorerMainWindow")
        } else if let key = NSApp.keyWindow ?? NSApp.mainWindow {
            w.setFrameTopLeftPoint(key.cascadeTopLeft(from: NSPoint(x: key.frame.minX, y: key.frame.maxY)))
        } else {
            w.center()
        }
        addTab(location)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Tabs

    func addTab(_ location: Location, activate: Bool = true) {
        let vc = ExplorerViewController(location: location)
        vc.host = self
        tabs.append(vc)
        if activate { self.activate(vc) } else { refreshStrip() }
    }

    func activate(_ vc: ExplorerViewController) {
        guard activeTab !== vc else { return }
        activeTab?.view.removeFromSuperview()
        activeTab = vc
        host.addSubview(vc.view)
        vc.view.pinEdges(to: host)
        refreshStrip()
        vc.focusContent()
    }

    func refreshStrip() {
        tabStrip.tabs = tabs.map { TabInfo(title: $0.location.title, icon: $0.location.icon) }
        tabStrip.selected = tabs.firstIndex { $0 === activeTab } ?? 0
        window?.title = activeTab?.location.title ?? "File Explorer"
    }

    func tabUpdated(_ vc: ExplorerViewController) { refreshStrip() }

    func closeTab(_ vc: ExplorerViewController) {
        guard let i = tabs.firstIndex(where: { $0 === vc }) else { return }
        if tabs.count == 1 {
            window?.performClose(nil)
            return
        }
        let wasActive = vc === activeTab
        vc.prepareForClose()
        tabs.remove(at: i)
        if wasActive {
            activeTab?.view.removeFromSuperview()
            activeTab = nil
            activate(tabs[min(i, tabs.count - 1)])
        } else {
            refreshStrip()
        }
    }

    // MARK: TabStripDelegate

    func tabStripSelect(_ index: Int) { if let vc = tabs[safe: index] { activate(vc) } }
    func tabStripClose(_ index: Int) { if let vc = tabs[safe: index] { closeTab(vc) } }
    func tabStripNewTab() { addTab(Settings.shared.startLocation) }
    func tabStripMove(from: Int, to: Int) {
        let vc = tabs.remove(at: from)
        tabs.insert(vc, at: to)
        refreshStrip()
    }

    func tabStripMenu(for index: Int) -> NSMenu? {
        guard let vc = tabs[safe: index] else { return nil }
        return NSMenu(items: [
            ClosureMenuItem("New tab", symbol: "plus", key: "t") { [weak self] in self?.tabStripNewTab() },
            ClosureMenuItem("Duplicate tab", symbol: "plus.square.on.square") { [weak self] in self?.addTab(vc.location) },
            ClosureMenuItem("Move tab to new window", symbol: "macwindow.on.rectangle", enabled: tabs.count > 1) { [weak self] in
                self?.closeTab(vc)
                AppDelegate.shared.newWindow(vc.location)
            },
            .separator(),
            ClosureMenuItem("Close tab", key: "w") { [weak self] in self?.closeTab(vc) },
            ClosureMenuItem("Close other tabs", enabled: tabs.count > 1) { [weak self] in
                guard let self else { return }
                for t in self.tabs where t !== vc { self.closeTab(t) }
            },
            ClosureMenuItem("Close tabs to the right", enabled: index < tabs.count - 1) { [weak self] in
                guard let self else { return }
                for t in self.tabs[(index + 1)...] { self.closeTab(t) }
            },
        ])
    }

    // MARK: Actions (menu bar)

    @objc func newTab(_ sender: Any?) { tabStripNewTab() }
    @objc func closeCurrentTab(_ sender: Any?) { if let a = activeTab { closeTab(a) } }
    @objc func nextExplorerTab(_ sender: Any?) { cycle(1) }
    @objc func previousExplorerTab(_ sender: Any?) { cycle(-1) }

    private func cycle(_ d: Int) {
        guard let i = tabs.firstIndex(where: { $0 === activeTab }), tabs.count > 1 else { return }
        activate(tabs[(i + d + tabs.count) % tabs.count])
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        tabs.forEach { $0.prepareForClose() }
        AppDelegate.shared.windowClosed(self)
    }

    func windowDidResize(_ notification: Notification) { tabStrip.needsDisplay = true }
    func windowDidBecomeKey(_ notification: Notification) { tabStrip.needsDisplay = true }
}
