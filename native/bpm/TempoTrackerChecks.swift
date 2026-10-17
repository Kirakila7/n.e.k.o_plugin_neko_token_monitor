import Foundation

@main struct TempoTrackerChecks {
    static func signal(at t: Double, bpm: Double, alternating: Bool) -> Float {
        let period = 60 / bpm
        let beat = Int(floor(t / period))
        let within = t - Double(beat) * period
        let accent = alternating && beat % 2 == 1 ? 0.5 : 1.0
        let pulse = within < 0.16 ? accent * exp(-within * 28) *
            (0.72 * sin(2 * .pi * 72 * within) + 0.16 * sin(2 * .pi * 1200 * within)) : 0
        let background = 0.025 * sin(2 * .pi * 440 * t) + 0.008 * sin(2 * .pi * 183 * t)
        return Float(pulse + background)
    }
    static func render(_ tracker: TempoTracker, bpm: Double, rate: Double,
                       alternating: Bool, duration: Double, offset: Double = 0) {
        let chunk = 1024
        var index = 0
        let total = Int(rate * duration)
        var samples = [Float](repeating: 0, count: chunk)
        while index + chunk <= total {
            for j in 0..<chunk {
                samples[j] = signal(at: Double(index + j) / rate,
                                    bpm: bpm, alternating: alternating)
            }
            tracker.feed(samples: samples, sampleRate: rate, time: offset + Double(index) / rate)
            index += chunk
        }
    }
    static func main() {
        var failures = 0
        func check(_ ok: Bool, _ message: String) {
            if !ok { failures += 1; print("FAIL: \(message)") }
        }
        let start = ProcessInfo.processInfo.systemUptime
        for bpm in [40.0, 50.0, 80.0, 120.0, 160.0, 200.0] {
            for alternating in [false, true] {
                let tracker = TempoTracker()
                render(tracker, bpm: bpm, rate: 48000, alternating: alternating, duration: 12)
                let state = tracker.snapshot(at: 11.99)
                if bpm == 80 && !alternating {
                    for child in Mirror(reflecting: tracker).children {
                        if child.label == "onsetTimes" || child.label == "onsetCount" || child.label == "onsetWrite" || child.label == "beatAnchor" { print("diagnostic \(child.label ?? "")=\(child.value)") }
                    }
                }
                print("tempo=\(bpm) alternating=\(alternating) detected=\(state.bpm ?? 0) confidence=\(state.confidence) phase=\(state.phase) active=\(state.active)")
                check(state.active && abs((state.bpm ?? 0) - bpm) < 3, "\(bpm), alternating \(alternating)")
                check(state.phase >= 0 && state.phase < 1 && state.phase.isFinite, "phase range")
                let expectedPhase = 11.99 * bpm / 60 - floor(11.99 * bpm / 60)
                let phaseError = abs(state.phase - expectedPhase)
                check(min(phaseError, 1 - phaseError) < 0.15, "phase must follow real attack, not background tone")
                let paused = tracker.snapshot(at: 13.3)
                check(!paused.active && paused.phase == 0 && paused.amplitude == 0 && paused.bpm == nil, "stopped input expires")
                tracker.setManualBPM(111)
                let manual = tracker.snapshot(at: 11.99)
                check(manual.bpm == 111 && manual.active && manual.confidence == 1, "manual wins")
                tracker.reset()
                check(!tracker.snapshot(at: 12).active, "reset is inactive")
            }
        }
        let rateChange = TempoTracker()
        render(rateChange, bpm: 120, rate: 48000, alternating: false, duration: 6)
        render(rateChange, bpm: 80, rate: 44100, alternating: true, duration: 12, offset: 30)
        let changed = rateChange.snapshot(at: 41.99)
        print("rate/timestamp change bpm=\(changed.bpm ?? 0)")
        check(changed.active && abs((changed.bpm ?? 0) - 80) < 3, "sample rate and timestamp change")
        let steady = TempoTracker()
        var tone = [Float](repeating: 0, count: 1024)
        for block in 0..<469 {
            for j in tone.indices { tone[j] = Float(0.05 * sin(2 * .pi * 440 * Double(block * 1024 + j) / 48000)) }
            steady.feed(samples: tone, sampleRate: 48000, time: Double(block * 1024) / 48000)
        }
        let noBeat = steady.snapshot(at: 10)
        print("steady tone bpm=\(noBeat.bpm ?? 0) active=\(noBeat.active)")
        check(!noBeat.active, "steady tone must not become beat")
        let silent = TempoTracker()
        render(silent, bpm: 120, rate: 48000, alternating: true, duration: 8)
        let zeros = [Float](repeating: 0, count: 4800)
        for block in 0..<13 { silent.feed(samples: zeros, sampleRate: 48000, time: 8 + Double(block) * 0.1) }
        let silence = silent.snapshot(at: 9.3)
        check(!silence.active && silence.bpm == nil, "captured silence stops")
        print("elapsed_seconds=\(ProcessInfo.processInfo.systemUptime - start) failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
