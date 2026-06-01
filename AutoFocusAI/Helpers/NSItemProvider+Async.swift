import Foundation
import UniformTypeIdentifiers

public extension NSItemProvider {
	/// Load a representation as a file
	///
	/// Except for files registered as open-in-place, a temporary file containing a copy of the original will be
	/// provided to your completion handler. This temporary file will be deleted once your completion handler
	/// returns. To keep a copy of this file, move or copy it into another directory before returning from the
	/// completion handler.
	///
	/// If the representation was registered as `Data`, its contents will be written to a temporary file.
	///
	/// If `suggestedName` is non-nil, an attempt will be made to use it as the file name, with an appropriate
	/// file extension based on the content type. Otherwise, a suitable name and file extension will be chosen based on
	/// the content type.
	///
	/// - Note: The completion handler may be scheduled on an arbitrary queue.
	///
	/// - Parameters:
	///   - contentType: Content type of the representation to load. Must conform to one of the content types returned
	///                  by `registeredContentTypes`.
	///   - openInPlace: Pass `true` to attempt to open a file representation in place.
	///
	/// - Returns: A url pointing to the resource.
	/// The `openInPlace` parameter will be set to `true` if the file was successfully opened in place,
	/// or `false` if a copy of the file was created in a temporary directory.
	func loadFileRepresentation(for contentType: UTType, openInPlace: Bool = false) async throws -> (url: URL, wasLoadedInPlace: Bool) {
		try await withCheckedThrowingContinuation { continuation in
			_ = self.loadFileRepresentation(for: contentType, openInPlace: openInPlace) { url, wasLoadedInPlace, error in
				if let error {
					continuation.resume(throwing: error)
				} else if let url {
					continuation.resume(returning: (url, wasLoadedInPlace))
				} else {
					assertionFailure("unexpected callback parameters for loadFileRepresentation")
				}
			}
		}
	}

	func loadPersistentFileRepresentation(
		for contentType: UTType,
		openInPlace: Bool = true,
		copyingInto directory: URL,
	) async throws -> URL {
		try await withCheckedThrowingContinuation { continuation in
			_ = self.loadFileRepresentation(for: contentType, openInPlace: openInPlace) { url, wasLoadedInPlace, error in
				do {
					if let error {
						throw error
					}

					guard let url else {
						throw CocoaError(.fileReadUnknown)
					}

					guard !wasLoadedInPlace else {
						continuation.resume(returning: url)
						return
					}

					try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

					let fileExtension = url.pathExtension.isEmpty
						? contentType.preferredFilenameExtension ?? "mov"
						: url.pathExtension
					let destinationURL = directory
						.appendingPathComponent(UUID().uuidString)
						.appendingPathExtension(fileExtension)

					if FileManager.default.fileExists(atPath: destinationURL.path) {
						try FileManager.default.removeItem(at: destinationURL)
					}
					try FileManager.default.copyItem(at: url, to: destinationURL)
					continuation.resume(returning: destinationURL)
				} catch {
					continuation.resume(throwing: error)
				}
			}
		}
	}
}
