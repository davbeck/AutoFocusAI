import AVFoundation
import CoreImage
import Foundation
import Vision

public struct ReframingConfiguration: Sendable {
	public var aspectRatio: CGSize
	public var renderSize: CGSize

	public init(
		aspectRatio: CGSize = ShotTracker.defaultAspectRatio,
		renderSize: CGSize = CGSize(width: 1080, height: 1920)
	) {
		self.aspectRatio = aspectRatio
		self.renderSize = renderSize
	}
}

public struct ReframingAnalysis: Sendable {
	public var sourceSize: CGSize
	public var renderSize: CGSize
	public var shotStates: [FrameData<ShotState>]

	public init(sourceSize: CGSize, renderSize: CGSize, shotStates: [FrameData<ShotState>]) {
		self.sourceSize = sourceSize
		self.renderSize = renderSize
		self.shotStates = shotStates
	}

	func interpolatedBounds(at compositionTime: CMTime) -> CGRect? {
		switch shotStates.binarySearch(for: compositionTime, transform: { $0.presentationTime }) {
		case .found(index: _, value: let frame):
			return frame.value.bounds
		case .insert(at: let index):
			guard !shotStates.isEmpty else { return nil }
			guard index != shotStates.startIndex else { return shotStates.first?.value.bounds }
			guard index != shotStates.endIndex else { return shotStates.last?.value.bounds }

			let previousFrame = shotStates[shotStates.index(before: index)]
			let nextFrame = shotStates[index]
			let duration = nextFrame.presentationTime.seconds - previousFrame.presentationTime.seconds

			guard duration > 0 else { return previousFrame.value.bounds }

			let progress = max(
				0,
				min(1, (compositionTime.seconds - previousFrame.presentationTime.seconds) / duration)
			)
			return previousFrame.value.bounds.interpolated(to: nextFrame.value.bounds, progress: progress)
		}
	}
}

public enum VideoReframerError: Swift.Error {
	case noVideoTrackFound
	case noDetectedSubject
	case unsupportedOutputFileType(String)
	case exportSessionUnavailable
	case exportFailed
	case exportCancelled
}

public actor VideoReframer {
	public let configuration: ReframingConfiguration

	public init(configuration: ReframingConfiguration = .init()) {
		self.configuration = configuration
	}

	public func analyze(asset: AVAsset) async throws -> ReframingAnalysis {
		guard let track = try await asset.loadTracks(withMediaType: .video).first else {
			throw VideoReframerError.noVideoTrackFound
		}

		let sourceSize = try await Self.sourceSize(for: track)
		let poseFrames = try await VideoProcessor(asset: asset).process()
		let tracker = ShotTracker(sourceSize: sourceSize, aspectRatio: configuration.aspectRatio)

		var shotStates: [FrameData<ShotState>] = []
		var detectedPoses = 0

		for frame in poseFrames {
			let pose = Self.primaryPose(in: frame.value, sourceSize: sourceSize)
			if pose != nil {
				detectedPoses += 1
			}

			let state = await tracker.track(pose, at: frame.presentationTime)
			shotStates.append(FrameData(presentationTime: frame.presentationTime, value: state))
		}

		guard detectedPoses > 0 else {
			throw VideoReframerError.noDetectedSubject
		}

		return ReframingAnalysis(
			sourceSize: sourceSize,
			renderSize: configuration.renderSize,
			shotStates: shotStates
		)
	}

	public func export(inputURL: URL, outputURL: URL) async throws {
		let asset = AVURLAsset(url: inputURL)
		let analysis = try await analyze(asset: asset)
		try await export(asset: asset, analysis: analysis, outputURL: outputURL)
	}

	public func export(asset: AVAsset, analysis: ReframingAnalysis, outputURL: URL) async throws {
		let videoComposition = try await self.makeVideoComposition(asset: asset, analysis: analysis)

		guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
			throw VideoReframerError.exportSessionUnavailable
		}

		if FileManager.default.fileExists(atPath: outputURL.path) {
			try FileManager.default.removeItem(at: outputURL)
		}

		exportSession.videoComposition = videoComposition
		exportSession.shouldOptimizeForNetworkUse = true
		try await exportSession.export(to: outputURL, as: Self.outputFileType(for: outputURL))
	}

	private func makeVideoComposition(asset: AVAsset, analysis: ReframingAnalysis) async throws -> AVMutableVideoComposition {
		guard let track = try await asset.loadTracks(withMediaType: .video).first else {
			throw VideoReframerError.noVideoTrackFound
		}

		let nominalFrameRate = try await track.load(.nominalFrameRate)
		let frameDuration: CMTime
		if nominalFrameRate > 0 {
			frameDuration = CMTime(value: 1, timescale: CMTimeScale(nominalFrameRate.rounded()))
		} else {
			frameDuration = CMTime(value: 1, timescale: 30)
		}

		let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
			guard let cropRect = analysis.interpolatedBounds(at: request.compositionTime) else {
				request.finish(with: request.sourceImage, context: nil)
				return
			}

			let outputImage = Self.reframedImage(
				request.sourceImage,
				cropRect: cropRect,
				renderSize: analysis.renderSize
			)
			request.finish(with: outputImage, context: nil)
		}

		composition.renderSize = analysis.renderSize
		composition.frameDuration = frameDuration
		return composition
	}

	private static func reframedImage(_ image: CIImage, cropRect: CGRect, renderSize: CGSize) -> CIImage {
		let cropped = image.cropped(to: cropRect)
		let translated = cropped.transformed(by: .init(translationX: -cropRect.minX, y: -cropRect.minY))
		let scaleTransform = CGAffineTransform(
			scaleX: renderSize.width / cropRect.width,
			y: renderSize.height / cropRect.height
		)
		return translated.transformed(by: scaleTransform)
	}

	private static func outputFileType(for outputURL: URL) throws -> AVFileType {
		switch outputURL.pathExtension.lowercased() {
		case "mov":
			return .mov
		case "mp4":
			return .mp4
		default:
			throw VideoReframerError.unsupportedOutputFileType(outputURL.pathExtension)
		}
	}

	private static func primaryPose(in poses: [HumanBodyPoseObservation], sourceSize: CGSize) -> HumanBodyPoseObservation? {
		poses.max { lhs, rhs in
			boundingArea(for: lhs, sourceSize: sourceSize) < boundingArea(for: rhs, sourceSize: sourceSize)
		}
	}

	private static func boundingArea(for pose: HumanBodyPoseObservation, sourceSize: CGSize) -> CGFloat {
		let points = pose.allJoints().values.map { $0.location.toImageCoordinates(sourceSize, origin: .lowerLeft) }
		let rect = CGRect.boundingRect(of: points)
		return rect.width * rect.height
	}

	private static func sourceSize(for track: AVAssetTrack) async throws -> CGSize {
		let (naturalSize, preferredTransform) = try await track.load(.naturalSize, .preferredTransform)
		let rect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
		return CGSize(width: abs(rect.width), height: abs(rect.height))
	}
}

private extension CGRect {
	func interpolated(to other: CGRect, progress: Double) -> CGRect {
		let progress = CGFloat(progress)

		return CGRect(
			x: origin.x + (other.origin.x - origin.x) * progress,
			y: origin.y + (other.origin.y - origin.y) * progress,
			width: size.width + (other.size.width - size.width) * progress,
			height: size.height + (other.size.height - size.height) * progress
		)
	}
}
