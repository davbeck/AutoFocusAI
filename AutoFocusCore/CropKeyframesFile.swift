import CoreMedia
import Foundation

public struct CropKeyframesFile: Codable, Sendable {
	public static let currentSchemaVersion = 1

	public struct TimeRange: Codable, Sendable {
		public var startTime: Double
		public var endTime: Double
	}

	public struct Configuration: Codable, Sendable {
		public var outputWidth: Double
		public var outputHeight: Double
		public var keyframes: [Keyframe]
	}

	public struct Keyframe: Codable, Sendable {
		public var timestamp: Double
		public var x: Double
		public var y: Double
		public var width: Double
		public var height: Double
	}

	public var schemaVersion: Int
	public var coordinateSystem: String
	public var sourceWidth: Double
	public var sourceHeight: Double
	public var timeRange: TimeRange
	public var configurations: [Configuration]

	public init(
		analyses: [ReframingAnalysis],
		timeRange: CMTimeRange,
		timelineOrigin: CMTime,
	) {
		let sourceSize = analyses.first?.sourceSize ?? .zero
		schemaVersion = Self.currentSchemaVersion
		coordinateSystem = "source pixels, upper-left origin"
		sourceWidth = sourceSize.width
		sourceHeight = sourceSize.height
		self.timeRange = TimeRange(
			startTime: (timeRange.start - timelineOrigin).seconds,
			endTime: (timeRange.end - timelineOrigin).seconds,
		)
		configurations = analyses.map { analysis in
			Configuration(
				outputWidth: analysis.renderSize.width,
				outputHeight: analysis.renderSize.height,
				keyframes: analysis.shotStates.map { frame in
					Keyframe(
						timestamp: (frame.presentationTime - timelineOrigin).seconds,
						x: frame.value.bounds.origin.x,
						y: analysis.sourceSize.height - frame.value.bounds.maxY,
						width: frame.value.bounds.width,
						height: frame.value.bounds.height,
					)
				},
			)
		}
	}
}
