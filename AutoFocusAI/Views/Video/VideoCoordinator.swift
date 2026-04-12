@preconcurrency import AVFoundation
import AutoFocusCore
import Foundation
import Observation

@MainActor
@Observable
final class VideoCoordinator {
	enum PreviewMode: Hashable {
		case original
		case output
		case comparison
	}

	let url: URL

	private let asset: AVAsset
	private let reframer = VideoReframer()
	private let originalItem: AVPlayerItem
	private var outputItem: AVPlayerItem?
	private var comparisonItem: AVPlayerItem?

	let player: AVPlayer

	var isProcessing = false
	var hasComparisonPreview = false
	var errorText: String?
	var previewMode: PreviewMode = .original {
		didSet {
			guard previewMode != oldValue else { return }
			updatePreviewMode()
		}
	}

	private var loopObserver: NSObjectProtocol?

	init(url: URL) {
		self.url = url
		self.asset = AVURLAsset(url: url)

		let playerItem = AVPlayerItem(asset: asset)
		self.originalItem = playerItem
		let player = AVPlayer(playerItem: playerItem)
		player.isMuted = true
		player.actionAtItemEnd = .none

		self.player = player
		self.installLoopObserver(for: playerItem)

		Task { await self.loadComparisonPreview() }
	}

	func play() {
		player.play()
	}

	func pause() {
		player.pause()
	}

	private func installLoopObserver(for item: AVPlayerItem) {
		if let loopObserver {
			NotificationCenter.default.removeObserver(loopObserver)
		}

		loopObserver = NotificationCenter.default.addObserver(
			forName: .AVPlayerItemDidPlayToEndTime,
			object: item,
			queue: .main
		) { [weak self] _ in
			self?.player.seek(to: .zero)
			self?.player.play()
		}
	}

	private func loadComparisonPreview() async {
		isProcessing = true
		defer { isProcessing = false }

		do {
			let analysis = try await reframer.analyze(asset: asset)
			async let outputItem = reframer.makeOutputPlayerItem(asset: asset, analysis: analysis)
			async let comparisonItem = reframer.makeComparisonPlayerItem(asset: asset, analysis: analysis)

			self.outputItem = try await outputItem
			self.comparisonItem = try await comparisonItem

			hasComparisonPreview = true
			errorText = nil
			updatePreviewMode()
		} catch {
			errorText = error.localizedDescription
		}
	}

	private func updatePreviewMode() {
		let item: AVPlayerItem = switch previewMode {
		case .original:
			originalItem
		case .output:
			outputItem ?? originalItem
		case .comparison:
			comparisonItem ?? originalItem
		}

		guard player.currentItem !== item else { return }

		let currentTime = player.currentTime()
		let shouldResumePlayback = player.rate != 0 || player.timeControlStatus != .paused

		installLoopObserver(for: item)
		player.replaceCurrentItem(with: item)

		Task { @MainActor [weak self] in
			guard let self else { return }
			await self.player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero)
			if shouldResumePlayback {
				self.player.play()
			}
		}
	}
}
