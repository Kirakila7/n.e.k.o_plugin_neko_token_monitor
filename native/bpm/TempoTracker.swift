import Foundation

struct TempoState {
    let bpm: Double?
    let confidence: Double
    let phase: Double
    let active: Bool
    let amplitude: Double
}

/// A local, bounded-cost tempo/phase tracker. `feed.time` is the time of the
/// FIRST sample in its block. `snapshot.time` must use the same seconds clock.
/// Calls are serialized internally because audio capture and the panel render
/// callback normally run on different queues.
final class TempoTracker {
    private let lock = NSLock()
    private let envelopeRate = 100.0
    private let capacity = 1_024
    private var envelope = [Double](repeating: 0, count: 1_024)
    private var envelopeWrite = 0
    private var envelopeCount = 0
    private var onsetTimes = [Double](repeating: 0, count: 64)
    private var onsetWrite = 0
    private var onsetCount = 0

    private var rate = 0.0
    private var hpCoefficient = 0.0
    private var lpCoefficient = 0.0
    private var previousInput = 0.0
    private var highPassed = 0.0
    private var lowPassed = 0.0
    private var bucketSamples = 0
    private var bucketSize = 480
    private var lowSquares = 0.0
    private var wideSquares = 0.0
    private var previousLogEnergy = 0.0
    private var olderNovelty = 0.0
    private var previousNovelty = 0.0
    private var smoothedNovelty = 0.0
    private var noveltyMean = 0.0
    private var level = 0.0

    private var expectedNextTime: Double?
    private var lastProcessedTime: Double?
    private var lastSignalTime: Double?
    private var lastOnsetTime: Double?
    private var lastEstimateTime = -Double.infinity
    private var quietCleared = false
    private var automaticBPM: Double?
    private var automaticConfidence = 0.0
    private var pendingBPM: Double?
    private var pendingCount = 0
    private var manualBPM: Double?
    private var beatAnchor = 0.0

    func feed(samples: [Float], sampleRate: Double, time: Double) {
        guard !samples.isEmpty, sampleRate.isFinite, sampleRate >= 8_000,
              sampleRate <= 192_000, time.isFinite else { return }
        lock.lock()
        defer { lock.unlock() }

        // A seek, clock discontinuity, dropped long block, or sample-rate change
        // invalidates both filter history and the old song's beat grid.
        let discontinuity = expectedNextTime.map { abs(time - $0) > 0.25 } ?? false
        if rate != sampleRate || discontinuity {
            clearSignalState()
            rate = sampleRate
            bucketSize = max(1, Int((sampleRate / envelopeRate).rounded()))
            hpCoefficient = exp(-2 * Double.pi * 30 / sampleRate)
            lpCoefficient = 1 - exp(-2 * Double.pi * 220 / sampleRate)
            beatAnchor = time
        }
        let inverseRate = 1 / sampleRate
        for index in samples.indices {
            let value = Double(samples[index])
            let input = value.isFinite ? max(-4, min(4, value)) : 0
            highPassed = hpCoefficient * (highPassed + input - previousInput)
            previousInput = input
            lowPassed += lpCoefficient * (highPassed - lowPassed)
            lowSquares += lowPassed * lowPassed
            wideSquares += input * input
            bucketSamples += 1
            if bucketSamples >= bucketSize {
                consumeBucket(at: time + Double(index + 1) * inverseRate)
            }
        }
        expectedNextTime = time + Double(samples.count) * inverseRate
        lastProcessedTime = expectedNextTime
    }

    func snapshot(at time: Double) -> TempoState {
        lock.lock()
        defer { lock.unlock() }
        guard time.isFinite, let signalTime = lastSignalTime,
              time - signalTime <= 1.15,
              let processedTime = lastProcessedTime,
              time - processedTime <= 1.15 else {
            return TempoState(bpm: manualBPM, confidence: 0, phase: 0,
                              active: false, amplitude: 0)
        }
        let bpm = manualBPM ?? automaticBPM
        let confidence = manualBPM == nil ? automaticConfidence : 1.0
        guard let tempo = bpm, confidence >= 0.25 else {
            return TempoState(bpm: nil, confidence: confidence, phase: 0,
                              active: false, amplitude: 0)
        }
        // A steady tone is sound, but is not evidence of a continuing beat.
        if manualBPM == nil,
           lastOnsetTime.map({ time - $0 > max(1.15, 3 * 60 / tempo) }) ?? true {
            return TempoState(bpm: nil, confidence: 0, phase: 0,
                              active: false, amplitude: 0)
        }
        let cycles = (time - beatAnchor) * tempo / 60
        let phase = cycles - floor(cycles)
        return TempoState(bpm: tempo, confidence: confidence, phase: phase,
                          active: true, amplitude: min(1, 2 * sqrt(max(0, level))))
    }

