import Foundation

/// Details for command-line diagnostics without dumping arbitrary error userInfo.
public enum ErrorDiagnostics {
	public static func description(for error: any Error) -> String {
		var lines: [String] = []
		var cause: (any Error)? = error
		// Framework errors can contain several nested causes. Bound diagnostic output.
		for depth in 0 ..< 8 {
			guard let current = cause else { break }
			let nsError = current as NSError
			let prefix = depth == 0 ? "Failure" : "Caused by"
			lines.append("\(prefix): \(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)")
			if let reason = nsError.localizedFailureReason, reason != nsError.localizedDescription {
				lines.append("Reason: \(reason)")
			}
			if case let PoseVideoAnalyzer.Error.unableToGenerateImage(underlying) = current {
				cause = underlying
			} else {
				cause = nsError.userInfo[NSUnderlyingErrorKey] as? any Error
			}
		}
		return lines.joined(separator: "\n")
	}
}
