# md_mbt — GPUI 后端的 Markdown 所见即所得编辑器核心

MoonBit 实现的可复用 Markdown WYSIWYG **编辑核心**，渲染后端为
[gpui-moonbit](https://github.com/nakake/gpui-moonbit)（MoonBit → C FFI →
Rust staticlib → Zed GPUI）。架构参考
[velotype](https://github.com/manyougz/velotype)：块树运行时模型 +
稳定 Markdown 子集 ↔ 块树双向转换 + 不稳定语法 Raw 原样回退。

## 分层

```
core/      纯逻辑编辑内核（零 GUI / 零 FFI 依赖，core/moon.pkg 无任何 import）
  mark.mbt     Marks：粗体/斜体/删除线/行内代码/链接 位样式
  inline.mbt   扁平样式 run 数组 + 原子节点（Link/Image/Footnote）与切分/插入/样式 toggle
  block.mbt    块树类型：Heading(1-6)/Paragraph/List(有序·无序·任务·嵌套)/Quote/
               CodeBlock(lang)/Table/ThematicBreak/独立 Image + Raw 回退
  unit.mbt     编辑单元（collect_units）与 CoW 写路径（collect → patch）
  edit.mbt     编辑内核：insert/delete/split/merge/块类型转换/样式 toggle/
               光标与跨块选区模型（Caret/Sel）
  rules.mbt    输入规则引擎：「标记+空格」转块、Enter 规则（围栏/分隔线/
               空列表退出）、ensure_trailing、词移动、多行粘贴拆分、
               任务勾选、缩进/反缩进、表格加删行、代码块语言循环
  reparse.mbt  活行内转换：serialize→parse 幂等往返 + plain→source 偏移映射，
               键入的字面 `**x**`/`` `x` ``/`~~x~~`/`[t](u)` 原地变样式
  history.mbt  快照式 undo/redo（含选区恢复）；apply_text 合并窗口
               （同单元连续键入/退格折叠为一次撤销，velotype 同款语义）
  mdparse.mbt  Markdown 解析（块级 + 行内）
  mdwrite.mbt  规范化序列化；对稳定子集保证 parse→serialize→parse 幂等
  strutil.mbt  字符串工具（本工具链 String API 的垫片）

adapter/   GPUI 适配层（独立包，import core + gpui-bindings，不 import link 包）
  render.mbt   块树 → gpui 命令缓冲：逐编辑单元可点击 div（含任务框独立点击区）、
               rich_text 多 run 样式、光标段、选区高亮、表头加粗、代码块 lang 标签；
               纯字节构造，无 FFI，可被 moon test 直接验证
  app.mbt      编辑器状态、事件分发（键入+空格规则+活转换、Enter 规则链、快捷键、
               逐单元点击/任务框点击）、动态增长的 handler id 池、
               可滚动容器（OVERFLOW_SCROLL + set_key 跨重建保位）、
               rebuild/dispatch 入口

main/      装配：register_dispatch → build_tree → run_window（唯一链接 Rust staticlib 的包）
selftest/  无 GUI 自检：build_tree(0) + debug_dump_text 回读 + 事件注入，走真实 FFI
```

## 构建与运行

前置：MoonBit 工具链（本项目验证于 `moon 0.1.20260824`）、Rust（aarch64-apple-darwin）、
Xcode CLT。gpui-moonbit 已 vendored 在 `third_party/`。

```sh
moon test                     # core + adapter 单元测试（47 个，无 GUI）
moon build --target native    # 首次会由 link 包 prebuild 触发 cargo 构建 libgpui_sys.a

./build.sh                    # 确保 staticlib + 构建所有 native 目标
./bundle.sh                   # 打包 dist/MdMbt.app（macOS bundle，键盘投递需要）
open dist/MdMbt.app           # 启动编辑器 demo
```

自检（真实 FFI 链路，可在无窗口环境跑）：

```sh
moon build --target native
./_build/native/debug/build/selftest/selftest.exe   # 末行输出 SELFTEST PASS
```

selftest 验证：解析 demo 文档 → 渲染全块词汇 → FFI 提交 → `debug_dump_text`
回读断言；随后注入 Click（单元/任务框）/Enter/Cmd+Z/Cmd+A/Cmd+B 事件走真实
`dispatch` 入口，并直接驱动空格规则与活行内转换的键入序列，验证
「事件 → 规则 → 编辑内核 → 脏标记 → 重渲染 → 提交」闭环、勾选切换与 undo。

## 操作方式

### 键入即转换（velotype 式输入规则）

| 键入 | 效果 |
| --- | --- |
| `# ` ~ `###### ` + 空格 | 当前段 → 对应级别标题（标题里敲可改级别） |
| `- ` / `* ` / `+ ` | → 无序列表 |
| `N. ` | → 有序列表（起始号 N） |
| `> ` | → 引用块 |
| `[ ] ` / `[x] ` | → 任务列表（未/已勾选） |
| 行尾 ` ```lang ` + Enter | → 代码块（空代码块自动补可打字段落） |
| 独占行 `---`/`***`/`___` + Enter | → 分隔线 |
| 空列表项上按 Enter | 退出列表（末项整表转段落） |
| 键入 `**x**`、`` `x` ``、`~~x~~`、`[t](u)` | 触发字符落定后原地变样式（活行内转换） |

### 快捷键

| 操作 | 行为 |
| --- | --- |
| 直接键入 | 当前光标处插入，继承左侧 run 样式；连续键入合并为一次撤销 |
| 点击单元（段落/列表项/表格格…） | 光标落到该单元尾（框架无坐标，见 framework-gaps） |
| 点击 ☑/☐ 任务框 | 勾选切换 |
| Enter / Backspace / Delete | Enter 先走规则再拆分；格首退格/格尾前删只移光标（防幽灵格） |
| Alt+Enter | 表格：当前行下方加一行 |
| Cmd+Enter | 代码块出逃：块后插入新段落并聚焦 |
| ←→↑↓ Home End，Shift 扩展选区 | ↑↓ 为相邻编辑单元近似 |
| Alt+←/→（Shift 扩展） | 词级移动（中文逐字） |
| Cmd+B / Cmd+I / Cmd+E | 选区/落点样式：粗体 / 斜体 / 行内代码 |
| Cmd+Shift+X | 删除线 |
| Cmd+[ / Cmd+] | 列表项反缩进（脱离列表）/ 缩进（并入前项子列表） |
| Cmd+Shift+L | 代码块语言标签循环（moonbit/rust/python/…） |
| Cmd+Z / Cmd+Shift+Z | 撤销 / 重做（快照式，含选区恢复） |
| Cmd+A | 全文档选择 |
| 多行粘贴 | 按行拆分为多段，逐行跑空格规则 |
| 鼠标滚轮 | 全文档滚动（滚动位置跨重渲染保持） |

## 已知限制

完整列表见 [docs/framework-gaps.md](docs/framework-gaps.md)，摘要：

- 点击不带坐标 → 点击已细化到「编辑单元」并把光标放到该单元尾，
  不能点哪停哪（单元内像素级定位被框架封死）。
- Tab 被框架焦点遍历吃掉 → 缩进/反缩进用 Cmd+] / Cmd+[。
- 无文本度量接口 → ↑↓ 是"相邻编辑单元"近似，不跟视觉软换行走。
- 光标是渲染的“▍”字符段，不闪烁；无 IME 内联候选窗。
- 鼠标拖拽选区、右键菜单：框架单事件入口无对应事件，未实现。
- 导出时行内特殊字符（如 `*`）不做反斜杠转义，含字面样式符号的文本
  往返可能有歧义；Raw 块本身零损失。
- 仅 macOS arm64 本地验证；无跨平台 CI。
