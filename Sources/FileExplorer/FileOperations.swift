import AppKit

// MARK: - Undo

final class UndoStack {
    static let shared = UndoStack()
    struct Entry {
        let name: String
        let undo: () -> Void
        let redo: () -> Void
    }
    private var undoEntries: [Entry] = []
    private var redoEntries: [Entry] = []
    private(set) var isRedoing = false

    var undoName: String? { undoEntries.last?.name }
    var redoName: String? { redoEntries.last?.name }

    func push(_ name: String, fromRedo: Bool = false, undo: @escaping () -> Void, redo: @escaping () -> Void) {
        undoEntries.append(Entry(name: name, undo: undo, redo: redo))
        if undoEntries.count > 50 { undoEntries.removeFirst() }
        if !(isRedoing || fromRedo) { redoEntries.removeAll() }
    }

    func undo() {
        guard let e = undoEntries.popLast() else { NSSound.beep(); return }
        e.undo()
        redoEntries.append(e)
    }

    func redo() {
        guard let e = redoEntries.popLast() else { NSSound.beep(); return }
        isRedoing = true
        e.redo()
        isRedoing = false
    }
}

// MARK: - Transfer job

enum ConflictChoice { case replace, skip, keepBoth, cancel }

final class TransferJob {
    enum Kind { case copy, move }
    let kind: Kind
    let sources: [URL]
    let destination: URL
    let startDate = Date()

    private let lock = NSLock()
    private var _cancelled = false
    private var _completedBytes: Int64 = 0
    private var _currentFileBytes: Int64 = 0
    private var _completedItems = 0
    private var _currentName = ""
    private(set) var totalBytes: Int64 = 0
    private(set) var totalItems = 0

    var policyForAll: ConflictChoice?
    var results: [URL] = []
    var moved: [(from: URL, to: URL)] = []
    var created: [URL] = []
    var errors: [String] = []

