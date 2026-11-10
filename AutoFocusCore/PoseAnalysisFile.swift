import AVFoundation
import Foundation
import Vision

/// Reusable source observations. Crop paths and sampling intervals are deliberately
/// excluded: each render computes its own path and fills missing sample requests.
public struct PoseAnalysisFile: Codable, Sendable {
	public static let currentSchemaVersion = 1

	public struct Time: Codable, Hashable, Sendable {
		public let value: Int64
		public let timescale: Int32
		public let epoch: Int64

		public init(_ time: CMTime) throws {
			guard time.isNumeric, time.timescale > 0 else {
				throw Error.invalidTime("Timestamps must be finite rational times with a positive timescale.")
			}
			value = time.value
			timescale = time.timescale
			epoch = time.epoch
		}

		public var cmTime: CMTime { CMTime(value: value, timescale: timescale, flags: .valid, epoch: epoch) }

		public static func == (lhs: Self, rhs: Self) -> Bool { lhs.cmTime == rhs.cmTime }

		public func hash(into hasher: inout Hasher) { hasher.combine(cmTime) }

		private enum CodingKeys: CodingKey { case value, timescale, epoch }

		public init(from decoder: any Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			let value = try container.decode(Int64.self, forKey: .value)
			let timescale = try container.decode(Int32.self, forKey: .timescale)
			let epoch = try container.decode(Int64.self, forKey: .epoch)
			try self.init(CMTime(value: value, timescale: timescale, flags: .valid, epoch: epoch))
		}
	}

	public struct TimeRange: Codable, Equatable, Sendable {
		public let start: Time
		public let duration: Time

		public init(_ range: CMTimeRange) throws {
			guard range.isValid, range.duration.isNumeric, range.duration > .zero else {
				throw Error.invalidTime("Analysis ranges must have a finite, positive duration.")
			}
			start = try Time(range.start)
			duration = try Time(range.duration)
		}

		public var cmTimeRange: CMTimeRange { CMTimeRange(start: start.cmTime, duration: duration.cmTime) }

		private enum CodingKeys: CodingKey { case start, duration }

		public init(from decoder: any Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			let start = try container.decode(Time.self, forKey: .start)
			let duration = try container.decode(Time.self, forKey: .duration)
			try self.init(CMTimeRange(start: start.cmTime, duration: duration.cmTime))
		}
	}

	public struct SourceIdentity: Codable, Equatable, Sendable {
		public var canonicalPath: String
		public var fileSize: Int
		public var modificationDate: Date
		public var trackID: CMPersistentTrackID
		public var naturalSize: CGSize
		public var preferredTransform: CGAffineTransform
		public var timeRange: TimeRange

		public init(
			canonicalPath: String,
			fileSize: Int,
			modificationDate: Date,
			trackID: CMPersistentTrackID,
			naturalSize: CGSize,
			preferredTransform: CGAffineTransform,
			timeRange: CMTimeRange,
		) throws {
			self.canonicalPath = canonicalPath
			self.fileSize = fileSize
			self.modificationDate = modificationDate
			self.trackID = trackID
			self.naturalSize = naturalSize
			self.preferredTransform = preferredTransform
			self.timeRange = try TimeRange(timeRange)
		}

		public static func load(url: URL, videoTrack: AVAssetTrack) async throws -> Self {
			guard url.isFileURL else { throw Error.requiresLocalSource }
			let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
			let values = try canonicalURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
			guard let fileSize = values.fileSize, let modificationDate = values.contentModificationDate else {
				throw Error.sourceMetadataUnavailable
			}
			let (naturalSize, preferredTransform, timeRange) = try await videoTrack.load(.naturalSize, .preferredTransform, .timeRange)
			return try Self(
				canonicalPath: canonicalURL.path,
				fileSize: fileSize,
				modificationDate: modificationDate,
				trackID: videoTrack.trackID,
				naturalSize: naturalSize,
				preferredTransform: preferredTransform,
				timeRange: timeRange,
			)
		}
	}

	public struct DetectionParameters: Codable, Equatable, Sendable {
		public var analyzerVersion: Int
		public var maximumDetectionLongEdge: CGFloat
		public var visionRevision: String
		public var detectsHands: Bool

