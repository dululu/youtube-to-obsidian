---
name: youtube-to-obsidian
description: 把 YouTube / Bilibili（以及 yt-dlp 支持的其它站点）视频自动转成 Obsidian 结构化笔记。抓字幕（人工字幕优先、自动字幕兜底、多语言回退）→ 清洗去重 → 按「知识型走费曼策略、观点型走求真策略」深度改写 → 写入 vault；参数里加「截图」还会抽取关键帧并嵌入笔记。触发词：视频转笔记、YouTube 笔记、B站笔记、Bilibili 笔记、字幕转文字、视频截图、播客笔记。
license: MIT
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
---

# YouTube / Bilibili → Obsidian 结构化笔记

把一条视频链接变成一篇**人愿意读**的 Obsidian 笔记。

- **输入**：视频 URL ＋ 可选参数（语言、存放目录、是否截图）
- **输出**：`<vault>/<笔记目录>/<频道 - 标题>.md`，截图模式下额外产出附件图片
- **边界**：只处理「有字幕或能转写」的视频；不搬运、不发布视频本身；除用户要求外不改动已有笔记

执行原则：**只在出错和最后交付时汇报**，中间步骤不要逐步播报。

---

## Step 0 — 解析参数

用户这次给的参数（Claude Code 里就是 `$ARGUMENTS`，其它宿主是用户原话）：

**$ARGUMENTS**

参数缺失时按下面的默认值直接干活，**不要为默认值反问用户**：

| 参数 | 识别方式 | 默认 |
| --- | --- | --- |
| URL | 消息里的第一个链接 | 必需 |
| 平台 | 由域名判断 | 自动 |
| 语言 | 「英文 / 中文 / 双语」等描述，或 `en` / `zh-Hans` | 见下表 |
| 截图模式 | 出现 `截图` / `screenshot` / `--screenshots` | 关闭 |
| 存放目录 | 用户给了路径就用 | 自动解析（见 Step 6） |

| 域名 | 平台 | 字幕语言优先级 |
| --- | --- | --- |
| `youtube.com` `youtu.be` `youtube-nocookie.com` | YouTube | `en → en-orig → zh-Hans → zh-Hant → zh` |
| `bilibili.com` `b23.tv` `bili2233.cn` | Bilibili | `zh-Hans → zh-CN → zh → zh-Hant → ai-zh → en` |
| 其它（播客、公开课等 yt-dlp 支持的站点） | 通用 | `en → zh-Hans` |

短链（`b23.tv`）直接交给 yt-dlp 跟随，不要手动展开。

**只有这三种情况才追问用户**：① 没有 URL；② 多 P / 播放列表视频没说是哪一集；③ 完全没有字幕、需要决定是否走语音转写。其余一律用默认值直接做。

## Step 1 — 依赖自检

```bash
SKILL_DIR="<包含本 SKILL.md 的目录绝对路径>"
bash "$SKILL_DIR/scripts/check_deps.sh" --screenshots
```

- 缺 `yt-dlp`：`brew install yt-dlp`（或 `pipx install yt-dlp`）
- 缺 `ffmpeg`：`brew install ffmpeg`。**装不上就降级**——跳过截图，只出文字笔记，并告知用户
- `SKILL_DIR` 就是本文件所在目录；如果 `scripts/` 不存在（只复制了 SKILL.md），见文末「附：脚本获取」

## Step 2 — 抓字幕

```bash
OUT=/tmp/yt-obsidian
bash "$SKILL_DIR/scripts/fetch_transcript.sh" --url "<URL>" --out "$OUT" --lang "<语言列表>"
```

脚本已经替你处理完这些事，不要自己重写一遍：

- 平台识别与语言回退：一次请求多个语言，挑可用的最好的那份
- Cookie 策略：`chrome → safari → firefox → 无 cookie`，逐个重试（两个平台一致）
- 人工字幕优先，没有人工字幕就用自动字幕
- 默认只取单集（`--no-playlist`），不会误下整个播放列表
- 产出：`subtitle.*.(srt|vtt)`、`video-meta.tsv`（标题/UP主/日期/时长/ID/URL）、`fetch-report.txt`

补充手段：

- 想知道视频到底有哪些语言字幕：加 `--list-subs`
- 遇到反爬或播放器拒绝：用 `--extra "--extractor-args youtube:player_client=web_safari"` 之类的原生 yt-dlp 参数逃生
- 报错提示读不到浏览器 Cookies：那是 macOS 权限问题，见 `references/troubleshooting.md`

**拿不到任何字幕时**：走 `references/troubleshooting.md` 的语音转写（ASR）兜底，或者明确告诉用户这条视频处理不了。**绝对不要凭标题猜内容、编造视频里没说的话。**

## Step 3 — 清洗字幕

```bash
python3 "$SKILL_DIR/scripts/clean_srt.py" --dir "$OUT" --timestamps
```

产出：

- `transcript.txt`——最佳一份的连续文本（人工字幕优先，其次字符数最多）
- `transcript.timed.txt`——带 `[HH:MM:SS]` 段落标记，写笔记时用来定位、截图时用来对时间
- 每份原始字幕各自的 `*.txt`