    init(kind: Kind, sources: [URL], destination: URL) {
        self.kind = kind
        self.sources = sources
        self.destination = destination
    }

    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }

    struct Snapshot { let done: Int64; let total: Int64; let items: Int; let totalItems: Int; let name: String }
    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(done: _completedBytes + _currentFileBytes, total: totalBytes, items: _completedItems,
                        totalItems: totalItems, name: _currentName)
    }

    fileprivate func setCurrentFileBytes(_ b: Int64) { lock.lock(); _currentFileBytes = b; lock.unlock() }
    fileprivate func fileFinished(bytes: Int64) {
        lock.lock(); _completedBytes += bytes; _currentFileBytes = 0; _completedItems += 1; lock.unlock()
    }
    private func setCompleted(bytes: Int64, addItems: Int) {
        lock.lock(); _completedBytes = bytes; _currentFileBytes = 0; _completedItems += addItems; lock.unlock()
    }
    private var completedBytes: Int64 { lock.lock(); defer { lock.unlock() }; return _completedBytes }
    fileprivate func setName(_ n: String) { lock.lock(); _currentName = n; lock.unlock() }

    var verb: String { kind == .copy ? "Copying" : "Moving" }

    // MARK: Run

    func run() {
        for s in sources {
            if kind == .move && FileOperations.sameVolume(s, destination) {
                totalItems += 1
            } else {
                let m = FileOperations.measure(s)
                totalBytes += m.bytes
                totalItems += m.items
            }
        }
        for s in sources {
            if cancelled { break }
            process(s, into: destination, top: true)
        }
    }

    private func process(_ src: URL, into dir: URL, top: Bool) {
        let fm = FileManager.default
        let name = src.lastPathComponent
        setName(name)
        let srcIsDir = src.isDirectoryOnDisk && !isSymlink(src)

        if srcIsDir && (dir.path == src.path || dir.path.hasPrefix(src.path + "/")) {
            errors.append("The destination folder is a subfolder of the source folder \"\(name)\".")
            return
        }

        let sameParent = src.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path
        if sameParent {
            if kind == .move { if top { results.append(src) }; return }
            let target = FileOperations.uniqueURL(name, in: dir, style: .copy)
            if copyItem(src, to: target) {
                if top { results.append(target) }
                created.append(target)
            }
            return
        }

        var target = dir.appendingPathComponent(name)
        if fm.fileExists(atPath: target.path) || isSymlink(target) {
            if srcIsDir && target.isDirectoryOnDisk {
                // Windows merges folders and only asks about individual files.
                let children = (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil, options: [])) ?? []
                for c in children {
                    if cancelled { return }
                    process(c, into: target, top: false)
                }
                if kind == .move, (try? fm.contentsOfDirectory(atPath: src.path))?.isEmpty == true {
                    try? fm.removeItem(at: src)
                }
                if top { results.append(target) }
                return
            }
            switch resolveConflict(name: name, src: src, dst: target) {
            case .skip:
                let m = FileOperations.measure(src)
                setCompleted(bytes: completedBytes + m.bytes, addItems: m.items)
                return
            case .cancel:
                cancel()
                return
            case .replace:
                do {
                    try fm.trashItem(at: target, resultingItemURL: nil)
                } catch {
                    do { try fm.removeItem(at: target) } catch {
                        errors.append("Couldn't replace \"\(name)\": \(error.localizedDescription)")
                        return
                    }
                }
            case .keepBoth:
                target = FileOperations.uniqueURL(name, in: dir, style: .number)
            }
        }

        let ok = kind == .move ? moveItem(src, to: target) : copyItem(src, to: target)
        if ok {
            if top { results.append(target) }
            if kind == .move { moved.append((src, target)) } else { created.append(target) }
        }
    }

    private func isSymlink(_ u: URL) -> Bool {
        (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
    }

    private func moveItem(_ src: URL, to dst: URL) -> Bool {
        if FileOperations.sameVolume(src, dst.deletingLastPathComponent()) {
            do {
                try FileManager.default.moveItem(at: src, to: dst)
                fileFinished(bytes: 0)
                return true
            } catch {
                errors.append("Couldn't move \"\(src.lastPathComponent)\": \(error.localizedDescription)")
                return false
            }
        }
        guard copyItem(src, to: dst) else { return false }
        do { try FileManager.default.removeItem(at: src) } catch {
            errors.append("\"\(src.lastPathComponent)\" was copied but the original couldn't be removed.")
        }
        return true
    }

    private func copyItem(_ src: URL, to dst: URL) -> Bool {
        let base = completedBytes
        let m = FileOperations.measure(src)
        guard let state = copyfile_state_alloc() else { return false }
        defer { copyfile_state_free(state) }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(copyProgressCallback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(self).toOpaque())
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW | COPYFILE_EXCL | COPYFILE_CLONE)
        let rc = src.withUnsafeFileSystemRepresentation { s in
            dst.withUnsafeFileSystemRepresentation { d in copyfile(s, d, state, flags) }
        }
        let err = errno
        lock.lock()
        _completedBytes = base + m.bytes
        _currentFileBytes = 0
        lock.unlock()
        if rc != 0 {
            if cancelled {
                try? FileManager.default.removeItem(at: dst)
            } else {
                errors.append("Couldn't copy \"\(src.lastPathComponent)\": \(String(cString: strerror(err)))")
            }
            return false
        }
        return true
    }

    private func resolveConflict(name: String, src: URL, dst: URL) -> ConflictChoice {
        if let p = policyForAll { return p }
        var choice = ConflictChoice.skip
        var all = false
        DispatchQueue.main.sync {
            (choice, all) = ConflictDialog.run(job: self, name: name, src: src, dst: dst)
        }
        if all && choice != .cancel { policyForAll = choice }
        return choice
    }
}

