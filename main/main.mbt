/// Demo 可执行入口：注册 dispatch → 首次 build_tree → 进入 GPUI 事件循环。
/// 与 counter 示例的消费端形态一致：本包 import `link` 以获得 Rust staticlib
/// 的链接参数，且除了 main 不含任何逻辑（link 参数会传染到测试可执行文件）。

///|
///|
fn now_ms() -> Double {
  @env.now().reinterpret_as_int64().to_double()
}

///|
fn main {
  let args = @env.args()
  // md_editor gpui2 适配器协议：--benchmark 为 headless-render 诊断行，
  // --ui-benchmark 为真实窗口 ui-frame 帧循环（Rust 侧打印 JSON 后退出）。
  if args.length() >= 4 && args[1] == "--benchmark" {
    @mdmbt/adapter.run_headless_benchmark(args[2], args[3])
    return
  }
  if args.length() >= 4 && args[1] == "--ui-benchmark" {
    let load_started = now_ms()
    let source = @fs.read_file_to_string(args[2]) catch {
      _ => abort("gpui2 benchmark fixture is unreadable")
    }
    @nakake/gpui-bindings.register_dispatch(@mdmbt/adapter.dispatch)
    @mdmbt/adapter.run_ui_benchmark(
      source,
      args[3],
      (now_ms() - load_started).max(0.0),
    )
    return
  }
  @nakake/gpui-bindings.register_dispatch(@mdmbt/adapter.dispatch)
  @mdmbt/adapter.set_viewport_height(720.0)
  // 按文件启动：`open dist/MdMbt.app --args <path>`（Finder「打开方式」的
  // 命令行形态）。读取/解析失败则回退内置 demo 文档。
  let opened = if args.length() >= 2 {
    match @mdmbt/adapter.open_path(args[1]) {
      Ok(_) => {
        println("opened: " + args[1])
        true
      }
      Err(e) => {
        println("open failed: " + e + " — 回退到 demo 文档")
        false
      }
    }
  } else {
    false
  }
  if !opened {
    @mdmbt/adapter.load(@mdmbt/adapter.demo_sample())
  }
  @nakake/gpui-bindings.expect_ok(
    @mdmbt/adapter.build_tree(0),
    "initial build_tree",
  )
  @nakake/gpui-bindings.expect_ok(
    @nakake/gpui-bindings.run_window(0, 960.0, 720.0),
    "run_window",
  )
}
