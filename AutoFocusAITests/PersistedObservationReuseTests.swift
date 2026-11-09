import CoreGraphics
import CoreMedia
import Foundation
import Testing
import Vision
@testable import AutoFocusCore

struct PersistedObservationReuseTests {
	private enum Failure: Error, Equatable { case extraction }
	private final class BundleMarker: NSObject {}

	private actor Detector {
		var batches: [[CMTime]] = []
		var failuresRemaining = 0
		var omittedTimes: Set<CMTime> = []
		let poses: [HumanBodyPoseObservation]
		let actualOffset: CMTime

		init(poses: [HumanBodyPoseObservation] = [], actualOffset: CMTime = .zero) {
			self.poses = poses
			self.actualOffset = actualOffset
		}

		func failNextBatch() { failuresRemaining += 1 }
		func omit(_ times: Set<CMTime>) { omittedTimes = times }

		func samples(_ requests: [PoseVideoAnalyzer.SampleRequest]) throws -> [PoseAnalysisFile.Sample] {
			batches.append(requests.map(\.requestedTime))
			if failuresRemaining > 0 {
				failuresRemaining -= 1
				throw Failure.extraction
			}
			return try requests.compactMap { request in
				guard !omittedTimes.contains(request.requestedTime) else { return nil }
				let index = max(0, min(poses.count - 1, Int(request.requestedTime.seconds - 280)))
				let actualTime = request.context.extractionTime.cmTime + actualOffset
				let frame = FrameData(presentationTime: actualTime, value: poses.isEmpty ? [] : [poses[index]])
				let frames = actualTime >= request.timeRange.start && actualTime < request.timeRange.end ? [frame] : []
				return try PoseAnalysisFile.Sample(requestedTime: request.requestedTime, frames: frames, context: request.context)
			}
		}
	}

	private actor PausedDetector {
		var calls = 0
		var started = false
		var startedWaiter: CheckedContinuation<Void, Never>?
		var releaseWaiter: CheckedContinuation<Void, Never>?

		func waitUntilStarted() async {
			if started { return }
			await withCheckedContinuation { startedWaiter = $0 }
		}

		func release() { releaseWaiter?.resume(); releaseWaiter = nil }

		func samples(_ requests: [PoseVideoAnalyzer.SampleRequest]) async throws -> [PoseAnalysisFile.Sample] {
			calls += 1
			if calls == 1 {
				started = true
				startedWaiter?.resume()
				startedWaiter = nil
				// Deliberately ignores cancellation to verify the cache checks it.
				await withCheckedContinuation { releaseWaiter = $0 }
			}
			return try requests.map { request in
				try PoseAnalysisFile.Sample(requestedTime: request.requestedTime, frames: [FrameData(presentationTime: request.context.extractionTime.cmTime, value: [])], context: request.context)
			}
		}
	}

	private static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
	private static var range: CMTimeRange { CMTimeRange(start: time(280), end: time(284)) }

	private static func requests(_ times: [CMTime], range: CMTimeRange = Self.range, restricted: Bool = true, strategy: PoseFrameSelectionStrategy = .individualFrames) throws -> [PoseVideoAnalyzer.SampleRequest] {
		try PoseVideoAnalyzer.sampleRequests(at: times, sampleInterval: time(1), nominalFrameRate: 30, timeRange: range, restrictsToTimeRange: restricted, strategy: strategy)
	}

	private static func cache(_ detector: Detector, samples: [PoseAnalysisFile.Sample] = []) -> SharedPoseFrameProvider {
		SharedPoseFrameProvider(samples: samples) { requests, _ in try await detector.samples(requests) }
	}

	@Test
	func initialRequestsStayBatchedAndNewIntervalsFillOnlyMissingTimestamps() async throws {
		let detector = Detector()
		let cache = Self.cache(detector)
		let original = try Self.requests([Self.time(280), Self.time(281), Self.time(282)])
		_ = try await cache.frames(for: original, phase: .initial)
		let dense = try Self.requests([Self.time(280), Self.time(280.5), Self.time(281), Self.time(281.5), Self.time(282)])
		_ = try await cache.frames(for: dense, phase: .initial)

		#expect(await detector.batches == [[Self.time(280), Self.time(281), Self.time(282)], [Self.time(280.5), Self.time(281.5)]])
		#expect(await cache.statistics.newRequests == 5)
		#expect(await cache.statistics.cachedRequests == 3)
	}

