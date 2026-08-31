# 字幕色号按钮实现计划（v3 — 悬停展开 / 已验证）

## Summary
在 mpv-lazy 的 uosc 控件栏右下角新增一个「字幕色号」按钮（palette 图标）。鼠标悬停按钮展开面板，移出关闭；面板内：
1. 一个大色块实时预览当前字幕颜色；
2. 一个可编辑的十六进制色号输入框（如 `#FFFFFF`）；
3. 一排 10 个预设色块，单击套用该色、双击把当前色保存到该槽。

全部通过 mpv `sub-color` 属性运行时生效，预设持久化到独立 JSON 文件，不改动 mpv.conf。

## Current State Analysis
- 当前字幕色号：`sub-color = "#ffb3b3"`（`portable_config/mpv.conf:187`）。
- uosc 控件栏定义在 `Controls.lua`：
  - `shorthands` 表 `L41-L83`；`['sub-color'] = 'sub_color:palette?字幕颜色'` 在 `L63` 被注释。
  - kind 分派创建控件在 `L151-L246`；`sub_color` 分支骨架在 `L210` 被注释并混在 `play_mode` 分支里。
  - `require('elements/SubColorButton')` 在 `L6` 被注释。
- 控件列表字符串在 `main.lua:40-41`，末尾为 `...,play-mode,gap,prev,items,next,gap,fullscreen`，当前不含 `sub-color`。
- 参考实现：`PlayModeButton.lua`（自研接口按钮）、`Button.lua`（渲染骨架）、`Menu.lua`（`any_unicode`/`kp` 输入与 `cursor:zone` 命中检测）、`Element.lua`（`add_key_binding`/`observe_mp_property`/`render_order`/`proximity`）。

## Proposed Changes

### 1. 新建 `portable_config/scripts/uosc/elements/SubColorButton.lua`
继承 `Element`（自定义渲染，不直接复用 `Button`，因为需要面板+rgb 输入+预设）。

**工具函数（文件内局部，自包含，不改 main.lua）：**
- `normalize_hex(input)`：清洗输入并统一转成 `#RRGGBB`（支持 `#RRGGBB`、`RRGGBB`、`&HBBGGRR`、忽略空白；无效返回 `nil`）。
- `hex_to_rgb(hex)` / `rgb_to_hex(r,g,b)`：文本↔数值，供色块绘制与预览。
- `load_presets()` / `save_presets(presets)`：读写 `sub_color_presets.json`（用 `mp.find_config_file('sub_color_presets.json')`，查不到则 `expand-path ~~/sub_color_presets.json`），内容为 10 个 hex 字符串数组。文件不存在时初始化：槽1 = 当前 `sub-color`，其余用默认色 `#FFFFFF,#000000,#FF0000,#00FF00,#0000FF,#FFFF00,#FF00FF,#00FFFF,#FF8800,#888888`。读写失败静默降级为内存态。

**状态字段：**
- `open`(bool)：面板开合。
- `presets`(table)：10 个 hex。
- `text_input`(string)：当前编辑串；`text_input_active`(bool)：输入框是否聚焦；`cursor_pos`(number)。
- `hover_index`(number|nil)：悬停预设槽（高亮）。
- `last_click_index` / `last_click_time`：双击检测。

**初始化：**
- 读当前 `sub-color`、载入预设。
- `self:observe_mp_property('sub-color', ...)` 同步 tooltip 与面板预览，并当不在输入态时刷新 `text_input`。

**布局（面板位于按钮上方，因控件栏在底部）：**
- 按钮 bbox 即控件坐标（由 Controls 布局传入 `ax,ay,bx,by`）。
- 面板宽 ≈ `5×swatch + 2×padding`（swatch≈44 → 宽约 254），右缘对齐按钮中心，`render_order = 6`(controls) + 2 = `8`，低于 Menu 的 1001。
- 从上到下：预览大色块(高≈56) → hex 输入行(高≈26) → 预设 2 行×5 列(高≈2×46)。

**render（`ass` API）：**
1. 按钮本体：`ass:rect` 底色 + `ass:icon(palette)`；当前色作为小圆点/色带画在图标右下角作「当前色」提示。
2. 面板(仅 `open` 时)：背景 `ass:rect`（含圆角、半透明，`render_order=8`）；预览色块实心 `ass:rect` + 细边框；hex 文本 `ass:txt`，聚焦时在 `cursor_pos` 画竖线光标。
3. 10 个预设色块 `ass:rect`，悬停项边框加粗。
4. 命中检测 `cursor:zone`：
   - `primary_down` 按钮区域 → `toggle_panel()`。
   - `primary_down` 预览色块 / hex 输入行 → `focus_text_input()`。
   - `primary_down` 每个预设色块 → 单击应用；结合 `last_click_*` 判双击保存。
- 面板打开时把交点区域（按钮+面板）纳入 `proximity`/`get_visibility` 判定，避免面板内容时被顶部其他元素遮挡（`render_order=8` 已保证在菜单下方之上）。

