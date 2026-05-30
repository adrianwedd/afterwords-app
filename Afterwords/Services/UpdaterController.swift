import Combine
import Sparkle

@MainActor final class UpdaterController: ObservableObject {
    private let controller: SPUStandardUpdaterController

    @Published var canCheckForUpdates = false
    @Published var automaticallyChecksForUpdates = false

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
        // automaticallyChecksForUpdates is KVO-observable on SPUUpdater; mirror
        // it so the Settings toggle reflects the current (possibly user-changed
        // or plist-defaulted) value.
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$automaticallyChecksForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Toggle background update checks. Sparkle persists this in UserDefaults,
    /// overriding the SUEnableAutomaticChecks plist default.
    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }
}
