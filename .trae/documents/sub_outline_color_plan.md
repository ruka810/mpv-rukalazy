# 描边颜色（sub-outline-color）配置方案

## Summary（目标）
在现有的右下角「字幕色号按钮」面板上，新增 `sub-outline-color`（描边颜色）的配置能力，使其与现有的 `sub-color`（文字颜色）体验一致。面板顶部加「文字 / 描边」两个切换标签，点选后下方的实时色块、hex 输入框、10 个预设整体作用于当前选中的目标颜色属性。同样支持持久化到 mpv.conf，预设持久化到独立的 json 文件。

## Current State Analysis（现状）
- 位置：[SubColorButton.lua](file:///e:/mpv-lazy/portable_config/scripts/uosc/elements/SubColorButton.lua)
  - 仅关注 `sub-color`：`current_color`、`presets`、`text_input`、输入框、预设网格、持久化全部围绕 `sub-color`。
  - `persist_sub_color(hex)` 直接改写 mpv.conf 中的 `sub-color` 行（[L78-L96](file:///e:/mpv-lazy/portable_config/scripts/uosc/elements/SubColorButton.lua#L78-L96)）。
  - 面板几何在 `get_panel_bounds()`（[L170-L218](file:///e:/mpv-lazy/portable_config/scripts/uosc/elements/SubColorButton.lua#L170-L218)）：顶部一行「实时色块 + 输入框」（`tr_h` 高、`gap` 间隙），下方 5×2 预设网格。
  - `sub-color` 属性观察在 `observe_mp_property`（[L121-L130](file:///e:/mpv-lazy/portable_config/scripts/uosc/elements/SubColorButton.lua#L121-L130)）。
- mpv.conf [L185-L190](file:///e:/mpv-lazy/portable_config/mpv.conf#L185-L190)：已设 `sub-outline-size = 4`、`sub-color = "#DCE2F1"`；`sub-outline-color` 未设置（走 mpv 默认，需补写）。

## Proposed Changes（具体改动）

### 1. mpv.conf — 补充默认描边颜色
在 `sub-color` 行后新增一行，避免持久化首次写入时追加到文件尾部乱序：
```ini
sub-outline-color = "#000000"
```

### 2. SubColorButton.lua — 支持双颜色目标
整体思路：引入「当前模式」`self.mode = 'fill' | 'outline'`，以及两套相互独立的状态（当前色、预设、观察器、持久化），共用一套输入框与预设网格 UI。

#### 2.1 状态字段（init 中新增）
- `self.mode = 'fill'`（fill=文字，outline=描边）。
- `self.fill_current`、`self.outline_current`：两种颜色各自的当前值（从 `sub-color` / `sub-outline-color` 读取）。
- `self.fill_presets`、`self.outline_presets`：两套预设，分别持久化到 `sub_color_presets.json` / `sub_outline_color_presets.json`。
- `self.current_*` 相关引用改为跟随 `self.mode` 的动态读取，避免出现两套拼写冗余（提供局部函数 `color_state()` / `presets()` 按 mode 取当前套）。
- 原有 `self.current_color` / `self.presets` 字段改为动态映射，或替换为按 mode 访问。为减少改动面，保留字段名但对 `fill`/`outline` 各存一份，通过 `mode = 'fill'` 时用 `current_color`，`mode='outline'` 时用 `outline_color`。

> 推荐最小改动：新增 `self.outline_color`、`self.outline_presets`，并把所有「读取/写入当前套」的地方收敛到 2 个辅助函数：
> - `current_color_hex()` → 返回 `mode=='fill' and self.current_color or self.outline_color`
> - `current_presets()` → 返回 `mode=='fill' and self.presets or self.outline_presets`
> 预设设值时写成 `if mode=='fill' then self.presets[i]=.. else self.outline_presets[i]=.. end`。

#### 2.2 观察器
两个属性都观察：
- `sub-color` → 更新 `self.current_color`（现有逻辑）。
- 新增 `sub-outline-color` → 更新 `self.outline_color`。
- 回调里只在「对应 mode 且输入框未聚焦」时同步输入框文本。

#### 2.3 持久化
- 把 `persist_sub_color` 泛化成 `persist_sub_prop(prop_name, hex)`，其中写入样式默认 `#RRGGBB`。
- `handle_submit` / `handle_preset_click` 中，按当前 mode 选择属性名：`mode=='fill' and 'sub-color' or 'sub-outline-color'` 以及对应 json 文件。
- 预设加载/保存：`load_presets(file_path, current_hex)` / `save_presets(file_path, presets)`，两套各调一次。

#### 2.4 面板 UI — 顶部切换标签
在 `get_panel_bounds` 与 `render_panel` 中，于「实时色块+输入框」一行**上方**再增加一行标签（约 `tr_h` 高），该行左移会导致面板高度在 `pad + tr_h + gap + grid_h + pad` 基础上再增加 `tr_h + gap`。
- 两个标签：`文字`、`描边`，并排（各占可点击的区域）。
- 当前激活标签高亮（`text_input_active` 式边框或更高亮背景），未激活用常规样式。
- `update_hover` / 命中检测增加：点击标签 → `self:switch_mode('fill'|'outline')`，切换后刷新输入框文本为对应当前色，失焦。

#### 2.5 输入框行为不变
输入、光标、粘贴、过滤、回车提交逻辑完全复用，仅提交时写入的属性名与预设套随 mode 变化。

### 3. tooltip 文案
`self.tooltip` 按 mode 显示「字幕文字颜色 xxx」/「字幕描边颜色 xxx」。

## Assumptions & Decisions（假设与决策）
- 采用「顶部切换标签」方案（用户已确认）。
- 文字颜色与描边颜色各自独立的预设集合与持久化文件，互不干扰。
- 描边颜色默认值为 mpv 默认黑色 `#000000`，首次持久化前先在 mpv.conf 补写，保证观感一致。
- 不改动其余控件、编码、剪贴板等已稳定的逻辑。

## Verification（验证）
1. `luac -p` 检查 SubColorButton.lua 语法。
2. 重启 mpv 打开视频，悬停到色号按钮确认面板展开。
3. 顶部看到「文字 / 描边」标签，默认选中「文字」。
4. 点「描边」标签：色块演示当前描边色（初始为黑），输入框显示对应色号。
5. 输入任意 `#RRGGBB`（如 `#FFD700`），回车：字幕描边即时变为该色，检查 mpv.conf 中 `sub-outline-color = "#FFD700"` 已写入。
6. 双击某个预设色块保存到描边槽；重启 mpv，确认描边色与预设均保留。
7. 切回「文字」标签，确认文字颜色功能不受影响，预设各自独立。