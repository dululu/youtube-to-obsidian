#!/usr/bin/env bash
# 从视频里抽取关键帧截图，文件名自带真实时间戳，方便嵌进 Obsidian 笔记。
#
# 特性：
#   * 两种模式：scene（画面变化检测，挑有信息的帧）/ interval（固定间隔）
#   * 文件名形如 shot_003_00-12-30.png，时间戳来自真实帧 pts，不是猜的
#   * --max 控制总张数，超出按均匀间隔抽稀
#   * --contact-sheet 额外拼一张总览图，方便一次性挑图
#
# 用法:
#   bash make_screenshots.sh --video /tmp/yt-obsidian/video.mp4 --out /tmp/yt-obsidian/shots
#   bash make_screenshots.sh --url "https://youtu.be/xxx" --out ./shots --max 12
#
# 输出:
#   $OUT/shot_NNN_HH-MM-SS.png
#   $OUT/timestamps.tsv        file / timestamp / seconds
#   $OUT/contact-sheet.png     （加 --contact-sheet 时）
set -uo pipefail

video=""
url=""
out=""
mode="auto"
interval=""
max_shots=16
width=1280
threshold="0.30"
cookies="auto"
contact_sheet=0
keep_video=0

usage() {
  sed -n '2,20p' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --video) video="${2:-}"; shift 2 ;;
    --url) url="${2:-}"; shift 2 ;;
    --out) out="${2:-}"; shift 2 ;;
    --mode) mode="${2:-}"; shift 2 ;;
    --interval) interval="${2:-}"; shift 2 ;;
    --max) max_shots="${2:-}"; shift 2 ;;
    --width) width="${2:-}"; shift 2 ;;
    --threshold) threshold="${2:-}"; shift 2 ;;
    --cookies) cookies="${2:-}"; shift 2 ;;
    --contact-sheet) contact_sheet=1; shift ;;
    --keep-video) keep_video=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

for tool in ffmpeg ffprobe; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: 缺少 ${tool}（截图模式必需）：brew install ffmpeg" >&2
    exit 1
  fi
done

tmp="$(mktemp -d "${TMPDIR:-/tmp}/yt-shots.XXXXXX")"
cleanup() {
  if [ "$keep_video" -eq 1 ]; then
    echo "keep: 临时目录保留在 $tmp"
    return
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

if [ -z "$out" ]; then
  echo "ERROR: 缺少 --out <目录>" >&2
  exit 2
fi
mkdir -p "$out"

# ---------- 需要时先下载视频 ----------
if [ -z "$video" ]; then
  if [ -z "$url" ]; then
    echo "ERROR: 需要 --video <文件> 或 --url <链接>" >&2
    exit 2
  fi
  if ! command -v yt-dlp >/dev/null 2>&1; then
    echo "ERROR: 缺少 yt-dlp：brew install yt-dlp" >&2
    exit 1
  fi
  echo "== 下载视频（<=1080p）=="
  strategies=()
  case "$cookies" in
    auto) strategies=("--cookies-from-browser chrome" "--cookies-from-browser safari" "") ;;
    none) strategies=("") ;;
    *) strategies=("--cookies-from-browser $cookies" "") ;;
  esac
  formats=(
    "bestvideo[height<=1080]+bestaudio/best[height<=1080]/best"
    "best[height<=480]/worst"
  )
  >"$tmp/download.log"
  for fmt in "${formats[@]}"; do
    for strategy in "${strategies[@]}"; do
      {
        echo "===== attempt: fmt='$fmt' cookies='${strategy:-none}' ====="
      } >>"$tmp/download.log"
      # shellcheck disable=SC2086
      yt-dlp $strategy --no-playlist --ignore-config \
        -f "$fmt" --merge-output-format "mp4/mkv" \
        -o "$tmp/video.%(ext)s" "$url" >>"$tmp/download.log" 2>&1
      video="$(find "$tmp" -maxdepth 1 -type f \( -name 'video.mp4' -o -name 'video.mkv' -o -name 'video.webm' \) | head -1)"
      [ -n "$video" ] && break 2
    done
  done
  if [ -z "$video" ]; then
    echo "ERROR: 视频下载失败（已尝试多档清晰度与多组 cookies）。错误摘要：" >&2
    grep -E "^ERROR|Sign in to confirm|Forbidden|could not find" "$tmp/download.log" | tail -5 >&2
    echo "完整日志：$tmp/download.log（脚本退出后会被清理，需要留存就加 --keep-video）" >&2
    exit 1
  fi
