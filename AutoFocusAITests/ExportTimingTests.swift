import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import AutoFocusCore

struct ExportTimingTests {
	private enum Cadence: CaseIterable, Sendable {
		case integer, fractional, variable

		var durations: [CMTime] {
			(0 ..< 90).map { index in
				switch self {
				case .integer:
					CMTime(value: 1000, timescale: 30000)
				case .fractional:
					CMTime(value: 1001, timescale: 30000)
				case .variable:
					CMTime(value: [1001, 2002, 1001, 3003][index % 4], timescale: 30000)
				}
			}
		}
	}

	@Test(arguments: Cadence.allCases)
	private func cropExportPreservesSourcePresentationTimes(cadence: Cadence) async throws {
		let directory = try makeDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let source = try await makeSource(at: directory.appendingPathComponent("source.mov"), durations: cadence.durations)
		let before = try await samples(in: source)
		let reframer = VideoReframer()
		let analysis = staticAnalysis()
		let outputURL = directory.appendingPathComponent("crop.mov")
		try await reframer.export(asset: source, analysis: analysis, outputURL: outputURL)
		let output = AVURLAsset(url: outputURL)
		let after = try await samples(in: output)

		#expect(after.map(\.time) == before.map(\.time))
		#expect(after.map(\.duration) == before.map(\.duration))
		#expect(try await output.load(.duration) == source.load(.duration))
		#expect(try await output.loadTracks(withMediaType: .audio).isEmpty)
		let track = try #require(await output.loadTracks(withMediaType: .video).first)
		#expect(try await track.load(.naturalSize) == analysis.renderSize)
	}

	@Test
	func comparisonExportPreservesFractionalSourcePresentationTimes() async throws {
		let directory = try makeDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let source = try await makeSource(at: directory.appendingPathComponent("source.mov"), durations: Cadence.fractional.durations)
		let sourceSamples = try await samples(in: source)
		let comparison = try await VideoReframer.makeComparisonAsset(from: source)
		let composition = try await VideoReframer().makeComparisonVideoComposition(asset: comparison, analysis: staticAnalysis())
		let session = try #require(AVAssetExportSession(asset: comparison, presetName: AVAssetExportPresetHighestQuality))
		session.videoComposition = composition
		let outputURL = directory.appendingPathComponent("comparison.mov")
		try await session.export(to: outputURL, as: .mov)
		let outputSamples = try await samples(in: AVURLAsset(url: outputURL))

		#expect(outputSamples.map(\.time) == sourceSamples.map(\.time))
		#expect(outputSamples.map(\.duration) == sourceSamples.map(\.duration))
	}

	@Test
	func subrangeExportsShareElapsedTimingAndIncludeFinalFrame() async throws {
		let directory = try makeDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let frameDuration = CMTime(value: 1001, timescale: 30000)
		let source = try await makeSource(at: directory.appendingPathComponent("source.mov"), durations: Cadence.fractional.durations)
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

	@Test
	func nonzeroTrackOriginAndPartialFramesPreserveElapsedTime() async throws {
		let directory = try makeDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let source = try await makeSource(at: directory.appendingPathComponent("source.mov"), durations: Cadence.fractional.durations)
		let sourceTrack = try #require(await source.loadTracks(withMediaType: .video).first)
		let composition = AVMutableComposition()
		let track = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
		let origin = CMTime(seconds: 7, preferredTimescale: 30000)
		try await track.insertTimeRange(sourceTrack.load(.timeRange), of: sourceTrack, at: origin)
		let frameDuration = CMTime(value: 1001, timescale: 30000)
		let range = CMTimeRange(
			start: origin + CMTimeMultiplyByRatio(frameDuration, multiplier: 23, divisor: 2),
			end: origin + CMTimeMultiplyByRatio(frameDuration, multiplier: 289, divisor: 4),
		)
		let url = directory.appendingPathComponent("partial.mov")
		try await VideoReframer().export(asset: composition, analysis: staticAnalysis(timeRange: range), outputURL: url)
		let output = AVURLAsset(url: url)
		let result = try await samples(in: output)
		let expectedTimes = [.zero] + (12 ... 72).map {
			origin + CMTimeMultiply(frameDuration, multiplier: Int32($0)) - range.start
		}

		#expect(result.count == expectedTimes.count)
		// AVAssetExportSession quantizes an arbitrary edit to the output track's
		// media timescale. Preserve cadence within one tick, without frame rounding.
		#expect(zip(result, expectedTimes).allSatisfy { abs(($0.time - $1).seconds) <= 1 / 30000.0 })
		let last = try #require(result.last)
		#expect(abs((last.time + last.duration - range.duration).seconds) <= 1 / 30000.0)
		let outputDuration = try await output.load(.duration)
		#expect(abs((outputDuration - range.duration).seconds) <= 1 / 30000.0)
	}

	private struct Sample: Equatable {
		var time: CMTime
		var duration: CMTime
	}

	private func samples(in asset: AVAsset) async throws -> [Sample] {
		let track = try #require(await asset.loadTracks(withMediaType: .video).first)
		let reader = try AVAssetReader(asset: asset)
		let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
		reader.add(output)
		#expect(reader.startReading())
		var times: [CMTime] = []
		while let buffer = output.copyNextSampleBuffer() {
			// Readers can emit empty marker buffers at edit boundaries. They are
			// not displayed frames, and compressed packet durations can extend
			// beyond an edit. Measure presentation coverage instead.
			guard buffer.numSamples > 0, CMSampleBufferGetTotalSampleSize(buffer) > 0 else { continue }
			times.append(buffer.presentationTimeStamp)
		}
		#expect(reader.status == .completed)
		times.sort()
		let end = try await track.load(.timeRange).end
		return zip(times, times.dropFirst() + [end]).map { time, nextTime in
			Sample(time: time, duration: nextTime - time)
		}
	}

	private func makeDirectory() throws -> URL {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return directory
	}

	private func makeSource(at url: URL, durations: [CMTime]) async throws -> AVURLAsset {
		let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
		writer.movieTimeScale = 30000
		let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
			AVVideoCodecKey: AVVideoCodecType.proRes422,
			AVVideoWidthKey: 320,
			AVVideoHeightKey: 240,
		])
		input.mediaTimeScale = 30000
		let attributes = CVPixelBufferCreationAttributes(
			pixelFormatType: .init(rawValue: kCVPixelFormatType_32BGRA),
			size: .init(width: 320, height: 240),
		)
		let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
		#expect(writer.startWriting())
		writer.startSession(atSourceTime: .zero)
		var time = CMTime.zero
		for (index, duration) in durations.enumerated() {
			var buffer = try CVMutablePixelBuffer(attributes)
			buffer.accessUnsafeMutableRawPlaneBytes { planes in
				for plane in planes {
					plane.bytes.initializeMemory(as: UInt8.self, repeating: UInt8(index * 2))
				}
			}
			try await receiver.append(CVReadOnlyPixelBuffer(buffer), with: time)
			time = time + duration
		}
		writer.endSession(atSourceTime: time)
		receiver.finish()
		await writer.finishWriting()
		#expect(writer.status == .completed)
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