		public init(configuration: PoseVideoAnalysisConfiguration) {
			analyzerVersion = 1
			maximumDetectionLongEdge = configuration.maximumDetectionLongEdge
			visionRevision = String(describing: DetectHumanBodyPoseRequest().revision)
			detectsHands = false
		}
	}

	/// Extraction context distinguishes a selected-range boundary from an interior
	/// request at the same timestamp, and sparse seeks from sequential decoding.
	public struct RequestContext: Codable, Equatable, Sendable {
		public let strategy: String
		public let extractionTime: Time
		public let toleranceBefore: Time
		public let toleranceAfter: Time

		public init(strategy: String, extractionTime: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime) throws {
			self.strategy = strategy
			self.extractionTime = try Time(extractionTime)
			self.toleranceBefore = try Time(toleranceBefore)
			self.toleranceAfter = try Time(toleranceAfter)
			try validate()
		}

		private func validate() throws {
			guard toleranceBefore.cmTime >= .zero, toleranceAfter.cmTime >= .zero else {
				throw Error.invalidTime("Frame extraction tolerances cannot be negative.")
			}
		}

		private enum CodingKeys: CodingKey { case strategy, extractionTime, toleranceBefore, toleranceAfter }

		public init(from decoder: any Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			strategy = try container.decode(String.self, forKey: .strategy)
			extractionTime = try container.decode(Time.self, forKey: .extractionTime)
			toleranceBefore = try container.decode(Time.self, forKey: .toleranceBefore)
			toleranceAfter = try container.decode(Time.self, forKey: .toleranceAfter)
			try validate()
		}
	}

	public struct Frame: Codable, Sendable {
		public var actualTime: Time
		public var poses: [HumanBodyPoseObservation]

		public init(_ frame: FrameData<[HumanBodyPoseObservation]>) throws {
			actualTime = try Time(frame.presentationTime)
			poses = frame.value
		}

		public var frameData: FrameData<[HumanBodyPoseObservation]> {
			FrameData(presentationTime: actualTime.cmTime, value: poses)
		}
	}

	public struct Sample: Codable, Sendable {
		public var requestedTime: Time
		public var frames: [Frame]
		public var context: RequestContext

		public init(requestedTime: CMTime, frames: [FrameData<[HumanBodyPoseObservation]>], context: RequestContext) throws {
			self.requestedTime = try Time(requestedTime)
			self.frames = try frames.map(Frame.init)
			self.context = context
		}
	}

	public var schemaVersion: Int
	public var source: SourceIdentity
	public var detection: DetectionParameters
	public var selectedTimeRange: TimeRange
	public var samples: [Sample]

	public init(source: SourceIdentity, detection: DetectionParameters, selectedTimeRange: CMTimeRange, samples: [Sample]) throws {
		schemaVersion = Self.currentSchemaVersion
		self.source = source
		self.detection = detection
		self.selectedTimeRange = try TimeRange(selectedTimeRange)
		self.samples = samples
		try validateContents()
	}

	public init(asset: AVAsset, configuration: PoseVideoAnalysisConfiguration, samples: [Sample]) async throws {
		let source = try await Self.sourceIdentity(for: asset)
		let selectedTimeRange = try PoseVideoAnalyzer.resolvedTimeRange(
			availableTimeRange: source.timeRange.cmTimeRange,
			requestedTimeRange: configuration.timeRange,
		)
		try self.init(source: source, detection: DetectionParameters(configuration: configuration), selectedTimeRange: selectedTimeRange, samples: samples)
	}

	public func validate(asset: AVAsset, configuration: PoseVideoAnalysisConfiguration) async throws {
		try await validate(source: Self.sourceIdentity(for: asset), detection: DetectionParameters(configuration: configuration))
	}

	public func validate(source currentSource: SourceIdentity, detection currentDetection: DetectionParameters) throws {
		try validateContents()
		guard source.canonicalPath == currentSource.canonicalPath else { throw Error.incompatibleSource("file path") }
		guard source.fileSize == currentSource.fileSize else { throw Error.incompatibleSource("file size") }
		guard source.modificationDate == currentSource.modificationDate else { throw Error.incompatibleSource("modification date") }
		guard source.trackID == currentSource.trackID else { throw Error.incompatibleSource("video track") }
		guard source.naturalSize == currentSource.naturalSize, source.preferredTransform == currentSource.preferredTransform else {
			throw Error.incompatibleSource("video geometry")
		}
		guard source.timeRange == currentSource.timeRange else { throw Error.incompatibleSource("video timing") }
		guard detection == currentDetection else { throw Error.incompatibleDetection }
	}

