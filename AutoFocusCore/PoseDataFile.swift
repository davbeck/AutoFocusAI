import CoreMedia
import Foundation
import Vision

public struct PoseDataFile: Codable, Sendable {
	public static let currentSchemaVersion = 1

	public struct TimeRange: Codable, Sendable {
		public var startTime: Double
		public var endTime: Double
	}

	public struct Frame: Codable, Sendable {
		public var timestamp: Double
		public var poses: [Pose]
	}

	public struct Pose: Codable, Sendable {
		public var id: UUID
		public var confidence: Float
		public var joints: [String: Joint]
	}

	public struct Joint: Codable, Sendable {
		public var x: Double
		public var y: Double
		public var confidence: Float
	}

	public var schemaVersion: Int
	public var coordinateSystem: String
	public var sampleInterval: Double
	public var timeRange: TimeRange
	public var frames: [Frame]

	public init(
		frames: [FrameData<[HumanBodyPoseObservation]>],
		timeRange: CMTimeRange,
		timelineOrigin: CMTime,
		sampleInterval: Double,
	) {
		schemaVersion = Self.currentSchemaVersion
		coordinateSystem = "normalized, lower-left origin"
		self.sampleInterval = sampleInterval
		self.timeRange = TimeRange(
			startTime: (timeRange.start - timelineOrigin).seconds,
			endTime: (timeRange.end - timelineOrigin).seconds,
		)
		self.frames = frames.map { frame in
			Frame(
				timestamp: (frame.presentationTime - timelineOrigin).seconds,
				poses: frame.value.map { observation in
					Pose(
						id: observation.uuid,
						confidence: observation.confidence,
						joints: Dictionary(
							uniqueKeysWithValues: observation.allJoints().map { jointName, joint in
								(
									jointName.rawValue,
									Joint(
										x: Double(joint.location.x),
										y: Double(joint.location.y),
										confidence: joint.confidence,
									),
								)
							},
						),
					)
				},
			)
		}
	}
}
