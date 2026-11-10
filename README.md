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

Pose detection runs once per second by default, including for moving speakers. Use `--pose-interval` to set the
number of seconds between detections, and `--start-time` / `--end-time` to limit
both analysis and video export to a half-open range of video timestamps:

```sh
afai input.mov output.mov --pose-interval 1 --start-time 60 --end-time 120
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
are shared by source timestamp. Use `--save-analysis` and `--load-analysis` to
retain those observations between invocations. `--pose-data` remains a separate
inspection export.
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

Save reusable analysis alongside a video export, then reuse it for a different
crop. Loading observations does not reuse the previous crop path: each output
calculates its own framing.

```sh
afai Sermon-Wide.mov Sermon-Close-Up.mov \
  --resolution 1920x1080 --pose-interval 1 \
  --save-analysis Sermon.analysis.json

afai Sermon-Wide.mov Sermon-Vertical.mov \
  --resolution 1080x1920 --pose-interval 1 \
  --load-analysis Sermon.analysis.json --save-analysis Sermon.analysis.json
```

The second command reuses compatible samples and detects any additional frames
needed by the new crop. Saving to the same analysis path atomically retains the
new observations for future runs. Without `--save-analysis`, loaded data is read
only and any new observations remain in memory for that invocation. Analysis is
saved after the initial pass and after crop calculation, before video export.

You can also create analysis without rendering, or combine it with keyframe or
inspection JSON output:

```sh
afai Sermon-Wide.mov --save-analysis Sermon.analysis.json --pose-interval 1
afai Sermon-Wide.mov --keyframes crops.json --resolution 1080x1920 --pose-interval 1 \
  --load-analysis Sermon.analysis.json --save-analysis Sermon.analysis.json
```

Changing the pose interval or selected source range fills missing requests while
retaining observations that still match. Requests preserve exact rational source
timestamps and their actual decoded frame times, including nonzero track origins.
Different extraction strategies or boundary tolerances may require fresh samples.
The CLI reports how many sample requests were new or reused.

Reusable files are versioned JSON containing native Vision observations, bound to
the local source's canonical path, size, modification date, video track, geometry,
and track timing. Moving or replacing the source requires new analysis. The file
also records detector settings and Vision revision; incompatible settings or an
unsupported schema are rejected before pose detection. Sampling interval and crop
configuration are allowed to change. The identity check uses file metadata rather
than hashing the full recording; these are local analysis files, not portable
interchange reports. The original source is still required for video export and
for detecting missing samples.

`--pose-data` keeps its existing human-readable format. It cannot be loaded with
`--load-analysis`; use `--save-analysis` to create a reusable file. Analysis paths
must differ from the source and all video/JSON output paths. Only the analysis
file's own load and save paths may coincide.

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
