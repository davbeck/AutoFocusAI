# Source timing in reframed exports

Output and comparison compositions now use the source video track's presentation
timing. The old implementation disabled source timing and rounded the floating
point nominal frame rate to an integer (29.97 became 30).

`AVVideoComposition.Configuration(for:)` supplies the timing defaults; setting
`sourceTrackIDForFrameTiming` selects the actual video track (the left track in a
comparison composition). No nominal-rate conversion or retiming is applied.
Apple documents this property as the mechanism for preserving source frame timing:
[sourceTrackIDForFrameTiming](https://developer.apple.com/documentation/avfoundation/avvideocomposition/sourcetrackidforframetiming).

## Supported timing policy

- Integer, fractional, and variable presentation cadence follow the source track.
  A VFR source remains VFR; an output's reported average rate may differ from its
  nominal rate, especially for short trims and quantized capture timestamps.
- A selected half-open source interval is exported at elapsed time zero. When the
  boundary falls inside a frame, the first displayed frame covers that boundary;
  subsequent presentation times retain their source offsets. Arbitrary edit
  boundaries are quantized to the output media timescale, rather than rounded to
  whole frames.
- The container's edit duration bounds final-frame coverage. A compressed packet
  can extend past the edit's end, so packet duration alone is not the clip duration.
- Empty edits use AVFoundation's configuration-derived fallback cadence. We do
  not synthesize missing capture coverage or normalize arbitrary discontinuities.
- There is no speed adjustment or audio-offset correction. No audio track is added
  to a video-only input.

## Validation on November 8, 2026

The production MEVO source is 3840 × 2160 HEVC, nominal `30000/1001`, with a
`1/600` media timebase. Its 91,939 frames cover 3067.698333 seconds. Its timestamps
contain small cadence variations; this change preserves them rather than forcing
an idealized CFR grid.

To isolate export timing from Vision analysis, a static native crop was exported
from source 280–282.01 seconds using the unchanged and corrected compositions.

| Measurement | Before | After |
| --- | --- | --- |
| Nominal rate, both outputs | `30/1` | `30000/1001` |
| Displayed frames, both outputs | 61 | 61 |
| Container duration, both outputs | 2.010000 s | 2.010000 s |
| Dimensions | 1920 × 1080 / 1080 × 1920 | Same |
| Audio tracks | 0 | 0 |
| Initial output timestamps | 0, .033333, .066667, .100000 | 0, .013333, .046667, .080000 |
| Final output timestamp | 2.000000 | 1.981667 |

The corrected initial partial frame covers source 280.000000–280.013333. The last
frame begins at source 281.981667 and remains visible through the selected end
282.010000. All subsequent timestamps match source timestamps minus 280 seconds,
including the source's 35 ms step. Landscape and portrait have identical
presentation timing. The metadata correction does not establish audio drift or a
shortened video: this comparison preserved duration before and after.

A separate corrected export of source 2970–2972.01 seconds also produced 61 frames
and exactly 2.010000 seconds in each shape, with `30000/1001` nominal rate, no audio
track, and identical presentation timestamps. Every timestamp after the initial
boundary matched its source timestamp minus 2970 seconds. This checks source-time
selection late in the recording without a full-length render.

`ExportTimingTests` generates small ProRes sources with integer, exact fractional,
and variable cadence, then inspects actual exported samples. It checks presentation
timestamps and coverage, comparison composition timing, paired crop synchronization,
frame-aligned and arbitrary subranges, a nonzero track origin, dimensions,
translation-only native crop transforms, and video-only output. Empty reader marker
buffers are excluded from frame counts; coverage is measured between presentation
timestamps and the track's edited end.

Inspect an exported movie with:

```sh
ffprobe -v error -show_streams -show_format -of json output.mov
ffprobe -v error -select_streams v:0 -show_packets \
  -show_entries packet=pts_time,duration_time -of json output.mov
```

No full 51-minute export or new soundboard alignment measurement was needed for
this timing fix. The capture-specific alignment values from the editing session
remain separate from AutoFocusAI's export policy.
