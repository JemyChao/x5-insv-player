# X5 INSV Player

Native macOS player for raw X5 `.insv` 360 captures.

It opens a capture straight off the camera card, decodes both HEVC lens tracks
with VideoToolbox through AVFoundation, parses the capture's metadata trailer,
and stitches the two fisheye circles into an interactive 360-degree view in a
Metal shader. No vendor SDK is involved.

## What it does

- X5 single-file, dual-video-track captures, 5.7K and 8K
- Hardware HEVC decode, with the two lens tracks realigned by presentation time
- Feathered seam blend across the overlap band the two 190-plus degree lenses share
- Audio playback, and a media clock so playback runs at the capture's real frame rate
- INSV trailer parsing: metadata blocks, gyro/accelerometer track, GPS fixes, exposure records, preview image
- Capture date and time from three independent sources, with the time-zone offset between them
- Horizon lock and full orientation lock driven by the capture's own IMU track
- Four views: perspective, equirectangular, little planet, and a raw-lens inspector for calibration
- BT.709 and BT.2020 matrices, with an optional HLG-to-SDR tone map for 10-bit captures
- Drag or scroll to look around, pinch or scroll to zoom, space to play, `R` to recentre

## Open in Xcode

Open `Package.swift` in Xcode 15.3 or later, choose the `X5INSVPlayer` scheme,
and run it on macOS 14 or later.

For a real check, open an original 5.7K-or-higher `.insv` file directly from the
camera card. Keep the original name and the neighbouring camera files intact.

`.insv` is a plain MP4 container, but AVFoundation types files by extension and
does not know that one. The player therefore retries through a temporary `.mp4`
symlink (falling back to a copy) whenever the direct open finds no lens tracks.
The sidebar says when that path was taken.

## Inspecting a capture from the terminal

```
swift run X5INSVPlayer --dump /Volumes/<card>/DCIM/Camera01/VID_xxx_00_001.insv
```

This prints the trailer block table, the IMU sample rate and magnitudes, any
text blobs, the GPS layout it settled on with the first and last fix, the three
capture timestamps, the container box list, and every underscore-separated
numeric list found in the trailer and in `udta`. It is the quickest way to see
why a capture did not yield calibration, gyro or GPS data.

## Time and location

Three timestamps are read, and all three are shown because they disagree in a
way that matters:

- **`mvhd`** in the MP4 movie header, seconds since 1904-01-01, normally UTC.
- **The file name**, `VID_20250101_120000_00_001.insv`, in the camera's local
  time. This is the only place the camera's time-zone offset survives, so the
  name is read as wall clock and compared against UTC to recover it. A
  container stamp two hours behind the name is how the sidebar works out that
  the camera was set to UTC+2.
- **The first GPS fix**, always UTC, and the most trustworthy of the three
  because copying or re-muxing a file cannot rewrite it.

GPS comes from trailer block 0x0700. The X5 has no GPS receiver of its own, so
that block is absent unless a GPS remote was paired, and no capture to hand
contains one. Rather than hard-code a layout that cannot be checked, the decoder
looks for the pair of adjacent doubles that behaves like a coordinate across the
whole block and reports whatever it settles on, so it can be verified the first
time a capture with fixes turns up.

## Calibration

The INSV trailer is reverse engineered rather than documented, and the format
below was read off a real X5 capture (firmware v1.11.6) rather than guessed:

- The trailer is a top-level MP4 box of type `inst` and ends with a 78 byte
  footer whose last 32 bytes are the ASCII magic, with the trailer length at
  offset 38 and the size of the block index at offset 2.
- Blocks are located through a flat index of ten byte slots sitting just in
  front of the footer: big-endian id, then little-endian length and offset from
  the start of the trailer. Empty slots are zero-filled.
- Block 0x0300 holds 20 byte IMU records: a microsecond timestamp and six
  16-bit channels biased by 0x8000, accelerometer XYZ then gyro XYZ.
- Block 0x0400 holds 16 byte exposure records: a microsecond timestamp on the
  same clock and the shutter time as a double, one per video frame. Its first
  timestamp is where video time zero sits, so it is what the IMU track is
  aligned against.