**交互逻辑：**
- **悬停开合**（由 proximity 驱动）：
  - 覆盖 `update_proximity()`：面板关闭时用按钮 bbox 计算（默认行为）；面板打开时构造 `union_rect = {ax=min(...), ay=min(...), bx=max(...), by=max(...)}`（按钮∪面板），对 `get_point_to_rectangle_proximity(cursor, union_rect)` 计算。这样鼠标移到面板上时 `self.proximity` 仍 >0，面板不因离开按钮而关闭。
  - `get_visibility()` 返回 >0 即渲染并注册面板命中区；proximity→0（鼠标同时离开按钮与面板）时面板自动消失。循环在 render/update 中自然触发 `request_render()`。
  - 无需点击切换；再次悬停即可重新使用。
- 点击（`cursor:zone('primary_down')`）：
  - 预览色块 / hex 输入行 → `focus_text_input()`（`text_input_active=true`、聚焦并注册输入键绑定 namespace `'subcolor'`）。
  - 每个预设色块 → 单击 `mp.set_property('sub-color', hex)`；双击（同槽 < 350ms）→ `presets[i]=当前色; save_presets`。
- 文本提交：`normalize_hex` 有效则 `mp.set_property`，无效 `osd_message` 提示不应用。
- 键绑定（面板打开且 `text_input_active` 时注册，flags `{repeatable=true, complex=true}`）：
  - `any_unicode`：追加合法字符（仅 `#` + `0-9a-fA-F`，最多 7 位），逻辑参考 `Menu.lua:1349`（`info.key_text`）。
  - `kp0..kp9`、`kp_dec`：同上（`Menu.lua:1437-1442` 说明这些不进 any_unicode）。
  - `bs`/`del`/`left`/`right`/`home`/`end`：编辑光标。
  - `enter`/`kp_enter`：提交并退出输入态。
  - `esc`：退出输入态（`text_input_active=false`）并移除输入键绑定。
- 输入态退出 / 面板关闭时 `self:remove_key_bindings('subcolor')`。

### 2. 修改 `portable_config/scripts/uosc/elements/Controls.lua`
1. 取消注释 `L6`：`local SubColorButton = require('elements/SubColorButton')`。
2. 取消注释 `L63`：`['sub-color'] = 'sub_color:palette?字幕颜色'`（从注释改回启用）。
3. 新增 kind 分支（参考 `PlayModeButton` 分支 `L203-209`，修好 `L210` 处错位的注释块）：
```lua
elseif kind == 'sub_color' then
	local element = SubColorButton:new('control_' .. i, {
		render_order = self.render_order + 2,
		anchor_id = 'controls',
		foreground = fg,
		background = bg,
	})
	table_assign(control, {element = element, sizing = 'static', scale = 1, ratio = 1})
```
需注意：现 `L210-L223` 的注释块与 `play_mode` 分支粘连（`elseif kind == 'sub_color'` 的注释残留放进了 `play_mode` 分支），改动时把该残留注释清理掉，恢复为独立 `elseif` 分支。

### 3. 修改 `portable_config/scripts/uosc/main.lua`
在 `L41` 控件字符串结尾（`...,items,next,gap,fullscreen`）中间插入 `,sub-color`，使按钮落在右下角、紧邻 `fullscreen`：
```
...,items,next,sub-color,gap,fullscreen
```

### 4.（可选，不改也可用）`portable_config/script-opts.conf`
不修改。控件由 `options.controls` 驱动，`sub-color` 已写死进主配置字符串，无需改示例行。

## Assumptions & Decisions
- **交互为悬停展开**：按你的选择，鼠标移到按钮展开面板、移出（离开按钮与面板）自动关闭，贴近 uosc 原生行为；面板通过 `update_proximity` 覆盖纳入并集 rect，避免移上面板即关闭。
- **预设数量固定 10**：2 行 × 5 列；首批文件缺失时槽1自动填入当前字幕色。
- **持久化位置**：`sub_color_presets.json` 放 config 根目录（`portable_config/` 旁），不写回 mpv.conf。
- **颜色格式**：界面上统一 `#RRGGBB`；设置属性用同格式字符串，色块绘制用 `hex_to_rgb` 取 RGB。
- **预设槽双击保存**：单击立即生效、快速双击同槽则覆盖保存，实现简单且符合「可保存十个预设」。

## Verification
1. 重启 mpv 或 reload uosc，控件栏右下角出现 palette 图标按钮（`sub-color` 集成、shorthand、kind 分支三处生效）。
2. 鼠标悬停按钮弹出面板，预览色块显示当前色 `#ffb3b3`，hex 文本显示 `#ffb3b3`；鼠标移到面板内面板保持不关闭。
3. 鼠标离开面板（按钮+面板都离开）面板消失。
4. 点击输入框聚焦后输入 `#FFFFFF` 回车，字幕立即变白；无效输入（如 `#GGGGGG`）提示且不生效；`esc` 退出输入态。
5. 单击预设色块字幕立即变色；悬停预设方形有高亮边框。
6. 双击某预设槽，当前色被保存；重启 mpv 后 `sub_color_presets.json` 内数据仍在，面板回显正确。
7. 输入态退出 / 面板关闭后，`any_unicode` 等键绑定被移除，不影响 mpv 其他快捷键。
8. `q` 调小窗口宽度时鼠标/眼测控件栏不因新按钮明显异常（static 元素会自动隐藏，`Controls.lua` 已有机制）。