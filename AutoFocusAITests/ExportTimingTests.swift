import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import AutoFocusCore

struct ExportTimingTests {
	private enum Cadence: String, CaseIterable, Sendable {
		case integer24, integer25, integer, integer50, integer60
		case fractional24, fractional, fractional60, variable, irregular
	}

	@Test(arguments: Cadence.allCases)
	private func cropExportPreservesSourcePresentationTimes(cadence: Cadence) async throws {
		let directory = try makeDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let source = try source(cadence: cadence)
		let before = try await samples(in: source)
		let final = try #require(before.last)
		let sourceEnd = final.time + final.duration
		let movieDuration = try await source.load(.duration)
		#expect(movieDuration >= sourceEnd)
		#expect((movieDuration - sourceEnd).seconds < 1 / Double(movieDuration.timescale))
		let reframer = VideoReframer()
		let originalMarkers = try await frameMarkers(in: source)
		#expect(originalMarkers == (0 ..< 90).map(UInt8.init))
		var outputSamples: [[Sample]] = []
		for (name, size) in Self.outputShapes {
			let analysis = staticAnalysis(renderSize: size)
			let outputURL = directory.appendingPathComponent("\(name).mov")
			try await reframer.export(asset: source, analysis: analysis, outputURL: outputURL)
			let output = AVURLAsset(url: outputURL)
			let after = try await samples(in: output)
			let outputMarkers = try await frameMarkers(in: output)

			#expect(outputMarkers.count == originalMarkers.count)
			#expect(outputMarkers == originalMarkers)
			#expect(after == before)
			#expect(try await output.load(.duration) == sourceEnd)
			#expect(try await output.loadTracks(withMediaType: .audio).isEmpty)
			let track = try #require(await output.loadTracks(withMediaType: .video).first)
			#expect(try await track.load(.naturalSize) == size)
			outputSamples.append(after)
		}
		#expect(outputSamples[0] == outputSamples[1])
	}

	@Test(arguments: [Cadence.integer, .fractional24, .fractional, .fractional60, .irregular])
	private func comparisonExportsPreserveSourceCadenceForBothShapes(cadence: Cadence) async throws {
		let directory = try makeDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let source = try source(cadence: cadence)
		let sourceSamples = try await samples(in: source)
		let final = try #require(sourceSamples.last)
		let sourceEnd = final.time + final.duration
		let comparison = try await VideoReframer.makeComparisonAsset(from: source)
		for (name, size) in Self.outputShapes {
			let composition = try await VideoReframer().makeComparisonVideoComposition(asset: comparison, analysis: staticAnalysis(renderSize: size))
			let session = try #require(AVAssetExportSession(asset: comparison, presetName: AVAssetExportPresetHighestQuality))
			session.videoComposition = composition
			let outputURL = directory.appendingPathComponent("comparison-\(name).mov")
			try await session.export(to: outputURL, as: .mov)
			let output = AVURLAsset(url: outputURL)
			#expect(try await samples(in: output) == sourceSamples)
			#expect(try await output.load(.duration) == sourceEnd)
			#expect(try await output.loadTracks(withMediaType: .audio).isEmpty)
		}
	}

	@Test
	func subrangeExportsShareElapsedTimingAndIncludeFinalFrame() async throws {
		let directory = try makeDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let frameDuration = CMTime(value: 1001, timescale: 30000)
		let source = try source(cadence: .fractional)
		let range = CMTimeRange(
			start: CMTimeMultiply(frameDuration, multiplier: 11),
			duration: CMTimeMultiply(frameDuration, multiplier: 61),
		)
		var outputs: [[Sample]] = []
		for (name, size) in [("landscape", CGSize(width: 160, height: 90)), ("portrait", CGSize(width: 90, height: 160))] {
			let url = directory.appendingPathComponent("\(name).mov")
			let analysis = staticAnalysis(renderSize: size, timeRange: range)
			let reframer = VideoReframer()
			let composition = try await reframer.makeOutputVideoComposition(asset: source, analysis: analysis)
			let instruction = try #require(composition.instructions.first as? AVVideoCompositionInstruction)
			let ramp = try #require(instruction.layerInstructions.first?.transformRamp(at: range.start))
			#expect(composition.renderSize == size)
			for transform in [ramp.start, ramp.end] {
				#expect(transform.a == 1)
				#expect(transform.b == 0)
				#expect(transform.c == 0)
				#expect(transform.d == 1)
			}
			try await reframer.export(asset: source, analysis: analysis, outputURL: url)
			let output = AVURLAsset(url: url)
			let outputSamples = try await samples(in: output)
			#expect(outputSamples.count == 61)
			#expect(outputSamples.first?.time == .zero)
			#expect(outputSamples.last.map { $0.time + $0.duration } == range.duration)
			#expect(try await output.load(.duration) == range.duration)
			#expect(outputSamples.map(\.time) == (0 ..< 61).map { CMTimeMultiply(frameDuration, multiplier: Int32($0)) })
			outputs.append(outputSamples)
		}
		#expect(outputs[0] == outputs[1])
	}