- Block 0x0101 carries the camera model, serial, firmware and the lens
  calibration as underscore-separated number lists.

The calibration list used is the sixteen-fields-per-lens form:

    <count>_ radius_cx_cy_ roll_pitch_heading_ tx_ty_tz_ k1_k2_k3_k4_ w_h_code

`radius`, `cx` and `cy` are pixels on a canvas holding both circles (10752 x
5376 on the sample, so each lens gets a 5376 square lane), and k1...k4 are the
radial polynomial in exactly the form the shader wants: they sum to 0.996 at the
rim, which is the normalised radius the model expects there. The headings share
a convention offset near 90 degrees, so they are taken relative to the front
lens rather than at face value.

The one number the list does not carry is the field of view, so that stays at
the 192 degree default. The lens model is fully exposed in the inspector panel,
which means dialling in a capture is now a matter of trimming one scalar. Switch to the **Raw lenses** view, turn on the guide circles,
align centre and radius against the actual image circles, then switch back to
perspective and trim FOV, yaw, roll and gain until the seam disappears. The
profile is saved to `~/Library/Application Support/X5INSVPlayer/lens-profile.json`
and reloaded at launch.

The radial term is a quartic in `θ / (fov/2)`, so `k2` and `k3` handle a lens
that is not perfectly equidistant without needing the manufacturer's polynomial.

## Stabilisation

The IMU axis convention is not documented either, but the accelerometer and the
gyro share a body frame. Averaging the accelerometer over a whole clip gives
gravity in that frame; aligning it with world down pins every axis that matters
for a level horizon, and the only rotation left undetermined is a spin about
gravity. On both sample captures gravity sits on the IMU's X axis, so IMU -X is
the camera's down.

That rotation is snapped to whole right angles rather than taken as the shortest
arc to the measured mean. The sensor is soldered to a board inside the body, so
the true rotation maps axes onto axes; averaged gravity says which axis points
down and nothing more, because the rest of it is how far the operator happened
to hold the camera off level during that clip. Taking the shortest arc folds
that into the frame and tilts every horizon the clip produces. It is 12.4
degrees on one sample capture and 3.3 on another from the same camera — a fixed
mounting cannot move between clips, which is how the mistake shows itself.

Orientation is integrated from the gyro with a complementary correction toward
measured gravity, so it does not drift over a long clip.

The sensor scales and the clock origin are read from the capture, not assumed.
Trailer record 1 is a protobuf carrying `gyro_cfg_info` (+/-32 g and +/-2000
deg/s on an X5), `is_raw_gyro` (which of the two IMU encodings is in use), and
`first_frame_timestamp`, which is where video time zero sits on the IMU's clock.

Both were got wrong here by guessing first. The accelerometer range was measured
correctly, but fitting the gyro range against the accelerometer's tilt landed
near 1100 and was read as +/-1000: half the truth. Worse, video time zero was
taken from the first exposure record, which on the sample capture is 0.767 s
before `first_frame_timestamp` — the camera runs the IMU through a pre-roll. So
every frame's correction was looked up three quarters of a second out of step,
which at 16 deg/s of camera motion is a median 2.84 degrees of error per frame,
6.4 at the 90th percentile and 12 at worst, changing frame to frame. That is a
swimming horizon, and no amount of filter tuning fixes it.

The gravity reference is averaged over a window centred on each sample, not a
trailing one. Nothing here is real time, so there is no reason to accept the lag
a causal filter would cost, and handheld linear acceleration swamps the raw
accelerometer badly enough that steering by it directly is what makes
stabilisation read as shake rather than cure it. The correction gain comes from
elapsed time rather than a fixed per-sample fraction, so the filter's time
constant does not change with the sample rate — this IMU runs at 1 kHz, where a
constant tuned for a slower sensor ends up forty times too aggressive.

Measured on the sample capture, against a gravity reference the filter does not
itself use: unstabilised, the horizon sits 5.8 degrees off level. A per-sample
gain of 0.02 leaves it at 5.9 — no levelling at all — while raising
high-frequency judder 27 per cent above unstabilised, which is exactly what
"stabilisation makes it worse" looks like. With the window at 1.5 s the horizon
lands 1.3 degrees off and judder falls 14 per cent below unstabilised. The
**Smoothing** control is that window: short is twitchy, long is steady but slow
to re-level after a real tilt.

