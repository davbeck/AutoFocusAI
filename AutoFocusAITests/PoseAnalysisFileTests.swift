import AVFoundation
import Foundation
import Testing
import Vision
@testable import AutoFocusCore

struct PoseAnalysisFileTests {
	@Test
	func syntheticObservationMatchesHandAuthoredSkeleton() throws {
		let observation = try observationFixture()
		let expected: [HumanBodyPoseObservation.JointName: CGPoint] = [
			.leftEar: CGPoint(x: 0.46, y: 0.87), .leftEye: CGPoint(x: 0.48, y: 0.89),
			.rightEar: CGPoint(x: 0.54, y: 0.87), .rightEye: CGPoint(x: 0.52, y: 0.89),
			.neck: CGPoint(x: 0.5, y: 0.8), .nose: CGPoint(x: 0.5, y: 0.87),
			.leftShoulder: CGPoint(x: 0.4, y: 0.77), .rightShoulder: CGPoint(x: 0.6, y: 0.77),
			.leftElbow: CGPoint(x: 0.33, y: 0.63), .rightElbow: CGPoint(x: 0.67, y: 0.63),
			.leftWrist: CGPoint(x: 0.3, y: 0.5), .rightWrist: CGPoint(x: 0.7, y: 0.5),
			.root: CGPoint(x: 0.5, y: 0.5),
			.leftHip: CGPoint(x: 0.45, y: 0.48), .rightHip: CGPoint(x: 0.55, y: 0.48),
			.leftKnee: CGPoint(x: 0.45, y: 0.28), .rightKnee: CGPoint(x: 0.55, y: 0.28),
			.leftAnkle: CGPoint(x: 0.45, y: 0.08), .rightAnkle: CGPoint(x: 0.55, y: 0.08),
		]
		#expect(observation.uuid == UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
		#expect(observation.confidence == 1)
		#expect(observation.leftHand == nil)
		#expect(observation.rightHand == nil)
		#expect(observation.allJoints().count == expected.count)
		for (name, position) in expected {
			let joint = try #require(observation.joint(for: name))
			#expect(joint.confidence == 1)
			#expect(abs(joint.location.x - position.x) < 0.000001)
			#expect(abs(joint.location.y - position.y) < 0.000001)
		}
	}

	@Test
	func roundTripPreservesNativeObservationsRationalTimesAndEmptyRequests() throws {
		let observation = try observationFixture()
		let requested = CMTime(value: 108_108, timescale: 30000)
		let actual = requested + CMTime(value: 1001, timescale: 30000)
		let context = try requestContext(at: requested)
		let samples = try [
			PoseAnalysisFile.Sample(
				requestedTime: requested,
				frames: [FrameData(presentationTime: actual, value: [observation])],
				context: context,
			),
			PoseAnalysisFile.Sample(
				requestedTime: requested + CMTime(value: 1001, timescale: 1000),
				frames: [FrameData(presentationTime: requested + CMTime(value: 1001, timescale: 1000), value: [])],
				context: context,
			),
			PoseAnalysisFile.Sample(
				requestedTime: requested + CMTime(value: 2002, timescale: 1000),
				frames: [],
				context: context,
			),
		]
		let original = try analysis(samples: samples)
		let restored = try JSONDecoder().decode(PoseAnalysisFile.self, from: JSONEncoder().encode(original))

		#expect(restored.source == original.source)
		#expect(restored.selectedTimeRange == original.selectedTimeRange)
		#expect(restored.samples.count == 3)
		#expect(restored.samples[0].requestedTime.value == requested.value)
		#expect(restored.samples[0].requestedTime.timescale == requested.timescale)
		#expect(restored.samples[0].frames[0].frameData.presentationTime == actual)
		#expect(restored.samples[0].frames[0].poses == [observation])
		#expect(restored.samples[0].frames[0].poses[0].allJoints() == observation.allJoints())
		#expect(restored.samples[1].frames.count == 1)
		#expect(restored.samples[1].frames[0].poses.isEmpty)
		#expect(restored.samples[2].frames.isEmpty)
	}

	@Test
	func rationallyEquivalentTimesShareEqualityAndHashingWithoutLosingRepresentation() throws {
		let a = try PoseAnalysisFile.Time(CMTime(value: 1001, timescale: 30000, flags: .valid, epoch: 7))
		let b = try PoseAnalysisFile.Time(CMTime(value: 2002, timescale: 60000, flags: .valid, epoch: 7))
		let restored = try JSONDecoder().decode(PoseAnalysisFile.Time.self, from: JSONEncoder().encode(b))

		#expect(a == b)
		#expect(Set([a, b]).count == 1)
		#expect(restored.value == 2002)
		#expect(restored.timescale == 60000)
		#expect(restored.epoch == 7)
	}

