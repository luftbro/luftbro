import Foundation

/// Keeps the Mac awake while it streams. The Apple TV fetches every segment
/// from this Mac, and nobody touches the Mac while watching the TV, so macOS
/// would idle-sleep it mid-film (display off, "Idle Sleep" five seconds later)
/// and lose the AirPlay connection. For the TV the display may still turn off;
/// on This Mac the film is on this screen, so the display stays on too, which
/// also keeps the screensaver away (AVPlayer holds no such assertion here).
/// A screen Luftbro has darkened (ScreenDimmer) stays awake too, so the keys
/// reach Luftbro instead of waking it. A paused film lets the Mac sleep, and
/// closing the lid still sleeps it.
@MainActor
final class SleepGuard {
    static let shared = SleepGuard()
    private var activity: NSObjectProtocol?
    private var keepsDisplayOn = false
    private var streaming = false
    private var onThisMac = false

    /// Again with the last state, when the screen is darkened or comes back.
    func refresh() { update(streaming: streaming, onThisMac: onThisMac) }

    func update(streaming: Bool, onThisMac: Bool) {
        self.streaming = streaming
        self.onThisMac = onThisMac
        let display = streaming && (onThisMac || ScreenDimmer.shared.isDark)
        if let a = activity, !streaming || display != keepsDisplayOn {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
        if streaming, activity == nil {
            // .userInitiated includes .idleSystemSleepDisabled (not display sleep) and keeps App Nap off.
            activity = ProcessInfo.processInfo.beginActivity(
                options: display ? [.userInitiated, .idleDisplaySleepDisabled] : .userInitiated,
                reason: !display ? "Streaming video to an Apple TV"
                    : onThisMac ? "Playing video on this Mac" : "Keeping the darkened screen awake for the playback keys")
        }
        keepsDisplayOn = display
    }
}
