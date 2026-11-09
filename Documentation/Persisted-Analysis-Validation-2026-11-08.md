# Reusable analysis across crop commands

This change is stacked on PR #2 (`codex/reuse-source-analysis`). It adds explicit
`--save-analysis` and `--load-analysis` options. The original `--pose-data`
inspection format remains unchanged and is not a reusable analysis artifact.

## Supported workflow

Save observations during a video export, then reuse them for a different crop:

```sh
afai Sermon-Wide.mov Close-Up.mov \
  --resolution 1920x1080 --pose-interval 1 \
  --save-analysis Sermon.analysis.json

afai Sermon-Wide.mov Vertical.mov \
  --resolution 1080x1920 --pose-interval 1 \
  --load-analysis Sermon.analysis.json --save-analysis Sermon.analysis.json
```

Each command derives its own crop path. The second command reuses compatible
observations and detects additional frames when its crop or sampling requests
require them. Saving to the input analysis path atomically retains those new
observations. Loading without saving leaves the file unchanged.

Analysis can also be saved without rendering, or alongside keyframe/inspection
JSON output. Initial observations are saved before crop calculation; adaptive
observations are saved after each crop calculation and before video export, so a
later export failure does not discard completed analysis.

Reconstruct accidentally split recordings at original resolution before the
first analysis. Keep Scripture Reading and Sermon as separate logical sections.
The original video remains necessary for export and filling missing samples.

## Compatibility and timing

The versioned JSON artifact binds observations to the source's canonical local
path, byte size, modification date, video-track identifier, native geometry,
preferred transform, and complete track time range. The identity is a quick
metadata check, not a hash of the entire recording. A moved, replaced, or modified
source is rejected; symlink aliases resolve to the same canonical source.

Detector revision, analyzer version, detection image size, and hand-detection
settings must match. Crop configuration, pose interval, and selected subrange can
change. Concurrent detection limits do not alter compatibility. This is a local
native Vision observation format, not a portable pose-data interchange schema.
Unsupported schemas, legacy inspection reports, and incompatible inputs produce
errors with instructions to create new analysis using `--save-analysis`.

Requested times, actual decoded presentation times, source track origin, and the
selected range are stored as exact rational values with epochs. The selection is
provenance, not a claim that every possible timestamp in it has been analyzed.

Sparse selected-start requests shift by one frame in the existing analyzer;
interior requests do not. Extraction context therefore preserves the effective
request time, decode strategy, and tolerances. Incompatible contexts are filled
instead of reusing the wrong observation. Sequential positive observations can
survive a changed end boundary when their actual presentation times remain in
the selected range. A shorter sequential selection also retains known observations
for a later wider selection, even if its own end excludes them. The regular initial pass still batches missing requests,
including sequential-reader requests, instead of issuing one seek per frame.

Decoded frames containing no people remain reusable observations. Missing or
failed extractions do not become persisted empty-human detections. Failed or
canceled batches clear their pending entries and remain retryable. Statistics
report sample requests and cache hits, not an exact count of Vision executions
when extraction fails.

## Real-media validation

Source:

```text
/Volumes/Recordings/2026-11-08/10.31.35.209 Sermon 2026-11-08 MEVO-KH4KR (Mevo-KH4KR).mov
```

Validation used source 296–306 seconds, explicit 1s pose sampling, a Debug CLI,
and separate invocations. No full-sermon exports were performed.

```sh
SOURCE='/Volumes/Recordings/2026-11-08/10.31.35.209 Sermon 2026-11-08 MEVO-KH4KR (Mevo-KH4KR).mov'
afai "$SOURCE" /tmp/Close-Up.mov --resolution 1920x1080 \
  --pose-interval 1 --start-time 296 --end-time 306 \
  --save-analysis /tmp/Sermon.analysis.json

afai "$SOURCE" /tmp/Vertical.mov --resolution 1080x1920 \
  --pose-interval 1 --start-time 296 --end-time 306 \
  --load-analysis /tmp/Sermon.analysis.json \
  --save-analysis /tmp/Sermon.analysis.json
```

