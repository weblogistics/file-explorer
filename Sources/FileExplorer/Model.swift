import AppKit
import UniformTypeIdentifiers

// MARK: - Known folders

enum KnownFolder: String, CaseIterable {
    case desktop, downloads, documents, pictures, music, videos

    var url: URL {
        let dir: FileManager.SearchPathDirectory
        switch self {
        case .desktop: dir = .desktopDirectory
        case .downloads: dir = .downloadsDirectory
        case .documents: dir = .documentDirectory
        case .pictures: dir = .picturesDirectory
        case .music: dir = .musicDirectory
        case .videos: dir = .moviesDirectory
        }
        return (FileManager.default.urls(for: dir, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())).dirNormalized
    }

    var title: String {
        switch self {
        case .desktop: return "Desktop"
        case .downloads: return "Downloads"
        case .documents: return "Documents"
        case .pictures: return "Pictures"
        case .music: return "Music"
        case .videos: return "Videos"
        }
    }

    var symbol: String {
        switch self {
        case .desktop: return "menubar.dock.rectangle"
        case .downloads: return "arrow.down.to.line"
        case .documents: return "doc.text.fill"
        case .pictures: return "photo.fill"
        case .music: return "music.note"
        case .videos: return "play.rectangle.fill"
        }
    }

    var color: NSColor {
        switch self {
        case .desktop: return NSColor(hex: 0x1E88E5)
        case .downloads: return NSColor(hex: 0x1E9E4A)
        case .documents: return NSColor(hex: 0x5B7FB0)
        case .pictures: return NSColor(hex: 0x2B88D8)
        case .music: return NSColor(hex: 0xE8590C)
        case .videos: return NSColor(hex: 0x8C4FD3)
        }
    }

    private static let byPath: [String: KnownFolder] = {
        var d: [String: KnownFolder] = [:]
        for k in KnownFolder.allCases { d[k.url.path] = k }
        return d
    }()

    static func match(_ url: URL) -> KnownFolder? { byPath[url.standardizedFileURL.path] }
}

let homeURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
let trashURL = homeURL.appendingPathComponent(".Trash", isDirectory: true)

// MARK: - File item

final class FileItem: NSObject {
    static let keys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey, .isAliasFileKey,
        .fileSizeKey, .totalFileSizeKey, .contentModificationDateKey, .creationDateKey,
        .contentAccessDateKey, .localizedTypeDescriptionKey, .isVolumeKey,
    ]

    let url: URL
    let path: String
    let name: String
    let ext: String
    let isDirectory: Bool
    let isPackage: Bool
    let isHidden: Bool
    let isLink: Bool
    let isAlias: Bool
    let isVolume: Bool
    let size: Int64
    let modified: Date?
    let created: Date?
    let accessed: Date?
    let typeDescription: String

    init(url: URL) {
        self.url = url
        path = url.path
        let v = try? url.resourceValues(forKeys: Set(FileItem.keys))
        name = v?.name ?? url.lastPathComponent
        ext = url.pathExtension.lowercased()
        let symlink = v?.isSymbolicLink ?? false
        isLink = symlink
        isAlias = (v?.isAliasFile ?? false) && !symlink
        var dir = v?.isDirectory ?? false
        if symlink {
            var d: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &d) { dir = d.boolValue }
        }
        isPackage = v?.isPackage ?? false
        isDirectory = dir && !(v?.isPackage ?? false)
        isHidden = (v?.isHidden ?? false) || name.hasPrefix(".")
        isVolume = v?.isVolume ?? false
        size = Int64(v?.totalFileSize ?? v?.fileSize ?? 0)
        modified = v?.contentModificationDate
        created = v?.creationDate
        accessed = v?.contentAccessDate
        if dir && !(v?.isPackage ?? false) {
            typeDescription = "File folder"
        } else if (v?.isAliasFile ?? false) && !symlink {
            typeDescription = "Shortcut"
        } else if ext == "app" {
            typeDescription = "Application"
        } else if let d = v?.localizedTypeDescription, !d.isEmpty {
            typeDescription = d
        } else {
            typeDescription = ext.isEmpty ? "File" : "\(ext.uppercased()) File"
        }
        super.init()
    }

    var parent: URL { url.deletingLastPathComponent() }

    func displayName(showExtensions: Bool) -> String {
        if showExtensions || isDirectory || ext.isEmpty || name.hasPrefix(".") { return name }
        return (name as NSString).deletingPathExtension
    }

    var isImage: Bool { UTType(filenameExtension: ext)?.conforms(to: .image) ?? false }
    var isZip: Bool { ext == "zip" }

    override func isEqual(_ object: Any?) -> Bool { (object as? FileItem)?.path == path }
    override var hash: Int { path.hashValue }
}

