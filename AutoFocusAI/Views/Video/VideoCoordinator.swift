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
	private let isAccessingSecurityScopedURL: Bool
	private let originalItem: AVPlayerItem
	private var outputItem: AVPlayerItem?
	private var comparisonItem: AVPlayerItem?
	private var analysis: ReframingAnalysis?
	private var analysisTask: Task<ReframingAnalysis, Error>?
	private var outputItemTask: Task<Void, Never>?
	private var comparisonItemTask: Task<Void, Never>?

	let player: AVPlayer

	var isProcessing = false
	var processingProgress: ReframingProgress?
	var hasPreviewAnalysis = false
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
		self.isAccessingSecurityScopedURL = url.startAccessingSecurityScopedResource()
		self.asset = AVURLAsset(url: url)

		let playerItem = AVPlayerItem(asset: asset)
		self.originalItem = playerItem
		let player = AVPlayer(playerItem: playerItem)
		player.isMuted = true
		player.actionAtItemEnd = .none

		self.player = player
		self.installLoopObserver(for: playerItem)

		startAnalysisIfNeeded()
	}

	deinit {
		if isAccessingSecurityScopedURL {
			url.stopAccessingSecurityScopedResource()
		}
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

		let isAccessingOutputURL = outputURL.startAccessingSecurityScopedResource()
		defer {
			if isAccessingOutputURL {
				outputURL.stopAccessingSecurityScopedResource()
			}
		}

		isProcessing = true
		defer {
			isProcessing = false
			processingProgress = nil
		}

		do {
			let analysis = try await loadAnalysis()
			processingProgress = .init(stage: .buildingExport, fractionCompleted: 0)
			await Task.yield()

			try await reframer.export(asset: asset, analysis: analysis, outputURL: outputURL) { @MainActor [weak self] progress in
				self?.processingProgress = progress
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

	private func startAnalysisIfNeeded() {
		guard analysis == nil, analysisTask == nil else {
			hasPreviewAnalysis = analysis != nil
			return
		}

		isProcessing = true
		processingProgress = .init(stage: .poseDetection, fractionCompleted: 0)

		let task = Task<ReframingAnalysis, Error> { [asset, reframer] in
			try await reframer.analyze(asset: asset) { @MainActor [weak self] progress in
				self?.processingProgress = progress
			}
		}
		analysisTask = task

		Task { @MainActor [weak self] in
			guard let self else { return }

			do {
				let analysis = try await task.value
				self.analysis = analysis
				self.hasPreviewAnalysis = true
				self.errorText = nil
			} catch {
				self.errorText = error.localizedDescription
			}

			self.analysisTask = nil
			self.finishProcessingIfIdle()
		}
	}

	private func finishProcessingIfIdle() {
		guard analysisTask == nil, outputItemTask == nil, comparisonItemTask == nil else { return }
		isProcessing = false
		processingProgress = nil
	}

	private func loadAnalysis() async throws -> ReframingAnalysis {
		if let analysis {
			return analysis
		}

		startAnalysisIfNeeded()
		guard let analysisTask else {
			fatalError("Analysis task should exist when analysis is unavailable.")
		}
		return try await analysisTask.value
	}

	private func preparePreviewItemIfNeeded(for mode: PreviewMode) {
		switch mode {
		case .original:
			return
		case .output:
			guard outputItem == nil, outputItemTask == nil else { return }
			outputItemTask = Task { @MainActor [weak self] in
				guard let self else { return }
				defer {
					self.outputItemTask = nil
					self.finishProcessingIfIdle()
				}

				do {
					let analysis = try await self.loadAnalysis()
					self.isProcessing = true
					self.processingProgress = .init(stage: .buildingPreview, fractionCompleted: 0.95)

					let outputItem = AVPlayerItem(asset: self.asset)
					outputItem.videoComposition = try await self.reframer.makeOutputVideoComposition(asset: self.asset, analysis: analysis)
					self.processingProgress = .init(stage: .buildingPreview, fractionCompleted: 1)
					self.outputItem = outputItem
					self.errorText = nil
					if self.previewMode == .output {
						self.updatePreviewMode()
					}
				} catch {
					self.errorText = error.localizedDescription
				}
			}
		case .comparison:
			guard comparisonItem == nil, comparisonItemTask == nil else { return }
			comparisonItemTask = Task { @MainActor [weak self] in
				guard let self else { return }
				defer {
					self.comparisonItemTask = nil
					self.finishProcessingIfIdle()
				}

				do {
					let analysis = try await self.loadAnalysis()
					self.isProcessing = true
					self.processingProgress = .init(stage: .buildingPreview, fractionCompleted: 0.95)

					let comparisonAsset = try await VideoReframer.makeComparisonAsset(from: self.asset)
					self.processingProgress = .init(stage: .buildingPreview, fractionCompleted: 0.97)
					let comparisonItem = AVPlayerItem(asset: comparisonAsset)
					comparisonItem.videoComposition = try await self.reframer.makeComparisonVideoComposition(asset: comparisonAsset, analysis: analysis)
					self.processingProgress = .init(stage: .buildingPreview, fractionCompleted: 1)
					self.comparisonItem = comparisonItem
					self.errorText = nil
					if self.previewMode == .comparison {
						self.updatePreviewMode()
					}
				} catch {
					self.errorText = error.localizedDescription
				}
			}
		}
	}

	private func updatePreviewMode() {
		preparePreviewItemIfNeeded(for: previewMode)

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