private let copyProgressCallback: @convention(c) (Int32, Int32, copyfile_state_t?, UnsafePointer<CChar>?,
                                                  UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Int32 = {
    what, stage, state, src, _, ctx in
    guard let ctx else { return COPYFILE_CONTINUE }
    let job = Unmanaged<TransferJob>.fromOpaque(ctx).takeUnretainedValue()
    if job.cancelled { return COPYFILE_QUIT }
    if what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS, let state {
        var copied: off_t = 0
        copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
        job.setCurrentFileBytes(Int64(copied))
    } else if what == COPYFILE_RECURSE_FILE && stage == COPYFILE_START, let src {
        job.setName((String(cString: src) as NSString).lastPathComponent)
    } else if what == COPYFILE_RECURSE_FILE && stage == COPYFILE_FINISH, let src {
        var st = stat()
        let size: Int64 = lstat(src, &st) == 0 ? Int64(st.st_size) : 0
        job.fileFinished(bytes: size)
    } else if stage == COPYFILE_ERR {
        return COPYFILE_SKIP
    }
    return COPYFILE_CONTINUE
}

// MARK: - File operations

final class FileOperations {
    static let shared = FileOperations()
    private var activeJobs: [TransferJob] = []

    enum UniqueStyle { case copy, number }

    static func uniqueURL(_ name: String, in dir: URL, style: UniqueStyle) -> URL {
        let fm = FileManager.default
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ext.isEmpty ? name : ns.deletingPathExtension
        func make(_ b: String) -> URL { dir.appendingPathComponent(ext.isEmpty ? b : "\(b).\(ext)") }
        switch style {
        case .number:
            var u = make(base)
            var n = 2
            while fm.fileExists(atPath: u.path) { u = make("\(base) (\(n))"); n += 1 }
            return u
        case .copy:
            var u = make("\(base) - Copy")
            var n = 2
            while fm.fileExists(atPath: u.path) { u = make("\(base) - Copy (\(n))"); n += 1 }
            return u
        }
    }

    static func volumeID(_ url: URL) -> NSObject? {
        var u = url
        while !FileManager.default.fileExists(atPath: u.path) && u.path != "/" { u = u.deletingLastPathComponent() }
        return (try? u.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let x = volumeID(a), let y = volumeID(b) else { return false }
        return x.isEqual(y)
    }

    static func measure(_ url: URL) -> (bytes: Int64, items: Int) {
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return (0, 1) }
        if v.isDirectory != true || v.isSymbolicLink == true { return (Int64(v.fileSize ?? 0), 1) }
        var bytes: Int64 = 0
        var items = 1
        let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        while let u = en?.nextObject() as? URL {
            items += 1
            if let s = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize { bytes += Int64(s) }
        }
        return (bytes, items)
    }

    // MARK: Copy / move

    func transfer(_ sources: [URL], to dest: URL, kind: TransferJob.Kind, undoable: Bool = true,
                  completion: (([URL]) -> Void)? = nil) {
        guard !sources.isEmpty else { return }
        guard FileManager.default.isWritableFile(atPath: dest.path) else {
            Alerts.show("Destination Folder Access Denied", "You need permission to perform this action in \"\(dest.lastPathComponent)\".")
            return
        }
        let job = TransferJob(kind: kind, sources: sources, destination: dest)
        let fromRedo = UndoStack.shared.isRedoing
        activeJobs.append(job)
        let progress = ProgressWindowController(job: job)
        var finished = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if !finished { progress.showWindow(nil) } }
        Thread.detachNewThread {
            job.run()
            DispatchQueue.main.async {
                finished = true
                progress.finish()
                self.activeJobs.removeAll { $0 === job }
                if !job.errors.isEmpty {
                    let shown = job.errors.prefix(8).joined(separator: "\n")
                    let more = job.errors.count > 8 ? "\n…and \(job.errors.count - 8) more." : ""
                    Alerts.show("Some items couldn't be \(kind == .copy ? "copied" : "moved")", shown + more)
                }
                if undoable { self.registerUndo(job, fromRedo: fromRedo) }
                completion?(job.results)
            }
        }
    }

    private func registerUndo(_ job: TransferJob, fromRedo: Bool) {
        let srcs = job.sources, dest = job.destination
        if job.kind == .copy, !job.created.isEmpty {
            let created = job.created
            UndoStack.shared.push("Copy", fromRedo: fromRedo, undo: {
                for u in created { try? FileManager.default.trashItem(at: u, resultingItemURL: nil) }
            }, redo: {
                FileOperations.shared.transfer(srcs, to: dest, kind: .copy)
            })
        } else if job.kind == .move, !job.moved.isEmpty {
            let moved = job.moved
            UndoStack.shared.push("Move", fromRedo: fromRedo, undo: {
                for (from, to) in moved.reversed() {
                    try? FileManager.default.createDirectory(at: from.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if (try? FileManager.default.moveItem(at: to, to: from)) == nil {
                        _ = try? FileManager.default.copyItem(at: to, to: from)
                        try? FileManager.default.removeItem(at: to)
                    }
                }
            }, redo: {
                FileOperations.shared.transfer(moved.map(\.from), to: dest, kind: .move)
            })
        }
    }

    // MARK: Delete

    /// Moves items to the Recycle Bin (Trash). Offers permanent deletion for items that can't be recycled.
    func recycle(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var pairs: [(URL, URL)] = []
        var failed: [URL] = []
        for u in urls {
            do {
                var out: NSURL?
                try FileManager.default.trashItem(at: u, resultingItemURL: &out)
                if let o = out as URL? { pairs.append((u, o)) }
            } catch {
                failed.append(u)
            }
        }
        if !pairs.isEmpty {
            UndoStack.shared.push("Delete", undo: {
                for (orig, t) in pairs { try? FileManager.default.moveItem(at: t, to: orig) }
            }, redo: {
                FileOperations.shared.recycle(pairs.map(\.0))
            })
        }
        if !failed.isEmpty {
            let what = failed.count == 1 ? "\"\(failed[0].lastPathComponent)\" is" : "\(failed.count) items are"
            if Alerts.confirm("Delete File", "\(what) too big to recycle or can't be moved to the Recycle Bin. Do you want to permanently delete \(failed.count == 1 ? "it" : "them")?") {
                deletePermanently(failed, confirm: false)
            }
        }
    }

    func deletePermanently(_ urls: [URL], confirm: Bool = true) {
        guard !urls.isEmpty else { return }
        if confirm {
            let msg = urls.count == 1
                ? "Are you sure you want to permanently delete \"\(urls[0].lastPathComponent)\"?"
                : "Are you sure you want to permanently delete these \(urls.count) items?"
            let icon = urls.count == 1 ? NSWorkspace.shared.icon(forFile: urls[0].path) : nil
            guard Alerts.confirm(urls.count == 1 ? "Delete File" : "Delete Multiple Items", msg + "\n\nThis can't be undone.", icon: icon) else { return }
        }
        var errors: [String] = []
        for u in urls {
            do { try FileManager.default.removeItem(at: u) } catch { errors.append("\(u.lastPathComponent): \(error.localizedDescription)") }
        }
        if !errors.isEmpty { Alerts.show("Some items couldn't be deleted", errors.joined(separator: "\n")) }
    }

    func emptyRecycleBin() {
        guard Alerts.confirm("Delete Multiple Items", "Are you sure you want to permanently delete all of the items in the Recycle Bin?") else { return }
        var err: NSDictionary?
        NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&err)
        if let err { Alerts.show("Couldn't empty the Recycle Bin", "\(err[NSAppleScript.errorMessage] ?? "Unknown error")") }
    }

    // MARK: Rename

    static let invalidChars = CharacterSet(charactersIn: "/:")

    /// Renames with Windows-like validation. Returns the new URL, or nil if cancelled/failed.
    @discardableResult
    func rename(_ url: URL, to rawName: String, registerUndo: Bool = true) -> URL? {
        let newName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return nil }
        if newName.rangeOfCharacter(from: Self.invalidChars) != nil {
            Alerts.show("Invalid file name", "A file name can't contain any of the following characters:\n/  :")
            return nil
        }
        if newName == url.lastPathComponent { return url }
        let dest = url.deletingLastPathComponent().appendingPathComponent(newName)
        let caseOnly = newName.lowercased() == url.lastPathComponent.lowercased()
        if !caseOnly && FileManager.default.fileExists(atPath: dest.path) {
            Alerts.show("Rename Item", "There is already a file with the same name in this location.")
            return nil
        }
        let oldExt = url.pathExtension.lowercased(), newExt = (newName as NSString).pathExtension.lowercased()
        if !url.isDirectoryOnDisk, !oldExt.isEmpty, oldExt != newExt, registerUndo {
            guard Alerts.confirm("Rename", "If you change a file name extension, the file might become unusable.\n\nAre you sure you want to change it?") else { return nil }
        }
        let rc = url.withUnsafeFileSystemRepresentation { s in
            dest.withUnsafeFileSystemRepresentation { d in Darwin.rename(s!, d!) }
        }
        if rc != 0 {
            Alerts.show("Rename Item", "Couldn't rename \"\(url.lastPathComponent)\": \(String(cString: strerror(errno)))")
            return nil
        }
        if registerUndo {
            let oldName = url.lastPathComponent
            UndoStack.shared.push("Rename", undo: {
                FileOperations.shared.rename(dest, to: oldName, registerUndo: false)
            }, redo: {
                FileOperations.shared.rename(url, to: newName, registerUndo: false)
            })
        }
        return dest
    }

    // MARK: Create

    func newFolder(in dir: URL, name: String = "New folder") -> URL? {
        let u = Self.uniqueURL(name, in: dir, style: .number)
        do {
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: false)
        } catch {
            Alerts.show("Couldn't create folder", error.localizedDescription)
            return nil
        }
        registerCreate(u)
        return u
    }

    func newFile(in dir: URL, name: String, contents: Data = Data()) -> URL? {
        let u = Self.uniqueURL(name, in: dir, style: .number)
        guard FileManager.default.createFile(atPath: u.path, contents: contents) else {
            Alerts.show("Couldn't create file", "You might not have permission to create files in this folder.")
            return nil
        }
        registerCreate(u)
        return u
    }

    private func registerCreate(_ u: URL) {
        UndoStack.shared.push("New", undo: {
            try? FileManager.default.trashItem(at: u, resultingItemURL: nil)
        }, redo: {})
    }

    // MARK: Zip

    func compress(_ urls: [URL], completion: @escaping (URL?) -> Void) {
        guard let first = urls.first else { return }
        let dir = first.deletingLastPathComponent()
        let base = urls.count == 1 && !first.isDirectoryOnDisk ? first.deletingPathExtension().lastPathComponent : first.lastPathComponent
        let target = Self.uniqueURL("\(base).zip", in: dir, style: .number)
        let sameParent = urls.allSatisfy { $0.deletingLastPathComponent().path == dir.path }
        var args = ["-r", "-y", "-q"]
        if !sameParent { args.append("-j") }
        args.append(target.path)
        args += sameParent ? urls.map(\.lastPathComponent) : urls.map(\.path)
        args += ["-x", "*.DS_Store"]
        runTool("/usr/bin/zip", args, cwd: dir, title: "Compressing \(urls.count == 1 ? "1 item" : "\(urls.count) items")") { ok in
            if ok {
                self.registerCreate(target)
                completion(target)
            } else {
                Alerts.show("Compressed (zipped) Folders Error", "File Explorer couldn't create the zip file.")
                completion(nil)
            }
        }
    }

    func extract(_ zip: URL, to dest: URL, completion: @escaping (URL?) -> Void) {
        do { try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true) } catch {
            Alerts.show("Extract Compressed (Zipped) Folders", error.localizedDescription)
            completion(nil)
            return
        }
        runTool("/usr/bin/ditto", ["-x", "-k", zip.path, dest.path], cwd: zip.deletingLastPathComponent(),
                title: "Extracting \(zip.lastPathComponent)") { ok in
            if ok {
                self.registerCreate(dest)
                completion(dest)
            } else {
                Alerts.show("Compressed (zipped) Folders Error", "The compressed (zipped) folder \"\(zip.lastPathComponent)\" is invalid.")
                completion(nil)
            }
        }
    }

    private func runTool(_ tool: String, _ args: [String], cwd: URL, title: String, completion: @escaping (Bool) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let progress = ProgressWindowController(title: title, process: p)
        var done = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if !done { progress.showWindow(nil) } }
        p.terminationHandler = { proc in
            DispatchQueue.main.async {
                done = true
                progress.finish()
                completion(proc.terminationStatus == 0 && proc.terminationReason == .exit)
            }
        }
        do { try p.run() } catch {
            done = true
            progress.finish()
            completion(false)
        }
    }
}

