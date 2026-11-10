# Reusable-analysis fixtures

`pose-observation.json` is a fully hand-authored, synthetic body skeleton in
Vision's native `HumanBodyPoseObservation` Codable shape. Every value was written
from constants: 19 public joint names, symmetric normalized coordinates centered
at x = 0.5, confidence 1, UUID `00000000-0000-0000-0000-000000000001`, no hands,
an unspecified time range, and the public `revision2` request descriptor. The
wrists span x = 0.3–0.7, so the tracking tests' horizontal shifts stay inside the
normalized image. No detected observations, production-media coordinates,
confidence values, UUIDs, images, or audio were used to generate this payload.
Tests decode and re-encode it through native Vision Codable and verify its
canonical joint positions before using it for reuse and tracking checks.

`analysis-source.mov` is a 4,252-byte synthetic video-only H.264 source for testing
file metadata and symlink identity, generated with FFmpeg 8.1.2. It contains 90
320 × 240 frames, exact `30000/1001` cadence, and a `1/30000` timebase. It was
generated with:

```sh
ffmpeg -v error -f lavfi \
  -i "nullsrc=size=320x240:rate=30000/1001,geq=lum='16+2*N':cb=128:cr=128" \
  -frames:v 90 -c:v libx264 -crf 10 -bf 0 \
  -video_track_timescale 30000 -an -y analysis-source.mov
```

Its SHA-256 is
`8e9a03ec9a1f89327a5dbc239ee563ba332f0622f1c848a90ae1313b9bd5063e`.
FFmpeg is only needed for regeneration; tests use the bundled file.
