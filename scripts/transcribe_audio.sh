#!/usr/bin/env bash
# 视频/音频 → 字幕文件。视频完全没有字幕时用它兜底（Step 2 失败后的 Plan B）。
#
# 输入端三选一（按优先级）：
#   --video <文件>   本地视频，先抽音轨再转写
#   --audio <文件>   本地音视频文件，直接转写
#   --url  <链接>    用 yt-dlp 下载音轨
#
# 转写后端自动挑选：
#   1. MLX Whisper  —— Apple Silicon 上快很多，装了就优先用
#   2. OpenAI Whisper CLI —— 通用兜底，本机通常已装
#   3. Python whisper 模块 —— 连 CLI 都没有时的最后一招
#
# 用法:
#   bash transcribe_audio.sh --video foo.mp4 --out /tmp/yt-obsidian
#   bash transcribe_audio.sh --url "https://youtu.be/xxx" --out /tmp/yt-obsidian --model small
#   bash transcribe_audio.sh --audio foo.m4a --out /tmp/yt-obsidian --language zh --model medium
#
# 输出:
#   $OUT/audio.wav        抽出来的 16k 单声道音轨
#   $OUT/transcript.srt   Whisper 输出的字幕
#   $OUT/asr-report.txt   用了什么模型/后端/耗时
#   终端: 一行 ESTIMATED_MINUTES=<n>，供上层决定是否等得起
set -uo pipefail

video=""
audio=""
url=""
out=""
model="auto"
language="auto"
cookies="auto"

while [ $# -gt 0 ]; do
  case "$1" in
    --video) video="${2:-}"; shift 2 ;;
    --audio) audio="${2:-}"; shift 2 ;;
    --url) url="${2:-}"; shift 2 ;;
    --out) out="${2:-}"; shift 2 ;;
    --model) model="${2:-}"; shift 2 ;;
    --language | --lang) language="${2:-}"; shift 2 ;;
    --cookies) cookies="${2:-}"; shift 2 ;;
    -h | --help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$out" ]; then
  echo "ERROR: 缺少 --out <目录>" >&2
  exit 2
fi
mkdir -p "$out"

for tool in ffmpeg ffprobe; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: 缺少 ${tool}（转写需要先抽音轨）：brew install ffmpeg" >&2
    exit 1
  fi
done

# ---------- 定模型 ----------
# Apple Silicon 内存宽裕可以直接上 medium；只用 CPU 时 medium 会慢到不可用
total_ram_gb=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || sysctl -n hw.memsize 2>/dev/null | awk '{printf "%d", $1/1024/1024/1024}')
is_arm=0
[ "$(uname -m)" = "arm64" ] && is_arm=1

if [ "$model" = "auto" ]; then
  if [ "$is_arm" -eq 1 ]; then
    model="small"
  else
    model="base"
  fi
fi

# ---------- 取音轨 ----------
want_wav="$out/audio.wav"

extract_from_file() {
  local src="$1"
  ffmpeg -hide_banner -nostdin -y -loglevel error -i "$src" \
    -vn -ac 1 -ar 16000 -c:a pcm_s16le "$want_wav" >"$out/.ffmpeg.log" 2>&1
}

has_audio() {
  ffprobe -v error -select_streams a:0 -show_entries stream=codec_type \
    -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null | grep -q audio
}

if [ -n "$audio" ]; then
  if [ ! -f "$audio" ]; then echo "ERROR: 找不到音频文件 $audio" >&2; exit 1; fi
  echo "== 从本地音频抽 16k 单声道 =="
  extract_from_file "$audio"
elif [ -n "$video" ]; then
  if [ ! -f "$video" ]; then echo "ERROR: 找不到视频文件 $video" >&2; exit 1; fi
  if ! has_audio "$video"; then
    echo "ERROR: 这个视频没有音轨，转写没有输入。" >&2
    echo "       纯字幕视频或静音录屏你得换个有声音的文件。" >&2
    exit 1
  fi
  echo "== 从本地视频抽音轨 =="
  extract_from_file "$video"
elif [ -n "$url" ]; then
  if ! command -v yt-dlp >/dev/null 2>&1; then
    echo "ERROR: 缺少 yt-dlp：brew install yt-dlp" >&2
    exit 1
  fi
  echo "== 下载音轨 =="
  strategies=()
  case "$cookies" in
    auto) strategies=("--cookies-from-browser chrome" "--cookies-from-browser safari" "") ;;
    none) strategies=("") ;;
    *) strategies=("--cookies-from-browser $cookies" "") ;;
  esac
  dl_ok=0
  for strategy in "${strategies[@]}"; do
    # shellcheck disable=SC2086
    yt-dlp $strategy --no-playlist --ignore-config -x --audio-format wav \
      -o "$out/audio_src.%(ext)s" "$url" >"$out/.yt-dlp.log" 2>&1
    for f in "$out"/audio_src.wav "$out"/audio_src.m4a "$out"/audio_src.webm "$out"/audio_src.mp3; do
      [ -f "$f" ] && { audio="$f"; dl_ok=1; break; }
    done
    [ "$dl_ok" -eq 1 ] && break
  done
  if [ "$dl_ok" -eq 0 ]; then
    echo "ERROR: 音轨下载失败。" >&2
    grep -E "^ERROR|Sign in to confirm|Forbidden" "$out/.yt-dlp.log" 2>/dev/null | tail -4 >&2
    exit 1
  fi
  echo "== 归一化音频 =="
  extract_from_file "$audio"
