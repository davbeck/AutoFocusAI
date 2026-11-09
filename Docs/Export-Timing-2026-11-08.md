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

`ExportTimingTests` uses small bundled synthetic sources with integer, exact
fractional, and variable cadence, then inspects actual exported samples. The
[fixture provenance](../AutoFocusAITests/Fixtures/README.md) records generation
commands and timing. It checks presentation
timestamps and coverage, comparison composition timing, paired crop synchronization,
frame-aligned and arbitrary subranges, a nonzero track origin, dimensions,
translation-only native crop transforms, and video-only output. Empty reader marker
buffers are excluded from frame counts; coverage is measured between presentation
timestamps, bounded by both the final sample end and the track's edited end.

The fixtures encode a distinct eight-bit black/white frame number. Decoded output markers
are compared exactly with the source markers as well as their presentation timestamps,
so duplicated, dropped, or reordered frames are observable. They are bundled
rather than encoded during tests because concurrent `AVAssetWriter` fixture
generation was observed to stall with incomplete source movies on this
macOS/Xcode combination. The exact AVFoundation cause was not established.
The tests remain parallel and exercise real exports.

Inspect an exported movie with:

```sh
ffprobe -v error -show_streams -show_format -of json output.mov
ffprobe -v error -select_streams v:0 -show_packets \
  -show_entries packet=pts_time,duration_time -of json output.mov
```

No full 51-minute export or new soundboard alignment measurement was needed for
this timing fix. The capture-specific alignment values from the editing session
remain separate from AutoFocusAI's export policy.


## Expanded cadence and multiweek validation

The exported-media matrix now covers 24, 25, 30, 50, and 60 fps; exact
24000/1001, 30000/1001, and 60000/1001; regular VFR; and irregular VFR including
667 ms frame holds. Full exports of both crop shapes compare every source/output
PTS, actual presentation coverage, and decoded frame number. Five representative
cadences also exercise both comparison shapes. Four fractional/VFR cases trim
through partial frames near the source end after insertion at a seven-second
track origin. The frame-aligned trim and native unit-transform checks remain.

An incoming-audio fixture checks the current policy: audio present in the input
is retained at elapsed zero after trimming, with matching audio end coverage to
one audio media tick. Video-only inputs produce no audio track. AutoFocusAI does
not automatically strip incoming audio; the production camera recordings used
here already have separate audio files.

Two precision distinctions were demonstrated by the expanded tests:

- A MOV's edit header can have coarser precision than its samples. In the exact
  23.976 fixture, AVFoundation reports a 3.754 s track/edit range while the last
  actual sample ends at 3.753750 s. Inspection bounds final coverage by both
  values, and does not assign an empty header tail to the final frame. Exported
  video duration matches actual source sample coverage; it can differ from the
  source's coarse movie duration by less than one source header tick. Tests check
  that bound separately from cadence and displayed frame coverage.
- A trim through half of a media tick can round differently in separate export
  sessions. Arbitrary-boundary paired PTS remain within one source media tick
  (8.33 µs for the 120000-timescale fixture), with each output independently
  checked against the source phase and selected duration. Frame-aligned exports
  preserve exact paired PTS. This is distinct from rounding to a video frame.

The full repository test run passed, including twenty-one timing cases producing
42 tiny real exports. The timing cases completed in 1.663–4.863 s while running
in parallel. They remain parallel. A
sample of the initially expanded run showed cooperative workers blocked inside
`copyNextSampleBuffer`; the macOS 26 async provider also reached that synchronous
operation. Each inspector now has its own Dispatch-backed actor executor, leaving
Swift's shared cooperative pool available for AVFoundation's async work. No tests
are serialized and no sleeps, retries, or Sendable escape hatches are used. This
is the [documented custom-executor use case for blocking I/O](https://developer.apple.com/documentation/swift/serialexecutor).

Separate static-crop exports inspected three recording weeks, with no Vision
analysis, to isolate the export path:

| Source | Intervals | Crop dimensions | Frames per output |
| --- | --- | --- | --- |
| August 23 HEVC 4K, quantized 29.97 | Beginning, middle, final 3.01 s | 1920 × 1080 / 1080 × 1920 | 91 each |
| September 20 H.264 4K, quantized 29.97 | Beginning, middle, final 3.01 s | 1920 × 1080 / 1080 × 1920 | 91 each |
| October 18 H.264 4K with irregular gaps | Beginning, middle, final 3.01 s | 1920 × 1080 / 1080 × 1920 | 91 each |
| September 20 H.264 1080p, 30 fps | Beginning, middle, final 3.01 s | 960 × 540 / 540 × 960 | 91 each |
| October 18, 40.406667 s source PTS gap | 78.68–82.68 s | 1920 × 1080 / 1080 × 1920 | 31 over 4 s |
| October 18, 1.801667 s source PTS gap | 549.783333–553.783333 s | 1920 × 1080 / 1080 × 1920 | 67 over 4 s |

All 28 exported movies matched the expected source-relative packet PTS exactly,
retained the requested duration exactly, had identical paired PTS, and contained
no audio track. Output dimensions matched the table. The two gap intervals retain
existing source cadence and holds; missing capture coverage is not repaired.
Frame-rate metadata inferred from a VFR excerpt can differ from its source's
nominal field, so the validation uses actual PTS rather than metadata equality.

These sequential two-shape jobs took 21.069 s total on this Mac, including encoder
startup and excluding Vision analysis. This is 44.12 selected source seconds and
88.24 output seconds, not a full-length performance benchmark. Export timing was
checked independently from subject framing; these static crops do not validate
tracking quality. No production footage or derived subject observations were
added to the repository.