fi

if [ ! -f "$video" ]; then
  echo "ERROR: 找不到视频文件 $video" >&2
  exit 1
fi

# ---------- 时长 ----------
duration="$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$video" 2>/dev/null | head -1)"
if [ -z "$duration" ]; then
  echo "ERROR: ffprobe 读不到时长，文件可能损坏：$video" >&2
  exit 1
fi
echo "duration: $(awk -v d="$duration" 'BEGIN{printf "%.1fs (%.1f min)", d, d/60}')  |  max shots: $max_shots"

if [ "$mode" = "auto" ]; then
  if awk -v d="$duration" 'BEGIN{exit !(d <= 1800)}'; then
    mode="scene"
  else
    mode="interval"
  fi
fi
echo "mode: $mode"

# ---------- 抽帧 ----------
extract_interval() {
  [ -z "$interval" ] && interval="$(awk -v d="$duration" -v m="$max_shots" \
    'BEGIN{ if (d<=180) b=15; else if (d<=600) b=45; else if (d<=1800) b=120;
            else if (d<=5400) b=180; else b=300;
            need=int(d/m)+1; if (need>b) b=need; print b }')"
  echo "interval: ${interval}s"
  ffmpeg -hide_banner -nostdin -y -loglevel error -i "$video" \
    -vf "fps=1/${interval},scale=${width}:-2" "$tmp/frame_%04d.png"
}

extract_scene() {
  if ffmpeg -hide_banner -h full 2>/dev/null | grep -q -- "-fps_mode"; then
    vsync_flag=(-fps_mode vfr)
  else
    vsync_flag=(-vsync vfr)
  fi
  # showinfo 只在 info 级别输出，这里不能用 -loglevel error
  ffmpeg -hide_banner -nostdin -y -loglevel info -i "$video" \
    -vf "select='gt(scene,${threshold})',scale=${width}:-2,showinfo" "${vsync_flag[@]}" \
    "$tmp/frame_%04d.png" 2>"$tmp/showinfo.log"
  # showinfo 在 select 之后，所以每个 pts_time 对应一张已选出的帧
  grep -o 'pts_time:[0-9.]*' "$tmp/showinfo.log" | cut -d: -f2 |
    awk 'NR==1 || $1 != seen {print; seen=$1}' >"$tmp/scene-times.txt"
  echo "scene hits: $(wc -l <"$tmp/scene-times.txt" | tr -d ' ')"
}

if [ "$mode" = "scene" ]; then
  extract_scene
  n_frames=$(find "$tmp" -maxdepth 1 -name 'frame_*.png' | wc -l | tr -d ' ')
  if [ "$n_frames" -lt 3 ] || [ "$(wc -l <"$tmp/scene-times.txt" | tr -d ' ')" -eq 0 ]; then
    echo "画面变化点太少或时间戳解析失败（${n_frames} 帧），回退到固定间隔模式"
    find "$tmp" -maxdepth 1 -name 'frame_*.png' -delete
    mode="interval"
  fi
fi

if [ "$mode" = "interval" ]; then
  extract_interval
fi

# ---------- 把帧序号和真实时间戳对齐 ----------
n_frames=$(find "$tmp" -maxdepth 1 -name 'frame_*.png' | wc -l | tr -d ' ')
if [ "$n_frames" -eq 0 ]; then
  echo "ERROR: ffmpeg 没有抽出任何帧。" >&2
  exit 1
