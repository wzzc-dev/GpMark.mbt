# 目标：用 MoonBit 实现基于 GPUI 的 Markdown 所见即所得编辑器核心

## 一句话目标

在 /Volumes/Data/Code/moon/md_mbt 中，用 MoonBit native 实现一个 Markdown 所见即所得（WYSIWYG）编辑器的**可复用核心库**（md-core），底层 UI 通过 [nakake/gpui-moonbit](https://github.com/nakake/gpui-moonbit) 的 Rust/C FFI 绑定驱动 Zed 的 GPUI 渲染，编辑器架构（块树模型、解析/序列化、双编辑模式、源文回退）参考 [manyougz/velotype](https://github.com/manyougz/velotype)。

## 背景与依赖事实（已调研，可直接采信）

- **gpui-moonbit** 提供 MoonBit native → Rust staticlib → GPUI 的完整链路：
  - 渲染：MoonBit 通过 `build_tree(view, cb)` 一次性提交命令缓冲（length-delimited opcode 流），GPUI 持有 retained node tree。可用 opcode 包括 `OP_DIV / OP_TEXT / OP_TEXT_RUN / OP_TEXT_INPUT / OP_SET_FLEX / OP_SET_PADDING / OP_SET_BORDER / OP_SET_TEXT_SIZE / OP_SET_FONT_WEIGHT / OP_SET_LINE_HEIGHT / OP_SET_OVERFLOW / OP_SET_ON_CLICK / OP_SET_SCROLL_ID / OP_SET_FOCUSABLE` 等（见 `gpui-sys/abi.toml`）。
  - 事件：Rust 回调 `dispatch_entry(abi_version, event_kind, view, data_a, data_b)`，消费者注册自己的 dispatch（`register_dispatch`，run_window 之前、主线程），通常委托给 `framework_dispatch`。事件种类：`EVENT_CLICK / EVENT_KEY / EVENT_TEXT / EVENT_NAMED_KEY / EVENT_ASYNC / EVENT_INPUT_CHANGED / EVENT_INPUT_SUBMIT / EVENT_SCROLL`。
  - dispatch 返回 1 触发整树重建；文本负载经 `gpui_event_copy_text` 拷贝。
  - 构建必须走它的 build driver（`build.sh`），不能裸跑 `cargo build` / `moon build`；macOS 上键盘输入需要 `.app`  bundle（build.sh 默认产出）。
  - 消费方组织约束：`link` 相关 import 与 `fn main` 必须隔离在独立 main 包，应用主体包不 import `link`，否则 `moon test` 无法运行——**这决定了编辑器核心必须是纯逻辑包，GUI 适配层单独成包**。
- **velotype** 的核心架构结论：以原生**块树**为运行时模型；导入时把稳定支持的 Markdown 解析为结构化块，保存时块树序列化回规范化 Markdown；对解析不稳定的语法保留原始源文（可见、可编辑）作为回退；支持 WYSIWYG 渲染编辑与源文编辑双模式。

## 范围（做什么）

### 1. md-core 纯逻辑包（主体工作，`moon test` 全覆盖，不依赖任何 GUI/FFI）

- **文档模型**：块树类型定义——heading(1-6)、paragraph、list（有序/无序/任务列表，支持嵌套）、blockquote、code block（含语言标记）、table、thematic break、image、以及 `Raw(text)` 源文回退块；行内节点——text、bold、italic、strikethrough、inline code、link、image、footnote 引用。
- **Markdown 解析器**：MoonBit 实现，行级块解析 + 行内解析；对无法稳定 round-trip 的构造落入 `Raw` 块保留原文。
- **规范化序列化**：块树 → 规范化 Markdown 文本；`parse → serialize → parse` 幂等（对稳定子集）。
- **编辑内核**：块级操作（插入/删除/分裂/合并/类型转换，如段落↔标题、段落↔列表项）、行内样式 toggle（在选区上应用/移除 bold、italic 等）、选区与光标模型（块位置 + 字符偏移，支持跨块选区）。
- **撤销/重做**：基于操作历史或快照，undo/redo 语义正确且不破坏选区不变量。
- 可选加分：增量重解析（仅重解析受影响块）。

### 2. GPUI 适配层（独立包，import gpui bindings）

- 块树 → gpui 节点树渲染：每个块一个 div；`OP_TEXT_RUN` + 样式 opcode 表达行内样式（粗体、斜体、行内代码底色、链接色）；代码块用等宽字体 + 背景；列表缩进；表格边框。
- dispatch 接线：命名键（Enter/Backspace/方向键）、`EVENT_TEXT`/`EVENT_INPUT_CHANGED` 驱动编辑内核，返回是否变更以驱动重建；滚动经 `OP_SET_SCROLL_ID` + `EVENT_SCROLL`。
- 已知限制要在代码与文档中明示：gpui-moonbit 的文本输入能力有限，若无法实现真正的行内 caret 编辑，采用「块级 editing：活动块切换为 text_input，其余块渲染为富文本」的策略，并把该限制记录进 README。

### 3. Demo + 构建

- `examples/` 或 `cmd/main`：打开窗口渲染一个内置示例文档，可点击块进入编辑、打字、Enter 换块、撤销重做。
- 顶层构建脚本复用 gpui-moonbit 的 build driver 流程；macOS 产出 .app。

## 非目标（不做什么）

- 不做 velotype 级别的完整功能：主题市场、i18n、HTML/PDF 导出、图片托管、工作区/大纲、远程图片加载。
- 不修改 gpui-moonbit 的 C ABI（abi.toml / gpui-sys）；如发现绑定缺口，记录到 `docs/framework-gaps.md` 并在核心层规避。
- 不追求 IME 完整性与跨平台 CI；本机 macOS arm64 跑通即可。

## 验收标准（goal 完成的判定）

1. `moon test` 在核心包全绿，覆盖：解析、序列化、round-trip 幂等、块操作、样式 toggle、undo/redo、Raw 回退。
2. 经 build driver 构建成功，demo 在 macOS 上启动窗口，渲染示例 Markdown（标题/列表/任务列表/引用/代码块/表格/行内样式/链接），能进行块级编辑并撤销。
3. README 说明架构分层（core / adapter / demo）、如何构建运行、已知限制。
4. 编辑核心不 import 任何 FFI/link 相关包（可用脚本或包结构检查验证）。

## 建议执行顺序

1. clone gpui-moonbit，跑通其 counter example，确认本机工具链与 build driver 可用（此步失败先修环境）。
2. 搭 MoonBit 包结构（core / adapter / main 三包，main 包只管 link 与 run_window）。
3. 先实现 core 的类型 + 解析 + 序列化 + 测试（纯 MoonBit，迭代最快）。
4. 再实现编辑操作与 undo/redo + 测试。
5. 最后接 GPUI 适配层与 demo，用真实运行验证渲染与事件回路。
