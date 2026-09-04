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
- **已解（词内精确）**：桥层新增鼠标回传 + 几何探针拉取通道（见缺口 14），
  按下/拖拽坐标与真实布局矩形同帧可得，命中按像素比例插值到词内；token
  点击通道保留为退化路径（代码块等无探针几何的区域）。

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
  代价：没有系统光标闪烁；IME 组词文本浮动渲染在光标右侧（缺口 13 的
  ImeBridge 推送 + render 的光标覆盖层），不走真实 inline marked-text 重排。

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
- **已解（Windows，gpui-sys 侧）**：Windows 上这个双投递不是「快捷键杂散
  补发」而是**所有可打印键常态双发**——每个未消费的 WM_KEYDOWN 都会被
  平台后端 `TranslateMessage` 成 WM_CHAR，`handle_char_msg` 把它投给焦点
  `ImeBridge::replace_text_in_range`（→ `EVENT_TEXT`），keydown 路径再发
  一次 `typed_text` 即字母/数字各进两条（与缺口 13a mac 第三方输入法的
  「双发」同症状，mac 靠输入源判定门控，Windows 则无条件发生）。
  gpui-sys 现按平台门控：普通键的文本只走 WM_CHAR（Windows 权威文本通道，
  layout/死键感知、控制字符过滤）；Alt/AltGr 组合走 WM_SYSKEYDOWN、不产生
  char 消息，其 keydown 文本保留。mac 的 Cmd 组合仍靠代际计数绕行。

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

## 7. 事件回调单入口，无 hover/右键

`register_dispatch` 只有一个 C 回调；无 hover、context-menu。
- **已解（拖拽）**：gpui-sys 根 div 上的左键 down/up + dragging-move 监听
  把事件封装成 EVENT_ASYNC 鼠标负载回传，鼠标拖拽选区已实现（缺口 14）。
- **仍存**：hover、右键菜单。选区的键盘路径（Shift+方向键）照常可用。

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
widget，见缺口 2）。库包又不能加 `cc-link-flags`（会令 moon 误把本包当可
执行目标），因此**不能**直接在 adapter 里链 AppKit 调 `NSOpenPanel`。

- **影响**：拿不到「浏览…」对话框选中的路径，也不能把文件拖进窗口。
- **绕行**（`adapter/filedialog_stub.c` + `adapter/app.mbt` + `main/main.mbt`）：
  1. `Cmd+O`（顶栏 Open 按钮同款；Windows 上快捷键修饰为 Ctrl，见下）经
     `filedialog_stub.c`（native-stub）**子进程成桥**弹出真正的系统文件
     选择框：macOS 跑 `osascript -e 'choose file'`（NSOpenPanel，由独立
     osascript 进程承载）；Windows 跑 `powershell -Command` 的
     `System.Windows.Forms.OpenFileDialog/SaveFileDialog`（Win32 通用
     对话框；脚本纯 ASCII——cmd 按 OEM 代码页解析命令行；stdout 强制
     UTF-8 供上层 `@utf8` 解码；MSVC CRT 只有 `_popen/_pclose`）。选中后
     `open_path` 读入并关联；
     `Cmd+S`（顶栏 Save 按钮同款）规范导出回写关联文件，未关联文档弹
     系统保存框（Windows 默认名 Untitled.md + .md 过滤）选定目的地。
     弹出期间本进程同步阻塞在 popen 上，等价模态；取消/出错返回空即无操作。
     Windows 上 gpui 把 platform 修饰映射到 Win 键（几乎传不进应用），
     因此 adapter 的快捷键判定在 win32 额外接受 Ctrl（`cmd_mask`）。
  2. `open dist/MdMbt.app --args <path>` 按文件启动（Finder「打开方式」
     的命令行形态），失败回退内置 demo。
  3. 剪贴板已绕开本缺口：`adapter/clipboard_stub.c`（native-stub）经
     `pbcopy`/`pbpaste` 同步读写系统剪贴板，`Cmd+C/X/V` 直接可用——见缺口 13。
  形态说明：文件选择框与剪贴板同为「绕开框架、native-stub 子进程成桥」
  （与 `moonbitlang/x/fs` 的 stub 一致），零框架链接依赖，测试可执行文件
  同样能链接；选择框 FFI 不在 `moon test` 里触发（会弹真框阻塞），只测其
  下游 `open_path`。限制：仍不支持把文件拖进窗口。

