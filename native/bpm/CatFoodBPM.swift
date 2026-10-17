import AppKit
import QuartzCore
import CoreGraphics
import Darwin

// Audio-only accessory application. No visible window, screen-frame output,
// network requests or retained audio; only scalar tempo state crosses to Python.
final class BPMApplication: NSObject, NSApplicationDelegate {
    private let tracker = TempoTracker()
    private let listener = AudioListener()
    private var args: [String: String] = [:]
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var lastCommand = ""
    private var status = "ready"
    private var error = ""
    private var manual: Double?
    private var epoch = CACurrentMediaTime()
    private var strength = 0.65
    private var stopping = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let raw = CommandLine.arguments
        var i = 1
        while i + 1 < raw.count { args[raw[i]] = raw[i+1]; i += 2 }
        guard args["--state"] != nil, args["--control"] != nil, args["--session"] != nil else {
            NSApp.terminate(nil); return
        }
        strength = Double(args["--strength"] ?? "0.65") ?? 0.65
        listener.onSamples = { [weak self] samples, rate, time in
            self?.tracker.feed(samples: samples, sampleRate: rate, time: time)
        }
        listener.onError = { [weak self] message in
            guard let self, self.manual == nil, !self.stopping else { return }
            self.status = "error"; self.error = message; self.tracker.reset()
        }
        let tick = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        timer = tick; RunLoop.main.add(tick, forMode: .common)
        if let value = args["--bpm"].flatMap(Double.init), (40...200).contains(value) {
            useManual(value)
        } else { startAudio() }
        writeState()
    }

    private func startAudio() {
        generation &+= 1
        let request = generation
        task?.cancel()
        manual = nil; tracker.setManualBPM(nil); tracker.reset(); error = ""
        status = "starting"
        task = Task { @MainActor [weak self] in
            guard let self, self.generation == request, !Task.isCancelled else { return }
            await self.listener.stop()
            guard self.generation == request, !Task.isCancelled else { return }
            if !CGPreflightScreenCaptureAccess() {
                self.status = "permission_required"
                self.writeState()
                _ = CGRequestScreenCaptureAccess()
                return
            }
            do {
                let started = try await self.listener.start()
                guard self.generation == request, !Task.isCancelled else { return }
                self.status = started ? "listening" : "ready"
            } catch {
                guard self.generation == request, !Task.isCancelled else { return }
                self.status = "error"; self.error = error.localizedDescription
            }
            self.writeState()
        }
    }

    private func useManual(_ bpm: Double) {
        generation &+= 1; task?.cancel(); task = nil
        let request = generation
        manual = bpm; epoch = CACurrentMediaTime(); status = "manual"; error = ""
        tracker.reset()
        task = Task { @MainActor [weak self] in
            guard let self, self.generation == request, !Task.isCancelled else { return }
            await self.listener.stop()
        }
    }

    private func readControl() {
        guard let path = args["--control"], let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = command["generation"] as? String, id != lastCommand,
              let action = command["action"] as? String else { return }
        lastCommand = id
        switch action {
        case "auto", "listen": startAudio()
        case "manual":
            if let bpm = command["bpm"] as? Double, bpm.isFinite, (40...200).contains(bpm) { useManual(bpm) }
        case "strength":
            if let value = command["strength"] as? Double, value.isFinite { strength = max(0, min(1, value)) }
        case "quit":
            stopping = true; status = "stopped"; generation &+= 1; task?.cancel()
            Task { @MainActor [weak self] in
                await self?.listener.stop(); self?.writeState(); NSApp.terminate(nil)
            }
        default: break
        }
    }

    private func tick() {
        if let parent = args["--parent"].flatMap(Int32.init), getppid() != parent || kill(parent, 0) != 0 {
            NSApp.terminate(nil); return
        }
        readControl()
        if status == "permission_required", CGPreflightScreenCaptureAccess() { startAudio() }
        writeState()
    }

    private func writeState() {
        guard let path = args["--state"] else { return }
        let now = CACurrentMediaTime()
        let tempo = tracker.snapshot(at: now)
        let bpm = manual ?? tempo.bpm
        let active = !stopping && strength > 0 && (manual != nil || (status == "listening" && tempo.active))
        let phase = manual != nil ? ((now - epoch) * manual! / 60).truncatingRemainder(dividingBy: 1) : tempo.phase
        let state: [String: Any] = [
            "session": args["--session"] ?? "", "pid": ProcessInfo.processInfo.processIdentifier,
            "generation": lastCommand, "capture_status": status, "error": error,
            "bpm": active ? bpm.map { $0 as Any } ?? NSNull() : NSNull(),
            "active": active, "phase": max(0, phase), "confidence": manual != nil ? 1 : tempo.confidence,
            "amplitude": active ? (manual != nil ? 0.6 : tempo.amplitude) : 0,
            "source": manual != nil ? "manual" : "system", "strength": strength,
            "updated_at": Date().timeIntervalSince1970
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate(); stopping = true; status = "stopped"; generation &+= 1; task?.cancel()
        writeState()
    }
}

@main struct Launcher {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = BPMApplication()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
