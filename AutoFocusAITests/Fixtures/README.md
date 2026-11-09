# Export timing fixtures

These synthetic MOV files were generated with FFmpeg 8.1.2 on November 8, 2026.
They contain no production media. Each video has 90 frames at 320 × 240. Frame
`N` stores `N` as an eight-bit, little-endian black/white marker in 8-pixel-wide
vertical stripes, repeated every 64 pixels. Decoding the stripe centers provides
robust frame identity through re-encoding, including narrow native portrait crops.

The fixtures cover integer 24, 25, 30, 50, and 60 fps, exact fractional
24000/1001, 30000/1001, and 60000/1001 fps, regular VFR, and irregular VFR. The
120000 timebase represents all new CFR rates exactly. Existing 30 and 29.97
fixtures retain a 30000 timebase to cover multiple media timescales.

| File | Media timebase | Video duration |
| --- | --- | --- |
| `timing-audio.mov` | `1/30000` | 3.003000 s |
| `timing-fractional.mov` | `1/30000` | 3.003000 s |
| `timing-fractional24.mov` | `1/120000` | 3.753750 s |
| `timing-fractional60.mov` | `1/120000` | 1.501500 s |
| `timing-integer.mov` | `1/30000` | 3.000000 s |
| `timing-integer24.mov` | `1/120000` | 3.750000 s |
| `timing-integer25.mov` | `1/120000` | 3.600000 s |
| `timing-integer50.mov` | `1/120000` | 1.800000 s |
| `timing-integer60.mov` | `1/120000` | 1.500000 s |
| `timing-irregular.mov` | `1/60000` | 11.787100 s |
| `timing-variable.mov` | `1/30000` | 5.205200 s |

`timing-variable.mov` has repeating PTS gaps of 1001, 2002, 1001, 3003 ticks.
`timing-irregular.mov` uses gaps of 1001, 733, 4004, 40040, 2002, 1001, 6006 ticks,
including a 667 ms hold. Its reported nominal rate can be 60000/1 because the
irregular tick spacings have a GCD of one; actual presentation timestamps determine
cadence. Tests never derive expected display timing from that nominal field.

`timing-audio.mov` adds a synthetic 1 kHz AAC tone at 48 kHz to the fractional
source. It checks the existing incoming-audio preservation policy; the other ten
fixtures have no audio track. FFmpeg is needed only for fixture regeneration.

Regenerate from this directory, in one shell:

```sh
timing_pattern="geq=lum='16+219*mod(floor(N/pow(2,mod(floor(X/8),8))),2)':cb=128:cr=128"
for timing_spec in \
  'integer24|24|120000' 'integer25|25|120000' 'integer|30|30000' \
  'integer50|50|120000' 'integer60|60|120000' \
  'fractional24|24000/1001|120000' 'fractional|30000/1001|30000' \
  'fractional60|60000/1001|120000'
do
  timing_name="${timing_spec%%|*}"
  timing_remaining="${timing_spec#*|}"
  timing_rate="${timing_remaining%%|*}"
  timing_scale="${timing_remaining#*|}"
  ffmpeg -v error -f lavfi \
    -i "nullsrc=size=320x240:rate=${timing_rate},${timing_pattern}" \
    -frames:v 90 -c:v libx264 -crf 10 -bf 0 \
    -video_track_timescale "$timing_scale" -an -y "timing-${timing_name}.mov"
done

ffmpeg -v error -f lavfi \
  -i "nullsrc=size=320x240:rate=30000/1001,${timing_pattern},settb=1/30000,setpts='floor(N/4)*7007+if(eq(mod(N,4),0),0,if(eq(mod(N,4),1),1001,if(eq(mod(N,4),2),3003,4004)))'" \
  -frames:v 90 -fps_mode passthrough -enc_time_base 1:30000 \
  -c:v libx264 -crf 10 -bf 0 -video_track_timescale 30000 -an -y timing-variable.mov

ffmpeg -v error -f lavfi \
  -i "nullsrc=size=320x240:rate=30000/1001,${timing_pattern},settb=1/60000,setpts='floor(N/7)*54787+if(eq(mod(N,7),0),0,if(eq(mod(N,7),1),1001,if(eq(mod(N,7),2),1734,if(eq(mod(N,7),3),5738,if(eq(mod(N,7),4),45778,if(eq(mod(N,7),5),47780,48781))))))'" \
  -frames:v 90 -fps_mode passthrough -enc_time_base 1:60000 \
  -c:v libx264 -crf 10 -bf 0 -video_track_timescale 60000 -an -y timing-irregular.mov

ffmpeg -v error -i timing-fractional.mov \
  -f lavfi -i 'sine=frequency=1000:sample_rate=48000:duration=3.003' \
  -map 0:v:0 -map 1:a:0 -c:v copy -c:a aac -t 3.003 -y timing-audio.mov
```

SHA-256 hashes (encoder upgrades can change bytes without changing the required
cadence and frame-identity content):

```text
af235d652b8d911ae5307599b461c2cc3a47a62c13600e34bb6dd37e7155a449  timing-audio.mov
954859a98853ef0147cdea028db7be28f5f64993348fb39c8c61e9048a50499d  timing-fractional.mov
5702da146b86e41b5b3802469f5912faa155c05d0e525276da7fc70c60bfbef5  timing-fractional24.mov
c05575fb1aec5d631ac815598232a8bdf5fafee694c8a394559134827c390faf  timing-fractional60.mov
dce6ac4ff0f55c24dde2a56e540b7c99e7bcbc52f74af7cdd813eff925e805bd  timing-integer.mov
e6b91eab824ae0e0cbd0ff00ed8e55a8011b953cdd3ecd1bb6c812398c6fe22e  timing-integer24.mov
b383893400776176f35b74fd5dd84e74ee3be64bc2890f307becfedc56e53a7c  timing-integer25.mov
21193b8127f72245e1b1719d46bb896b0d7968d64c637d3220348d48c0719a2f  timing-integer50.mov
112548a93ecd4f1e1943f813e73d0f9617db3ce30dced8c8bc1fa4121a9e4168  timing-integer60.mov
6bc54823d4d673b28853e5670e33164f470247c5c0c5a94072f8c0a56b1ddd83  timing-irregular.mov
071f8c88021b6b74e31d8a3f227200be69bf94d0fa96b72c785d079d16344040  timing-variable.mov
```
