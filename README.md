# X5 INSV Player

Native macOS player for raw Insta360 X5 `.insv` captures.

It opens a capture straight off the camera card, decodes both HEVC lens tracks
with VideoToolbox through AVFoundation, parses the Insta360 metadata trailer,
and stitches the two fisheye circles into an interactive 360-degree view in a
Metal shader. No Insta360 SDK is involved.

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
swift run X5INSVPlayer --dump /Volumes/Insta360/DCIM/Camera01/VID_xxx_00_001.insv
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
- **The file name**, `VID_20260627_145116_00_015.insv`, in the camera's local
  time. This is the only place the camera's time-zone offset survives, so the
  name is read as wall clock and compared against UTC to recover it. On the X5
  sample the container says 12:51:16 and the name says 14:51:16, which is how
  the sidebar knows the camera was set to UTC+2.
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
gravity — which is the yaw the viewer controls anyway. On the X5 sample gravity
sits almost entirely on the IMU's X axis and the recovered alignment is 86.6
degrees, so a hard-coded axis convention would have tipped that capture on its
side. Orientation is integrated from the gyro with a complementary correction
toward measured gravity, so it does not drift over a long clip.

The sensor scales were measured rather than assumed: mean accelerometer
magnitude came out at 0.993 g against the 1024 counts per g that a +/-32 g range
implies, and fitting integrated gyro rotation against the accelerometer's tilt
over two second windows landed on +/-1000 deg/s.

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
