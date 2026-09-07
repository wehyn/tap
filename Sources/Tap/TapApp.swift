import AppKit
import CoreGraphics
import Foundation
import IOKit.hid
import Observation
import ServiceManagement
import SwiftUI
import TapProbeCore
import UniformTypeIdentifiers

private enum SensitivityMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high
    case custom

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }
}

private enum GestureActionCategory: String, CaseIterable, Identifiable, Sendable {
    case general
    case screenshots
    case clipboard
    case mediaAndVolume
    case utilities
    case appsAndShortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            return "General"
        case .screenshots:
            return "Screenshots"
        case .clipboard:
            return "Clipboard"
        case .mediaAndVolume:
            return "Media & Volume"
        case .utilities:
            return "Utilities"
        case .appsAndShortcuts:
            return "Apps & Shortcuts"
        }
    }
}

private enum GestureAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case showConfirmation
    case screenshot
    case screenshotClipboard
    case screenshotSelection
    case copy
    case paste
    case pasteWithoutFormatting
    case undo
    case redo
    case mute
    case mediaPlayPause
    case mediaNextTrack
    case mediaPreviousTrack
    case volumeUp
    case volumeDown
    case toggleWiFi
    case launchApp
    case openURL
    case runShortcut

    var id: String { rawValue }

    var category: GestureActionCategory {
        switch self {
        case .none, .showConfirmation:
            return .general
        case .screenshot, .screenshotClipboard, .screenshotSelection:
            return .screenshots
        case .copy, .paste, .pasteWithoutFormatting, .undo, .redo:
            return .clipboard
        case .mute, .mediaPlayPause, .mediaNextTrack, .mediaPreviousTrack, .volumeUp, .volumeDown:
            return .mediaAndVolume
        case .toggleWiFi:
            return .utilities
        case .launchApp, .openURL, .runShortcut:
            return .appsAndShortcuts
        }
    }

    var title: String {
        switch self {
        case .none:
            return "Do Nothing"
        case .showConfirmation:
            return "Show Confirmation"
        case .screenshot:
            return "Screenshot"
        case .screenshotClipboard:
            return "Screenshot → Clipboard"
        case .screenshotSelection:
            return "Screenshot Selected Area"
        case .copy:
            return "Copy"
        case .paste:
            return "Paste"
        case .pasteWithoutFormatting:
            return "Paste Without Formatting"
        case .undo:
            return "Undo"
        case .redo:
            return "Redo"
        case .mute:
            return "Mute / Unmute"
        case .mediaPlayPause:
            return "Play / Pause Media"
        case .mediaNextTrack:
            return "Next Track"
        case .mediaPreviousTrack:
            return "Previous Track"
        case .volumeUp:
            return "Volume Up"
        case .volumeDown:
            return "Volume Down"
        case .toggleWiFi:
            return "Toggle Wi‑Fi"
        case .launchApp:
            return "Launch App"
        case .openURL:
            return "Open URL"
        case .runShortcut:
            return "Run Apple Shortcut"
        }
    }

    var parameterPlaceholder: String? {
        switch self {
        case .launchApp:
            return "Application name, e.g. Notes"
        case .openURL:
            return "https://example.com"
        case .runShortcut:
            return "Shortcut name"
        case .none, .showConfirmation, .screenshot, .screenshotClipboard, .screenshotSelection, .copy,
             .paste, .pasteWithoutFormatting, .undo, .redo, .mute, .mediaPlayPause,
             .mediaNextTrack, .mediaPreviousTrack, .volumeUp, .volumeDown, .toggleWiFi:
            return nil
        }
    }

    var permissionNote: String? {
        switch self {
        case .screenshot, .screenshotClipboard, .screenshotSelection:
            return "Screen Recording permission may be required by macOS."
        case .copy, .paste, .pasteWithoutFormatting, .undo, .redo:
            return "Accessibility permission may be required to send keyboard shortcuts."
        case .mediaPlayPause:
            return "Automation permission for Music may be required."
        case .mediaNextTrack, .mediaPreviousTrack:
            return "Automation permission for Music may be required."
        case .runShortcut:
            return "Automation permission may be requested for Shortcuts."
        case .none, .showConfirmation, .mute, .volumeUp, .volumeDown, .toggleWiFi,
             .launchApp, .openURL:
            return nil
        }
    }
}

private enum PermissionRecovery: Equatable, Sendable {
    case inputMonitoring
    case screenRecording
    case accessibility
    case automation(target: String)

    var message: String {
        switch self {
        case .inputMonitoring:
            return "Tap needs Input Monitoring access to read the MacBook motion sensors."
        case .screenRecording:
            return "Tap needs Screen Recording access to capture the display."
        case .accessibility:
            return "Tap needs Accessibility access to send keyboard shortcuts."
        case let .automation(target):
            return "Tap needs Automation access to control \(target)."
        }
    }

    var privacyKey: String {
        switch self {
        case .inputMonitoring:
            return "Privacy_ListenEvent"
        case .screenRecording:
            return "Privacy_ScreenCapture"
        case .accessibility:
            return "Privacy_Accessibility"
        case .automation:
            return "Privacy_Automation"
        }
    }
}

private enum LaunchAtLoginState: Equatable {
    case enabled
    case disabled
    case needsApproval
    case unavailable

    var code: String {
        switch self {
        case .enabled: return "enabled"
        case .disabled: return "disabled"
        case .needsApproval: return "needsApproval"
        case .unavailable: return "unavailable"
        }
    }

    var message: String {
        switch self {
        case .enabled:
            return "Tap will start automatically when you sign in."
        case .disabled:
            return "Tap starts only when you open it."
        case .needsApproval:
            return "macOS requires approval in System Settings > General > Login Items."
        case .unavailable:
            return "Launch at login is available from the packaged Tap.app bundle."
        }
    }
}

private enum GestureSlotID: String, Codable, CaseIterable, Identifiable, Sendable {
    case leftOne
    case leftTwo
    case leftThree
    case rightOne
    case rightTwo
    case rightThree

    var id: String { rawValue }

    var side: TapSide {
        rawValue.hasPrefix("left") ? .left : .right
    }

    var tapCount: Int {
        switch self {
        case .leftOne, .rightOne:
            return 1
        case .leftTwo, .rightTwo:
            return 2
        case .leftThree, .rightThree:
            return 3
        }
    }

    var title: String {
        "\(side.rawValue.capitalized) · \(tapCount) \(tapCount == 1 ? "tap" : "taps")"
    }

    init?(side: TapSide, tapCount: Int) {
        switch (side, tapCount) {
        case (.left, 1): self = .leftOne
        case (.left, 2): self = .leftTwo
        case (.left, 3): self = .leftThree
        case (.right, 1): self = .rightOne
        case (.right, 2): self = .rightTwo
        case (.right, 3): self = .rightThree
        default: return nil
        }
    }
}

private struct GestureSlotSettings: Codable, Equatable, Sendable {
    var enabled: Bool
    var action: GestureAction
    var urlString: String

    init(
        enabled: Bool = true,
        action: GestureAction = .none,
        urlString: String = ""
    ) {
        self.enabled = enabled
        self.action = action
        self.urlString = urlString
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case action
        case urlString
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        action = try container.decodeIfPresent(GestureAction.self, forKey: .action) ?? .none
        urlString = try container.decodeIfPresent(String.self, forKey: .urlString) ?? ""
    }
}

