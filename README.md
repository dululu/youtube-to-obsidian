# YouTube to Obsidian · youtube-to-obsidian

把一条 **YouTube / Bilibili** 视频链接，变成一篇**人愿意读**的 Obsidian 笔记。

一句话讲清它和「字幕导出工具」的区别：**它不在搬运字幕，而是在按内容类型重写一遍。**
知识型视频用费曼策略（打散时间线、按理解逻辑重组、抽象概念配类比），
观点型视频用求真策略（保留主讲人的口语、语气和论证节奏，不把他说的话「翻译」成书面语）。

加上「截图」两个字，还会用 ffmpeg 抽出带真实时间戳的关键帧，嵌进笔记对应段落里。

---

## 它解决什么问题

**问题一：视频里的信息，看完就散了。**
收藏夹里堆着几十个「以后再看」的教程和访谈，一年后一个都没打开。字幕能导出来，但导出的是几千行时间轴，
既不是知识，也不能回顾——你需要的是**有人替你消化过一遍的结构化笔记**。

**问题二：摘要工具把有味道的东西磨平了。**
访谈、演讲、对谈这类内容，价值一半在观点，一半在**说话的人和说话的方式**。
一律「总结成 5 个要点」会把主讲人的语气、犹豫、修辞全部抹掉，剩下的是一段谁都能写的正确废话。

**问题三：视频里的图，文字笔记留不住。**
架构图、对比表、公式推导、可视化结果——这些恰恰是文字描述最费劲的部分。抽成截图存进 vault 才不丢。

**问题四：有些视频拿不到字幕，或者你压根不想登录。**
内部录像、屏幕录制、下载下来的本地文件、B 站风控时的 412——这些情况下
`transcribe_audio.sh` 会直接抽音轨转写，**不需要任何站点登录**。

---

## 效果

```bash
> 帮我把这个视频转成笔记 https://www.bilibili.com/video/BV1iKAZzLEVN 截图
```

产出一篇 `频道 - 标题.md`，包含：

- 正确的 frontmatter（`tags` / `created` / `source` / `author` / `aliases`）
- 按内容结构组织的正文，不是字幕流水账
- 关键画面截图，嵌在对应段落之后，每张带一行时间戳说明
- vault 内已有的概念用 `[[wikilink]]` 自动串起来

```
瀑布式流程：
  视频 URL
     │
     ▼  yt-dlp（人工字幕优先 → 自动字幕 → 多语言回退 → cookie 回退）
  字幕 SRT / VTT
     │
     ▼  clean_srt.py（去时间轴、合并滚动重复行、中文不加空格、按停顿分段）
  连续文本 + 带时间戳文本
     │
     ├──▶  Agent 判断类型 → 费曼策略 / 求真策略 → 重写
     │
     └──▶  ffmpeg 关键帧（画面变化检测 / 固定间隔）→ 截图 + timestamps.tsv
     │
     ▼
  Obsidian 笔记（+ 附件目录）
```

---

## 安装

### 作为 Agent Skill 安装

本仓库遵循通用 Agent Skills 约定：入口是根目录的 `SKILL.md`，脚本在 `scripts/`，参考文档在 `references/`。

```bash
# 把 <skills-dir> 换成你的宿主的技能目录
git clone https://github.com/dululu/youtube-to-obsidian.git \
  <skills-dir>/youtube-to-obsidian
```

常见技能目录：

| 宿主 | 目录 |
| --- | --- |
| WorkBuddy | `~/.workbuddy/skills/` |
| Claude Code | `~/.claude/skills/` |
| Codex | `~/.codex/skills/` |
| 其它支持 Agent Skills 的宿主 | 放进它约定的 skills 目录即可 |

### 依赖

| 依赖 | 用途 | 安装 | 是否必需 |
| --- | --- | --- | --- |
| `yt-dlp` | 抓字幕和元数据 | `brew install yt-dlp` 或 `pipx install yt-dlp` | 必需 |
| `python3` | 字幕清洗 | 系统自带 / `brew install python3` | 必需 |
| `ffmpeg` + `ffprobe` | 截图模式抽帧 | `brew install ffmpeg` | 仅截图模式 |
| `whisper` 家族 | 无字幕时语音转写 | `pipx install openai-whisper`，Apple Silicon 建议 `pipx install mlx-whisper`（快很多） | 仅 ASR 兜底 |

自检一条命令：

```bash
bash scripts/check_deps.sh --screenshots
```

---

## 用法

在装了本技能的 Agent 里直接说话就行：

```
把 https://youtu.be/xxx 转成笔记
这个 B 站视频帮我整理成 Obsidian 笔记，要截图
https://www.youtube.com/watch?v=xxx  英文的，笔记放到「视频笔记」目录
```

也可以直接调脚本：

```bash
# 1. 抓字幕（人工字幕优先，自动字幕兜底）
bash scripts/fetch_transcript.sh --url "<URL>" --out /tmp/yt-obsidian

# 2. 清洗成连续文本（--timestamps 额外产出带时间标记的版本）
python3 scripts/clean_srt.py --dir /tmp/yt-obsidian --timestamps

# 3. 抽关键帧截图
bash scripts/make_screenshots.sh --url "<URL>" --out /tmp/yt-obsidian/shots \
  --max 16 --contact-sheet

# 3'. 无字幕时：本地文件直接转写（不用登录任何站点）
bash scripts/transcribe_audio.sh --video /path/to/video.mp4 --out /tmp/yt-obsidian
python3 scripts/clean_srt.py --dir /tmp/yt-obsidian --timestamps   # 之后流程完全一样

# 4. 看看解析出来的 vault 路径对不对
bash scripts/resolve_vault.sh
```