// MARK: - Locations

enum Location: Hashable {
    case home
    case thisPC
    case gallery
    case folder(URL)
    case search(URL, String)

    static func dir(_ url: URL) -> Location { .folder(url.dirNormalized) }

    var folderURL: URL? {
        if case .folder(let u) = self { return u }
        return nil
    }

    /// The folder whose contents are shown (folder itself, or a search scope).
    var scopeURL: URL? {
        switch self {
        case .folder(let u): return u
        case .search(let u, _): return u
        default: return nil
        }
    }

    var isSearch: Bool { if case .search = self { return true }; return false }

    var title: String {
        switch self {
        case .home: return "Home"
        case .thisPC: return "This PC"
        case .gallery: return "Gallery"
        case .folder(let u): return Location.displayName(for: u)
        case .search(let u, let q): return "\(q) - Search Results in \(Location.displayName(for: u))"
        }
    }

    var icon: NSImage {
        switch self {
        case .home: return IconFactory.navIcon(.home)
        case .thisPC: return IconFactory.navIcon(.thisPC)
        case .gallery: return IconFactory.navIcon(.gallery)
        case .search: return Sym.colored("magnifyingglass", size: 12, color: NSColor(hex: 0x5F5F5F))
        case .folder(let u): return Location.icon(for: u)
        }
    }

