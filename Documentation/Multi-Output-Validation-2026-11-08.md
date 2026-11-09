# Shared source analysis for sermon crops

Validated with the November 8, 2026 MEVO sermon recording, source seconds
280–320. The input is video-only, 3840×2160, with a reported 30000/1001 rate
and a 1/600 track time base. The two native crops are 1920×1080 and 1080×1920.

## Supported workflow

```sh
SOURCE='/Volumes/Recordings/2026-11-08/10.31.35.209 Sermon 2026-11-08 MEVO-KH4KR (Mevo-KH4KR).mov'
afai "$SOURCE" /tmp/Close-Up-test.mov /tmp/Vertical-test.mov \
  --resolution 1920x1080 --resolution 1080x1920 \
  --pose-interval 1 --start-time 280 --end-time 320
```

For a full logical section, omit `--start-time` and `--end-time`. Reconstruct
accidental recording splits at original resolution before analysis. Scripture
Reading and Sermon remain separate logical sections.

The CLI validates the complete list of destinations and dimensions before
analysis. Output paths pair with resolutions in argument order. Source
observations are shared; each shape independently selects and tracks its crop.
Additional movement-boundary probes share in-flight and completed observations
at identical requested source timestamps. Actual decoded timestamps are retained.

Reuse lasts for this invocation. No on-disk cache or reusable artifact was added;
`--pose-data` still writes inspection JSON and cannot supply a subsequent render.
This avoids introducing source-identity or cache-invalidation rules for a
workflow that needs two outputs together.

## Measurements

Analysis-only measurements used `--keyframes`, the same 280–320 source range,
and `--pose-interval 1`. Runs were sequential using the Debug CLI:

| Crop calculation | Initial samples | Unique additional requests | Reused requests | Elapsed |
| --- | ---: | ---: | ---: | ---: |
| Close Up, separate invocation | 40 | 28 | 1 | 3.308 s |
| Vertical, separate invocation | 40 | 41 | 6 | 3.511 s |
| Both shapes, one invocation | 40 | 59 | 17 | 4.370 s |

The combined run made 99 sample/detection requests versus 149 across the separate
runs (34% fewer), and took 4.370 s versus 6.819 s in total (36% less elapsed time).
Of the 17 reused additional requests, ten represent reuse between the two shapes;
seven also repeat within their individual crop calculations. The combined
keyframes for each shape exactly matched the corresponding separate invocation.
These are short-interval measurements, not a full-sermon performance projection.

Exporting both 40-second videos took 19.08 s with the one-second pose interval.
A separate two-output run at 0.5 seconds took 20.02 s. Both one-second outputs
contained one video stream and no audio, with the expected dimensions and
identical presentation-time and sample-duration arrays: 1,200 frames,
PTS 0 through 39.966667 s, and duration 40.000000 s.

Those media inspections were performed on this PR independently of the fractional
cadence fix: they still report 30 fps. That separate issue must be combined with
this change before claiming preservation of fractional source cadence. The
matching elapsed timing establishes synchronization between these two exports;
it does not establish or imply audio drift in the production recording.

## Checks

- CLI build and repository `bin/format` passed.
- Three `SharedAnalysisTests` passed: source timestamps and empty observations
  survive reuse, overlapping requests detect once, and the crop shapes calculate
  distinct native bounds on the same source timeline.
- CLI smoke checks rejected mismatched output/resolution counts, duplicate
  destinations, conflicting modes, an oversized second crop, and an unsupported
  destination extension, each before pose analysis.
- FFprobe inspection confirmed native dimensions and video-only output. Native
  bounds remain exactly the requested dimensions in the crop calculations.
- The tracking-quality and cadence changes have separate validation and PRs.