private struct DiagnosticCandidateSummary: Encodable, Sendable {
    let side: String
    let peakDynamicAccelerationG: Double
    let peakAngularRateDps: Double
    let confidence: Double
}

private struct DiagnosticGestureSummary: Encodable, Sendable {
    let side: String
    let tapCount: Int
}

private struct DiagnosticExport: Encodable, Sendable {
    let exportedAt: Date
    let appVersion: String
    let macOSVersion: String
    let readerPhase: String
    let sensorDescriptors: [SensorDescriptor]
    let openedDeviceCount: Int
    let parsedReportCount: Int
    let parserErrorCount: Int
    let accelerometerSampleCount: Int
    let gyroscopeSampleCount: Int
    let calibrationProgress: Double
    let hasCalibrationProfile: Bool
    let sideProfileReady: Bool
    let sensitivity: String
    let customThresholdG: Double
    let groupingWindowMilliseconds: Double
    let cooldownMilliseconds: Double
    let launchAtLoginState: String
    let inputMonitoringPermissionGranted: Bool
    let screenRecordingPermissionGranted: Bool
    let permissionRecovery: String?
    let lastCandidate: DiagnosticCandidateSummary?
    let lastGesture: DiagnosticGestureSummary?
}

private struct TapSettings: Codable, Equatable, Sendable {
    static let storageKey = "tap.settings.v1"
    private static let currentRecognitionDefaultsVersion = 2

    var recognitionDefaultsVersion = Self.currentRecognitionDefaultsVersion
    var enabled = false
    var launchAtLogin = false
    var hasCompletedOnboarding = false
    var sensitivityMode: SensitivityMode = .medium
    var customThresholdG = 0.10
    var calibrationSeconds = 2.0
    var groupingWindowMilliseconds = 450.0
    var cooldownMilliseconds = 120.0
    var sideProfileData: Data?
    var calibrationProfileData: Data?
    var slots: [GestureSlotID: GestureSlotSettings] = Self.defaultSlots

    private enum CodingKeys: String, CodingKey {
        case recognitionDefaultsVersion
        case enabled
        case launchAtLogin
        case hasCompletedOnboarding
        case sensitivityMode
        case customThresholdG
        case calibrationSeconds
        case groupingWindowMilliseconds
        case cooldownMilliseconds
        case sideProfileData
        case calibrationProfileData
        case slots
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recognitionDefaultsVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .recognitionDefaultsVersion
        ) ?? 1
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        hasCompletedOnboarding = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasCompletedOnboarding
        ) ?? false
        sensitivityMode = try container.decodeIfPresent(
            SensitivityMode.self,
            forKey: .sensitivityMode
        ) ?? .medium
        customThresholdG = try container.decodeIfPresent(
            Double.self,
            forKey: .customThresholdG
        ) ?? 0.10
        calibrationSeconds = try container.decodeIfPresent(
            Double.self,
            forKey: .calibrationSeconds
        ) ?? 2.0
        groupingWindowMilliseconds = try container.decodeIfPresent(
            Double.self,
            forKey: .groupingWindowMilliseconds
        ) ?? 450.0
        cooldownMilliseconds = try container.decodeIfPresent(
            Double.self,
            forKey: .cooldownMilliseconds
        ) ?? 120.0
        sideProfileData = try container.decodeIfPresent(Data.self, forKey: .sideProfileData)
        calibrationProfileData = try container.decodeIfPresent(
            Data.self,
            forKey: .calibrationProfileData
        )
        slots = try container.decodeIfPresent(
            [GestureSlotID: GestureSlotSettings].self,
            forKey: .slots
        ) ?? Self.defaultSlots
    }

    static var defaultSlots: [GestureSlotID: GestureSlotSettings] {
        Dictionary(uniqueKeysWithValues: GestureSlotID.allCases.map { slot in
            (
                slot,
                GestureSlotSettings(
                    action: slot == .leftOne ? .showConfirmation : .none
                )
            )
        })
    }

    static func load(from defaults: UserDefaults = .standard) -> TapSettings {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(TapSettings.self, from: data) else {
            return TapSettings()
        }

        var settings = decoded
        if settings.recognitionDefaultsVersion < currentRecognitionDefaultsVersion {
            // Version 1 used 250 ms, which swallowed normal fast double taps.
            // Timing is internal, so migrate the old default without adding a
            // user-facing calibration or advanced timing control.
            if abs(settings.cooldownMilliseconds - 250) < 0.001 {
                settings.cooldownMilliseconds = 120
            }
            settings.recognitionDefaultsVersion = currentRecognitionDefaultsVersion
            settings.save(to: defaults)
        }
        for slot in GestureSlotID.allCases where settings.slots[slot] == nil {
            settings.slots[slot] = defaultSlots[slot]
        }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else {
            return
        }
        defaults.set(data, forKey: Self.storageKey)
    }
}

private struct RuntimeSnapshot: Sendable {
    let accelerometerSampleCount: Int
    let gyroscopeSampleCount: Int
    let calibrationProgress: Double
    let calibrationProfile: CalibrationProfile?
}

private final class AppMotionRuntime: @unchecked Sendable {
    private let session: RecognitionSession
    private let lock = NSLock()
    private var accelerometerSampleCount = 0
    private var gyroscopeSampleCount = 0
    private var calibrationProfile: CalibrationProfile?
    private var calibrationProgress = 0.0

    init(
        settings: TapSettings,
        sideProfile: TapSideProfile?,
        detectionThresholdOverrideG: Double? = nil
    ) {
        let configuredThreshold: Double?
        switch settings.sensitivityMode {
        case .custom:
            configuredThreshold = max(0.02, min(0.50, settings.customThresholdG))
        case .low, .medium, .high:
            configuredThreshold = nil
        }

        let sensitivity: TapSensitivity
        switch settings.sensitivityMode {
        case .low: sensitivity = .low
        case .medium: sensitivity = .medium
        case .high, .custom: sensitivity = .high
        }

        let threshold = detectionThresholdOverrideG.map {
            max(0.02, min(0.50, $0))
        } ?? configuredThreshold

        session = RecognitionSession(
            calibrationSeconds: max(0.5, min(10, settings.calibrationSeconds)),
            sensitivity: sensitivity,
            thresholdG: threshold,
            sideProfile: sideProfile,
            groupingWindowNanoseconds: UInt64(
                max(100, min(2_000, settings.groupingWindowMilliseconds)) * 1_000_000
            ),
            cooldownNanoseconds: UInt64(
                max(50, min(2_000, settings.cooldownMilliseconds)) * 1_000_000
            )
        )
    }

    func process(_ sample: MotionSample) -> RecognitionUpdate {
        lock.lock()
        switch sample.channel {
        case .accelerometer:
            accelerometerSampleCount += 1
        case .gyroscope:
            gyroscopeSampleCount += 1
        }
        lock.unlock()

        let update = session.process(sample)
        lock.lock()
        calibrationProgress = update.calibrationProgress
        if let profile = update.calibrationProfile {
            calibrationProfile = profile
        }
        lock.unlock()
        return update
    }

    func snapshot() -> RuntimeSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return RuntimeSnapshot(
            accelerometerSampleCount: accelerometerSampleCount,
            gyroscopeSampleCount: gyroscopeSampleCount,
            calibrationProgress: calibrationProgress,
            calibrationProfile: calibrationProfile
        )
    }
}

private struct LocalCommandResult: Sendable {
    let succeeded: Bool
    let stdout: String
    let stderr: String
}