	@Test(arguments: [Cadence.fractional24, .fractional, .fractional60, .irregular])
	private func nearEndTrimsPreserveFinalContentWithNonzeroOrigin(cadence: Cadence) async throws {
		let directory = try makeDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let source = try source(cadence: cadence)
		let sourceSamples = try await samples(in: source)
		let sourceMarkers = try await frameMarkers(in: source)
		let sourceTrack = try #require(await source.loadTracks(withMediaType: .video).first)
		let sourceTimeScale = try await sourceTrack.load(.naturalTimeScale)
		let composition = AVMutableComposition()
		let track = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
		let origin = CMTime(seconds: 7, preferredTimescale: sourceTimeScale)
		try await track.insertTimeRange(sourceTrack.load(.timeRange), of: sourceTrack, at: origin)
		let first = sourceSamples[sourceSamples.count - 12]
		let last = try #require(sourceSamples.last)
		let range = CMTimeRange(
			start: origin + first.time + CMTimeMultiplyByRatio(first.duration, multiplier: 1, divisor: 2),
			end: origin + last.time + CMTimeMultiplyByRatio(last.duration, multiplier: 3, divisor: 4),
		)
		let expectedTimes = [.zero] + sourceSamples.suffix(11).map { origin + $0.time - range.start }
		let expectedMarkers = Array(sourceMarkers.suffix(12))
		let precision = 1 / Double(sourceTimeScale)
		var outputs: [[Sample]] = []
		for (name, size) in Self.outputShapes {
			let url = directory.appendingPathComponent("tail-\(name).mov")
			try await VideoReframer().export(asset: composition, analysis: staticAnalysis(renderSize: size, timeRange: range), outputURL: url)
			let output = AVURLAsset(url: url)
			let result = try await samples(in: output)
			let markers = try await frameMarkers(in: output)
			#expect(result.count == expectedTimes.count)
			#expect(zip(result, expectedTimes).allSatisfy { abs(($0.time - $1).seconds) <= precision })
			#expect(markers.count == expectedMarkers.count)
			#expect(markers == expectedMarkers)
			let final = try #require(result.last)
			#expect(abs((final.time + final.duration - range.duration).seconds) <= precision)
			let outputDuration = try await output.load(.duration)
			#expect(abs((outputDuration - range.duration).seconds) <= precision)
			outputs.append(result)
		}
		#expect(outputs[0].count == outputs[1].count)
		#expect(zip(outputs[0], outputs[1]).allSatisfy { abs(($0.time - $1.time).seconds) <= precision })
	}

	@Test
	func incomingAudioRetainsItsElapsedTimelineThroughCropExports() async throws {
		let directory = try makeDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let url = try #require(Bundle(for: BundleToken.self).url(forResource: "timing-audio", withExtension: "mov"))
		let source = AVURLAsset(url: url)
		let range = CMTimeRange(start: CMTime(value: 517, timescale: 1000), end: CMTime(value: 2913, timescale: 1000))
		let sourceAudio = try #require(await source.loadTracks(withMediaType: .audio).first)
		let audioTimeScale = try await sourceAudio.load(.naturalTimeScale)
		var outputs: [[Sample]] = []
		for (name, size) in Self.outputShapes {
			let outputURL = directory.appendingPathComponent("audio-\(name).mov")
			try await VideoReframer().export(asset: source, analysis: staticAnalysis(renderSize: size, timeRange: range), outputURL: outputURL)
			let output = AVURLAsset(url: outputURL)
			let tracks = try await output.loadTracks(withMediaType: .audio)
			#expect(tracks.count == 1)
			let audio = try #require(tracks.first)
			let audioRange = try await audio.load(.timeRange)
			#expect(audioRange.start == .zero)
			#expect(abs((audioRange.end - range.duration).seconds) <= 1 / Double(audioTimeScale))
			try await outputs.append(samples(in: output))
		}
		#expect(outputs[0] == outputs[1])
	}

