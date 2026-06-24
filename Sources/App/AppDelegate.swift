import Bonsplit
import Cocoa
import SwiftUI

private class EditorPanel: NSPanel {
    override var hidesOnDeactivate: Bool {
        get { false }
        set { }
    }

    // Right-click anywhere the content doesn't handle → window-chrome menu (restore the
    // hidden title-bar buttons). Best-effort; the menu-bar item is the reliable path.
    override func rightMouseDown(with event: NSEvent) {
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.showWindowContextMenu(for: event, in: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }
}

/// Content container whose safe-area insets can be forced to zero, so in compact (no
/// title bar) mode the content fills to the very top edge instead of leaving the empty
/// strip the title bar's safe area would otherwise reserve.
private class ContentContainerView: NSView {
    var ignoresTopSafeArea = true {
        didSet {
            guard ignoresTopSafeArea != oldValue else { return }
            needsLayout = true
            subviews.forEach { $0.needsLayout = true }
        }
    }

    override var safeAreaInsets: NSEdgeInsets {
        ignoresTopSafeArea ? NSEdgeInsets() : super.safeAreaInsets
    }
}

private class FileDropView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) else { return [] }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        NotificationCenter.default.post(
            name: EditorTextView.fileDropNotification,
            object: nil,
            userInfo: ["urls": urls]
        )
        return true
    }
}

// MARK: - Toolbar identifiers

private extension NSToolbarItem.Identifier {
    static let newTab = NSToolbarItem.Identifier("newTab")
    static let openFile = NSToolbarItem.Identifier("openFile")
    static let saveFile = NSToolbarItem.Identifier("saveFile")
    static let findReplace = NSToolbarItem.Identifier("findReplace")
    static let tabSwitcher = NSToolbarItem.Identifier("tabSwitcher")
    static let markdownPreview = NSToolbarItem.Identifier("markdownPreview")
    static let fileBrowser = NSToolbarItem.Identifier("fileBrowser")
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSToolbarDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var editorWindow: NSPanel?
    private var editorCoordinator: EditorCoordinator?
    private var fileBrowserSplitVC: FileBrowserSplitViewController?
    private var settingsWindow: NSWindow?
    private var windowWasVisible = false
    private var workspaceObserver: Any?
    private var activationObserver: Any?
    private var lastFrontmostBundleID: String?
    private var settingsObserver: Any?
    private var appearanceObservation: NSKeyValueObservation?
    private var recentFilesMenu: NSMenu?
    private var isPinned = UserDefaults.standard.bool(forKey: "alwaysOnTop") {
        didSet { UserDefaults.standard.set(isPinned, forKey: "alwaysOnTop") }
    }
    private var windowButtonsVisible = false
    private weak var editorContentContainer: ContentContainerView?
    private var markdownObserver: Any?
    private var autosaveTimer: Timer?
    private var windowKeyObservers: [Any] = []
    private var showMarkdownPreview = false
    private var pendingFileURLs: [URL] = []
    private var tabSwitchMonitor: Any?
    private var globalSearchController: GlobalSearchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupEditorWindow()
        setupMainMenu()
        updateDockVisibility()

        // Register hotkey
        HotkeyManager.shared.register()

        installTabSwitchMonitor()
        setupAutosave()