    static func icon(for u: URL) -> NSImage {
        if let k = KnownFolder.match(u) { return IconFactory.knownGlyph(k) }
        if u.path == trashURL.path { return IconFactory.navIcon(.recycleBin) }
        if (try? u.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true {
            return IconFactory.drive(size: 16, kind: VolumeInfo.kind(for: u))
        }
        return IconFactory.folder(size: 16)
    }

    static func displayName(for u: URL) -> String {
        if u.path == "/" { return VolumeInfo.name(for: u) }
        if u.path == trashURL.path { return "Recycle Bin" }
        if let k = KnownFolder.match(u), k == .videos { return "Videos" }
        if (try? u.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true { return VolumeInfo.name(for: u) }
        return u.lastPathComponent
    }
}

// MARK: - View settings

enum ViewMode: Int, Codable, CaseIterable {
    case extraLarge, large, medium, small, list, details, tiles, content

    var title: String {
        switch self {
        case .extraLarge: return "Extra large icons"
        case .large: return "Large icons"
        case .medium: return "Medium icons"
        case .small: return "Small icons"
        case .list: return "List"
        case .details: return "Details"
        case .tiles: return "Tiles"
        case .content: return "Content"
        }
    }

    var symbol: String {
        switch self {
        case .extraLarge: return "square"
        case .large: return "square.grid.2x2"
        case .medium: return "square.grid.3x3"
        case .small: return "square.grid.4x3.fill"
        case .list: return "list.bullet"
        case .details: return "list.bullet.rectangle"
        case .tiles: return "rectangle.grid.2x2"
        case .content: return "rectangle.grid.1x2"
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .extraLarge: return 256
        case .large: return 96
        case .medium: return 48
        case .small, .list, .details: return 16
        case .tiles: return 48
        case .content: return 32
        }
    }
}

enum SortKey: String, Codable, CaseIterable {
    case name, modified, type, size, created, folder

    var title: String {
        switch self {
        case .name: return "Name"
        case .modified: return "Date modified"
        case .type: return "Type"
        case .size: return "Size"
        case .created: return "Date created"
        case .folder: return "Folder"
        }
    }

    /// Windows sorts dates and sizes newest/largest first on first click.
    var defaultAscending: Bool { !(self == .modified || self == .created || self == .size) }
}

enum GroupBy: String, Codable, CaseIterable {
    case none, name, modified, type, size, month

    var title: String {
        switch self {
        case .none: return "(None)"
        case .name: return "Name"
        case .modified: return "Date modified"
        case .type: return "Type"
        case .size: return "Size"
        case .month: return "Month"
        }
    }
}

struct FolderViewState: Codable, Equatable {
    var mode: ViewMode = .details
    var sortKey: SortKey = .name
    var ascending = true
    var groupBy: GroupBy = .none
}

enum SidePaneMode: String { case none, details, preview }

// MARK: - Settings

extension Notification.Name {
    static let settingsChanged = Notification.Name("FESettingsChanged")
    static let pinsChanged = Notification.Name("FEPinsChanged")
    static let clipboardChanged = Notification.Name("FEClipboardChanged")
    static let recentChanged = Notification.Name("FERecentChanged")
    static let volumesChanged = Notification.Name("FEVolumesChanged")
}

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            "showHidden": false,
            "showExtensions": false,
            "compactView": false,
            "showNavPane": true,
            "sidePane": SidePaneMode.none.rawValue,
            "openTo": "home",
            "showRecent": true,
            "navWidth": 220.0,
            "sideWidth": 300.0,
            "visibleColumns": ["name", "modified", "type", "size"],
            "pinned": KnownFolder.allCases.map { $0.url.path },
        ])
    }

    private func post() { NotificationCenter.default.post(name: .settingsChanged, object: nil) }

    var showHidden: Bool { get { d.bool(forKey: "showHidden") } set { d.set(newValue, forKey: "showHidden"); post() } }
    var showExtensions: Bool { get { d.bool(forKey: "showExtensions") } set { d.set(newValue, forKey: "showExtensions"); post() } }
    var compactView: Bool { get { d.bool(forKey: "compactView") } set { d.set(newValue, forKey: "compactView"); post() } }
    var showNavPane: Bool { get { d.bool(forKey: "showNavPane") } set { d.set(newValue, forKey: "showNavPane"); post() } }
    var showRecent: Bool { get { d.bool(forKey: "showRecent") } set { d.set(newValue, forKey: "showRecent"); post() } }
    var sidePane: SidePaneMode {
        get { SidePaneMode(rawValue: d.string(forKey: "sidePane") ?? "") ?? .none }
        set { d.set(newValue.rawValue, forKey: "sidePane"); post() }
    }
    var openTo: String { get { d.string(forKey: "openTo") ?? "home" } set { d.set(newValue, forKey: "openTo") } }
    var navWidth: CGFloat { get { CGFloat(d.double(forKey: "navWidth")) } set { d.set(Double(newValue), forKey: "navWidth") } }
    var sideWidth: CGFloat { get { CGFloat(d.double(forKey: "sideWidth")) } set { d.set(Double(newValue), forKey: "sideWidth") } }
    var visibleColumns: [String] {
        get { d.stringArray(forKey: "visibleColumns") ?? [] }
        set { d.set(newValue, forKey: "visibleColumns") }
    }

    var startLocation: Location { openTo == "thispc" ? .thisPC : .home }

    // Pinned (Quick access)
    var pinned: [URL] {
        (d.stringArray(forKey: "pinned") ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    func isPinned(_ url: URL) -> Bool { (d.stringArray(forKey: "pinned") ?? []).contains(url.standardizedFileURL.path) }
    func pin(_ url: URL) {
        var p = d.stringArray(forKey: "pinned") ?? []
        let path = url.standardizedFileURL.path
        guard !p.contains(path) else { return }
        p.append(path)
        d.set(p, forKey: "pinned")
        NotificationCenter.default.post(name: .pinsChanged, object: nil)
    }
    func unpin(_ url: URL) {
        var p = d.stringArray(forKey: "pinned") ?? []
        p.removeAll { $0 == url.standardizedFileURL.path }
        d.set(p, forKey: "pinned")
        NotificationCenter.default.post(name: .pinsChanged, object: nil)
    }

    // Recently opened files (by this app)
    var recentFiles: [(URL, Date)] {
        let dict = d.dictionary(forKey: "recentFiles") as? [String: Double] ?? [:]
        return dict.map { (URL(fileURLWithPath: $0.key), Date(timeIntervalSince1970: $0.value)) }
    }
    func addRecent(_ url: URL) {
        var dict = d.dictionary(forKey: "recentFiles") as? [String: Double] ?? [:]
        dict[url.path] = Date().timeIntervalSince1970
        if dict.count > 40 {
            for k in dict.sorted(by: { $0.value < $1.value }).prefix(dict.count - 40).map(\.key) { dict[k] = nil }
        }
        d.set(dict, forKey: "recentFiles")
    }
    func clearHistory() {
        d.removeObject(forKey: "recentFiles")
        d.removeObject(forKey: "typedPaths")
        NotificationCenter.default.post(name: .recentChanged, object: nil)
    }

    // Per folder view state (Windows remembers views per folder)
    private var folderStates: [String: FolderViewState] = {
        guard let data = UserDefaults.standard.data(forKey: "folderStates"),
              let s = try? JSONDecoder().decode([String: FolderViewState].self, from: data) else { return [:] }
        return s
    }()

    static func key(for loc: Location) -> String {
        switch loc {
        case .folder(let u): return "path:" + u.path
        case .gallery: return "gallery"
        case .search: return "search"
        case .home: return "home"
        case .thisPC: return "thispc"
        }
    }

    func folderState(for loc: Location) -> FolderViewState {
        if let s = folderStates[Settings.key(for: loc)] { return s }
        var s = FolderViewState()
        switch loc {
        case .gallery:
            s.mode = .large; s.sortKey = .created; s.ascending = false; s.groupBy = .month
        case .folder(let u):
            switch KnownFolder.match(u) {
            case .downloads: s.sortKey = .modified; s.ascending = false; s.groupBy = .modified
            case .pictures, .videos: s.mode = .large
            default: break
            }
        default: break
        }
        return s
    }

    func setFolderState(_ s: FolderViewState, for loc: Location) {
        folderStates[Settings.key(for: loc)] = s
        if let data = try? JSONEncoder().encode(folderStates) { d.set(data, forKey: "folderStates") }
    }
}

// MARK: - Clipboard

enum Clipboard {
    private static var cutChangeCount = -1
    private static var cutPaths: Set<String> = []

    static func put(_ urls: [URL], cut: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
        if cut {
            cutChangeCount = pb.changeCount
            cutPaths = Set(urls.map(\.path))
        } else {
            cutChangeCount = -1
            cutPaths = []
        }
        NotificationCenter.default.post(name: .clipboardChanged, object: nil)
    }

    static func putText(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        cutChangeCount = -1
        cutPaths = []
        NotificationCenter.default.post(name: .clipboardChanged, object: nil)
    }

    static var isCut: Bool { NSPasteboard.general.changeCount == cutChangeCount }
    static func isCut(_ path: String) -> Bool { isCut && cutPaths.contains(path) }

    static func clearCut() {
        guard cutChangeCount != -1 else { return }
        cutChangeCount = -1
        cutPaths = []
        NotificationCenter.default.post(name: .clipboardChanged, object: nil)
    }

    static var urls: [URL] {
        NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    static var hasFiles: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }
}

// MARK: - Volumes

enum DriveKind { case system, local, removable, network }

struct VolumeInfo {
    let url: URL
    let name: String
    let total: Int64
    let free: Int64
    let kind: DriveKind
    let format: String
    let ejectable: Bool

    private static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey,
        .volumeIsLocalKey, .volumeIsBrowsableKey, .volumeLocalizedFormatDescriptionKey, .volumeIsRootFileSystemKey,
    ]

    static func list() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { info(for: $0) }.filter { $0.url.path == "/" || !$0.url.path.hasPrefix("/System") }
    }

    static func info(for url: URL) -> VolumeInfo? {
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        if v.volumeIsBrowsable == false { return nil }
        let free = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
        return VolumeInfo(url: url.dirNormalized,
                          name: v.volumeLocalizedName ?? v.volumeName ?? url.lastPathComponent,
                          total: Int64(v.volumeTotalCapacity ?? 0),
                          free: free,
                          kind: kind(from: v, url: url),
                          format: v.volumeLocalizedFormatDescription ?? "",
                          ejectable: (v.volumeIsEjectable ?? false) || (v.volumeIsRemovable ?? false))
    }

    private static func kind(from v: URLResourceValues, url: URL) -> DriveKind {
        if v.volumeIsRootFileSystem == true || url.path == "/" { return .system }
        if v.volumeIsLocal == false { return .network }
        if v.volumeIsRemovable == true || v.volumeIsEjectable == true || v.volumeIsInternal == false { return .removable }
        return .local
    }

    static func kind(for url: URL) -> DriveKind {
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return .local }
        return kind(from: v, url: url)
    }

    static func name(for url: URL) -> String {
        let v = try? url.resourceValues(forKeys: [.volumeLocalizedNameKey, .volumeNameKey])
        return v?.volumeLocalizedName ?? v?.volumeName ?? url.lastPathComponent
    }

    var typeName: String {
        switch kind {
        case .system, .local: return "Local Disk"
        case .removable: return "Removable Disk"
        case .network: return "Network Drive"
        }
    }

    var freeText: String { "\(Fmt.size(free)) free of \(Fmt.size(total))" }
}