else
  echo "ERROR: 需要 --video / --audio / --url 三者之一" >&2
  exit 2
fi

if [ ! -s "$want_wav" ]; then
  echo "ERROR: 音轨抽取失败（产出了 0 字节）。完整日志：$out/.ffmpeg.log" >&2
  tail -5 "$out/.ffmpeg.log" 2>/dev/null >&2
  exit 1
fi

wav_size=$(stat -f %z "$want_wav" 2>/dev/null || echo 0)
# 16k 单声道 16bit = 32000 字节/秒
minutes=$(awk -v b="$wav_size" 'BEGIN{printf "%.1f", b/32000/60}')
echo "audio: ${minutes} 分钟"

printf 'source=%s\nmodel=%s\nlanguage=%s\naudio=%s\nRAM_GB=%s\napple_silicon=%s\n' \
  "${video:-${audio:-$url}}" "$model" "$language" "$want_wav" "${total_ram_gb:-?}" "$is_arm" >"$out/asr-report.txt"

# ---------- 定语言 ----------
lang_arg=""
[ "$language" != "auto" ] && lang_arg="--language $language"

# ---------- 选后端 ----------
start=$(date +%s)
rc=1
backend=""

if command -v mlx_whisper >/dev/null 2>&1; then
  backend="mlx-whisper"
  echo "== 转写：mlx-whisper（Apple Silicon 加速），模型 $model =="
  # shellcheck disable=SC2086
  mlx_whisper "$want_wav" --model "mlx-community/whisper-${model}" \
    $lang_arg --output-format srt --output-dir "$out" >"$out/.mlx.log" 2>&1
  rc=$?
  [ -f "$out/audio.srt" ] && mv "$out/audio.srt" "$out/transcript.srt"
fi

if [ "$rc" -ne 0 ] || [ ! -s "$out/transcript.srt" ]; then
  if command -v whisper >/dev/null 2>&1; then
    backend="whisper-cli"
    echo "== 转写：OpenAI Whisper CLI，模型 $model =="
    # shellcheck disable=SC2086
    whisper "$want_wav" --model "$model" $lang_arg \
      --output_format srt --output_dir "$out" >"$out/.whisper.log" 2>&1
    rc=$?
    [ -f "$out/audio.srt" ] && mv "$out/audio.srt" "$out/transcript.srt"
  fi
fi

if [ "$rc" -ne 0 ] || [ ! -s "$out/transcript.srt" ]; then
  backend="whisper-python"
  echo "== 转写：whisper Python API，模型 $model =="
  WHISPER_MODEL="$model" WHISPER_WAV="$want_wav" WHISPER_LANG="$language" WHISPER_OUT="$out" \
  python3 - >"$out/.whisper-py.log" 2>&1 <<'PY'
import os, sys, warnings
warnings.filterwarnings("ignore")
import whisper

model_name = os.environ["WHISPER_MODEL"]
wav = os.environ["WHISPER_WAV"]
lang = os.environ["WHISPER_LANG"]
out_dir = os.environ["WHISPER_OUT"]

model = whisper.load_model(model_name)
kwargs = {"fp16": False}
if lang != "auto":
    kwargs["language"] = lang
result = model.transcribe(wav, **kwargs)


def srt_time(seconds):
    total_ms = int(round(seconds * 1000))
    h, rem = divmod(total_ms, 3600000)
    m, rem = divmod(rem, 60000)
    s, ms = divmod(rem, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


lines = []
for i, seg in enumerate(result.get("segments", []), start=1):
    text = (seg.get("text") or "").strip()
    if not text:
        continue
    lines.append(str(i))
    lines.append(f"{srt_time(seg['start'])} --> {srt_time(seg['end'])}")
    lines.append(text)
    lines.append("")

if not lines:
    # 没有分段时（极短音频）至少把整段文本写进去
    text = (result.get("text") or "").strip()
    lines = ["1", "00:00:00,000 --> 00:00:01,000", text, ""]

path = os.path.join(out_dir, "transcript.srt")
with open(path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines))
print(f"WROTE {path} chars={sum(len(l) for l in lines)}")
PY
  rc=$?
  [ -f "$out/audio.srt" ] && mv "$out/audio.srt" "$out/transcript.srt"
fi

elapsed=$(( $(date +%s) - start ))

if [ ! -s "$out/transcript.srt" ]; then
  echo "ERROR: 转写失败，没有产出字幕。查看日志：$out/.whisper*.log" >&2
  tail -6 "$out/.whisper.log" "$out/.whisper-py.log" "$out/.mlx.log" 2>/dev/null >&2
  exit 1
fi

chars=$(wc -c <"$out/transcript.srt" | tr -d ' ')
printf 'backend=%s\nelapsed_seconds=%s\nsrt_bytes=%s\n' "$backend" "$elapsed" "$chars" >>"$out/asr-report.txt"

echo "transcript: $out/transcript.srt (${chars} bytes, ${elapsed}s, backend=$backend)"
echo "NOTE: 这是机器转写，专有名词和同音错别字大概率会有。写笔记时要交叉核对。"
