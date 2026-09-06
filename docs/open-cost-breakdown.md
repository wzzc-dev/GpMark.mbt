# GpMark 打开（首次可交互）成本分解与结论

对 `open` 场景首次可交互耗时（stress.md 基线 165.02 ms）的量化归因、
gpui-sys 层可动性评估与上游建议。测量口径与基准协议完全一致：窗口期仍由
`gpui_run_window_benchmark` 的 `started = Instant::now()` 起点到首帧
paint 完成锚点，本文只在该窗口**内部**加了带开关的阶段打点，未移动任何
计时边界。

## 测量手段

1. **阶段打点**：`third_party/gpui-moonbit/gpui-sys/src/lib.rs` 中的
   `open_trace_mark`（`GPUI_OPEN_TRACE=1` 才输出 stderr，关闭时零成本，
   纯附加、不改 C ABI）。`first_paint` 在 `open_window` 调用内部触发，
   证明首次绘制是 `cx.open_window` 同步完成的一部分。
2. **采样**：`xcrun sample` 附加到 scroll 场景进程（open 场景存活太短采
   不到栈），按一次性初始化符号过滤调用图归因。

## 阶段分解（stress.md open，debug 构建，干净进程）

| 阶段 | 耗时（约） | 归属 |
| --- | --- | --- |
| `Application::new()` | 35 ms | gpui 框架（NSApplication 获取、平台服务、全局执行器） |
| `.run()` → 应用闭包被调度（NSApp finishLaunching + 首轮事件路由） | 22 ms | AppKit |
| `spawn_drain_pump` | 0.4 ms | gpui-sys |
| `cx.open_window`（含首帧，`first_paint` 在其中触发） | 104 ms | gpui / AppKit / Metal |
| 收尾（基准帧调度 + `cx.activate(true)`） | 6–7 ms | gpui-sys + AppKit |
| **合计 = first_interactive** | **≈165 ms** | |

fixture 无关性已验证：small 与 stress 的 `open_window` 段差异只到噪声
量级（各 fixture 的 first_interactive 差 <10 ms），即该成本与文档大小、
树规模基本无关，是**固定的框架初始化开销**。

`open_window` 内部按采样权重归因（同一次采样总权重 435，供相对占比参
考，不是绝对毫秒）：NSWindow `initWithContentRect` ≈ 82，
`Window::draw` 首帧（taffy flexbox 全树布局 + 绘制）≈ 30，
`makeKeyAndOrderFront`（NSDisplayLink / CALayer 显示初始化）≈ 6，
MetalRenderer 创建/首次提交、字体 `load_family`、字形栅格化均为一次性
低权重（字体加载仅 ~1，与“字形栅格化主导首帧”的预设不符）。

**构建口径注意**：`moonbit-bindings/build.py` 仅在 Windows 用
`--release`，macOS 上 gpui-sys 以 debug 构建，框架侧绝对值有放大；基线
与本轮为同一构建，前后对比不受影响，但绝对毫秒数应视为上界。

## B2：gpui-sys 纯附加优化的评估结论

窗口期内由 gpui-sys 自身代码执行的工作只有两处：

- `spawn_drain_pump`：**0.4 ms**，延迟化无收益，且事件泵推迟会改变事件
  注入时序（协议行为），否决。
- 收尾段（基准帧调度 + `cx.activate(true)`）：约 6–7 ms。其中激活是窗口
  生命周期语义的一部分，把它挪到首帧之后只是把真实工作移出计时锚点，违
  反“所有延后工作在真实应用中仍会完整执行”的口径精神，且 4% 收益不成比
  例，否决。

其余 ~160 ms 全部发生在 gpui/AppKit/Metal 的框架调用内部。**结论：
gpui-sys 层不存在有意义的纯附加优化项，本轮不实施。**

## B3：框架内部成本的上游建议（gpui 0.2.2，不改动 vendored 依赖）

按预期收益排序：

1. **`open_window` 同步完成首帧（~104 ms 的主体）**。`Window::new` 内
   联了 NSWindow 创建、`makeKeyAndOrderFront`（连带 DisplayLink/显示初
   始化）与 MetalRenderer 首帧绘制。建议：
   - MetalRenderer 惰性创建到首帧、管线编译（含 8 条默认管线的
     `makeRenderPipelineState`）异步化，未完成前以纯色提交首帧；
   - 提供 `open_window` 的 “ordered-out until first frame” 选项：先
   建窗、首帧就绪后再 `makeKeyAndOrderFront`，把 DisplayLink 初始化移出
   关键路径。
2. **`Application::new()`（~35 ms）**：平台服务与全局执行器改为首次使用
   惰性初始化；`sharedApplication` 前的重复环境探测（屏幕/字体源查询）可
   推迟。
3. **NSApp `finishLaunching`（~22 ms）**：在首个窗口打开前跳过主菜单最
   大化/激活相关处理，允许 headless/benchmark 路径显式精简启动菜单。
4. **首帧 taffy 全树布局（首帧绘制的最大子项）**：支持根节点布局结果快
   照（同一尺寸与树版本下跳过重算）。
5. **构建口径**：上游文档若报告绝对启动时间，应使用 `--release`；debug
   的 gpui 会把上述所有项放大数倍。

## 复现方式

```sh
GPUI_OPEN_TRACE=1 UI_BENCHMARK_ADAPTER_NAME=gpmark \
  bench/adapters/gpmark/dist/gpmark-markdown-editor \
  --ui-benchmark "$PWD/data/stress.md" open
# stderr: gpui-open-trace application_new=… / nsapp_ready=… / drain_pump=… /
#         open_window=… / first_paint=… / startup_tail=…（均为自起点累计毫秒）
```
