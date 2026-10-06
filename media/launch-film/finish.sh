#!/bin/bash
# Assembles the deliverables from <dir>/video.mp4 (render.mjs full) and <dir>/audio.wav (audio.py).
# Usage: ./finish.sh [dir] [name]   (defaults: out appotheque-film); POSTER_T picks the poster frame.
#   <dir>/<name>.mp4         film with sound, -14 LUFS, poster as frame 0
#   <dir>/poster.jpg            the poster frame
#   <dir>/readme-loop.gif       silent loop of the opening for the README (960 px)
set -euo pipefail
cd "$(dirname "$0")"
D=${1:-out}; NAME=${2:-appotheque-film}
PACE=${PACE:-1}   # same pace as the render, to time the README loop
POSTER_T=${POSTER_T:-20.4}   # a settled frame: the icon, the name and the tagline

ff() { ffmpeg -hide_banner -loglevel error -y "$@"; }

ff -ss "$POSTER_T" -i $D/video.mp4 -frames:v 1 -q:v 2 $D/poster.jpg
# Frame 0 becomes the poster so every platform shows it as the thumbnail; the duration stays the same.
ff -i $D/video.mp4 -i $D/poster.jpg -i $D/audio.wav \
  -filter_complex "[1:v]scale=1920:1080,format=yuv420p[p];[0:v][p]overlay=enable='eq(n\,0)'[v];[2:a]loudnorm=I=-14:TP=-1.5:LRA=11,alimiter=limit=0.7:level=false[a]" \
  -map "[v]" -map "[a]" -c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p -c:a aac -b:a 192k -shortest -movflags +faststart \
  $D/$NAME.mp4
# README loop: the fingerprint forming and the title, 0.3 s to 3.6 s.
# (This ffmpeg has no WebP encoder: a GIF with its own palette.)
ff -ss $(awk "BEGIN{print 0.3*$PACE}") -t $(awk "BEGIN{print 3.3*$PACE}") -i $D/video.mp4 -filter_complex "fps=20,scale=960:-2:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" -loop 0 $D/readme-loop.gif
ls -lh $D/$NAME.mp4 $D/poster.jpg $D/readme-loop.gif
