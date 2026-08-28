import ArgumentParser
import AutoFocusCore
import AVFoundation
import Foundation

@main
struct AutoFocusAICLI: AsyncParsableCommand {
	static let configuration = CommandConfiguration(
		abstract: "Analyze and reframe a video to keep the subject centered in a vertical crop.",
	)

	@Argument(help: "Path to the source video file.")
	var input: String

	@Argument(help: "Path where the cropped output video should be written. Omit when using --pose-data.")
	var output: String?

	@Option(help: "Seconds between pose detections.")
	var poseInterval = 5.0

	@Option(help: "First video timestamp to analyze and export, in seconds.")
	var startTime: Double?

	@Option(help: "Video timestamp at which analysis and export stop, in seconds.")
	var endTime: Double?

	@Option(help: "Write raw pose observations as JSON to this path instead of exporting video.")
	var poseData: String?

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
		if poseData == nil, output == nil {
			throw ValidationError("Provide an output video path or use --pose-data <json-path>.")
		}
		if poseData != nil, output != nil {
			throw ValidationError("Omit the output video path when using --pose-data.")
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

		guard let output else {
			throw ValidationError("Provide an output video path.")
		}
		let outputURL = try validatedOutputURL(for: output, inputURL: inputURL)
		let reframer = VideoReframer(
			configuration: .init(poseAnalysisConfiguration: poseConfiguration),
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
			print("time(s)\tcropX\tsubjectMidX\tsubjectMidY")
			for frame in analysis.shotStates {
				let b = frame.value.bounds
				if let sc = frame.value.subjectCenter {
					print(String(format: "%.3f\t%.1f\t%.1f\t%.1f", frame.presentationTime.seconds, b.origin.x, sc.x, sc.y))
				} else {
					print(String(format: "%.3f\t%.1f\t-\t-", frame.presentationTime.seconds, b.origin.x))
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
}