| Invocation | New sample requests | Reused requests | Elapsed |
| --- | ---: | ---: | ---: |
| First Close Up render, save analysis | 20 | 2 | 3.06s |
| New Vertical render, load and extend | 4 | 13 | 1.99s |
| Repeat Vertical render, load | 0 | 17 | 2.25s |
| Fresh Close Up keyframes | 20 | 2 | 1.15s |
| Reused Close Up keyframes | 0 | 22 | 0.03s |
| Fresh Vertical keyframes | 17 | 0 | 0.76s |
| Reused Vertical keyframes | 0 | 17 | 0.03s |
| Denser Vertical keyframes, 0.5s sampling | 12 | 13 | 0.63s |
| Extend selection to 295.5–307.5s, 0.5s sampling | 5 | 24 | 0.32s |
| Repeat extended selection | 0 | 29 | 0.03s |

These are individual wall-clock measurements on a shared Mac, not throughput
projections. Video encoding dominates some runs; fewer detections do not imply
that every complete export becomes faster. The analysis-only measurements
isolate the practical benefit of reuse.

Fresh keyframes are identical to PR #2's baseline. Reused and fresh keyframes
match exactly for each crop shape. The repeated extended-range keyframes also
match. The larger selection preserves prior observations and adds only missing
requests. The resulting analysis file contains 41 stored requests.

FFprobe inspection of the initial landscape, changed portrait, and repeated
portrait exports confirmed 1920×1080 / 1080×1920 dimensions, zero audio tracks,
300 frames, 10.000000s duration, and identical integer presentation-time arrays
(0 through 9.966667s). This PR retains PR #2's 30fps export implementation; the
fractional-cadence correction remains in the separate timing PR #3. Loading
analysis does not change export cadence, duration, or elapsed subrange timing.

Analysis-only saving and `--pose-data` export from loaded analysis also passed.
The latter reused all 10 initial samples and retained inspection schema version 1,
1s sample interval, and video-relative range 296–306s.

## Checks and limits

Tests cover native Vision observation round trips, rational timestamps and
nonzero track origins, source/detector/schema rejection, batched and partial
reuse, changed extraction contexts, empty-human observations, retry after failure
or cancellation, and identical crop bounds after serialization for both native
shapes. Tests remain parallel and use no sleeps or serialization.

CLI smoke checks rejected legacy reports, unsupported schema, changed source size,
incompatible detector revision, invalid timing, and missing files. Destination
checks reject source/output collisions and directory-symlink aliases, including
when an output's final component does not yet exist. Only analysis load/save paths
may coincide. These checks run before expensive analysis or output writes.

The supported policy is best-effort reuse. New crop paths, denser sampling,
expanded ranges, or incompatible extraction contexts may require new observations.
There is no automatic cache directory, background invalidation service, or hidden
artifact update. Preserving/reusing observations does not repair missing source
coverage or introduce an audio alignment correction.

Final verification on macOS 26.6.2:

```sh
xcodebuild build -project AutoFocusAI.xcodeproj -scheme AutoFocusAICLI \
  -derivedDataPath /tmp/afai-persisted-build CODE_SIGNING_ALLOWED=NO
xcodebuild test -project AutoFocusAI.xcodeproj -scheme AutoFocusAI \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/afai-persisted-build CODE_SIGNING_ALLOWED=NO
```

The complete hosted test plan passed all 77 tests with zero failures. Bundled
fixtures contain a fully hand-authored synthetic skeleton and a generated gray
video; no captured pose observations, images, or audio are included. SwiftFormat
0.58.1 lint reported 0 of 30 Swift files requiring changes, and
`git diff --check` passed. The final rebuilt CLI again produced the exact fresh
landscape keyframes with zero new sample requests and 22 cache hits.
