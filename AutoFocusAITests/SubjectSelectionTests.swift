import CoreGraphics
import Foundation
import Testing
import Vision
@testable import AutoFocusCore

struct SubjectSelectionTests {
	@Test(arguments: [false, true])
	func continuityUsesTheSameCompositionPointForEveryCandidate(reverseCandidateOrder: Bool) async throws {
		let speaker = try syntheticPose(
			faceCenter: CGPoint(x: 2000, y: 1650),
			torsoCenter: CGPoint(x: 2000, y: 1300),
			shoulderHalfWidth: 120,
			wristHalfWidth: 250,
			ankleY: 300,
		)
		let bystander = try syntheticPose(
			faceCenter: CGPoint(x: 2450, y: 1850),
			torsoCenter: CGPoint(x: 2450, y: 1500),
			shoulderHalfWidth: 300,
			wristHalfWidth: 450,
			ankleY: 1050,
		)
		let tracker = ShotTracker(sourceSize: CGSize(width: 3840, height: 2160), outputSize: CGSize(width: 1080, height: 1920))
		let preferredCenter = try #require(await tracker.subjectCenter(for: speaker))
		let selected = VideoReframer.primaryPose(
			in: reverseCandidateOrder ? [bystander, speaker] : [speaker, bystander],
			sourceSize: CGSize(width: 3840, height: 2160),
			preferredCenter: preferredCenter,
			maximumDistance: nil,
		)

		// The bystander's full-body box is closer to the speaker's eye line
		// than the speaker's own box center, but their composition point is not.
		#expect(selected?.uuid == speaker.uuid)
	}

	@Test
	func untrackablePoseDoesNotDisplaceAVisibleSubject() throws {
		let speaker = try syntheticPose(
			faceCenter: CGPoint(x: 2000, y: 1650), torsoCenter: CGPoint(x: 2000, y: 1300),
			shoulderHalfWidth: 120, wristHalfWidth: 250, ankleY: 300,
		)
		let obscured = try syntheticPose(
			faceCenter: CGPoint(x: 1900, y: 1950), torsoCenter: CGPoint(x: 1900, y: 1400),
			shoulderHalfWidth: 500, wristHalfWidth: 800, ankleY: 100,
			anchorConfidence: 0,
		)
		let selected = VideoReframer.primaryPose(
			in: [obscured, speaker], sourceSize: CGSize(width: 3840, height: 2160),
			preferredCenter: nil, maximumDistance: nil,
		)
		#expect(selected?.uuid == speaker.uuid)
	}

	/// Fabricated joint geometry, encoded through Vision's native Codable shape.
	/// No production observations or media are used by this regression.
	private func syntheticPose(
		faceCenter: CGPoint,
		torsoCenter: CGPoint,
		shoulderHalfWidth: CGFloat,
		wristHalfWidth: CGFloat,
		ankleY: CGFloat,
		anchorConfidence: Double = 1,
	) throws -> HumanBodyPoseObservation {
		let joints: [String: CGPoint] = [
			"nose": faceCenter,
			"leftEye": CGPoint(x: faceCenter.x - 20, y: faceCenter.y + 10),
			"rightEye": CGPoint(x: faceCenter.x + 20, y: faceCenter.y + 10),
			"leftEar": CGPoint(x: faceCenter.x - 30, y: faceCenter.y + 5),
			"rightEar": CGPoint(x: faceCenter.x + 30, y: faceCenter.y + 5),
			"neck": CGPoint(x: torsoCenter.x, y: torsoCenter.y + 250),
			"leftShoulder": CGPoint(x: torsoCenter.x - shoulderHalfWidth, y: torsoCenter.y + 200),
			"rightShoulder": CGPoint(x: torsoCenter.x + shoulderHalfWidth, y: torsoCenter.y + 200),
			"root": CGPoint(x: torsoCenter.x, y: torsoCenter.y - 250),
			"leftHip": CGPoint(x: torsoCenter.x - 100, y: torsoCenter.y - 300),
			"rightHip": CGPoint(x: torsoCenter.x + 100, y: torsoCenter.y - 300),
			"leftWrist": CGPoint(x: torsoCenter.x - wristHalfWidth, y: torsoCenter.y),
			"rightWrist": CGPoint(x: torsoCenter.x + wristHalfWidth, y: torsoCenter.y),
			"leftAnkle": CGPoint(x: torsoCenter.x - 50, y: ankleY),
			"rightAnkle": CGPoint(x: torsoCenter.x + 50, y: ankleY),
		]
		let anchorJoints: Set<String> = [
			"nose", "leftEye", "rightEye", "leftEar", "rightEar", "neck", "root",
			"leftShoulder", "rightShoulder", "leftHip", "rightHip",
		]
		let allJoints: [Any] = joints.sorted { $0.key < $1.key }.flatMap { name, point -> [Any] in
			[name, [
				"jointName": name,
				"confidence": anchorJoints.contains(name) ? anchorConfidence : 1,
				"location": ["cgPoint": [point.x / 3840, point.y / 2160]],
			]]
		}
		let encoded: [String: Any] = [
			"allJoints": allJoints,
			"leftHand": NSNull(),
			"rightHand": NSNull(),
			"observation": [
				"confidence": 1.0,
				"uuid": UUID().uuidString,
				"requestDescriptor": ["detectHumanBodyPoseRequest": ["_0": ["revision2": [:]]]],
				"timeRange": ["start": [:], "end": [:]],
			],
		]
		return try JSONDecoder().decode(HumanBodyPoseObservation.self, from: JSONSerialization.data(withJSONObject: encoded))
	}
}
