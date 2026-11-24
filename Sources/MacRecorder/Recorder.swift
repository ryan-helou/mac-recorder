import AppKit
import AVFoundation
import ScreenCaptureKit

enum RecordingScope: String {
    case fullScreen   // whole display + all system audio (works for Teams in browser too)
    case teamsOnly    // only Teams windows + only Teams audio
}

enum RecorderError: LocalizedError {
    case noDisplay
    case teamsNotRunning
    case micDenied

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display found to record."
        case .teamsNotRunning: return "Microsoft Teams isn't running. Open Teams, or switch to “Entire screen”."
        case .micDenied: return "Microphone access is off. Enable it in System Settings → Privacy & Security → Microphone."
        }
    }
}

/// Records screen video + system audio + microphone straight to an .mp4 using
/// ScreenCaptureKit's SCRecordingOutput (macOS 15+).
@MainActor
final class Recorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    static let folder: URL = {
        let url = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Call Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var finished = false
    private var finishWaiter: CheckedContinuation<Void, Never>?
    private var activity: NSObjectProtocol?

    private(set) var outputURL: URL?
    var isRecording: Bool { stream != nil }

    /// Called if capture dies on its own (e.g. display disconnected).
    var onUnexpectedStop: ((Error) -> Void)?

    func start(scope: RecordingScope) async throws {
        guard stream == nil else { return }

        // Microphone permission (Screen Recording permission is prompted by SCShareableContent).
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw RecorderError.micDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        let mouseDisplayID = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }?
            .deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == mouseDisplayID }) ?? content.displays.first
        else { throw RecorderError.noDisplay }

        let filter: SCContentFilter
        switch scope {
        case .fullScreen:
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        case .teamsOnly:
            let apps = content.applications.filter {
                $0.bundleIdentifier.hasPrefix("com.microsoft.teams")
            }
            guard !apps.isEmpty else { throw RecorderError.teamsNotRunning }
            filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        }

        // Size: native pixels, capped at 2560 on the long side, even dimensions.
        let info = SCShareableContent.info(for: filter)
        var w = info.contentRect.width * CGFloat(info.pointPixelScale)
        var h = info.contentRect.height * CGFloat(info.pointPixelScale)
        let cap: CGFloat = 2560
        if max(w, h) > cap { let s = cap / max(w, h); w *= s; h *= s }

        let cfg = SCStreamConfiguration()
        cfg.width = Int(w) & ~1
        cfg.height = Int(h) & ~1
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        cfg.showsCursor = true
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        cfg.captureMicrophone = true

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = Self.folder.appendingPathComponent("Call \(fmt.string(from: Date())).mp4")

        let rc = SCRecordingOutputConfiguration()
        rc.outputURL = url
        rc.outputFileType = .mp4
        rc.videoCodecType = .hevc

        let out = SCRecordingOutput(configuration: rc, delegate: self)
        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addRecordingOutput(out)

        finished = false
        try await stream.startCapture()

        self.stream = stream
        self.recordingOutput = out
        self.outputURL = url
        // Keep the Mac awake and the app un-throttled for the whole call.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Recording a call")
    }

    /// Stops and waits for the file to be finalized. Returns the file URL.
    @discardableResult
    func stop() async -> URL? {
        guard let stream else { return nil }
        let url = outputURL
        if !finished {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                self.finishWaiter = c
                Task { @MainActor in try? await stream.stopCapture() }
                // Safety net: never hang waiting for the finalize callback.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(8))
                    self.resumeWaiter()
                }
            }
        }
        cleanup()
        return url
    }

    private func cleanup() {
        stream = nil
        recordingOutput = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private func resumeWaiter() {
        finishWaiter?.resume()
        finishWaiter = nil
    }

    // MARK: SCRecordingOutputDelegate
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            self.finished = true
            self.resumeWaiter()
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            self.finished = true
            self.resumeWaiter()
            self.onUnexpectedStop?(error)
        }
    }

    // MARK: SCStreamDelegate
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.stream != nil, !self.finished else { return }
            self.onUnexpectedStop?(error)
        }
    }
}
