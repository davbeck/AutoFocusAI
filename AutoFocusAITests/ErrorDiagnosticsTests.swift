import Foundation
import Testing
@testable import AutoFocusCore

struct ErrorDiagnosticsTests {
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
}
