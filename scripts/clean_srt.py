#!/usr/bin/env python3
"""把 SRT / VTT 字幕清洗成便于阅读、也便于喂给 AI 的连续文本。

处理内容：
  * 去掉时间轴、序号、HTML/ASS 标签
  * 合并 YouTube 自动字幕的滚动重复行（hello -> hello world -> world）
  * 中文不加空格拼接，英文用单空格拼接
  * 字幕停顿 > --gap 秒时另起一段
  * 可选出带 [HH:MM:SS] 时间标记的版本，方便定位截图和引用

用法:
  python3 clean_srt.py --dir /tmp/yt-obsidian --timestamps
  python3 clean_srt.py a.srt b.vtt

输出（写在与输入同一目录）:
  <stem>.txt            每个输入一份纯文本
  transcript.txt        最佳一份的副本（人工字幕优先，其次字符数最多）
  transcript.timed.txt  带段落时间标记（加 --timestamps 时生成）
"""

from __future__ import annotations

import argparse
import glob
import html
import os
import re
import shutil
import sys

TIMING_RE = re.compile(
    r"^\s*"
    r"(\d{1,3}:\d{2}:\d{2}[.,]\d{1,3}|\d{1,3}:\d{2}[.,]\d{1,3})"
    r"\s*-->\s*"
    r"(\d{1,3}:\d{2}:\d{2}[.,]\d{1,3}|\d{1,3}:\d{2}[.,]\d{1,3})"
)
TAG_RE = re.compile(r"<[^>]*>")
ASS_TAG_RE = re.compile(r"\{\\[^}]*\}")
CJK_RE = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]")
SENT_END = "。！？!?…"
# yt-dlp / yt 自动字幕常见的语言后缀，用来判断「同一个视频」的多份字幕
LANG_SUFFIX_RE = re.compile(r"^(?P<base>.+?)\.(?P<lang>ai-[a-z]{2,3}|[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,6})*)$")


def to_seconds(ts: str) -> float:
    ts = ts.replace(",", ".")
    parts = ts.split(":")
    parts = [float(p) for p in parts]
    while len(parts) < 3:
        parts.insert(0, 0.0)
    return parts[0] * 3600 + parts[1] * 60 + parts[2]


def hhmmss(seconds: float) -> str:
    total = int(seconds)
    return f"{total // 3600:02d}:{(total % 3600) // 60:02d}:{total % 60:02d}"


def read_text(path: str) -> str:
    for enc in ("utf-8-sig", "utf-8", "latin-1"):
        try:
            with open(path, "r", encoding=enc) as fh:
                return fh.read()
        except UnicodeDecodeError:
            continue
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read()


def parse_cues(raw: str) -> list[tuple[float, float, list[str]]]:
    """解析 SRT / VTT 为 (start, end, [text lines])。非字幕行（WEBVTT 头、NOTE、序号）自然被跳过。"""
    raw = raw.replace("\r\n", "\n").replace("\r", "\n")
    if raw.startswith("\ufeff"):
        raw = raw[1:]
    lines = raw.split("\n")
    cues: list[tuple[float, float, list[str]]] = []
    i = 0
    while i < len(lines):
        match = TIMING_RE.match(lines[i])
        if not match:
            i += 1
            continue
        start, end = to_seconds(match.group(1)), to_seconds(match.group(2))
        i += 1
        body: list[str] = []
        while i < len(lines) and lines[i].strip() and not TIMING_RE.match(lines[i]):
            body.append(lines[i])
            i += 1
        cues.append((start, end, body))
    return cues


def clean_line(line: str) -> str:
    line = TAG_RE.sub("", line)
    line = ASS_TAG_RE.sub("", line)
    line = line.replace("&nbsp;", " ").replace("&lrm;", "").replace("&rlm;", "")
    line = html.unescape(line)
    line = re.sub(r"^(?:align:\S+\s*|position:\S+\s*|line:\S+\s*)+", "", line)
    line = re.sub(r"\s+", " ", line)
    return line.strip()


def dedupe(cues: list[tuple[float, float, list[str]]]) -> list[tuple[float, float, str]]:
    """展开字幕并消掉滚动重复。返回 (start, end, text) 序列。"""
    out: list[tuple[float, float, str]] = []
    recent: list[str] = []
    last = ""

    def remember(key: str) -> None:
        recent.append(key)
        del recent[:-8]

    for start, end, body in cues:
        for raw_line in body:
            line = clean_line(raw_line)
            if not line:
                continue
            if line == last:
                continue
            if last and line.startswith(last):
                added = line[len(last):].strip()
                if added:
                    out.append((start, end, added))
                last = line
                remember(line)
                continue
            if last and len(line) >= 4 and last.endswith(line):
                # 上一句尾巴的重复
                remember(line)
                continue
            if line in recent:
                continue
            out.append((start, end, line))
            last = line
            remember(line)
    return out


