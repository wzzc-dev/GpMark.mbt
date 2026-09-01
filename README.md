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
  history.mbt  快照式 undo/redo（含选区恢复）
  mdparse.mbt  Markdown 解析（块级 + 行内）
  mdwrite.mbt  规范化序列化；对稳定子集保证 parse→serialize→parse 幂等
  strutil.mbt  字符串工具（本工具链 String API 的垫片）

adapter/   GPUI 适配层（独立包，import core + gpui-bindings，不 import link 包）
  render.mbt   块树 → gpui 命令缓冲（rich_text 多 run 样式、光标段、选区高亮），
               纯字节构造，无 FFI，可被 moon test 直接验证
  app.mbt      编辑器状态、事件分发（键入/回车/删除/方向键/Cmd+Z·Shift+Z/Cmd+A）、
               点击聚焦、rebuild/dispatch 入口

main/      装配：register_dispatch → build_tree → run_window（唯一链接 Rust staticlib 的包）
selftest/  无 GUI 自检：build_tree(0) + debug_dump_text 回读 + 事件注入，走真实 FFI
```

## 构建与运行

前置：MoonBit 工具链（本项目验证于 `moon 0.1.20260824`）、Rust（aarch64-apple-darwin）、
Xcode CLT。gpui-moonbit 已 vendored 在 `third_party/`。

```sh
moon test                     # core + adapter 单元测试（30 个，无 GUI）
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
回读断言；随后注入 Click/Enter/Cmd+Z 事件走真实 `dispatch` 入口，验证
「事件 → 编辑内核 → 脏标记 → 重渲染 → 提交」闭环与 undo。

## 操作方式

| 操作 | 行为 |
| --- | --- |
| 直接键入 | 在当前光标处插入，继承左侧 run 的样式 |
| 点击任意块 | 聚焦该块，光标置于块尾（框架限制，见 docs/framework-gaps.md） |
| Enter / Backspace / Delete | 块内拆分 / 跨块合并 / 前向删除 |
| ←→↑↓ Home End，Shift 扩展选区 | 方向键中 ↑↓ 为相邻编辑单元近似 |
| Cmd+Z / Cmd+Shift+Z | 撤销 / 重做（快照式，含选区恢复） |
| Cmd+A | 全文档选择 |

## 已知限制

完整列表见 [docs/framework-gaps.md](docs/framework-gaps.md)，摘要：

- 点击不带坐标 → 点击块只能把光标放到块尾，不能点哪停哪。
- 无文本度量接口 → ↑↓ 是"相邻编辑单元"近似，不跟视觉软换行走。
- 光标是渲染的“▍”字符段，不闪烁；无 IME 内联候选窗。
- 鼠标拖拽选区、右键菜单：框架单事件入口无对应事件，未实现。
- 导出时行内特殊字符（如 `*`）不做反斜杠转义，含字面样式符号的文本
  往返可能有歧义；Raw 块本身零损失。
- 仅 macOS arm64 本地验证；无跨平台 CI。
