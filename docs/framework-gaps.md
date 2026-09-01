# gpui-moonbit 框架缺口记录与绕行方案

本项目的约束是**不修改 gpui-moonbit 的 C ABI**（vendored 于 `third_party/`）。
以下是实现在 WYSIWYG 编辑器过程中遇到的框架限制，以及我们在
adapter/core 侧采取的绕行方案。按发现顺序记录。

## 1. click 事件不携带坐标

`EVENT_CLICK` 信封只有 `handler_id`（`data_a`），没有鼠标位置。

- **影响**：无法把点击映射到块内的字符偏移（无法“点哪停哪”）。
- **绕行（两级）**：
  1. 单元级：可点击区域从“顶层块”细化到“编辑单元”，非文本单元（代码块/
     图片/Raw/HR）点击 = 光标落该单元尾。任务框 ☑/☐ 独立点击区
     （`on_box_click`→勾选切换）。handler id 池按需增长（历史固定 128 槽
     会越界全部指向末块）。
  2. token 级：文本单元（标题/段落/列表项/表格格）在渲染时拆成 token——
     CJK 一字一 token、拉丁词一词（`adapter/textlayout.mbt`）——每个 token
     是独立点击区，点击 = 光标落该 token 起点；行尾剩余宽度是「落块尾」的
     虚拟点击区。折行由 MoonBit 侧按估算宽度自算（见缺口 4）。
  这是无坐标约束下“点哪停哪”的最大逼近：CJK 精确到字、拉丁精确到词，
  词/字之内无法再细分。

## 2. 无内联文本编辑控件可用（编辑器模式）

`OP_TEXT_INPUT`（RFC 0003）是完整 widget，但其焦点模型/选区 API 面向
表单场景，拿不到块级富文本所需的：字符级选区回读、样式化渲染、
Enter/Backspace 自定义拦截（widget 会吞掉这些键，见 lib.rs
`input_focused` 分支——焦点在 input 时框架不再向 app 转发任何键事件）。

- **影响**：goal 中允许的降级路径（“活动块 = text_input”）实际也不可用。
- **绕行**：完全自绘——文档渲染为 `rich_text` run；文本区光标是绝对定位
  （`OP_SET_POSITION` + `OP_SET_INSET`）的零宽光标条，画在光标偏移所在
  token/子 token 的左缘，不占排版宽度、不推文字（代码块内仍是“▏”字符段，
  因为把行拆成两半会破坏长行软换行）；选区是背景色 run；所有键事件走 app 级
  `on_key/on_named_key/on_text` 由 core 的编辑内核处理。
  代价：没有系统光标闪烁、没有 IME 内联候选窗（goal 明确不要求 IME）。

## 3. `typed_text` 不检查修饰键（键入与快捷键双投递）

`gpui-sys` 的 `on_key_down` 在发出 `EVENT_KEY` 之后，只要
`key_char`/单字符键就**无条件**再发一条 `EVENT_TEXT`。
即 `Cmd+Z` 会同时产生 `KEY('z', PLATFORM)` 和 `TEXT("z")`。
`EVENT_TEXT` 信封不带 mods，接收端无法自判。

- **实测证据**：未处理时按 Cmd+Z 撤销后，字符 `z` 又被插入文档。
- **绕行**：`adapter` 采用**代际计数**（`key_gen`/`swallow_gen`）而非一次性
  布尔标志——每次 keydown 递增 `key_gen`，带 Platform/Ctrl/Alt 的 keydown
  记下 `swallow_gen=key_gen`；`on_text` 仅当 `swallow_gen==key_gen` 时吞掉
  该条 text 事件（`adapter/app.mbt:on_key/on_text`）。一次性布尔标志曾会
  误吞后续普通键入，代际计数保证“只吞当次快捷键补发的那一条”。

## 4. 无文本换行度量接口

无法向框架查询“第 N 个字符的像素坐标”，也就无法实现上下方向键的
视觉行移动。

- **绕行**：Up/Down 近似为**相邻编辑单元**的首/尾跳转
  （`core::doc_move`），跨软换行的行为与视觉行不一致；这是已知简化。
  token 点击定位所需的折行也在 MoonBit 侧自算：按 demo 窗口固定 960px 宽、
  按字符类别（宽字符 ≈1em、普通字母 ≈0.56em）估算 token 宽度后贪心折行
  （`textlayout::layout_text`）。估算与实际字体度量有 ±10% 级别出入，
  且**窗口缩放不会重新折行**（框架无 resize 事件）。

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

## 8. Tab 键被焦点遍历吃掉，无法送达 MoonBit

`gpui-sys/src/lib.rs` 的 `focused_input_or` 分支（约 2863-2877 行）在按键
为 Tab 时直接执行 GPUI 的 focus traversal 并 `return true`，**不转发**给
注册回调。因此编辑器永远收不到 Tab。

- **影响**：无法用 Tab 做列表缩进/代码块内制表。
- **绕行**：缩进/反缩进改用 `Cmd+]` / `Cmd+[`
  （`core::doc_indent` / `doc_outdent`），并在 README 注明键位。

## 9. 无内联图片渲染 opcode

命令缓冲没有 image 节点类型（只有 div/text/rich_text 及样式 op）。
- **绕行**：`ImageBlock` 渲染为 `⛁ alt · url` 文本占位，编辑时按原子块
  整体退格/前删。图片二进制渲染超出本期范围。

## 10. run_window 前 build_tree 是合法的（澄清）

`gpui_build_tree` 只解码命令缓冲并写入 `VIEWS[view]`（越界自动
resize），**不需要**窗口/App 上下文；`run_window` 仅打开窗口渲染
`VIEWS[view]`。因此 `selftest` 可以完全无 GUI 地走
build_tree → debug_dump_text 全链路（本项目 CI 手段）。
## 11. 无原生文件选择框 / 无拖放 / 无 paste 代理

框架没有 open-panel、没有文件拖放事件，`Cmd+V` 也不会作为 paste 内容送达
（gpui-sys 仅在 focus 于 `OP_TEXT_INPUT` widget 时才代理剪贴板；我们不用
widget，见缺口 2）。

- **影响**：拿不到「浏览…」对话框选中的路径，也不能把文件拖进窗口。
- **绕行**（`adapter/app.mbt` + `main/main.mbt`）：
  1. `Cmd+O` 弹出窗口顶部**路径栏**：应用自管的单行输入（on_text/
     Backspace/Enter/Esc 全走现有事件链），`~` 展开后用 `@fs` 读文件；
     `Cmd+S` 规范导出回写关联文件（未关联时报错并弹栏提示）。
  2. `open dist/MdMbt.app --args <path>` 按文件启动（Finder「打开方式」
     的命令行形态），失败回退内置 demo。
  限制：路径栏没有 IME 内联候选（同缺口 2）；不做自动补全。

## 12. 无程序化滚动写入（虚拟窗口的遗留缺口）

滚动状态只有**读**接口 `scroll_state(view, scroll_id)`（notify-then-pull），
`ScrollHandle::set_offset` 只存在于 Rust 侧 benchmark 内部，没有对应 opcode。

- **影响**：虚拟窗口渲染（16c496f）下，用方向键把光标移出可视窗口时无法
  让视口自动跟随——只能靠用户滚动滚轮。spacer 保证滚动行程与全文等长，
  所以手动滚回去总能到。
- **绕行**：无（正面解法是给 ABI 加 `OP_SET_SCROLL_OFFSET`，本期不改 ABI）。
