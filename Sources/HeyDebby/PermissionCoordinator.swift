import AppKit
import AVFoundation
import Combine
import CoreGraphics
import Foundation
import Speech

@MainActor
final class PermissionCoordinator: ObservableObject {
    enum Permission: String, CaseIterable, Hashable {
        case accessibility
        case screenRecording
        case microphone
        case speechRecognition
    }

    enum Status: String, Equatable {
        case notDetermined
        case denied
        case restricted
        case authorized

        var isAuthorized: Bool { self == .authorized }
    }

    enum Action: Equatable {
        case prompt
        case openSystemSettings
        case none
    }

    @Published private(set) var accessibility: Status = .notDetermined
    @Published private(set) var screenRecording: Status = .notDetermined
    @Published private(set) var microphone: Status = .notDetermined
    @Published private(set) var speechRecognition: Status = .notDetermined
    @Published private(set) var hasAssemblyAIAPIKey = false
    @Published private(set) var relaunchNeeded = false
    private(set) var relaunchReasons: Set<Permission> = []

    var accessibilityStatus: Status { accessibility }
    var screenRecordingStatus: Status { screenRecording }
    var microphoneStatus: Status { microphone }
    var speechRecognitionStatus: Status { speechRecognition }
    var requiresRelaunch: Bool { relaunchNeeded }

    /// Apple transcription needs both TCC grants; AssemblyAI does not use Apple Speech.
    var appleSpeechPrerequisitesSatisfied: Bool {
        microphone.isAuthorized && speechRecognition.isAuthorized
    }

    /// AssemblyAI still needs the microphone, plus a configured service key.
    var assemblyAIPrerequisitesSatisfied: Bool {
        microphone.isAuthorized && hasAssemblyAIAPIKey
    }

    var accessibilityAction: Action { action(for: .accessibility) }
    var screenRecordingAction: Action { action(for: .screenRecording) }
    var microphoneAction: Action { action(for: .microphone) }
    var speechRecognitionAction: Action { action(for: .speechRecognition) }

    private let defaults: UserDefaults
    private let environment: [String: String]
    private var assemblyAIConfiguredOverride: Bool?
    private var hasBaseline = false

    init(defaults: UserDefaults = .standard,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.defaults = defaults
        self.environment = environment
        refresh()
    }

    /// Re-reads TCC and key state, e.g. after returning from System Settings.
    func refresh() {
        let nextAccessibility = binaryStatus(
            granted: AXIsProcessTrusted(), prompted: defaults.bool(forKey: promptKey(.accessibility))
        )
        let nextScreen = binaryStatus(
            granted: CGPreflightScreenCaptureAccess(),
            prompted: defaults.bool(forKey: promptKey(.screenRecording))
        )
        let nextMicrophone = status(AVCaptureDevice.authorizationStatus(for: .audio))
        let nextSpeech = status(SFSpeechRecognizer.authorizationStatus())

        if hasBaseline {
            if !accessibility.isAuthorized && nextAccessibility.isAuthorized {
                relaunchReasons.insert(.accessibility)
            }
            if !screenRecording.isAuthorized && nextScreen.isAuthorized {
                relaunchReasons.insert(.screenRecording)
            }
            if !relaunchReasons.isEmpty { relaunchNeeded = true }
        }
        accessibility = nextAccessibility
        screenRecording = nextScreen
        microphone = nextMicrophone
        speechRecognition = nextSpeech
        hasAssemblyAIAPIKey = assemblyAIConfiguredOverride
            ?? !(environment["ASSEMBLYAI_API_KEY"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        hasBaseline = true
    }

    func updateAssemblyAIConfiguration(isConfigured: Bool) {
        assemblyAIConfiguredOverride = isConfigured
        hasAssemblyAIAPIKey = isConfigured
    }

    func status(for permission: Permission) -> Status {
        switch permission {
        case .accessibility: return accessibility
        case .screenRecording: return screenRecording
        case .microphone: return microphone
        case .speechRecognition: return speechRecognition
        }
    }

    /// First use gets the native prompt; a denied/restricted grant goes to its Settings pane.
    func action(for permission: Permission) -> Action {
        switch status(for: permission) {
        case .notDetermined: return .prompt
        case .denied, .restricted: return .openSystemSettings
        case .authorized: return .none
        }
    }

    func performAction(for permission: Permission) {
        switch action(for: permission) {
        case .prompt: prompt(permission)
        case .openSystemSettings: _ = openSystemSettings(for: permission)
        case .none: break
        }
    }

    /// Explicit prompt entry point; no-ops once the permission is determined.
    func prompt(_ permission: Permission) {
        guard status(for: permission) == .notDetermined else { return }
        switch permission {
        case .accessibility:
            defaults.set(true, forKey: promptKey(permission))
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            refresh()
        case .screenRecording:
            defaults.set(true, forKey: promptKey(permission))
            _ = CGRequestScreenCaptureAccess()
            refresh()
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        case .speechRecognition:
            SFSpeechRecognizer.requestAuthorization { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    @discardableResult
    func openSystemSettings(for permission: Permission) -> Bool {
        let pane: String
        switch permission {
        case .accessibility: pane = "Privacy_Accessibility"
        case .screenRecording: pane = "Privacy_ScreenCapture"
        case .microphone: pane = "Privacy_Microphone"
        case .speechRecognition: pane = "Privacy_SpeechRecognition"
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
        else { return false }
        return NSWorkspace.shared.open(url)
    }

    private func promptKey(_ permission: Permission) -> String {
        "PermissionCoordinator.didPrompt.\(permission.rawValue)"
    }

    private func binaryStatus(granted: Bool, prompted: Bool) -> Status {
        granted ? .authorized : (prompted ? .denied : .notDetermined)
    }

    private func status(_ status: AVAuthorizationStatus) -> Status {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        @unknown default: return .restricted
        }
    }

    private func status(_ status: SFSpeechRecognizerAuthorizationStatus) -> Status {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        @unknown default: return .restricted
        }
    }

}
