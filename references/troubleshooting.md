# 故障排查

## 1. 读不到浏览器 Cookies

**症状**

```
ERROR: could not find chrome cookies database in "/Users/<你>/Library/Application Support/Google/Chrome"
```

或 cookie 提取直接报权限错误。

**原因**：macOS 的 TCC 机制不允许未授权的进程读取浏览器的 Cookies 数据库。

**解决**：系统设置 → 隐私与安全性 → **完全磁盘访问权限** → 打开运行本技能的终端（Terminal / iTerm / Codex），然后**重启终端**。

**替代方案**：手动导出 cookies 文件，再用 `--cookies` 指定：

```bash
# 用浏览器插件（如 Get cookies.txt LOCALLY）导出 Netscape 格式的 cookies.txt
yt-dlp --cookies /path/to/cookies.txt --write-subs ...

# 本技能的脚本写法
bash scripts/fetch_transcript.sh --url "<URL>" --cookies none --extra "--cookies /path/to/cookies.txt"
```

`--extra` 会把原生 yt-dlp 参数原样透传，所有 yt-dlp 选项都能这样加。

---

## 2. YouTube 提示「Sign in to confirm you're not a bot」

**症状**

```
ERROR: [youtube] xxxxx: Sign in to confirm you’re not a bot. Use --cookies-from-browser ...
```

**解决顺序**

1. 在浏览器里登录 YouTube，然后让脚本用 cookie 策略重试（`--cookies auto` 是默认值）
2. 换播放器客户端试探：

```bash
bash scripts/fetch_transcript.sh --url "<URL>" --extra "--extractor-args youtube:player_client=web_safari"
```

3. 换网络环境（机房 / 云主机 IP 触发风控的概率明显更高，家用宽带通常没问题）
4. 升级 yt-dlp：`yt-dlp -U` 或 `pipx upgrade yt-dlp`。YouTube 的接口经常变，旧版本是最常见的失败原因

---

## 3. Bilibili 报 412 / 风控

**症状**：`HTTP Error 412: Precondition Failed`

**解决**

1. 用浏览器 cookies 重试（B 站字幕接口几乎一定需要登录态）
2. 确认浏览器里已登录 B 站，且不是无痕窗口
3. 降低请求频率：不要短时间内连续跑十条视频
4. 检查是不是多 P 视频——脚本默认只取第一集，需要指定就用具体的 `?p=N` 链接

---

## 4. 完全没有字幕

先确认真的是没有，而不是语言不对：

```bash
bash scripts/fetch_transcript.sh --url "<URL>" --list-subs
```

如果列表为空，走语音转写（ASR）。推荐两条路：

**方案 A：本地 Whisper（隐私好，慢）**

```bash
pipx install openai-whisper          # 或 brew install whisper-cpp
OUT=/tmp/yt-obsidian
mkdir -p "$OUT"
yt-dlp --cookies-from-browser chrome -x --audio-format mp3 \
  -o "$OUT/audio.%(ext)s" "<URL>"
whisper "$OUT/audio.mp3" --model medium --language zh --output_format srt --output_dir "$OUT"
python3 scripts/clean_srt.py --dir "$OUT" --timestamps
```

**方案 B：Apple 芯片加速（快得多）**

```bash
pipx install mlx-whisper
mlx_whisper "$OUT/audio.mp3" --model mlx-community/whisper-large-v3-mlx \
  --language zh --output-dir "$OUT" --output-format srt
```

转写结果的处理方式与字幕完全一致，接着跑 Step 3 即可。**如果是自动转写，交付时要提醒用户可能有识别错误。**

---

## 5. 字幕清洗后内容重复

YouTube 自动字幕是滚动式的（同一句会在相邻条目里重复出现）。`clean_srt.py` 已经做了去重，如果仍有残留：

- 用 `--gap 4` 调大分段阈值，减少跨段重复
- 检查是否同时下载了人工和自动两份字幕——`transcript.txt` 会自动挑更好的一份，但目录里其它 `*.txt` 仍然各自保留了原文

---

## 6. 截图相关

| 症状 | 处理 |
| --- | --- |
| `ffprobe 读不到时长` | 视频没下载完整，加 `--keep-video` 保留临时目录检查 |
| 画面变化点太少（访谈、口播类） | 用 `--mode interval --interval 60` 走固定间隔 |
| 截图张数太多 | 用 `--max 12` 控制，脚本会均匀抽稀 |
| 图片太大 | 用 `--width 960` 降低分辨率 |
| `contact-sheet.png` 没生成 | 通常是只有 1 张截图；单张不需要总览图 |
| 想换个画面变化灵敏度 | `--threshold 0.2`（更灵敏）到 `0.5`（更严格） |

---

## 7. 长视频

- 字幕超过 1500 行：分段读、分段总结，最后合并；**不要只读开头就动笔**
- 超过 1 小时的视频，截图默认走固定间隔模式（画面变化检测要全片解码，太慢）
- 如果一次上下文装不下，就让笔记「分两次交付」——先出上半部分，确认后再出下半部分

---

## 8. 找不到 vault

`resolve_vault.sh` 输出 `STATUS=no-vault` 时：

```bash
mkdir -p ~/.config/youtube-to-obsidian
cat > ~/.config/youtube-to-obsidian/config <<'EOF'
YT_OBSIDIAN_VAULT="/你的/vault/路径"
YT_OBSIDIAN_NOTE_DIR="视频笔记"
YT_OBSIDIAN_ATTACH_SUBDIR="attachments/yt-screenshots"
EOF
```

如果只是这一次不想写配置，直接把目标目录告诉 Agent 也行（Step 0 的「存放目录」参数）。
