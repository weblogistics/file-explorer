import AppKit
import UniformTypeIdentifiers

// MARK: - Colors

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    /// A color that resolves differently in light and dark appearance.
    static func dyn(_ light: UInt32, _ dark: UInt32, _ lightAlpha: CGFloat = 1, _ darkAlpha: CGFloat = 1) -> NSColor {
        let l = NSColor(hex: light, alpha: lightAlpha)
        let d = NSColor(hex: dark, alpha: darkAlpha)
        return NSColor(name: nil) { $0.isDark ? d : l }
    }
}

/// Windows 11 inspired palette.
enum Theme {
    static let tabStrip = NSColor.dyn(0xE3E9F0, 0x1C1C1C)
    static let chrome = NSColor.dyn(0xF7F9FC, 0x2B2B2B)
    static let content = NSColor.dyn(0xFFFFFF, 0x191919)
    static let separator = NSColor.dyn(0xE5E5E5, 0x383838)
    static let strongSeparator = NSColor.dyn(0xD1D1D1, 0x474747)
    static let text = NSColor.dyn(0x1A1A1A, 0xF2F2F2)
    static let secondaryText = NSColor.dyn(0x5F5F5F, 0xC0C0C0)
    static let tertiaryText = NSColor.dyn(0x8A8A8A, 0x8F8F8F)
    static let disabledText = NSColor.dyn(0xA6A6A6, 0x666666)
    static let accent = NSColor.dyn(0x005FB8, 0x60CDFF)
    static let accentStrong = NSColor.dyn(0x005FB8, 0x0078D4)
    static let itemHover = NSColor.dyn(0xE5F3FF, 0x2D2D2D)
    static let itemSelected = NSColor.dyn(0xCCE8FF, 0x3A4552)
    static let itemSelectedHover = NSColor.dyn(0xB9DEFF, 0x44515F)
    static let itemSelectedInactive = NSColor.dyn(0xE4E4E4, 0x333333)
    static let itemDrop = NSColor.dyn(0xCCE8FF, 0x2E4A66)
    static let navHover = NSColor.dyn(0xF0F0F0, 0x262626)
    static let navSelected = NSColor.dyn(0xE3E3E3, 0x303030)
    static let buttonHover = NSColor.dyn(0x000000, 0xFFFFFF, 0.06, 0.08)
    static let buttonPressed = NSColor.dyn(0x000000, 0xFFFFFF, 0.10, 0.05)
    static let buttonToggled = NSColor.dyn(0x000000, 0xFFFFFF, 0.07, 0.10)
    static let field = NSColor.dyn(0xFFFFFF, 0x2D2D2D)
    static let fieldBorder = NSColor.dyn(0xDCDCDC, 0x3D3D3D)
    static let closeHover = NSColor(hex: 0xC42B1C)
    static let progressGreen = NSColor(hex: 0x06B025)
    static let progressTrack = NSColor.dyn(0xE6E6E6, 0x3A3A3A)
    static let driveBar = NSColor.dyn(0x26A0DA, 0x4CC2FF)
    static let driveBarFull = NSColor(hex: 0xDA2626)
    static let groupHeader = NSColor.dyn(0x1E3287, 0x99EBFF)
    static let searchProgress = NSColor.dyn(0x06B025, 0x2FD24A, 0.22, 0.28)

    static func font(_ size: CGFloat = 12, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }
}

// MARK: - Symbols

enum Sym {
    static func base(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "questionmark.square", accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 16, height: 16))
    }

    /// A monochrome template symbol.
    static func image(_ name: String, size: CGFloat = 14, weight: NSFont.Weight = .regular) -> NSImage {
        let b = base(name)
        let img = b.withSymbolConfiguration(.init(pointSize: size, weight: weight)) ?? b
        img.isTemplate = true
        return img
    }

    /// A symbol rendered in a fixed color.
    static func colored(_ name: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) -> NSImage {
        let b = base(name)
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let img = b.withSymbolConfiguration(cfg) ?? b
        img.isTemplate = false
        return img
    }
}

// MARK: - Drawing

