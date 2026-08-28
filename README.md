# AutoFocusAI

Crop videos based on the person's position.

## Requirements

- Xcode with the macOS 26 SDK
- Swift 6 toolchain

The app, CLI, and tests all target macOS 26.

## Build

```sh
xcodebuild build -project AutoFocusAI.xcodeproj -scheme AutoFocusAI
```

## Test

```sh
xcodebuild test -project AutoFocusAI.xcodeproj -scheme AutoFocusAI
```

## CLI

```sh
xcodebuild build -project AutoFocusAI.xcodeproj -scheme AutoFocusAICLI
```

Run the built binary with:

```sh
<input-video> <output-video>
```

Pose detection runs once per second by default. Use `--pose-interval` to set the
number of seconds between detections, and `--start-time` / `--end-time` to limit
both analysis and video export to a half-open range of video timestamps:

```sh
afai input.mov output.mov --pose-interval 5 --start-time 60 --end-time 120
```

Use `--pose-data` in place of the output-video argument to write every detected
pose and its normalized Vision joints to JSON. This mode does not reframe or
export video:

```sh
afai input.mov --pose-data poses.json --pose-interval 5 --start-time 60 --end-time 120
```

Sparse sampling uses individual timestamp extraction so the decoder can skip
most of the video. Dense sampling over a sufficiently long range switches to a
sequential asset reader to avoid repeated seek overhead.
