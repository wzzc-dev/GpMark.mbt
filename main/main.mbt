/// Demo 可执行入口：注册 dispatch → 首次 build_tree → 进入 GPUI 事件循环。
/// 与 counter 示例的消费端形态一致：本包 import `link` 以获得 Rust staticlib
/// 的链接参数，且除了 main 不含任何逻辑（link 参数会传染到测试可执行文件）。

///|
///|
fn main {
  @nakake/gpui-bindings.register_dispatch(@mdmbt/editor/adapter.dispatch)
  @mdmbt/editor/adapter.load(@mdmbt/editor/adapter.demo_sample())
  @nakake/gpui-bindings.expect_ok(
    @mdmbt/editor/adapter.build_tree(0),
    "initial build_tree",
  )
  @nakake/gpui-bindings.expect_ok(
    @nakake/gpui-bindings.run_window(0, 960.0, 720.0),
    "run_window",
  )
}
