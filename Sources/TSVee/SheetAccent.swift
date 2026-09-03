import AppKit

/// A sheet's accent color: the tint of range selection, section headers,
/// checkboxes, fold triangles and the rest of the grid's chrome.
///
/// `.system` is the default — it follows the accent color set in System
/// Settings, so TSVee looks like the rest of the Mac. Naming a color instead
/// is a per-sheet choice, remembered in the `.tss` sidecar: telling one
/// project's sheets apart at a glance is worth more than uniformity across
/// all of them.
enum SheetAccent: String, CaseIterable {
    case system
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case green
    case graphite

    var title: String {
        self == .system ? "Automatic" : rawValue.capitalized
    }

    /// Every one of these is a dynamic color resolved at draw time, so the
    /// grid tracks light/dark appearance — and `.system` tracks whatever
    /// System Settings currently says.
    var color: NSColor {
        switch self {
        case .system: return .controlAccentColor
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .graphite: return .systemGray
        }
    }

    /// A filled dot for the menu item. Drawn on demand rather than baked, so
    /// it resolves against the menu's own appearance and `.system` picks up an
    /// accent change made while TSVee is running.
    var swatch: NSImage {
        let color = self.color
        return NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
    }
}