## 12. 无程序化滚动写入（虚拟窗口的遗留缺口）

滚动状态只有**读**接口 `scroll_state(view, scroll_id)`（notify-then-pull），
`ScrollHandle::set_offset` 只存在于 Rust 侧 benchmark 内部，没有对应 opcode。

- **影响**：虚拟窗口渲染（16c496f）下，用方向键把光标移出可视窗口时无法
  让视口自动跟随——只能靠用户滚动滚轮。spacer 保证滚动行程与全文等长，
  所以手动滚回去总能到。
- **绕行**：无（正面解法是给 ABI 加 `OP_SET_SCROLL_OFFSET`，本期不改 ABI）。

## 13. 自绘编辑器的 IME 与剪贴板（gpui-sys 附加面，本期已解）

自绘编辑器（缺口 2）从不提交 `OP_TEXT_INPUT`，窗口没有 input handler，
带来两个框架级缺口，本期在 vendored gpui-sys 内以**纯附加**方式补齐
（不改 ABI 版本、不改既有 opcode/事件信封，旧消费者不受影响）：

### 13a. IME 桥接（中文输入修复）

- **根因**：mac 窗口把按键转交 `NSInputContext` 后，`NSTextInputClient`
  查询全部落在 `window.input_handler`——为 None。组词无法登记 marked
  text、提交文本被丢弃，而 raw 拼音字母已经作为 `EVENT_TEXT` 插入文档，
  中文输入退化为插入拉丁字母。
- **修复**（gpui-sys）：`ImeBridge`（实现 gpui `InputHandler`）由
  `ImeBridgeProbe` 包装元素在**每次 paint** 时 `Window::handle_input`
  注册（handle_input 只允许 paint 期调用；真实 text-input widget 随后
  在自己的 paint 里覆盖注册，RFC 0003 行为不变）：
  - marked range 存 `IME_MARKED` 静态表（重注册不丢组合状态），
    mac 窗口的 `is_composing` 据此把组词期按键路由给输入法；
  - 组词更新（`replace_and_mark_text_in_range`）/取消（`unmark_text`）经
    `EVENT_ASYNC` 推 `0xEE` 标记 + UTF-8 组合文本，adapter 侧 `on_preedit`
    记录、rebuild 时经 `render.set_preedit` 渲染为挂在光标位置的一行浮动
    覆盖层 `[组词文本][光标条]`（组词文本蓝色下划线、光标条跟在其后，整行
    绝对定位不推文字；取代旧顶栏「输入中」组合条）；
  - 提交（`replace_text_in_range`）→ `EVENT_TEXT`（与普通键入同一载荷
    路径，adapter `on_text` 无需特判）+ `window.refresh()`（重绘请求，
    否则提交文本要等下一次无关帧才可见）。
- **按键分流**（gpui-sys 根 on_key_down）：当前输入源是输入法——
  `kTISPropertyInputSourceType` 为 `kTISTypeKeyboardInputMethodWithoutModes`
  或 `kTISTypeKeyboardInputMode`（`CFEqual` 身份比较）——且为无
  Ctrl/Cmd/Fn 修饰的可打印键时，不向 MoonBit 派发（不派发也不
  stop-propagation，mac 窗口把原生事件转交输入法），并补发一条未知
  named-key（id 0）维持 MoonBit 侧 swallow 代际（缺口 3），防快捷键的
  杂散 `EVENT_TEXT` 吞掉后续 IME 提交。纯布局（ABC）行为完全不变。
- **候选窗锚点**（已修复）：`InputHandler::bounds_for_range` 只能给几何，
  桥层本无应用文本度量、旧实现固定返回视口左下锚点。现由应用声明几何：
  渲染层把光标覆盖层 div `set_key("caret")`，gpui-sys 的 render_node 对带
  `caret`/`probe:*` key 的 div 包一层透明 `ProbeBoundsProbe`（仿
  `TextGlyphInset`：布局全权委托子节点，仅 prepaint 时把窗口坐标矩形记入
  `PROBE_BOUNDS` 表，见缺口 14），`bounds_for_range` 返回 "caret" 项——mac
  窗口据此换算屏幕 firstRect，候选窗/组词预览跟随光标。探针是纯附加 Rust
  改动（不动 C ABI），key 契约由 render_wbtest 断言锁定。