enum Draw {
    static func fit(_ size: NSSize, in rect: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let s = min(rect.width / size.width, rect.height / size.height)
        let w = size.width * s, h = size.height * s
        return NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    static func image(_ img: NSImage, in rect: NSRect, alpha: CGFloat = 1) {
        let r = fit(img.size, in: rect)
        img.draw(in: r, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true,
                 hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
    }

    /// Draws a template image tinted with `color`, resolved against the current appearance.
    static func symbol(_ img: NSImage, in rect: NSRect, color: NSColor) {
        let natural = img.size
        let target: NSRect
        if natural.width <= rect.width && natural.height <= rect.height {
            target = NSRect(x: (rect.midX - natural.width / 2).rounded(), y: (rect.midY - natural.height / 2).rounded(),
                            width: natural.width, height: natural.height)
        } else {
            target = fit(natural, in: rect)
        }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.beginTransparencyLayer(in: target.insetBy(dx: -2, dy: -2), auxiliaryInfo: nil)
        img.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        color.setFill()
        target.insetBy(dx: -2, dy: -2).fill(using: .sourceAtop)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    static func rounded(_ r: NSRect, _ radius: CGFloat, fill: NSColor? = nil, stroke: NSColor? = nil, lineWidth: CGFloat = 1) {
        if let fill {
            fill.setFill()
            NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
        }
        if let stroke {
            stroke.setStroke()
            let p = NSBezierPath(roundedRect: r.insetBy(dx: lineWidth / 2, dy: lineWidth / 2), xRadius: radius, yRadius: radius)
            p.lineWidth = lineWidth
            p.stroke()
        }
    }

    static func attrs(_ font: NSFont, _ color: NSColor, align: NSTextAlignment = .left, wrap: Bool = false) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.alignment = align
        p.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
        return [.font: font, .foregroundColor: color, .paragraphStyle: p]
    }

    static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    /// Single line text, vertically centred in `r` (flipped coordinates).
    static func text(_ s: String, in r: NSRect, font: NSFont = Theme.font(), color: NSColor = Theme.text, align: NSTextAlignment = .left) {
        let h = lineHeight(font)
        let rect = NSRect(x: r.minX, y: (r.midY - h / 2).rounded(), width: r.width, height: h)
        (s as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                             attributes: attrs(font, color, align: align))
    }

    /// Multi line text from the top of `r`, truncated after `maxLines`.
    static func wrapped(_ s: String, in r: NSRect, font: NSFont = Theme.font(), color: NSColor = Theme.text,
                        align: NSTextAlignment = .center, maxLines: Int = 2) {
        let h = min(r.height, lineHeight(font) * CGFloat(maxLines))
        let rect = NSRect(x: r.minX, y: r.minY, width: r.width, height: h)
        var a = attrs(font, color, align: align, wrap: true)
        // Like Windows, break long names without spaces mid-word instead of clipping them.
        let longestWord = s.split(whereSeparator: { $0 == " " || $0 == "-" }).map { textWidth(String($0), font: font) }.max() ?? 0
        if longestWord > r.width, let p = (a[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
            p.lineBreakMode = .byCharWrapping
            a[.paragraphStyle] = p
        }
        (s as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: a)
    }

    static func textWidth(_ s: String, font: NSFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }
}

// MARK: - Formatting

enum Fmt {
    static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    static let longDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .medium
        return f
    }()

    static let monthYear: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return f
    }()

    static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    static func number(_ n: Int64) -> String { grouped.string(from: NSNumber(value: n)) ?? "\(n)" }

    /// Windows "Size" column style: always KB, rounded up.
    static func kb(_ bytes: Int64) -> String {
        let kb = bytes <= 0 ? 0 : (bytes + 1023) / 1024
        return "\(number(kb)) KB"
    }

    /// Windows style size with three significant digits ("1.23 MB").
    static func size(_ bytes: Int64) -> String {
        if bytes < 1024 { return bytes == 1 ? "1 byte" : "\(bytes) bytes" }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var v = Double(bytes) / 1024
        var i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1024; i += 1 }
        let s: String
        if v >= 100 { s = String(format: "%.0f", floor(v)) }
        else if v >= 10 { s = String(format: "%.1f", floor(v * 10) / 10) }
        else { s = String(format: "%.2f", floor(v * 100) / 100) }
        return "\(s) \(units[i])"
    }

    static func sizeWithBytes(_ bytes: Int64) -> String {
        "\(size(bytes)) (\(number(bytes)) bytes)"
    }

    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(number(Int64(n))) \(n == 1 ? singular : (plural ?? singular + "s"))"
    }

    static func date(_ d: Date?) -> String { d.map { shortDate.string(from: $0) } ?? "" }

    static func abbreviatePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

// MARK: - Menus

final class ClosureMenuItem: NSMenuItem {
    private var handler: (() -> Void)?

    init(_ title: String, symbol: String? = nil, image: NSImage? = nil, key: String = "",
         modifiers: NSEvent.ModifierFlags = [.command], checked: Bool = false, enabled: Bool = true,
         handler: (() -> Void)? = nil) {
        self.handler = handler
        super.init(title: title, action: handler == nil ? nil : #selector(ClosureMenuItem.fire), keyEquivalent: key)
        target = self
        keyEquivalentModifierMask = modifiers
        if let image { self.image = image } else if let symbol { self.image = Sym.image(symbol, size: 13) }
        state = checked ? .on : .off
        isEnabled = enabled && handler != nil
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { handler?() }
}

extension NSMenu {
    convenience init(items: [NSMenuItem]) {
        self.init()
        autoenablesItems = false
        items.forEach { addItem($0) }
    }

    static func sub(_ title: String, symbol: String? = nil, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol { item.image = Sym.image(symbol, size: 13) }
        item.submenu = NSMenu(items: items)
        return item
    }
}

// MARK: - Views

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A view that paints a solid (appearance aware) background.
class ColorView: FlippedView {
    var color: NSColor { didSet { needsDisplay = true } }
    init(_ color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        dirtyRect.intersection(bounds).fill()
    }
}

extension NSView {
    func pinEdges(to other: NSView, insets: NSEdgeInsets = NSEdgeInsets()) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom),
        ])
    }
}

func makeLabel(_ text: String = "", size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = Theme.text) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = Theme.font(size, weight)
    l.textColor = color
    l.lineBreakMode = .byTruncatingTail
    l.translatesAutoresizingMaskIntoConstraints = false
    return l
}

// MARK: - Alerts

enum Alerts {
    @discardableResult
    static func show(_ title: String, _ message: String = "", style: NSAlert.Style = .warning,
                     buttons: [String] = ["OK"], icon: NSImage? = nil) -> Int {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = style
        if let icon { a.icon = icon }
        for b in buttons { a.addButton(withTitle: b) }
        let r = a.runModal()
        return r.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    static func confirm(_ title: String, _ message: String, yes: String = "Yes", no: String = "No", icon: NSImage? = nil) -> Bool {
        show(title, message, buttons: [yes, no], icon: icon) == 0
    }
}

// MARK: - Misc

extension URL {
    /// Normalised directory URL used for location identity.
    var dirNormalized: URL { URL(fileURLWithPath: standardizedFileURL.path, isDirectory: true) }
    var isDirectoryOnDisk: Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &d) && d.boolValue
    }
    var isPackageOnDisk: Bool { (try? resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false }
}

extension Array {
    subscript(safe i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}
