# Export timing fixtures

These synthetic, video-only H.264 MOV files were generated with FFmpeg 8.1.2 on
November 8, 2026. They contain no production footage. Each has 90 frames at
320 × 240 with a `1/30000` media timebase. Frame `N` has luma `16 + 2*N` and neutral
chroma, providing a distinct decoded gray level for detecting repeated or
reordered frames after export.

| File | Presentation timestamps (ticks) | Duration |
| --- | --- | --- |
| `timing-integer.mov` | `N * 1000` | 3.000000 s |
| `timing-fractional.mov` | `N * 1001` | 3.003000 s |
| `timing-variable.mov` | Repeating gaps of 1001, 2002, 1001, 3003 | 5.205200 s |

The variable fixture's final frame lasts 1001 ticks, as chosen by FFmpeg. Tests
read the authoritative presentation timestamps and edited track end rather than
assuming a nominal frame duration. FFmpeg is needed only to regenerate fixtures;
running tests uses the bundled media and AVFoundation.

Run these commands from this directory to regenerate:

```sh
ffmpeg -v error -f lavfi \
  -i "nullsrc=size=320x240:rate=30,geq=lum='16+2*N':cb=128:cr=128" \
  -frames:v 90 -c:v libx264 -crf 10 -bf 0 \
  -video_track_timescale 30000 -an -y timing-integer.mov

ffmpeg -v error -f lavfi \
  -i "nullsrc=size=320x240:rate=30000/1001,geq=lum='16+2*N':cb=128:cr=128" \
  -frames:v 90 -c:v libx264 -crf 10 -bf 0 \
  -video_track_timescale 30000 -an -y timing-fractional.mov

ffmpeg -v error -f lavfi \
  -i "nullsrc=size=320x240:rate=30000/1001,geq=lum='16+2*N':cb=128:cr=128,settb=1/30000,setpts='floor(N/4)*7007+if(eq(mod(N,4),0),0,if(eq(mod(N,4),1),1001,if(eq(mod(N,4),2),3003,4004)))'" \
  -frames:v 90 -fps_mode passthrough -enc_time_base 1:30000 \
  -c:v libx264 -crf 10 -bf 0 -video_track_timescale 30000 \
  -an -y timing-variable.mov
```

Original SHA-256 hashes (encoder upgrades can change bytes without changing the
required timing/content):

```text
8e9a03ec9a1f89327a5dbc239ee563ba332f0622f1c848a90ae1313b9bd5063e  timing-fractional.mov
c6413c69315896da4ac4f543953f7c2dda928b6a4b410652d5b919093695ec61  timing-integer.mov
647508b37b93cca4d19462a1918b3e05a91bedd15cee89631cf676cca1d8c29b  timing-variable.mov
```