	private static let outputShapes = [
		("landscape", CGSize(width: 192, height: 108)),
		("portrait", CGSize(width: 108, height: 192)),
	]

	private struct Sample: Equatable, Sendable {
		var time: CMTime
		var duration: CMTime
	}

	private func samples(in asset: AVURLAsset) async throws -> [Sample] {
		try await Inspector().samples(at: asset.url)
	}

	private func frameMarkers(in asset: AVURLAsset) async throws -> [UInt8] {
		try await Inspector().frameMarkers(at: asset.url)
	}

	private enum InspectionError: Error {
		case noVideoTrack, readerDidNotStart, readerDidNotFinish, missingPixelBytes
	}

	private actor Inspector {
		// Reader.next() also reaches blocking AVFoundation code on macOS 26.
		// Each inspection owns an independent Dispatch executor, so parallel
		// tests leave cooperative workers available for async media operations.
		nonisolated let queue = DispatchSerialQueue(label: "AutoFocusAI.ExportTimingInspection")
		nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

		func samples(at url: URL) async throws -> [Sample] {
			let asset = AVURLAsset(url: url)
			guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw InspectionError.noVideoTrack }
			let end = try await track.load(.timeRange).end
			let reader = try AVAssetReader(asset: asset)
			let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
			reader.add(output)
			guard reader.startReading() else { throw reader.error ?? InspectionError.readerDidNotStart }
			var frames: [Sample] = []
			while let buffer = output.copyNextSampleBuffer() {
				// Empty marker buffers are not displayed frames. Measure coverage
				// from presentation timestamps and the edited track end.
				guard buffer.numSamples > 0, CMSampleBufferGetTotalSampleSize(buffer) > 0 else { continue }
				frames.append(Sample(time: buffer.presentationTimeStamp, duration: buffer.duration))
			}
			guard reader.status == .completed else { throw reader.error ?? InspectionError.readerDidNotFinish }
			frames.sort { $0.time < $1.time }
			let finalEnd: CMTime
			if let last = frames.last, last.duration.isNumeric, last.duration > .zero {
				// MOV edit headers can round beyond the final actual sample.
				// Trim packet coverage at the edit, without inventing an empty tail.
				finalEnd = min(end, last.time + last.duration)
			} else {
				finalEnd = end
			}
			let times = frames.map(\.time)
			return zip(times, times.dropFirst() + [finalEnd]).map { time, nextTime in
				Sample(time: time, duration: nextTime - time)
			}
		}

		func frameMarkers(at url: URL) async throws -> [UInt8] {
			let asset = AVURLAsset(url: url)
			guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw InspectionError.noVideoTrack }
			let reader = try AVAssetReader(asset: asset)
			let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
				kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
			])
			reader.add(output)
			guard reader.startReading() else { throw reader.error ?? InspectionError.readerDidNotStart }
			var markers: [(CMTime, UInt8)] = []
			while let sample = output.copyNextSampleBuffer() {
				guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
				CVPixelBufferLockBaseAddress(buffer, .readOnly)
				defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
				guard let address = CVPixelBufferGetBaseAddress(buffer) else { throw InspectionError.missingPixelBytes }
				var marker: UInt8 = 0
				for bit in 0 ..< 8 {
					let x = bit * 8 + 4
					if address.load(fromByteOffset: x * 4, as: UInt8.self) > 128 { marker |= 1 << bit }
				}
				markers.append((sample.presentationTimeStamp, marker))
			}
			guard reader.status == .completed else { throw reader.error ?? InspectionError.readerDidNotFinish }
			return markers.sorted { $0.0 < $1.0 }.map(\.1)
		}
	}

	private func makeDirectory() throws -> URL {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return directory
	}

	private final class BundleToken {}

	private func source(cadence: Cadence) throws -> AVURLAsset {
		let url = try #require(Bundle(for: BundleToken.self).url(forResource: "timing-\(cadence.rawValue)", withExtension: "mov"))
		return AVURLAsset(url: url)
	}

	private func staticAnalysis(renderSize: CGSize = CGSize(width: 160, height: 120), timeRange: CMTimeRange? = nil) -> ReframingAnalysis {
		ReframingAnalysis(
			sourceSize: CGSize(width: 320, height: 240),
			renderSize: renderSize,
			shotStates: [FrameData(
				presentationTime: .zero,
				value: ShotState(bounds: CGRect(origin: .zero, size: renderSize), target: .zero, subjectCenter: nil),
			)],
			timeRange: timeRange,
		)
	}
}