清洗逻辑（脚本已实现，除非它失败否则不要手工重做）：去掉时间轴/序号/HTML 与 ASS 标签、合并 YouTube 自动字幕的滚动重复行、中文不加空格拼接、停顿超过 2.5 秒断段、超长段落强制切断。

## Step 4 — 读并理解

1. 读 `transcript.txt`；超过 1500 行就分段读，每段 ≤1500 行
2. 读 `video-meta.tsv` 拿标题 / 频道 / 上传日期 / 时长
3. 截图模式必读 `transcript.timed.txt`，边读边记下值得截图的画面时间点
4. 读完之后先在脑子里梳理**内容结构与逻辑脉络**，再动笔

## Step 5 — 判断类型，选写作策略（核心步骤）

> 目标是产出一篇**读者愿意读完、读完有收获**的笔记，不是字幕摘要。

先分类，两类策略**不要混用**：

| 信号 | 类型 | 策略 |
| --- | --- | --- |
| 课程、教程、科普、学术讲座、技能教学；有定义、步骤、公式、结论 | 📖 知识 / 理论型 | **费曼策略** |
| 访谈、对谈、演讲、评论、个人叙事；有第一人称、语气、故事、立场 | 💬 观点 / 表达型 | **求真策略** |
| 两者兼具（例：访谈里讲方法论） | 按**主要目的**判 | 主体用一种，局部借用另一种 |

### 费曼策略（知识 / 理论型）——目标是让读者「学会」

1. **简化概念，不简化意思**：用直觉、类比、具体例子解释抽象概念；把术语翻成人话，但不丢精度
2. **可以重组逻辑**：视频的时间线不利于学习时，按知识点的依赖关系重排，用 `## 一、` `## 二、` 层级标题导航
3. **不添油加醋**：简化不等于编造，不制造主讲人没说的「金句」，不写假装深刻的废话

### 求真策略（观点 / 表达型）——目标是让读者「听见」

1. **保留口语表达方式**：保留主讲人的语言风格、节奏和语气；不要为了「通顺」把口语强行改成书面语
2. **跟随内容自然流动**：按视频原有的内容块和论证节奏组织文字；长句、复合句如果本来就是主讲人的说话方式，就保持原样，不要拆碎原文逻辑
3. **标题克制**：只在内容真的发生自然转换时才加标题；不要频繁用一二级标题把文章切碎，不要制造视频里本来不存在的分层结构
4. **写给人看**：读者是一个活生生的人，不是搜索引擎、不是 AI。要有节奏、有呼吸感、有主讲人真实的声音

### 两种策略都适用的规则

- **具体案例优先**：抽象概念要配具体例子，让读者「看见」而不只是「知道」
- **表格适度**：对比、参数确有必要时才用表格，能自然语言说清就不用
- **链接策略**：vault 里已有相关笔记就用 `[[wikilink]]` 链接；**不要凭空捏造不存在的笔记链接**；同一个概念只在第一次出现时链接
- **不写套话**：删掉「在当今飞速发展」「众所周知」「总而言之」这类空转的句子

## Step 6 — 写笔记并落盘

先解析出 vault、笔记目录、附件目录：

```bash
bash "$SKILL_DIR/scripts/resolve_vault.sh"
```

输出 `VAULT=` / `NOTE_DIR=` / `ATTACH_DIR=` / `STATUS=`，可直接读取使用。

解析优先级：`--dir` 或用户指定 → 环境变量 `YT_OBSIDIAN_VAULT` 等 → 配置文件 `~/.config/youtube-to-obsidian/config` → 自动探测（从当前目录向上找 `.obsidian`，再试常见位置）。配置文件示例见仓库里的 `config.example`。

**文件名**：`{频道/UP主} - {视频标题}.md`

- 去掉 `/ : ? * " < > |` 等特殊字符，中文保持原样
- 超过 80 字符时在标点或词边界截断，不要硬切

**Frontmatter**（模板见 `references/note-template.md`）：

```yaml
---
tags: [主题标签1, 主题标签2, 视频笔记]
created: {今天日期 YYYY-MM-DD}
source: "{视频URL}"
author: "{频道名 / UP主}"
aliases: [{视频简称}]
---
```

`tags` 和 `created` 为必需字段，`source` / `author` / `aliases` 尽量补全。标签从内容里提炼 3-7 个，最后固定加上 `视频笔记`。

**已经存在同名笔记时**：先读旧笔记，问用户是覆盖、合并还是另存（另存加 ` - 2`）。不要静默覆盖。

**Obsidian 语法**：嵌入图片用 `![[...]]`，内部链接用 `[[...]]`，不要用 Markdown 的 `![]()`。写之前如果宿主里装了 `obsidian-markdown` 技能，可以直接参考它。

## Step 7 — 截图模式（仅当参数里出现「截图」）