	@Test
	func selectedBoundaryAndInteriorRequestsDoNotCollide() async throws {
		let detector = Detector()
		let cache = Self.cache(detector)
		let selected = try Self.requests([Self.time(280)])
		let interior = try Self.requests([Self.time(280)], range: CMTimeRange(start: Self.time(279), end: Self.time(284)))
		let first = try await cache.frames(for: selected)
		let second = try await cache.frames(for: interior)
		_ = try await cache.frames(for: selected)

		#expect(first.first?.presentationTime == Self.time(280) + CMTime(value: 1, timescale: 30))
		#expect(second.first?.presentationTime == Self.time(280))
		#expect(await detector.batches.count == 2)
		#expect(try await cache.snapshot().count == 2)
	}

	@Test
	func implicitWholeTrackAndExplicitStartHaveDifferentExtractionContexts() throws {
		let implicit = try Self.requests([Self.time(280)], restricted: false)
		let explicit = try Self.requests([Self.time(280)], restricted: true)
		#expect(implicit.first?.context.extractionTime.cmTime == Self.time(280))
		#expect(explicit.first?.context.extractionTime.cmTime == Self.time(280) + CMTime(value: 1, timescale: 30))
	}

	@Test
	func extendingSequentialRangeReusesExistingPositiveObservations() async throws {
		let detector = Detector()
		let cache = Self.cache(detector)
		let short = try Self.requests([Self.time(280), Self.time(281)], range: CMTimeRange(start: Self.time(280), end: Self.time(282)), strategy: .sequentialReader)
		let extended = try Self.requests([Self.time(280), Self.time(281), Self.time(282)], strategy: .sequentialReader)
		_ = try await cache.frames(for: short, phase: .initial)
		_ = try await cache.frames(for: extended, phase: .initial)
		#expect(await detector.batches == [[Self.time(280), Self.time(281)], [Self.time(282)]])
	}

	@Test
	func shorterSequentialWindowDoesNotDiscardKnownFrameForLaterReuse() async throws {
		let detector = Detector(actualOffset: CMTime(value: 1, timescale: 30))
		let cache = Self.cache(detector)
		let time = Self.time(281.9)
		let original = try Self.requests([time], strategy: .sequentialReader)
		let shorter = try Self.requests([time], range: CMTimeRange(start: Self.time(280), end: Self.time(281.92)), strategy: .sequentialReader)
		let first = try await cache.frames(for: original)
		#expect(first.count == 1)
		#expect(try await cache.frames(for: shorter).isEmpty)
		let saved = try await cache.snapshot()
		#expect(saved.count == 1)
		#expect(saved.first?.frames.first?.actualTime.cmTime == first.first?.presentationTime)
		let repeated = try await cache.frames(for: original)
		#expect(repeated.map(\.presentationTime) == first.map(\.presentationTime))
		#expect(await detector.batches.count == 2)
		let loadedDetector = Detector()
		let loaded = Self.cache(loadedDetector, samples: saved)
		#expect(try await loaded.frames(for: original).map(\.presentationTime) == first.map(\.presentationTime))
		#expect(await loadedDetector.batches.isEmpty)
	}

	@Test
	func missingDecodedFramesAreNotPersistedButEmptySubjectObservationsAre() async throws {
		let requests = try Self.requests([Self.time(280), Self.time(281)])
		let noFrame = try PoseAnalysisFile.Sample(requestedTime: requests[0].requestedTime, frames: [], context: requests[0].context)
		let emptySubjects = try PoseAnalysisFile.Sample(requestedTime: requests[1].requestedTime, frames: [FrameData(presentationTime: Self.time(281), value: [])], context: requests[1].context)
		let detector = Detector()
		let cache = Self.cache(detector, samples: [noFrame, emptySubjects])
		#expect(try await cache.snapshot().count == 1)
		_ = try await cache.frames(for: requests)
		#expect(await detector.batches == [[Self.time(280)]])
		let saved = try await cache.snapshot()
		#expect(saved.count == 2)
		#expect(saved.flatMap(\.frames).map(\.poses.count) == [0, 0])
	}

	@Test
	func skippedExtractionRemainsRetryableWithoutRepeatingSuccessfulObservations() async throws {
		let detector = Detector()
		await detector.omit([Self.time(281)])
		let cache = Self.cache(detector)
		let requests = try Self.requests([Self.time(280), Self.time(281)])
		#expect(try await cache.frames(for: requests).count == 1)
		#expect(try await cache.snapshot().count == 1)
		await detector.omit([])
		#expect(try await cache.frames(for: requests).count == 2)
		#expect(await detector.batches == [[Self.time(280), Self.time(281)], [Self.time(281)]])
	}