// MARK: - Progress window

final class ProgressWindowController: NSWindowController, NSWindowDelegate {
    private var job: TransferJob?
    private var process: Process?
    private let headline = makeLabel("", size: 12)
    private let percent = makeLabel("", size: 17, weight: .regular)
    private let bar = WinProgressBar()
    private let nameLabel = makeLabel("", size: 11, color: Theme.secondaryText)
    private let timeLabel = makeLabel("", size: 11, color: Theme.secondaryText)
    private let itemsLabel = makeLabel("", size: 11, color: Theme.secondaryText)
    private let speedLabel = makeLabel("", size: 11, color: Theme.secondaryText)
    private var timer: Timer?
    private var phase: CGFloat = 0
    private var finished = false

    convenience init(job: TransferJob) {
        self.init(window: nil)
        self.job = job
        build(headline: "\(job.verb) \(Fmt.count(job.sources.count, "item")) from ",
              from: job.sources.first?.deletingLastPathComponent().lastPathComponent ?? "",
              to: job.destination.lastPathComponent)
    }

    convenience init(title: String, process: Process) {
        self.init(window: nil)
        self.process = process
        build(headline: title, from: nil, to: nil)
        bar.indeterminate = true
    }

    private func build(headline text: String, from: String?, to: String?) {
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 210), styleMask: [.titled, .closable],
                        backing: .buffered, defer: true)
        w.title = "0% complete"
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.delegate = self
        window = w

        let a = NSMutableAttributedString(string: text, attributes: [.font: Theme.font(12), .foregroundColor: Theme.text])
        if let from, let to {
            let link: [NSAttributedString.Key: Any] = [.font: Theme.font(12), .foregroundColor: Theme.accent]
            a.append(NSAttributedString(string: from, attributes: link))
            a.append(NSAttributedString(string: " to ", attributes: [.font: Theme.font(12), .foregroundColor: Theme.text]))
            a.append(NSAttributedString(string: to, attributes: link))
        }
        headline.attributedStringValue = a

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false

        let details = NSStackView(views: [nameLabel, timeLabel, itemsLabel, speedLabel])
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 3
        details.translatesAutoresizingMaskIntoConstraints = false

        let root = ColorView(Theme.content)
        for v in [headline, percent, bar, details, cancel] as [NSView] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            headline.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            headline.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            headline.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            percent.topAnchor.constraint(equalTo: headline.bottomAnchor, constant: 10),
            percent.leadingAnchor.constraint(equalTo: headline.leadingAnchor),
            bar.topAnchor.constraint(equalTo: percent.bottomAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: headline.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            bar.heightAnchor.constraint(equalToConstant: 14),
            details.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 12),
            details.leadingAnchor.constraint(equalTo: headline.leadingAnchor),
            details.trailingAnchor.constraint(lessThanOrEqualTo: cancel.leadingAnchor, constant: -12),
            cancel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            cancel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        w.contentView = root
        w.center()
    }

    override func showWindow(_ sender: Any?) {
        guard !finished else { return }
        super.showWindow(sender)
        update()
        let t = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func update() {
        guard let job else {
            phase = phase >= 1 ? 0 : phase + 0.04
            bar.phase = phase
            percent.stringValue = "Working on it…"
            window?.title = "Working…"
            return
        }
        let s = job.snapshot
        let fraction = s.total > 0 ? Double(s.done) / Double(s.total) : (s.totalItems > 0 ? Double(s.items) / Double(s.totalItems) : 0)
        let pct = Int(min(100, fraction * 100))
        percent.stringValue = "\(pct)% complete"
        window?.title = "\(pct)% complete"
        bar.value = fraction
        nameLabel.stringValue = "Name:  \(s.name)"
        let elapsed = Date().timeIntervalSince(job.startDate)
        let speed = elapsed > 0 ? Double(s.done) / elapsed : 0
        speedLabel.stringValue = speed > 0 ? "Speed:  \(Fmt.size(Int64(speed)))/s" : "Speed:  Calculating…"
        if speed > 0, s.total > s.done {
            let secs = Int(Double(s.total - s.done) / speed)
            timeLabel.stringValue = "Time remaining:  " + (secs < 60 ? "About \(max(1, secs)) seconds" : "About \(secs / 60) minutes")
        } else {
            timeLabel.stringValue = "Time remaining:  Calculating…"
        }
        itemsLabel.stringValue = "Items remaining:  \(max(0, s.totalItems - s.items)) (\(Fmt.size(max(0, s.total - s.done))))"
    }

    @objc private func cancelPressed() {
        job?.cancel()
        process?.terminate()
    }

    func windowWillClose(_ notification: Notification) {
        if !finished { cancelPressed() }
        timer?.invalidate()
    }

    func finish() {
        finished = true
        timer?.invalidate()
        window?.orderOut(nil)
    }
}

