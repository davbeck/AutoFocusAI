import AutoFocusCore
import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class VideoCoordinator {
	enum OutputFormat: String, CaseIterable, Identifiable, Sendable {
		case maximum9By16
		case fullHDLandscape
		case fullHDVertical
		case custom

		var id: Self { self }

		var label: String {
			switch self {
			case .maximum9By16:
				"9:16 Max"
			case .fullHDLandscape:
				"1920 × 1080"
			case .fullHDVertical:
				"1080 × 1920"
			case .custom:
				"Custom"
			}
		}
	}

	enum PreviewMode: Hashable {
		case original
		case output
		case comparison
	}

	let url: URL

	private let asset: AVAsset
	private let isAccessingSecurityScopedURL: Bool
	private let originalItem: AVPlayerItem
	private var sourceAnalysisTask: Task<ReframingSourceAnalysis, Error>?
	private var outputItem: AVPlayerItem?
	private var comparisonItem: AVPlayerItem?
	private var analysis: ReframingAnalysis?
	private var analysisTask: Task<ReframingAnalysis, Error>?
	private var outputItemTask: Task<Void, Never>?
	private var comparisonItemTask: Task<Void, Never>?
	private var settingsUpdateTask: Task<Void, Never>?
	private var analysisGeneration = 0

	let player: AVPlayer

	var isProcessing = false
	var isExporting = false
	var processingProgress: ReframingProgress?
	var hasPreviewAnalysis = false
	var errorText: String?
	var outputSettingsErrorText: String?
	var outputFormat = OutputFormat.maximum9By16 {
		didSet {
			guard outputFormat != oldValue else { return }
			outputSettingsDidChange()
		}
	}

	var customOutputWidth = 1080 {
		didSet {
			guard customOutputWidth != oldValue, outputFormat == .custom else { return }
			outputSettingsDidChange()
		}
	}

	var customOutputHeight = 1920 {
		didSet {
			guard customOutputHeight != oldValue, outputFormat == .custom else { return }
			outputSettingsDidChange()
		}
	}

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

	var resolvedOutputDescription: String? {
		guard let renderSize = analysis?.renderSize else { return nil }
		return "\(Int(renderSize.width)) × \(Int(renderSize.height)) pixels"
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
		isExporting = true
		defer {
			isProcessing = false
			isExporting = false
			processingProgress = nil
		}

		do {
			let analysis = try await loadAnalysis()
			processingProgress = .init(stage: .buildingExport, fractionCompleted: 0)
			await Task.yield()

			try await currentReframer.export(asset: asset, analysis: analysis, outputURL: outputURL) { @MainActor [weak self] progress in
				self?.processingProgress = progress
			}

			errorText = nil
		} catch {
			errorText = Self.presentationText(for: error)
		}
	}

	private var selectedOutputSize: VideoOutputSize {
		switch outputFormat {
		case .maximum9By16:
			.maximum9By16
		case .fullHDLandscape:
			.fullHDLandscape
		case .fullHDVertical:
			.fullHDVertical
		case .custom:
			.fixed(width: customOutputWidth, height: customOutputHeight)
		}
	}

	private var currentReframer: VideoReframer {
		VideoReframer(configuration: .init(outputSize: selectedOutputSize))
	}

	private func outputSettingsDidChange() {
		settingsUpdateTask?.cancel()
		do {
			try selectedOutputSize.validate()
			outputSettingsErrorText = nil
		} catch {
			outputSettingsErrorText = Self.presentationText(for: error)
			invalidateReframingAnalysis()
			return
		}

		settingsUpdateTask = Task { @MainActor [weak self] in
			do {
				try await Task.sleep(for: .milliseconds(250))
			} catch {
				return
			}
			guard let self else { return }
			self.invalidateReframingAnalysis()
			self.startAnalysisIfNeeded()
		}
	}

	private func invalidateReframingAnalysis() {
		analysisGeneration += 1
		analysisTask?.cancel()
		analysisTask = nil
		outputItemTask?.cancel()
		outputItemTask = nil
		comparisonItemTask?.cancel()
		comparisonItemTask = nil
		analysis = nil
		outputItem = nil
		comparisonItem = nil
		hasPreviewAnalysis = false
		isProcessing = false
		processingProgress = nil
		updatePreviewMode()
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

		let sourceAnalysisTask: Task<ReframingSourceAnalysis, Error>
		if let existingTask = self.sourceAnalysisTask {
			sourceAnalysisTask = existingTask
		} else {
			let asset = asset
			let task = Task<ReframingSourceAnalysis, Error> { @MainActor [weak self] in
				try await VideoReframer().analyzeSource(asset: asset) { @MainActor [weak self] progress in
					self?.processingProgress = progress
				}
			}
			self.sourceAnalysisTask = task
			sourceAnalysisTask = task
		}

		let generation = analysisGeneration
		let reframer = currentReframer
		let task = Task<ReframingAnalysis, Error> { @MainActor [weak self] in
			let sourceAnalysis = try await sourceAnalysisTask.value
			return try await reframer.reframe(sourceAnalysis) { @MainActor [weak self] progress in
				guard self?.analysisGeneration == generation else { return }
				self?.processingProgress = progress
			}
		}
		analysisTask = task

		Task { @MainActor [weak self] in
			guard let self else { return }

			do {
				let analysis = try await task.value
				guard self.analysisGeneration == generation else { return }
				self.analysis = analysis
				self.hasPreviewAnalysis = true
				self.errorText = nil
				self.outputSettingsErrorText = nil
				self.updatePreviewMode()
			} catch is CancellationError {
				return
			} catch let error as VideoReframerError {
				guard self.analysisGeneration == generation else { return }
				switch error {
				case .invalidOutputSize, .outputSizeExceedsSource:
					self.outputSettingsErrorText = Self.presentationText(for: error)
				case .noVideoTrackFound, .noDetectedSubject, .unsupportedOutputFileType,
				     .exportSessionUnavailable, .exportFailed, .exportCancelled:
					self.errorText = Self.presentationText(for: error)
				}
			} catch {
				guard self.analysisGeneration == generation else { return }
				self.errorText = Self.presentationText(for: error)
			}

			guard self.analysisGeneration == generation else { return }
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
					outputItem.videoComposition = try await self.currentReframer.makeOutputVideoComposition(asset: self.asset, analysis: analysis)
					self.processingProgress = .init(stage: .buildingPreview, fractionCompleted: 1)
					self.outputItem = outputItem
					self.errorText = nil
					if self.previewMode == .output {
						self.updatePreviewMode()
					}
				} catch is CancellationError {
					return
				} catch {
					self.errorText = Self.presentationText(for: error)
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
					comparisonItem.videoComposition = try await self.currentReframer.makeComparisonVideoComposition(asset: comparisonAsset, analysis: analysis)
					self.processingProgress = .init(stage: .buildingPreview, fractionCompleted: 1)
					self.comparisonItem = comparisonItem
					self.errorText = nil
					if self.previewMode == .comparison {
						self.updatePreviewMode()
					}
				} catch is CancellationError {
					return
				} catch {
					self.errorText = Self.presentationText(for: error)
				}
			}
		}
	}

	private func updatePreviewMode() {
		if hasPreviewAnalysis {
			preparePreviewItemIfNeeded(for: previewMode)
		}

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

	private static func presentationText(for error: any Error) -> String {
		let nsError = error as NSError
		return [nsError.localizedDescription, nsError.localizedRecoverySuggestion]
			.compactMap(\.self)
			.joined(separator: " ")
	}
}
