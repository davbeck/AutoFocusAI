import ArgumentParser
import AutoFocusCore
import Foundation

@main
struct AutoFocusAICLI: ParsableCommand {
	static let configuration = CommandConfiguration(
		abstract: "Command-line entry point for AutoFocusAI analysis and export experiments."
	)

	@Argument(help: "Path to the source video file.")
	var input: String

	@Argument(help: "Path where the cropped output video should be written.")
	var output: String

	mutating func run() throws {
		let inputURL = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
		let outputURL = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)

		let inputPath = inputURL.standardizedFileURL.path
		let outputPath = outputURL.standardizedFileURL.path

		guard FileManager.default.fileExists(atPath: inputPath) else {
			throw ValidationError("Input video does not exist: \(inputPath)")
		}

		var isDirectory: ObjCBool = false
		guard !FileManager.default.fileExists(atPath: inputPath, isDirectory: &isDirectory) || !isDirectory.boolValue else {
			throw ValidationError("Input path is a directory, expected a video file: \(inputPath)")
		}

		let outputDirectory = outputURL.deletingLastPathComponent().standardizedFileURL.path
		guard FileManager.default.fileExists(atPath: outputDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
			throw ValidationError("Output directory does not exist: \(outputDirectory)")
		}

		guard inputPath != outputPath else {
			throw ValidationError("Input and output paths must be different.")
		}

		throw CleanExit.message(
			"""
			Input: \(inputPath)
			Output: \(outputPath)
			Export is not implemented yet.
			"""
		)
	}
}
