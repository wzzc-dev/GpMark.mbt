# md_mbt — GPUI 后端的 Markdown 所见即所得编辑器核心

MoonBit 实现的可复用 Markdown WYSIWYG **编辑核心**，渲染后端为
[gpui-moonbit](https://github.com/nakake/gpui-moonbit)（MoonBit → C FFI →
Rust staticlib → Zed GPUI）。架构参考
[velotype](https://github.com/manyougz/velotype)：块树运行时模型 +
稳定 Markdown 子集 ↔ 块树双向转换 + 不稳定语法 Raw 原样回退。

## 分层

工程为 moon.work 多模块工作区（moon.mod.json + moon.pkg），四个成员模块，
依赖只能单向：core ← adapter ← main / selftest。

```
core/      独立模块 mdmbt/core：纯逻辑编辑内核（零 GUI / 零 FFI 依赖，
           moon.mod.json 无 deps、moon.pkg 无任何 import——验收标准 4 可包结构直查）
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

adapter/   独立模块 mdmbt/adapter：GPUI 适配层（import core + gpui-bindings，
           不 import link，故可 `moon test`）
  render.mbt   块树 → gpui 命令缓冲：文本单元按 token（CJK 逐字/拉丁逐词）拆成
               可点击 div、任务框独立点击区、rich_text 多 run 样式、光标段、
               选区高亮、表头加粗、代码块 lang 标签、表格定宽列；
               虚拟窗口：估算高度前缀和只提交可视块 ±800px，窗口外 spacer 撑滚动行程；
               纯字节构造，无 FFI，可被 moon test 直接验证
  textlayout.mbt 点击定位布局器：token 分词 + 按字符类别的宽度估算 + 贪心折行
               （框架无坐标/度量，「点哪停哪」在 MoonBit 侧自算）
  hit.mbt      鼠标坐标命中测试：渲染层为每个 token/行尾区挂探针 key，gpui-sys
               paint 时记录真实布局矩形，经 gpui_probe_rect 拉回按行/列映射为
               插入点——拖拽选区与按下落点都走这里（词内像素级精确）
  clipboard.mbt / clipboard_stub.c
               系统剪贴板同步读写（native-stub 经 pbcopy/pbpaste，
               Cmd+C/X/V；与 moonbitlang/x/fs 的 stub 同一形态）
  filedialog.mbt / filedialog_stub.c
               系统文件选择框（native-stub 经 osascript choose file /
               choose file name，即 NSOpenPanel/NSSavePanel；Cmd+O 打开、
               未关联文档 Cmd+S 弹保存框另存）
  app.mbt      编辑器状态、事件分发（键入+空格规则+活转换、Enter 规则链、快捷键、
               逐单元点击/任务框点击、顶栏按钮 + Cmd+O/Cmd+S 系统文件对话框 +
               打开/保存文件、
               IME 组词内联预览、剪贴板）、
               滚动事件拉取（scroll_state）驱动虚拟窗口滑动、
               动态增长的 handler id 池、
               可滚动容器（OVERFLOW_SCROLL + set_key 跨重建保位）、
               rebuild/dispatch 入口

main/      独立模块 mdmbt/main：demo 装配，register_dispatch → build_tree →
           run_window（import link 链接 Rust staticlib，仅 main.mbt）
selftest/  独立模块 mdmbt/selftest：无 GUI 自检，build_tree(0) + debug_dump_text
           回读 + 事件注入，走真实 FFI

gpui-moonbit 以 vendored 路径依赖引入（third_party/，git submodule），不是工作区
成员——根目录 `moon test` 因此不会扫到它的示例与测试。
```

## 构建与运行

前置：MoonBit 工具链（本项目验证于 `moon 0.1.20260824`）、Rust（aarch64-apple-darwin）、
Xcode CLT。gpui-moonbit 已 vendored 在 `third_party/`。

```sh
moon test                     # core + adapter 单元测试（68 个，无 GUI）
moon build --target native    # 首次会由 link 包 prebuild 触发 cargo 构建 libgpui_sys.a

./build.sh                    # 确保 staticlib + 构建所有 native 目标
./bundle.sh                   # 打包 dist/MdMbt.app（macOS bundle，键盘投递需要）
open dist/MdMbt.app           # 启动编辑器 demo
open dist/MdMbt.app --args <file.md>   # 按文件启动：直接打开该 Markdown 文件（失败回退 demo）
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

### 顶栏

窗口最上面一排：左侧显示当前文件名（未关联文件时 `Untitled.md`），右侧为
**New / Open / Save** 按钮——New 清空为新文档，Open 弹出系统文件选择框
（同 Cmd+O），Save 规范回写关联文件（未关联时弹系统保存框另存，同 Cmd+S）。

### 中文输入（IME）

选择中文输入法直接打字即可：组词期按键自动让给输入法，组词文本以蓝色
下划线浮动显示在光标处，光标条紧跟组词文本之后（整行不推文字、不占排版
宽度），候选上屏后提交文本插入光标处；输入法候选窗锚定在组词文本下方，
跟随光标移动。输入源按 TIS 类型（input method /
input mode）判定，第三方输入法（搜狗、微信等）与系统拼音行为一致，不会
出现字母/数字双发（见 docs/framework-gaps.md §13a）。

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
| 点击文本任意处 | 光标落在点击处：经探针几何按像素比例插值，词内可精确到字（见 framework-gaps §14）；点击段落间大空白不动光标 |
| 鼠标左键拖拽 | 选区从按下点扩到当前位置（像素级命中；跨块、跨表格连续） |
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
| Cmd+C / Cmd+X / Cmd+V | 复制 / 剪切 / 粘贴（系统剪贴板；粘贴多行按行拆段） |
| Cmd+O | 弹出**系统文件选择框**打开 Markdown 文件（NSOpenPanel；取消无操作） |
| Cmd+S | 规范导出回写（文档由文件打开后关联）；未关联文档弹系统保存框选定目的地 |
| 多行粘贴 | 按行拆分为多段，逐行跑空格规则 |
| 鼠标滚轮 | 全文档滚动（滚动位置跨重渲染保持） |

## 已知限制

完整列表见 [docs/framework-gaps.md](docs/framework-gaps.md)，摘要：

- 点击文本/拖拽选区的坐标经「渲染层探针 key → gpui-sys 回传布局矩形」获得
  （framework-gaps §14），像素级精确；但只覆盖 token 渲染的单元——代码块、
  表格线框等非 token 区域仍按单元落点（点代码块落块尾）。
- 折行按固定 960px 估算宽度手动进行 → 窗口缩放不会重新折行。
- Tab 被框架焦点遍历吃掉 → 缩进/反缩进用 Cmd+] / Cmd+[。
- 无文本度量接口 → ↑↓ 是"相邻编辑单元"近似，不跟视觉软换行走；折行宽度
  为字符类别估算值，与实际字体度量有 ±10% 级别的出入。
- 文本区光标是绝对定位的 2px 光标条（零宽、不推文字），不闪烁；代码块内
  光标仍是“▏”字符段（会占一格宽）；IME 组词文本浮动渲染在光标处而非
  真实 inline 重排（候选窗经 key="caret" 几何回传已跟随光标，见
  docs/framework-gaps.md §13）。
- 右键菜单未实现（桥层鼠标回传只订了左键按下/拖拽移动/释放三类事件）。
- 文件拖拽进窗口不支持 → 打开/保存走系统文件选择框（native-stub 经
  osascript choose file 弹出 NSOpenPanel/NSSavePanel，framework-gaps §11），
  或按文件启动；剪贴板经 native-stub 直接读写系统剪贴板（framework-gaps §13b）。
- 虚拟窗口下方向键把光标移出可视区时视口不自动跟随（无滚动写入 API，
  framework-gaps §12）；滚轮可达任意位置。
- 导出时行内特殊字符（如 `*`）不做反斜杠转义，含字面样式符号的文本
  往返可能有歧义；Raw 块本身零损失。
- 仅 macOS arm64 本地验证；Linux x86_64 / Windows x64 由 GitHub Actions CI
  构建验证（能编译、能产出二进制），未做交互验证。非 macOS 上文件对话框
  降级为「取消」（osascript 仅 macOS），剪贴板 Windows 尽力而为、Linux 不可用
  （见 adapter/*_stub.c）。Windows 要求 Win10 1703+（DirectWrite 文本系统依赖
  IDWriteFactory5）；gpui-sys 在 Windows 上以 release 构建（debug 档的 gpui
  启动时会去编译机源码头文件路径现编 shader，产物换机即挂）。