```bash
SCRIPT_DIR="$SKILL_DIR/scripts"
bash "$SCRIPT_DIR/make_screenshots.sh" --url "<URL>" --out /tmp/yt-obsidian/shots \
  --max 16 --contact-sheet
# 已经有本地视频文件时用： --video /path/to/video.mp4
```

脚本产出：

- `shot_001_00-12-30.png`——文件名里的时间戳来自真实帧时间，不是猜的
- `timestamps.tsv`——`file / timestamp / seconds` 三列，写图注时直接引用
- `contact-sheet.png`——总览图，**先用它一次性浏览所有画面**，再决定挑哪几张

模式选择：`--mode auto`（默认，≤30 分钟用画面变化检测，更长用固定间隔）、`scene`、`interval`。张数用 `--max` 控制（默认 16）。

**挑图与嵌入原则**：

- 优先：架构图、对比表、关键公式、代码示例、数据可视化、关键帧
- 跳过：纯人物讲话、过渡画面、没有信息量的画面
- 一般嵌 3-5 张，最多不超过 8 张；**嵌入在相关段落之后**，不要堆在文末
- 每张配一行时间戳说明即可，不必展开描述

把选中的图复制到 vault：

```bash
SLUG="<笔记文件名去掉扩展名，空格换短横线>"
mkdir -p "$ATTACH_DIR/$SLUG"
cp /tmp/yt-obsidian/shots/shot_005_00-12-30.png "$ATTACH_DIR/$SLUG/"
```

笔记里这样引用（用 vault 内相对路径，避免不同视频的截图重名冲突）：

```markdown
![[attachments/yt-screenshots/维特根斯坦-语言游戏/shot_005_00-12-30.png]]
*12:30 - 家族相似性的网络结构*
```

## Step 8 — 清理与交付

```bash
rm -rf /tmp/yt-obsidian
```

最后**用一段话交付**，包含：

- 笔记路径（wikilink 形式，如 `[[频道 - 标题]]`）
- 用的一句话说明这篇笔记按哪种策略写的
- 截图数量（仅截图模式）
- 需要用户注意的地方（如：字幕是自动生成的，可能有识别错误）

---

## 交付前自检

写完笔记、交付之前，逐条过一遍：

```
[ ] Frontmatter 有 tags 和 created，source 链接正确
[ ] 每个二级标题下面的内容，都能在字幕里找到出处，没有编造
[ ] 观点型视频：口语风格、语气、论证结构保留了；没有被改写成「正确的废话」
[ ] 知识型视频：抽象概念都有类比或例子；顺序是按理解逻辑排的，不是按时间线硬切
[ ] 没有「在当今飞速发展」「众所周知」这类套话
[ ] 表格只在真有必要的地方出现
[ ] [[wikilink]] 指向的笔记真实存在（不确定就删掉链接，保留纯文本）
[ ] 截图（如有）嵌在相关段落后，每张有一行时间戳说明
[ ] 笔记结尾有对全文的收束（小结 / 一句话核心），不是突然断掉
```

---

## 错误处理总则

| 场景 | 处理 |
| --- | --- |
| 读不到浏览器 Cookies | macOS 需给终端/Agent 打开「完全磁盘访问权限」；或手动导出 cookies 文件 |
| YouTube 提示 confirm you're not a bot | 先在浏览器登录 YouTube，再用 cookie 策略重试；或 `--extra "--extractor-args youtube:player_client=web_safari"` |
| Bilibili 报 412 / 风控 | 用 cookie 重试；仍失败则降低请求频率，隔一会儿再试 |
| 指定语言没有字幕 | 回退到该平台其它默认语言，并告知用户实际使用的语言 |
| 完全没有字幕 | 走 ASR 兜底（见 troubleshooting），或明确告知无法处理 |
| 多 P / 播放列表视频 | 问用户要哪一集，或加 `--playlist`（不推荐，除非用户明确要全部） |
| 字幕太长超出上下文 | 分段读、分段总结，最后合并；不要只读开头就动笔 |
| 截图模式缺 ffmpeg | `brew install ffmpeg`；装不上就跳过截图，只出文字笔记 |
| ffmpeg 抽不到帧 / 画面变化点太少 | 脚本会自动回退到固定间隔模式；仍失败就跳过截图 |
| Python 脚本报错 | 换用 `/usr/bin/python3` 或 `python3.13` 重试 |

---

## 附：脚本获取

如果 `$SKILL_DIR/scripts/` 不存在（宿主只同步了 SKILL.md），先把脚本取到本地再用：

```bash
SKILL_DIR=/tmp/yt-obsidian-skill
mkdir -p "$SKILL_DIR/scripts"
for f in check_deps.sh fetch_transcript.sh clean_srt.py make_screenshots.sh resolve_vault.sh; do
  curl -fsSL "https://raw.githubusercontent.com/dululu/youtube-to-obsidian/main/scripts/$f" -o "$SKILL_DIR/scripts/$f"
done
chmod +x "$SKILL_DIR"/scripts/*
```

仓库里还有 `references/note-template.md`（笔记模板）和 `references/troubleshooting.md`（故障排查），需要时一并取用。
