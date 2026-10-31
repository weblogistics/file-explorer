import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

enum NavIconKind { case home, gallery, thisPC, recycleBin, network }

enum IconFactory {
    private static var cache: [String: NSImage] = [:]

    private static func cached(_ key: String, size: CGFloat, draw: @escaping (NSRect) -> Void) -> NSImage {
        if let c = cache[key] { return c }
        let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { r in draw(r); return true }
        cache[key] = img
        return img
    }

    // MARK: Folder

    static func folder(size: CGFloat, badge: KnownFolder? = nil, link: Bool = false) -> NSImage {
        cached("folder-\(size)-\(badge?.rawValue ?? "-")-\(link)", size: size) { r in
            drawFolder(in: r, badge: badge, link: link, band: false)
        }
    }

    static func drawFolder(in r: NSRect, badge: KnownFolder?, link: Bool, band: Bool) {
        let s = r.width
        func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: r.minX + x * s, y: r.minY + y * s) }
        func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: r.minX + x * s, y: r.minY + y * s, width: w * s, height: h * s)
        }
        let rad = max(1, s * 0.05)
        let k = rad / s

        // Back panel with tab
        let tab = NSBezierPath()
        tab.move(to: P(0.05, 0.32))
        tab.line(to: P(0.05, 0.17 + k))
        tab.curve(to: P(0.05 + k, 0.17), controlPoint1: P(0.05, 0.17), controlPoint2: P(0.05, 0.17))
        tab.line(to: P(0.35, 0.17))
        tab.curve(to: P(0.40, 0.19), controlPoint1: P(0.38, 0.17), controlPoint2: P(0.38, 0.17))
        tab.line(to: P(0.47, 0.245))
        tab.line(to: P(0.47, 0.32))
        tab.close()
        let body = NSBezierPath(roundedRect: R(0.05, 0.225, 0.90, 0.62), xRadius: rad, yRadius: rad)
        let back = NSGradient(starting: NSColor(hex: 0xF2B526), ending: NSColor(hex: 0xE09A0E))!
        back.draw(in: tab, angle: 90)
        back.draw(in: body, angle: 90)

        // Paper
        if s >= 20 {
            let paper = NSBezierPath(roundedRect: R(0.11, 0.28, 0.78, 0.40), xRadius: rad * 0.6, yRadius: rad * 0.6)
            NSColor(hex: 0xFFFFFF).setFill()
            paper.fill()
            NSColor(hex: 0xE2E2E2).setStroke()
            paper.lineWidth = max(0.5, s / 128)
            paper.stroke()
        }

        // Front panel
        let front = NSBezierPath(roundedRect: R(0.05, 0.37, 0.90, 0.475), xRadius: rad, yRadius: rad)
        NSGradient(starting: NSColor(hex: 0xFFDC72), ending: NSColor(hex: 0xFFC738))!.draw(in: front, angle: 90)
        if s >= 32 {
            NSColor(hex: 0xFFEBAE).setFill()
            R(0.05 + k, 0.37, 0.90 - 2 * k, max(1, s / 96) / s).fill()
        }

        if band {
            let b = NSBezierPath(roundedRect: R(0.05, 0.70, 0.90, 0.145), xRadius: rad, yRadius: rad)
            NSGradient(starting: NSColor(hex: 0x2A9BF0), ending: NSColor(hex: 0x0F6CC2))!.draw(in: b, angle: 90)
            NSColor(hex: 0x0F6CC2).setFill()
            R(0.05, 0.70, 0.90, 0.05).fill()
        }

        if let badge, s >= 24 {
            let g = Sym.colored(badge.symbol, size: s * 0.24, color: badge.color, weight: .semibold)
            Draw.image(g, in: R(0.32, 0.45, 0.36, 0.32))
        }

        if link { drawLinkArrow(in: r) }
    }

    static func drawLinkArrow(in r: NSRect) {
        let s = r.width
        let box = NSRect(x: r.minX + s * 0.02, y: r.maxY - s * 0.36, width: s * 0.34, height: s * 0.34)
        Draw.rounded(box, s * 0.04, fill: .white, stroke: NSColor(hex: 0xB0B0B0), lineWidth: max(0.5, s / 64))
        let a = Sym.colored("arrow.up.right", size: s * 0.2, color: NSColor(hex: 0x0067C0), weight: .bold)
        Draw.image(a, in: box.insetBy(dx: s * 0.06, dy: s * 0.06))
    }

    // MARK: Drive

    static func drive(size: CGFloat, kind: DriveKind) -> NSImage {
        cached("drive-\(size)-\(kind)", size: size) { r in drawDrive(in: r, kind: kind) }
    }

    static func drawDrive(in r: NSRect, kind: DriveKind) {
        let s = r.width
        func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: r.minX + x * s, y: r.minY + y * s, width: w * s, height: h * s)
        }
        let top: CGFloat = kind == .removable ? 0.46 : 0.42
        let body = NSBezierPath(roundedRect: R(0.07, top, 0.86, 0.80 - top), xRadius: s * 0.06, yRadius: s * 0.06)
        let colors: (UInt32, UInt32) = kind == .network ? (0xD9E6F2, 0x9DB3C8) : (0xE8EBEF, 0xB3BBC4)
        NSGradient(starting: NSColor(hex: colors.0), ending: NSColor(hex: colors.1))!.draw(in: body, angle: 90)
        NSColor(hex: 0x7F8891).setStroke()
        body.lineWidth = max(0.6, s / 48)
        body.stroke()
        NSColor(hex: 0x8E979F).setFill()
        R(0.12, 0.70, 0.62, max(1, s / 32) / s).fill()
        NSColor(hex: 0x3BD14A).setFill()
        NSBezierPath(ovalIn: R(0.78, 0.66, 0.07, 0.07)).fill()

        switch kind {
        case .system where s >= 20:
            let q = 0.11, g = 0.015, x0 = 0.385, y0 = 0.12
            NSColor(hex: 0x0078D4).setFill()
            for (dx, dy) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] {
                R(x0 + dx * (q + g), y0 + dy * (q + g), q, q).fill()
            }
        case .removable where s >= 20:
            let u = Sym.colored("cable.connector", size: s * 0.22, color: NSColor(hex: 0x5A6570))
            Draw.image(u, in: R(0.35, 0.12, 0.3, 0.3))
        case .network where s >= 20:
            NSColor(hex: 0x5A6570).setFill()
            R(0.48, 0.80, 0.04, 0.10).fill()
            R(0.25, 0.88, 0.50, 0.04).fill()
        default: break
        }
    }

    // MARK: Glyphs

    static func knownGlyph(_ k: KnownFolder, size: CGFloat = 13) -> NSImage {
        let key = "glyph-\(k.rawValue)-\(size)"
        if let c = cache[key] { return c }
        let img = Sym.colored(k.symbol, size: size, color: k.color, weight: .medium)
        cache[key] = img
        return img
    }

    static func navIcon(_ kind: NavIconKind, size: CGFloat = 13) -> NSImage {
        let key = "nav-\(kind)-\(size)"
        if let c = cache[key] { return c }
        let img: NSImage
        switch kind {
        case .home: img = Sym.colored("house.fill", size: size, color: NSColor(hex: 0xE0A030))
        case .gallery: img = Sym.colored("photo.on.rectangle.angled", size: size, color: NSColor(hex: 0x2B88D8))
        case .thisPC: img = Sym.colored("desktopcomputer", size: size, color: NSColor(hex: 0x2B88D8))
        case .recycleBin: img = Sym.colored("trash.fill", size: size, color: NSColor(hex: 0x7A8590))
        case .network: img = Sym.colored("network", size: size, color: NSColor(hex: 0x2B88D8))
        }
        cache[key] = img
        return img
    }

    // MARK: App icon

    static func writeIconset(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let specs: [(String, Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for (name, px) in specs {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = NSSize(width: px, height: px)
            NSGraphicsContext.saveGraphicsState()
            let ctx = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current = ctx
            // Flip so the folder drawing code (top-left origin) works.
            ctx?.cgContext.translateBy(x: 0, y: CGFloat(px))
            ctx?.cgContext.scaleBy(x: 1, y: -1)
            let inset = CGFloat(px) * 0.06
            drawFolder(in: NSRect(x: inset, y: inset, width: CGFloat(px) - inset * 2, height: CGFloat(px) - inset * 2),
                       badge: nil, link: false, band: true)
            NSGraphicsContext.restoreGraphicsState()
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: dir.appendingPathComponent("\(name).png"))
            }
        }
    }
}

