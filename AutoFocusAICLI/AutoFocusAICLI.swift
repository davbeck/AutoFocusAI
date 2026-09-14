import ArgumentParser
import AutoFocusCore
import AVFoundation
import Foundation

struct OutputResolution: ExpressibleByArgument, Sendable {
	var outputSize: VideoOutputSize

	var defaultValueDescription: String {
		switch outputSize {
		case .maximum9By16:
			"9:16-max"
		case let .fixed(width, height):
			"\(width)x\(height)"
		}
	}

	init(_ outputSize: VideoOutputSize) {
		self.outputSize = outputSize
	}

	init?(argument: String) {
		let normalized = argument.lowercased()
		if ["9:16-max", "9x16-max", "max"].contains(normalized) {
			self.outputSize = .maximum9By16
			return
		}

		let dimensions = normalized
			.replacingOccurrences(of: "×", with: "x")
			.split(separator: "x", omittingEmptySubsequences: false)
		guard
			dimensions.count == 2,
			let width = Int(dimensions[0]),
			let height = Int(dimensions[1])
		else {
			return nil
		}

		self.outputSize = .fixed(width: width, height: height)
	}
}

@main
struct AutoFocusAICLI: AsyncParsableCommand {
	static let configuration = CommandConfiguration(
		abstract: "Analyze and reframe a video to keep the subject composed in a native-resolution crop.",
	)

	@Argument(help: "Path to the source video file.")
	var input: String

	@Argument(help: "Path where the cropped output video should be written. Omit when exporting JSON data.")
	var output: String?

	@Option(help: "Seconds between pose detections.")
	var poseInterval = 5.0

	@Option(help: "First video timestamp to analyze and export, in seconds.")
	var startTime: Double?

	@Option(help: "Video timestamp at which analysis and export stop, in seconds.")
	var endTime: Double?

	@Option(help: "Write raw pose observations as JSON to this path instead of exporting video.")
	var poseData: String?

	@Option(help: "Write crop keyframes as JSON to this path instead of exporting video.")
	var keyframes: String?

	@Option(help: "Native output crop: 9:16-max, 1920x1080, 1080x1920, or a custom WIDTHxHEIGHT.")
	var resolution: [OutputResolution] = []

	@Flag(help: "Print crop bounds and subject position for each tracked frame before exporting.")
	var debug = false

	mutating func validate() throws {
		guard poseInterval.isFinite, poseInterval > 0 else {
			throw ValidationError("--pose-interval must be greater than zero.")
		}
		if let startTime, !startTime.isFinite || startTime < 0 {
			throw ValidationError("--start-time must be a nonnegative number of seconds.")
		}
		if let endTime, !endTime.isFinite || endTime <= 0 {
			throw ValidationError("--end-time must be greater than zero.")
		}
		if let startTime, let endTime, endTime <= startTime {
			throw ValidationError("--end-time must be later than --start-time.")
		}
		let outputModeCount = [output, poseData, keyframes].compactMap(\.self).count
		if outputModeCount == 0 {
			throw ValidationError("Provide an output video path, --pose-data <json-path>, or --keyframes <json-path>.")
		}
		if outputModeCount > 1 {
			throw ValidationError("Choose exactly one output video path, --pose-data, or --keyframes.")
		}
		if keyframes == nil, resolution.count > 1 {
			throw ValidationError("Multiple --resolution values are supported only with --keyframes.")
		}
		for resolution in resolvedResolutions {
			do {
				try resolution.outputSize.validate()
			} catch {
				throw ValidationError(Self.presentationText(for: error))
			}
		}
	}

