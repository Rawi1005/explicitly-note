import AVFoundation
import Foundation
import Observation

/// Plays pronunciation audio from a remote URL. A single shared player
/// is used so starting a new pronunciation always stops the previous
/// one — two streams never play at once.
@MainActor
@Observable
final class AudioPlayerService {
    private(set) var isPlaying = false
    private(set) var currentURL: URL?

    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?

    func play(url: URL) {
        stop()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stop()
            }
        }
        self.player = player
        currentURL = url
        isPlaying = true
        player.play()
    }

    func stop() {
        player?.pause()
        player = nil
        currentURL = nil
        isPlaying = false
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    /// Toggle helper for the speaker button.
    func toggle(url: URL) {
        if isPlaying && currentURL == url {
            stop()
        } else {
            play(url: url)
        }
    }
}
