#!/usr/bin/env bash
# 下载 YouTube / Bilibili（以及 yt-dlp 支持的其它站点）字幕 + 视频元数据。
#
# 特性：
#   * 自动识别平台，选用默认语言优先级
#   * 语言回退：一次请求多个语言，下游挑可用最好的
#   * Cookie 回退：chrome -> safari -> firefox -> 无 cookie（两平台一致）
#   * 人工字幕优先，没有则用自动字幕
#   * 默认只取单集（--no-playlist），避免误下整个列表
#
# 用法:
#   bash fetch_transcript.sh --url "https://youtu.be/xxx" --out /tmp/yt-obsidian
#   bash fetch_transcript.sh --url "..." --lang "zh-Hans,zh-CN" --cookies none
#   bash fetch_transcript.sh --url "..." --list-subs
#   bash fetch_transcript.sh --url "..." --extra "--extractor-args youtube:player_client=web_safari"
#
# 输出:
#   $OUT/*.srt|*.vtt      字幕文件
#   $OUT/video-meta.tsv   标题|||UP主|||上传日期|||时长|||ID|||URL
#   $OUT/subtitles.list   字幕文件清单（无字幕时不存在）
#   $OUT/fetch-report.txt 本次抓取的参数与结果
set -uo pipefail

usage() {
  sed -n '2,20p' "$0"
}

url=""
lang=""
out="/tmp/yt-obsidian"
platform="auto"
cookies="auto"
list_subs=0
allow_playlist=0
extra=""

while [ $# -gt 0 ]; do
  case "$1" in
    --url) url="${2:-}"; shift 2 ;;
    --lang | --langs) lang="${2:-}"; shift 2 ;;
    --out) out="${2:-}"; shift 2 ;;
    --platform) platform="${2:-}"; shift 2 ;;
    --cookies) cookies="${2:-}"; shift 2 ;;
    --list-subs) list_subs=1; shift ;;
    --playlist) allow_playlist=1; shift ;;
    --extra) extra="${2:-}"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *)
      if [ -z "$url" ]; then
        url="$1"
        shift
      else
        echo "unknown argument: $1" >&2
        exit 2
      fi
      ;;
  esac
done

if [ -z "$url" ]; then
  echo "ERROR: 缺少视频 URL（--url \"<URL>\"）" >&2
  exit 2
fi

if ! command -v yt-dlp >/dev/null 2>&1; then
  echo "ERROR: 找不到 yt-dlp，请先安装：brew install yt-dlp" >&2
  exit 1
fi

if [ "$platform" = "auto" ]; then
  case "$url" in
    *youtube.com* | *youtu.be* | *youtube-nocookie.com*) platform="youtube" ;;
    *bilibili.com* | *b23.tv* | *bili2233.cn*) platform="bilibili" ;;
    *) platform="generic" ;;
  esac
fi

if [ -z "$lang" ]; then
  case "$platform" in
    youtube) lang="en,en-orig,zh-Hans,zh-Hant,zh" ;;
    bilibili) lang="zh-Hans,zh-CN,zh,zh-Hant,ai-zh,en" ;;
    *) lang="en,zh-Hans" ;;
  esac
fi

playlist_opt="--no-playlist"
[ "$allow_playlist" -eq 1 ] && playlist_opt="--yes-playlist"

mkdir -p "$out"

if [ "$list_subs" -eq 1 ]; then
  echo "== 可用字幕列表（诊断用）=="
  # shellcheck disable=SC2086
  yt-dlp $playlist_opt --list-subs "$url" 2>&1 | head -60
  exit 0
fi

clear_subs() {
  find "$out" -maxdepth 1 \( -name '*.srt' -o -name '*.vtt' \) -delete 2>/dev/null
}

subs_present() {
  find "$out" -maxdepth 1 \( -name '*.srt' -o -name '*.vtt' \) -size +10c 2>/dev/null | head -1 | grep -q .
}