- **教训（已修复）**：输入源判定最早用 `kTISPropertyInputSourceID` 的
  `com.apple.inputmethod.` 前缀，漏掉第三方输入法（搜狗 `com.sogou.*`、
  微信 `com.tencent.inputmethod.wetype`）——可打印键被 raw `typed_text` 与
  IME commit 各投递一次，字母/数字**双发**，WeType「中英混输」组词首字
  重复（"nihao"→"n你好"）也源于此。改按输入源 TYPE 判定后一并修复。

### 13b. 剪贴板（native-stub）

`adapter/clipboard_stub.c`（moon.pkg `native-stub`）用
`popen(pbcopy/pbpaste)` 同步读写纯文本剪贴板，导出
`gpui_clipboard_write_text` / `gpui_clipboard_read_len` /
`gpui_clipboard_read_copy` 三个 C 符号。选 gpui `App::read_from_clipboard`
而非直接 NSPasteboard objc 调用的原因：C 导出拿不到 App 上下文（INPUT_MIRROR
同一约束），而队列+下一帧排水是异步的；native-stub 与 `moonbitlang/x/fs`
的形态一致，测试可执行文件同样能链接。`Cmd+C` 复制选区
（`core::doc_selection_text`）、`Cmd+X` 剪切（复制+删选区）、`Cmd+V`
粘贴（直接走 `doc_paste`，多行自动拆段）。

### 13c. 顶栏

窗口顶部常驻一排：左侧应用名 + 当前文件名（未关联显示 Untitled.md），
右侧 New / Open / Save 按钮（New 清空为新文档，Open/Save 与 Cmd+O/Cmd+S
同一路径；打开/保存走系统文件选择框，见缺口 11）。

## 14. 鼠标事件与几何回传通道（拖拽选区，本期已解）

框架只有无坐标的 click（缺口 1）与滚轮。本期在 gpui-sys 里加了两条**纯附加**
通道（不动 C ABI，不动 MoonBit 绑定层的既有语义），实现鼠标拖拽选区与词内
像素级落点：

- **鼠标回传（推）**：`FfiView::render` 的根 div 上挂 `on_mouse_down(Left)`
  / `on_mouse_up(Left)` / `on_mouse_move`（仅 `dragging()` 时转发），把事件
  封装成 EVENT_ASYNC 负载 `[0xEF, phase, x i32LE, y i32LE]`（phase 0 按下/
  1 拖拽移动/2 释放，坐标取整像素避开 f32 位解码）。既有 click 通道照常
  合成、照常送达，互不干扰。
- **几何拉取（拉）**：渲染层给每个 token / 行尾空白区 div 挂
  `set_key("probe:t{gen}:{unit}:{ti}")` / `("probe:x…")`；render_node 对
  `caret` / `probe:*` key 的 div 包透明 `ProbeBoundsProbe`，prepaint 时把
  真实布局矩形（窗口坐标）写入 `PROBE_BOUNDS: HashMap<String,[f32;4]>`。
  MoonBit 经 `gpui_probe_rect(key, out)` 拉回，行匹配 + 区间内水平插值得到
  插入点（`adapter/hit.mbt`）。
- **失效策略**：key 带代号 `gen`（每次 rebuild 递增）；root 的首个零尺寸
  子节点带 `probe:clear`，prepaint 命中即清表——读到的永远是当帧几何，
  滚动/重建后不会拿旧矩形命中错行。
- **合成 click 的协调**：按下已按像素比例精确落点，紧随其后的合成 token
  click 会被 `mouse_placed`（未拖拽）/`drag_moved`（拖过）一次性压制——
  否则粗粒度的 token 起点定位会覆盖精确定位、或抹掉刚拖出的选区。

**教训（重要）**：

- **探针嵌套死锁**：`ProbeBoundsProbe::prepaint` 若在持 `PROBE_BOUNDS` 锁
  时调 `child.prepaint`，嵌套探针（token div 里含 caret 覆盖层，两者都带
  key）会二次加锁，std Mutex 不可重入 → 启动首帧即死锁、窗口永不出现。
  锁必须收窄到「记录自己」为止，再放锁下钻。
- **moon 增量不追踪外部 staticlib**：改完 gpui-sys 的 Rust 代码后
  `moon build` 提示 "up to date"，**不会重新链接**新的 libgpui_sys.a，
  dist 里跑的还是旧二进制。改过 Rust 侧必须 `moon clean` 再构建（或删
  `_build`），否则一切 GUI 验证都在测旧版本。
