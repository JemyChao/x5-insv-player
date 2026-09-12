# X5 INSV Player

Native macOS proof of concept for playing raw Insta360 X5 `.insv` files.

This first version opens an X5 capture directly, decodes its two HEVC lens
tracks with VideoToolbox through AVFoundation, and sends their pixel buffers to
a Metal shader for an interactive 360-degree preview.

## Current scope

- X5 single-file, dual-video-track captures
- HEVC hardware decoding through macOS media frameworks
- Metal 360-degree look-around preview
- Drag to pan, scroll to change field of view
- Play/pause and local file access

## Deliberate limitations in this first version

The shader uses an approximate X5 lens model. It does not yet parse the
per-capture calibration, gyro track, exposure data, or time map in the INSV
trailer. Stitch precision and FlowState stabilization are therefore not final.
Audio and older two-file captures are also not part of this milestone.

## Open in Xcode

Open `Package.swift` in Xcode 15.3 or later, choose the `X5INSVPlayer` scheme,
and run it on macOS 14 or later. The app needs no Insta360 SDK.

For a real X5 check, open an original 5.7K-or-higher `.insv` file directly from
the camera card. Keep the original name and neighbouring camera files intact.

## Architecture

`CaptureReader` owns AVAssetReader and produces synchronized pixel-buffer pairs.
`PanoramaRenderer` owns Metal texture upload and the perspective projection
shader. `PlayerModel` keeps UI state away from the decode and render layers.

## Next milestone

Parse the INSV trailer and feed per-lens Mei calibration plus gyro orientation
to the Metal shader. That replaces the approximate projection with capture-
accurate stitching and horizon lock.