private enum LocalCommandRunner {
    static func run(executablePath: String, arguments: [String]) async -> Bool {
        await capture(executablePath: executablePath, arguments: arguments).succeeded
    }

    static func capture(
        executablePath: String,
        arguments: [String]
    ) async -> LocalCommandResult {
        await withCheckedContinuation { continuation in
            do {
                let process = Process()
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                process.terminationHandler = { process in
                    let output = String(
                        decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                        as: UTF8.self
                    )
                    let error = String(
                        decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                        as: UTF8.self
                    )
                    continuation.resume(
                        returning: LocalCommandResult(
                            succeeded: process.terminationStatus == 0,
                            stdout: output,
                            stderr: error
                        )
                    )
                }
                try process.run()
            } catch {
                continuation.resume(
                    returning: LocalCommandResult(
                        succeeded: false,
                        stdout: "",
                        stderr: error.localizedDescription
                    )
                )
            }
        }
    }
}

private final class LifecycleObserverStore: @unchecked Sendable {
    var tokens: [NSObjectProtocol] = []
}

@MainActor
@Observable
private final class TapAppModel {
    var settings: TapSettings
    var readerStatus = SensorReaderStatus(phase: .idle)
    var lastCandidate: TapEvent?
    var lastGesture: TapProbeCore.TapGesture?
    var calibrationProgress = 0.0
    var calibrationProfile: CalibrationProfile?
    var storedCalibrationProfile: CalibrationProfile?
    var accelerometerSampleCount = 0
    var gyroscopeSampleCount = 0
    var feedbackMessage = "Ready when you are."
    var inputMonitoringPermissionGranted = false
    var screenRecordingPermissionGranted = false
    var permissionRecovery: PermissionRecovery?
    var launchAtLoginState: LaunchAtLoginState = .disabled
    var availableShortcuts: [String] = []
    var isLoadingShortcuts = false
    var sideCalibration = GuidedSideCalibration(requiredSamplesPerSide: 5)

    @ObservationIgnored private var reader: AppleSPUHIDReader?
    @ObservationIgnored private var runtime: AppMotionRuntime?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var recognitionWasEnabledBeforeSideCalibration = false
    @ObservationIgnored private let lifecycleObserverStore = LifecycleObserverStore()

    init() {
        settings = TapSettings.load()
        if !settings.hasCompletedOnboarding {
            settings.hasCompletedOnboarding = true
            settings.save()
        }
        storedCalibrationProfile = settings.calibrationProfileData.flatMap {
            try? JSONDecoder().decode(CalibrationProfile.self, from: $0)
        }
        inputMonitoringPermissionGranted = hasInputMonitoringAccess()
        screenRecordingPermissionGranted = CGPreflightScreenCaptureAccess()
        refreshLaunchAtLoginState()
        registerLifecycleObservers()
    }

    deinit {
        refreshTask?.cancel()
        wakeTask?.cancel()
        reconnectTask?.cancel()
        reader?.stop()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        lifecycleObserverStore.tokens.forEach(workspaceCenter.removeObserver)
    }

    var phaseTitle: String {
        if case .inputMonitoring = permissionRecovery,
           readerStatus.phase != .streaming {
            return "Input Monitoring needed"
        }
        switch readerStatus.phase {
        case .idle: return "Paused"
        case .starting: return "Starting"
        case .streaming: return calibrationProgress < 1 ? "Starting" : "Listening"
        case .stopped: return "Paused"
        case .noSensors: return "Sensors unavailable"
        case .failed: return "Sensor error"
        }
    }

    var phaseColor: Color {
        switch readerStatus.phase {
        case .streaming:
            return calibrationProgress < 1 ? .orange : .green
        case .starting:
            return .orange
        case .noSensors, .failed:
            return .red
        case .idle, .stopped:
            return .secondary
        }
    }

    var currentThresholdText: String {
        switch settings.sensitivityMode {
        case .custom:
            return String(format: "%.2f g", customThreshold)
        case .low, .medium, .high:
            return String(format: "%.2f g", selectedSensitivity.minimumDynamicAccelerationG)
        }
    }

    var selectedSensitivity: TapSensitivity {
        switch settings.sensitivityMode {
        case .low: return .low
        case .medium: return .medium
        case .high, .custom: return .high
        }
    }

    var customThreshold: Double {
        get { max(0.02, min(0.50, settings.customThresholdG)) }
        set {
            settings.customThresholdG = max(0.02, min(0.50, newValue))
            saveAndRestartIfNeeded()
        }
    }

    var profileIsUsable: Bool {
        loadedSideProfile()?.isUsable == true
    }

    var hasSavedSideProfile: Bool {
        guard let data = settings.sideProfileData,
              let profile = try? JSONDecoder().decode(TapSideProfile.self, from: data) else {
            return false
        }
        return profile.isUsable
    }

    var sideModelDescription: String {
        if sideCalibration.isActive {
            return "Calibration in progress"
        }
        return hasSavedSideProfile
            ? "Using your saved side profile"
            : "Using the bundled MacBook profile"
    }

    var sideCalibrationMessage: String {
        switch sideCalibration.phase {
        case .idle:
            return hasSavedSideProfile
                ? "Tap is using your saved left/right profile. Recalibrate if side labels are still wrong."
                : "Tap is using the bundled directional profile. If side labels are wrong, calibrate this MacBook once."
        case .preparing:
            return "Keep the MacBook still while Tap measures a short baseline…"
        case .left:
            return "Tap the left palm rest "
                + String(sideCalibration.leftSampleCount)
                + "/"
                + String(sideCalibration.requiredSamplesPerSide)
                + " times. Pause briefly between taps."
        case .right:
            return "Left palm rest saved. Tap the right palm rest "
                + String(sideCalibration.rightSampleCount)
                + "/"
                + String(sideCalibration.requiredSamplesPerSide)
                + " times."
        case .complete:
            return "Your left/right side profile is saved locally."
        }
    }

    func startIfNeeded() {
        refreshPermissions()
        guard settings.enabled, reader == nil else {
            return
        }
        startForCurrentConfiguration()
    }

    func setEnabled(_ value: Bool) {
        if !value, sideCalibration.isActive {
            cancelSideCalibration()
        }
        settings.enabled = value
        settings.save()
        if value {
            startForCurrentConfiguration()
        } else {
            stop()
        }
    }

    private func startForCurrentConfiguration() {
        if sideCalibration.isActive {
            startInternal(
                sideProfile: nil,
                detectionThresholdOverrideG: 0.02
            )
        } else {
            start()
        }
    }

    func start() {
        guard !sideCalibration.isActive else {
            startForCurrentConfiguration()
            return
        }
        startInternal(sideProfile: loadedSideProfile())
    }

    func beginSideCalibration() {
        guard !sideCalibration.isActive else {
            return
        }

        recognitionWasEnabledBeforeSideCalibration = settings.enabled
        sideCalibration.start()
        if !settings.enabled {
            settings.enabled = true
            settings.save()
        }
        feedbackMessage = "Keep the MacBook still while Tap measures a baseline."
        startInternal(
            sideProfile: nil,
            detectionThresholdOverrideG: 0.02
        )
    }

    func cancelSideCalibration() {
        guard sideCalibration.isActive else {
            return
        }

        let shouldResumeRecognition = recognitionWasEnabledBeforeSideCalibration
        recognitionWasEnabledBeforeSideCalibration = false
        sideCalibration.cancel()
        if shouldResumeRecognition {
            feedbackMessage = "Side calibration cancelled. Recognition is using the previous profile."
            start()
        } else {
            stopReaderOnly()
            settings.enabled = false
            settings.save()
            readerStatus = SensorReaderStatus(phase: .stopped)
            calibrationProgress = 0
            feedbackMessage = "Side calibration cancelled."
        }
    }