// MARK: - Recent files (Home)

final class RecentFiles: NSObject {
    static let shared = RecentFiles()
    private(set) var items: [(URL, Date)] = []
    private var query: NSMetadataQuery?

    func refresh() {
        guard Settings.shared.showRecent else {
            items = []
            NotificationCenter.default.post(name: .recentChanged, object: nil)
            return
        }
        guard query == nil else { return }
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(format: "kMDItemLastUsedDate >= %@", Date().addingTimeInterval(-30 * 86400) as NSDate)
        q.searchScopes = [NSMetadataQueryUserHomeScope]
        q.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        NotificationCenter.default.addObserver(self, selector: #selector(gathered(_:)),
                                               name: .NSMetadataQueryDidFinishGathering, object: q)
        query = q
        if !q.start() { finish(with: []) }
    }

    @objc private func gathered(_ n: Notification) {
        guard let q = query else { return }
        q.disableUpdates()
        var found: [(URL, Date)] = []
        for i in 0..<min(q.resultCount, 400) {
            guard let item = q.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  let date = item.value(forAttribute: "kMDItemLastUsedDate") as? Date else { continue }
            if path.contains(".app") || path.contains("/Library/") || path.contains("/.") { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
            found.append((URL(fileURLWithPath: path), date))
            if found.count >= 40 { break }
        }
        q.stop()
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: q)
        finish(with: found)
    }

