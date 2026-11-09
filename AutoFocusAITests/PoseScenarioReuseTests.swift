import CoreGraphics
import CoreMedia
import Foundation
import Testing
import Vision
@testable import AutoFocusCore

// Geometry is generated from the hand-authored skeleton in Analysis-Fixtures.md.
// Confidence, visibility, identity, gestures, and movement use synthetic constants.
struct PoseScenarioReuseTests {
	private final class BundleMarker: NSObject {}
	enum Scenario: String, CaseIterable, Sendable {
		case walkingAndTurning
		case occlusionAndReentry
		case multiplePeople
		case gesturesAndHeadDips
	}

	private actor TraceDetector {
		let scenario: Scenario
		let template: Data
		var batches: [[CMTime]] = []

		init(_ scenario: Scenario) throws {
			self.scenario = scenario
			let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "pose-observation", withExtension: "json"))
			template = try Data(contentsOf: url)
		}

		func samples(_ requests: [PoseVideoAnalyzer.SampleRequest]) throws -> [PoseAnalysisFile.Sample] {
			batches.append(requests.map(\.requestedTime))
			return try requests.map { request in
				let actual = request.context.extractionTime.cmTime
				let elapsed = (actual - PoseScenarioReuseTests.selection.start).seconds
				var poses: [HumanBodyPoseObservation] = []
				if scenario != .occlusionAndReentry || elapsed < 3 || elapsed >= 5 {
					let turned = scenario == .walkingAndTurning && elapsed >= 2 && elapsed < 4
					let shoulderHidden = scenario == .walkingAndTurning && elapsed >= 4.5 && elapsed < 5.5
					let armRaise = scenario == .gesturesAndHeadDips ? max(0, sin(elapsed * .pi / 4)) : 0
					let headDip = scenario == .gesturesAndHeadDips ? max(0, sin(elapsed * .pi / 3)) * 0.06 : 0
					let speaker = try PoseScenarioReuseTests.pose(template, center: PoseScenarioReuseTests.speakerX(elapsed), scale: 1, id: 1, faceHidden: turned, shoulderHidden: shoulderHidden, armRaise: armRaise, headDip: headDip)
					poses = [speaker]
					if scenario == .multiplePeople, elapsed >= 2 {
						let background = try PoseScenarioReuseTests.pose(template, center: 0.15, scale: 0.5, id: 2)
						poses = Int(elapsed).isMultiple(of: 2) ? [background, speaker] : [speaker, background]
					}
				}
				let frame = FrameData(presentationTime: actual, value: poses)
				return try PoseAnalysisFile.Sample(requestedTime: request.requestedTime, frames: [frame], context: request.context)
			}
		}
	}

	private static var selection: CMTimeRange {
		CMTimeRange(start: time(120.125), end: time(132.125))
	}

	private static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

	private static func speakerX(_ elapsed: Double) -> Double {
		switch elapsed {
		case ..<2: 0.4 + max(0, elapsed) * 0.1
		case ..<4: 0.6
		case ..<6: 0.6 + (elapsed - 4) * 0.06
		case ..<8: 0.72 - (elapsed - 6) * 0.11
		default: max(0.35, 0.5 - (elapsed - 8) * 0.05)
		}
	}

	private static func pose(_ template: Data, center: Double, scale: Double, id: Int, faceHidden: Bool = false, shoulderHidden: Bool = false, armRaise: Double = 0, headDip: Double = 0) throws -> HumanBodyPoseObservation {
		var json = try #require(JSONSerialization.jsonObject(with: template) as? [String: Any])
		var joints = try #require(json["allJoints"] as? [Any])
		let faceNames: Set<String> = ["leftEar", "rightEar", "leftEye", "rightEye", "nose"]
		for index in stride(from: 1, to: joints.count, by: 2) {
			var joint = try #require(joints[index] as? [String: Any])
			let name = try #require(joint["jointName"] as? String)
			var location = try #require(joint["location"] as? [String: Any])
			let point = try #require(location["cgPoint"] as? [Double])
			let armOffset = name.hasSuffix("Wrist") ? armRaise * 0.4 : name.hasSuffix("Elbow") ? armRaise * 0.25 : 0
			let faceOffset = faceNames.contains(name) ? -headDip : 0
			location["cgPoint"] = [center + (point[0] - 0.5) * scale, 0.5 + (point[1] - 0.5 + armOffset + faceOffset) * scale]
			joint["location"] = location
			joint["confidence"] = faceHidden && faceNames.contains(name) || shoulderHidden && name == "leftShoulder" ? 0 : 1
			joints[index] = joint
		}
		json["allJoints"] = joints
		var observation = try #require(json["observation"] as? [String: Any])
		observation["uuid"] = String(format: "00000000-0000-0000-0000-%012d", id)
		json["observation"] = observation
		return try JSONDecoder().decode(HumanBodyPoseObservation.self, from: JSONSerialization.data(withJSONObject: json))
	}

	private static func cache(_ detector: TraceDetector, samples: [PoseAnalysisFile.Sample] = []) -> SharedPoseFrameProvider {
		SharedPoseFrameProvider(samples: samples) { requests, _ in try await detector.samples(requests) }
	}

	private static func requests(_ times: [CMTime], selection: CMTimeRange, interval: CMTime) throws -> [PoseVideoAnalyzer.SampleRequest] {
		try PoseVideoAnalyzer.sampleRequests(at: times, sampleInterval: interval, nominalFrameRate: 30, timeRange: selection, restrictsToTimeRange: true, strategy: .individualFrames)
	}

	private static func source(_ cache: SharedPoseFrameProvider, selection: CMTimeRange = Self.selection, interval: CMTime = Self.time(1)) async throws -> ReframingSourceAnalysis {
		let times = PoseVideoAnalyzer.requestedTimes(for: selection, sampleInterval: interval)
		let frames = try await cache.frames(for: requests(times, selection: selection, interval: interval), phase: .initial)
		let metadata = try PoseAnalysisFile(
			source: .init(canonicalPath: "/synthetic-source.mov", fileSize: 100, modificationDate: Date(timeIntervalSince1970: 0), trackID: 1, naturalSize: CGSize(width: 3840, height: 2160), preferredTransform: .identity, timeRange: CMTimeRange(start: time(100), end: time(200))),
			detection: .init(configuration: .init()), selectedTimeRange: selection, samples: [],
		)
		return ReframingSourceAnalysis(sourceSize: CGSize(width: 3840, height: 2160), poseFrames: frames, timeRange: selection, sharedPoseFrameProvider: cache, poseFrameProvider: { times in
			try await cache.frames(for: Self.requests(times, selection: selection, interval: interval))
		}, analysisMetadata: metadata)
	}

	private static func renderBoth(_ source: ReframingSourceAnalysis) async throws -> [ReframingAnalysis] {
		var result: [ReframingAnalysis] = []
		for size in [VideoOutputSize.fullHDLandscape, .fullHDVertical] {
			try await result.append(VideoReframer(configuration: .init(outputSize: size)).reframe(source))
		}
		return result
	}

	@Test(arguments: Scenario.allCases)
	func cachedScenariosPreserveSubjectSelectionAndIndependentCropPaths(_ scenario: Scenario) async throws {
		let detector = try TraceDetector(scenario)
		let cache = Self.cache(detector)
		let source = try await Self.source(cache)
		let original = try await Self.renderBoth(source)
		let file = try await source.poseAnalysisFile()
		let restored = try JSONDecoder().decode(PoseAnalysisFile.self, from: JSONEncoder().encode(file))
		let loadedDetector = try TraceDetector(scenario)
		let loadedCache = Self.cache(loadedDetector, samples: restored.samples)
		let loadedSource = try await Self.source(loadedCache)
		let repeated = try await Self.renderBoth(loadedSource)

		#expect(await loadedDetector.batches.isEmpty)
		#expect(await loadedCache.statistics.newRequests == 0)
		#expect(restored.source.timeRange.start.cmTime.seconds == 100)
		#expect(restored.selectedTimeRange.start.cmTime == Self.selection.start)
		#expect(loadedSource.poseFrames.map(\.presentationTime) == source.poseFrames.map(\.presentationTime))
		#expect(original[0].shotStates.map(\.value.bounds) != original[1].shotStates.map(\.value.bounds))
		for (first, second) in zip(original, repeated) {
			#expect(second.shotStates.map(\.presentationTime) == first.shotStates.map(\.presentationTime))
			#expect(second.shotStates.map(\.value.bounds) == first.shotStates.map(\.value.bounds))
			#expect(second.shotStates.map(\.value.subjectCenter) == first.shotStates.map(\.value.subjectCenter))
			#expect(second.shotStates.allSatisfy { $0.value.bounds.size == second.renderSize })
			#expect(second.shotStates.allSatisfy { $0.value.bounds.minX >= 0 && $0.value.bounds.minY >= 0 && $0.value.bounds.maxX <= 3840 && $0.value.bounds.maxY <= 2160 })
			for frame in loadedSource.poseFrames {
				let state = try #require(second.shotStates.first { $0.presentationTime == frame.presentationTime })
				if frame.value.isEmpty {
					#expect(state.value.subjectCenter == nil)
				} else {
					let x = try #require(state.value.subjectCenter?.x)
					let expected = Self.speakerX((frame.presentationTime - Self.selection.start).seconds) * 3840
					// Torso fallback during partial occlusion can shift the anchor;
					// the smaller background person is more than 600 pixels away.
					#expect(abs(x - expected) < 160)
				}
			}
		}
		if scenario == .multiplePeople {
			#expect(restored.samples.flatMap(\.frames).contains { $0.poses.count == 2 })
		}
		if scenario == .occlusionAndReentry {
			#expect(restored.samples.flatMap(\.frames).contains { $0.poses.isEmpty })
		}
	}

	@Test
	func differentTrackingPrecisionFillsNewProbesThenReusesThem() async throws {
		let detector = try TraceDetector(.walkingAndTurning)
		let cache = Self.cache(detector)
		let source = try await Self.source(cache)
		_ = try await Self.renderBoth(source)
		let saved = try await source.poseAnalysisFile()
		let loadedDetector = try TraceDetector(.walkingAndTurning)
		let loadedCache = Self.cache(loadedDetector, samples: saved.samples)
		let loadedSource = try await Self.source(loadedCache)
		let reframer = VideoReframer(configuration: .init(outputSize: .fullHDLandscape, trackingFramesPerSecond: 16))
		let first = try await reframer.reframe(loadedSource)
		let calls = await loadedDetector.batches.count
		#expect(calls > 0)
		let second = try await reframer.reframe(loadedSource)
		#expect(await loadedDetector.batches.count == calls)
		#expect(second.shotStates.map(\.value.bounds) == first.shotStates.map(\.value.bounds))
	}

	@Test
	func narrowerEmptySubrangeDoesNotLeakCachedPeopleFromOtherTimes() async throws {
		let detector = try TraceDetector(.occlusionAndReentry)
		let cache = Self.cache(detector)
		let originalSource = try await Self.source(cache)
		_ = try await Self.renderBoth(originalSource)
		let saved = try await originalSource.poseAnalysisFile()
		let loadedDetector = try TraceDetector(.occlusionAndReentry)
		let loadedCache = Self.cache(loadedDetector, samples: saved.samples)
		let selected = CMTimeRange(start: Self.time(123.125), end: Self.time(125.125))
		let empty = try await Self.source(loadedCache, selection: selected)
		#expect(empty.poseFrames.count == 2)
		#expect(empty.poseFrames.map(\.value.count) == [0, 0])
		#expect(empty.poseFrames.first?.presentationTime == selected.start + CMTime(value: 1, timescale: 30))
		#expect(await loadedDetector.batches == [[selected.start]])
		await #expect(throws: VideoReframerError.self) { try await VideoReframer().reframe(empty) }
	}
}
