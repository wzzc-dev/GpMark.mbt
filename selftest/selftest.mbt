/// 无 GUI 自检：不走 run_window，直接 build_tree(0) 提交渲染树，
/// 再用 debug_dump_text 回读全部文本节点验证渲染内容。
/// 这验证了真实 FFI 链路（moon → C → Rust → GPUI 树），可在终端里跑。
/// 失败打印 SELFTEST FAIL 并触发 panic（debug 模式 → 非零退出码）。

///|
let failed : Array[Int] = []

fn check(needle : String, hay : String) -> Unit {
  if hay.contains(needle) {
    println("  ok: \{needle}")
  } else {
    println("MISSING: \{needle}")
    failed.push(1)
  }
}

///|
fn main {
  @nakake/gpui-bindings.register_dispatch(@mdmbt/editor/adapter.dispatch)
  @mdmbt/editor/adapter.load(@mdmbt/editor/adapter.demo_sample())
  @nakake/gpui-bindings.expect_ok(
    @mdmbt/editor/adapter.build_tree(0),
    "initial build_tree",
  )
  let dump = match @nakake/gpui-bindings.debug_dump_text(0) {
    Ok(s) => s
    Err(code) => {
      println("debug_dump_text failed: \{code}")
      failed.push(1)
      ""
    }
  }
  check("md_mbt 编辑器演示", dump) // 标题文本（# 不渲染，光标在文本前）
  check("GPUI 后端", dump)
  check("WYSIWYG 核心", dump)
  check("•", dump)
  check("☑", dump)
  check("☐", dump)
  check("1.", dump)
  check("引用块", dump)
  check("fn greet(name : String)", dump)
  check("链接", dump) // 链接渲染为内层文本（URL 不显示）
  check("已完成任务", dump)
  check("moon.png", dump) // 图片块 alt · url
  check("<div class=\"raw-block\">", dump) // Raw 块原样可见
  // 光标唯一性：▍ 只应出现一次（回归防护：曾因 emit_text 尾部条件缺失到处画光标）
  let caret_n = dump.to_array().filter(c => c == '▍').length()
  if caret_n == 1 {
    println("  ok: caret unique")
  } else {
    println("BAD caret count: \{caret_n}")
    failed.push(1)
  }
  // 模拟编辑：插入字符 → 重建 → dump 应包含新内容
  let ed = @mdmbt/editor/adapter.ed
  ed.apply(fn(b, s) { @core.doc_insert(b, s, "Zq") })
  @nakake/gpui-bindings.expect_ok(
    @mdmbt/editor/adapter.build_tree(0),
    "rebuild after insert",
  )
  let dump2 = match @nakake/gpui-bindings.debug_dump_text(0) {
    Ok(s) => s
    Err(_) => ""
  }
  check("Zq", dump2)
  // 模拟 undo：撤销插入 → 重建 → 新内容消失
  ed.undo()
  @nakake/gpui-bindings.expect_ok(
    @mdmbt/editor/adapter.build_tree(0),
    "rebuild after undo",
  )
  match @nakake/gpui-bindings.debug_dump_text(0) {
    Ok(s) =>
      if s.contains("Zq") {
        println("MISSING: undo should remove Zq")
        failed.push(1)
      } else {
        println("  ok: undo removed Zq")
      }
    Err(_) => { failed.push(1) }
  }
  // --- 事件注入：用 Rust 回调同款信封直接打 dispatch 入口，验证
  // dispatch → decode_event → handler → core 编辑 → dirty → rebuild → FFI 提交 ---
  let base_blocks = ed.blocks.length()
  let r_click = @mdmbt/editor/adapter.dispatch(
    @nakake/gpui-bindings.ABI_VERSION,
    @nakake/gpui-bindings.EVENT_CLICK,
    0,
    @mdmbt/editor/adapter.click_id_of(2),
    0,
  )
  if r_click == 1 {
    println("  ok: click dispatch → dirty rebuild")
  } else {
    println(
      "BAD: click dispatch returned \{r_click}, id=\{@mdmbt/editor/adapter.click_id_of(2)}",
    )
    failed.push(1)
  }
  let dump3 = match @nakake/gpui-bindings.debug_dump_text(0) {
    Ok(s) => s
    Err(_) => ""
  }
  if dump3.contains("列表与任务▍") {
    println("  ok: click moved caret to block end")
  } else {
    println("BAD: click did not move caret to 列表与任务 end")
    failed.push(1)
  }
  let r_enter = @mdmbt/editor/adapter.dispatch(
    @nakake/gpui-bindings.ABI_VERSION,
    @nakake/gpui-bindings.EVENT_NAMED_KEY,
    0,
    @nakake/gpui-bindings.KEY_ENTER,
    0,
  )
  if r_enter != 1 {
    println("BAD: enter dispatch returned \{r_enter}")
    failed.push(1)
  }
  if ed.blocks.length() == base_blocks + 1 {
    println("  ok: injected Enter split block")
  } else {
    println(
      "BAD: blocks after enter = \{ed.blocks.length()}, want \{base_blocks + 1}",
    )
    failed.push(1)
  }
  let dump4 = match @nakake/gpui-bindings.debug_dump_text(0) {
    Ok(s) => s
    Err(_) => ""
  }
  if dump4.to_array().filter(c => c == '▍').length() == 1 {
    println("  ok: caret unique after split")
  } else {
    println("BAD: caret not unique after split")
    failed.push(1)
  }
  // Cmd+Z 走 on_key 路径
  let _ = @mdmbt/editor/adapter.dispatch(
    @nakake/gpui-bindings.ABI_VERSION,
    @nakake/gpui-bindings.EVENT_KEY,
    0,
    'z'.to_int(),
    @nakake/gpui-bindings.MOD_PLATFORM,
  )
  if ed.blocks.length() == base_blocks {
    println("  ok: injected Cmd+Z undid split")
  } else {
    println("BAD: blocks after undo = \{ed.blocks.length()}")
    failed.push(1)
  }
  if failed.length() > 0 {
    println("---- dump ----")
    println(dump4)
    println("SELFTEST FAIL (\{failed.length()} problems)")
    let boom : Array[Int] = []
    println(boom[999].to_string()) // debug panic → 非零退出
  } else {
    println("SELFTEST PASS")
  }
}
