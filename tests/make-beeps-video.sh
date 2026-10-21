#!/usr/bin/env bash
# Makes tests/video/beeps.webm, the video probe's test video (committed; this
# script is how it was made, with a host FFmpeg that has libvpx and libopus):
# 3 seconds at 60 pictures a second, 320x180, VP9 and Opus like Ikemen GO's
# own videos. The picture is black but white from 1.0 to 1.1 seconds and from
# 2.0 to 2.1; the sound is silent but a 440 Hz beep at those same times, so a
# test can see that a video's sound comes with its pictures.
# usage: tests/make-beeps-video.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
on='gte(t,1)*lt(mod(t,1),0.1)'
ffmpeg -v error -y -bitexact \
	-f lavfi -i "color=c=black:s=320x180:r=60:d=3,drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='$on'" \
	-f lavfi -i "aevalsrc='if($on,0.5*sin(2*PI*440*t),0)':c=stereo:s=48000:d=3" \
	-c:v libvpx-vp9 -b:v 300k -g 60 -c:a libopus -b:a 96k -map_metadata -1 -fflags +bitexact \
	"$here/video/beeps.webm"
echo "make-beeps-video: $here/video/beeps.webm ($(du -h "$here/video/beeps.webm" | cut -f1))"