	@Test
	func sameTimestampCanRetainDifferentExtractionContextsAndEarlierCoverage() throws {
		let requested = CMTime(value: 108_108, timescale: 30000)
		let interior = try requestContext(at: requested)
		let boundary = try PoseAnalysisFile.RequestContext(
			strategy: "individualFrames",
			extractionTime: requested + CMTime(value: 1001, timescale: 30000),
			toleranceBefore: .zero,
			toleranceAfter: CMTime(value: 1001, timescale: 30000),
		)
		let samples = try [interior, boundary].map {
			try PoseAnalysisFile.Sample(requestedTime: requested, frames: [], context: $0)
		}
		let file = try PoseAnalysisFile(
			source: sourceIdentity(),
			detection: .init(configuration: .init()),
			selectedTimeRange: CMTimeRange(start: CMTime(seconds: 10, preferredTimescale: 600), duration: CMTime(seconds: 5, preferredTimescale: 600)),
			samples: samples,
		)
		let restored = try JSONDecoder().decode(PoseAnalysisFile.self, from: JSONEncoder().encode(file))

		#expect(restored.samples.count == 2)
		#expect(restored.samples[0].context != restored.samples[1].context)
		#expect(restored.samples[0].requestedTime.cmTime < restored.selectedTimeRange.cmTimeRange.start)
	}

