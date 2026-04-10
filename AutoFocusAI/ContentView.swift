import AVKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import Vision

struct ContentView: View {
	@SceneStorage("url") private var url: URL?

	@State private var coordinator: VideoCoordinator?

	@State private var dragOver = false

	@State private var isInspectorPresented = true

	@State private var error: Error?

	var body: some View {
		HStack {
			if let coordinator {
				VideoView(coordinator: coordinator)
			} else {
				DropTargetView()
					.onDrop(of: [.movie], isTargeted: $dragOver) { providers -> Bool in
						guard let provider = providers.first else { return false }

						Task {
							do {
								self.url = try await provider.loadFileRepresentation(for: .movie, openInPlace: true).url
							} catch {
								self.error = error
							}
						}

						return true
					}
			}
//			ZStack {
//				MetalView(image: processor.currentSource)

//				if let state = processor.currentState {
//					if let pose = state.pose {
//						BodyPoseView(pose: pose)
//					}
//
//					if let size = processor.size {
//						BoundsShape(bounds: state.bounds, source: size)
//							.stroke(Color.red, lineWidth: 5)
//						BoundsShape(bounds: state.target, source: size)
//							.stroke(Color.orange, lineWidth: 5)
//					}
//				}
//			}
//			.aspectRatio(CGSize(width: 1920, height: 1080), contentMode: .fit)

//			MetalView(image: processor.currentOutput)
//				.aspectRatio(CGSize(width: 1080, height: 1920), contentMode: .fit)
		}
		.padding()
		.inspector(isPresented: $isInspectorPresented, content: {
			Inspector(isProcessing: coordinator?.isProcessing == true)
		})
		.task {
			// var shotFrames: [FrameData<ShotState>] = []
//			let videoAsset = AVURLAsset(url: url)
//
//			let track = try! await videoAsset.loadTracks(withMediaType: .video).first!
//			let (naturalSize, preferredTransform) = try! await track.load(.naturalSize, .preferredTransform)
//			let size = CGSizeApplyAffineTransform(naturalSize, preferredTransform)
//
//			let shotTracker = ShotTracker(sourceSize: size)
//
//			let poseComposition = try! await AVMutableVideoComposition.videoComposition(with: videoAsset) { request in
//				Task {
//					let visionRequestHandler = ImageRequestHandler(request.sourceImage)
//
//					let bodyPostRequest = DetectHumanBodyPoseRequest()
//					let poses = try await visionRequestHandler.perform(bodyPostRequest)
//
//					guard let context = CGContext(
//						data: nil,
//						width: Int(size.width),
//						height: Int(size.height),
//						bitsPerComponent: 8,
//						bytesPerRow: 0,
//						space: CGColorSpaceCreateDeviceRGB(),
//						bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
//					) else {
//						fatalError()
//					}
//
//					let bounds: CGRect
//					if let pose = poses.first {
//						let foo = await shotTracker.track(pose, at: request.compositionTime)
//
//						context.move(to: foo.target.origin)
//						context.addRect(foo.target)
//						context.setStrokeColor(NSColor.systemOrange.cgColor)
//						context.setLineWidth(10)
//						context.strokePath()
//
//						context.move(to: foo.points.origin)
//						context.addRect(foo.points)
//						context.setStrokeColor(NSColor.systemGreen.cgColor)
//						context.setLineWidth(10)
//						context.strokePath()
//
//						bounds = foo.bounds
//
			////					for pose in poses {
//						for (name, joint) in pose.allJoints() {
//							let center = joint.location.toImageCoordinates(size, origin: .lowerLeft)
//
//							let radius: Double = 30
//							context.move(to: center)
//							context.addEllipse(in: CGRect(origin: .init(x: center.x - radius / 2, y: center.y - radius / 2), size: .init(width: radius, height: radius)))
//
//							let color = switch name {
//							case .root:
//								NSColor.systemBlue
//							case .leftEar:
//								NSColor.systemGray
//							case .leftEye:
//								NSColor.systemGreen
//							case .rightEar:
//								NSColor.systemGray
//							case .rightEye:
//								NSColor.systemGreen
//							case .neck:
//								NSColor.systemGray
//							case .nose:
//								NSColor.systemGray
//							case .leftShoulder:
//								NSColor.systemRed
//							case .leftElbow:
//								NSColor.systemPink
//							case .leftWrist:
//								NSColor.systemRed
//							case .rightShoulder:
//								NSColor.systemRed
//							case .rightElbow:
//								NSColor.systemPink
//							case .rightWrist:
//								NSColor.systemRed
//							case .leftHip:
//								NSColor.systemPurple
//							case .leftKnee:
//								NSColor.systemCyan
//							case .leftAnkle:
//								NSColor.systemMint
//							case .rightHip:
//								NSColor.systemPurple
//							case .rightKnee:
//								NSColor.systemCyan
//							case .rightAnkle:
//								NSColor.systemMint
//							@unknown default:
//								NSColor.black
//							}
//							context.setFillColor(color.withAlphaComponent(CGFloat(joint.confidence)).cgColor)
//							context.fillPath()
//						}
//					} else {
//						bounds = await shotTracker.currentBounds
//					}
//
//					context.move(to: bounds.origin)
//					context.addRect(bounds)
//					context.setStrokeColor(NSColor.systemRed.cgColor)
//					context.setLineWidth(10)
//					context.strokePath()
//
//					guard let drawing = context.makeImage() else { fatalError() }
//
//					let outputImage = CIImage(cgImage: drawing).composited(over: request.sourceImage)
			////						.cropped(to: bounds)
//
//					request.finish(with: outputImage, context: nil)
//				}
//			}
//
//			let videoItem = AVPlayerItem(asset: videoAsset)
//			videoItem.videoComposition = poseComposition
//
//			player = AVPlayer(playerItem: videoItem)
		}
		.onOpenURL { url in
			self.url = url
		}
		.onChange(of: url, initial: true) { oldValue, newValue in
			self.coordinator = newValue.map { VideoCoordinator(url: $0) }
		}
	}
}

#Preview {
	ContentView()
}