def build_paragraphs(items, gap: float, cjk: bool, max_para: int = 400):
    """按停顿切段，段内按句子断行。返回 [(start_seconds, paragraph_text)]。"""
    sep = "" if cjk else " "
    paragraphs = []
    buffer: list[str] = []
    buffer_len = 0
    para_start = 0.0
    prev_end = None

    def flush() -> None:
        nonlocal buffer, buffer_len
        if not buffer:
            return
        text = sep.join(buffer).strip()
        # 段内按句末标点断行，手机/编辑器里更好读
        text = re.sub(r"(?<=[" + re.escape(SENT_END) + r"])\s*(?=\S)", "\n", text)
        paragraphs.append((para_start, text))
        buffer = []
        buffer_len = 0

    for start, end, text in items:
        if prev_end is not None and start - prev_end > gap:
            flush()
            para_start = start
        elif not buffer:
            para_start = start
        if buffer and buffer_len + len(text) > max_para:
            # 没有标点、没有停顿的长段落（歌词、念稿）也要切断
            flush()
            para_start = start
        buffer.append(text)
        buffer_len += len(text)
        prev_end = end
    flush()
    return paragraphs


def is_cjk_text(text: str) -> bool:
    if not text:
        return False
    return len(CJK_RE.findall(text)) / len(text) > 0.10


def sort_key(path: str, chars: int):
    name = os.path.basename(path).lower()
    low_quality = 1 if ("ai-" in name or "-orig" in name or ".auto" in name) else 0
    fmt_bonus = 0 if name.endswith(".srt") else 1
    return (low_quality, fmt_bonus, -chars)


def main() -> int:
    parser = argparse.ArgumentParser(description="SRT/VTT -> 连续文本")
    parser.add_argument("files", nargs="*", help="字幕文件；不传则配合 --dir 使用")
    parser.add_argument("--dir", default=None, help="扫描该目录下的 *.srt / *.vtt")
    parser.add_argument("--timestamps", action="store_true", help="额外生成带 [HH:MM:SS] 的版本")
    parser.add_argument("--gap", type=float, default=2.5, help="超过该秒数停顿就分段（默认 2.5）")
    parser.add_argument("--max-para", type=int, default=400, help="单段最长字符数，超出即断段（默认 400）")
    args = parser.parse_args()

    files = [f for f in args.files if os.path.isfile(f)]
    if args.dir:
        files += sorted(glob.glob(os.path.join(args.dir, "*.srt")))
        files += sorted(glob.glob(os.path.join(args.dir, "*.vtt")))
    seen: set[str] = set()
    files = [f for f in files if not (f in seen or seen.add(f))]

    if not files:
        print("ERROR: 没有找到字幕文件。", file=sys.stderr)
        return 1

    produced: list[tuple[str, int]] = []
    groups: dict[str, list[tuple[str, int]]] = {}

    for path in files:
        cues = parse_cues(read_text(path))
        if not cues:
            print(f"skip    {os.path.basename(path)}: 解析不出字幕条目")
            continue
        items = dedupe(cues)
        joined = "".join(t for _, _, t in items)
        cjk = is_cjk_text(joined)
        paragraphs = build_paragraphs(items, args.gap, cjk, args.max_para)

        body = "\n\n".join(text for _, text in paragraphs).strip() + "\n"
        stem = os.path.splitext(path)[0]
        txt_path = f"{stem}.txt"
        with open(txt_path, "w", encoding="utf-8") as fh:
            fh.write(body)

        if args.timestamps:
            timed = "\n\n".join(f"[{hhmmss(start)}] {text}" for start, text in paragraphs)
            with open(f"{stem}.timed.txt", "w", encoding="utf-8") as fh:
                fh.write(timed.strip() + "\n")

        produced.append((txt_path, len(body)))
        base_match = LANG_SUFFIX_RE.match(os.path.splitext(os.path.basename(path))[0])
        group = os.path.join(os.path.dirname(path), base_match.group("base") if base_match else os.path.basename(stem))
        groups.setdefault(group, []).append((txt_path, len(body)))
        print(f"cleaned {os.path.basename(path)} -> {os.path.basename(txt_path)} "
              f"({len(cues)} 条字幕 / {len(body)} 字符 / {'中文' if cjk else '西文'}拼接)")

    if not produced:
        print("ERROR: 所有输入都解析失败。", file=sys.stderr)
        return 1

    best_group = max(groups.values(), key=lambda g: max(c for _, c in g))
    best_path, best_chars = sorted(best_group, key=lambda item: sort_key(item[0], item[1]))[0]
    out_dir = os.path.dirname(files[0]) if args.dir is None else args.dir
    target = os.path.join(out_dir, "transcript.txt")
    shutil.copyfile(best_path, target)
    if args.timestamps:
        timed_src = best_path[:-4] + ".timed.txt"
        if os.path.isfile(timed_src):
            shutil.copyfile(timed_src, os.path.join(out_dir, "transcript.timed.txt"))

    others = [f"{os.path.basename(p)} ({c})" for p, c in produced if p != best_path]
    print(f"\nbest -> {target}  <- {os.path.basename(best_path)} ({best_chars} 字符)")
    if others:
        print("其它候选: " + ", ".join(others))
    print("done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
