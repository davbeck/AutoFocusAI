import ArgumentParser
import AutoFocusCore
import AVFoundation
import Foundation

@main
struct AutoFocusAICLI: AsyncParsableCommand {
	static let configuration = CommandConfiguration(
		abstract: "Analyze and reframe a video to keep the subject centered in a vertical crop.",
	)

	@Argument(help: "Path to the source video file.")
	var input: String

	@Argument(help: "Path where the cropped output video should be written.")
	var output: String

	@Flag(help: "Print crop bounds and subject position for each analyzed frame instead of exporting.")
	var debug = false

	mutating func run() async throws {
		let inputURL = URL(fileURLWithPath: (input as NSString).expandingTildeInPath).standardizedFileURL
		let outputURL = URL(fileURLWithPath: (output as NSString).expandingTildeInPath).standardizedFileURL

		guard FileManager.default.fileExists(atPath: inputURL.path) else {
			throw ValidationError("Input video does not exist: \(inputURL.path)")
		}

		var isDirectory: ObjCBool = false
		guard !FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDirectory) || !isDirectory.boolValue else {
			throw ValidationError("Input path is a directory, expected a video file: \(inputURL.path)")
		}

		let outputDirectory = outputURL.deletingLastPathComponent().standardizedFileURL.path
		guard FileManager.default.fileExists(atPath: outputDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
			throw ValidationError("Output directory does not exist: \(outputDirectory)")
		}

		guard inputURL.path != outputURL.path else {
			throw ValidationError("Input and output paths must be different.")
		}

		let asset = AVURLAsset(url: inputURL)
		let reframer = VideoReframer()

		print("Analyzing \(inputURL.lastPathComponent)...")
		let analysis = try await reframer.analyze(asset: asset)

		if debug {
			print("sourceSize: \(Int(analysis.sourceSize.width)) x \(Int(analysis.sourceSize.height))")
			print("renderSize: \(Int(analysis.renderSize.width)) x \(Int(analysis.renderSize.height))")
			if let first = analysis.shotStates.first {
				print("cropSize:   \(Int(first.value.bounds.width)) x \(Int(first.value.bounds.height))")
			}
			if let firstPose = analysis.shotStates.first(where: { $0.value.pose != nil })?.value.pose {
				print("allJoints count:   \(firstPose.allJoints().count)")
				print("face joints count: \(firstPose.allJoints(in: .face).count)")
				print("torso joints count: \(firstPose.allJoints(in: .torso).count)")
			}
			print("")
			print("time(s)\tcropX\tsubjectMidX\tsubjectMidY")
			for frame in analysis.shotStates {
				let b = frame.value.bounds
				if let sc = frame.value.subjectCenter {
					print(String(format: "%.3f\t%.1f\t%.1f\t%.1f", frame.presentationTime.seconds, b.origin.x, sc.x, sc.y))
				} else {
					print(String(format: "%.3f\t%.1f\t-\t-", frame.presentationTime.seconds, b.origin.x))
				}
			}
			print("")
		}

		print("Analyzed \(analysis.shotStates.count) frames. Exporting...")
		try await reframer.export(asset: asset, analysis: analysis, outputURL: outputURL)
		print("Exported to \(outputURL.path)")
	}
}
