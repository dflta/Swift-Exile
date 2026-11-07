import AppKit
import ApplicationServices
import SwiftExileCore

/// Finds the game window by title and follows it with AX notifications (plan §2.2).
/// Replaces electron-overlay-window's `mac.mm`, without its 0.2 s × 5 s polling loop.
@MainActor
final class GameWindowTracker {
    struct Snapshot: Equatable {
        var pid: pid_t
        var appName: String
        var title: String
        var geometry: GameWindowGeometry
        /// Drawable area in Cocoa coordinates, ready for `NSWindow.setFrame`.
        var contentRect: CGRect
        var flavor: GameFlavor
    }

    var windowTitle = "Path of Exile 2" {
        didSet {
            guard windowTitle != oldValue else { return }
            detach()
            scan()
        }
    }

    var onAttach: ((Snapshot) -> Void)?
    var onDetach: (() -> Void)?
    var onGeometryChange: ((Snapshot) -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    private(set) var current: Snapshot?
    private(set) var gameFrontmost = false

    private var appElement: AXUIElement?
    private var windowElement: AXUIElement?
    private var observer: AXObserver?
    private var settleItems: [DispatchWorkItem] = []
    private var tokens: [NSObjectProtocol] = []
    private var presentationObservation: NSKeyValueObservation?
    private let log: (String) -> Void
    /// Last event that may move or resize the game window, for time-to-correct measurements
    /// (go/no-go criterion G1). Cleared 2 s after it happened.
    private var lastTrigger: (name: String, at: Date)?

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        tokens.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { self?.handleAppActivation(pid: pid) }
        })
        tokens.append(workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRescans() }
        })
        tokens.append(workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, let pid, pid == self.current?.pid else { return }
                self.log("info [GameWindow] game process exited")
                self.detach()
            }
        })
        tokens.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.transitionHappened("Space change") }
        })
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.transitionHappened("display change") }
        })
        // Games (Wine included) often enter fullscreen by hiding the menu bar and Dock (mac.mm:586-592).
        presentationObservation = NSApp.observe(\.currentSystemPresentationOptions) { [weak self] _, _ in
            DispatchQueue.main.async { self?.transitionHappened("presentation options change") }
        }
        scan()
    }

    // MARK: Finding the window

    func scan() {
        guard current == nil else { return }
        let ownPid = ProcessInfo.processInfo.processIdentifier
        let candidates = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPid }
            .sorted { Self.likelihood($0) > Self.likelihood($1) }

        for app in candidates {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.25)
            guard let windows: [AXUIElement] = copyAttribute(element, kAXWindowsAttribute) else { continue }
            for window in windows where copyAttribute(window, kAXTitleAttribute) as String? == windowTitle {
                attach(app: app, appElement: element, window: window)
                return
            }
        }
    }

    /// Check likely owners first (plan §2.2): Wine `.exe` apps, NotProton wrappers, GGG apps.
    private static func likelihood(_ app: NSRunningApplication) -> Int {
        let name = app.localizedName ?? ""
        let bundleID = app.bundleIdentifier ?? ""
        if name.lowercased().hasSuffix(".exe") || bundleID.hasPrefix("com.GGG") { return 3 }
        if bundleID.hasPrefix("com.notproton.launcher.") || app.executableURL?.lastPathComponent.hasPrefix("wine") == true { return 2 }
        if name.contains("Path of Exile") { return 1 }
        return 0
    }

    private func attach(app: NSRunningApplication, appElement: AXUIElement, window: AXUIElement) {
        let pid = app.processIdentifier
        var newObserver: AXObserver?
        guard AXObserverCreate(pid, trackerCallback, &newObserver) == .success, let newObserver else {
            log("error [GameWindow] could not observe pid \(pid)")
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                     kAXApplicationActivatedNotification, kAXApplicationDeactivatedNotification,
                     kAXApplicationHiddenNotification, kAXApplicationShownNotification] {
            AXObserverAddNotification(newObserver, appElement, name as CFString, refcon)
        }
        for name in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification,
                     kAXTitleChangedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            AXObserverAddNotification(newObserver, window, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .defaultMode)

        self.observer = newObserver
        self.appElement = appElement
        self.windowElement = window

        guard let geometry = readGeometry(window) else {
            log("error [GameWindow] found the window but could not read its frame")
            detach()
            return
        }
        let flavor = GameFlavor.detect(bundleID: app.bundleIdentifier, processArguments: ProcessArguments.read(pid: pid))
        let snapshot = Snapshot(
            pid: pid,
            appName: app.localizedName ?? "pid \(pid)",
            title: windowTitle,
            geometry: geometry,
            contentRect: cocoaContentRect(geometry),
            flavor: flavor
        )
        current = snapshot
        log("info [GameWindow] attached to \"\(snapshot.title)\" (\(snapshot.appName), pid \(pid), \(flavor.displayName))")
        log("info [GameWindow] window \(Self.describe(geometry.frame)), titled \(geometry.isTitled), native fullscreen \(geometry.isNativeFullScreen) → overlay \(Self.describe(quartzContentRect(geometry)))")
        if case .wine(let prefix, let installDir) = flavor {
            log("info [GameWindow] Wine prefix \(prefix ?? "?"), install dir \(installDir ?? "?")")
        }
        onAttach?(snapshot)
        reportFocus()
        settle()
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        appElement = nil
        windowElement = nil
        settleItems.forEach { $0.cancel() }
        settleItems = []
        let wasAttached = current != nil
        current = nil
        gameFrontmost = false
        if wasAttached { onDetach?() }
    }

    // MARK: Events

    fileprivate func handle(notification: String) {
        switch notification {
        case kAXMovedNotification, kAXResizedNotification:
            if lastTrigger == nil { markTrigger(notification == kAXMovedNotification ? "window moved" : "window resized") }
            refreshGeometry()
        case kAXUIElementDestroyedNotification:
            log("info [GameWindow] window closed")
            detach()
            scheduleRescans()
        case kAXTitleChangedNotification:
            if let window = windowElement, copyAttribute(window, kAXTitleAttribute) as String? != windowTitle {
                log("info [GameWindow] title changed, re-scanning")
                detach()
                scan()
            }
        default:
            reportFocus()
            refreshGeometry()
        }
    }

    /// Pid from the latest activation notification. `NSWorkspace.frontmostApplication` lags behind
    /// that notification (measured: ~500 ms after a Space switch back), so prefer this right after it.
    private var activated: (pid: pid_t, at: Date)?

    private func handleAppActivation(pid: pid_t?) {
        if let pid { activated = (pid, Date()) }
        if current == nil {
            scan()
        } else {
            markTrigger("app activation")
            reportFocus()
            settle()
        }
    }

    /// Space change, display change, or presentation options change.
    private func transitionHappened(_ trigger: String) {
        guard current != nil else { return }
        markTrigger(trigger)
        refreshGeometry()
        reportFocus()
        settle()
    }

    /// Bounded settle re-reads instead of the library's 25 polls (plan §2.2): at most three
    /// one-shot reads after a transition, cancelled and restarted on every new trigger.
    private func settle() {
        settleItems.forEach { $0.cancel() }
        settleItems = [0.15, 0.5, 1.2].map { delay in
            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.refreshGeometry()
                    self?.reportFocus()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return item
        }
    }

    /// The game may need a moment after launch before its window exists.
    private func scheduleRescans() {
        for delay in [1.0, 3.0, 8.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.scan() }
            }
        }
    }

    private func markTrigger(_ name: String) {
        let at = Date()
        lastTrigger = (name, at)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                if self?.lastTrigger?.at == at { self?.lastTrigger = nil }
            }
        }
    }

    func refreshGeometry() {
        guard var snapshot = current, let window = windowElement, let geometry = readGeometry(window) else { return }
        let contentRect = cocoaContentRect(geometry)
        guard geometry != snapshot.geometry || contentRect != snapshot.contentRect else { return }
        snapshot.geometry = geometry
        snapshot.contentRect = contentRect
        current = snapshot
        let timing = lastTrigger.map { " \(Int(Date().timeIntervalSince($0.at) * 1000)) ms after \($0.name)" } ?? ""
        log("debug [GameWindow] geometry changed\(timing): window \(Self.describe(geometry.frame)), titled \(geometry.isTitled), native fullscreen \(geometry.isNativeFullScreen) → overlay \(Self.describe(quartzContentRect(geometry)))")
        onGeometryChange?(snapshot)
    }

    private func reportFocus() {
        guard let snapshot = current else { return }
        let frontmostPid: pid_t?
        if let activated, Date().timeIntervalSince(activated.at) < 1 {
            frontmostPid = activated.pid
        } else {
            frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        var focused = frontmostPid == snapshot.pid
        if focused, let app = appElement, let window = windowElement,
           let focusedWindow: AXUIElement = copyAttribute(app, kAXFocusedWindowAttribute) {
            focused = CFEqual(focusedWindow, window)
        }
        if let window = windowElement, (copyAttribute(window, kAXMinimizedAttribute) as Bool?) == true {
            focused = false
        }
        guard focused != gameFrontmost else { return }
        gameFrontmost = focused
        onFocusChange?(focused)
    }

    // MARK: AX helpers

    private func readGeometry(_ window: AXUIElement) -> GameWindowGeometry? {
        guard let positionValue: AXValue = copyAttribute(window, kAXPositionAttribute),
              let sizeValue: AXValue = copyAttribute(window, kAXSizeAttribute)
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue, .cgPoint, &position)
        AXValueGetValue(sizeValue, .cgSize, &size)
        let closeButton: AXUIElement? = copyAttribute(window, kAXCloseButtonAttribute)
        let fullScreen: Bool = copyAttribute(window, "AXFullScreen") ?? false
        return GameWindowGeometry(
            frame: CGRect(origin: position, size: size),
            isTitled: closeButton != nil,
            isNativeFullScreen: fullScreen
        )
    }

    /// Overlay area in screen coordinates with the origin at the top-left of the main display
    /// (same space as AX window frames), used for logs.
    private func quartzContentRect(_ geometry: GameWindowGeometry) -> CGRect {
        let probe = NSRect(x: 0, y: 0, width: 400, height: 400)
        let titleBarHeight = NSWindow.frameRect(forContentRect: probe, styleMask: [.titled]).height - probe.height
        return geometry.contentRect(titleBarHeight: titleBarHeight)
    }

    /// Overlay area in AppKit coordinates (origin bottom-left of the main display), for `setFrame`.
    private func cocoaContentRect(_ geometry: GameWindowGeometry) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return ScreenCoordinates.cocoaRect(fromQuartz: quartzContentRect(geometry), primaryHeight: primaryHeight)
    }

    private func copyAttribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func describe(_ rect: CGRect) -> String {
        "(\(Int(rect.minX)), \(Int(rect.minY)), \(Int(rect.width))×\(Int(rect.height)))"
    }
}

/// AX observer callback. AX delivers on the run loop we added the source to (main).
private func trackerCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let tracker = Unmanaged<GameWindowTracker>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated {
        tracker.handle(notification: name)
    }
}