    private func finish(with found: [(URL, Date)]) {
        query = nil
        var merged: [String: (URL, Date)] = [:]
        for (u, d) in found + Settings.shared.recentFiles where FileManager.default.fileExists(atPath: u.path) {
            if let e = merged[u.path], e.1 >= d { continue }
            merged[u.path] = (u, d)
        }
        items = merged.values.sorted { $0.1 > $1.1 }.prefix(25).map { $0 }
        NotificationCenter.default.post(name: .recentChanged, object: nil)
    }
}

// MARK: - Directory loading & watching

enum DirectoryLoader {
    static func load(_ url: URL, showHidden: Bool) throws -> [FileItem] {
        let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: FileItem.keys,
                                                               options: showHidden ? [] : [.skipsHiddenFiles])
        return urls.map { FileItem(url: $0) }
    }

    static func canOpen(_ url: URL) -> Bool {
        guard let d = opendir(url.path) else { return false }
        closedir(d)
        return true
    }

    static func subfolders(of url: URL, showHidden: Bool, limit: Int = 500) -> [URL] {
        let opts: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: opts) else { return [] }
        let dirs = urls.filter {
            let v = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
        }
        return Array(dirs.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }.prefix(limit))
    }
}

final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var pending = false
    var onChange: (() -> Void)?

    func watch(_ url: URL?) {
        stop()
        guard let url else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                            eventMask: [.write, .rename, .delete, .link, .attrib],
                                                            queue: .main)
        src.setEventHandler { [weak self] in self?.schedule() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func schedule() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.pending = false
            self?.onChange?()
        }
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit { stop() }
}