	mutating func run() async throws {
		let inputURL = URL(fileURLWithPath: (input as NSString).expandingTildeInPath).standardizedFileURL

		guard FileManager.default.fileExists(atPath: inputURL.path) else {
			throw ValidationError("Input video does not exist: \(inputURL.path)")
		}

		guard try inputURL.resourceValues(forKeys: [.fileResourceTypeKey]).fileResourceType != .directory else {
			throw ValidationError("Input path is a directory, expected a video file: \(inputURL.path)")
		}

		let asset = AVURLAsset(url: inputURL)
		guard let track = try await asset.loadTracks(withMediaType: .video).first else {
			throw VideoReframerError.noVideoTrackFound
		}
		let (trackTimeRange, nominalFrameRate) = try await track.load(.timeRange, .nominalFrameRate)
		let selectedTimeRange = try selectedTimeRange(for: trackTimeRange)
		let configuredTimeRange = startTime != nil || endTime != nil ? selectedTimeRange : nil
		let maximumFramesPerSecond = 1 / poseInterval
		let poseConfiguration = PoseVideoAnalysisConfiguration(
			maximumFramesPerSecond: maximumFramesPerSecond,
			timeRange: configuredTimeRange,
		)

		if let poseData {
			let poseDataURL = try validatedOutputURL(for: poseData, inputURL: inputURL)
			print("Detecting poses in \(inputURL.lastPathComponent)...")
			let frames = try await PoseVideoAnalyzer(
				asset: asset,
				videoTrack: track,
				configuration: poseConfiguration,
			).process()
			let effectiveSampleInterval = PoseVideoAnalyzer.sampleInterval(
				forNominalFrameRate: nominalFrameRate,
				maximumFramesPerSecond: maximumFramesPerSecond,
			).seconds
			let poseDataFile = PoseDataFile(
				frames: frames,
				timeRange: selectedTimeRange,
				timelineOrigin: trackTimeRange.start,
				sampleInterval: effectiveSampleInterval,
			)
			let encoder = JSONEncoder()
			encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
			try encoder.encode(poseDataFile).write(to: poseDataURL, options: .atomic)
			print("Wrote \(frames.count) pose samples to \(poseDataURL.path)")
			return
		}

		if let keyframes {
			let keyframesURL = try validatedOutputURL(for: keyframes, inputURL: inputURL)
			let (naturalSize, preferredTransform) = try await track.load(.naturalSize, .preferredTransform)
			let sourceRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
			let sourceSize = CGSize(width: abs(sourceRect.width), height: abs(sourceRect.height))
			for resolution in resolvedResolutions {
				do {
					_ = try resolution.outputSize.resolve(for: sourceSize)
				} catch {
					throw ValidationError(Self.presentationText(for: error))
				}
			}

			print("Analyzing \(inputURL.lastPathComponent)...")
			let sourceAnalysis = try await VideoReframer(
				configuration: .init(
					outputSize: resolvedResolutions[0].outputSize,
					poseAnalysisConfiguration: poseConfiguration,
				),
			).analyzeSource(asset: asset)
			var analyses: [ReframingAnalysis] = []
			analyses.reserveCapacity(resolvedResolutions.count)
			for resolution in resolvedResolutions {
				let reframer = VideoReframer(
					configuration: .init(
						outputSize: resolution.outputSize,
						poseAnalysisConfiguration: poseConfiguration,
					),
				)
				let analysis = try await reframer.reframe(sourceAnalysis)
				analyses.append(analysis)
			}

			let keyframesFile = CropKeyframesFile(
				analyses: analyses,
				timeRange: selectedTimeRange,
				timelineOrigin: trackTimeRange.start,
			)
			let encoder = JSONEncoder()
			encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
			try encoder.encode(keyframesFile).write(to: keyframesURL, options: .atomic)
			print(
				"Wrote keyframes for \(analyses.count) output configuration\(analyses.count == 1 ? "" : "s") to \(keyframesURL.path)",
			)
			return
		}

		guard let output else {
			throw ValidationError("Provide an output video path.")
		}
		let outputURL = try validatedOutputURL(for: output, inputURL: inputURL)
		let (naturalSize, preferredTransform) = try await track.load(.naturalSize, .preferredTransform)
		let sourceRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
		let sourceSize = CGSize(width: abs(sourceRect.width), height: abs(sourceRect.height))
		do {
			_ = try resolvedResolutions[0].outputSize.resolve(for: sourceSize)
		} catch {
			throw ValidationError(Self.presentationText(for: error))
		}
		let reframer = VideoReframer(
			configuration: .init(
				outputSize: resolvedResolutions[0].outputSize,
				poseAnalysisConfiguration: poseConfiguration,
			),
		)

		print("Analyzing \(inputURL.lastPathComponent)...")
		let analysis = try await reframer.analyze(asset: asset)

		if debug {
			print("sourceSize: \(Int(analysis.sourceSize.width)) x \(Int(analysis.sourceSize.height))")
			print("renderSize: \(Int(analysis.renderSize.width)) x \(Int(analysis.renderSize.height))")
			if let first = analysis.shotStates.first {
				print("cropSize:   \(Int(first.value.bounds.width)) x \(Int(first.value.bounds.height))")
			}
			print("")
			print("time(s)\tcropX\tcropY\tsubjectMidX\tsubjectMidY")
			for frame in analysis.shotStates {
				let b = frame.value.bounds
				if let sc = frame.value.subjectCenter {
					print(
						String(
							format: "%.3f\t%.1f\t%.1f\t%.1f\t%.1f",
							frame.presentationTime.seconds,
							b.origin.x,
							b.origin.y,
							sc.x,
							sc.y,
						),
					)
				} else {
					print(
						String(
							format: "%.3f\t%.1f\t%.1f\t-\t-",
							frame.presentationTime.seconds,
							b.origin.x,
							b.origin.y,
						),
					)
				}
			}
			print("")
		}

		print("Analyzed \(analysis.shotStates.count) frames. Exporting...")
		try await reframer.export(asset: asset, analysis: analysis, outputURL: outputURL)
		print("Exported to \(outputURL.path)")
	}

