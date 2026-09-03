// macOS audio backend (AVAudioEngine), port of VCL/SndOut.pas.
//
// The Windows original pushes 512-sample blocks to waveOut. This backend
// uses AVAudioPlayerNode with a main-thread timer that keeps a small lead of
// blocks scheduled ahead, so the simulation still advances on the main
// thread at real-time pace — exactly like the original's Synchronize design.
//
// Scheduling is based on the player's *actual* render position
// (playerTime.sampleTime), not on buffer-completion callbacks. Completion
// callbacks are delivered asynchronously on the main queue and can lag,
// which made the old pending-block counter overestimate the buffered audio
// and let the player underrun — heard as gaps between CW characters.

import AVFoundation
import MorseRunnerCore

/// AVAudioEngine-backed AudioBackend for macOS.
final class AVAudioBackend: AudioBackend, @unchecked Sendable {
    /// Created lazily so headless runs never touch CoreAudio. AVAudioPlayerNode
    /// init throws an uncatchable Objective-C exception when no audio output
    /// component is available (CI/headless), so it must not run eagerly.
    private lazy var engine = AVAudioEngine()
    private lazy var player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    /// Total samples scheduled to the player (main-thread only).
    private var scheduledSamples = 0
    /// Lead time in blocks (~46 ms each). Keep a single block queued so an
    /// Enter-key transmission starts within the requested 50 ms latency.
    /// A larger lead would make the response feel noticeably delayed.
    private let leadBlocks = 1
    /// Poll frequently enough that a newly entered callsign is picked up
    /// without adding a full 20 ms timer tick to the audio-buffer latency.
    private let fillInterval: TimeInterval = 0.001
    /// Silent fallback keeps the original two-ticks-per-block pacing; using
    /// the low-latency audio polling interval here would run the simulation
    /// much faster than real time.
    private let silentFillInterval: TimeInterval = 0.02
    private var timer: Timer?
    private var blockProvider: (() -> SampleArray)?

    /// Master output volume 0..1 applied to the player node.
    var playerVolume: Float = 1.0 {
        didSet { if playerReady { player.volume = playerVolume } }
    }

    var diagnostics: (engineRunning: Bool, playerPlaying: Bool, pending: Int) {
        (engine.isRunning, player.isPlaying, pendingBlockCount)
    }

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: Double(AudioConstants.defaultRate), channels: 1)!
    }

    func start(blockProvider: @escaping () -> SampleArray) {
        self.blockProvider = blockProvider
        scheduledSamples = 0

        setupPlayerIfNeeded()
        guard playerReady else {
            // No usable audio device: keep the timer running so the
            // simulation advances silently (same as SilentAudioBackend).
            let t = Timer(timeInterval: silentFillInterval, repeats: true) { [weak self] _ in
                self?.fillSilently()
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            return
        }

        do {
            try engine.start()
        } catch {
            NSLog("MorseRunner: audio engine failed to start: \(error)")
        }
        player.play()
        // prime the lead
        fill()
        let t = Timer(timeInterval: fillInterval, repeats: true) { [weak self] _ in
            self?.fill()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if playerReady {
            player.stop()
            engine.stop()
        }
        scheduledSamples = 0
    }

    /// Lazily attach the player node. Creating AVAudioPlayerNode can throw an
    /// Objective-C exception on machines without a usable audio output, which
    /// Swift cannot catch; deferring it to start() and keeping it optional
    /// lets headless runs proceed silently instead of crashing.
    private var playerReady = false

    private func setupPlayerIfNeeded() {
        guard !playerReady else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        playerReady = true
    }

    /// Number of 512-sample blocks currently queued but not yet played.
    private var pendingBlockCount: Int {
        let played = playedSamples
        let pendingSamples = max(0, scheduledSamples - played)
        return pendingSamples / AudioConstants.defaultBufSize
    }

    /// Actual play position in samples (0 when the render clock is unknown).
    private var playedSamples: Int {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else {
            return 0
        }
        return max(0, Int(playerTime.sampleTime))
    }

    private func fill() {
        guard playerReady else { return }
        guard let provider = blockProvider else { return }
        let target = leadBlocks * AudioConstants.defaultBufSize
        // Refill until the unplayed lead is back up to target.
        while scheduledSamples - playedSamples < target {
            let samples = provider()
            // Only full-size blocks carry audio; the warm-up [0] blocks are
            // dropped (the simulation clock still advances in getAudio).
            guard samples.count == AudioConstants.defaultBufSize else { break }
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)) else { break }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            if let channel = buffer.floatChannelData?[0] {
                for (i, s) in samples.enumerated() {
                    // The simulation produces 16-bit scale samples (maxOut
                    // ~20000 of 32767); normalize to -1..1 for float PCM.
                    // Without this every sample was clipped to full scale,
                    // making the output deafeningly loud.
                    channel[i] = max(-1, min(1, s / 32768.0))
                }
            }
            scheduledSamples += samples.count
            player.scheduleBuffer(buffer, at: nil, options: [])
        }
    }

    private func fillSilently() {
        guard let provider = blockProvider else { return }
        // one block = 512 samples at 11025 Hz ≈ 46.4 ms; with a 20 ms timer,
        // every second tick is close enough to real time.
        scheduledSamples += 1
        if scheduledSamples >= 2 {
            scheduledSamples = 0
            _ = provider()
        }
    }
}
