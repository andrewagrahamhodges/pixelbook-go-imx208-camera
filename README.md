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
git apply /path/to/libcamera-imx208-agc-metering.patch
git apply /path/to/libcamera-imx208-wb-trim.patch
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
2. **Gamma 2.0** — shadow/midtone lift (upstream 1.1 left shadows crushed).
3. **Contrast S-curve 1.35** — S-curve around the midpoint restores punch so the brightened image doesn't look hazy.
4. **Digital brightness lift ×1.4** — multiplier after the contrast stage, clamped at white. Blacks and clipped highlights are unaffected.

Order matters: normalize/crush first, then gamma, then contrast, then the brightness multiplier. Curve values were tuned visually (1.7/0.03/1.3 was the first pass, judged "brighter but foggy"; 1.9/0.04/1.4 was the second, judged "much better"; 2.0/0.04/1.35 is the final).

The brightness lift exists because the AE has no headroom left in indoor light (see next section): with exposure and analogue gain already at the sensor ceiling, this is the only honest lever. It is entirely ISP-side, so there is no frame-rate cost.

### AE metering patch (backlit scene fix)

In a backlit scene (subject in front of a bright window) the whole-frame, mean-based AGC meters the window too and leaves the subject heavily underexposed. `patches/libcamera-imx208-agc-metering.patch` changes `src/ipa/ipu3/algorithms/agc.cpp` in two ways:

1. **Center-weighted metering** — each statistics cell is weighted by a Gaussian of its distance from frame center, sigma 0.28 half-frame units (aggressive). The bright window at the frame edge contributes almost nothing to the exposure decision; a uniformly bright scene meters to the same value as before, so the bias below keeps its meaning.
2. **Exposure bias ×2.0 (+1 EV)** — the estimated luminance is divided by 2 before the solver, biasing exposure up one stop. The default AE constraint is a lower bound only, so it cannot cancel the bias out.

Tuning history: the first pass used sigma 0.35, then 0.28 (owner asked for more aggression; A/B in identical light showed the metering had plateaued since the window's weight was already near zero). The exposure bias was tried at 2.8 (+1.5 EV) and judged "far too much" - 2.0 is final.

**Physical exposure ceiling (important context):** with this patch in indoor light the imx208 runs at its sensor ceiling - exposure 1129/1130 lines (~16.5 ms at 60 fps), analogue gain 185/224 (~18×) - while the AGC requests ~595× gain that the hardware clamps. More AE aggression cannot brighten the subject further; only the digital lift in the tone-mapping patch can.

### White-balance trim (yellow cast fix)

Even with a neutral tone curve, images had a persistent warm (yellow) cast in typical indoor light: upstream's grey-world AWB under-corrects warm illumination. `patches/libcamera-imx208-wb-trim.patch` applies a fixed trim in `src/ipa/ipu3/algorithms/awb.cpp` after the grey-world estimate.

**Current values: red gain ×1.04, blue gain ×0.97** (warm trim). History: the original trim was cool (red ×0.93, blue ×1.10), tuned for warm evening light; in daylight it over-cooled the image into a pale washed-out look. The trim is load-bearing in both directions — grey-world's estimate varies with the room light, so re-tune by measuring face-region chroma on a live capture if the light in the room changes character.

Install gotcha: the IPA must be installed with `sudo ninja -C build install` (which signs it and places it at the nested `libcamera/ipa/` path). A bare `cp` of `ipa_ipu3.so` to the flat `libcamera/` path silently does nothing — libcamera ignores it.

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
