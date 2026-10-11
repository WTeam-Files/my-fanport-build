import UIKit
import MetalKit
import GameController
import AVFAudio
import UniformTypeIdentifiers
import os

private func engineLog(_ message: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) {
    guard let message, let context else { return }
    let line = String(cString: message)
    let controller = Unmanaged<NativePortViewController>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { controller.appendLog(line) }
}

final class NativePortViewController: UIViewController, MTKViewDelegate, UIDocumentPickerDelegate {
    private var metalView: MTKView!
    private var queue: MTLCommandQueue?
    private let output = UITextView()
    private let controllerLabel = UILabel()
    private let fpsLabel = UILabel()
    private var lastFPSLabelUpdate: CFTimeInterval = 0
    private let launchButton = UIButton(type: .system)
    private let preloadLabel = UILabel()
    private let audioEngine = AVAudioEngine()
    private var audioSource: AVAudioSourceNode?
    private var displayLink: CADisplayLink?
    private var lastControllerPoll: CFTimeInterval?
    private var lines: [String] = []
    private var metrics: [String: String] = [:]
    private var logFile: URL?
    private let touchControls = TouchControlsView(frame: .zero)
    private let gyro = GyroInput()
    private let settingsButton = UIButton(type: .system)
    private let layoutButton = UIButton(type: .system)
    private let serverButton = UIButton(type: .system)
    private var engineStarted = false
    private var bootedPreset = GameSettings.shared.graphicsPreset
    private var bootedMode: GameMode?
    private let modePicker = UISegmentedControl(items: GameMode.allCases.map(\.title))
    private let modeDetail = UILabel()
    private var stableTimer: Timer?
    private var healthTimer: Timer?
    private var lastHealth: [UInt64] = [0, 0, 0, 0, 0, 0, 0]
    private var padProof: PGPadState?
    private var lastGameStatus: UInt32 = 999
    private var worldReadyAt: CFTimeInterval?
    private var tiltNeutral: Double?
    private var tiltSince: CFTimeInterval?
    private var tiltSmoothed: Double = 0
    private var touchControlsAvailable = false
    private var lastTouchInputTrace = ""
    private var movementProofStarted = false
    private var proofController: GCController?
    private var proofInputSamples = 0
    private var proofInputActive = false
    private var diagnosticsOverlay: UIStackView?
    #if targetEnvironment(simulator)
    private var simulatorKeys = Set<UIKeyboardHIDUsage>()
    override var canBecomeFirstResponder: Bool { true }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses { if let key = press.key { simulatorKeys.insert(key.keyCode) } }
        super.pressesBegan(presses, with: event)
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses { if let key = press.key { simulatorKeys.remove(key.keyCode) } }
        super.pressesEnded(presses, with: event)
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        simulatorKeys.removeAll()
        super.pressesCancelled(presses, with: event)
    }
    #endif

    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override func viewDidLoad() {
        super.viewDidLoad()
        UIApplication.shared.isIdleTimerDisabled = true
        let device = MTLCreateSystemDefaultDevice()
        metalView = MTKView(frame: .zero, device: device)
        queue = device?.makeCommandQueue()
        metalView.delegate = self
        metalView.clearColor = MTLClearColorMake(0.025, 0.025, 0.035, 1)
        metalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(metalView)

        let title = UILabel()
        title.text = "GTA V Port"
        title.font = .systemFont(ofSize: 34, weight: .bold)
        title.textColor = .white
        let subtitle = UILabel()
        subtitle.text = "Fan project · plays your own game files"
        subtitle.font = .preferredFont(forTextStyle: .subheadline)
        subtitle.textColor = .lightGray
        controllerLabel.text = "Controller: none connected"
        controllerLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        controllerLabel.textColor = .lightGray
        var play = UIButton.Configuration.filled()
        play.title = "Play"
        play.cornerStyle = .large
        play.buttonSize = .large
        launchButton.configuration = play
        launchButton.configurationUpdateHandler = { button in
            // Progress text (preparing assets, loading) shows on the disabled button.
            button.configuration?.title = button.isEnabled ? "Play" : button.title(for: .disabled) ?? "Loading…"
        }
        launchButton.addTarget(self, action: #selector(startEngine), for: .touchUpInside)
        output.isEditable = false
        output.isHidden = !ProcessInfo.processInfo.arguments.contains("--show-log")
        output.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        output.textColor = .white
        output.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        settingsButton.setTitle("Settings", for: .normal)
        settingsButton.setImage(UIImage(systemName: "gearshape"), for: .normal)
        settingsButton.addAction(UIAction { [weak self] _ in self?.showSettings() }, for: .touchUpInside)
        layoutButton.setTitle("Edit controls layout", for: .normal)
        layoutButton.setImage(UIImage(systemName: "hand.tap"), for: .normal)
        layoutButton.addAction(UIAction { [weak self] _ in self?.showLayoutEditor() }, for: .touchUpInside)
        serverButton.contentHorizontalAlignment = .leading
        serverButton.titleLabel?.numberOfLines = 0
        serverButton.addAction(UIAction { [weak self] _ in self?.askForGameFiles() }, for: .touchUpInside)
        updateServerStatus()
        // Debug/automation: --local-game-folder /path (a folder the app can already read) skips the picker.
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--local-game-folder"), index + 1 < ProcessInfo.processInfo.arguments.count {
            let folder = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[index + 1])
            if let problem = GameFolder.choose(folder) { appendLog("Game folder refused: " + problem) }
        }
        if GameFolder.isChosen { updateServerStatus() }
        else if !GameSettings.shared.assetServer.isEmpty { testAssetServer() }
        // Debug/automation: --game-mode story|sandbox picks the mode before Play.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--game-mode"), index + 1 < arguments.count {
            GameSettings.shared.gameMode = arguments[index + 1] == "story" ? .story : .sandbox
        }
        modePicker.accessibilityLabel = "Game mode"
        modePicker.overrideUserInterfaceStyle = .dark
        modePicker.addAction(UIAction { [weak self] _ in
            guard let self, self.modePicker.selectedSegmentIndex >= 0 else { return }
            GameSettings.shared.gameMode = GameMode.allCases[self.modePicker.selectedSegmentIndex]
            self.refreshModeChoice()
        }, for: .valueChanged)
        modeDetail.font = .preferredFont(forTextStyle: .footnote)
        modeDetail.textColor = .lightGray
        modeDetail.numberOfLines = 0
        refreshModeChoice()
        preloadLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        preloadLabel.textColor = .lightGray
        preloadLabel.numberOfLines = 0
        preloadLabel.isHidden = true
        // The log (when shown) takes the spare height; everything else hugs its content.
        for item in [title, subtitle, serverButton, modePicker, modeDetail, launchButton, settingsButton, layoutButton, preloadLabel, controllerLabel] as [UIView] {
            item.setContentHuggingPriority(.required, for: .vertical)
            item.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        let buttonsRow = UIStackView(arrangedSubviews: [settingsButton, layoutButton])
        buttonsRow.spacing = 24
        buttonsRow.alignment = .leading
        let stack = UIStackView(arrangedSubviews: [title, subtitle, serverButton, modePicker, modeDetail, launchButton, buttonsRow, preloadLabel, controllerLabel, output, spacer])
        stack.setCustomSpacing(20, after: subtitle)
        stack.setCustomSpacing(16, after: serverButton)
        diagnosticsOverlay = stack
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        fpsLabel.text = "— FPS"
        fpsLabel.isHidden = true
        fpsLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        fpsLabel.textColor = .white
        fpsLabel.textAlignment = .center
        fpsLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        fpsLabel.layer.cornerRadius = 6
        fpsLabel.clipsToBounds = true
        fpsLabel.isUserInteractionEnabled = false
        fpsLabel.accessibilityLabel = "Game frame rate"
        fpsLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fpsLabel)
        touchControls.translatesAutoresizingMaskIntoConstraints = false
        touchControls.isHidden = true
        touchControls.inputChanged = { [weak self] in self?.pollController() }
        touchControls.openSettings = { [weak self] in self?.showSettings() }
        view.addSubview(touchControls)
        NSLayoutConstraint.activate([
            touchControls.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            touchControls.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            touchControls.topAnchor.constraint(equalTo: view.topAnchor),
            touchControls.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        NSLayoutConstraint.activate([
            fpsLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            fpsLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            fpsLabel.widthAnchor.constraint(equalToConstant: 68),
            fpsLabel.heightAnchor.constraint(equalToConstant: 24)
        ])
        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            metalView.topAnchor.constraint(equalTo: view.topAnchor),
            metalView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        logFile = directory.appendingPathComponent("native-port.log")
        // Keep the previous run's log: after a crash it is the one worth sharing (Settings, Share log).
        let previous = directory.appendingPathComponent("native-port-previous.log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: logFile!, to: previous)
        try? Data().write(to: logFile!)
        appendLog("Native UIKit + Metal host. Engine compiled into the app; no WebView or JIT.")
        appendLog("Metal device: \(device?.name ?? "unavailable")")
        GameFolder.log = { [weak self] line in self?.appendLog(line) }
        // A game folder moved into Files › On My iPhone › GTA V Port is found without any picking.
        if GameFolder.findInAppFolder() { updateServerStatus() }
        NotificationCenter.default.addObserver(self, selector: #selector(lookForGameFiles), name: UIApplication.didBecomeActiveNotification, object: nil)
        displayLink = CADisplayLink(target: self, selector: #selector(pollController))
        // ProMotion screens only run above 60 Hz when the app asks: "Unlocked" asks for up to 120.
        if GameSettings.shared.frameRateCap == 0 {
            let top = Float(UIScreen.main.maximumFramesPerSecond)
            displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, top), maximum: top, preferred: top)
        }
        displayLink?.add(to: .main, forMode: .common)
        NotificationCenter.default.addObserver(self, selector: #selector(controllerChanged), name: .GCControllerDidDisconnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(controllerChanged), name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(releaseTouchControls), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(leftApp), name: UIApplication.didEnterBackgroundNotification, object: nil)
        if let recovery = GameSettings.shared.recoverFromFailedBoot() {
            appendLog("Previous launch on \(recovery.failed.title) did not finish; lowered to \(recovery.fallback.title)\(recovery.resetHeight.map { ", resolution \($0)p back to Auto" } ?? "").")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.explainRecovery(recovery) }
        }
        if ProcessInfo.processInfo.arguments.contains("--touch-controls-preview") {
            diagnosticsOverlay?.isHidden = true
            touchControlsAvailable = true
            fpsLabel.isHidden = false
            touchControls.isHidden = false
        }
        NotificationCenter.default.addObserver(self, selector: #selector(preloadChanged), name: .assetPreloadChanged, object: nil)
        // Continue an unfinished "Download all game files" after a relaunch.
        AssetPreloader.shared.resumeIfNeeded()
        if ProcessInfo.processInfo.arguments.contains("--preload-autostart") {
            // Debug: start the download without tapping (simulator checks).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if let message = AssetPreloader.shared.start() { self.appendLog("Preload refused: " + message) }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--open-layout-editor") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.showLayoutEditor() }
        }
        if ProcessInfo.processInfo.arguments.contains("--open-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.showSettings() }
        }
        if ProcessInfo.processInfo.arguments.contains("--boot-engine") {
            DispatchQueue.main.async { self.startEngine() }
        }
    }

    @objc private func preloadChanged() {
        let summary = AssetPreloader.shared.launchSummary
        preloadLabel.text = summary
        preloadLabel.isHidden = summary == nil
    }

    func appendLog(_ line: String) {
        NSLog("[native-port] %@", line)
        if line.hasPrefix("ASSET_WARM_PROGRESS ") {
            let parts = line.split(separator: " ")
            if parts.count >= 3 {
                let size = Double(parts[2]).map { String(format: "%.1f GB", $0 * 1048576 / 1_000_000_000) } ?? ""
                launchButton.setTitle("Preparing assets… \(parts[1])% · \(size)", for: .disabled); launchButton.setNeedsUpdateConfiguration()
            }
        }
        if line == "ASSET_WARM_COMPLETE" { launchButton.setTitle("Loading…", for: .disabled); launchButton.setNeedsUpdateConfiguration() }
        if line == "WORLD_READY", ProcessInfo.processInfo.arguments.contains("--capture-world") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 35) { PGCaptureNativeFrame("optimized-world") }
        }
        if line == "WORLD_READY", let i = ProcessInfo.processInfo.arguments.firstIndex(of: "--pad-script"), i + 1 < ProcessInfo.processInfo.arguments.count, !movementProofStarted {
            movementProofStarted = true
            runPadScript(ProcessInfo.processInfo.arguments[i + 1])
        }
        if line == "WORLD_READY", ProcessInfo.processInfo.arguments.contains("--verify-pad"), !movementProofStarted {
            movementProofStarted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.verifyVirtualPad() }
        }
        if line == "WORLD_READY", ProcessInfo.processInfo.arguments.contains("--verify-movement"), !movementProofStarted {
            movementProofStarted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.verifyMovement() }
        }
        if line == "WORLD_READY" { PGSetTargetingMode(Int32(GameSettings.shared.targetingMode)); if worldReadyAt == nil { worldReadyAt = CACurrentMediaTime() } }
        if line == "WORLD_READY", healthTimer == nil {
            // Every 10 s: memory, how often the memory guard held streaming back, and game-file reads.
            healthTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.logHealth() }
        }
        if line == "WORLD_READY", stableTimer == nil {
            // Three minutes in the world counts as a launch that fits in memory.
            stableTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { _ in GameSettings.shared.markBootStable() }
        }
        if line == "WORLD_READY" || line.contains("\"label\":\"First frame\"") {
            diagnosticsOverlay?.isHidden = true
            touchControlsAvailable = true
            fpsLabel.isHidden = false
        }
        if line.hasPrefix("Native boot stopped:") || line == "iOS could not reserve the engine memory." {
            audioEngine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            metalView.isPaused = true
        }
        if let logFile, let data = (line + "\n").data(using: .utf8),
           let handle = try? FileHandle(forWritingTo: logFile) {
            defer { try? handle.close() }
            do { try handle.seekToEnd(); try handle.write(contentsOf: data) } catch {}
        }
        for key in ["[wgpu] fps:", "[wgpu] draw costs", "Native frame costs:", "Phone memory:", "WORLD_READY"] where line.hasPrefix(key) {
            metrics[key] = line
            if let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]), let logFile {
                try? data.write(to: logFile.deletingLastPathComponent().appendingPathComponent("native-metrics.json"), options: .atomic)
            }
        }
        lines.append(line)
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        guard diagnosticsOverlay?.isHidden != true else { return }
        output.text = lines.joined(separator: "\n")
        if !output.text.isEmpty { output.scrollRangeToVisible(NSRange(location: output.text.utf16.count - 1, length: 1)) }
    }

    /// The launch screen asks for a mode once; after that it remembers it.
    private func refreshModeChoice() {
        let choice = GameSettings.shared.gameModeChoice
        modePicker.selectedSegmentIndex = choice.flatMap { GameMode.allCases.firstIndex(of: $0) } ?? UISegmentedControl.noSegment
        modeDetail.text = choice?.detail ?? "Choose Story mode or Sandbox to play."
        if !engineStarted { launchButton.isEnabled = choice != nil }
    }

    @objc private func startEngine() {
        if GameSettings.shared.gameModeChoice == nil {
            // Automated launches without a choice keep the old sandbox start.
            guard ProcessInfo.processInfo.arguments.contains("--boot-engine") else { return }
        }
        guard let path = EnginePaths.manifest else {
            appendLog("Asset manifest is missing from the app bundle.")
            return
        }
        metalView.isPaused = true
        metalView.delegate = nil
        // Dawn owns the drawable size from here; MTKView must not reset it on layout.
        metalView.autoResizeDrawable = false
        PGAttachMetalLayer(Unmanaged.passUnretained(metalView.layer).toOpaque())
        launchButton.isEnabled = false
        settingsButton.isHidden = true
        layoutButton.isHidden = true
        modePicker.isEnabled = false
        engineStarted = true
        let mode = GameSettings.shared.gameMode
        bootedMode = mode
        PGSetStartMode(Int32(mode.rawValue))
        appendLog("Game mode: \(mode.title)")
        bootedPreset = GameSettings.shared.graphicsPreset
        appendLog("Graphics: " + GraphicsConfiguration.apply(GameSettings.shared, screen: view.bounds.size))
        appendLog("Device: " + GameSettings.shared.tier.summary)
        GameSettings.shared.markBootStarted()
        launchButton.setTitle("Loading…", for: .disabled); launchButton.setNeedsUpdateConfiguration()
        appendLog("Native touch controls support held buttons, sprint and weapon selection.")
        startAudio()
        let (root, rootNote) = EnginePaths.filesRoot()
        if let rootNote { appendLog(rootNote) }
        if GameFolder.isChosen {
            guard let data = GameFolder.open() else {
                appendLog("The game folder on this iPhone can't be opened any more. Choose it again.")
                showWhenFree(title: "Game files not found", message: "The game folder was moved or deleted. Put it back in Files › On My iPhone › GTA V Port, or pick it again.")
                GameFolder.clear(); updateServerStatus(); launchButton.isEnabled = true; launchButton.setTitle("Play", for: .normal)
                return
            }
            PGSetLocalGameFolder(data.path)
        } else {
            PGSetAssetServer(GameSettings.shared.assetServer)
        }
        AssetPreloader.shared.engineRunning = true
        path.withCString { manifest in
            root.withCString { PGStartEngine(manifest, $0, engineLog, Unmanaged.passUnretained(self).toOpaque()) }
        }
    }

    private func verifyMovement() {
        let testController = GCController.withExtendedGamepad()
        guard let pad = testController.extendedGamepad else {
            appendLog("Movement proof needs the native touch controller.")
            return
        }
        appendLog("Movement proof: capturing the world before native controller input.")
        PGCaptureNativeFrame("movement-before")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.proofController = testController
            self.proofInputActive = true
            self.proofInputSamples = 0
            pad.leftThumbstick.setValueForXAxis(0, yAxis: 0.8)
            pad.rightThumbstick.setValueForXAxis(0.25, yAxis: 0)
            self.appendLog("Movement proof: native controller sticks active.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                self.proofInputActive = false
                self.appendLog("Movement proof: \(self.proofInputSamples) controller samples delivered to the engine.")
                pad.leftThumbstick.setValueForXAxis(0, yAxis: 0)
                pad.rightThumbstick.setValueForXAxis(0, yAxis: 0)
                self.proofController = nil
                PGCaptureNativeFrame("movement-after")
                self.appendLog("Movement proof: native controller sticks released.")
            }
        }
    }

    /// Debug: scripted controller input, "step;step;..." with steps "wait:<s>", "hold:<buttons>:<s>"
    /// (buttons: a b x y l1 r1 lt rt down up left right start rx+ rx- ry+ ry-, joined with +), "frame:<name>".
    /// Debug: --watch-memory <address> <length> logs which bytes change between pad-script frames.
    private var watchSnapshot: [UInt8]?
    private func watchMemory(_ label: String) {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--watch-memory"), i + 2 < args.count,
              let start = UInt64(args[i + 1]), let length = Int(args[i + 2]) else { return }
        var now = [UInt8](repeating: 0, count: length)
        guard now.withUnsafeMutableBytes({ PGDebugReadMemory(start, $0.baseAddress, UInt64(length)) }) else { return }
        if let before = watchSnapshot {
            var changes: [String] = []
            for k in 0..<length where before[k] != now[k] { changes.append("\(start + UInt64(k)):\(before[k])>\(now[k])") }
            appendLog("Memory watch \(label): \(changes.count) changed " + changes.prefix(400).joined(separator: " "))
        }
        watchSnapshot = now
    }
    private func runPadScript(_ script: String) {
        var at = 0.0
        for step in script.split(separator: ";") {
            let parts = step.split(separator: ":").map(String.init)
            switch parts.first {
            case "wait": at += Double(parts.count > 1 ? parts[1] : "1") ?? 1
            case "frame":
                let name = parts.count > 1 ? parts[1] : "script"
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { PGCaptureNativeFrame(name); self.appendLog("Pad script: frame \(name)"); self.watchMemory(name) }
            case "hold":
                var state = PGPadState(); var held = PadButtons()
                for name in (parts.count > 1 ? parts[1] : "").split(separator: "+") {
                    switch name {
                    case "a": held.insert(.a); case "b": held.insert(.b); case "x": held.insert(.x); case "y": held.insert(.y)
                    case "l1": held.insert(.l1); case "r1": held.insert(.r1); case "down": held.insert(.down); case "up": held.insert(.up)
                    case "left": held.insert(.left); case "right": held.insert(.right); case "start": held.insert(.start)
                    case "lt": state.leftTrigger = 1; case "rt": state.rightTrigger = 1
                    case "rx+": state.rightX = 1; case "rx-": state.rightX = -1; case "ry+": state.rightY = 1; case "ry-": state.rightY = -1
                    default: break
                    }
                }
                state.padButtons = held
                let duration = Double(parts.count > 2 ? parts[2] : "0.3") ?? 0.3
                let label = String(step)
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { self.padProof = state; self.appendLog("Pad script: \(label)") }
                at += duration
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { self.padProof = PGPadState() }
            default: break
            }
        }
        // Hand input back to the touch controls (and controller) when the script ends.
        DispatchQueue.main.asyncAfter(deadline: .now() + at + 0.5) { self.padProof = nil; self.appendLog("Pad script: done") }
    }

    /// Simulator proof that the engine accepts the virtual controller and
    /// that controller aiming locks on: walk, pick a gun from the wheel, aim.
    private func verifyVirtualPad() {
        func log(_ step: String) { appendLog("Pad proof: \(step); input device \(PGLastInputDevice()), targeting mode \(PGTargetingMode())") }
        func pad(_ build: (inout PGPadState) -> Void) -> PGPadState { var s = PGPadState(); build(&s); return s }
        let steps: [(Double, PGPadState?, String?, String?)] = [
            (0, PGPadState(), "before input", "pad-before"),
            (0.5, pad { $0.leftY = 0.8 }, nil, nil),
            (3.5, PGPadState(), "walked forward", "pad-moved"),
            // Weapon wheel: hold L1 and point the right stick at a slot.
            (4.5, pad { $0.padButtons = .l1 }, nil, nil),
            (5.3, pad { $0.padButtons = .l1; $0.rightX = 1 }, "wheel open, pointing right", "pad-wheel"),
            (6.3, PGPadState(), "wheel released", nil),
            (8.0, pad { $0.leftTrigger = 1 }, nil, nil),
            (9.2, pad { $0.leftTrigger = 1 }, "aim held", "pad-aim"),
            (9.4, pad { $0.leftTrigger = 1; $0.rightX = 0.35 }, nil, nil),
            (10.0, pad { $0.leftTrigger = 1; $0.rightTrigger = 1 }, nil, nil),
            (10.6, pad { $0.leftTrigger = 1; $0.rightTrigger = 1 }, "aim and fire", "pad-fire"),
            (11.5, PGPadState(), "released", nil)]
        for (time, state, message, frame) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + time) {
                if let state { self.padProof = state }
                if let message { log(message) }
                if let frame { PGCaptureNativeFrame(frame) }
            }
        }
    }

    private func startAudio() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setPreferredSampleRate(48000)
            try session.setActive(true)
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
            let source = AVAudioSourceNode(format: format) { _, _, count, audioBufferList in
                let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
                guard buffers.count >= 2, let left = buffers[0].mData, let right = buffers[1].mData else { return noErr }
                PGFillAudio(left.assumingMemoryBound(to: Float.self), right.assumingMemoryBound(to: Float.self), count)
                return noErr
            }
            audioSource = source
            audioEngine.attach(source)
            audioEngine.connect(source, to: audioEngine.mainMixerNode, format: format)
            #if targetEnvironment(simulator)
            // Simulator runs are silent unless --sound is passed (test runs play through the Mac's speakers).
            if !ProcessInfo.processInfo.arguments.contains("--sound") { audioEngine.mainMixerNode.outputVolume = 0 }
            #endif
            // Silent test runs on a phone.
            if ProcessInfo.processInfo.arguments.contains("--mute") { audioEngine.mainMixerNode.outputVolume = 0 }
            try audioEngine.start()
        } catch { appendLog("Native audio setup failed: \(error.localizedDescription)") }
    }

    @objc private func controllerChanged() { pollController() }

    // MARK: Game file server

    /// Back in the app (for example after moving the game folder in Files): look again.
    @objc private func lookForGameFiles() {
        guard !engineStarted, !GameFolder.isChosen || GameFolder.inAppFolder else { return }
        GameFolder.findInAppFolder()
        updateServerStatus()
    }
    /// Shows the server and whether it answers; Play needs a working server.
    private func updateServerStatus(_ status: String? = nil) {
        let server = GameSettings.shared.assetServer
        let text: String
        if GameFolder.inAppFolder { text = "Game files: \"\(GameFolder.name)\" in the GTA V Port folder ✓ (tap to change)" }
        else if GameFolder.isChosen { text = "Game files: \"\(GameFolder.name)\" on this iPhone ✓ (tap to change)" }
        else if server.isEmpty { text = "Game files: not set. Move your game folder into Files › On My iPhone › GTA V Port, or tap here." }
        else { text = "Game files: from \(server)\(status.map { " · " + $0 } ?? "")" }
        serverButton.setTitle(text, for: .normal)
        launchButton.isEnabled = (GameFolder.isChosen || !server.isEmpty) && !engineStarted
    }
    /// Where the game files come from: a folder on this iPhone, or a server (your computer).
    private func askForGameFiles() {
        guard !engineStarted else { return }
        let sheet = UIAlertController(title: "Where are your game files?", message: "Easiest: in the Files app, move your game folder into On My iPhone › GTA V Port. The app finds it there by itself.", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "I moved it into the GTA V Port folder", style: .default) { [weak self] _ in self?.checkAppFolder() })
        sheet.addAction(UIAlertAction(title: "Pick a folder on this iPhone", style: .default) { [weak self] _ in self?.pickGameFolder() })
        sheet.addAction(UIAlertAction(title: "My computer (server address)", style: .default) { [weak self] _ in self?.askForAssetServer() })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = serverButton
        present(sheet, animated: true)
    }
    private func pickGameFolder() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }
    private func checkAppFolder() {
        GameFolder.clear()
        if GameFolder.findInAppFolder() { updateServerStatus(); return }
        updateServerStatus()
        showWhenFree(title: "Game files not found", message: "There is no complete game folder in Files › On My iPhone › GTA V Port yet.\n\nOpen the Files app, find your game folder (the one with \"data\" and \"b\" inside), long-press it, tap Move, and choose On My iPhone › GTA V Port. If you got a .rar or .zip, unpack it first.")
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let folder = urls.first else { appendLog("Folder picker returned nothing."); return }
        serverButton.setTitle("Game files: checking the folder…", for: .normal)
        DispatchQueue.global(qos: .userInitiated).async {
            let problem = GameFolder.choose(folder)
            DispatchQueue.main.async {
                self.updateServerStatus()
                guard let problem else { return }
                self.appendLog("Game folder refused: " + problem)
                self.showWhenFree(title: "That folder can't be used", message: problem)
            }
        }
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { appendLog("Folder picker cancelled.") }
    /// Shows a message once nothing else (like the closing folder picker) is on screen; iOS drops
    /// alerts presented during another presentation.
    private func showWhenFree(title: String, message: String, attempt: Int = 0) {
        if (presentedViewController != nil || transitionCoordinator != nil) && attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.showWhenFree(title: title, message: message, attempt: attempt + 1) }
            return
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
    private func askForAssetServer() {
        let alert = UIAlertController(title: "Game file server", message: "The address of the computer that serves your own copy of the game files, for example https://my-pc.tailnet-name.ts.net", preferredStyle: .alert)
        alert.addTextField { field in
            field.text = GameSettings.shared.assetServer
            field.placeholder = "https://my-pc.tailnet-name.ts.net"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save and test", style: .default) { [weak self, weak alert] _ in
            GameFolder.clear()
            GameSettings.shared.assetServer = alert?.textFields?.first?.text ?? ""
            self?.testAssetServer()
        })
        present(alert, animated: true)
    }
    /// Checks that the server answers with the game's file list.
    private func testAssetServer() {
        var server = GameSettings.shared.assetServer
        while server.hasSuffix("/") { server.removeLast() }
        guard let url = URL(string: server + "/data/manifest.json"), url.scheme?.hasPrefix("http") == true else {
            updateServerStatus("not a valid address"); return
        }
        updateServerStatus("checking…")
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                if code == 200 { self?.updateServerStatus("connected ✓") }
                else if let error { self?.updateServerStatus("can't connect (\(error.localizedDescription))") }
                else { self?.updateServerStatus("answered \(code); is the address the folder with data/ and b/?") }
            }
        }.resume()
    }
    /// The popup after a launch that ran out of memory: what happened, what changed, and the way back.
    private func explainRecovery(_ recovery: GameSettings.BootRecovery) {
        let lowered = recovery.fallback != recovery.failed
        let title = lowered ? "Graphics lowered to \(recovery.fallback.title)" : "Resolution set back to Auto"
        var message = "The game closed while starting on \(recovery.failed.title)"
        if let height = recovery.resetHeight { message += " at \(height)p" }
        message += ". That usually means this setting needs more memory than iOS gives the app on this iPhone (about \(recovery.memoryLimitMB) MB)."
        message += lowered ? "\n\nThe game now starts on \(recovery.fallback.title)" : "\n\nThe game now starts at its usual resolution"
        message += recovery.resetHeight != nil && lowered ? " with Auto resolution." : "."
        message += " You can change this any time in Settings."
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        alert.addAction(UIAlertAction(title: "Share log", style: .default) { _ in
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let logs = ["native-port-previous.log", "native-port.log"].map { documents.appendingPathComponent($0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            let sheet = UIActivityViewController(activityItems: logs, applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = self.view
            self.present(sheet, animated: true)
        })
        alert.addAction(UIAlertAction(title: "Try \(recovery.failed.title) again", style: .destructive) { _ in
            GameSettings.shared.undoRecovery(recovery)
            self.appendLog("Kept \(recovery.failed.title) after the warning.")
        })
        present(alert, animated: true)
    }

    private func logHealth() {
        var vm = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        } == KERN_SUCCESS
        let used = ok ? Int(vm.phys_footprint / 1_048_576) : -1
        let available = Int(os_proc_available_memory() / 1_048_576)
        let free = available > 0 ? available : max(0, GameSettings.shared.tier.memoryLimitMB - used)
        var reads = [UInt64](repeating: 0, count: 6)
        reads.withUnsafeMutableBufferPointer { PGAssetHealth($0.baseAddress) }
        let now = [PGMemoryBudgetClamps()] + reads
        let d = zip(now, lastHealth).map { $0 &- $1 }
        lastHealth = now
        let avgMS = d[1] > 0 ? Double(d[6]) / Double(d[1]) / 1000 : 0
        appendLog(String(format: "Health: memory %d MB used, %d MB free · guard held back streaming %llu× · reads %llu (%.1f MB, avg %.1f ms, slow %llu, errors %llu) · %.0f FPS",
                         used, free, d[0], d[1], Double(d[2]) / 1_048_576, avgMS, d[5], d[3], PGRenderedFramesPerSecond()))
    }

    @objc private func leftApp() { if stableTimer?.isValid != false { GameSettings.shared.markBootInterrupted() } }

    /// The touch-controls layout editor (pre-game, or from Settings).
    private func showLayoutEditor() {
        let editor = ControlsLayoutEditorController()
        editor.modalPresentationStyle = .fullScreen
        editor.onDone = { [weak self] in
            self?.touchControls.updateVisibility()
            self?.appendLog("Controls layout saved (\(ControlsLayout.entries.count) customized controls).")
        }
        (presentedViewController ?? self).present(editor, animated: true)
    }
    private func showSettings() {
        guard presentedViewController == nil else { return }
        touchControls.reset()
        let controller = SettingsViewController(engineRunning: engineStarted, runningMode: bootedMode)
        controller.gameModeChanged = { [weak self] in self?.refreshModeChoice() }
        controller.resolutionChanged = { [weak self] in self?.applyLiveResolution() }
        controller.controlsChanged = { [weak self] in self?.touchControls.updateVisibility() }
        controller.editLayout = { [weak self] in self?.showLayoutEditor() }
        controller.targetingChanged = { PGSetTargetingMode(Int32(GameSettings.shared.targetingMode)) }
        present(UINavigationController(rootViewController: controller), animated: true)
    }
    /// The engine follows back-buffer size changes while running.
    private func applyLiveResolution() {
        guard engineStarted else { return }
        let settings = GameSettings.shared
        let (width, height) = GraphicsConfiguration.size(for: bootedPreset, renderHeight: settings.renderHeight, screen: view.bounds.size, matchScreenShape: settings.matchScreenShape)
        PGSetBackBufferSize(Int32(width), Int32(height))
        appendLog("Graphics: live resize to \(width)×\(height)")
    }
    @objc private func releaseTouchControls() {
        touchControls.reset(publish: false)
        gyro.setRunning(false, orientation: .landscapeRight)
        lastControllerPoll = nil
        #if targetEnvironment(simulator)
        simulatorKeys.removeAll()
        #endif
        PGUpdateVirtualPad(PGPadState())
    }
    @objc private func pollController() {
        guard UIApplication.shared.applicationState == .active else {
            touchControls.reset(publish: false)
            lastControllerPoll = nil
            PGUpdateVirtualPad(PGPadState())
            return
        }
        let now = CACurrentMediaTime()
        if now - lastFPSLabelUpdate >= 0.25 {
            let fps = PGRenderedFramesPerSecond()
            fpsLabel.text = fps > 0 ? String(format: "%.0f FPS", fps) : "— FPS"
            lastFPSLabelUpdate = now
        }
        let elapsed = lastControllerPoll.map { now - $0 } ?? (1.0 / 60.0)
        lastControllerPoll = now
        let gameStatus = PGGameStatus()
        if gameStatus != lastGameStatus {
            lastGameStatus = gameStatus
            appendLog("Game state: control \(gameStatus & 1 != 0 ? "off" : "on")\(gameStatus & 2 != 0 ? ", phone out" : "")\(gameStatus & 4 != 0 ? ", cutscene" : "")\(gameStatus & 8 != 0 ? ", warning screen" : "")\(gameStatus & 16 != 0 ? ", no player" : "")")
            if ProcessInfo.processInfo.arguments.contains("--capture-state") { PGCaptureNativeFrame("state-\(gameStatus)-\(Int(now))") }
        }
        if let padProof { PGUpdateVirtualPad(padProof); return }
        // Everything reaches the engine as its own controller, so controller
        // features (assisted aim, analog steering and throttle) apply.
        var state = PGPadState()
        var hasController = false
        if let controller = GCController.controllers().first(where: { $0.extendedGamepad != nil }), let pad = controller.extendedGamepad {
            state = PGPadState(gamepad: pad)
            hasController = true
            if diagnosticsOverlay?.isHidden != true { controllerLabel.text = "Controller: \(controller.vendorName ?? "Gamepad")" }
        } else if diagnosticsOverlay?.isHidden != true {
            controllerLabel.text = "Touch controls ready"
        }
        // With a controller connected the touch controls step aside (Settings › Touch controls).
        let touchActive = touchControlsAvailable && !(hasController && GameSettings.shared.hideTouchWithController)
        touchControls.isHidden = !touchActive
        var vehicle = touchActive ? PGCurrentTouchContext() : 0
        var pauseMenu = PGPauseMenuActive()
        // Debug: --preview-context <vehicle type + 1 | menu> to review a layout.
        let arguments = ProcessInfo.processInfo.arguments
        if let i = arguments.firstIndex(of: "--preview-context"), i + 1 < arguments.count {
            if arguments[i + 1] == "menu" { pauseMenu = true } else { vehicle = UInt32(arguments[i + 1]) ?? 0 }
        }
        // Debug: --context-after <seconds after WORLD_READY> <vehicle type + 1> simulates entering a vehicle.
        if let i = arguments.firstIndex(of: "--context-after"), i + 2 < arguments.count, let ready = worldReadyAt,
           let after = Double(arguments[i + 1]), now - ready > after { vehicle = UInt32(arguments[i + 2]) ?? vehicle }
        if touchActive {
            // Debug: --preview-prompt shows the Accept/Back prompt layout, --preview-phone the phone dock.
            var status = gameStatus
            if arguments.contains("--preview-prompt") { status |= 1 }
            if arguments.contains("--preview-phone") { status |= 2 }
            touchControls.characterSwitchEnabled = bootedMode == .story || arguments.contains("--preview-switch")
            touchControls.updateGameState(status)
            touchControls.updateContext(vehicle: vehicle, pauseMenu: pauseMenu)
            let touch = touchControls.padState(elapsed: elapsed)
            if ProcessInfo.processInfo.arguments.contains("--trace-touch-controls") {
                let sample = String(format: "Touch pad: buttons=%u move=%.2f,%.2f look=%.2f,%.2f triggers=%.2f,%.2f device=%d", touch.buttons, touch.leftX, touch.leftY, touch.rightX, touch.rightY, touch.leftTrigger, touch.rightTrigger, PGLastInputDevice())
                if sample != lastTouchInputTrace { lastTouchInputTrace = sample; appendLog(sample) }
            }
            state.merge(touch)
        }
        #if targetEnvironment(simulator)
        var keys = PGPadState()
        func held(_ key: UIKeyboardHIDUsage) -> Float { simulatorKeys.contains(key) ? 1 : 0 }
        keys.leftX = held(.keyboardD) - held(.keyboardA)
        keys.leftY = held(.keyboardW) - held(.keyboardS)
        keys.rightX = held(.keyboardRightArrow) - held(.keyboardLeftArrow)
        keys.rightY = held(.keyboardUpArrow) - held(.keyboardDownArrow)
        keys.leftTrigger = held(.keyboardZ); keys.rightTrigger = held(.keyboardX)
        let map: [(UIKeyboardHIDUsage, PadButtons)] = [(.keyboardSpacebar, .x), (.keyboardLeftShift, .a), (.keyboardF, .y), (.keyboardR, .b),
            (.keyboardQ, .r1), (.keyboardTab, .l1), (.keyboardV, .select), (.keyboardEscape, .start), (.keyboardE, .l3),
            (.keyboardReturnOrEnter, .a), (.keyboardDeleteOrBackspace, .b), (.keyboardI, .up), (.keyboardK, .down), (.keyboardJ, .left), (.keyboardL, .right)]
        var keyButtons = PadButtons()
        for (key, bit) in map where simulatorKeys.contains(key) { keyButtons.insert(bit) }
        keys.padButtons = keyButtons
        state.merge(keys)
        #endif
        // Optional gyro: phone rotation adds to the right stick.
        let settings = GameSettings.shared
        let onFoot = vehicle == 0
        let driving = touchControls.context.driving
        let tiltWanted = touchActive && driving && settings.tiltSteer != .off
        let gyroWanted = touchActive && ((settings.gyroAim != .off && !touchControls.flyingWithRightStick && touchControls.context != .menu) || tiltWanted)
        let orientation = view.window?.windowScene?.interfaceOrientation ?? .landscapeRight
        gyro.setRunning(gyroWanted, orientation: orientation)
        if tiltWanted, let angle = gyro.steeringAngle() {
            // The neutral angle is however the phone is held on entering.
            if tiltSince == nil { tiltSince = now }
            if tiltNeutral == nil, now - (tiltSince ?? now) > 0.15 { tiltNeutral = angle }
            if let neutral = tiltNeutral {
                var degrees = (angle - neutral) * 180 / .pi
                degrees = abs(degrees) < 1.5 ? 0 : degrees - copysign(1.5, degrees)
                let raw = max(-1, min(1, degrees / settings.tiltFullLock))
                let curved = copysign(pow(abs(raw), 1.4), raw)
                tiltSmoothed += (curved - tiltSmoothed) * min(1, elapsed / 0.06)
                let fadeIn = min(1, (now - (tiltSince ?? now) - 0.15) / 0.3)
                let tilt = Float(tiltSmoothed * max(0, fadeIn))
                if settings.tiltSteer == .full && abs(state.leftX) < 0.05 { state.leftX = tilt }
                else if settings.tiltSteer == .assist { state.leftX = max(-1, min(1, state.leftX + tilt * 0.6)) }
            }
        } else if !driving {
            tiltNeutral = nil; tiltSince = nil; tiltSmoothed = 0
        }
        if gyroWanted && settings.gyroAim != .off {
            let aiming = touchControls.aiming || state.leftTrigger > 0.1
            let active = aiming || (settings.gyroAim == .always && onFoot)
            let rate = gyro.rate(active: active, elapsed: elapsed)
            // About 2 rad/s of phone rotation is a full stick at sensitivity 1.
            let gain = 350 * settings.gyroSensitivity
            let invert: CGFloat = settings.gyroInvertY ? -1 : 1
            state.rightX = max(-1, min(1, state.rightX + TouchControlsView.lookAxis(rate.dx * gain)))
            state.rightY = max(-1, min(1, state.rightY - TouchControlsView.lookAxis(rate.dy * gain * invert)))
        }
        PGUpdateVirtualPad(state)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue?.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }
}
