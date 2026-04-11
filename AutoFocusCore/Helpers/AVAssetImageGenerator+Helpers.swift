import AVFoundation

extension AVAssetImageGenerator {
	func image(at time: CMTime) async throws -> (image: CGImage, actualTime: CMTime) {
		try await withCheckedThrowingContinuation { continuation in
			self.generateCGImageAsynchronously(for: time) { image, time, error in
				if let error {
					continuation.resume(throwing: error)
				} else if let image {
					continuation.resume(returning: (image, time))
				} else {
					continuation.resume(throwing: ContinuationCallbackFailure(function: #function))
				}
			}
		}
	}
}

struct ContinuationCallbackFailure: Error {
	var function: StaticString
}
