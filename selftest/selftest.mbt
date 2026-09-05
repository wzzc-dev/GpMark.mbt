/// 无 GUI 自检：不走 run_window，直接 build_tree(0) 提交渲染树，
/// 再用 debug_dump_text 回读全部文本节点验证渲染内容。
/// 这验证了真实 FFI 链路（moon → C → Rust → GPUI 树），可在终端里跑。
/// 失败打印 SELFTEST FAIL 并触发 panic（debug 模式 → 非零退出码）。

///|
let failed : Array[Int] = []

/// debug_dump_text 返回「u32 长度前缀 + utf8」记录流；token 化渲染后
/// 一段文本被拆成多条记录，前缀字节会把子串切断。剥掉控制字节与
/// 解码替换符，还原连续文本再做包含断言。
fn squash(raw : String) -> String {
  String::from_array(
    raw.to_array().filter(fn(c) {
      let u = c.to_int()
      u >= 0x20 && u != 0xFFFD
    }),
  )
}

fn dump0() -> String {
  match @nakake/gpui-bindings.debug_dump_text(0) {
    Ok(t) => squash(t)
    Err(_) => ""
  }
}

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
  @nakake/gpui-bindings.register_dispatch(@mdmbt/adapter.dispatch)
  @mdmbt/adapter.load(@mdmbt/adapter.demo_sample())
  @nakake/gpui-bindings.expect_ok(
    @mdmbt/adapter.build_tree(0),
    "initial build_tree",
  )
  let dump = dump0()
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
  // 光标是绝对定位覆盖层，不进入文本流：▏ 不应出现在 dump（回归防护：
  // 曾以字符段实现，会把后面的字推走一格）
  let caret_n = dump.to_array().filter(c => c == '▏').length()
  if caret_n == 0 {
    println("  ok: caret not in text flow")
  } else {
    println("BAD: caret char leaked into text flow: \{caret_n}")
    failed.push(1)
  }
  // 模拟编辑：插入字符 → 重建 → dump 应包含新内容
  let ed = @mdmbt/adapter.ed
  ed.apply(fn(b, s) { @core.doc_insert(b, s, "Zq") })
  @nakake/gpui-bindings.expect_ok(
    @mdmbt/adapter.build_tree(0),
    "rebuild after insert",
  )
  let dump2 = dump0()
  check("Zq", dump2)
  // 模拟 undo：撤销插入 → 重建 → 新内容消失
  ed.undo()
  @nakake/gpui-bindings.expect_ok(
    @mdmbt/adapter.build_tree(0),
    "rebuild after undo",
  )
  {
    let s = dump0()
    if s.contains("Zq") {
        println("MISSING: undo should remove Zq")
        failed.push(1)
      } else {
        println("  ok: undo removed Zq")
      }
  }
  // --- 事件注入：用 Rust 回调同款信封直接打 dispatch 入口，验证
  // dispatch → decode_event → handler → core 编辑 → dirty → rebuild → FFI 提交 ---
  let base_blocks = ed.blocks.length()
  let r_click = @mdmbt/adapter.dispatch(
    @nakake/gpui-bindings.ABI_VERSION,
    @nakake/gpui-bindings.EVENT_CLICK,
    0,
    @mdmbt/adapter.click_id_of(2),
    0,
  )
  if r_click == 1 {
    println("  ok: click dispatch → dirty rebuild")
  } else {
    println(
      "BAD: click dispatch returned \{r_click}, id=\{@mdmbt/adapter.click_id_of(2)}",
    )
    failed.push(1)
  }
  let dump3 = dump0()
  {
    let f = ed.sel.focus
    if f.unit == 2 && f.offset > 0 {
      println("  ok: click moved caret to block end (unit=\{f.unit})")
    } else {
      println("BAD: click did not move caret, focus=\{f.unit}@\{f.offset}")
      failed.push(1)
    }
  }
  let r_enter = @mdmbt/adapter.dispatch(
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
  let dump4 = dump0()
  if dump4.to_array().filter(c => c == '▏').length() == 0 {
    println("  ok: no caret chars after split")
  } else {
    println("BAD: caret char leaked after split")
    failed.push(1)
  }
  // Cmd+Z 走 on_key 路径
  let _ = @mdmbt/adapter.dispatch(
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
  // --- 点列表项文本单元：光标落该单元尾，且全树仍只有一个光标 ---
  {
    let u0 = @core.collect_units(ed.blocks)
    let mut item_u = -1
    for k = 0; k < u0.length(); k = k + 1 {
      if u0[k].plain == "已完成任务" {
        item_u = k
      }
    }
    if item_u < 0 {
      println("BAD: task text unit not found")
      failed.push(1)
    } else {
      let _ = @mdmbt/adapter.dispatch(
        @nakake/gpui-bindings.ABI_VERSION,
        @nakake/gpui-bindings.EVENT_CLICK,
        0,
        @mdmbt/adapter.click_id_of(item_u),
        0,
      )
      let d = dump0()
      let f = ed.sel.focus
      let expect_off = u0[item_u].plain.to_array().length()
      if f.unit == item_u && f.offset == expect_off &&
        d.to_array().filter(c => c == '▏').length() == 0 {
        println("  ok: list-item click caret at unit end, no caret chars")
      } else {
        println("BAD: list-item click caret wrong: \{f.unit}@\{f.offset}")
        failed.push(1)
      }
    }
  }
  // --- 行段点击定位：点击列表项第 1 个行段，光标落行首（7db0276 行粒度
  // 合并后 tok_starts_of 以"行"为段；token 级点击语义已并入像素路径）---
  {
    let u0b = @core.collect_units(ed.blocks)
    let mut item_u2 = -1
    for k = 0; k < u0b.length(); k = k + 1 {
      if u0b[k].plain == "已完成任务" {
        item_u2 = k
      }
    }
    if item_u2 < 0 {
      println("BAD: task text unit not found (token test)")
      failed.push(1)
    } else {
      let _ = @mdmbt/adapter.dispatch(
        @nakake/gpui-bindings.ABI_VERSION,
        @nakake/gpui-bindings.EVENT_CLICK,
        0,
        @mdmbt/adapter.token_click_id_of(item_u2, 0),
        0,
      )
      let d = dump0()
      let f2 = ed.sel.focus
      if f2.unit == item_u2 && f2.offset == 0 &&
        d.to_array().filter(c => c == '▏').length() == 0 {
        println("  ok: row-segment click positions caret at row start")
      } else {
        println("BAD: row-segment click caret wrong: \{f2.unit}@\{f2.offset}")
        failed.push(1)
      }
    }
  }
  // --- 任务框点击：勾选切换（box id 池独立于单元 id 池）---------------
  let units_now = @core.collect_units(ed.blocks)
  let mut task_u = -1
  for k = 0; k < units_now.length(); k = k + 1 {
    if units_now[k].plain.contains("已完成任务") {
      task_u = k
    }
  }
  if task_u < 0 {
    println("BAD: task unit not found")
    failed.push(1)
  } else {
    let before = @mdmbt/adapter.dump()
    let _ = @mdmbt/adapter.dispatch(
      @nakake/gpui-bindings.ABI_VERSION,
      @nakake/gpui-bindings.EVENT_CLICK,
      0,
      @mdmbt/adapter.box_id_of(task_u),
      0,
    )
    if @mdmbt/adapter.dump().contains("- [ ] 已完成任务") {
      println("  ok: checkbox click toggled task")
    } else {
      println("BAD: checkbox click did not toggle (before=\{before})")
      failed.push(1)
    }
    ed.undo()
    if !@mdmbt/adapter.dump().contains("- [ ] 已完成任务") {
      println("  ok: undo restored checkbox")
    } else {
      println("BAD: undo did not restore checkbox")
      failed.push(1)
    }
  }
  // --- 「标记+空格」规则：键入序列走 core（TEXT 事件无坐标不能注入）---
  let p_u = @core.collect_units(ed.blocks)
  let mut para_u = -1
  for k = 0; k < p_u.length(); k = k + 1 {
    if p_u[k].kind == @core.ParagraphU {
      para_u = k
      break
    }
  }
  if para_u < 0 {
    println("BAD: no paragraph unit")
    failed.push(1)
  } else {
    ed.set_sel(@core.collapsed_sel(@core.Caret::{ unit: para_u, offset: 0 }))
    ed.apply_text("selftest", fn(b, s) {
      // 模拟逐键：先敲 "# "（触发规则），再敲标题文本
      let (b1, s1) = @core.doc_insert(b, s, "# ")
      let (b2, s2, hit) = @core.doc_apply_space_rule(b1, s1)
      if !hit {
        println("BAD: space rule did not fire")
        failed.push(1)
      }
      @core.doc_insert(b2, s2, "规则标题")
    })
    if @mdmbt/adapter.dump().contains("# 规则标题") {
      println("  ok: space rule produced heading")
    } else {
      println("BAD: serialize missing '# 规则标题'")
      failed.push(1)
    }
    ed.undo()
  }
  // --- 活行内转换：键入 `**x**` 后空格 → bold run -----------------------
  if para_u >= 0 {
    ed.set_sel(@core.collapsed_sel(@core.Caret::{ unit: para_u, offset: 0 }))
    ed.apply_text("selftest2", fn(b, s) {
      let (b1, s1) = @core.doc_insert(b, s, "**粗**x")
      let us = @core.collect_units(b1)
      let c = s1.focus
      let (ni, no, changed) = @core.reparse_inlines(us[c.unit].inlines, c.offset)
      if !changed {
        println("BAD: reparse did not change")
        failed.push(1)
      }
      ((us[c.unit].set_inlines)(ni), @core.collapsed_sel(@core.Caret::{
        unit: c.unit,
        offset: no,
      }))
    })
    @nakake/gpui-bindings.expect_ok(
      @mdmbt/adapter.build_tree(0),
      "rebuild after reparse",
    )
    let rdump = dump0()
    if rdump.contains("**") {
      println("BAD: rendered text should not show literal markers")
      failed.push(1)
    } else if rdump.contains("粗x") {
      println("  ok: live inline reparse consumed markers")
    } else {
      println("BAD: rendered text missing 粗x")
      failed.push(1)
    }
    ed.undo()
  }
  // --- Cmd+A + Cmd+B：选区加粗走真实 on_key 事件 ------------------------
  let _ = @mdmbt/adapter.dispatch(
    @nakake/gpui-bindings.ABI_VERSION,
    @nakake/gpui-bindings.EVENT_KEY,
    0,
    'a'.to_int(),
    @nakake/gpui-bindings.MOD_PLATFORM,
  )
  let _ = @mdmbt/adapter.dispatch(
    @nakake/gpui-bindings.ABI_VERSION,
    @nakake/gpui-bindings.EVENT_KEY,
    0,
    'b'.to_int(),
    @nakake/gpui-bindings.MOD_PLATFORM,
  )
  if @mdmbt/adapter.dump().contains("**md_mbt 编辑器演示**") {
    println("  ok: Cmd+A + Cmd+B bolded whole doc")
  } else {
    println("BAD: Cmd+B did not bold selection")
    failed.push(1)
  }
  let _ = @mdmbt/adapter.dispatch(
    @nakake/gpui-bindings.ABI_VERSION,
    @nakake/gpui-bindings.EVENT_KEY,
    0,
    'z'.to_int(),
    @nakake/gpui-bindings.MOD_PLATFORM,
  )
  if !@mdmbt/adapter.dump().contains("**md_mbt 编辑器演示**") {
    println("  ok: Cmd+Z undid bold")
  } else {
    println("BAD: undo did not restore bold state")
    failed.push(1)
  }
  // --- 打开/保存文件：真文件读写回（open_path 与 Cmd+O 选中后的同一入口）---
  // Cmd+O 本身不派发：它会弹出真实系统文件选择框并阻塞进程，无法无人值守
  // 跑完；对话框桥（filedialog_stub.c）的正确性靠 GUI 手工验证 + wbtest 对
  // 下游 open_path 的覆盖。
  {
    let tmp = "/tmp/mdmbt_selftest_open.md"
    let fixture = "# 自检外部文档\n\n来自打开功能的测试内容。\n"
    @fs.write_string_to_file(tmp, fixture) catch {
      _ => {
        println("BAD: cannot write temp fixture")
        failed.push(1)
      }
    }
    match @mdmbt/adapter.open_path(tmp) {
      Ok(_) => {
        @nakake/gpui-bindings.expect_ok(
          @mdmbt/adapter.build_tree(0),
          "rebuild after open_path",
        )
        let d = dump0()
        check("自检外部文档", d)
        check("来自打开功能的测试内容", d)
        if @mdmbt/adapter.current_path() == tmp {
          println("  ok: opened file tracked as current")
        } else {
          println("BAD: current_path not tracked")
          failed.push(1)
        }
      }
      Err(e) => {
        println("BAD: open_path failed: \{e}")
        failed.push(1)
      }
    }
    // Cmd+S 回写：编辑后注入键事件，再读盘验证
    let us = @core.collect_units(ed.blocks)
    let last = us.length() - 1
    ed.set_sel(@core.collapsed_sel(@core.Caret::{
      unit: last,
      offset: us[last].plain.to_array().length(),
    }))
    ed.apply_text("selftest-save", fn(b, s) { @core.doc_insert(b, s, "回写验证") })
    let _ = @mdmbt/adapter.dispatch(
      @nakake/gpui-bindings.ABI_VERSION,
      @nakake/gpui-bindings.EVENT_KEY,
      0,
      's'.to_int(),
      @nakake/gpui-bindings.MOD_PLATFORM,
    )
    let saved = @fs.read_file_to_string(tmp) catch { _ => "" }
    if saved.contains("回写验证") {
      println("  ok: Cmd+S persisted to disk")
    } else {
      println("BAD: Cmd+S did not persist")
      failed.push(1)
    }
    let _ = @fs.remove_file(tmp) catch { _ => () }
  }
  // --- 代码块：div 光标条进块、探针段按行注册、点击落单元尾 -------------
  {
    @mdmbt/adapter.load(
      "code 前置\n```rust\nfn main() {\n  let x = 42;\n}\n```\n",
    )
    let us_code = @core.collect_units(ed.blocks)
    let mut code_u = -1
    for k = 0; k < us_code.length(); k = k + 1 {
      if us_code[k].kind == @core.CodeU {
        code_u = k
      }
    }
    if code_u < 0 {
      println("BAD: code unit not found")
      failed.push(1)
    } else {
      // 光标进代码块行 1 中部 → 重建 → 无 ▏ 泄漏（div 条不进文本流）
      ed.set_sel(@core.collapsed_sel(@core.Caret::{ unit: code_u, offset: 16 }))
      @nakake/gpui-bindings.expect_ok(
        @mdmbt/adapter.build_tree(0),
        "code caret build",
      )
      let d = dump0()
      if d.contains("let x = 42") &&
        d.to_array().filter(c => c == '▏').length() == 0 {
        println("  ok: code caret renders without glyph leak")
      } else {
        println("BAD: code caret glyph leak or missing code text")
        failed.push(1)
      }
      // 探针段按行注册（行首 0/12/26 + 哨兵 27）；光标不再劈行
      //（桥层按行声明画 quad，见 text-row ABI），段表与无光标时一致
      let starts = @mdmbt/adapter.tok_starts_of(code_u)
      let ulen = us_code[code_u].plain.to_array().length()
      if starts.to_string() == "[0, 12, 26, 27]" && ulen == 27 {
        println("  ok: code probe starts registered")
      } else {
        println("BAD: code probe starts \{starts} (ulen=\{ulen})")
        failed.push(1)
      }
      // 点击代码块 → 光标落单元尾（精确落点由探针矩形在 paint 后给出，
      // headless 只验兜底路径；行列映射契约见 hit_wbtest）
      let _ = @mdmbt/adapter.dispatch(
        @nakake/gpui-bindings.ABI_VERSION,
        @nakake/gpui-bindings.EVENT_CLICK,
        0,
        @mdmbt/adapter.click_id_of(code_u),
        0,
      )
      let f = ed.sel.focus
      if f.unit == code_u && f.offset == ulen {
        println("  ok: code click caret at unit end")
      } else {
        println("BAD: code click caret wrong: \{f.unit}@\{f.offset}")
        failed.push(1)
      }
    }
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
