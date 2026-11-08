import AppKit
import CoreGraphics
import SwiftUI

/// The Mac's screen goes dark while a film plays on the TV: nobody watches
/// it, and in a dark room it glows. ScreenDimmer darkens it without putting
/// it to sleep, so the playback keys keep working in the dark; the mouse
/// brings it back with the remote on it. On This Mac the film is on this
/// screen, so it stays lit.
extension AppModel {
    static let darkScreenKey = "darkenScreenWhileStreaming"
    /// Long enough to read the notice, and to move the mouse if the Mac is
    /// still wanted.
    static let darkScreenDelay = 2.5
    /// Lit again during a film (the mouse, another key) and then left alone
    /// this long with Luftbro in front: dark again. In another app the Mac is
    /// being used, also while nobody touches it (reading, say).
    static let idleDarkDelay = 15.0

    /// Plays on another device: an Apple TV, or the development simulator
    /// standing in for one.
    var streamsElsewhere: Bool { hasSession && !playsOnThisMac }

    /// The playback the darkening belongs to: this file on this device, so a
    /// restart for another audio or subtitle track doesn't offer it again.
    var darkScreenPlayback: String? {
        guard let s = live?.session, let path = s.file?.path else { return nil }
        return path + "\n" + (s.device?.id ?? "")
    }

    /// When a playback first plays, and each time it is resumed (Play means
    /// watching again): a notice, then the screen goes dark unless the Mac
    /// was used meanwhile, or playback paused or stopped. Lit again later, the
    /// same once the Mac is left alone (idleDarkDelay). Runs with every state
    /// update, once a second while a film plays.
    func followDarkScreen(_ phase: Phase, from previous: Phase) {
        // Moved to This Mac: the film is on this screen now.
        if ScreenDimmer.shared.isDark, playsOnThisMac { ScreenDimmer.shared.restore() }
        // Snapshot runs never darken, so the offer and its notice would only repeat.
        guard !Self.offStage, let playback = darkScreenPlayback else { return }
        if phase != .playing {
            if darkScreenTask != nil, !phase.isActive || phase == .paused { cancelDarkScreen() }
            return
        }
        guard streamsElsewhere, UserDefaults.standard.bool(forKey: Self.darkScreenKey) else {
            darkScreenOffered = playback
            return
        }
        if playback != darkScreenOffered {
            darkScreenOffered = playback
            scheduleDarkScreen(after: Self.darkScreenDelay, unlessUsed: true)
        } else if previous == .paused, darkScreenTask == nil, !ScreenDimmer.shared.isDark {
            scheduleDarkScreen(after: Self.darkScreenDelay, unlessUsed: true)
        } else if darkScreenTask == nil, !ScreenDimmer.shared.isDark, NSApp.isActive,
                  Self.secondsSinceInput() >= Self.idleDarkDelay {
            scheduleDarkScreen(after: Self.darkScreenDelay, unlessUsed: true)
        }
    }

    /// The switch flipped. In the player and the Playback menu, mid-film, it
    /// acts at once: on darkens the screen, off brings it back. In Settings
    /// it is a preference: on waits for the next film.
    func darkScreenChanged(_ on: Bool, now: Bool) {
        guard on else {
            cancelDarkScreen()
            ScreenDimmer.shared.restore()
            return
        }
        guard now, streamsElsewhere, canControl else { return }
        darkScreenOffered = darkScreenPlayback
        scheduleDarkScreen(after: 1, unlessUsed: false)
    }

    private func scheduleDarkScreen(after delay: Double, unlessUsed: Bool) {
        cancelDarkScreen()
        let playback = darkScreenPlayback
        showStatusHint("Darkening the screen…", symbol: "display", seconds: delay)
        darkScreenTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.darkScreenTask = nil
            guard self.darkScreenPlayback == playback, self.streamsElsewhere, self.canControl else { return }
            // The automatic one is for a film that plays and a Mac left alone.
            // The press that started it (Play, its key coming up) is not "used":
            // only input after the notice's first moment counts.
            if unlessUsed && (self.phase == .paused || Self.secondsSinceInput() < delay - 0.5) { return }
            if !Self.offStage { ScreenDimmer.shared.darken() }
        }
    }

    func cancelDarkScreen() {
        guard let task = darkScreenTask else { return }
        task.cancel()
        darkScreenTask = nil
        if statusHint?.symbol == "display" { statusHint = nil }
    }

    /// Playback is over: the next one is offered again. A dark screen stays
    /// dark (whoever watched may have gone) until the Mac is used.
    func endDarkScreen() {
        cancelDarkScreen()
        darkScreenOffered = nil
    }

    /// Mouse, trackpad or keyboard, anywhere on the Mac.
    private static func secondsSinceInput() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Scripted snapshot runs leave the screen of the Mac they run on alone.
    private static let offStage = ProcessInfo.processInfo.environment["LUFTBRO_SNAPSHOT_DIR"] != nil
}

/// Beside the sleep timer while playing on a TV: the same setting as in the
/// Playback menu and Settings, as a switch, so whether it is on is never in
/// doubt. Few apps do this, so an info button says what it does.
struct DarkScreenSwitch: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppModel.darkScreenKey) private var darkScreen = true
    @State private var explaining = false

    var body: some View {
        HStack(spacing: 6) {
            Text("Darken Mac screen")
                .font(.callout)
                .foregroundStyle(.secondary)
            // Shown while the pointer is on it, at once, and gone when it
            // leaves: never left open over the remote, nor in the way of the keys.
            Image(systemName: "info.circle")
                .font(.callout)
                .foregroundStyle(explaining ? .primary : .secondary)
                .contentShape(Rectangle())
                .onHover { explaining = $0 }
                .popover(isPresented: Binding(get: { explaining || model.darkScreenExplainerShown },
                                              set: { if !$0 { explaining = false; model.darkScreenExplainerShown = false } }),
                         arrowEdge: .bottom) { DarkScreenExplainer() }
                .accessibilityLabel("About darkening the Mac screen")
                .accessibilityHint(DarkScreenExplainer.spoken)
            Toggle("Darken Mac screen", isOn: Binding(get: { darkScreen }, set: { set($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .keyFocus(.darkScreen, radius: 8) { set(!darkScreen) }
        }
        .fixedSize()
        .disabled(!model.canControl)
    }

    private func set(_ on: Bool) {
        darkScreen = on
        model.darkScreenChanged(on, now: true)
    }
}

private struct DarkScreenExplainer: View {
    static let lines = [
        "While a film plays on the TV, the Mac's screen goes dark a couple of seconds after it starts, so it doesn't light up the room. The film keeps playing.",
        "Space, the arrow keys and the media keys still work, and the screen stays dark. Move the mouse to bring it back. Press Play, or leave the Mac alone for 15 seconds with Luftbro in front, and it goes dark again.",
        "Switched off, the screen dims and turns off as your Mac's own settings say.",
    ]
    static let shortcut = "⇧⌘D switches it from anywhere in Luftbro."
    static var spoken: String { (lines + [shortcut]).joined(separator: " ") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Darken Mac screen").font(.headline)
            ForEach(Self.lines, id: \.self) { Text($0) }
            Text(Self.shortcut).foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 280, alignment: .leading)
        .padding(14)
    }
}