	public static func load(from url: URL) throws -> Self {
		let data = try Data(contentsOf: url)
		do {
			return try JSONDecoder().decode(Self.self, from: data)
		} catch let error as DecodingError {
			throw Error.invalidFormat(String(reflecting: error))
		}
	}

	public func write(to url: URL) throws {
		try validateContents()
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		try encoder.encode(self).write(to: url, options: .atomic)
	}

	private static func sourceIdentity(for asset: AVAsset) async throws -> SourceIdentity {
		guard let asset = asset as? AVURLAsset, asset.url.isFileURL else { throw Error.requiresLocalSource }
		guard let track = try await asset.loadTracks(withMediaType: .video).first else {
			throw VideoReframerError.noVideoTrackFound
		}
		return try await SourceIdentity.load(url: asset.url, videoTrack: track)
	}

	private func validateContents() throws {
		guard schemaVersion == Self.currentSchemaVersion else { throw Error.unsupportedSchema(schemaVersion) }
		let sourceRange = source.timeRange.cmTimeRange
		let selected = selectedTimeRange.cmTimeRange
		guard selected.start >= sourceRange.start, selected.end <= sourceRange.end else {
			throw Error.invalidTime("The recorded selection lies outside the source video track.")
		}
		for sample in samples {
			let requested = sample.requestedTime.cmTime
			guard requested >= sourceRange.start, requested < sourceRange.end else {
				throw Error.invalidTime("A sample request lies outside the source video track.")
			}
			guard sample.frames.allSatisfy({ $0.actualTime.cmTime >= sourceRange.start && $0.actualTime.cmTime < sourceRange.end }) else {
				throw Error.invalidTime("An observed frame lies outside the source video track.")
			}
		}
	}

	private enum CodingKeys: CodingKey { case schemaVersion, source, detection, selectedTimeRange, samples }

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
		guard schemaVersion == Self.currentSchemaVersion else { throw Error.unsupportedSchema(schemaVersion) }
		source = try container.decode(SourceIdentity.self, forKey: .source)
		detection = try container.decode(DetectionParameters.self, forKey: .detection)
		selectedTimeRange = try container.decode(TimeRange.self, forKey: .selectedTimeRange)
		samples = try container.decode([Sample].self, forKey: .samples)
		try validateContents()
	}
}

public extension PoseAnalysisFile {
	enum Error: Swift.Error, LocalizedError, CustomDebugStringConvertible {
		case unsupportedSchema(Int)
		case invalidFormat(String)
		case invalidTime(String)
		case incompatibleSource(String)
		case incompatibleDetection
		case requiresLocalSource
		case sourceMetadataUnavailable

		public var errorDescription: String? {
			switch self {
			case let .unsupportedSchema(version):
				"Saved analysis version \(version) is not supported by this version of AutoFocusAI."
			case .invalidFormat:
				"This file is not reusable AutoFocusAI analysis. A --pose-data report cannot be loaded as analysis."
			case let .invalidTime(reason):
				"The saved analysis has invalid timing. \(reason)"
			case let .incompatibleSource(component):
				"The saved analysis cannot be reused because the source's \(component) differs."
			case .incompatibleDetection:
				"The saved analysis uses different pose-detection settings or a different Vision revision."
			case .requiresLocalSource:
				"Reusable analysis requires a local source video file."
			case .sourceMetadataUnavailable:
				"The source video's size or modification date could not be read for reusable analysis."
			}
		}

		public var recoverySuggestion: String? {
			switch self {
			case .unsupportedSchema, .invalidFormat, .invalidTime, .incompatibleSource, .incompatibleDetection:
				"Analyze the source again and create a new file with --save-analysis."
			case .requiresLocalSource, .sourceMetadataUnavailable:
				nil
			}
		}

		public var debugDescription: String {
			if case let .invalidFormat(details) = self { return "Invalid reusable analysis: \(details)" }
			return errorDescription ?? "Reusable analysis failed."
		}
	}
}