// MARK: - File icons & thumbnails

final class FileIcons {
    static let shared = FileIcons()
    private var typeCache: [String: NSImage] = [:]
    private let pathCache = NSCache<NSString, NSImage>()
    private let thumbCache = NSCache<NSString, NSImage>()
    private var waiting: [String: [(NSImage) -> Void]] = [:]
    private var failed: Set<String> = []

    init() {
        pathCache.countLimit = 2000
        thumbCache.countLimit = 600
    }

    func icon(for item: FileItem, size: CGFloat) -> NSImage {
        if item.isVolume { return IconFactory.drive(size: size, kind: VolumeInfo.kind(for: item.url)) }
        if item.isDirectory {
            if item.path == trashURL.path { return Sym.colored("trash.fill", size: size * 0.7, color: NSColor(hex: 0x7A8590)) }
            return IconFactory.folder(size: max(16, size), badge: KnownFolder.match(item.url), link: item.isLink || item.isAlias)
        }
        return fileIcon(url: item.url, ext: item.ext, unique: item.isPackage || item.ext.isEmpty || item.isLink || item.isAlias
                        || ["app", "icns", "ico", "prefpane", "webloc"].contains(item.ext))
    }

    func fileIcon(url: URL, ext: String, unique: Bool) -> NSImage {
        if unique {
            if let c = pathCache.object(forKey: url.path as NSString) { return c }
            let img = NSWorkspace.shared.icon(forFile: url.path)
            pathCache.setObject(img, forKey: url.path as NSString)
            return img
        }
        if let c = typeCache[ext] { return c }
        let img = FileManager.default.fileExists(atPath: url.path)
            ? NSWorkspace.shared.icon(forFile: url.path)
            : NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        typeCache[ext] = img
        return img
    }

