## Build & Test

This is a native Xcode project — no SPM or Makefile.

- **Build:** `xcodebuild build -project AutoFocusAI.xcodeproj -scheme AutoFocusAI`
- **Tests:** `xcodebuild test -project AutoFocusAI.xcodeproj -scheme AutoFocusAI`
- **CLI tool:** `xcodebuild build -project AutoFocusAI.xcodeproj -scheme AutoFocusAICLI`, then run the resulting binary with `<input-video> <output-video>`

Tests use the Swift Testing framework (`@Test` macros), not XCTest.

## Performance Testing

Use the CLI for apples-to-apples performance measurements. Keep the input clip and sampling configuration the same when comparing changes.

- **Representative sample video:** `.examples/TrackingExample.mov`
- **Benchmark helper:** `bin/benchmark_cli.sh .examples/TrackingExample.mov`
- **Optional explicit output path:** `bin/benchmark_cli.sh .examples/TrackingExample.mov /tmp/TrackingExample-benchmark.mov`

The benchmark helper rebuilds `AutoFocusAICLI`, resolves the built binary from Xcode build settings, and runs it under `/usr/bin/time -p`.

When evaluating a performance change:

1. Record a baseline run before editing.
2. Make the change.
3. Re-run the same benchmark command.
4. Compare elapsed time and the CLI's analyzed frame count.
5. Run `xcodebuild test -project AutoFocusAI.xcodeproj -scheme AutoFocusAI` after the change.

Prefer the sample video above for iterative work. Use longer sermon files only after a change looks promising on the smaller benchmark, since long clips are much slower to validate and can mix together analysis, preview, and playback costs.

## Architecture

Three targets share the work:

- **AutoFocusCore** — framework with all core logic; usable by both app and CLI
- **AutoFocusAI** — SwiftUI macOS app; thin UI layer over the core
- **AutoFocusAICLI** — ArgumentParser CLI tool for batch processing

### Data Flow

1. User drops a video → `VideoCoordinator` (`@Observable`) is created and handed to the UI
2. `PoseVideoAnalyzer` samples frames at ~10 FPS, downscales them for Vision, and runs `VNDetectHumanBodyPoseRequest`
3. `ShotTracker` (actor) ingests detected poses and computes smooth crop bounds using a spring/damping physics model (force from bbox offset → velocity → position with damping)
4. Results are stored as `[FrameData<ShotState>]`; `BinarySearch.value(atOrBefore:)` provides O(log n) time-based lookup
5. `VideoReframer` (actor) orchestrates analysis + export: builds an `AVMutableVideoComposition` that applies the computed crop path per frame and writes output

### Key Files

| File                                             | Role                                               |
| ------------------------------------------------ | -------------------------------------------------- |
| `AutoFocusCore/Controllers/PoseVideoAnalyzer.swift` | Frame extraction + Vision pose detection         |
| `AutoFocusCore/Controllers/ShotTracker.swift`    | Physics-based smooth tracking; outputs crop bounds |
| `AutoFocusCore/Controllers/VideoReframer.swift`  | End-to-end analysis + AVFoundation export          |
| `AutoFocusCore/Helpers/BinarySearch.swift`       | Generic binary search used for frame-time lookup   |
| `AutoFocusAI/Controllers/VideoCoordinator.swift` | `@Observable` bridge between UI and core           |
| `AutoFocusAI/Views/ContentView.swift`            | Root view; handles drag-drop, scene coordination   |

### Concurrency Model

Swift 6 strict concurrency is enabled. Do not use `@unchecked Sendable`, `@preconcurrency`, `assumeIsolated` or any other escape hatches.

### Tracking Algorithm Notes

- `ShotTracker` uses a spring-physics model: pose bbox center exerts a "force" when it leaves a dead-zone window (70% of crop width, 50% of height, 40% from top)
- When no subject is detected, the tracker coasts with its last velocity (inertia-based fallback)
- Crop bounds are clamped to stay within source video frame at all times
- Default export: 1080×1920 (9:16), ~10 FPS analysis sampling

## Current State (M1 In Progress)

Core pipeline (detection → tracking → export) is complete and tested. The UI is minimal — drag-drop works, processing runs, but the export button and framing overlay are not yet wired up. `Inspector.swift` is mostly a placeholder.