	@Test
	func failedBatchClearsEveryPendingKeyForRetry() async throws {
		let detector = Detector()
		await detector.failNextBatch()
		let cache = Self.cache(detector)
		let requests = try Self.requests([Self.time(280), Self.time(281)])
		await #expect(throws: Failure.extraction) { try await cache.frames(for: requests) }
		#expect(try await cache.frames(for: [requests[1]]).count == 1)
		#expect(await detector.batches == [[Self.time(280), Self.time(281)], [Self.time(281)]])
	}

	@Test
	func cancellationClearsAllPendingKeysEvenIfDecoderReturnsSuccessfully() async throws {
		let detector = PausedDetector()
		let cache = SharedPoseFrameProvider { requests, _ in try await detector.samples(requests) }
		let requests = try Self.requests([Self.time(280), Self.time(281)])
		let task = Task { try await cache.frames(for: requests) }
		await detector.waitUntilStarted()
		task.cancel()
		await detector.release()
		await #expect(throws: CancellationError.self) { try await task.value }
		#expect(try await cache.frames(for: [requests[1]]).count == 1)
		#expect(await detector.calls == 2)
	}

	@Test
	func roundTripReframesBothShapesWithoutRepeatingInitialOrAdaptiveDetection() async throws {
		let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "pose-observation", withExtension: "json"))
		let pose = try JSONDecoder().decode(HumanBodyPoseObservation.self, from: Data(contentsOf: url))
		let shifted = try Self.shifted(pose, by: -0.2)
		let detector = try Detector(poses: [shifted, pose, Self.shifted(pose, by: 0.1), shifted])
		let cache = Self.cache(detector)
		let metadata = try Self.metadata()
		let source = try await Self.analysis(cache: cache, metadata: metadata)
		var original: [ReframingAnalysis] = []
		for size in [VideoOutputSize.fullHDLandscape, .fullHDVertical] {
			try await original.append(VideoReframer(configuration: .init(outputSize: size)).reframe(source))
		}
		let encoded = try await JSONEncoder().encode(source.poseAnalysisFile())
		let decoded = try JSONDecoder().decode(PoseAnalysisFile.self, from: encoded)
		#expect(decoded.samples.count > 4)
		let repeatedDetector = Detector(poses: [pose])
		let repeatedCache = Self.cache(repeatedDetector, samples: decoded.samples)
		let repeatedSource = try await Self.analysis(cache: repeatedCache, metadata: decoded)
		for (index, size) in [VideoOutputSize.fullHDLandscape, .fullHDVertical].enumerated() {
			let repeated = try await VideoReframer(configuration: .init(outputSize: size)).reframe(repeatedSource)
			#expect(repeated.shotStates.map(\.presentationTime) == original[index].shotStates.map(\.presentationTime))
			#expect(repeated.shotStates.map(\.value.bounds) == original[index].shotStates.map(\.value.bounds))
		}
		#expect(await repeatedDetector.batches.isEmpty)
		#expect(await repeatedCache.statistics.newRequests == 0)
		#expect(repeatedSource.poseFrames.first?.presentationTime.seconds ?? 0 >= 280)
	}

	private static func analysis(cache: SharedPoseFrameProvider, metadata: PoseAnalysisFile) async throws -> ReframingSourceAnalysis {
		let requests = try Self.requests([time(280), time(281), time(282), time(283)])
		return try await ReframingSourceAnalysis(
			sourceSize: CGSize(width: 3840, height: 2160),
			poseFrames: cache.frames(for: requests, phase: .initial),
			timeRange: range,
			sharedPoseFrameProvider: cache,
			poseFrameProvider: { times in try await cache.frames(for: Self.requests(times)) },
			analysisMetadata: metadata,
		)
	}

	private static func metadata() throws -> PoseAnalysisFile {
		try PoseAnalysisFile(
			source: .init(canonicalPath: "/recording.mov", fileSize: 100, modificationDate: Date(timeIntervalSince1970: 0), trackID: 1, naturalSize: CGSize(width: 3840, height: 2160), preferredTransform: .identity, timeRange: range),
			detection: .init(configuration: .init()),
			selectedTimeRange: range,
			samples: [],
		)
	}

	private static func shifted(_ pose: HumanBodyPoseObservation, by offset: Double) throws -> HumanBodyPoseObservation {
		func shift(_ value: Any) -> Any {
			if let array = value as? [Any] { return array.map(shift) }
			guard var dictionary = value as? [String: Any] else { return value }
			if let point = dictionary["cgPoint"] as? [Double], point.count == 2 {
				dictionary["cgPoint"] = [point[0] + offset, point[1]]
				return dictionary
			}
			return dictionary.mapValues(shift)
		}
		let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pose))
		return try JSONDecoder().decode(HumanBodyPoseObservation.self, from: JSONSerialization.data(withJSONObject: shift(value)))
	}
}
