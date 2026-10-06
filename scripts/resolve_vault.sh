#!/usr/bin/env bash
# 解析 Obsidian vault / 笔记目录 / 附件目录，输出 KEY=VALUE 供 Agent 读取。
#
# 优先级（高 -> 低）：
#   1. 环境变量 YT_OBSIDIAN_VAULT / YT_OBSIDIAN_NOTE_DIR / YT_OBSIDIAN_ATTACH_SUBDIR
#   2. 配置文件 ~/.config/youtube-to-obsidian/config（KEY=VALUE 形式）
#   3. 自动探测：从当前目录向上找 .obsidian，再试几个常见 vault 位置
set -uo pipefail

config_file="${YT_OBSIDIAN_CONFIG:-$HOME/.config/youtube-to-obsidian/config}"
if [ -f "$config_file" ]; then
  # shellcheck disable=SC1090
  . "$config_file"
fi

vault="${YT_OBSIDIAN_VAULT:-}"
attach_subdir="${YT_OBSIDIAN_ATTACH_SUBDIR:-attachments/yt-screenshots}"
note_dir="${YT_OBSIDIAN_NOTE_DIR:-}"

has_vault() { [ -n "${1:-}" ] && [ -d "$1" ] && [ -d "$1/.obsidian" ]; }

if ! has_vault "$vault"; then
  probe="$PWD"
  while [ "$probe" != "/" ] && [ -n "$probe" ]; do
    if [ -d "$probe/.obsidian" ]; then
      vault="$probe"
      break
    fi
    probe="$(dirname "$probe")"
  done
fi

if ! has_vault "$vault"; then
  for candidate in \
    "$HOME/Obsidian" \
    "$HOME/Documents/Obsidian" \
    "$HOME/Desktop/obsidian" \
    "$HOME/Desktop/obsidian/obsgit"; do
    if has_vault "$candidate"; then
      vault="$candidate"
      break
    fi
  done
fi

if [ -z "$vault" ] || [ ! -d "$vault/.obsidian" ]; then
  echo "VAULT="
  echo "NOTE_DIR="
  echo "ATTACH_SUBDIR=$attach_subdir"
  echo "ATTACH_DIR="
  echo "STATUS=no-vault"
  exit 1
fi

if [ -z "$note_dir" ] || [ ! -d "$vault/$note_dir" ]; then
  note_dir=""
  while IFS= read -r candidate; do
    [ -z "$candidate" ] && continue
    if [ -d "$vault/$candidate" ]; then
      note_dir="$candidate"
      break
    fi
  done <<LIST
3 记忆与记录/4 随笔杂记/2 长视频记录
0 收集想法/inbox 收件箱
0 收集想法/inbox
视频笔记
inbox
LIST
fi

[ -z "$note_dir" ] && note_dir="inbox"

echo "VAULT=$vault"
echo "NOTE_DIR=$vault/$note_dir"
echo "ATTACH_SUBDIR=$attach_subdir"
echo "ATTACH_DIR=$vault/$attach_subdir"
echo "STATUS=ok"
