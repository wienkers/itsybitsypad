import SwiftUI
import Bonsplit

/// The controls injected at the trailing (far-right) edge of every pane's tab bar,
/// left to right: toggle markdown preview, global search.
///
/// Wired into Bonsplit via `BonsplitController.tabBarTrailingAccessory`. Search is
/// window-global and dispatches through the responder chain to `AppDelegate`; the
/// markdown toggle operates on the focused pane's selected tab via the coordinator.
struct TabBarAccessoryView: View {
    let coordinator: EditorCoordinator

    /// Bumped on `markdownStateChanged` so the preview button refreshes when language
    /// detection lands after a tab is opened (tab/pane switches refresh via @Observable).
    @State private var markdownStateTick = 0

    private var focusedTabID: TabID? {
        guard let paneId = coordinator.controller.focusedPaneId else { return nil }
        return coordinator.controller.selectedTab(inPane: paneId)?.id
    }

    private var isMarkdown: Bool {
        _ = markdownStateTick
        return coordinator.isCurrentTabMarkdown
    }

    private var isPreviewing: Bool {
        _ = markdownStateTick
        guard let id = focusedTabID else { return false }
        return coordinator.isPreviewActive(for: id)
    }

    var body: some View {
        HStack(spacing: 2) {
            accessoryButton(
                systemImage: isPreviewing ? "rectangle.split.2x1.fill" : "rectangle.split.2x1",
                help: String(localized: "toolbar.toggle_markdown_preview", defaultValue: "Toggle markdown preview")
            ) {
                coordinator.togglePreview()
            }
            .disabled(!isMarkdown)

            accessoryButton(
                systemImage: "magnifyingglass",
                help: String(localized: "toolbar.search", defaultValue: "Search")
            ) {
                NSApp.sendAction(#selector(AppDelegate.globalSearchAction), to: nil, from: nil)
            }
        }
        .padding(.horizontal, 6)
        .onReceive(NotificationCenter.default.publisher(for: EditorCoordinator.markdownStateChanged)) { _ in
            markdownStateTick &+= 1
        }
    }

    @ViewBuilder
    private func accessoryButton(
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
