# 右下角字幕颜色按钮实现计划（v2）

## Repository Research

### 当前架构
- 控件栏按钮定义在 `Controls.lua` 的 `shorthands` 表中，已扩展支持 `play_mode` kind。
- 所有 Element 都继承 `Element.lua`，提供 `add_key_binding(key, fnFlags, namespace)` / `remove_key_bindings(namespace)` 强制键绑定能力，生命周期跟随元素销毁自动清理。
- `Menu.lua` 已展示了如何用 `any_unicode` 绑定 + `complex=true` flags 捕获所有键盘字符（含 kp 数字键）。
- mpv `sub-color` 属性可通过 `mp.set_property('sub-color', '#RRGGBB')` 直接设置。
- 颜色格式：ASS 绘制用 `&HBBGGRR`，mpv 属性用 `#RRGGBB` 或 `&HBBGGRR`。
- 持久化可通过 `mp.find_config_file()` 定位 config 目录，用 `mp.utils.format_json` / `mp.utils.parse_json` 读写 JSON 文件。
- `cursor` 全局模块提供鼠标坐标和 proximity 机制。
- 按钮 render_order 范围：controls=6，menu=1001，panel 设为 8~10 即可。

### 交互已确认
- **布局**：鼠标悬停按钮自动出现面板，移出自动关闭。
- **色号输入**：面板内文本框，支持键盘直接输入（通过 `any_unicode` + `bs`/`del`/`enter`/`esc` 键绑定）。
- **预设交互**：左键应用 / 双击保存当前色到该槽。
- **预设持久化**：独立 JSON 文件，放在 `portable_config/sub_color_presets.json`。

## Files and Modules

| 文件 | 变更 |
|------|------|
| `portable_config/scripts/uosc/elements/Controls.lua` | 新增 require SubColorButton、`sub-color` shorthand、`sub_color` kind 创建分支 |
| `portable_config/scripts/uosc/elements/SubColorButton.lua` | **新建**：按钮 + 面板整体元素 |
| `portable_config/scripts/uosc/main.lua` | 控件列表末尾加 `,sub-color`；注册 script-message；预设文件读写工具 |
| `portable_config/script-opts.conf` | controls 示例行同步更新 |

## Implementation Steps

### Step 1: 色值与持久化工具（放在 main.lua 或 SubColorButton.lua）
```lua
-- 校验 + 补全 → #RRGGBB
function normalize_hex(input)
    input = tostring(input):gsub('%s+', '')
    -- 支持：#RRGGBB, RRGGBB, &HBBGGRR, &HAABBGGRR, 空字符串 → nil
    -- 统一输出 #RRGGBB，无效则返回 nil
end

-- #RRGGBB → &HBBGGRR
function hex_to_ass(hex)
    local r,g,b = hex:match('#(%x%x)(%x%x)(%x%x)')
    return r and ('&H' .. b .. g .. r) or '&HFFFFFF'
end

-- 预设读写
function load_sub_color_presets()  -- 返回 10 个 hex color
function save_sub_color_presets(presets)
```
默认 10 色：`#FFFFFF, #000000, #FF0000, #00FF00, #0000FF, #FFFF00, #FF00FF, #00FFFF, #FF8800, #888888`

### Step 2: SubColorButton 元素（继承 Button）

#### 状态
- `open` (bool): 面板是否正在显示
- `panel_ax/ay/bx/by`: 面板布局坐标
- `text_input` (table): `value`, `cursor` 当前正在编辑的 hex 字符串和光标位置
- `text_input_active` (bool): 文本框是否处于输入焦点（鼠标点进文本框后激活）
- `presets` (table): 10 个 hex 值
- `last_hover_swatch`: 最近鼠标悬停的预设索引（高亮）

#### 初始化
- 读取 `sub-color` 当前值、加载预设
- 注册 `observe_mp_property('sub-color', ...)` 实时同步按钮 tooltip 和面板预览色

#### render 结构
```
按钮：palette 图标 + tooltip "字幕颜色"

悬停展开的面板 render_order=8~10：
┌──────────────────────────────┐
│  ┌──────────────────────┐    │
│  │  当前颜色预览大色块    │    │
│  └──────────────────────┘    │
│  #FFFFFF                    │
│  ┌─┬─┬─┬─┬─┬─┬─┬─┬─┬─┐     │
│  │ │ │ │ │ │ │ │ │ │ │     │
│  └─┴─┴─┴─┴─┴─┴─┴─┴─┴─┘     │
└──────────────────────────────┘
```

渲染细节（全部用 `ass` API）：
1. 面板背景：`ass:rect(ax, ay, bx, by, {color=bg, opacity=..., radius=state.radius})`
2. 大色块：居中，带细边框（边框色取前景色）
3. hex 文本：`ass:txt(x, y, 5, self.text_input.value, {size=..., color=fg, border=...})`
   - 文本框激活时显示光标（`self.text_input.cursor` 位置处画一条细竖线）
4. 预设 10 格：2 行 × 5 列 或 1 行 × 10 列（按面板宽度），每格用 `ass:rect` 画实心色 + 细边框
5. 鼠标悬停的预设：边框加粗 1px 或改色

#### 交互逻辑

**悬停开关**（主循环放在 render 或 update）：
- 通过 `self.proximity`（继承自 Element 的 proximity 系统）判断鼠标是否接近按钮或面板
- 当 `self.proximity > 0` 且面板未打开 → 打开展示面板（`open = true`，注册键绑定）
- 当 `self.proximity == 0` 且面板已打开 → 关闭面板（延迟 200ms，避免鼠标快速来回抖动），移除键绑定

