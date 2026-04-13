import AutoFocusCore
@preconcurrency import AVFoundation
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
	private var analysis: ReframingAnalysis?

	let player: AVPlayer

	var isProcessing = false
	var processingProgress: ReframingProgress?
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

	var suggestedExportFilename: String {
		"\(url.deletingPathExtension().lastPathComponent)-reframed.mov"
	}

	func export(to outputURL: URL) async {
		guard !isProcessing else { return }

		isProcessing = true
		processingProgress = .init(stage: .exporting, fractionCompleted: 0)
		defer {
			isProcessing = false
			processingProgress = nil
		}

		do {
			let analysis = try await loadAnalysis { [weak self] progress in
				await MainActor.run {
					self?.processingProgress = progress
				}
			}

			try await reframer.export(asset: asset, analysis: analysis, outputURL: outputURL) { [weak self] progress in
				await MainActor.run {
					self?.processingProgress = progress
				}
			}

			errorText = nil
		} catch {
			errorText = error.localizedDescription
		}
	}

	private func installLoopObserver(for item: AVPlayerItem) {
		if let loopObserver {
			NotificationCenter.default.removeObserver(loopObserver)
		}

		loopObserver = NotificationCenter.default.addObserver(
			forName: .AVPlayerItemDidPlayToEndTime,
			object: item,
			queue: .main,
		) { [weak self] _ in
			self?.player.seek(to: .zero)
			self?.player.play()
		}
	}

	private func loadComparisonPreview() async {
		isProcessing = true
		processingProgress = .init(stage: .poseDetection, fractionCompleted: 0)
		defer {
			isProcessing = false
			processingProgress = nil
		}

		do {
			let analysis = try await loadAnalysis { [weak self] progress in
				await MainActor.run {
					self?.processingProgress = progress
				}
			}
			processingProgress = .init(stage: .buildingPreview, fractionCompleted: 0.95)
			async let outputVideoComposition = reframer.makeOutputVideoComposition(asset: asset, analysis: analysis)
			let comparisonAsset = try await VideoReframer.makeComparisonAsset(from: asset)
			processingProgress = .init(stage: .buildingPreview, fractionCompleted: 0.97)
			async let comparisonVideoComposition = reframer.makeComparisonVideoComposition(asset: comparisonAsset, analysis: analysis)

			let outputItem = AVPlayerItem(asset: asset)
			outputItem.videoComposition = try await outputVideoComposition
			processingProgress = .init(stage: .buildingPreview, fractionCompleted: 0.985)
			self.outputItem = outputItem

			let comparisonItem = AVPlayerItem(asset: comparisonAsset)
			comparisonItem.videoComposition = try await comparisonVideoComposition
			processingProgress = .init(stage: .buildingPreview, fractionCompleted: 1)
			self.comparisonItem = comparisonItem

			hasComparisonPreview = true
			errorText = nil
			updatePreviewMode()
		} catch {
			errorText = error.localizedDescription
		}
	}

	private func loadAnalysis(
		progressHandler: VideoReframer.ProgressHandler? = nil,
	) async throws -> ReframingAnalysis {
		if let analysis {
			return analysis
		}

		let analysis = try await reframer.analyze(asset: asset, progressHandler: progressHandler)
		self.analysis = analysis
		return analysis
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
