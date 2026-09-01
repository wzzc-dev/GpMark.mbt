# gpui-moonbit 框架缺口记录与绕行方案

本项目的约束是**不修改 gpui-moonbit 的 C ABI**（vendored 于 `third_party/`）。
以下是实现在 WYSIWYG 编辑器过程中遇到的框架限制，以及我们在
adapter/core 侧采取的绕行方案。按发现顺序记录。

## 1. click 事件不携带坐标

`EVENT_CLICK` 信封只有 `handler_id`（`data_a`），没有鼠标位置。

- **影响**：无法把点击映射到块内的字符偏移（无法“点哪停哪”）。
- **绕行**：点击块 = 聚焦该块并把光标放到**块尾**
  （`adapter/app.mbt:on_block_click`）。这是本编辑器唯一的定点方式。

## 2. 无内联文本编辑控件可用（编辑器模式）

`OP_TEXT_INPUT`（RFC 0003）是完整 widget，但其焦点模型/选区 API 面向
表单场景，拿不到块级富文本所需的：字符级选区回读、样式化渲染、
Enter/Backspace 自定义拦截（widget 会吞掉这些键，见 lib.rs
`input_focused` 分支——焦点在 input 时框架不再向 app 转发任何键事件）。

- **影响**：goal 中允许的降级路径（“活动块 = text_input”）实际也不可用。
- **绕行**：完全自绘——文档渲染为 `rich_text` run，光标是插入文本流的
  “▍” 彩色段，选区是背景色 run；所有键事件走 app 级
  `on_key/on_named_key/on_text` 由 core 的编辑内核处理。
  代价：没有系统光标闪烁、没有 IME 内联候选窗（goal 明确不要求 IME）。

## 3. `typed_text` 不检查修饰键（键入与快捷键双投递）

`gpui-sys` 的 `on_key_down` 在发出 `EVENT_KEY` 之后，只要
`key_char`/单字符键就**无条件**再发一条 `EVENT_TEXT`。
即 `Cmd+Z` 会同时产生 `KEY('z', PLATFORM)` 和 `TEXT("z")`。
`EVENT_TEXT` 信封不带 mods，接收端无法自判。

- **实测证据**：未处理时按 Cmd+Z 撤销后，字符 `z` 又被插入文档。
- **绕行**：`adapter` 里处理任何带 Platform/Ctrl/Alt 的 keydown 时置
  `swallow_text` 标志，吞掉紧随其后的那一条 text 事件
  （`adapter/app.mbt:on_key/on_text`）。

## 4. 无文本换行度量接口

无法向框架查询“第 N 个字符的像素坐标”，也就无法实现上下方向键的
视觉行移动。

- **绕行**：Up/Down 近似为**相邻编辑单元**的首/尾跳转
  （`core::doc_move`），跨软换行的行为与视觉行不一致；这是已知简化。

## 5. `debug_dump_text` 是只读文本回读，不含样式/几何

- 用途良好（headless selftest 就靠它），但无法验证颜色/位置——
  渲染正确性最终仍需 GUI 截图确认。

## 6. 顶层 `let` 仅在“被引用”时求值（MoonBit 语义，非框架 bug，易踩）

副作用型初始化（如 `let _init = { for … arr.push(…) }`）若 `_init`
从未被引用则**永不执行**，导致数组为空——本项目曾以此方式埋了一个
静默 bug（click_slot 恒为空，点击无响应）。
- **绕行**：初始化全部内联在初始化表达式里（`Array::make(n, 0)`），
  且注册 keep-alive 一律经由被 `rebuild/dispatch` 实际引用的值。

## 7. 事件回调单入口，无 hover/右键/拖拽

`register_dispatch` 只有一个 C 回调；未提供 mouse-move/drag/context-menu。
- **影响**：无法用鼠标拖拽选区、右键菜单。选区只能靠 Shift+方向键。

## 8. run_window 前 build_tree 是合法的（澄清）

`gpui_build_tree` 只解码命令缓冲并写入 `VIEWS[view]`（越界自动
resize），**不需要**窗口/App 上下文；`run_window` 仅打开窗口渲染
`VIEWS[view]`。因此 `selftest` 可以完全无 GUI 地走
build_tree → debug_dump_text 全链路（本项目 CI 手段）。
