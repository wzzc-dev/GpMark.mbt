/// 基准模式（md_editor gpui2 适配器用）：headless-render 诊断行与真实窗口
/// ui-frame 帧循环。协议与 md_editor 的 gpui v1 适配器逐字段一致，仅适配器
/// 名不同（ui-frame 行由 fork 的 Rust 报告在 UI_BENCHMARK_ADAPTER_NAME 下打
/// 上 "gpui2"；headless 行在这里直接输出）。

///|
fn now_ms() -> Double {
  @env.now().reinterpret_as_int64().to_double()
}

///|
fn percentile(values : Array[Double], ratio : Double) -> Double {
  let sorted = values.copy()
  sorted.sort()
  sorted[((sorted.length() - 1).to_double() * ratio).round().to_int()]
}

///|
fn summary(
  scenario : String,
  samples : Array[Double],
  document_load_ms : Double,
) -> String {
  let mean = samples.fold(init=0.0, fn(total, value) { total + value }) /
    samples.length().to_double()
  "{\"adapter\":\"gpui2\",\"measurement_scope\":\"headless-render\",\"scenario\":\"" +
  scenario +
  "\",\"frame_work_samples_ms\":[" +
  samples.map(value => value.to_string()).join(",") +
  "],\"frame_interval_samples_ms\":[],\"input_to_visible_samples_ms\":[" +
  (if scenario == "input" { samples.map(value => value.to_string()).join(",") } else { "" }) +
  "],\"offscreen_samples_ms\":[" + samples.map(_ => "null").join(",") +
  "],\"readback_samples_ms\":[" + samples.map(_ => "null").join(",") +
  "],\"offscreen_readback_samples_ms\":[" + samples.map(_ => "null").join(",") +
  "],\"frame_work_ms\":" +
  mean.to_string() +
  ",\"frame_interval_ms\":null,\"input_to_visible_ms\":" +
  (if scenario == "input" { mean.to_string() } else { "null" }) +
  ",\"offscreen_ms\":null,\"readback_ms\":null,\"offscreen_readback_ms\":null,\"frame_work_p95_ms\":" +
  percentile(samples, 0.95).to_string() +
  ",\"frame_interval_p95_ms\":null,\"input_to_visible_p95_ms\":" +
  (if scenario == "input" { percentile(samples, 0.95).to_string() } else { "null" }) +
  ",\"dropped_display_frames\":" + "0" +
  ",\"first_interactive_ms\":null,\"document_load_ms\":" +
  document_load_ms.to_string() +
  ",\"viewport\":{\"width\":1280,\"height\":800},\"font\":\"system-ui 16px\",\"line_height\":1.55,\"overscan\":3,\"virtual_row_height\":66}"
}

///|
/// 纯逻辑诊断：解析 + 规范化序列化往返（headless-render，无窗口、无 FFI 提交）。
pub fn run_headless_benchmark(fixture : String, scenario : String) -> Unit {
  let source = @fs.read_file_to_string(fixture) catch {
    _ => {
      println(
        "{\"adapter\":\"gpui2\",\"status\":\"error\",\"error\":\"fixture unreadable\"}",
      )
      return
    }
  }
  let samples : Array[Double] = []
  let count = if scenario == "open" {
    1
  } else if scenario == "scroll" {
    120
  } else {
    10
  }
  for index in 0..<count {
    let value = if scenario == "input" {
      source + index.to_string()
    } else {
      source
    }
    let started = now_ms()
    let blocks = @core.doc_ensure(@core.parse_doc(value))
    let round_trip = @core.serialize_doc(blocks)
    if round_trip.length() < 0 {
      abort("unreachable")
    }
    samples.push((now_ms() - started).max(0.0))
  }
  println(summary(scenario, samples, 0.0))
}

///|
extern "c" fn exit(code : Int) -> Unit = "exit"

///|
/// fork gpui-sys 的窗口帧循环：打开窗口、按帧驱动 action、结束后自行打印
/// ui-frame JSON 并退出进程（macOS quit 不解栈）。
extern "C" fn gpui_run_window_benchmark_ffi(
  view : Int,
  width : Float,
  height : Float,
  scenario : Int,
  target : Int,
  stride : Float,
  document_load_ms : Double,
) -> Int = "gpui_run_window_benchmark"

///|
const BENCHMARK_VIEWPORT_WIDTH : Float = 1280.0

///|
const BENCHMARK_VIEWPORT_HEIGHT : Float = 800.0

///|
/// 每次滚动 action 的逻辑像素步长，与 MoUI/Electron 适配器发送的滚轮增量一致。
const BENCHMARK_SCROLL_STRIDE : Float = 480.0

///|
/// 真实窗口 ui-frame 基准：提交整树后把帧循环交给 Rust 侧。open=1 帧，
/// input=10 个 EVENT_TEXT 注入，scroll=120 次交替滚动目标。与 gpui v1 同
/// scope（ui-frame、1280x800）。成功路径上 Rust 打印报告后终止进程，本函数
/// 不返回。
pub fn run_ui_benchmark(
  source : String,
  scenario : String,
  document_load_ms : Double,
) -> Unit {
  load(source)
  @gpui.expect_ok(build_tree(0), "ui-benchmark initial build_tree")
  let scenario_id = if scenario == "open" {
    0
  } else if scenario == "input" {
    1
  } else {
    2
  }
  let target = if scenario == "open" {
    1
  } else if scenario == "scroll" {
    120
  } else {
    10
  }
  let status = gpui_run_window_benchmark_ffi(
    0,
    BENCHMARK_VIEWPORT_WIDTH,
    BENCHMARK_VIEWPORT_HEIGHT,
    scenario_id,
    target,
    BENCHMARK_SCROLL_STRIDE,
    document_load_ms,
  )
  // 成功时 macOS 上 quit 直接终止进程（不可达）；返回 0 是正常完成路径。
  if status == 0 {
    exit(0)
  }
  abort("gpui2 benchmark window failed with status \{status}")
}
