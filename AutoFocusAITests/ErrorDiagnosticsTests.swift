import Foundation
import Testing
@testable import AutoFocusCore

struct ErrorDiagnosticsTests {
	private struct ReaderFailure: Error, CustomNSError, LocalizedError {
		static let errorDomain = "TestReaderFailure"
		var errorCode: Int { 71 }
		var errorDescription: String? { "The source could not be read." }
		var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: "The source could not be read."] }
	}

	@Test
	func decodeFailureRetainsDistinctUnderlyingCauses() {
		let accessFailure = NSError(
			domain: NSCocoaErrorDomain,
			code: NSFileReadNoPermissionError,
			userInfo: [NSLocalizedDescriptionKey: "Access denied"],
		)
		let decoderFailure = NSError(
			domain: "AVFoundationErrorDomain",
			code: -11821,
			userInfo: [
				NSLocalizedDescriptionKey: "Cannot Decode",
				NSUnderlyingErrorKey: accessFailure,
				"unrelatedSensitiveValue": "not-for-logs",
			],
		)
		let error = PoseVideoAnalyzer.Error.unableToGenerateImage(decoderFailure)

		#expect(error.localizedDescription == "Unable to generate an analysis frame: Cannot Decode")
		let diagnostics = ErrorDiagnostics.description(for: error)
		#expect(diagnostics.contains("AVFoundationErrorDomain (-11821): Cannot Decode"))
		#expect(diagnostics.contains("NSCocoaErrorDomain (257): Access denied"))
		#expect(!diagnostics.contains("not-for-logs"))
		#expect(!diagnostics.lowercased().contains("sandbox"))
	}

	@Test
	func unknownErrorsRetainDomainCodeAndReason() {
		let error = NSError(
			domain: "UnexpectedDecoder",
			code: 42,
			userInfo: [
				NSLocalizedDescriptionKey: "Cannot Decode",
				NSLocalizedFailureReasonErrorKey: "Unsupported profile",
			],
		)

		let diagnostics = ErrorDiagnostics.description(for: error)
		#expect(diagnostics.contains("UnexpectedDecoder (42): Cannot Decode"))
		#expect(diagnostics.contains("Unsupported profile"))
	}

	@Test
	func missingUnderlyingErrorStillHasUsefulDiagnostic() {
		let diagnostics = ErrorDiagnostics.description(for: PoseVideoAnalyzer.Error.unableToGenerateImage(nil))
		#expect(diagnostics.contains("Unable to generate an analysis frame."))
		#expect(!diagnostics.contains("Caused by"))
	}

	@Test
	func nativeReaderFailurePreservesNestedFrameworkAndSystemIdentity() {
		let systemFailure = NSError(
			domain: NSPOSIXErrorDomain,
			code: 13,
			userInfo: [NSLocalizedDescriptionKey: "Permission denied"],
		)
		let mediaFailure = NSError(
			domain: NSOSStatusErrorDomain,
			code: -12911,
			userInfo: [NSUnderlyingErrorKey: systemFailure],
		)
		let readerFailure = NSError(
			domain: "AVFoundationErrorDomain",
			code: -11800,
			userInfo: [
				NSLocalizedDescriptionKey: "The operation could not be completed.",
				NSLocalizedFailureReasonErrorKey: "The video reader stopped.",
				NSUnderlyingErrorKey: mediaFailure,
			],
		)

		let diagnostics = ErrorDiagnostics.description(for: readerFailure)
		#expect(diagnostics.contains("AVFoundationErrorDomain (-11800)"))
		#expect(diagnostics.contains("The video reader stopped."))
		#expect(diagnostics.contains("NSOSStatusErrorDomain (-12911)"))
		#expect(diagnostics.contains("NSPOSIXErrorDomain (13): Permission denied"))
		#expect(!diagnostics.contains("Unable to generate an analysis frame"))
		#expect(!diagnostics.lowercased().contains("sandbox"))
	}

	@Test
	func unexpectedSwiftErrorRetainsItsFoundationIdentity() {
		let diagnostics = ErrorDiagnostics.description(for: ReaderFailure())
		#expect(diagnostics.contains("TestReaderFailure (71): The source could not be read."))
	}

	@Test
	func deepUnderlyingChainHasBoundedOutputWithoutLeakingUnrelatedUserInfo() {
		var error = NSError(domain: "DeepestCause", code: 99, userInfo: ["privatePayload": "not-for-diagnostics"])
		for index in (0 ..< 12).reversed() {
			error = NSError(
				domain: "Layer\(index)",
				code: index,
				userInfo: [
					NSLocalizedDescriptionKey: "Reader failed",
					NSUnderlyingErrorKey: error,
				],
			)
		}

		let diagnostics = ErrorDiagnostics.description(for: error)
		#expect(diagnostics.components(separatedBy: "\n").count == 8)
		#expect(diagnostics.contains("Failure: Layer0 (0)"))
		#expect(diagnostics.contains("Caused by: Layer7 (7)"))
		#expect(!diagnostics.contains("Layer8"))
		#expect(!diagnostics.contains("DeepestCause"))
		#expect(!diagnostics.contains("privatePayload"))
	}

	@Test
	func repeatedFailureReasonIsNotDuplicated() {
		let error = NSError(
			domain: "Reader",
			code: 7,
			userInfo: [
				NSLocalizedDescriptionKey: "Reader failed",
				NSLocalizedFailureReasonErrorKey: "Reader failed",
			],
		)
		#expect(ErrorDiagnostics.description(for: error) == "Failure: Reader (7): Reader failed")
	}
}