// MARK: - Conflict dialog

enum ConflictDialog {
    static func run(job: TransferJob, name: String, src: URL, dst: URL) -> (ConflictChoice, Bool) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 330), styleMask: [.titled],
                            backing: .buffered, defer: false)
        panel.title = "Replace or Skip Files"
        let root = ColorView(Theme.content)
        panel.contentView = root

        let srcName = job.sources.first?.deletingLastPathComponent().lastPathComponent ?? ""
        let head = makeLabel("\(job.verb) \(Fmt.count(job.sources.count, "item")) from \(srcName) to \(job.destination.lastPathComponent)",
                             size: 12, color: Theme.secondaryText)
        let title = makeLabel("The destination already has a file named \"\(name)\"", size: 15, weight: .regular, color: Theme.accent)
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 3
        title.preferredMaxLayoutWidth = 430

        var result = ConflictChoice.skip
        func option(_ symbol: String, _ text: String, _ choice: ConflictChoice) -> HoverButton {
            let b = HoverButton(symbol: symbol, size: 15, title: text)
            b.alignLeft = true
            b.height = 40
            b.hPadding = 12
            b.font = Theme.font(13)
            b.imageColor = Theme.accent
            b.action = { result = choice; NSApp.stopModal() }
            return b
        }
        let replace = option("checkmark", "Replace the file in the destination", .replace)
        let skip = option("arrow.uturn.right", "Skip this file", .skip)
        let both = option("doc.on.doc", "Keep both files", .keepBoth)

        let fmt = { (u: URL) -> String in
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return "\(Fmt.size(Int64(v?.fileSize ?? 0))), modified \(Fmt.date(v?.contentModificationDate))"
        }
        let info = makeLabel("Source: \(fmt(src))\nDestination: \(fmt(dst))", size: 11, color: Theme.secondaryText)
        info.maximumNumberOfLines = 2

        let check = NSButton(checkboxWithTitle: "Do this for all conflicts", target: nil, action: nil)
        let cancel = NSButton(title: "Cancel", target: nil, action: nil)
        let cancelHandler = ButtonHandler { result = .cancel; NSApp.stopModal() }
        cancel.target = cancelHandler
        cancel.action = #selector(ButtonHandler.fire)
        cancel.keyEquivalent = "\u{1b}"

        let stack = NSStackView(views: [head, title, replace, skip, both, info, check])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(14, after: title)
        stack.setCustomSpacing(12, after: both)
        stack.translatesAutoresizingMaskIntoConstraints = false
        cancel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        root.addSubview(cancel)
        for b in [replace, skip, both] { b.widthAnchor.constraint(equalToConstant: 420).isActive = true }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
            cancel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            cancel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            cancel.topAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 10),
        ])
        panel.center()
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        _ = cancelHandler
        return (result, check.state == .on)
    }
}

/// Target/action trampoline for closures.
final class ButtonHandler: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func fire() { block() }
}
