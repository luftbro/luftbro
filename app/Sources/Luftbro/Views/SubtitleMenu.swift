import SwiftUI

/// What the subtitle menu shows, taken from the model when the menu is built.
/// The menu reads only this, not the model: the model changes every second
/// while something plays, and a menu that redraws closes its open Delay
/// submenu. So it redraws only when one of these changes.
struct SubtitleMenuState: Hashable {
    var path: String
    var trackIDs: [Int]
    var selected: Int
    var delay: Double
    var scale: Double
    var syncWorking: Bool
    var syncApplies: Bool
}

extension AppModel {
    func subtitleMenuState(_ probe: ProbeResult, inPlayer: Bool) -> SubtitleMenuState {
        SubtitleMenuState(path: probe.path, trackIDs: probe.subtitleTracks.map(\.id),
                          selected: inPlayer ? sessionSubtitleID : subtitleID,
                          delay: shownSubtitleDelay, scale: shownSubtitleScale,
                          syncWorking: subtitleSyncWorking, syncApplies: subtitleSyncApplies)
    }
}

/// The subtitle menu's content, shared by the ready view, the player and the
/// This Mac window: the Delay submenu first (also shows a stretch Sync
/// Automatically has applied), where a long list of tracks can't push it out
/// of sight, then the tracks (picture subtitles marked "shown as text" when
/// they are read with OCR).
struct SubtitleMenuContent: View {
    @Environment(AppModel.self) private var model
    let probe: ProbeResult
    /// In the player a change restarts the stream at the current position.
    let inPlayer: Bool
    let state: SubtitleMenuState

    var body: some View {
        // One pick is one restart; H / J (Playback menu) nudge by half a second.
        let delay = state.delay
        let scale = state.scale
        Menu("Delay: \(Self.delayText(delay))") {
            // The backend listens to a few minutes of the audio and sets the
            // delay to where the subtitles fit the speech (stretching them too
            // when they drift); while it does, the item says so (and nothing
            // else on screen changes).
            Button(state.syncWorking ? "Syncing…" : "Sync Automatically") {
                model.syncSubtitlesAutomatically()
            }
            .disabled(!state.syncApplies || state.syncWorking)
            Divider()
            // A stretch is a fact about the subtitle file, not a choice among
            // the delays: one line saying so, and a way back to the file's own
            // times. The picker below moves the delay on top of it.
            if scale != 1 {
                Button(Self.stretchText(scale)) {}
                    .disabled(true)
                Button("Use the File’s Timing") { model.resetSubtitleTiming() }
                Divider()
            }
            Picker("Delay", selection: Binding(get: { delay }, set: { model.setSubtitleDelay($0) })) {
                ForEach(Self.delayChoices(including: delay), id: \.self) { d in
                    Text(d == 0 ? "None" : Self.delayText(d)).tag(d)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .disabled(state.selected == 0)

        Divider()
        Picker("Subtitles", selection: Binding(
            get: { state.selected },
            set: { id in
                if inPlayer { model.switchTracks(subtitle: id) } else { model.subtitleID = id }
            })) {
            Text("Off").tag(0)
            ForEach(probe.subtitleTracks) { t in
                Text(Self.title(t, in: probe.subtitleTracks)).tag(t.id)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    /// The fixed choices, plus the current delay when it is none of them
    /// (from H / J or a saved setting), so it still has its checkmark.
    static func delayChoices(including d: Double) -> [Double] {
        let fixed = AppModel.subtitleDelayChoices
        return fixed.contains(d) ? fixed : (fixed + [d]).sorted()
    }

    static func title(_ t: SubtitleTrack, in tracks: [SubtitleTrack]) -> String {
        Fmt.trackTitle(t, in: tracks) + (t.burnsIn ? " · burned in, re-encodes video"
                             : t.viaOCR ? " · picture, shown as text" : "")
    }

    static func delayText(_ d: Double) -> String {
        d == 0 ? "none" : signed(d)
    }

    /// "Stretched 4.3 % to fit (made for 25 fps)": what a subtitle stretch
    /// does, in the words of the sync note.
    static func stretchText(_ scale: Double) -> String {
        let percent = (max(scale, 1 / scale) - 1) * 100
        let amount = String(format: percent >= 0.1 ? "%.1f %%" : "%.2f %%", percent)
        let made = madeFor.first { abs(scale / $0.ratio - 1) <= 4e-4 }.map { " (made for \($0.fps) fps)" } ?? ""
        return (scale > 1 ? "Stretched " : "Shortened ") + amount + " to fit" + made
    }

    private static let ntscFilm = 24000.0 / 1001

    /// Frame-rate ratios whose source rate the ratio alone tells (1.001 is
    /// 24 on 23.976 as well as 30 on 29.97, so it names none).
    private static let madeFor: [(ratio: Double, fps: String)] = [
        (25 / ntscFilm, "25"), (25 / 24, "25"), (ntscFilm / 25, "23.976"), (24 / 25, "24"),
    ]

    /// Short suffix for a menu label, e.g. " · +0.5 s".
    static func labelSuffix(_ d: Double) -> String {
        d == 0 ? "" : " · " + signed(d)
    }

    /// "+0.5 s" / "−1.0 s", with a real minus sign.
    private static func signed(_ d: Double) -> String {
        String(format: "%+.1f s", d).replacingOccurrences(of: "-", with: "\u{2212}")
    }
}

/// One quiet line in the ready view while Sync Automatically listens, and
/// its outcome for a few seconds after ("Subtitles moved 2.4 s later").
/// In the player the status line carries the same words.
struct SubtitleSyncNote: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let note = model.subtitleSyncNote, !model.showsPlayer {
            Label(note.text, systemImage: note.symbol)
                .lineLimit(2)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// One quiet line in the ready view while picture subtitles are read as text.
struct OCRNote: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let s = model.ocrStatus, model.selectedSubtitle?.viaOCR == true {
            HStack(spacing: 6) {
                switch s.status {
                case "working":
                    ProgressView(value: s.progress ?? 0).progressViewStyle(.linear).controlSize(.small).frame(width: 70)
                    Text("Reading the subtitles as text · \(Fmt.percent(s.progress))")
                case "ready":
                    Image(systemName: "text.viewfinder").foregroundStyle(.green)
                    Text("Picture subtitles read as text — no re-encode")
                case "failed", "unavailable":
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(s.error ?? "Couldn’t read the subtitles as text").lineLimit(2)
                default:
                    EmptyView()
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}