    func retrySensorAccess() {
        guard settings.enabled else {
            feedbackMessage = "Enable recognition before retrying sensor access."
            return
        }
        start()
    }

    func refreshPermissions() {
        inputMonitoringPermissionGranted = hasInputMonitoringAccess()
        screenRecordingPermissionGranted = CGPreflightScreenCaptureAccess()
        if inputMonitoringPermissionGranted,
           permissionRecovery == .inputMonitoring {
            permissionRecovery = nil
        }
        if screenRecordingPermissionGranted,
           permissionRecovery == .screenRecording {
            permissionRecovery = nil
        }
    }

    func requestScreenRecordingPermission() {
        screenRecordingPermissionGranted = CGRequestScreenCaptureAccess()
        if screenRecordingPermissionGranted {
            permissionRecovery = nil
            feedbackMessage = "Screen Recording permission is enabled."
        } else {
            permissionRecovery = .screenRecording
            feedbackMessage = "Screen Recording permission is still required for screenshots."
        }
    }

    func requestInputMonitoringPermission() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        refreshPermissions()
        if inputMonitoringPermissionGranted {
            permissionRecovery = nil
            feedbackMessage = "Input Monitoring access is enabled. Tap is reconnecting to the motion sensors."
            if settings.enabled {
                startForCurrentConfiguration()
            }
        } else {
            permissionRecovery = .inputMonitoring
            feedbackMessage = "Allow Tap in Privacy & Security > Input Monitoring, then retry sensor access."
        }
    }

    var launchAtLoginEnabled: Bool {
        launchAtLoginState == .enabled || launchAtLoginState == .needsApproval
    }

    func refreshLaunchAtLoginState() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginState = .enabled
        case .requiresApproval:
            launchAtLoginState = .needsApproval
        case .notRegistered:
            launchAtLoginState = .disabled
        case .notFound:
            launchAtLoginState = .unavailable
        @unknown default:
            launchAtLoginState = .unavailable
        }

        let actualPreference = launchAtLoginEnabled
        if launchAtLoginState != .unavailable,
           settings.launchAtLogin != actualPreference {
            settings.launchAtLogin = actualPreference
            settings.save()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
            settings.launchAtLogin = enabled
            settings.save()
            refreshLaunchAtLoginState()
            feedbackMessage = launchAtLoginState.message
        } catch {
            refreshLaunchAtLoginState()
            feedbackMessage = "Could not update launch at login: \(error.localizedDescription)"
        }
    }

    func openLoginItemsSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.settings.LoginItems",
            "x-apple.systempreferences:com.apple.settings.General",
        ].compactMap(URL.init(string:))
        let opened = candidates.contains { NSWorkspace.shared.open($0) }
        feedbackMessage = opened
            ? "Opened Login Items settings. Approve Tap if macOS asks."
            : "Open System Settings > General > Login Items and approve Tap."
    }

    func loadShortcuts() {
        guard !isLoadingShortcuts else {
            return
        }
        isLoadingShortcuts = true
        feedbackMessage = "Loading shortcuts…"

        Task { @MainActor [weak self] in
            let result = await LocalCommandRunner.capture(
                executablePath: "/usr/bin/shortcuts",
                arguments: ["list"]
            )
            guard let self else {
                return
            }
            isLoadingShortcuts = false

            guard result.succeeded else {
                availableShortcuts = []
                permissionRecovery = .automation(target: "Shortcuts")
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                feedbackMessage = detail.isEmpty
                    ? "Could not list Apple Shortcuts. Check Automation permission."
                    : "Could not list Apple Shortcuts: \(detail)"
                return
            }

            availableShortcuts = Array(Set(
                result.stdout
                    .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )).sorted()
            permissionRecovery = nil
            feedbackMessage = availableShortcuts.isEmpty
                ? "No Apple Shortcuts were found."
                : "Loaded \(availableShortcuts.count) Apple Shortcuts."
        }
    }

    func exportDiagnostics() {
        let export = DiagnosticExport(
            exportedAt: Date(),
            appVersion: (Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String) ?? "development",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            readerPhase: readerStatus.phase.rawValue,
            sensorDescriptors: readerStatus.descriptors,
            openedDeviceCount: readerStatus.openedDeviceCount,
            parsedReportCount: readerStatus.parsedSampleCount,
            parserErrorCount: readerStatus.parseErrorCount,
            accelerometerSampleCount: accelerometerSampleCount,
            gyroscopeSampleCount: gyroscopeSampleCount,
            calibrationProgress: calibrationProgress,
            hasCalibrationProfile: calibrationProfile != nil,
            sideProfileReady: profileIsUsable,
            sensitivity: settings.sensitivityMode.rawValue,
            customThresholdG: customThreshold,
            groupingWindowMilliseconds: settings.groupingWindowMilliseconds,
            cooldownMilliseconds: settings.cooldownMilliseconds,
            launchAtLoginState: launchAtLoginState.code,
            inputMonitoringPermissionGranted: inputMonitoringPermissionGranted,
            screenRecordingPermissionGranted: screenRecordingPermissionGranted,
            permissionRecovery: permissionRecovery?.message,
            lastCandidate: lastCandidate.map {
                DiagnosticCandidateSummary(
                    side: $0.side.rawValue,
                    peakDynamicAccelerationG: $0.peakDynamicAccelerationG,
                    peakAngularRateDps: $0.peakAngularRateDps,
                    confidence: $0.confidence
                )
            },
            lastGesture: lastGesture.map {
                DiagnosticGestureSummary(side: $0.side.rawValue, tapCount: $0.tapCount)
            }
        )

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(export)

            let panel = NSSavePanel()
            panel.title = "Export Tap Diagnostics"
            panel.nameFieldStringValue = "Tap Diagnostics.json"
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else {
                return
            }

            try data.write(to: url, options: .atomic)
            feedbackMessage = "Exported redacted diagnostics to \(url.lastPathComponent)."
        } catch {
            feedbackMessage = "Could not export diagnostics: \(error.localizedDescription)"
        }
    }

    func openPermissionSettings() {
        guard let recovery = permissionRecovery else {
            return
        }

        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?\(recovery.privacyKey)",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(recovery.privacyKey)",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity",
        ].compactMap(URL.init(string:))
        let opened = candidates.contains { NSWorkspace.shared.open($0) }
        feedbackMessage = opened
            ? "Opened Privacy & Security. Allow Tap, then test the action again."
            : "Open System Settings > Privacy & Security and allow Tap, then test again."
    }

    private func startInternal(
        sideProfile: TapSideProfile?,
        detectionThresholdOverrideG: Double? = nil
    ) {
        // Core Graphics' event-listening preflight can lag behind the
        // Input Monitoring toggle. Attempt the actual HID connection and let
        // AppleSPUHIDReader report whether macOS permits the sensor open.
        refreshPermissions()
        if !inputMonitoringPermissionGranted {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            refreshPermissions()
        }
        stopReaderOnly()
        lastCandidate = nil
        lastGesture = nil
        calibrationProgress = 0
        calibrationProfile = nil
        accelerometerSampleCount = 0
        gyroscopeSampleCount = 0
        feedbackMessage = "Starting motion detection…"

        let runtime = AppMotionRuntime(
            settings: settings,
            sideProfile: sideProfile,
            detectionThresholdOverrideG: detectionThresholdOverrideG
        )
        self.runtime = runtime

        let reader = AppleSPUHIDReader(
            onSample: { [weak self, weak runtime] sample, _ in
                guard let runtime else { return }
                let update = runtime.process(sample)
                guard update.calibrationProfile != nil
                        || update.tapEvent != nil
                        || !update.completedGestures.isEmpty else {
                    return
                }
                Task { @MainActor [weak self] in
                    self?.receive(update)
                }
            },
            onStatus: { [weak self] status in
                Task { @MainActor [weak self] in
                    self?.receive(status)
                }
            }
        )
        self.reader = reader
        reader.start()
        startRefreshTask()
    }

    func stop() {
        settings.enabled = false
        settings.save()
        wakeTask?.cancel()
        wakeTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        stopReaderOnly()
        readerStatus = SensorReaderStatus(phase: .stopped)
        feedbackMessage = "Recognition is paused."
    }

    func updateSensitivity(_ mode: SensitivityMode) {
        settings.sensitivityMode = mode
        saveAndRestartIfNeeded()
    }

    func action(for slot: GestureSlotID) -> GestureAction {
        settings.slots[slot]?.action ?? .none
    }

    func slotEnabled(_ slot: GestureSlotID) -> Bool {
        settings.slots[slot]?.enabled ?? true
    }

    func updateSlotEnabled(_ enabled: Bool, for slot: GestureSlotID) {
        settings.slots[slot, default: GestureSlotSettings()].enabled = enabled
        settings.save()
    }

    func updateAction(_ action: GestureAction, for slot: GestureSlotID) {
        settings.slots[slot, default: GestureSlotSettings()].action = action
        settings.save()
    }

    func url(for slot: GestureSlotID) -> String {
        settings.slots[slot]?.urlString ?? ""
    }

    func parameterPlaceholder(for slot: GestureSlotID) -> String {
        action(for: slot).parameterPlaceholder ?? ""
    }

    func permissionNote(for slot: GestureSlotID) -> String? {
        let selectedAction = action(for: slot)
        if [.screenshot, .screenshotClipboard, .screenshotSelection].contains(selectedAction) {
            return screenRecordingPermissionGranted
                ? "Screen Recording: allowed."
                : "Screen Recording permission is required."
        }
        return selectedAction.permissionNote
    }

    func updateURL(_ value: String, for slot: GestureSlotID) {
        settings.slots[slot, default: GestureSlotSettings()].urlString = value
        settings.save()
    }

    func test(slot: GestureSlotID) {
        execute(action: action(for: slot), urlString: url(for: slot), label: "Test · \(slot.title)")
    }

    private func receive(_ status: SensorReaderStatus) {
        readerStatus = status
        if status.phase == .streaming {
            // The sensor open is the authoritative permission check for this
            // reader. A successful stream should clear a stale Core Graphics
            // preflight result and any old recovery message.
            inputMonitoringPermissionGranted = true
            if permissionRecovery == .inputMonitoring {
                permissionRecovery = nil
            }
            reconnectTask?.cancel()
            reconnectTask = nil
        }
        if status.phase == .noSensors || status.phase == .failed {
            feedbackMessage = status.message ?? "Tap could not access the motion sensors."
            if status.message?.localizedCaseInsensitiveContains("Input Monitoring") == true {
                inputMonitoringPermissionGranted = false
                permissionRecovery = .inputMonitoring
            }
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard settings.enabled, reconnectTask == nil else {
            return
        }
        reconnectTask = Task { @MainActor [weak self] in
            for _ in 0..<5 {
                guard !Task.isCancelled,
                      let self,
                      self.settings.enabled else {
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled,
                      self.settings.enabled else {
                    return
                }
                self.start()
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else {
                    return
                }
                if self.readerStatus.phase == .streaming {
                    return
                }
            }
            guard let self, !Task.isCancelled else {
                return
            }
            self.reconnectTask = nil
            self.feedbackMessage = "Sensors are still unavailable. Use Retry sensor access when ready."
        }
    }

    private func receive(_ update: RecognitionUpdate) {
        calibrationProgress = update.calibrationProgress
        if let profile = update.calibrationProfile {
            calibrationProfile = profile
            storedCalibrationProfile = profile
            settings.calibrationProfileData = try? JSONEncoder().encode(profile)
            settings.save()
            if sideCalibration.phase == .preparing {
                sideCalibration.markCalibrationComplete()
                feedbackMessage = "Baseline ready. Tap the left palm rest "
                    + String(sideCalibration.requiredSamplesPerSide)
                    + " times."
            } else {
                feedbackMessage = "Tap is ready."
            }
        }
        if let event = update.tapEvent {
            if sideCalibration.isActive {
                receiveSideCalibrationEvent(event)
                return
            }
            lastCandidate = event
            feedbackMessage = event.side == .unknown
                ? "Tap candidate detected, but the side was ambiguous. Try a firmer tap or adjust sensitivity."
                : "\(event.side.rawValue.capitalized) tap candidate detected."
        }
        for gesture in update.completedGestures {
            handle(gesture)
        }
    }

    private func receiveSideCalibrationEvent(_ event: TapEvent) {
        guard sideCalibration.phase == .left || sideCalibration.phase == .right else {
            return
        }

        lastCandidate = event
        let phaseBefore = sideCalibration.phase
        sideCalibration.add(event: event)

        switch sideCalibration.phase {
        case .left:
            feedbackMessage = "Left palm-rest tap "
                + String(sideCalibration.leftSampleCount)
                + "/"
                + String(sideCalibration.requiredSamplesPerSide)
                + " captured."
        case .right:
            if phaseBefore == .left {
                feedbackMessage = "Left palm rest saved. Now tap the right palm rest "
                    + String(sideCalibration.requiredSamplesPerSide)
                    + " times."
            } else {
                feedbackMessage = "Right palm-rest tap "
                    + String(sideCalibration.rightSampleCount)
                    + "/"
                    + String(sideCalibration.requiredSamplesPerSide)
                    + " captured."
            }
        case .complete:
            guard let profile = sideCalibration.profile else {
                feedbackMessage = "Side calibration did not produce a usable profile. Try again."
                return
            }
            settings.sideProfileData = try? JSONEncoder().encode(profile)
            settings.save()
            recognitionWasEnabledBeforeSideCalibration = false
            feedbackMessage = "Side calibration saved. Recognition is ready."
            startInternal(sideProfile: profile)
        case .idle, .preparing:
            break
        }
    }

    private func handle(_ gesture: TapProbeCore.TapGesture) {
        lastGesture = gesture
        guard let slot = GestureSlotID(side: gesture.side, tapCount: gesture.tapCount) else {
            feedbackMessage = "\(gesture.tapCount)-tap gesture needs a classified side."
            return
        }
        guard slotEnabled(slot) else {
            feedbackMessage = "Recognized \(slot.title); that slot is disabled."
            return
        }
        execute(action: action(for: slot), urlString: url(for: slot), label: slot.title)
    }

    private func execute(action: GestureAction, urlString: String, label: String) {
        switch action {
        case .none:
            feedbackMessage = "Recognized \(label); no action is assigned."
        case .showConfirmation:
            feedbackMessage = "Recognized \(label)."
            NSSound.beep()
        case .screenshot:
            refreshPermissions()
            guard screenRecordingPermissionGranted else {
                requestScreenRecordingPermission()
                feedbackMessage = "Enable Screen Recording, then test \(label) again."
                return
            }
            let desktopURL = FileManager.default.urls(
                for: .desktopDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.homeDirectoryForCurrentUser
            let fileName = "Tap Screenshot \(Int(Date().timeIntervalSince1970)).png"
            let destination = desktopURL.appendingPathComponent(fileName)
            runCommand(
                executablePath: "/usr/sbin/screencapture",
                arguments: ["-x", destination.path],
                label: label,
                successMessage: "Saved screenshot for \(label) to the Desktop."
            )
        case .screenshotClipboard:
            refreshPermissions()
            guard screenRecordingPermissionGranted else {
                requestScreenRecordingPermission()
                feedbackMessage = "Enable Screen Recording, then test \(label) again."
                return
            }
            runCommand(
                executablePath: "/usr/sbin/screencapture",
                arguments: ["-c"],
                label: label,
                successMessage: "Copied a screenshot to the clipboard for \(label)."
            )
        case .screenshotSelection:
            refreshPermissions()
            guard screenRecordingPermissionGranted else {
                requestScreenRecordingPermission()
                feedbackMessage = "Enable Screen Recording, then test \(label) again."
                return
            }
            runCommand(
                executablePath: "/usr/sbin/screencapture",
                arguments: ["-x", "-i", "-c"],
                label: label,
                successMessage: "Copied the selected area to the clipboard for \(label)."
            )
        case .copy:
            runCommand(
                executablePath: "/usr/bin/osascript",
                arguments: [
                    "-e",
                    "tell application \"System Events\" to keystroke \"c\" using command down"
                ],
                label: label,
                successMessage: "Copied the front app selection for \(label).",
                permissionRecovery: .accessibility
            )
        case .paste:
            runCommand(
                executablePath: "/usr/bin/osascript",
                arguments: [
                    "-e",
                    "tell application \"System Events\" to keystroke \"v\" using command down"
                ],
                label: label,
                successMessage: "Pasted from the clipboard for \(label).",
                permissionRecovery: .accessibility
            )
        case .pasteWithoutFormatting:
            runCommand(
                executablePath: "/usr/bin/osascript",
                arguments: [
                    "-e",
                    "tell application \"System Events\" to keystroke \"v\" using {command down, option down, shift down}"
                ],
                label: label,
                successMessage: "Pasted without formatting for \(label).",
                permissionRecovery: .accessibility
            )
        case .undo:
            runCommand(
                executablePath: "/usr/bin/osascript",
                arguments: [
                    "-e",
                    "tell application \"System Events\" to keystroke \"z\" using command down"
                ],
                label: label,
                successMessage: "Undid the last action for \(label).",
                permissionRecovery: .accessibility
            )
        case .redo:
            runCommand(
                executablePath: "/usr/bin/osascript",
                arguments: [
                    "-e",
                    "tell application \"System Events\" to keystroke \"z\" using {command down, shift down}"
                ],
                label: label,
                successMessage: "Redid the last action for \(label).",
                permissionRecovery: .accessibility
            )
        case .mute:
            runCommand(
                executablePath: "/usr/bin/osascript",
                arguments: [
                    "-e",
                    "set volume output muted not (output muted of (get volume settings))"
                ],
                label: label,
                successMessage: "Toggled mute for \(label)."
            )
        case .mediaPlayPause:
            runCommand(
                executablePath: "/usr/bin/osascript",
                arguments: ["-e", "tell application \"Music\" to playpause"],
                label: label,
                successMessage: "Toggled media playback for \(label).",
                permissionRecovery: .automation(target: "Music")
            )
        case .mediaNextTrack:
            runCommand(
                executablePath: "/usr/bin/osascript",
                arguments: ["-e", "tell application \"Music\" to next track"],
                label: label,
                successMessage: "Skipped to the next track for \(label).",
                permissionRecovery: .automation(target: "Music")
            )
        case .mediaPreviousTrack:
            runCommand(
                executablePath: "/usr/bin/osascript",
                arguments: ["-e", "tell application \"Music\" to previous track"],
                label: label,
                successMessage: "Returned to the previous track for \(label).",
                permissionRecovery: .automation(target: "Music")
            )
        case .volumeUp:
            runCommand(
                executablePath: "/usr/bin/osascript",
                arguments: [
                    "-e",
                    "set currentVolume to output volume of (get volume settings)\n"
                        + "set volume output volume (currentVolume + 6)"
                ],
                label: label,
                successMessage: "Raised volume for \(label)."
            )
        case .volumeDown:
            runCommand(
                executablePath: "/usr/bin/osascript",
                arguments: [
                    "-e",
                    "set currentVolume to output volume of (get volume settings)\n"
                        + "set volume output volume (currentVolume - 6)"
                ],
                label: label,
                successMessage: "Lowered volume for \(label)."
            )
        case .toggleWiFi:
            toggleWiFi(label: label)
        case .launchApp:
            guard !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                feedbackMessage = "\(label) needs an application name."
                return
            }
            runCommand(
                executablePath: "/usr/bin/open",
                arguments: ["-a", urlString],
                label: label,
                successMessage: "Launched \(urlString) for \(label)."
            )
        case .openURL:
            guard let url = URL(string: urlString),
                  let scheme = url.scheme,
                  ["http", "https"].contains(scheme.lowercased()) else {
                feedbackMessage = "\(label) needs a valid http or https URL."
                return
            }
            let opened = NSWorkspace.shared.open(url)
            feedbackMessage = opened
                ? "Opened URL for \(label)."
                : "macOS could not open the URL for \(label)."
        case .runShortcut:
            guard !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                feedbackMessage = "\(label) needs a Shortcut name."
                return
            }
            runCommand(
                executablePath: "/usr/bin/shortcuts",
                arguments: ["run", urlString],
                label: label,
                successMessage: "Ran Shortcut \(urlString) for \(label).",
                permissionRecovery: .automation(target: "Shortcuts"),
                missingResourceMessage: "Shortcut \(urlString) was not found. Refresh the list or enter another name."
            )
        }
    }

    private func toggleWiFi(label: String) {
        feedbackMessage = "Checking Wi‑Fi…"
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let ports = await LocalCommandRunner.capture(
                executablePath: "/usr/sbin/networksetup",
                arguments: ["-listallhardwareports"]
            )
            guard ports.succeeded,
                  let device = Self.wifiDevice(from: ports.stdout) else {
                self.feedbackMessage = "Could not find the Wi‑Fi network interface for \(label)."
                return
            }

            let status = await LocalCommandRunner.capture(
                executablePath: "/usr/sbin/networksetup",
                arguments: ["-getairportpower", device]
            )
            guard status.succeeded,
                  let isEnabled = Self.wifiIsEnabled(from: status.stdout) else {
                self.feedbackMessage = "Could not read the Wi‑Fi state for \(label)."
                return
            }

            let target = isEnabled ? "off" : "on"
            let update = await LocalCommandRunner.capture(
                executablePath: "/usr/sbin/networksetup",
                arguments: ["-setairportpower", device, target]
            )
            guard update.succeeded else {
                self.feedbackMessage = "Could not turn Wi‑Fi \(target) for \(label)."
                return
            }

            self.permissionRecovery = nil
            self.feedbackMessage = target == "on"
                ? "Turned Wi‑Fi on for \(label)."
                : "Turned Wi‑Fi off for \(label)."
        }
    }

    private static func wifiDevice(from output: String) -> String? {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard lines.count > 1 else {
            return nil
        }

        for index in 0..<(lines.count - 1) {
            let port = lines[index].lowercased()
            guard port.contains("hardware port: wi-fi")
                    || port.contains("hardware port: wifi")
                    || port.contains("hardware port: airport") else {
                continue
            }

            let parts = lines[index + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "device" else {
                continue
            }
            let device = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            return device.isEmpty ? nil : device
        }
        return nil
    }

    private static func wifiIsEnabled(from output: String) -> Bool? {
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].lowercased().contains("power") else {
                continue
            }
            switch parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "on":
                return true
            case "off":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private func runCommand(
        executablePath: String,
        arguments: [String],
        label: String,
        successMessage: String,
        permissionRecovery: PermissionRecovery? = nil,
        missingResourceMessage: String? = nil
    ) {
        feedbackMessage = "Running \(label)…"
        Task { @MainActor [weak self] in
            let result = await LocalCommandRunner.capture(
                executablePath: executablePath,
                arguments: arguments
            )
            guard let self else {
                return
            }
            if result.succeeded {
                self.permissionRecovery = nil
                self.feedbackMessage = successMessage
            } else if self.isMissingShortcut(
                recovery: permissionRecovery,
                stderr: result.stderr
            ), let missingResourceMessage {
                self.permissionRecovery = nil
                self.feedbackMessage = missingResourceMessage
            } else {
                self.permissionRecovery = permissionRecovery
                self.feedbackMessage = permissionRecovery == nil
                    ? "\(label) failed or needs a macOS permission."
                    : "\(label) failed. Check the required macOS permission, then try again."
            }
        }
    }

    private func isMissingShortcut(
        recovery: PermissionRecovery?,
        stderr: String
    ) -> Bool {
        guard case .automation(target: "Shortcuts") = recovery else {
            return false
        }
        let normalized = stderr.lowercased()
        return normalized.contains("find shortcut")
            || normalized.contains("shortcut not found")
    }

    private func loadedSideProfile() -> TapSideProfile? {
        if let data = settings.sideProfileData,
           let profile = try? JSONDecoder().decode(TapSideProfile.self, from: data),
           profile.isUsable {
            return profile
        }
        return .bundledDefault
    }

    private func hasInputMonitoringAccess() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    private func registerLifecycleObservers() {
        let center = NSWorkspace.shared.notificationCenter
        lifecycleObserverStore.tokens = [
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleWillSleep()
                }
            },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleDidWake()
                }
            },
            center.addObserver(
                forName: NSWorkspace.screensDidSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleDisplaySleep()
                }
            },
            center.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleDisplayWake()
                }
            },
        ]
    }

    private func handleWillSleep() {
        guard settings.enabled, reader != nil else {
            return
        }
        reconnectTask?.cancel()
        reconnectTask = nil
        stopReaderOnly()
        readerStatus = SensorReaderStatus(
            phase: .stopped,
            message: "Recognition paused while the Mac is sleeping."
        )
        feedbackMessage = "Recognition paused for sleep; it will reconnect after wake."
    }

    private func handleDisplaySleep() {
        guard settings.enabled, reader != nil else {
            return
        }
        reconnectTask?.cancel()
        reconnectTask = nil
        stopReaderOnly()
        readerStatus = SensorReaderStatus(
            phase: .stopped,
            message: "Recognition paused while the display is sleeping."
        )
        feedbackMessage = "Recognition paused for display sleep; it will reconnect when the display wakes."
    }

    private func handleDidWake() {
        guard settings.enabled else {
            return
        }
        wakeTask?.cancel()
        feedbackMessage = "Reconnecting to the motion sensors…"
        wakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard let self, self.settings.enabled else {
                return
            }
            self.start()
        }
    }

    private func handleDisplayWake() {
        handleDidWake()
    }

    private func saveAndRestartIfNeeded() {
        settings.save()
        if settings.enabled {
            start()
        }
    }

    private func stopReaderOnly() {
        refreshTask?.cancel()
        refreshTask = nil
        reader?.stop()
        reader = nil
        runtime = nil
    }

    private func startRefreshTask() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, let runtime = self.runtime else { continue }
                let snapshot = runtime.snapshot()
                self.calibrationProgress = snapshot.calibrationProgress
                self.accelerometerSampleCount = snapshot.accelerometerSampleCount
                self.gyroscopeSampleCount = snapshot.gyroscopeSampleCount
                if let profile = snapshot.calibrationProfile {
                    self.calibrationProfile = profile
                }
            }
        }
    }
}