	@Test
	func changedSourceMetadataIsRejectedWithAnActionableError() throws {
		let file = try analysis()
		var changedPath = file.source
		changedPath.canonicalPath += ".moved"
		var changedSize = file.source
		changedSize.fileSize += 1
		var changedDate = file.source
		changedDate.modificationDate += 0.125
		var changedTrack = file.source
		changedTrack.trackID += 1
		var changedGeometry = file.source
		changedGeometry.naturalSize.width += 2
		var changedTransform = file.source
		changedTransform.preferredTransform.tx += 1
		var changedOrigin = file.source
		changedOrigin.timeRange = try PoseAnalysisFile.TimeRange(CMTimeRange(
			start: file.source.timeRange.cmTimeRange.start + CMTime(value: 1, timescale: 30000),
			duration: file.source.timeRange.cmTimeRange.duration,
		))
		for source in [changedPath, changedSize, changedDate, changedTrack, changedGeometry, changedTransform, changedOrigin] {
			#expect(throws: PoseAnalysisFile.Error.self) {
				try file.validate(source: source, detection: file.detection)
			}
		}
		let error = PoseAnalysisFile.Error.incompatibleSource("modification date")
		#expect(error.errorDescription?.contains("modification date") == true)
		#expect(error.recoverySuggestion?.contains("--save-analysis") == true)
	}

	@Test
	func detectionCompatibilityExcludesIntervalAndSubrangeButIncludesRevisionAndDecodeSize() throws {
		let file = try analysis()
		let changedSampling = PoseVideoAnalysisConfiguration(
			maximumFramesPerSecond: 2,
			timeRange: CMTimeRange(start: CMTime(seconds: 20, preferredTimescale: 600), duration: CMTime(seconds: 5, preferredTimescale: 600)),
			frameSelectionStrategy: .sequentialReader,
		)
		try file.validate(source: file.source, detection: .init(configuration: changedSampling))
		var changedLongEdge = file.detection
		changedLongEdge.maximumDetectionLongEdge = 1080
		var changedRevision = file.detection
		changedRevision.visionRevision = "anotherRevision"
		var changedHands = file.detection
		changedHands.detectsHands = true
		var changedAnalyzer = file.detection
		changedAnalyzer.analyzerVersion += 1
		for detection in [changedLongEdge, changedRevision, changedHands, changedAnalyzer] {
			#expect(throws: PoseAnalysisFile.Error.self) {
				try file.validate(source: file.source, detection: detection)
			}
		}
	}

	@Test
	func schemaAndMalformedRationalTimesAreRejectedBeforeReuse() throws {
		let file = try analysis()
		var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(file)) as? [String: Any])
		json["schemaVersion"] = 99
		#expect(throws: PoseAnalysisFile.Error.self) {
			try JSONDecoder().decode(PoseAnalysisFile.self, from: JSONSerialization.data(withJSONObject: json))
		}
		#expect(throws: PoseAnalysisFile.Error.self) {
			try JSONDecoder().decode(PoseAnalysisFile.Time.self, from: Data(#"{"value":1,"timescale":0,"epoch":0}"#.utf8))
		}
		#expect(throws: PoseAnalysisFile.Error.self) {
			try PoseAnalysisFile.Time(.indefinite)
		}
		#expect(throws: PoseAnalysisFile.Error.self) {
			try PoseAnalysisFile.TimeRange(CMTimeRange(start: .zero, duration: .zero))
		}
		#expect(throws: PoseAnalysisFile.Error.self) {
			try PoseAnalysisFile.RequestContext(strategy: "individualFrames", extractionTime: .zero, toleranceBefore: CMTime(value: -1, timescale: 30), toleranceAfter: .zero)
		}
	}

	@Test
	func legacyPoseReportIsRejectedWithRecreationInstructions() throws {
		let directory = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let url = directory.appendingPathComponent("poses.json")
		try Data(#"{"schemaVersion":1,"coordinateSystem":"normalized, lower-left origin","sampleInterval":5,"timeRange":{"startTime":0,"endTime":10},"frames":[]}"#.utf8).write(to: url)
		do {
			_ = try PoseAnalysisFile.load(from: url)
			Issue.record("A raw pose report was accepted as reusable analysis.")
		} catch let error as PoseAnalysisFile.Error {
			#expect(error.errorDescription?.contains("--pose-data") == true)
			#expect(error.recoverySuggestion?.contains("--save-analysis") == true)
			#expect(error.debugDescription.contains("source"))
		}
	}

	@Test
	func localSourceIdentityRoundTripsFractionalModificationDateAndCanonicalizesSymlinks() async throws {
		let directory = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let source = directory.appendingPathComponent("source.mov")
		let fixture = try #require(Bundle(for: BundleToken.self).url(forResource: "analysis-source", withExtension: "mov"))
		try FileManager.default.copyItem(at: fixture, to: source)
		try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_794_182_000.1234567)], ofItemAtPath: source.path)
		let alias = directory.appendingPathComponent("alias.mov")
		try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
		let asset = AVURLAsset(url: source)
		let file = try await PoseAnalysisFile(asset: asset, configuration: .init(), samples: [])
		let analysisURL = directory.appendingPathComponent("analysis.json")
		try file.write(to: analysisURL)
		let restored = try PoseAnalysisFile.load(from: analysisURL)
		try await restored.validate(asset: AVURLAsset(url: alias), configuration: .init(maximumFramesPerSecond: 2))
		#expect(restored.source.modificationDate == file.source.modificationDate)
		#expect(restored.source.canonicalPath == source.resolvingSymlinksInPath().path)
		#expect(restored.source.fileSize > 0)
		try FileManager.default.setAttributes([.modificationDate: file.source.modificationDate + 1], ofItemAtPath: source.path)
		await #expect(throws: PoseAnalysisFile.Error.self) {
			try await restored.validate(asset: AVURLAsset(url: source), configuration: .init())
		}
	}

	private final class BundleToken {}

	private func observationFixture() throws -> HumanBodyPoseObservation {
		let url = try #require(Bundle(for: BundleToken.self).url(forResource: "pose-observation", withExtension: "json"))
		return try JSONDecoder().decode(HumanBodyPoseObservation.self, from: Data(contentsOf: url))
	}

	private func requestContext(at time: CMTime) throws -> PoseAnalysisFile.RequestContext {
		try .init(strategy: "individualFrames", extractionTime: time, toleranceBefore: CMTime(value: 1001, timescale: 30000), toleranceAfter: CMTime(value: 1001, timescale: 30000))
	}

	private func sourceIdentity() throws -> PoseAnalysisFile.SourceIdentity {
		try .init(
			canonicalPath: "/example/source.mov",
			fileSize: 12345,
			modificationDate: Date(timeIntervalSince1970: 1_794_182_000.1234567),
			trackID: 1,
			naturalSize: CGSize(width: 3840, height: 2160),
			preferredTransform: .identity,
			timeRange: CMTimeRange(start: CMTime(value: 3003, timescale: 1000), duration: CMTime(value: 10010, timescale: 300)),
		)
	}

	private func analysis(samples: [PoseAnalysisFile.Sample] = []) throws -> PoseAnalysisFile {
		try PoseAnalysisFile(
			source: sourceIdentity(),
			detection: .init(configuration: .init()),
			selectedTimeRange: CMTimeRange(start: CMTime(value: 108_108, timescale: 30000), duration: CMTime(value: 1001, timescale: 100)),
			samples: samples,
		)
	}

	private func temporaryDirectory() throws -> URL {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}
}
