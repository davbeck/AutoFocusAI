import ArgumentParser
import Dispatch
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
		var result: Result<Void, Error>!
		let semaphore = DispatchSemaphore(value: 0)
		let command = self

		Task {
			do {
				try await command.runAsync()
				result = .success(())
			} catch {
				result = .failure(error)
			}
			semaphore.signal()
		}

		semaphore.wait()
		try result.get()
	}

	private func runAsync() async throws {
		let inputURL = URL(fileURLWithPath: (input as NSString).expandingTildeInPath).standardizedFileURL
		let outputURL = URL(fileURLWithPath: (output as NSString).expandingTildeInPath).standardizedFileURL

		let inputPath = inputURL.path
		let outputPath = outputURL.path

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

		print("Input: \(inputPath)")
		print("Output: \(outputPath)")
		print("Analyzing and exporting...")

		let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
			.standardizedFileURL
			.deletingLastPathComponent()
		let helperSource = Self.helperSource(
			inputPath: inputPath,
			outputPath: outputPath
		)

		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
		process.arguments = [
			"-module-cache-path", "/tmp/AutoFocusAICLI-module-cache",
			"-I", executableDirectory.path,
			"-F", executableDirectory.path,
			"-framework", "AutoFocusCore",
			"-e", helperSource,
		]
		process.environment = ProcessInfo.processInfo.environment
		process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
		process.standardOutput = FileHandle.standardOutput
		process.standardError = FileHandle.standardError

		do {
			try process.run()
			process.waitUntilExit()
		} catch {
			throw ValidationError("Failed to launch Swift helper: \(error.localizedDescription)")
		}

		guard process.terminationStatus == 0 else {
			throw ExitCode(process.terminationStatus)
		}
	}

	private static func helperSource(inputPath: String, outputPath: String) -> String {
		#"import AVFoundation; import AutoFocusCore; import Foundation; let inputURL = URL(fileURLWithPath: "__INPUT_PATH__"); let outputURL = URL(fileURLWithPath: "__OUTPUT_PATH__"); let asset = AVURLAsset(url: inputURL); let reframer = VideoReframer(); let analysis = try await reframer.analyze(asset: asset); print("Analyzed \(analysis.shotStates.count) frames."); print("Exporting..."); try await reframer.export(asset: asset, analysis: analysis, outputURL: outputURL); print("Export complete.")"#
			.replacingOccurrences(of: "__INPUT_PATH__", with: escapedSwiftStringLiteral(inputPath))
			.replacingOccurrences(of: "__OUTPUT_PATH__", with: escapedSwiftStringLiteral(outputPath))
	}

	private static func escapedSwiftStringLiteral(_ string: String) -> String {
		string
			.replacingOccurrences(of: "\\", with: "\\\\")
			.replacingOccurrences(of: "\"", with: "\\\"")
	}
}