	private func selectedTimeRange(for trackTimeRange: CMTimeRange) throws -> CMTimeRange {
		let videoDuration = trackTimeRange.duration.seconds
		guard videoDuration.isFinite, videoDuration > 0 else {
			throw ValidationError("The input video does not have a finite duration.")
		}

		let selectedStartTime = startTime ?? 0
		let selectedEndTime = endTime ?? videoDuration
		guard selectedStartTime < videoDuration else {
			throw ValidationError(
				"--start-time must be earlier than the video duration (\(Self.formatted(videoDuration)) seconds).",
			)
		}
		guard selectedEndTime <= videoDuration else {
			throw ValidationError(
				"--end-time cannot exceed the video duration (\(Self.formatted(videoDuration)) seconds).",
			)
		}

		let start = trackTimeRange.start + CMTime(seconds: selectedStartTime, preferredTimescale: 600_000)
		let end = trackTimeRange.start + CMTime(seconds: selectedEndTime, preferredTimescale: 600_000)
		return CMTimeRange(start: start, end: end)
	}

	private func validatedOutputURL(for path: String, inputURL: URL) throws -> URL {
		let outputURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
		let outputDirectory = outputURL.deletingLastPathComponent().standardizedFileURL
		var isDirectory: ObjCBool = false
		guard FileManager.default.fileExists(atPath: outputDirectory.path, isDirectory: &isDirectory),
		      isDirectory.boolValue
		else {
			throw ValidationError("Output directory does not exist: \(outputDirectory.path)")
		}
		guard inputURL != outputURL else {
			throw ValidationError("Input and output paths must be different.")
		}
		return outputURL
	}

	private static func formatted(_ seconds: Double) -> String {
		seconds.formatted(.number.precision(.fractionLength(0 ... 3)))
	}

	private var resolvedResolutions: [OutputResolution] {
		resolution.isEmpty ? [OutputResolution(.maximum9By16)] : resolution
	}

	private static func presentationText(for error: any Error) -> String {
		let nsError = error as NSError
		return [nsError.localizedDescription, nsError.localizedRecoverySuggestion]
			.compactMap(\.self)
			.joined(separator: " ")
	}
}
