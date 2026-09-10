# pixelbook-go-imx208-camera

End-to-end notes for getting the Sony IMX208 front camera of the **Google Pixelbook Go** working under Linux with MrChromebox coreboot firmware. Everything below was verified on real hardware: Ubuntu 26.04, kernel 7.0.0-31-generic, coreboot `26.06-1198-g1868e4c8dea-dirty` (2026-09-09).

Context and hardware discussion: [coreboot issue #992](https://ticket.coreboot.org/issues/992).

## The three layers

1. **Firmware** — the camera subtree must live in an SSDT, not the DSDT. Builds from 1198-dirty onward emit `_SB.PCI0.I2C3.CAM0` in an SSDT; the sensor powers on and appears in the media graph. On older firmware the sensor never enumerates (`INT3472 seems to have no dependents`).
2. **Kernel / V4L2** — the sensor binds as `i2c-INT3478:00`, but the IPU3 pipeline formats don't match out of the box. See [scripts/fix-pipeline.sh](scripts/fix-pipeline.sh).
3. **Userspace (libcamera)** — stock libcamera has no IMX208 sensor helper, so the IPU3 IPA fails with `Failed to create camera sensor helper for imx208` and no camera registers. Apply [patches/libcamera-imx208.patch](patches/libcamera-imx208.patch).

## libcamera patch (verified)

Built against **libcamera v0.7.2** (Ubuntu 26.04 stock is 0.7.0 and will not work):

```sh
git clone --branch v0.7.2 https://git.libcamera.org/libcamera/libcamera.git
cd libcamera
git apply /path/to/libcamera-imx208.patch
git apply /path/to/libcamera-imx208-tone-mapping.patch
meson setup build -Dpipelines=uvcvideo,ipu3 -Dipas=ipu3 -Dv4l2=true -Dgstreamer=enabled
ninja -C build && sudo ninja -C build install
```

Then **restart PipeWire and WirePlumber** so they load the patched libcamera from `/usr/local`:

```sh
systemctl --user restart pipewire wireplumber
```

Verified result: `cam -l` lists `_SB_.PCI0.I2C3.CAM0`, WirePlumber loads `/usr/local/share/libcamera/ipa/ipu3/imx208.yaml`, PipeWire exposes `imx208 [libcamera]`, and GNOME Snapshot shows a picture.

Known non-fatal warnings after the fix: missing location/rotation properties and V4L2 selection ioctls unsupported by the kernel driver.

### Tone-mapping patch (dark image fix)

Even with the helper in place, indoor images were very dark: the imx208 AGC pegs exposure and analogue gain at max in typical room light, and upstream's IPU3 IPA hardcodes tone-mapping gamma to 1.1 (nearly linear, no shadow lift). `patches/libcamera-imx208-tone-mapping.patch` replaces that curve in `src/ipa/ipu3/algorithms/tone_mapping.cpp` with a three-stage LUT:

1. **Black-point crush (4%)** — values below the sensor noise floor go to true black, so brightness later doesn't turn noise into gray fog.
2. **Gamma 1.9** — shadow/midtone lift (upstream 1.1 left shadows crushed).
3. **Contrast S-curve 1.4** — S-curve around the midpoint restores punch so the brightened image doesn't look hazy.

Order matters: normalize/crush first, then gamma, then contrast. Values were tuned visually (1.7/0.03/1.3 was the first pass, judged "brighter but foggy"; 1.9/0.04/1.4 is the current best). Exposure/gain are untouched - the lift is entirely ISP-side, so there is no frame-rate cost.

## Kernel driver patch (optional)

`patches/imx208-driver.patch` adds power management (avdd regulator, reset GPIO, clock enable, runtime PM) to the imx208 kernel driver. Not needed on 1198-dirty+ firmware where INT3472 power is wired; useful for setups where the sensor doesn't power on.

## V4L2 pipeline fix (raw capture without libcamera)

Out of the box, STREAMON fails with EPIPE (csi2 pad0 defaults to SGRGB10 vs sensor SRGGB10), then EINVAL on the video node. Fix:

```sh
media-ctl --set-v4l2 '"ipu3-csi2 0":0[fmt:SRGGB10_1X10/1936x1096]'
v4l2-ctl -d /dev/video0 --set-fmt-video=width=1936,height=1096,pixelformat=ip3r
```

Then capture: `v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=3`. See [scripts/fix-pipeline.sh](scripts/fix-pipeline.sh).

## Credits

- libcamera IMX208 helper patch based on [deepdream/atlas-imx208-camera](https://github.com/deepdream/atlas-imx208-camera) (GPL-2.0).
- Firmware work by the coreboot community (issue #992).

## License

GPL-2.0, matching the original sources.
