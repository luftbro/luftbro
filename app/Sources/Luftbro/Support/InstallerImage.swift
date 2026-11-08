import AppKit

/// After Luftbro is dragged to Applications and opened, its disk image is
/// still mounted. This ejects it: a read-only volume holding this very
/// Luftbro (same bundle id and build), and never the volume this copy runs
/// from. An image with another version stays, as it may be the next install.
@MainActor
enum InstallerImage {
    static func ejectIfMounted() {
        guard BackendProcess.bundledRuntime != nil else { return }      // the downloadable app only
        let me = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard !me.path.hasPrefix("/Volumes/") else { return }
        let id = Bundle.main.bundleIdentifier
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        let keys: [URLResourceKey] = [.volumeIsReadOnlyKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                            options: [.skipHiddenVolumes]) ?? []
        for volume in volumes where volume.path.hasPrefix("/Volumes/") {
            guard (try? volume.resourceValues(forKeys: Set(keys)))?.volumeIsReadOnly == true,
                  let info = NSDictionary(contentsOf: volume.appendingPathComponent("Luftbro.app/Contents/Info.plist")),
                  info["CFBundleIdentifier"] as? String == id,
                  info["CFBundleVersion"] as? String == build else { continue }
            Task.detached(priority: .utility) {
                try? NSWorkspace.shared.unmountAndEjectDevice(at: volume)
            }
        }
    }
}