    /// Manual calibration wins over the detector. Nil restores automatic mode.
    /// The musical range is 40...200 BPM; invalid values restore automatic mode.
    func setManualBPM(_ bpm: Double?) {
        lock.lock()
        defer { lock.unlock() }
        manualBPM = bpm.flatMap { $0.isFinite ? max(40, min(200, $0)) : nil }
        beatAnchor = lastOnsetTime ?? lastProcessedTime ?? 0
    }

    /// Clear captured audio and the beat grid, retaining manual calibration.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        clearSignalState()
        rate = 0
    }

    private func clearSignalState() {
        envelopeWrite = 0
        envelopeCount = 0
        onsetWrite = 0
        onsetCount = 0
        previousInput = 0
        highPassed = 0
        lowPassed = 0
        bucketSamples = 0
        lowSquares = 0
        wideSquares = 0
        previousLogEnergy = 0
        olderNovelty = 0
        previousNovelty = 0
        smoothedNovelty = 0
        noveltyMean = 0
        level = 0
        expectedNextTime = nil
        lastProcessedTime = nil
        lastSignalTime = nil
        lastOnsetTime = nil
        lastEstimateTime = -Double.infinity
        quietCleared = false
        automaticBPM = nil
        automaticConfidence = 0
        pendingBPM = nil
        pendingCount = 0
        beatAnchor = 0
    }

    private func consumeBucket(at time: Double) {
        let lowRMS = sqrt(lowSquares / Double(bucketSamples))
        let wideRMS = sqrt(wideSquares / Double(bucketSamples))
        lowSquares = 0
        wideSquares = 0
        bucketSamples = 0
        level += 0.2 * (wideRMS - level)
        if wideRMS > 0.001 {
            lastSignalTime = time
            quietCleared = false
        } else if !quietCleared, let signalTime = lastSignalTime,
                  time - signalTime > 1.15 {
            envelopeCount = 0
            onsetCount = 0
            automaticBPM = nil
            automaticConfidence = 0
            pendingBPM = nil
            pendingCount = 0
            lastOnsetTime = nil
            quietCleared = true
        }

        // Bass attack plus a smaller wide-band attack covers kick-less tracks.
        // Log compression prevents volume changes from dominating the estimate.
        let logEnergy = log1p(100 * lowRMS) + 0.25 * log1p(100 * wideRMS)
        let novelty = max(0, logEnergy - previousLogEnergy)
        previousLogEnergy = logEnergy
        noveltyMean += 0.025 * (novelty - noveltyMean)
        let onsetTime = time - 1 / envelopeRate
        if previousNovelty > olderNovelty, previousNovelty >= novelty,
           previousNovelty > max(0.07, 3 * noveltyMean),
           lastOnsetTime.map({ onsetTime - $0 >= 0.20 }) ?? true {
            let firstOnset = lastOnsetTime == nil
            lastOnsetTime = onsetTime
            onsetTimes[onsetWrite] = onsetTime
            onsetWrite = (onsetWrite + 1) % onsetTimes.count
            onsetCount = min(onsetTimes.count, onsetCount + 1)
            // Pull the grid gently toward nearby attacks. Off-beat attacks do
            // not immediately drag a correctly locked grid by half a beat.
            if let tempo = manualBPM ?? automaticBPM {
                if firstOnset { beatAnchor = onsetTime }
                let period = 60 / tempo
                let cycles = (onsetTime - beatAnchor) / period
                let error = (cycles - cycles.rounded()) * period
                if abs(error) < 0.24 * period { beatAnchor += 0.12 * error }
            }
        }
        olderNovelty = previousNovelty
        previousNovelty = novelty
        // A short smoothing tail makes fractional-bin periods (e.g. 160 BPM =
        // 37.5 envelope samples) correlate without falsely favoring 80 BPM.
        // The unsmoothed novelty above still supplies the precise attack times.
        smoothedNovelty += 0.45 * (novelty - smoothedNovelty)
        envelope[envelopeWrite] = smoothedNovelty
        envelopeWrite = (envelopeWrite + 1) % capacity
        envelopeCount = min(capacity, envelopeCount + 1)
        if manualBPM == nil, time - lastEstimateTime >= 0.5,
           envelopeCount >= 250, onsetCount >= 4 {
            lastEstimateTime = time
            estimate(at: time)
        }
    }

    private func envelopeValue(_ age: Int) -> Double {
        envelope[(envelopeWrite - 1 - age + capacity) % capacity]
    }

    private func onsetValue(_ age: Int) -> Double {
        onsetTimes[(onsetWrite - 1 - age + onsetTimes.count) % onsetTimes.count]
    }

    private func correlation(lag: Int, count: Int, mean: Double) -> Double {
        guard lag > 0, lag < count else { return 0 }
        var cross = 0.0
        var firstPower = 0.0
        var secondPower = 0.0
        for age in 0..<(count - lag) {
            let first = envelopeValue(age) - mean
            let second = envelopeValue(age + lag) - mean
            cross += first * second
            firstPower += first * first
            secondPower += second * second
        }
        let power = sqrt(firstPower * secondPower)
        return power > 1e-10 ? max(-1, min(1, cross / power)) : 0
    }

    private func intervalEvidence(period: Double, now: Double) -> Double {
        var score = 0.0
        var intervals = 0
        guard onsetCount >= 2 else { return 0 }
        for age in 0..<(onsetCount - 1) {
            let newer = onsetValue(age)
            let older = onsetValue(age + 1)
            if now - older > 8 { break }
            let interval = newer - older
            guard interval > 0 else { continue }
            var match = 0.0
            for multiple in 1...3 {
                let target = period * Double(multiple)
                let closeness = max(0, 1 - abs(interval - target) / (0.14 * target))
                let weight = multiple == 1 ? 1.0 : (multiple == 2 ? 0.35 : 0.15)
                match = max(match, weight * closeness)
            }
            score += match
            intervals += 1
        }
        return intervals > 0 ? score / Double(intervals) : 0
    }

    private func estimate(at time: Double) {
        let count = min(800, envelopeCount)
        var mean = 0.0
        for age in 0..<count { mean += envelopeValue(age) }
        mean /= Double(count)
        var bestLag = 0
        var bestScore = 0.0
        var bestCorrelation = 0.0
        var bestIntervals = 0.0
        // Shorter lags win equal scores. Consecutive onset intervals distinguish
        // strong/weak alternating beats from an erroneous half-tempo estimate.
        for lag in 30...150 {
            let corr = max(0, correlation(lag: lag, count: count, mean: mean))
            let intervals = intervalEvidence(period: Double(lag) / envelopeRate, now: time)
            var score = 0.72 * corr + 0.28 * intervals
            if let tempo = automaticBPM {
                let candidate = 60 * envelopeRate / Double(lag)
                if abs(candidate / tempo - 1) < 0.04 { score += 0.025 }
            }
            if score > bestScore + 0.002 {
                bestLag = lag
                bestScore = score
                bestCorrelation = corr
                bestIntervals = intervals
            }
        }
        guard bestLag > 0, bestCorrelation >= 0.22, bestScore >= 0.30 else {
            automaticConfidence *= 0.7
            return
        }
        let left = correlation(lag: bestLag - 1, count: count, mean: mean)
        let center = correlation(lag: bestLag, count: count, mean: mean)
        let right = correlation(lag: bestLag + 1, count: count, mean: mean)
        let denominator = left - 2 * center + right
        let offset = abs(denominator) > 1e-8
            ? max(-0.5, min(0.5, 0.5 * (left - right) / denominator)) : 0
        let candidate = max(40, min(200, 60 * envelopeRate / (Double(bestLag) + offset)))
        let confidence = min(1, max(0, (bestCorrelation - 0.15) / 0.7))
            * (0.65 + 0.35 * bestIntervals)

        if let tempo = automaticBPM, abs(candidate / tempo - 1) > 0.08 {
            if let pending = pendingBPM, abs(candidate / pending - 1) < 0.05 {
                pendingCount += 1
            } else {
                pendingBPM = candidate
                pendingCount = 1
            }
            guard pendingCount >= 3 else { return }
        }
        let oldTempo = automaticBPM
        let newTempo = oldTempo.map { abs(candidate / $0 - 1) < 0.08
            ? 0.8 * $0 + 0.2 * candidate : candidate } ?? candidate
        if let old = oldTempo {
            let cycles = (time - beatAnchor) * old / 60
            beatAnchor = time - (cycles - floor(cycles)) * 60 / newTempo
        } else {
            beatAnchor = lastOnsetTime ?? time
        }
        automaticBPM = newTempo
        automaticConfidence = confidence
        pendingBPM = nil
        pendingCount = 0
    }
}
