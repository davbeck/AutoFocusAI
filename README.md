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

Pose detection runs once every five seconds by default. Use `--pose-interval` to set the
number of seconds between detections, and `--start-time` / `--end-time` to limit
both analysis and video export to a half-open range of video timestamps:

```sh
afai input.mov output.mov --pose-interval 5 --start-time 60 --end-time 120
```

Output is a native-resolution crop: pixels are neither scaled up nor down. Use
`--resolution` to select `9:16-max` (the default), either built-in fixed size,
or any custom even-pixel dimensions that fit inside the source video:

```sh
afai input.mov vertical.mov --resolution 1080x1920
afai input.mov landscape.mov --resolution 1920x1080
afai input.mov custom.mov --resolution 720x1280
```

Provide multiple output paths and the same number of `--resolution` values, in
matching order, to analyze one source and render several crops:

```sh
afai Sermon-Wide.mov Sermon-Close-Up.mov Sermon-Vertical.mov \
  --resolution 1920x1080 --resolution 1080x1920 --pose-interval 1
```

The initial pose-detection pass runs once. Crop calculation runs independently
for each shape, while additional observations used to refine movement boundaries
are shared by source timestamp. This is an in-memory workflow for one invocation;
`--pose-data` remains an inspection export, not an input cache for later renders.
Both outputs use the same selected source-time range and elapsed timing, with
native source pixels and no scaling. Video-only sources remain video-only.

For a short tracking review around source 301 seconds:

```sh
afai Sermon-Wide.mov /tmp/Close-Up-test.mov /tmp/Vertical-test.mov \
  --resolution 1920x1080 --resolution 1080x1920 \
  --pose-interval 1 --start-time 280 --end-time 320
```

Reconstruct accidental file splits into each logical section at original
resolution **before** running this command. Track Scripture Reading and Sermon
as separate sections; concatenating independently tracked crops can reset framing
at the joins. Import the wide original separately in Descript. Do not apply a
capture-specific soundboard offset or speed correction in AutoFocusAI.

Use `--pose-data` in place of the output-video argument to write every detected
pose and its normalized Vision joints to JSON. This mode does not reframe or
export video:

```sh
afai input.mov --pose-data poses.json --pose-interval 5 --start-time 60 --end-time 120
```

Use `--keyframes` to write tracked crop bounds as JSON instead of exporting a
video. Repeat `--resolution` to generate keyframes for multiple output
configurations from one pose-analysis pass:

```sh
afai input.mov --keyframes crops.json \
  --resolution 1920x1080 \
  --resolution 1080x1920 \
  --resolution 720x1280
```

Each configuration contains its resolved native output dimensions and a list of
video-relative timestamps with crop rectangles in source-pixel coordinates,
using an upper-left origin.

Sparse sampling uses individual timestamp extraction so the decoder can skip
most of the video. Dense sampling over a sufficiently long range switches to a
sequential asset reader to avoid repeated seek overhead.

When analysis or export fails, add `--debug` to include error domains, codes,
failure reasons, and underlying causes on standard error. The normal concise
error and nonzero exit status are preserved. For example:

```sh
afai input.mov output.mov --start-time 280 --end-time 320 --debug 2>failure.log
```

`Cannot Decode` alone does not establish corrupt media or a sandbox/access
failure. Compare the underlying diagnostics and the same command in the intended
execution environment; the CLI does not retry with different permissions.