    func canThumbnail(_ item: FileItem) -> Bool {
        guard !item.isDirectory, !item.isPackage, let t = UTType(filenameExtension: item.ext) else { return false }
        return t.conforms(to: .image) || t.conforms(to: .movie) || t.conforms(to: .pdf)
            || t.conforms(to: .audiovisualContent) || t.conforms(to: .presentation)
    }

    /// Returns a cached thumbnail immediately, or nil and calls `completion` later.
    func thumbnail(for item: FileItem, size: CGFloat, completion: @escaping (NSImage) -> Void) -> NSImage? {
        let key = "\(item.path)|\(Int(size))|\(item.modified?.timeIntervalSince1970 ?? 0)"
        if let img = thumbCache.object(forKey: key as NSString) { return img }
        if failed.contains(key) { return nil }
        if waiting[key] != nil {
            waiting[key]?.append(completion)
            return nil
        }
        waiting[key] = [completion]
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let req = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: size, height: size),
                                               scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            let img = rep?.nsImage
            DispatchQueue.main.async {
                let callbacks = self.waiting.removeValue(forKey: key) ?? []
                guard let img else { self.failed.insert(key); return }
                self.thumbCache.setObject(img, forKey: key as NSString)
                callbacks.forEach { $0(img) }
            }
        }
        return nil
    }
}