**点击大色块/hex 文本** → `text_input_active = true`，聚焦输入框（光标到末尾）

**左键点预设** → `mp.set_property('sub-color', hex)`

**双击预设** → `presets[i] = mp.get_property('sub-color')` 然后 `save_sub_color_presets(presets)`
- 双击检测：记录 `last_click_swatch_index` 和 `last_click_time`，两次点击同一块且间隔 < 350ms 判为双击

**键盘输入**（面板打开时，通过 `add_key_binding` 注册，namespace='input'）：
- `any_unicode`（`repeatable=false, complex=true`）：追加可打印字符（限制只接受 `#` 和 `0-9a-fA-F`，最多 7 字符）
- `kp0..kp9`, `kp_dec`：同上（kp 数字键不进入 any_unicode）
- `bs` / `bs+ctrl`：删除光标前 1 个 / 全部
- `del`：删除光标后 1 个
- `left`/`right`：光标移动
- `home`/`end`：光标到首尾
- `enter`/`kp_enter`：提交 text_input.value → 校验后 `mp.set_property('sub-color', ...)`，并 `text_input_active = false`
- `esc`：关闭面板

**文本校验**：`normalize_hex` 返回 nil 时不应用，保留原值。`osd_message` 提示无效颜色。

#### 定位面板坐标
面板贴在按钮下方（或上方，按剩余空间），宽度 ≈ 按钮宽度 × 4~5，高度由行数决定。

### Step 3: Controls.lua 集成
1. require SubColorButton
2. shorthand：`['sub-color'] = 'sub_color:palette?字幕颜色'`
3. kind 分支：
```lua
elseif kind == 'sub_color' then
    local element = SubColorButton:new('control_' .. i, {
        render_order = self.render_order,
        anchor_id = 'controls',
    })
    table_assign(control, {element = element, sizing = 'static', scale = 1, ratio = 1})
```

### Step 4: main.lua 集成
- controls 末尾（fullscreen 前）加 `,sub-color`
- 在 main.lua 里提供全局工具函数 `normalize_hex` / `hex_to_ass` / `load_sub_color_presets` / `save_sub_color_presets`
- 暴露 `state.sub_color_presets`（或直接在 SubColorButton 内维护并调用保存）

### Step 5: script-opts.conf 同步
更新被注释的 controls 示例行。

## Dependencies and Considerations

- **Element.add_key_binding 使用 mp.add_forced_key_binding**：会覆盖其他按键绑定，因此只在面板打开且 `text_input_active` 时注册文本输入相关键，esc 可随时抢占退出。
- **any_unicode 在 complex 模式下回调 info.key_text 获取字符**：需参考 Menu:search_text_input 的实现。
- **面板 proximity 计算**：Element 的 proximity 系统只算按钮本身的矩形。需要在 SubColorButton 重写 `reset_proximity` / `update_proximity`，把面板区域也纳入 proximity 计算范围，避免鼠标移到面板上时 proximity 变 0 导致关闭。
- **面板 render_order**：设为比控件栏大（= controls.render_order + 2），比 Menu 小（Menu=1001）。
- **预设文件位置**：`mp.find_config_file('sub_color_presets.json')` 查不到时用 `mp.commandv('expand-path', '~~/sub_color_presets.json')` 定位，保证放在 config 根目录。
- **不持久化到 mpv.conf**：所有颜色修改通过 `mp.set_property` 运行时生效，不落盘 mpv.conf。
- **第一个预设**：文件不存在时，初始化把当前 `sub-color` 写入第 1 槽（用户原始需求）。
- **Unicode 字符过滤**：面板内文本框只接受 `#` 和 hex 字符（0-9, a-f, A-F），其他 any_unicode 字符忽略。

## Validation

- 启动 mpv，控件栏出现 palette 图标按钮
- 鼠标悬停按钮 → 面板立即出现；移出面板 → 面板关闭（有短暂延迟避免抖动）
- 面板内大色块显示当前字幕颜色；hex 文本显示 `#RRGGBB` 格式
- 鼠标点进 hex 文本区 → 文本可编辑（可聚焦），光标显示；可键入 hex 字符、退格、删除
- 按 Enter 提交 → 字幕颜色立即改变
- 左键点预设方块 → 字幕颜色立即改变
- 双击预设方块 → 把当前色保存到该槽；重启 mpv 后仍存在
- 面板关闭后键盘绑定被清理，不会干扰 mpv 其他操作
- `sub-color` 改变时按钮 tooltip 实时更新

## Risks

- **proximity 重写**：Element 基类的 proximity 是按按钮自身 bbox 计算的，面板超出 bbox 的部分 proximity=0。需要重写 `reset_proximity` 把面板区域也纳入 proximity 检查。
  处理：SubColorButton 重写 `update_proximity` 方法，把面板 bbox 加入 `get_point_to_rectangle_proximity` 计算的候选区域。
- **any_unicode 与 mpv 其他快捷键冲突**：面板内强制绑定 any_unicode 会覆盖 mpv 的键。
  处理：绑定仅在面板打开 + text_input_active 期间注册，且 esc 优先清除 text_input_active 状态；或 text_input 未激活时只有预设点击和关闭逻辑，不绑定字符键。
- **双击检测精度**：`last_click_time` 放在 SubColorButton 实例内即可，因为面板只在悬停时打开，不会有多个实例。
- **颜色格式不统一**：ASS 绘制用 BGR，mpv 属性用 RGB，务必使用统一的转换函数避免顺序写错。
- **Windows 输入法影响**：`any_unicode` 依赖输入法切换，若用户在中文输入法下输入 hex 会出中文字符。简单处理：只接受 hex 字符，非 hex 字符忽略。