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

	@Argument(help: "Output video paths, in the same order as --resolution values. Omit when exporting JSON data.")
	var outputs: [String] = []

	@Option(help: "Seconds between pose detections.")
	var poseInterval = 1.0

	@Option(help: "First video timestamp to analyze and export, in seconds.")
	var startTime: Double?

	@Option(help: "Video timestamp at which analysis and export stop, in seconds.")
	var endTime: Double?

	@Option(help: "Write raw pose observations as JSON to this path instead of exporting video.")
	var poseData: String?

	@Option(help: "Write crop keyframes as JSON to this path instead of exporting video.")
	var keyframes: String?

	@Option(help: "Reuse source observations from a saved analysis file, detecting missing samples as needed.")
	var loadAnalysis: String?

	@Option(help: "Save reusable source observations, including adaptive samples. May accompany video or JSON output.")
	var saveAnalysis: String?

	@Option(help: "Native output crop: 9:16-max, 1920x1080, 1080x1920, or a custom WIDTHxHEIGHT.")
	var resolution: [OutputResolution] = []

	@Flag(help: "Print crop bounds and subject positions, and include underlying error domains and codes on failure.")
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
		let outputModeCount = (outputs.isEmpty ? 0 : 1) + [poseData, keyframes].compactMap(\.self).count
		if outputModeCount == 0, saveAnalysis == nil {
			throw ValidationError("Provide an output video path, --pose-data <json-path>, --keyframes <json-path>, or --save-analysis <path>.")
		}
		if outputModeCount > 1 {
			throw ValidationError("Choose video output, --pose-data, or --keyframes.")
		}
		if !outputs.isEmpty, outputs.count != resolvedResolutions.count {
			throw ValidationError("Provide one --resolution per output video path, in matching order.")
		}
		if poseData != nil, resolution.count > 1 {
			throw ValidationError("--resolution does not apply to raw pose data.")
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
		do {
			try await runPipeline()
		} catch {
			if debug, !(error is CancellationError) {
				let diagnostics = ErrorDiagnostics.description(for: error) + "\n"
				FileHandle.standardError.write(Data(diagnostics.utf8))
			}
			throw error
		}
	}

	private mutating func runPipeline() async throws {
		let inputURL = Self.fileURL(for: input)
		guard FileManager.default.fileExists(atPath: inputURL.path) else {
			throw ValidationError("Input video does not exist: \(inputURL.path)")
		}
		guard try inputURL.resourceValues(forKeys: [.fileResourceTypeKey]).fileResourceType != .directory else {
			throw ValidationError("Input path is a directory, expected a video file: \(inputURL.path)")
		}

		let outputURLs = try outputs.map { try validatedOutputURL(for: $0, inputURL: inputURL) }
		let poseDataURL = try poseData.map { try validatedOutputURL(for: $0, inputURL: inputURL) }
		let keyframesURL = try keyframes.map { try validatedOutputURL(for: $0, inputURL: inputURL) }
		let savedAnalysisURL = try saveAnalysis.map { try validatedOutputURL(for: $0, inputURL: inputURL) }
		let loadedAnalysisURL = loadAnalysis.map(Self.fileURL(for:))
		let otherOutputURLs = outputURLs + [poseDataURL, keyframesURL].compactMap(\.self)
		let allOutputURLs = otherOutputURLs + [savedAnalysisURL].compactMap(\.self)
		guard Set(allOutputURLs).count == allOutputURLs.count else {
			throw ValidationError("Video, JSON, and saved-analysis output paths must be different from each other.")
		}
		if let loadedAnalysisURL, otherOutputURLs.contains(loadedAnalysisURL) {
			throw ValidationError("--load-analysis must differ from video and JSON output paths. Use --save-analysis to update an analysis file.")
		}
		for outputURL in outputURLs {
			guard ["mov", "mp4"].contains(outputURL.pathExtension.lowercased()) else {
				throw ValidationError("Output video must use a .mov or .mp4 extension: \(outputURL.path)")
			}
		}

		let asset = AVURLAsset(url: inputURL)
		guard let track = try await asset.loadTracks(withMediaType: .video).first else {
			throw VideoReframerError.noVideoTrackFound
		}
		let (trackTimeRange, nominalFrameRate, naturalSize, preferredTransform) = try await track.load(
			.timeRange, .nominalFrameRate, .naturalSize, .preferredTransform,
		)
		let selectedTimeRange = try selectedTimeRange(for: trackTimeRange)
		let configuredTimeRange = startTime != nil || endTime != nil ? selectedTimeRange : nil
		let sourceRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
		let sourceSize = CGSize(width: abs(sourceRect.width), height: abs(sourceRect.height))
		let producesCrops = !outputURLs.isEmpty || keyframesURL != nil
		if producesCrops {
			for resolution in resolvedResolutions {
				do {
					_ = try resolution.outputSize.resolve(for: sourceSize)
				} catch {
					throw ValidationError(Self.presentationText(for: error))
				}
			}
		}
		let maximumFramesPerSecond = 1 / poseInterval
		let poseConfiguration = PoseVideoAnalysisConfiguration(
			maximumFramesPerSecond: maximumFramesPerSecond,
			timeRange: configuredTimeRange,
		)
		let reframer = VideoReframer(configuration: .init(
			outputSize: producesCrops ? resolvedResolutions[0].outputSize : .maximum9By16,
			poseAnalysisConfiguration: poseConfiguration,
		))
		print("Analyzing \(inputURL.lastPathComponent)...")
		let sourceAnalysis = try await Self.prepareSourceAnalysis(reframer: reframer, asset: asset, loading: loadedAnalysisURL)
		// Persist the initial pass before rendering, then include each crop's new
		// adaptive observations before its potentially expensive media export.
		try await Self.persistAnalysis(sourceAnalysis, to: savedAnalysisURL)

		if let poseDataURL {
			let effectiveSampleInterval = PoseVideoAnalyzer.sampleInterval(
				forNominalFrameRate: nominalFrameRate,
				maximumFramesPerSecond: maximumFramesPerSecond,
			).seconds
			let poseDataFile = PoseDataFile(
				frames: sourceAnalysis.poseFrames,
				timeRange: selectedTimeRange,
				timelineOrigin: trackTimeRange.start,
				sampleInterval: effectiveSampleInterval,
			)
			try Self.writeJSON(poseDataFile, to: poseDataURL)
			print("Wrote \(sourceAnalysis.poseFrames.count) pose samples to \(poseDataURL.path)")
		} else if let keyframesURL {
			var analyses: [ReframingAnalysis] = []
			for resolution in resolvedResolutions {
				let cropReframer = VideoReframer(configuration: .init(
					outputSize: resolution.outputSize,
					poseAnalysisConfiguration: poseConfiguration,
				))
				try await analyses.append(cropReframer.reframe(sourceAnalysis))
				try await Self.persistAnalysis(sourceAnalysis, to: savedAnalysisURL)
			}
			try Self.writeJSON(CropKeyframesFile(
				analyses: analyses,
				timeRange: selectedTimeRange,
				timelineOrigin: trackTimeRange.start,
			), to: keyframesURL)
			print("Wrote keyframes for \(analyses.count) output configuration(s) to \(keyframesURL.path)")
		} else {
			print("Prepared \(sourceAnalysis.poseFrames.count) source pose samples for \(outputURLs.count) video output(s).")
			for (resolution, outputURL) in zip(resolvedResolutions, outputURLs) {
				let cropReframer = VideoReframer(configuration: .init(
					outputSize: resolution.outputSize,
					poseAnalysisConfiguration: poseConfiguration,
				))
				let analysis = try await cropReframer.reframe(sourceAnalysis)
				try await Self.persistAnalysis(sourceAnalysis, to: savedAnalysisURL)
				if debug { Self.printDebug(analysis) }
				print("Tracked \(analysis.shotStates.count) crop frames. Exporting \(outputURL.lastPathComponent)...")
				try await cropReframer.export(asset: asset, analysis: analysis, outputURL: outputURL)
				print("Exported to \(outputURL.path)")
			}
		}
		await Self.printSamplingStatistics(sourceAnalysis)
	}

	private static func fileURL(for path: String) -> URL {
		let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
		// The final component may not exist yet. Resolve its existing parent first
		// so video and analysis destinations cannot alias through a directory link.
		return url.deletingLastPathComponent().resolvingSymlinksInPath()
			.appendingPathComponent(url.lastPathComponent).resolvingSymlinksInPath()
	}

	private static func prepareSourceAnalysis(
		reframer: VideoReframer,
		asset: AVAsset,
		loading url: URL?,
	) async throws -> ReframingSourceAnalysis {
		do {
			let cachedAnalysis = try url.map { try PoseAnalysisFile.load(from: $0) }
			return try await reframer.analyzeSource(asset: asset, cachedAnalysis: cachedAnalysis)
		} catch let error as PoseAnalysisFile.Error {
			throw ValidationError(presentationText(for: error))
		}
	}

	private static func writeJSON(_ value: some Encodable, to url: URL) throws {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		try encoder.encode(value).write(to: url, options: .atomic)
	}

	private static func persistAnalysis(_ sourceAnalysis: ReframingSourceAnalysis, to url: URL?) async throws {
		guard let url else { return }
		let file = try await sourceAnalysis.poseAnalysisFile()
		try file.write(to: url)
		print("Saved reusable analysis to \(url.path)")
	}

	private static func printSamplingStatistics(_ sourceAnalysis: ReframingSourceAnalysis) async {
		let sampling = await sourceAnalysis.poseSamplingStatistics()
		print("Pose sampling: \(sampling.initialSamples) initial samples, \(sampling.additionalRequests) refinement requests; \(sampling.newRequests) new sample requests, \(sampling.cachedRequests) reused cached requests.")
	}

	private static func printDebug(_ analysis: ReframingAnalysis) {
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
		let outputURL = Self.fileURL(for: path)
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