// MARK: - Search

final class SearchTask {
    let scope: URL
    let query: String
    let showHidden: Bool
    private let lock = NSLock()
    private var _cancelled = false
    var onBatch: (([FileItem], Bool) -> Void)?

    var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    init(scope: URL, query: String, showHidden: Bool) {
        self.scope = scope
        self.query = query
        self.showHidden = showHidden
    }

    func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
    }

    func start() {
        let q = query.trimmingCharacters(in: .whitespaces)
        let wildcard = q.contains("*") || q.contains("?")
        let pattern = q.lowercased()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var opts: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
            if !showHidden { opts.insert(.skipsHiddenFiles) }
            let en = FileManager.default.enumerator(at: scope, includingPropertiesForKeys: [.nameKey],
                                                    options: opts, errorHandler: { _, _ in true })
            var batch: [FileItem] = []
            var last = Date()
            var total = 0
            while let url = en?.nextObject() as? URL {
                if cancelled { return }
                let name = url.lastPathComponent
                let match = wildcard ? fnmatch(pattern, name, FNM_CASEFOLD) == 0
                                     : name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                if match {
                    batch.append(FileItem(url: url))
                    total += 1
                }
                if !batch.isEmpty && Date().timeIntervalSince(last) > 0.3 {
                    let b = batch
                    batch = []
                    last = Date()
                    DispatchQueue.main.async { if !self.cancelled { self.onBatch?(b, false) } }
                }
                if total >= 20000 { break }
            }
            let b = batch
            DispatchQueue.main.async { if !self.cancelled { self.onBatch?(b, true) } }
        }
    }
}

// MARK: - Sorting & grouping

struct ItemGroup {
    let title: String
    let items: [FileItem]
}