        // Start clipboard monitoring if enabled
        if SettingsStore.shared.clipboardEnabled {
            ClipboardStore.shared.startMonitoring()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(editorWindowWillClose),
            name: NSWindow.willCloseNotification,
            object: editorWindow
        )
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
                self?.lastFrontmostBundleID = app.bundleIdentifier
            }
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == self.lastFrontmostBundleID else { return }
                self.restoreWindowIfNeeded()
            }
        }
        // Apply theme to window when settings change
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyWindowAppearance()
                self?.updateDockVisibility()
                self?.updateMenuBarVisibility()
            }
        }

        // Re-apply theme when macOS appearance changes (affects "system" mode)
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            MainActor.assumeIsolated {
                guard SettingsStore.shared.appearanceOverride == "system" else { return }
                NotificationCenter.default.post(name: .settingsChanged, object: nil)
            }
        }

        markdownObserver = NotificationCenter.default.addObserver(
            forName: EditorCoordinator.markdownStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                let isMarkdown = notification.userInfo?["isMarkdown"] as? Bool ?? false
                let isPreviewing = notification.userInfo?["isPreviewing"] as? Bool ?? false
                self?.updateMarkdownToolbarItem(isMarkdown: isMarkdown, isPreviewing: isPreviewing)
            }
        }

        // Notifications during EditorCoordinator.init fire before the observer above is registered,
        // so check the initial state now.
        if let isMarkdown = editorCoordinator?.isCurrentTabMarkdown {
            updateMarkdownToolbarItem(isMarkdown: isMarkdown, isPreviewing: false)
        }

        if SettingsStore.shared.newTabOnLaunch {
            let hasEmptyTab = TabStore.shared.tabs.contains { $0.content.isEmpty && $0.fileURL == nil }
            if !hasEmptyTab {
                editorCoordinator?.newTab()
            }
        }

        for url in pendingFileURLs {
            showWindowAndOpen(url: url)
        }
        pendingFileURLs.removeAll()
    }

    @objc private func editorWindowWillClose(_ note: Notification) {
        windowWasVisible = false
        DispatchQueue.main.async { [weak self] in
            self?.updateDockVisibility()
        }
    }

    private func restoreWindowIfNeeded() {
        // Only needed in accessory mode (no dock icon) where macOS won't
        // automatically bring our window forward after the frontmost app quits.
        guard !SettingsStore.shared.showInDock else { return }
        guard windowWasVisible, let window = editorWindow else { return }
        guard window.isVisible, !window.isMiniaturized else { return }
        window.orderFrontRegardless()
        window.makeKey()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let window = editorWindow else { return false }
        windowWasVisible = true
        window.orderFrontRegardless()
        window.makeKey()
        updateDockVisibility()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClipboardStore.shared.stopMonitoring()
        editorCoordinator?.saveActiveTabCursor()
        TabStore.shared.saveSession()
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        showWindowAndOpen(url: url)
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for filename in filenames {
            let url = URL(fileURLWithPath: filename)
            showWindowAndOpen(url: url)
        }
        sender.reply(toOpenOrPrint: .success)
    }

    private func showWindowAndOpen(url: URL) {
        guard let window = editorWindow else {
            pendingFileURLs.append(url)
            return
        }
        windowWasVisible = true
        window.orderFrontRegardless()
        window.makeKey()
        updateDockVisibility()
        editorCoordinator?.openFile(url: url)
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = makeMenuBarIcon()
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp])
        }
    }

    private func makeMenuBarIcon() -> NSImage {
        let bundle: Bundle
        #if SWIFT_PACKAGE
        bundle = Bundle.module
        #else
        bundle = Bundle.main
        #endif
        guard let image = bundle.image(forResource: "menuBar") else {
            return NSImage(size: NSSize(width: 18, height: 18))
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if let window = editorWindow, !window.isVisible || !window.isKeyWindow {
            showItsypad()
        } else {
            showMenu()
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        let windowIsActive = editorWindow?.isKeyWindow == true
        let toggleTitle = windowIsActive
            ? String(localized: "statusbar.hide", defaultValue: "Hide Itsypad")
            : String(localized: "statusbar.show", defaultValue: "Show Itsypad")
        let toggleIcon = windowIsActive ? "macwindow.badge.minus" : "macwindow"
        let showItem = NSMenuItem(title: toggleTitle, action: #selector(showItsypad), keyEquivalent: "")
        showItem.image = NSImage(systemSymbolName: toggleIcon, accessibilityDescription: nil)
        showItem.target = self
        if let keys = SettingsStore.shared.shortcutKeys {
            if keys.isTripleTap, let mod = keys.tapModifier {
                let symbol: String
                if mod.contains("option") { symbol = "⌥" }
                else if mod.contains("control") { symbol = "⌃" }
                else if mod.contains("shift") { symbol = "⇧" }
                else if mod.contains("command") { symbol = "⌘" }
                else { symbol = "" }
                let side = mod.hasPrefix("left-") ? " L" : mod.hasPrefix("right-") ? " R" : ""
                let hint = "  \(String(repeating: symbol, count: modifierTapCount))\(side)"
                let attributed = NSMutableAttributedString(string: toggleTitle)
                attributed.append(NSAttributedString(string: hint, attributes: [
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ]))
                showItem.attributedTitle = attributed
            } else if let char = Self.characterForKeyCode(keys.keyCode) {
                showItem.keyEquivalent = char
                showItem.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: UInt(keys.modifiers))
            }
        }
        menu.addItem(showItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: String(localized: "statusbar.settings", defaultValue: "Settings..."), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settingsItem.target = self
        menu.addItem(settingsItem)

        let buttonsItem = NSMenuItem(title: windowButtonsMenuTitle(), action: #selector(toggleWindowButtons), keyEquivalent: "")
        buttonsItem.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: nil)
        buttonsItem.target = self
        menu.addItem(buttonsItem)

        #if !APPSTORE
        let updateItem = NSMenuItem(title: String(localized: "statusbar.check_for_updates", defaultValue: "Check for updates..."), action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        updateItem.target = self
        menu.addItem(updateItem)
        #endif

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: String(localized: "statusbar.quit", defaultValue: "Quit Itsypad"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - Editor window

    private func setupEditorWindow() {
        let coordinator = EditorCoordinator()
        editorCoordinator = coordinator

        let rootView = BonsplitRootView(coordinator: coordinator)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.autoresizingMask = [.width, .height]

        // Wrap hosting view in a container so FileDropView isn't a direct subview of NSHostingView
        let contentContainer = ContentContainerView()
        editorContentContainer = contentContainer
        let dropView = FileDropView(frame: .zero)
        dropView.autoresizingMask = [.width, .height]
        contentContainer.addSubview(dropView)
        contentContainer.addSubview(hostingView)

        let splitVC = FileBrowserSplitViewController(contentView: contentContainer)
        splitVC.onFileSelected = { [weak coordinator] url in
            coordinator?.openFile(url: url)
        }
        fileBrowserSplitVC = splitVC

        let panel = EditorPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
            // .nonactivatingPanel lets the panel take keyboard focus WITHOUT activating
            // the app, so summoning it never pulls us off another app's full-screen Space.
            // No .closable/.miniaturizable: this is a chrome-less HUD overlay.
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.tabbingMode = .disallowed
        panel.isMovableByWindowBackground = true   // draggable without a title bar
        panel.isFloatingPanel = false
        panel.animationBehavior = .none   // instant show/hide – no fade flash when refocusing
        // Float above normal windows. Combined with the collection behavior below and
        // orderFrontRegardless() (see revealEditorWindow), this overlays the panel on
        // another app's full-screen Space instead of switching Spaces. Always floating so
        // the overlay works regardless of the (now cosmetic) Always-on-Top toggle.
        panel.level = .floating
        // .canJoinAllSpaces keeps the panel on whatever Space is active (including a
        // full-screen one); .fullScreenAuxiliary permits it to draw over a full-screen app.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Hide the traffic-light buttons – chrome-less HUD.
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.minSize = NSSize(width: 320, height: 400)
        panel.contentView = splitVC.view
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.setFrameAutosaveName("EditorWindow")

        editorWindow = panel

        applyWindowAppearance()

        // Show window on launch (as a floating overlay; does not switch Spaces).
        revealEditorWindow()
    }

    /// Reveal the editor panel as a floating overlay on the CURRENT Space – including over
    /// another app's full-screen Space – without switching Spaces. orderFrontRegardless()
    /// plus makeKey() (instead of NSApp.activate(ignoringOtherApps:)) is what keeps us on
    /// the current Space; the .nonactivatingPanel style lets the panel take keyboard focus
    /// without activating the app. Menu key-equivalents still work because the panel is key.
    private func revealEditorWindow() {
        guard let window = editorWindow else { return }
        windowWasVisible = true
        window.orderFrontRegardless()
        window.makeKey()
        updateDockVisibility()
    }

    private func applyWindowAppearance() {
        let theme = EditorTheme.current(for: SettingsStore.shared.appearanceOverride)
        editorWindow?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)

        // Set window background to theme color so Bonsplit's tab bar picks it up
        let blendTarget: NSColor = theme.isDark ? .white : .black
        let tabBarBg = theme.background.blended(withFraction: 0.06, of: blendTarget) ?? theme.background
        editorWindow?.backgroundColor = tabBarBg
    }

    func toggleWindow() {
        guard let window = editorWindow else { return }

        // Option double-tap is a pure open/close on visibility: if the panel is on screen
        // (focused or not) it hides; otherwise it shows and takes focus.
        if window.isVisible {
            windowWasVisible = false
            window.orderOut(nil)
            updateDockVisibility()
        } else {
            revealEditorWindow()
        }
    }

    func toggleClipboard() {
        guard let window = editorWindow else { return }

        if window.isKeyWindow {
            windowWasVisible = false
            window.orderOut(nil)
        } else {
            windowWasVisible = true
            window.orderFrontRegardless()
            window.makeKey()
            editorCoordinator?.selectClipboardTab()
        }
        updateDockVisibility()
    }

    /// Double-tap Command. If Itsy holds keyboard focus, hand it back to the previously
    /// active app while keeping the panel visible; otherwise (re)focus Itsy. When Itsy is
    /// not focused this matches the Option double-tap (both refocus Itsy).
    func commandTapAction() {
        guard let window = editorWindow else { return }
        if window.isKeyWindow {
            returnFocusToPreviousApp()
        } else {
            revealEditorWindow()
        }
    }

    /// Hand keyboard focus back to the app that was active before Itsy, without hiding the
    /// (floating) panel. Re-activating that app can be a no-op if it was already frontmost,
    /// so we also order the panel out and straight back in *without* makeKey(): that drops
    /// key focus to the active app's window while keeping the panel on screen.
    private func returnFocusToPreviousApp() {
        guard let window = editorWindow else { return }
        if let bid = lastFrontmostBundleID,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
            app.activate()
        }
        window.orderOut(nil)
        window.orderFrontRegardless()
    }

    // MARK: - Window chrome (toolbar + title-bar buttons)

    /// Apply the current chrome state. Compact (default): no toolbar, transparent title
    /// bar, hidden traffic-light buttons, content filling to the top edge. Full: the
    /// toolbar (sidebar / new / open / save / … icons) and traffic-light buttons return.
    private func applyChrome() {
        guard let window = editorWindow else { return }
        let show = windowButtonsVisible

        if show {
            // Drop .fullSizeContentView so the content sits BELOW the toolbar instead of
            // the toolbar overlaying the tabs.
            window.styleMask.remove(.fullSizeContentView)
            if window.toolbar == nil { window.toolbar = makeEditorToolbar() }
        } else {
            window.styleMask.insert(.fullSizeContentView)
            window.toolbar = nil
        }
        window.standardWindowButton(.closeButton)?.isHidden = !show
        window.standardWindowButton(.miniaturizeButton)?.isHidden = !show
        window.standardWindowButton(.zoomButton)?.isHidden = !show
        window.titlebarAppearsTransparent = !show
        editorContentContainer?.ignoresTopSafeArea = !show
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func makeEditorToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "EditorToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        // Suppress the toolbar's native right-click menu (Icon and Text / Text Only /
        // Customize…) – never used and it blocked re-hiding the toolbar.
        toolbar.allowsUserCustomization = false
        if #available(macOS 15.0, *) {
            toolbar.allowsDisplayModeCustomization = false
        }
        return toolbar
    }

    @objc func toggleWindowButtons() {
        windowButtonsVisible.toggle()
        applyChrome()
    }

    private func windowButtonsMenuTitle() -> String {
        windowButtonsVisible
            ? String(localized: "menu.window.hide_chrome", defaultValue: "Hide toolbar & buttons")
            : String(localized: "menu.window.show_chrome", defaultValue: "Show toolbar & buttons")
    }

    func showWindowContextMenu(for event: NSEvent, in window: NSWindow) {
        guard let contentView = window.contentView else { return }
        let menu = NSMenu()
        let item = NSMenuItem(title: windowButtonsMenuTitle(), action: #selector(toggleWindowButtons), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        NSMenu.popUpContextMenu(menu, with: event, for: contentView)
    }

    private func updateDockVisibility() {
        NSApp.setActivationPolicy(SettingsStore.shared.showInDock ? .regular : .accessory)
    }

    private func updateMenuBarVisibility() {
        statusItem.isVisible = SettingsStore.shared.showInMenuBar
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var items: [NSToolbarItem.Identifier] = [.fileBrowser, .newTab, .openFile, .saveFile, .flexibleSpace, .tabSwitcher, .space]
        if showMarkdownPreview {
            items.append(.markdownPreview)
        }
        items.append(.findReplace)
        return items
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.fileBrowser, .newTab, .openFile, .saveFile, .flexibleSpace, .tabSwitcher, .space, .markdownPreview, .findReplace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .fileBrowser:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: String(localized: "toolbar.sidebar", defaultValue: "Sidebar"))
            item.label = String(localized: "toolbar.sidebar", defaultValue: "Sidebar")
            item.toolTip = String(localized: "toolbar.toggle_sidebar", defaultValue: "Toggle sidebar (⌘B)")
            item.target = self
            item.action = #selector(toggleFileBrowser)
            return item
        case .tabSwitcher:
            let menuItem = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            menuItem.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: String(localized: "toolbar.tabs", defaultValue: "Tabs"))
            menuItem.label = String(localized: "toolbar.tabs", defaultValue: "Tabs")
            menuItem.toolTip = String(localized: "toolbar.switch_tab", defaultValue: "Switch tab")
            menuItem.showsIndicator = true
            menuItem.menu = buildTabSwitcherMenu()
            return menuItem
        default:
            break
        }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)

        switch itemIdentifier {
        case .newTab:
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: String(localized: "toolbar.new_tab", defaultValue: "New tab"))
            item.label = String(localized: "toolbar.new_tab", defaultValue: "New tab")
            item.toolTip = String(localized: "toolbar.new_tab", defaultValue: "New tab")
            item.target = self
            item.action = #selector(newTabAction)
        case .openFile:
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: String(localized: "toolbar.open", defaultValue: "Open"))
            item.label = String(localized: "toolbar.open", defaultValue: "Open")
            item.toolTip = String(localized: "toolbar.open_file", defaultValue: "Open file")
            item.target = self
            item.action = #selector(openFileAction)
        case .saveFile:
            item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: String(localized: "toolbar.save", defaultValue: "Save"))
            item.label = String(localized: "toolbar.save", defaultValue: "Save")
            item.toolTip = String(localized: "toolbar.save_file", defaultValue: "Save file")
            item.target = self
            item.action = #selector(saveFileAction)
        case .markdownPreview:
            let isPreviewing = currentSelectedTabID().flatMap { editorCoordinator?.isPreviewActive(for: $0) } ?? false
            item.image = NSImage(systemSymbolName: isPreviewing ? "rectangle.split.2x1.fill" : "rectangle.split.2x1", accessibilityDescription: String(localized: "toolbar.preview", defaultValue: "Preview"))
            item.label = String(localized: "toolbar.preview", defaultValue: "Preview")
            item.toolTip = String(localized: "toolbar.toggle_preview", defaultValue: "Toggle markdown preview (⇧⌘P)")
            item.target = self
            item.action = #selector(togglePreviewAction)
        case .findReplace:
            item.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: String(localized: "toolbar.search", defaultValue: "Search"))
            item.label = String(localized: "toolbar.search", defaultValue: "Search")
            item.toolTip = String(localized: "toolbar.search_all_tabs", defaultValue: "Search all tabs (⇧⌘F)")
            item.target = self
            item.action = #selector(globalSearchAction)
        default:
            return nil
        }

        return item
    }

    // MARK: - Settings

    @objc func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "settings.title", defaultValue: "Itsypad settings")
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false

        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window
    }

    // MARK: - Main menu

    private func setupMainMenu() {
        let builder = MenuBuilder(target: self)

        let recentMenu = NSMenu(title: String(localized: "statusbar.open_recent", defaultValue: "Open recent"))
        recentMenu.delegate = self
        recentFilesMenu = recentMenu

        let mainMenu = NSMenu()
        mainMenu.addItem(builder.buildAppMenuItem())
        mainMenu.addItem(builder.buildFileMenuItem(recentFilesMenu: recentMenu))
        mainMenu.addItem(builder.buildEditMenuItem())
        mainMenu.addItem(builder.buildViewMenuItem())
        mainMenu.addItem(builder.buildHelpMenuItem())
        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu actions

    @objc private func showItsypad() {
        toggleWindow()
    }

    #if !APPSTORE
    @objc func checkForUpdates() {
        UpdateChecker.check()
    }
    #endif

    @objc private func quitApp() {
        TabStore.shared.saveSession()
        NSApp.terminate(nil)
    }

    @objc func newTabAction() {
        editorCoordinator?.newTab()
    }

    @objc func openFileAction() {
        editorCoordinator?.openFile()
    }

    @objc func saveFileAction() {
        editorCoordinator?.saveFile()
    }

    @objc func saveFileAsAction() {
        editorCoordinator?.saveFileAs()
    }

    // MARK: - Autosave

    /// Autosave triggers: every minute, and whenever the editor window gains or loses key
    /// focus (i.e. you switch to or from Itsy). Closing a tab autosaves via confirmCloseTab.
    private func setupAutosave() {
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autosaveAll() }
        }
        let nc = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification] {
            let obs = nc.addObserver(forName: name, object: editorWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.autosaveAll() }
            }
            windowKeyObservers.append(obs)
        }
    }

    private func autosaveAll() {
        editorCoordinator?.saveActiveTabCursor()
        TabStore.shared.saveAll()
    }

    @objc func findAction(_ sender: NSMenuItem) {
        guard let textView = editorCoordinator?.activeTextView() else { return }

        // Cmd+F toggles the in-tab find bar: close it if it's already showing.
        if sender.tag == Int(NSTextFinder.Action.showFindInterface.rawValue),
           textView.enclosingScrollView?.isFindBarVisible == true {
            let hideItem = NSMenuItem()
            hideItem.tag = Int(NSTextFinder.Action.hideFindInterface.rawValue)
            textView.performFindPanelAction(hideItem)
            return
        }

        textView.performFindPanelAction(sender)
    }

    @objc func toggleChecklistAction() {
        editorCoordinator?.activeTextView()?.toggleChecklist()
    }

    @objc func moveLineUpAction() {
        editorCoordinator?.activeTextView()?.moveLine(.up)
    }

    @objc func moveLineDownAction() {
        editorCoordinator?.activeTextView()?.moveLine(.down)
    }

    @objc func closeTabAction() {
        editorCoordinator?.closeCurrentTab()
    }

    @objc func nextTabAction() {
        editorCoordinator?.selectNextTab()
    }

    @objc func previousTabAction() {
        editorCoordinator?.selectPreviousTab()
    }

    private func installTabSwitchMonitor() {
        tabSwitchMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let window = event.window,
                  window === self.editorWindow else { return event }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // ⌃Tab / ⌃⇧Tab
            if event.keyCode == 48, flags.contains(.control) {
                if flags.contains(.shift) {
                    self.editorCoordinator?.selectPreviousTab()
                } else {
                    self.editorCoordinator?.selectNextTab()
                }
                return nil
            }

            // ⌃D – close the current tab (it autosaves first). Overrides the emacs
            // delete-forward binding inside the text view.
            if flags == [.control], event.charactersIgnoringModifiers == "d" {
                self.editorCoordinator?.closeCurrentTab()
                return nil
            }

            // ⇧⌘] / ⇧⌘[ – matches Safari and iTerm. Handled here rather than relying on the
            // menu key-equivalent, which matches unreliably for shifted punctuation
            // (Shift turns "]" into "}"). charactersIgnoringModifiers keeps Shift applied,
            // so we match on "}"/"{" directly. Local monitors run before key-equivalent
            // dispatch, so returning nil prevents the menu item from also firing.
            if flags.contains(.command), flags.contains(.shift),
               !flags.contains(.control), !flags.contains(.option) {
                switch event.charactersIgnoringModifiers {
                case "}":
                    self.editorCoordinator?.selectNextTab()
                    return nil
                case "{":
                    self.editorCoordinator?.selectPreviousTab()
                    return nil
                // ikjl as arrow keys: move the insertion point in the focused text view.
                case "I":
                    return NSApp.sendAction(#selector(NSResponder.moveUp(_:)), to: nil, from: nil) ? nil : event
                case "K":
                    return NSApp.sendAction(#selector(NSResponder.moveDown(_:)), to: nil, from: nil) ? nil : event
                case "J":
                    return NSApp.sendAction(#selector(NSResponder.moveLeft(_:)), to: nil, from: nil) ? nil : event
                case "L":
                    return NSApp.sendAction(#selector(NSResponder.moveRight(_:)), to: nil, from: nil) ? nil : event
                // Split panes (shifted punctuation matched here for reliability).
                case "|":
                    self.editorCoordinator?.splitRight()
                    return nil
                case "_":
                    self.editorCoordinator?.splitDown()
                    return nil
                default:
                    break
                }
            }

            return event
        }
    }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        editorCoordinator?.selectTab(atIndex: sender.tag - 1)
    }

    @objc func splitRight() {
        editorCoordinator?.splitRight()
    }

    @objc func splitDown() {
        editorCoordinator?.splitDown()
    }

    @objc func increaseFontSize() {
        SettingsStore.shared.editorFontSize = min(36, SettingsStore.shared.editorFontSize + 1)
    }

    @objc func decreaseFontSize() {
        SettingsStore.shared.editorFontSize = max(8, SettingsStore.shared.editorFontSize - 1)
    }

    @objc func resetFontSize() {
        SettingsStore.shared.editorFontSize = 14
    }

    @objc func toggleLineNumbers() {
        SettingsStore.shared.showLineNumbers.toggle()
    }

    @objc func toggleWordWrap() {
        SettingsStore.shared.wordWrap.toggle()
    }

    @objc func togglePin() {
        // The HUD overlay is always at .floating so it can sit over full-screen apps; keep
        // it floating regardless of the toggle. (isPinned is still tracked/persisted.)
        isPinned.toggle()
        editorWindow?.level = .floating
    }

    @objc func togglePreviewAction() {
        editorCoordinator?.togglePreview()
    }

    @objc func toggleFileBrowser() {
        fileBrowserSplitVC?.toggleSidebar()
    }

    @objc func openFolderInSidebar() {
        fileBrowserSplitVC?.openFolder()
    }

    @objc func openHelpURL(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String,
              let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func currentSelectedTabID() -> TabID? {
        guard let focusedPaneId = editorCoordinator?.controller.focusedPaneId else { return nil }
        return editorCoordinator?.controller.selectedTab(inPane: focusedPaneId)?.id
    }

    private func updateMarkdownToolbarItem(isMarkdown: Bool, isPreviewing: Bool) {
        // HUD mode has no toolbar; just track markdown state for menu validation.
        showMarkdownPreview = isMarkdown
    }

    private func buildTabSwitcherMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    private func updateTabSwitcherMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        // NSMenuToolbarItem hides the first item; add a dummy so all tabs show
        let dummy = NSMenuItem(title: String(localized: "toolbar.tabs", defaultValue: "Tabs"), action: nil, keyEquivalent: "")
        dummy.isHidden = true
        menu.addItem(dummy)
        guard let coordinator = editorCoordinator else { return }
        for entry in coordinator.tabListForMenu() {
            let item = NSMenuItem(title: entry.title, action: #selector(switchToTab(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.tabID
            item.state = entry.isSelected ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func switchToTab(_ sender: NSMenuItem) {
        guard let tabID = sender.representedObject as? TabID else { return }
        editorCoordinator?.controller.selectTab(tabID)
    }

    @objc func globalSearchAction() {
        guard let window = editorWindow else { return }
        if !window.isVisible {
            windowWasVisible = true
            window.orderFrontRegardless()
            window.makeKey()
            updateDockVisibility()
        }

        let controller: GlobalSearchController
        if let existing = globalSearchController {
            controller = existing
        } else {
            controller = GlobalSearchController()
            controller.tabsProvider = {
                TabStore.shared.tabs.map { GlobalSearch.Source(id: $0.id, name: $0.name, content: $0.content) }
            }
            controller.onReveal = { [weak self] tabID, range in
                self?.editorCoordinator?.revealMatch(tabStoreID: tabID, range: range)
            }
            globalSearchController = controller
        }
        controller.toggle(over: window)
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Tab switcher menu — rebuild dynamically each time it opens
        if let toolbarItem = editorWindow?.toolbar?.items.first(where: { $0.itemIdentifier == .tabSwitcher }) as? NSMenuToolbarItem,
           menu === toolbarItem.menu {
            updateTabSwitcherMenu(menu)
            return
        }

        guard menu === recentFilesMenu else { return }
        menu.removeAllItems()

        let recentURLs = NSDocumentController.shared.recentDocumentURLs
        if recentURLs.isEmpty {
            let emptyItem = NSMenuItem(title: String(localized: "statusbar.no_recent_files", defaultValue: "No recent files"), action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
            return
        }

        for url in recentURLs {
            let item = NSMenuItem(title: url.path, action: #selector(openRecentFile(_:)), keyEquivalent: "")
            item.target = self
            item.toolTip = url.path
            item.representedObject = url
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let clearItem = NSMenuItem(title: String(localized: "statusbar.clear_menu", defaultValue: "Clear menu"), action: #selector(clearRecentFiles), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)
    }

    @objc private func openRecentFile(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        showWindowAndOpen(url: url)
    }

    @objc private func clearRecentFiles() {
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    private static func characterForKeyCode(_ keyCode: UInt16) -> String? {
        let map: [UInt16: String] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
            8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
            16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l",
            38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "n", 46: "m", 47: ".",
        ]
        return map[keyCode]
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleLineNumbers) {
            menuItem.state = SettingsStore.shared.showLineNumbers ? .on : .off
        }
        if menuItem.action == #selector(toggleWordWrap) {
            menuItem.state = SettingsStore.shared.wordWrap ? .on : .off
        }
        if menuItem.action == #selector(togglePin) {
            menuItem.state = isPinned ? .on : .off
        }
        if menuItem.action == #selector(toggleFileBrowser) {
            menuItem.state = fileBrowserSplitVC?.isSidebarVisible == true ? .on : .off
        }
        if menuItem.action == #selector(togglePreviewAction) {
            let isMarkdown = editorCoordinator?.isCurrentTabMarkdown ?? false
            if isMarkdown, let tabID = currentSelectedTabID() {
                menuItem.state = editorCoordinator?.isPreviewActive(for: tabID) ?? false ? .on : .off
            } else {
                menuItem.state = .off
            }
            return isMarkdown
        }
        return true
    }

}
