import Foundation

/// A menu item for tab context menus
public struct TabContextMenuItem: Identifiable {
    /// What kind of row this item represents.
    public enum Kind {
        /// An interactive item that runs `action` when chosen.
        case action
        /// A divider between groups of items.
        case separator
        /// A non-interactive informational row (rendered disabled), e.g. a statistic.
        case info
    }

    public let id = UUID()
    public let kind: Kind
    public let title: String
    public let icon: String?
    public let isEnabled: Bool
    public let isChecked: Bool?
    public let action: () -> Void

    public init(title: String, icon: String? = nil, isEnabled: Bool = true, isChecked: Bool? = nil, action: @escaping () -> Void) {
        self.kind = .action
        self.title = title
        self.icon = icon
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.action = action
    }

    private init(kind: Kind, title: String, icon: String?) {
        self.kind = kind
        self.title = title
        self.icon = icon
        self.isEnabled = false
        self.isChecked = nil
        self.action = {}
    }

    /// A divider between groups of items.
    public static var separator: TabContextMenuItem {
        TabContextMenuItem(kind: .separator, title: "", icon: nil)
    }

    /// A non-interactive informational row, e.g. a statistic.
    public static func info(_ title: String, icon: String? = nil) -> TabContextMenuItem {
        TabContextMenuItem(kind: .info, title: title, icon: icon)
    }
}
