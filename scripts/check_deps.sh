#!/usr/bin/env bash
# 依赖自检：yt-dlp / python3 为必需；ffmpeg + ffprobe 仅截图模式需要。
#
# 用法:
#   bash check_deps.sh               # 只检查基础依赖
#   bash check_deps.sh --screenshots # 额外要求 ffmpeg / ffprobe
set -uo pipefail

want_screenshots=0
for arg in "$@"; do
  [ "$arg" = "--screenshots" ] && want_screenshots=1
done

missing=0

if command -v yt-dlp >/dev/null 2>&1; then
  echo "ok      yt-dlp    $(yt-dlp --version 2>/dev/null | head -1)"
else
  echo "MISSING yt-dlp    -> brew install yt-dlp    (或 pipx install yt-dlp)"
  missing=1
fi

if command -v python3 >/dev/null 2>&1; then
  echo "ok      python3   $(python3 -V 2>&1 | head -1)"
else
  echo "MISSING python3   -> brew install python3"
  missing=1
fi

for tool in ffmpeg ffprobe; do
  if command -v "$tool" >/dev/null 2>&1; then
    echo "ok      $tool"
  elif [ "$want_screenshots" -eq 1 ]; then
    echo "MISSING $tool     -> brew install ffmpeg    (截图模式必需)"
    missing=1
  else
    echo "skip    $tool      仅截图模式需要，可忽略"
  fi
done

if [ "$missing" -eq 0 ]; then
  echo "deps: ok"
  exit 0
fi

echo "deps: missing required tools"
exit 1