enum Arranger {
    static func sort(_ items: [FileItem], key: SortKey, ascending: Bool) -> [FileItem] {
        items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return ascending ? a.isDirectory : !a.isDirectory }
            var r: ComparisonResult
            switch key {
            case .name: r = a.name.localizedStandardCompare(b.name)
            case .modified: r = compare(a.modified, b.modified)
            case .created: r = compare(a.created, b.created)
            case .type: r = a.typeDescription.localizedStandardCompare(b.typeDescription)
            case .size: r = a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
            case .folder: r = a.parent.path.localizedStandardCompare(b.parent.path)
            }
            if r == .orderedSame { r = a.name.localizedStandardCompare(b.name) }
            return ascending ? r == .orderedAscending : r == .orderedDescending
        }
    }

    private static func compare(_ a: Date?, _ b: Date?) -> ComparisonResult {
        let x = a ?? .distantPast, y = b ?? .distantPast
        return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
    }

    static func arrange(_ items: [FileItem], state: FolderViewState) -> [ItemGroup] {
        let sorted = sort(items, key: state.sortKey, ascending: state.ascending)
        guard state.groupBy != .none else { return [ItemGroup(title: "", items: sorted)] }

        var order: [String] = []
        var buckets: [String: [FileItem]] = [:]
        for it in sorted {
            let k = groupKey(it, state.groupBy)
            if buckets[k] == nil { order.append(k) }
            buckets[k, default: []].append(it)
        }
        let ranked: [String]
        switch state.groupBy {
        case .modified:
            ranked = dateBuckets.filter { buckets[$0] != nil }
        case .size:
            ranked = sizeBuckets.filter { buckets[$0] != nil }
        case .name:
            ranked = nameBuckets.filter { buckets[$0] != nil }
        case .month:
            ranked = order
        default:
            ranked = order.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        let final = (state.ascending || state.groupBy == .modified || state.groupBy == .month) ? ranked : ranked.reversed()
        return final.map { ItemGroup(title: $0, items: buckets[$0] ?? []) }
    }

    static let dateBuckets = ["Today", "Yesterday", "Earlier this week", "Last week", "Earlier this month",
                              "Last month", "Earlier this year", "A long time ago"]
    static let sizeBuckets = ["Empty (0 KB)", "Tiny (0 - 16 KB)", "Small (16 KB - 1 MB)", "Medium (1 - 128 MB)",
                              "Large (128 MB - 1 GB)", "Huge (1 - 4 GB)", "Gigantic (> 4 GB)", "Unspecified"]
    static let nameBuckets = ["0 - 9", "A - H", "I - P", "Q - Z", "Other"]

    private static func groupKey(_ it: FileItem, _ g: GroupBy) -> String {
        switch g {
        case .none: return ""
        case .type: return it.typeDescription
        case .name:
            guard let c = it.name.uppercased().first else { return "Other" }
            if c.isNumber { return "0 - 9" }
            if ("A"..."H").contains(String(c)) { return "A - H" }
            if ("I"..."P").contains(String(c)) { return "I - P" }
            if ("Q"..."Z").contains(String(c)) { return "Q - Z" }
            return "Other"
        case .size:
            if it.isDirectory { return "Unspecified" }
            let s = it.size
            if s == 0 { return sizeBuckets[0] }
            if s < 16 * 1024 { return sizeBuckets[1] }
            if s < 1024 * 1024 { return sizeBuckets[2] }
            if s < 128 * 1024 * 1024 { return sizeBuckets[3] }
            if s < 1024 * 1024 * 1024 { return sizeBuckets[4] }
            if s < 4 * 1024 * 1024 * 1024 { return sizeBuckets[5] }
            return sizeBuckets[6]
        case .month:
            return Fmt.monthYear.string(from: it.created ?? it.modified ?? Date())
        case .modified:
            guard let d = it.modified else { return "A long time ago" }
            let cal = Calendar.current
            let now = Date()
            let today = cal.startOfDay(for: now)
            let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
            let week = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? today
            let lastWeek = cal.date(byAdding: .day, value: -7, to: week) ?? week
            let month = cal.dateInterval(of: .month, for: now)?.start ?? today
            let lastMonth = cal.date(byAdding: .month, value: -1, to: month) ?? month
            let year = cal.dateInterval(of: .year, for: now)?.start ?? today
            if d >= today { return "Today" }
            if d >= yesterday { return "Yesterday" }
            if d >= week { return "Earlier this week" }
            if d >= lastWeek { return "Last week" }
            if d >= month { return "Earlier this month" }
            if d >= lastMonth { return "Last month" }
            if d >= year { return "Earlier this year" }
            return "A long time ago"
        }
    }
}
