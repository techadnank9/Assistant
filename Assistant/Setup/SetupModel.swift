import AVFoundation
import Observation
import UIKit
import UserNotifications

/// First-run (and whenever something's missing) checklist: microphone, speech recognition,
/// the model, notifications. The app only shows the orb once the required ones are ready.
@MainActor
@Observable
final class SetupModel {
    enum Step: Equatable {
        case waiting
        case working(String?, Double?)   // detail line, progress 0...1 if known
        case done
        case failed(String)
        case denied                      // permission refused; needs iOS Settings
    }

    private(set) var checked = false
    private(set) var microphone: Step = .waiting
    private(set) var speech: Step = .waiting
    private(set) var model: Step = .waiting
    private(set) var notifications: Step = .waiting
    /// Optional: the natural (Kokoro) voice. Apple's voice is used until it's ready.
    private(set) var voice: Step = .waiting
    var offersNaturalVoice: Bool { NaturalVoice.isSupported && AppSettings.shared.naturalVoice }

    /// Microphone, speech and model are required; notifications are optional.
    var isReady: Bool { microphone == .done && speech == .done && model == .done }

    /// Quick check at launch: skip the setup screen entirely if nothing is missing.
    func check() async {
        microphone = Self.microphoneStep()
        speech = await Listener.isInstalled() ? .done : .waiting
        let option = AppSettings.shared.model
        model = ModelFiles.localDirectory(for: option.id) != nil || ModelStatus.shared.state == .ready ? .done : .waiting
        #if targetEnvironment(simulator)
            model = .done
        #endif
        voice = NaturalVoice.isDownloaded ? .done : .waiting
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notifications = switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: .done
        case .denied: .denied
        default: .waiting
        }
        checked = true
        Log.info(.app, "Setup check: mic \(microphone), speech \(speech), model \(model)")
    }

    /// Starts every download that doesn't need a tap. Safe to call repeatedly.
    func startDownloads() {
        if speech == .waiting || isFailed(speech) { Task { await installSpeech() } }
        if model == .waiting || isFailed(model) {
            Task {
                await downloadModel()
                // One MLX download/load at a time: the voice follows the model.
                if offersNaturalVoice, voice == .waiting || isFailed(voice) { await downloadVoice() }
            }
        } else if offersNaturalVoice, voice == .waiting || isFailed(voice) {
            Task { await downloadVoice() }
        }
    }

    func requestMicrophone() async {
        if microphone == .denied {
            openSettings()
            return
        }
        microphone = .working(nil, nil)
        let granted = await AVAudioApplication.requestRecordPermission()
        microphone = granted ? .done : .denied
        Log.info(.app, "Microphone permission: \(granted)")
    }

    func requestNotifications() async {
        if notifications == .denied {
            openSettings()
            return
        }
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        notifications = granted ? .done : .denied
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func installSpeech() async {
        speech = .working("Downloading Apple's speech model…", nil)
        do {
            _ = try await Listener.setUp(status: { line in
                Task { @MainActor [weak self] in
                    let percent = line.split(separator: " ").last.flatMap { Double($0.dropLast()) }
                    self?.speech = .working("Downloading Apple's speech model…", percent.map { $0 / 100 })
                }
            }, timeout: .seconds(600))
            speech = .done
        } catch {
            Log.error(.speech, "Setup: speech failed: \(error)")
            speech = .failed(error.localizedDescription)
        }
    }

    private func downloadModel() async {
        model = .working("About 1 GB, once. Keeps downloading if you leave the app.", 0)
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                switch ModelStatus.shared.state {
                case .downloading(let f): model = .working("About 1 GB, once. Keeps downloading if you leave the app.", f)
                case .loading: model = .working("Getting it ready…", nil)
                default: break
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { watcher.cancel() }
        do {
            try await LLMEngine.shared.load(AppSettings.shared.model)
            model = .done
        } catch {
            model = .failed(error.localizedDescription)
        }
    }

    private func downloadVoice() async {
        voice = .working("About 328 MB, once. Keeps downloading if you leave the app.", 0)
        do {
            try await NaturalVoice.shared.load { fraction in
                Task { @MainActor [weak self] in
                    self?.voice = .working("About 328 MB, once. Keeps downloading if you leave the app.", fraction)
                }
            }
            voice = .done
        } catch {
            voice = .failed(error.localizedDescription)
        }
    }

    private func isFailed(_ step: Step) -> Bool {
        if case .failed = step { return true }
        return false
    }

    private static func microphoneStep() -> Step {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .done
        case .denied: .denied
        default: .waiting
        }
    }
}
