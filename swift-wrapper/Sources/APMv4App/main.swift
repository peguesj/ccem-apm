import AppKit
import WebKit

// MARK: - Constants

private let kAppName = "CCEM APM v4"
private let kServerURL = "http://localhost:3031"
private let kDefaultWidth: CGFloat = 1200
private let kDefaultHeight: CGFloat = 800
private let kWindowFrameKey = "MainWindowFrame"

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var errorView: NSView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupWindow()
        setupWebView()
        setupErrorView()
        setupMenuBar()
        loadDashboard()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveWindowFrame()
    }

    // MARK: - Window Setup

    private func setupWindow() {
        let frame = restoreWindowFrame() ?? NSRect(
            x: 0, y: 0,
            width: kDefaultWidth,
            height: kDefaultHeight
        )

        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = kAppName
        window.minSize = NSSize(width: 800, height: 600)
        window.delegate = self

        if restoreWindowFrame() == nil {
            window.center()
        }

        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - WebView Setup

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        window.contentView!.addSubview(webView)
    }

    // MARK: - Error View Setup

    private func setupErrorView() {
        errorView = NSView(frame: window.contentView!.bounds)
        errorView.autoresizingMask = [.width, .height]
        errorView.wantsLayer = true
        errorView.layer?.backgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0).cgColor
        errorView.isHidden = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSTextField(labelWithString: "⚠")
        icon.font = NSFont.systemFont(ofSize: 48)
        icon.alignment = .center

        let title = NSTextField(labelWithString: "Cannot Connect to APM Server")
        title.font = NSFont.boldSystemFont(ofSize: 18)
        title.textColor = .white
        title.alignment = .center

        let message = NSTextField(labelWithString: "The APM server at \(kServerURL) is not reachable.\nStart it with: cd ~/Developer/ccem/apm-v4 && mix phx.server")
        message.font = NSFont.systemFont(ofSize: 13)
        message.textColor = .secondaryLabelColor
        message.alignment = .center
        message.maximumNumberOfLines = 3

        let retryButton = NSButton(title: "Retry Connection", target: self, action: #selector(loadDashboard))
        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .large

        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(message)
        stack.addArrangedSubview(retryButton)

        errorView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: errorView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: errorView.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: errorView.widthAnchor, multiplier: 0.8)
        ])

        window.contentView!.addSubview(errorView)
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(kAppName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(kAppName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // View menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")

        let reloadItem = NSMenuItem(title: "Reload", action: #selector(loadDashboard), keyEquivalent: "r")
        viewMenu.addItem(reloadItem)

        let openInBrowserItem = NSMenuItem(title: "Open in Browser", action: #selector(openInBrowser), keyEquivalent: "B")
        openInBrowserItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(openInBrowserItem)

        viewMenu.addItem(.separator())

        let toggleFullScreen = NSMenuItem(title: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        toggleFullScreen.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(toggleFullScreen)

        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApplication.shared.mainMenu = mainMenu
        NSApplication.shared.windowsMenu = windowMenu
    }

    // MARK: - Actions

    @objc func loadDashboard() {
        errorView.isHidden = true
        webView.isHidden = false
        let url = URL(string: kServerURL)!
        webView.load(URLRequest(url: url))
    }

    @objc private func openInBrowser() {
        NSWorkspace.shared.open(URL(string: kServerURL)!)
    }

    private func showErrorView() {
        webView.isHidden = true
        errorView.isHidden = false
    }

    // MARK: - Window Frame Persistence

    private func saveWindowFrame() {
        let frame = window.frame
        let frameString = NSStringFromRect(frame)
        UserDefaults.standard.set(frameString, forKey: kWindowFrameKey)
    }

    private func restoreWindowFrame() -> NSRect? {
        guard let frameString = UserDefaults.standard.string(forKey: kWindowFrameKey) else {
            return nil
        }
        let frame = NSRectFromString(frameString)
        guard frame.width > 0 && frame.height > 0 else { return nil }
        return frame
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    func windowDidResize(_ notification: Notification) {
        saveWindowFrame()
    }

    func windowDidMove(_ notification: Notification) {
        saveWindowFrame()
    }
}

// MARK: - WKNavigationDelegate

extension AppDelegate: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showErrorView()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showErrorView()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        errorView.isHidden = true
        webView.isHidden = false
    }
}

// MARK: - Application Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