@main
private struct TapApp: App {
    @State private var model = TapAppModel()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(model)
                .frame(width: 360)
        } label: {
            Label("Tap", systemImage: "hand.tap")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 620, height: 560)
        }
    }
}

private struct MenuBarView: View {
    @Environment(TapAppModel.self) private var model

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { model.settings.enabled },
            set: { model.setEnabled($0) }
        )
    }

    private var sensitivityBinding: Binding<SensitivityMode> {
        Binding(
            get: { model.settings.sensitivityMode },
            set: { model.updateSensitivity($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "hand.tap.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tap")
                        .font(.headline)
                    Text("MacBook gestures")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusBadge(title: model.phaseTitle, color: model.phaseColor)
            }

            Toggle("Recognition enabled", isOn: enabledBinding)

            if model.settings.enabled {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Sensitivity")
                        Spacer()
                        Text(model.currentThresholdText)
                            .foregroundStyle(.secondary)
                    }
                    Picker("Sensitivity", selection: sensitivityBinding) {
                        ForEach(SensitivityMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)

                    if model.settings.sensitivityMode == .custom {
                        Slider(
                            value: Binding(
                                get: { model.customThreshold },
                                set: { model.customThreshold = $0 }
                            ),
                            in: 0.02...0.50,
                            step: 0.01
                        )
                        Text("Try 0.02–0.03 g for very light palm-rest taps; false positives may increase.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Status")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if model.readerStatus.openedDeviceCount > 0 {
                        Text("\(model.readerStatus.openedDeviceCount) sensors")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(model.feedbackMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.permissionRecovery != nil {
                    PermissionRecoveryRow()
                }
                if model.readerStatus.phase == .noSensors || model.readerStatus.phase == .failed {
                    Button("Retry sensor access") {
                        model.retrySensorAccess()
                    }
                    .buttonStyle(.borderless)
                }
                if model.settings.enabled && model.calibrationProgress < 1 {
                    ProgressView(value: model.calibrationProgress)
                    Text("Starting \(Int(model.calibrationProgress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(model.sideCalibrationMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.sideCalibration.isActive {
                    Button("Cancel side calibration") {
                        model.cancelSideCalibration()
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button("Calibrate left/right palm rests…") {
                        model.beginSideCalibration()
                    }
                    .buttonStyle(.borderless)
                }
                if let gesture = model.lastGesture {
                    Text("Last gesture: \(gesture.side.rawValue) · \(gesture.tapCount) \(gesture.tapCount == 1 ? "tap" : "taps")")
                        .font(.caption)
                }
            }

            HStack {
                Spacer()
                SettingsLink {
                    Text("Configure…")
                }
            }

            Divider()

            Button("Quit Tap") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(16)
        .task { model.startIfNeeded() }
    }
}

private struct SettingsView: View {
    @Environment(TapAppModel.self) private var model

    var body: some View {
        Form {
            Section("General") {
                Toggle(
                    "Recognition enabled",
                    isOn: Binding(
                        get: { model.settings.enabled },
                        set: { model.setEnabled($0) }
                    )
                )

                Toggle(
                    "Launch Tap at login",
                    isOn: Binding(
                        get: { model.launchAtLoginEnabled },
                        set: { model.setLaunchAtLogin($0) }
                    )
                )
                .disabled(model.launchAtLoginState == .unavailable)

                Text(model.launchAtLoginState.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.launchAtLoginState == .needsApproval {
                    Button("Open Login Items settings") {
                        model.openLoginItemsSettings()
                    }
                }
            }

            Section("Detection") {
                Picker(
                    "Sensitivity",
                    selection: Binding(
                        get: { model.settings.sensitivityMode },
                        set: { model.updateSensitivity($0) }
                    )
                ) {
                    ForEach(SensitivityMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                if model.settings.sensitivityMode == .custom {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { model.customThreshold },
                                set: { model.customThreshold = $0 }
                            ),
                            in: 0.02...0.50,
                            step: 0.01
                        )
                        Text(String(format: "%.2f g", model.customThreshold))
                            .monospacedDigit()
                            .frame(width: 55, alignment: .trailing)
                    }
                    Text("Try 0.02–0.03 g for very light palm-rest taps; normal-motion false positives may increase.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Tap quietly measures a sensor baseline when it starts. No user calibration is required for first run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            }

            Section("Side detection") {
                LabeledContent("Side model", value: model.sideModelDescription)
                Text(model.sideCalibrationMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.sideCalibration.isActive {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Button("Cancel calibration") {
                            model.cancelSideCalibration()
                        }
                    }
                } else {
                    Button(
                        model.hasSavedSideProfile
                            ? "Recalibrate palm rests"
                            : "Calibrate palm rests"
                    ) {
                        model.beginSideCalibration()
                    }
                    Text("Keep the MacBook flat and tap different spots across each outlined palm rest five times when prompted. Tap stores derived motion features locally.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(GestureSlotID.allCases) { slot in
                    GestureSlotRow(slot: slot)
                }
            } header: {
                HStack {
                    Text("Gesture actions")
                    Spacer()
                    Text("Six local slots")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Diagnostics") {
                LabeledContent("Sensor state", value: model.phaseTitle)
                LabeledContent(
                    "Opened devices",
                    value: "\(model.readerStatus.openedDeviceCount)"
                )
                LabeledContent(
                    "Input Monitoring",
                    value: model.inputMonitoringPermissionGranted ? "Allowed" : "Required"
                )
                LabeledContent(
                    "Parsed reports",
                    value: "\(model.accelerometerSampleCount + model.gyroscopeSampleCount)"
                )
                LabeledContent(
                    "Parser errors",
                    value: "\(model.readerStatus.parseErrorCount)"
                )
                LabeledContent(
                    "Stored calibration",
                    value: model.storedCalibrationProfile == nil ? "No" : "Yes"
                )
                LabeledContent("Side model", value: model.sideModelDescription)
                if let candidate = model.lastCandidate {
                    LabeledContent(
                        "Last candidate",
                        value: String(format: "%@ · %.3fg", candidate.side.rawValue, candidate.peakDynamicAccelerationG)
                    )
                }
                if let gesture = model.lastGesture {
                    LabeledContent(
                        "Last gesture",
                        value: "\(gesture.side.rawValue) · \(gesture.tapCount) \(gesture.tapCount == 1 ? "tap" : "taps")"
                    )
                }
                Text(model.feedbackMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.permissionRecovery != nil {
                    PermissionRecoveryRow()
                }
                Divider()
                Button("Export redacted diagnostics…") {
                    model.exportDiagnostics()
                }
                Text("Exports sensor health and derived recognition status only; raw motion traces and shortcut names are not included.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            model.refreshLaunchAtLoginState()
            model.startIfNeeded()
        }
    }
}

private struct GestureSlotRow: View {
    @Environment(TapAppModel.self) private var model
    let slot: GestureSlotID

    var body: some View {
        HStack(spacing: 10) {
            Toggle(
                "Enable \(slot.title)",
                isOn: Binding(
                    get: { model.slotEnabled(slot) },
                    set: { model.updateSlotEnabled($0, for: slot) }
                )
            )
            .labelsHidden()
            .controlSize(.small)
            .help(model.slotEnabled(slot) ? "Disable \(slot.title)" : "Enable \(slot.title)")
            Text(slot.title)
                .frame(width: 130, alignment: .leading)
            Picker(
                "Action",
                selection: Binding(
                    get: { model.action(for: slot) },
                    set: { model.updateAction($0, for: slot) }
                )
            ) {
                ForEach(GestureActionCategory.allCases) { category in
                    Section(category.title) {
                        ForEach(
                            GestureAction.allCases.filter { $0.category == category }
                        ) { action in
                            Text(action.title).tag(action)
                        }
                    }
                }
            }
            .labelsHidden()
            .frame(width: 170)
            Button("Test") { model.test(slot: slot) }
                .buttonStyle(.borderless)
        }

        if model.action(for: slot) == .runShortcut {
            ShortcutParameterEditor(slot: slot)
        } else if model.action(for: slot).parameterPlaceholder != nil {
            TextField(
                model.parameterPlaceholder(for: slot),
                text: Binding(
                    get: { model.url(for: slot) },
                    set: { model.updateURL($0, for: slot) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .padding(.leading, 140)
        }
        if let permissionNote = model.permissionNote(for: slot) {
            HStack(spacing: 8) {
                Text(permissionNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if [.screenshot, .screenshotClipboard, .screenshotSelection].contains(model.action(for: slot)),
                   !model.screenRecordingPermissionGranted {
                    Button("Request access") {
                        model.requestScreenRecordingPermission()
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.leading, 140)
        }
    }
}

private struct ShortcutParameterEditor: View {
    @Environment(TapAppModel.self) private var model
    let slot: GestureSlotID

    var body: some View {
        let currentName = model.url(for: slot)

        HStack(spacing: 8) {
            TextField(
                model.parameterPlaceholder(for: slot),
                text: Binding(
                    get: { model.url(for: slot) },
                    set: { model.updateURL($0, for: slot) }
                )
            )
            .textFieldStyle(.roundedBorder)

            if !model.availableShortcuts.isEmpty {
                Picker(
                    "Shortcut",
                    selection: Binding(
                        get: { model.url(for: slot) },
                        set: { model.updateURL($0, for: slot) }
                    )
                ) {
                    Text("Choose…").tag("")
                    if !currentName.isEmpty,
                       !model.availableShortcuts.contains(currentName) {
                        Text("\(currentName) (saved)").tag(currentName)
                    }
                    ForEach(model.availableShortcuts, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }

            Button(model.isLoadingShortcuts ? "Loading…" : "Refresh") {
                model.loadShortcuts()
            }
            .disabled(model.isLoadingShortcuts)
        }
        .padding(.leading, 140)
    }
}

private struct PermissionRecoveryRow: View {
    @Environment(TapAppModel.self) private var model

    var body: some View {
        if let recovery = model.permissionRecovery {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.trianglebadge.exclamationmark")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(recovery.message)
                        .font(.caption)
                    if recovery == .inputMonitoring {
                        Button("Request Input Monitoring access") {
                            model.requestInputMonitoringPermission()
                        }
                        .buttonStyle(.borderless)
                    }
                    Button("Open Privacy & Security") {
                        model.openPermissionSettings()
                    }
                    .buttonStyle(.borderless)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct StatusBadge: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
    }
}
