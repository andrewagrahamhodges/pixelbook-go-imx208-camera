#!/bin/sh
# Align IPU3 pipeline formats so the IMX208 streams (run after each boot)
media-ctl --set-v4l2 '"ipu3-csi2 0":0[fmt:SRGGB10_1X10/1936x1096]'
v4l2-ctl -d /dev/video0 --set-fmt-video=width=1936,height=1096,pixelformat=ip3r
