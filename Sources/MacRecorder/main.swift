import AppKit
import Carbon.HIToolbox

// MARK: global hotkey (⌃⌥⌘R) — no extra permission needed
private var hotKeyAction: (() -> Void)?
private func installHotKey(_ action: @escaping () -> Void) {
    hotKeyAction = action
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        DispatchQueue.main.async { hotKeyAction?() }
        return noErr
    }, 1, &spec, nil, nil)
    var ref: EventHotKeyRef?
    RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(cmdKey | optionKey | controlKey),
                        EventHotKeyID(signature: OSType(0x4D52434B), id: 1),
                        GetApplicationEventTarget(), 0, &ref)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let recorder = Recorder()
    private var scope: RecordingScope = RecordingScope(
        rawValue: UserDefaults.standard.string(forKey: "scope") ?? "") ?? .fullScreen
    private var timer: Timer?
    private var startedAt: Date?
    private var busy = false
    private var window: NSWindow!
    private let bigButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let scopePopup = NSPopUpButton()

    func applicationDidFinishLaunching(_ notification: Notification) {
        recorder.onUnexpectedStop = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                let url = await self.recorder.stop()
                self.stopTimer()
                self.refresh()
                self.alert("Recording stopped unexpectedly", error.localizedDescription
                           + (url.map { "\n\nWhat was captured is saved at:\n\($0.path)" } ?? ""))
            }
        }
        installHotKey { [weak self] in self?.toggle() }
        buildWindow()
        refresh()
        if !CommandLine.arguments.contains("--selftest") {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        // Headless self-test: MacRecorder --selftest <seconds> [full|teams]
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest") {
            let secs = Double(args.dropFirst(i + 1).first ?? "") ?? 5
            if args.contains("teams") { scope = .teamsOnly }
            Task { @MainActor in
                do {
                    try await self.recorder.start(scope: self.scope)
                    print("recording…"); fflush(stdout)
                    try await Task.sleep(for: .seconds(secs))
                    let url = await self.recorder.stop()
                    print("saved: \(url?.path ?? "nil")")
                } catch { print("error: \(error.localizedDescription)") }
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: window + Dock
    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Mac Recorder"
        window.isReleasedWhenClosed = false
        window.center()

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        statusLabel.alignment = .center

        bigButton.bezelStyle = .rounded
        bigButton.controlSize = .large
        bigButton.font = .systemFont(ofSize: 17, weight: .semibold)
        bigButton.target = self
        bigButton.action = #selector(toggle)
        bigButton.keyEquivalent = "\r"
        bigButton.widthAnchor.constraint(equalToConstant: 220).isActive = true

        scopePopup.addItems(withTitles: ["Entire screen + all audio", "Teams windows + Teams audio only"])
        scopePopup.target = self
        scopePopup.action = #selector(scopeChanged)

        let folder = NSButton(title: "Open Recordings Folder", target: self, action: #selector(openFolder))
        folder.bezelStyle = .inline

        let stack = NSStackView(views: [icon, statusLabel, bigButton, scopePopup, folder])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window.contentView = stack
    }

    @objc func scopeChanged() {
        scope = scopePopup.indexOfSelectedItem == 1 ? .teamsOnly : .fullScreen
        UserDefaults.standard.set(scope.rawValue, forKey: "scope")
        refresh()
    }

    // Clicking the Dock icon brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    // Right-click the Dock icon → Start / Stop Recording.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu()
        let item = NSMenuItem(title: recorder.isRecording ? "Stop Recording" : "Start Recording",
                              action: #selector(toggle), keyEquivalent: "")
        item.target = self
        m.addItem(item)
        return m
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: actions
    @objc func toggle() {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false; refresh() }
            if recorder.isRecording {
                let url = await recorder.stop()
                stopTimer()
                if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } else {
                do {
                    try await recorder.start(scope: scope)
                    startTimer()
                } catch {
                    alert("Couldn't start recording", error.localizedDescription
                          + "\n\nIf this is a permissions problem, enable Mac Recorder under System Settings → Privacy & Security → Screen & System Audio Recording, then try again.")
                }
            }
        }
    }

    @objc func setScope(_ sender: NSMenuItem) {
        guard !recorder.isRecording, let s = RecordingScope(rawValue: sender.representedObject as? String ?? "") else { return }
        scope = s
        UserDefaults.standard.set(s.rawValue, forKey: "scope")
        refresh()
    }

    @objc func openFolder() { NSWorkspace.shared.open(Recorder.folder) }

    @objc func quit() {
        Task { @MainActor in
            if recorder.isRecording { await recorder.stop() }
            NSApp.terminate(nil)
        }
    }

    // MARK: UI
    private func startTimer() {
        startedAt = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    private func stopTimer() { timer?.invalidate(); timer = nil; startedAt = nil }

    private func refresh() {
        let recording = recorder.isRecording
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "chart.line.uptrend.xyaxis", accessibilityDescription: "Chart")
            b.title = ""
        }
        let elapsed = startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
        statusLabel.stringValue = busy ? "Working…" : recording ? String(format: "● Recording  %d:%02d", elapsed / 60, elapsed % 60) : "Ready"
        statusLabel.textColor = recording ? .systemRed : .secondaryLabelColor
        bigButton.title = recording ? "■  Stop Recording" : "●  Start Recording"
        bigButton.bezelColor = recording ? nil : .systemRed
        bigButton.contentTintColor = recording ? nil : .white
        scopePopup.selectItem(at: scope == .teamsOnly ? 1 : 0)
        scopePopup.isEnabled = !recording

        let menu = NSMenu()
        let main = NSMenuItem(title: recording ? "Stop Recording" : "Start Recording",
                              action: #selector(toggle), keyEquivalent: "r")
        main.keyEquivalentModifierMask = [.control, .option, .command]
        main.target = self
        menu.addItem(main)
        menu.addItem(.separator())
        for (s, title) in [(RecordingScope.fullScreen, "Entire screen + all audio"),
                           (RecordingScope.teamsOnly, "Teams windows + Teams audio only")] {
            let item = NSMenuItem(title: title, action: #selector(setScope(_:)), keyEquivalent: "")
            item.representedObject = s.rawValue
            item.state = (scope == s) ? .on : .off
            item.target = self
            item.isEnabled = !recording
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Recordings Folder", action: #selector(openFolder), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let q = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)
        statusItem.menu = menu
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