fi

if [ "$mode" = "scene" ]; then
  head -n "$n_frames" "$tmp/scene-times.txt" >"$tmp/times.txt"
  n_times=$(wc -l <"$tmp/times.txt" | tr -d ' ')
  if [ "$n_times" -lt "$n_frames" ]; then
    echo "警告: 时间戳数（${n_times}）少于帧数（${n_frames}），按较短的对齐"
    n_frames="$n_times"
  fi
else
  awk -v i="$interval" -v n="$n_frames" 'BEGIN{ for (k=0; k<n; k++) print k*i }' >"$tmp/times.txt"
fi

# 序号 + 时间，超过上限时均匀抽稀（保留原始帧序号）
awk -v n="$n_frames" '{ printf "%d\t%s\n", NR-1, $0 }' "$tmp/times.txt" >"$tmp/indexed.tsv"
if [ "$n_frames" -gt "$max_shots" ]; then
  step=$(awk -v n="$n_frames" -v m="$max_shots" 'BEGIN{ printf "%d", int((n-1)/m) + 1 }')
  awk -v s="$step" 'NR==1 || (NR-1)%s==0' "$tmp/indexed.tsv" >"$tmp/selected.tsv"
  echo "帧数 ${n_frames} 超过上限 ${max_shots}，每 ${step} 帧取 1 帧"
else
  cp "$tmp/indexed.tsv" "$tmp/selected.tsv"
fi

# ---------- 重命名：把真实时间戳写进文件名 ----------
hhmmss() { awk -v s="$1" 'BEGIN{printf "%02d:%02d:%02d", int(s/3600), int(s%3600/60), int(s%60)}'; }

rm -f "$out"/shot_*.png 2>/dev/null
printf 'file\ttimestamp\tseconds\n' >"$out/timestamps.tsv"
idx=0
while IFS="$(printf '\t')" read -r frame_no t; do
  idx=$((idx + 1))
  src="$(printf '%s/frame_%04d.png' "$tmp" "$((frame_no + 1))")"
  [ -f "$src" ] || continue
  stamp="$(awk -v s="$t" 'BEGIN{printf "%02d-%02d-%02d", int(s/3600), int(s%3600/60), int(s%60)}')"
  dst="$(printf '%s/shot_%03d_%s.png' "$out" "$idx" "$stamp")"
  cp "$src" "$dst"
  printf '%s\t%s\t%s\n' "$(basename "$dst")" "$(hhmmss "$t")" "$t" >>"$out/timestamps.tsv"
done <"$tmp/selected.tsv"

total=$(find "$out" -maxdepth 1 -name 'shot_*.png' | wc -l | tr -d ' ')
if [ "$total" -eq 0 ]; then
  echo "ERROR: 一张截图都没生成。" >&2
  exit 1
fi

total=$(find "$out" -maxdepth 1 -name 'shot_*.png' | wc -l | tr -d ' ')
echo "screenshots: $total 张 -> $out"

# ---------- 总览图 ----------
if [ "$contact_sheet" -eq 1 ]; then
  layout=$(awk -v n="$total" 'BEGIN{ c=(n<4?n:4); if (c<1) c=1; r=int((n+c-1)/c); if (r<1) r=1; printf "%dx%d", c, r }')
  # 用 glob 输入：帧数少于 5 张时，ffmpeg 的 %04d 序列探测会失败
  ffmpeg -hide_banner -nostdin -y -loglevel error -pattern_type glob \
    -i "$out/shot_*.png" \
    -vf "scale=360:202:force_original_aspect_ratio=decrease,pad=360:202:(ow-iw)/2:(oh-ih)/2:color=0x111111,tile=${layout}:padding=6:color=0x222222" \
    -frames:v 1 "$out/contact-sheet.png" \
    && echo "contact sheet: $out/contact-sheet.png"
fi

echo "timestamps: $out/timestamps.tsv"
