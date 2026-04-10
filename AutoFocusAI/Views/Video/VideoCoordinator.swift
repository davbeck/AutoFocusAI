@preconcurrency import AVFoundation
import Foundation
import Observation
import SwiftUI
import Vision

@MainActor
@Observable
final class VideoCoordinator {
	let url: URL

	private let asset: AVAsset
//	private let playerItem: AVPlayerItem
	var player: AVPlayer
	private var looper: AVPlayerLooper

	var isProcessing = false

	var poseFrames: [FrameData<[HumanBodyPoseObservation]>] = []

	var currentTime: CMTime?

	init(url: URL) {
		self.url = url

		asset = AVURLAsset(url: url)

		let playerItem = AVPlayerItem(asset: asset)
		let player = AVQueuePlayer(playerItem: playerItem)
		looper = AVPlayerLooper(player: player, templateItem: playerItem)
//			let player = AVPlayer(playerItem: playerItem)
		player.isMuted = true

		self.player = player

		let videoProcessor = VideoProcessor(asset: asset)

		Task {
			isProcessing = true
			defer { isProcessing = false }

			do {
				self.poseFrames = try await videoProcessor.process()
			} catch {
				print("process failed: \(error)")
			}
		}

		player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { time in
			MainActor.assumeIsolated {
				self.currentTime = time
			}
		}
	}

	var currentPoses: [HumanBodyPoseObservation] {
		guard let currentTime else { return [] }
		return poseFrames.binarySearch(for: currentTime, transform: { $0.presentationTime }).value?.value ?? []
	}

//	func updatePoseComposition() async {
//		guard let poseFrames else { return }
//
//		let renderer = FrameAnnotationRenderer()
//
//		do {
//			let poseComposition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
//				let compositionTime = request.compositionTime
//				print("videoComposition", compositionTime)
//				guard
//					let poses = poseFrames.binarySearch(
//						for: compositionTime,
//						transform: { $0.presentationTime }
//					).value?.value
//				else { return }
//
//				Task { @MainActor in
//					renderer.poses = poses
//					if let annotation = renderer.image {
//						request.finish(
//							with: annotation.composited(over: request.sourceImage),
//							context: nil
//						)
//					} else {
//						request.finish(with: request.sourceImage, context: nil)
//					}
//				}
//			}
//
//			let playerItem = AVPlayerItem(asset: asset)
//			playerItem.videoComposition = poseComposition
//
//			let player = AVQueuePlayer(playerItem: playerItem)
//			looper = AVPlayerLooper(player: player, templateItem: playerItem)
//	//			let player = AVPlayer(playerItem: playerItem)
//			player.isMuted = true
//
//			self.player = player
//		} catch {
//			fatalError("\(error)")
//		}
//	}
}

@MainActor
final class FrameAnnotationRenderer {
	let renderer = ImageRenderer(content: FrameAnnotationView(poses: []))

	var poses: [HumanBodyPoseObservation] {
		get {
			renderer.content.poses
		}
		set {
			renderer.content.poses = newValue
		}
	}

	var image: CIImage? {
		renderer.cgImage.map { CIImage(cgImage: $0) }
	}
}
