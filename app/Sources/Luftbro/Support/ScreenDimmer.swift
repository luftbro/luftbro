import AppKit
import CoreGraphics

/// Darkens the screens without putting them to sleep. A sleeping screen
/// swallows the key that wakes it, so Space would take two presses; a dark
/// one that stays awake hands every key to Luftbro and stays dark.
///
/// Dark is a black picture (the screens' colour tables, which macOS restores
/// by itself when Luftbro quits) and the built-in screen's backlight at zero,
/// which is what saves the power. The backlight goes through DisplayServices,
/// the private framework behind the brightness keys; without it the picture
/// is still black. A helper process puts the brightness back should Luftbro
/// end while the screen is dark.
///
/// The mouse, a click or a key other than the playback keys (while Luftbro is
/// in front) brings the screens back, and so does the Mac waking from sleep.
@MainActor
final class ScreenDimmer {
    static let shared = ScreenDimmer()
    private(set) var isDark = false
    /// Called when the screens come back.
    var onRestore: (() -> Void)?

    private var savedBrightness: [CGDirectDisplayID: Float] = [:]
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var movedWindows: [NSWindow] = []
    private var watcher: Process?

    /// Keys that work in the dark (Space, the arrows with or without ⌘,
    /// H / J, M): pressing them keeps it dark. Media keys aren't key events.
    private static let playbackKeys: Set<UInt16> = [49, 123, 124, 125, 126, 4, 38, 46]

    func darken() {
        guard !isDark else { return }
        isDark = true
        for d in Self.onlineDisplays() {
            if let b = Brightness.get(d) {
                savedBrightness[d] = b
                Brightness.set(d, 0)
            }
            CGSetDisplayTransferByFormula(d, 0, 0, 1, 0, 0, 1, 0, 0, 1)
        }
        startWatcher()
        watchForReturn()
        SleepGuard.shared.refresh()
    }

    func restore() {
        guard isDark else { return }
        isDark = false
        CGDisplayRestoreColorSyncSettings()
        for (d, b) in savedBrightness { Brightness.set(d, b) }
        savedBrightness = [:]
        stopWatching()
        watcher?.terminate()
        watcher = nil
        SleepGuard.shared.refresh()
        onRestore?()
    }

    private func watchForReturn() {
        let mouse: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                            .leftMouseDragged, .scrollWheel]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mouse, handler: { _ in
            MainActor.assumeIsolated { ScreenDimmer.shared.restore() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mouse, handler: { event in
            let type = event.type
            let swallow = MainActor.assumeIsolated { () -> Bool in
                let dimmer = ScreenDimmer.shared
                guard dimmer.isDark else { return false }
                dimmer.restore()
                // A click made in the dark only brings the screen back: it
                // would land on whatever happens to be under the pointer.
                return [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type)
            }
            return swallow ? nil : event
        }) { monitors.append(m) }
        // The pointer moving over Luftbro's own windows reaches the local
        // monitor only from windows that take mouse-moved events.
        for w in NSApp.windows where w.isVisible && !w.acceptsMouseMovedEvents {
            w.acceptsMouseMovedEvents = true
            movedWindows.append(w)
        }
        // After sleep the screens wake with their own colours and brightness.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ScreenDimmer.shared.restore() }
            })
        }
    }

    /// Every key pressed in Luftbro, from its key monitor (AppDelegate), before
    /// anything handles it: only the playback keys keep the screen dark.
    func keyPressed(_ keyCode: UInt16) {
        guard isDark, !Self.playbackKeys.contains(keyCode) else { return }
        restore()
    }

    private func stopWatching() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
        movedWindows.forEach { $0.acceptsMouseMovedEvents = false }
        movedWindows = []
    }

    // MARK: - Brightness helper

    nonisolated private static let watcherFlag = "--restore-brightness-after"

    /// This same executable, waiting for Luftbro to end: it then sets the
    /// brightness back and exits. Ended by `restore()` once it isn't needed.
    private func startWatcher() {
        guard !savedBrightness.isEmpty, let exe = Bundle.main.executablePath else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = [Self.watcherFlag, String(ProcessInfo.processInfo.processIdentifier)]
            + savedBrightness.map { "\($0.key)=\($0.value)" }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            watcher = p
        } catch {
            watcher = nil
        }
    }

    /// The helper's side, run before any UI: true when this process is the helper.
    nonisolated static func runWatcherIfAsked() -> Bool {
        let args = CommandLine.arguments
        guard args.count >= 3, args[1] == watcherFlag, let pid = Int32(args[2]) else { return false }
        let levels = args.dropFirst(3).compactMap { arg -> (CGDirectDisplayID, Float)? in
            let parts = arg.split(separator: "=")
            guard parts.count == 2, let d = UInt32(parts[0]), let b = Float(parts[1]) else { return nil }
            return (d, b)
        }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        let putBack = {
            for (d, b) in levels { Brightness.set(d, b) }
            exit(0)
        }
        source.setEventHandler(handler: putBack)
        source.resume()
        // Already gone before the source was set up.
        if kill(pid, 0) != 0 { putBack() }
        dispatchMain()
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}

/// The built-in screen's brightness (0…1), through DisplayServices. nil where
/// it isn't available (external screens, a macOS without it).
private enum Brightness {
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32

    private static let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

    static func get(_ display: CGDirectDisplayID) -> Float? {
        guard let library, let sym = dlsym(library, "DisplayServicesGetBrightness") else { return nil }
        var value: Float = 0
        guard unsafeBitCast(sym, to: GetFn.self)(display, &value) == 0 else { return nil }
        return value
    }

    @discardableResult
    static func set(_ display: CGDirectDisplayID, _ value: Float) -> Bool {
        guard let library, let sym = dlsym(library, "DisplayServicesSetBrightness") else { return false }
        return unsafeBitCast(sym, to: SetFn.self)(display, value) == 0
    }
}
