import AVFoundation
import Observation

/// Plays a recording from any point, for History. One recording at a time: opening another
/// replaces it.
@MainActor @Observable
final class HistoryPlayer {
    private(set) var isPlaying = false
    /// Where the playhead is, in seconds. Zero until something has played.
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    /// Whether a recording is loaded, so the play bar has something to play.
    private(set) var isLoaded = false
    /// Set once playback has begun and until it is stopped, so the line being heard reads
    /// as playing while paused too.
    private(set) var hasStarted = false

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    func load(_ url: URL?) {
        stop()
        player = url.flatMap { try? AVAudioPlayer(contentsOf: $0) }
        duration = player?.duration ?? 0
        isLoaded = player != nil
    }

    /// Starts at `seconds`, a little early so the first word isn't clipped.
    func play(from seconds: Double) {
        guard let player else { return }
        player.currentTime = min(max(0, seconds - 0.15), max(0, duration - 0.01))
        resume()
    }

    func toggle() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            ticker?.cancel()
        } else {
            // Played to the end: start again from the top.
            if player.currentTime >= duration - 0.05 { player.currentTime = 0 }
            resume()
        }
    }

    /// Moves the playhead; keeps playing if it was.
    func seek(to seconds: Double) {
        guard let player else { return }
        player.currentTime = min(max(0, seconds), duration)
        currentTime = player.currentTime
    }

    func stop() {
        ticker?.cancel()
        player?.stop()
        player = nil
        isPlaying = false
        hasStarted = false
        isLoaded = false
        currentTime = 0
        duration = 0
    }

    private func resume() {
        guard let player else { return }
        player.play()
        isPlaying = true
        hasStarted = true
        currentTime = player.currentTime
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    // Reached the end: nothing is playing any more.
                    if player.currentTime == 0 || player.currentTime >= self.duration - 0.05 { self.hasStarted = false }
                    return
                }
            }
        }
    }
}