**Horizon overlay** draws where the IMU says level is, in red, against the
window's centre lines in green. Read it with **stabilisation off**: the line
then sits on the raw image, where the real horizon is usually visible, and the
footage becomes the reference the IMU cannot be for itself.

- Red line tracks the real horizon: the estimate is sound, so any remaining
  shake is in applying it rather than in working it out.
- Red line sits at a steady angle to the real horizon: the **IMU heading** is
  wrong and the correction tilts about the wrong axis. Try the other three.

Drawing this from a lightly smoothed accelerometer instead was tried and is a
trap: on a handheld capture the measured gravity direction sits a median 4.9
degrees off the filtered reference and moves 3 degrees a frame, so the line
shows linear acceleration and reads as though stabilisation had failed.

**Full** cancels the orientation outright. **Horizon** removes only the tilt and
lets the heading stay with the camera, which is `q⁻¹ · twist(q)`: cancel the
orientation, then put the heading back. Inverting the tilt on its own is not the
same thing — that rotates about a world-fixed axis rather than a camera-relative
one, so it mixes roll into pitch the moment the camera pans.

Because the horizon correction is a rotation about a horizontal axis, it has to
be expressed in the camera's heading frame, and the constant offset between the
IMU and the camera cannot be recovered from the IMU alone. The sensor is
board-mounted so the real value is a right angle, and the **IMU heading** control
offers the four. It matters: on the sample capture, measured against the
capture's own IMU track, per-frame horizon jitter is 4.28 degrees unstabilised,
0.00 with the correct heading, and 6.01 with one that is 90 degrees out. If the
horizon tips the wrong way, that control is the reason.

One more thing worth recording, because it made stabilisation look broken: the
correction is sampled at the timestamp of the frame on screen, never at the
playback clock. The view redraws at 60 Hz while a capture runs at 30, so reading
the clock rotates each frame differently on its two draws. On the sample that is
a 0.27 degree average step, 1.83 at its worst, alternating every draw — a 60 Hz
vibration sitting on top of an otherwise stabilised image.

## Architecture

| File | Responsibility |
| --- | --- |
| `CaptureReader` | AVAssetReader, `.insv` opening, PTS-aligned frame pairs, bounded decode queue |
| `PlaybackEngine` | Media clock, audio streaming, frame selection for the render loop |
| `INSVTrailer` | Trailer block walk, IMU/GPS/exposure decoding, calibration scanning |
| `CaptureMetadata` | MP4 box reader for `mvhd` dates and `udta` strings, file-name time parsing |
| `MotionTrack` | Gyro integration, gravity alignment, horizon/full lock |
| `LensProfile` | Per-lens fisheye model and its persistence |
| `PanoramaRenderer` | Metal textures for both planes of both lenses, uniforms, gestures |
| `Panorama.metal` | YUV decode, fisheye projection, seam blend, the four view modes |
| `PlayerModel` | UI state, kept away from the decode and render layers |

## Known limits

- Only the first two video tracks are used; older two-file captures are not handled.
- The HLG tone map is a roll-off, not a colour-managed HDR path.
- Seeking lands on the preceding sync sample and drops forward to the target,
  so scrubbing on an 8K capture is as fast as the decoder allows, no faster.

## Licence

Apache License 2.0 — see `LICENSE`. It is preferred here over a shorter permissive
licence for its explicit patent grant.

## Independent project

Not affiliated with, endorsed by, or connected to the camera's manufacturer. No
vendor SDK, library or source is used: the container layout was worked out by
reading the bytes of ordinary, unencrypted capture files.

## Acknowledgements

The trailer layout here was reverse engineered from captures directly, then
cross-checked against the `docs/research/insv-format.md` notes in
[aeharding/kjerag](https://github.com/aeharding/kjerag), which is a far deeper
treatment of the same format and is worth reading before repeating any of this
work. That document is what identified `gyro_cfg_info`, `first_frame_timestamp`
and the record id/format byte pair as fields rather than guesses. Kjerag is
AGPL-3.0 and no code from it is used here; file format facts are not
copyrightable, and the two implementations share nothing but the format.
