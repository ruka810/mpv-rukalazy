# Whisper 实时字幕「实时翻译」功能方案

## 一、摘要

在不改动现有 Whisper 实时字幕逻辑的前提下，新增 **W 键 = 开启/关闭中文实时翻译**：

- Whisper 识别出原文后立即照常显示原文字幕（Q 逻辑、模型、参数完全不动）。
- W 开启时，将识别出的原文**异步**翻译成简体中文，缓存相同原文，并与对应原文字幕一对一绑定。
- W 开启时默认显示**双语字幕**（原文本行 + 中文翻译行）；W 关闭恢复仅原文。
- 仅改两个文件，均为增量修改；不新建文件、不重构、不停止 Whisper。

## 二、现状分析（A 部分回答）

完整工作流程如下：

1. **按键绑定**：[input_uosc.conf](file:///e:/mpv-lazy/portable_config/input_uosc.conf#L21) 第 21 行
   `q script-binding whisper_realtime/toggle`，由 [mpv.conf](file:///e:/mpv-lazy/portable_config/mpv.conf#L6) 的 `input-conf = "~~/input_uosc.conf"` 加载。
2. **Lua 脚本** [whisper_realtime.lua](file:///e:/mpv-lazy/portable_config/scripts/whisper_realtime.lua)：
   - `enable()`：校验 E:\whisper 的文件是否齐全 → 保存原 secondary 字幕状态 → `start_bridge()` 启动 Python 内存桥、`start_server()` 启动 whisper-server（参数 `-m ggml-large-v3-turbo-q5_0.bin --host 127.0.0.1 --port <随机> -l auto`）。
   - `disable()`：停止 Whisper、桥接、清理注入的字幕轨、恢复 secondary 字幕状态。
   - `tick()` 每 0.25s 轮询：桥和服务器 ready 后，`capture_chunk()` → `send_audio()` 通过 curl（**异步** `mp.command_native_async`）POST 到桥的 `/transcribe`。
   - Python 桥 [whisper_memory_bridge.py](file:///e:/mpv-lazy/portable_config/tools/whisper_memory_bridge.py) 用 ffmpeg 抓 PCM → 发给 whisper-server → 返回 JSON（含 `segments`，每段有 `text/start/end`）。
3. **结果落字幕**：Lua 对每段 `add_segment()` 写入 `state.events`（做去重/合并），`refresh_track()` 把 events 组 SR**T → 上传到桥 `/subtitle` 拿到 URL → `sub-add` 注入为 secondary 轨并 `secondary-sid` 指向它。

**字幕对应关系的关键数据结构**：`state.events` 每个事件带 `text` 与 `normalized`（`normalized == text` 的单行文本），字幕显示时逐事件取 `event.text`。

## 三、翻译方案设计（B–G 部分回答）

### B. 加在哪 / C. 是否新建文件
翻译显示层、缓存、队列全部内聚到 **`whisper_realtime.lua`**（字幕如何渲染、`state.events`、`refresh_track` 都在这里，最容易保证对应关系）。**不需要新建文件、不动 Python 桥**。

可用性依据：现有字幕注入和转写请求已经大量使用 `mp.command_native_async` + curl，翻译沿用同一套异步子进程模式，可靠且与现有流程一致。

### D. Google Translate 请求实现
用 curl 的 `-G --data-urlencode` 安全做 URL 编码，请求 `translate_a/single` 网页端接口：

```
curl --silent --show-error --fail --connect-timeout 5 --max-time 15 \
  -G --data-urlencode "q=<原文>" \
  "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=zh-CN&dt=t"
```

- **代理**：复用 mpv 已配置的代理（`configured_proxy()` 现成返回 `http://127.0.0.1:10809`），有则给 curl 加 `--proxy <代理>`，无则直连。你已确认走 Clash，mpv 已配置，无需改 mpv。
- **响应解析**：返回 `[[ ["译文","原文",null,null,10], ... ], null, "检测语言", ...]`，取 `data[1]`（即 JSON 第一层数组 `[1]` 的每个 `row[1]`）拼接为最终译文。空则按失败处理。
- 源语言不写死：用 `sl=auto`（等价于上文“否则使用 Google Translate 自动语言检测”），满足任意语言→简体中文。

### E. 异步翻译
沿用 `mp.command_native_async` 子进程（与现有 `send_audio`/`refresh_track` 一致），天然不阻塞 Whisper：
- **单飞行 + FIFO 队列 + 最小间隔**：同一时刻最多一个翻译请求在跑，其余进队；相邻请求间隔 ≥ `MIN_TRANSLATE_INTERVAL`（默认 0.8s），从根上避免短时间大量请求。
- **失败隔离**：翻译失败只记 `translation_retry_after` 冷却（防止 403/429/断网时反复打接口），**不改动任何 Whisper 状态**，原文照常显示。

### F. 字幕正确对应（最关键的实现点）
用**“原文文本 → 译文”的缓存字典**解耦事件合并：`translation_cache[normalized] = 译文`，`build_srt` 渲染每个事件时按其 `event.normalized` 查缓存。这样不管 `state.events` 如何去重/合并，同一句原文永远取到同一句译文，天然不会错位；每句译文也随事件带相同的起止时间戳。

翻译完成后调用一次 `refresh_track(now_time())` 重注入更新后的双语 SRT。

### G. W 快捷键加在哪
1. `mp.add_key_binding(nil, 'translate', toggle_translate)`（新脚本绑定）。
2. [input_uosc.conf](file:///e:/mpv-lazy/portable_config/input_uosc.conf#L21) 第 21 行下方新增：
   `w  script-binding whisper_realtime/translate   #! 播放 > 开关 Whisper 实时翻译`

## 四、具体改动清单（H 部分回答）

### 1) `e:\mpv-lazy\portable_config\scripts\whisper_realtime.lua`（主改动）

**（1）新增常量**（对齐现有 `CHUNK_SECONDS` 等风格）：
```lua
local MIN_TRANSLATE_INTERVAL = 0.8      -- 相邻翻译请求最小间隔（秒），限流
local TRANSLATE_FAIL_COOLDOWN = 30      -- 翻译失败后的冷却（秒），避免打爆接口
local TRANSLATE_TARGET = 'zh-CN'        -- 目标语言固定简体中文
local TRANSLATE_URL = 'https://translate.googleapis.com/translate_a/single'
```

**（2）`state` 表新增字段**：
```lua
translate_enabled = false,
translation_cache = {},        -- [normalized原文] = 译文   （相同原文复用）
translation_pending = {},      -- [原文]=true 已入队/在飞/失败不再自动重试
translation_queue = {},        -- FIFO 待翻译 key 列表
translation_busy = false,      -- 是否有请求在飞（限流）
translation_last_sent = 0,
translation_retry_after = 0,
```

**（3）新增函数**：

- `parse_translation(data)`：解析 Google 响应 → 拼接译文字符串；非法返回 `''`。
- `translate_text(key)`：异步 curl 请求（带代理、限流、失败冷却）；成功写 `translation_cache[key]`、清 `translation_pending[key]`、随后 `refresh_track(now_time())`；失败只设冷却、`pending` 保留（不反复重试）。
- `queue_missing_translations()`：遍历 `state.events`，凡 `translate_enabled` 且原文不在缓存/未在 pending 的 `normalized`，加入队列（去重、避免重复请求）。
- `pump_translation()`：驱动队列——非忙、未冷却、超过最小间隔、队非空时取下一个 key→`translate_text`。
- `toggle_translate()`：翻转 `translate_enabled`；若被开启则 `queue_missing_translations()` 并 `refresh_track`，否则只停发新请求（不中断 Whisper）；OSD 提示“实时翻译已开启/已关闭”。

**（4）`build_srt` 行文本处**：原文行改用 `subtitle_text(event)`——
```lua
local function subtitle_text(event)
    if state.translate_enabled then
        local tr = state.translation_cache[event.normalized]
        if tr and tr ~= '' then return event.text .. '\n' .. tr end
    end
    return event.text   -- 未开启 / 尚未译出时，仅显示原文
end
```

**（5）`tick()`**：在 `if not state.enabled then return end` 之后（不受 Whisper 忙碌/暂停影响）插入：
```lua
if state.translate_enabled then
    queue_missing_translations()
    pump_translation()
end
```

**（6）`disable()`**：无需改动核心逻辑；翻译在 `enabled=false` 时,pump 自然停发新请求。可保留 `translation_cache`（同进程内跨开/关复用）。

**（7）注册新绑定**（文件底部，紧邻 `mp.add_key_binding(nil, 'toggle', toggle)` 处）：
```lua
mp.add_key_binding(nil, 'translate', toggle_translate)
```

### 2) `e:\mpv-lazy\portable_config\input_uosc.conf`
在 21 行 `q script-binding whisper_realtime/toggle` 下方新增一行：
```
 w                 script-binding whisper_realtime/translate               #! 播放 > 开关 Whisper 实时翻译
```

## 五、假设与决策

- **语言检测**：统一用 Google `sl=auto`（用户明确允许自动检测），目标固定 `zh-CN`；不依赖 Whisper 语言字段，最稳健。
- **缓存**：运行时内存缓存（`translation_cache`），同会话内相同原文不再请求；不做跨会话持久化文件，避免额外 IO/并发问题。
- **失败策略**：翻译失败不重试当前句、保留原文、进入冷却，绝不回退/停止 Whisper（满足“不能因为翻译失败导致 Whisper 停止”）。
- **进退行为**：W 在 Q 关时可切换开关但无实际效果；Q 开 + W 开才真正翻译。W 关只停新请求不停止 Whisper（符合需求）。
- **显示**：双语 = 原文本行 + 换行 + 译文；不触碰字号/位置/透明度等现有字幕设置。
- **代理**：复用 `configured_proxy()`（读到 `http://127.0.0.1:10809`），请求带代理；不新增 mpv 配置。

## 六、验证步骤

1. `luac.exe -p whisper_realtime.lua`（或用 mpv 启动日志）检查语法无错。
2. 重启 mpv，按 `Q` 启动实时字幕（模型加载 10–30s），确认原始行为与现在完全一致。
3. 播放一句已知外语音频，按 `W` → 出现双语（原文在上、译文在下），译文内容正确且与对应原文时间戳一致。
4. 连续多句不同文本 → 逐句正确对应，无串行错位。
5. 关网络/断代理再按 `W` → 仅显示原文，无报错、Whisper 继续运行。
6. 再次按 `W` 关闭 → 恢复仅原文字幕。
7. 观察日志确认翻译请求间隔 ≥0.8s、相同原文只请求一次（缓存命中）。
8. 按 `Q` 关闭 → 全部停止清理，二次字幕轨恢复原状。

（验证时用户为 `Q` 关闭 Whisper 也不影响——翻译仅跟随 `whisper_realtime`，独立于任何其他脚本。）