# 逐个 cookie 策略重试，第一次拿到非空字幕就停；每次尝试的日志都追加保留
try_download_subs() {
  local cookie_arg="$1"
  clear_subs
  {
    echo "===== attempt: cookies='${cookie_arg:-none}' langs='$lang' ====="
  } >>"$out/.yt-dlp.log"
  # shellcheck disable=SC2086
  yt-dlp $cookie_arg $extra $playlist_opt \
    --write-subs --write-auto-subs \
    --sub-langs "$lang" --sub-format "srt/vtt/best" \
    --skip-download --no-warnings --ignore-config \
    -o "$out/%(title)s.%(ext)s" "$url" >>"$out/.yt-dlp.log" 2>&1
  local rc=$?
  [ "$rc" -eq 0 ] && extraction_ok=1
  subs_present
}

cookie_strategies=()
case "$cookies" in
  auto) cookie_strategies=("--cookies-from-browser chrome" "--cookies-from-browser safari" "--cookies-from-browser firefox" "") ;;
  none) cookie_strategies=("") ;;
  *) cookie_strategies=("--cookies-from-browser $cookies" "") ;;
esac

used_cookie="none"
ok=0
extraction_ok=0
> "$out/.yt-dlp.log"
for strategy in "${cookie_strategies[@]}"; do
  if try_download_subs "$strategy"; then
    ok=1
    if [ -n "$strategy" ]; then
      used_cookie="${strategy##* }"
    fi
    break
  fi
done

find "$out" -maxdepth 1 \( -name '*.srt' -o -name '*.vtt' \) -size +10c 2>/dev/null | sort >"$out/subtitles.list"

# 元数据：失败也不致命
meta_cookie_arg=""
[ "$used_cookie" != "none" ] && meta_cookie_arg="--cookies-from-browser $used_cookie"
# shellcheck disable=SC2086
yt-dlp $meta_cookie_arg $playlist_opt --skip-download --no-warnings --ignore-config \
  --print "%(title)s|||%(channel,uploader)s|||%(upload_date)s|||%(duration)s|||%(id)s|||%(webpage_url)s" \
  "$url" 2>/dev/null | head -1 >"$out/video-meta.tsv"

{
  echo "PLATFORM=$platform"
  echo "LANG_REQUESTED=$lang"
  echo "COOKIE_USED=$used_cookie"
  echo "SUBTITLE_COUNT=$(wc -l <"$out/subtitles.list" | tr -d ' ')"
  echo "SUBTITLES_BEGIN"
  cat "$out/subtitles.list"
  echo "SUBTITLES_END"
  echo "META_BEGIN"
  cat "$out/video-meta.tsv" 2>/dev/null
  echo "META_END"
} >"$out/fetch-report.txt"

cat "$out/fetch-report.txt"

if [ "$ok" -eq 1 ]; then
  exit 0
fi

echo "ERROR: 未取到任何字幕（平台=${platform}，语言=${lang}）" >&2
echo "---- 各次尝试的错误摘要 ----" >&2
grep -E "^ERROR|^WARNING: \[|could not find|Sign in to confirm|Precondition Failed" "$out/.yt-dlp.log" | tail -8 >&2
echo "---- 完整日志: $out/.yt-dlp.log ----" >&2
if grep -q "could not find .* cookies database" "$out/.yt-dlp.log"; then
  echo "提示: 读不到浏览器 Cookies。macOS 需要给终端/Agent 打开「完全磁盘访问权限」：" >&2
  echo "      系统设置 -> 隐私与安全性 -> 完全磁盘访问权限 -> 打开你的终端/Codex" >&2
elif grep -q "Sign in to confirm you" "$out/.yt-dlp.log"; then
  echo "提示: 触发 YouTube 反爬。请在浏览器登录后重试，或先手动导出 cookies 文件再用 --cookies 指定。" >&2
elif [ "$extraction_ok" -eq 1 ]; then
  echo "提示: 视频能正常访问，但所选语言没有字幕。用 --list-subs 看可用语言，或走 ASR 兜底。" >&2
fi
echo "下一步：见 references/troubleshooting.md（换语言 / 开浏览器登录 / ASR 兜底）" >&2
exit 1