### 常用参数

| 脚本 | 参数 | 说明 |
| --- | --- | --- |
| `fetch_transcript.sh` | `--lang "en,zh-Hans"` | 指定语言优先级 |
| | `--cookies chrome\|safari\|firefox\|none` | 指定取 cookie 的浏览器（默认自动逐个试） |
| | `--list-subs` | 只列出视频有哪些语言字幕，用来诊断 |
| | `--extra "<yt-dlp 参数>"` | 透传任意原生 yt-dlp 参数，反爬时当逃生舱 |
| | `--playlist` | 允许多 P / 播放列表（默认只取单集） |
| `clean_srt.py` | `--timestamps` | 额外生成 `transcript.timed.txt` |
| | `--gap 2.5` | 停顿多少秒算分段 |
| | `--max-para 400` | 单段最长字符数（歌词、念稿类内容用得上） |
| `make_screenshots.sh` | `--mode auto\|scene\|interval` | 抽帧策略，默认 ≤30 分钟用画面变化检测 |
| | `--max 16` | 截图张数上限，超出自动均匀抽稀 |
| | `--width 1280` | 截图宽度 |
| | `--video <文件>` | 已经有本地视频时直接用，跳过下载 |
| `transcribe_audio.sh` | `--video <文件>` | 从本地视频抽音轨转写（**不需要登录**） |
| | `--audio <文件>` | 从本地音频转写 |
| | `--url <链接>` | 下载音轨后转写 |
| | `--model base\|small\|medium` | 模型越大越准越慢；Apple Silicon 默认 `small` |
| | `--language zh` | 已知语言就写死，比自动检测准 |
| | `--contact-sheet` | 额外拼一张总览图，方便一次性挑图 |
| | `--video <文件>` | 已经有本地视频时直接用，跳过下载 |

---

## 截图模式

截图文件名自带真实时间戳，比如 `shot_005_00-12-30.png` 就是 12 分 30 秒那一帧——
时间来自 ffmpeg 输出的真实帧 pts，不是按间隔推算的，所以不会和时间轴错位。

同目录还会生成 `timestamps.tsv`：

```
file                      timestamp   seconds
shot_005_00-12-30.png     00:12:30    750.4
```

以及一张 `contact-sheet.png` 总览图（需要加 `--contact-sheet`），让模型一次性把所有画面看完再挑，
省掉逐张读图的开销。

---

## 配置

vault 路径的解析优先级：**用户当场指定 > 环境变量 > 配置文件 > 自动探测**。

自动探测会从当前目录向上找 `.obsidian` 目录；找不到再试 `~/Obsidian`、`~/Documents/Obsidian`、`~/Desktop/obsidian` 等常见位置。

想固定下来就写配置文件：

```bash
mkdir -p ~/.config/youtube-to-obsidian
cp config.example ~/.config/youtube-to-obsidian/config
# 然后编辑里面的路径
```

| 变量 | 含义 | 默认 |
| --- | --- | --- |
| `YT_OBSIDIAN_VAULT` | vault 根目录 | 自动探测 |
| `YT_OBSIDIAN_NOTE_DIR` | 笔记存放目录（相对 vault） | 自动挑一个存在的：`视频笔记` / `0 收集想法/inbox` / `inbox` 等 |
| `YT_OBSIDIAN_ATTACH_SUBDIR` | 截图附件目录（相对 vault） | `attachments/yt-screenshots` |

---

## 常见问题

跑不通的时候先看 [`references/troubleshooting.md`](references/troubleshooting.md)，覆盖了这些高频坑：

- macOS 读不到浏览器 Cookies（需要「完全磁盘访问权限」）
- YouTube 提示 `Sign in to confirm you're not a bot`
- Bilibili 报 `412 Precondition Failed`
- 视频完全没有字幕时怎么用 Whisper / mlx-whisper 兜底
- 字幕清洗后仍有重复内容
- 访谈类视频画面变化太少、抽不出截图

---

## 目录结构

```
youtube-to-obsidian/
├── SKILL.md                       # 技能入口，Agent 读这个
├── README.md
├── LICENSE
├── config.example                 # vault 路径配置示例
├── skill.yaml                     # 技能清单
├── market.json / marketplace/     # 市场元数据
├── scripts/
│   ├── check_deps.sh              # 依赖自检
│   ├── fetch_transcript.sh        # 抓字幕 + 元数据（cookie / 语言回退）
│   ├── transcribe_audio.sh        # 语音转写兜底（本地文件 / 链接均可）
│   ├── clean_srt.py               # SRT / VTT 清洗与去重
│   ├── make_screenshots.sh        # 关键帧抽取
│   └── resolve_vault.sh           # vault 路径解析
├── references/
│   ├── note-template.md           # 笔记模板与结构
│   └── troubleshooting.md         # 故障排查
└── examples/
    └── sample-note.md             # 一个成品笔记长什么样
```

---

## 贡献

欢迎提 issue / PR，尤其欢迎这几类：

- 新的站点适配（只要 yt-dlp 支持，通常只差一个语言映射）
- 字幕清洗的边界情况（不同平台的滚动字幕格式差异很大）
- 抽帧策略的改进（当前用 ffmpeg 的画面变化检测，对访谈类内容偏保守）

## License

[MIT](LICENSE)
