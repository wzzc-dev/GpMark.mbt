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
  @nakake/gpui-bindings.register_dispatch(@mdmbt/editor/adapter.dispatch)
  @mdmbt/editor/adapter.load(@mdmbt/editor/adapter.demo_sample())
  @nakake/gpui-bindings.expect_ok(
    @mdmbt/editor/adapter.build_tree(0),
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
  let ed = @mdmbt/editor/adapter.ed
  ed.apply(fn(b, s) { @core.doc_insert(b, s, "Zq") })
  @nakake/gpui-bindings.expect_ok(
    @mdmbt/editor/adapter.build_tree(0),
    "rebuild after insert",
  )
  let dump2 = dump0()
  check("Zq", dump2)
  // 模拟 undo：撤销插入 → 重建 → 新内容消失
  ed.undo()
  @nakake/gpui-bindings.expect_ok(
    @mdmbt/editor/adapter.build_tree(0),
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
  let dump4 = dump0()
  if dump4.to_array().filter(c => c == '▏').length() == 0 {
    println("  ok: no caret chars after split")
  } else {
    println("BAD: caret char leaked after split")
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
      let _ = @mdmbt/editor/adapter.dispatch(
        @nakake/gpui-bindings.ABI_VERSION,
        @nakake/gpui-bindings.EVENT_CLICK,
        0,
        @mdmbt/editor/adapter.click_id_of(item_u),
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
  // --- token 级点击定位：点击列表项第 2 个 token，光标落 token 起点 ---
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
      let _ = @mdmbt/editor/adapter.dispatch(
        @nakake/gpui-bindings.ABI_VERSION,
        @nakake/gpui-bindings.EVENT_CLICK,
        0,
        @mdmbt/editor/adapter.token_click_id_of(item_u2, 1),
        0,
      )
      let d = dump0()
      let f2 = ed.sel.focus
      if f2.unit == item_u2 && f2.offset == 1 &&
        d.to_array().filter(c => c == '▏').length() == 0 {
        println("  ok: token click positions caret at token start, no text shift")
      } else {
        println("BAD: token click caret wrong: \{f2.unit}@\{f2.offset}")
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
    let before = @mdmbt/editor/adapter.dump()
    let _ = @mdmbt/editor/adapter.dispatch(
      @nakake/gpui-bindings.ABI_VERSION,
      @nakake/gpui-bindings.EVENT_CLICK,
      0,
      @mdmbt/editor/adapter.box_id_of(task_u),
      0,
    )
    if @mdmbt/editor/adapter.dump().contains("- [ ] 已完成任务") {
      println("  ok: checkbox click toggled task")
    } else {
      println("BAD: checkbox click did not toggle (before=\{before})")
      failed.push(1)
    }
    ed.undo()
    if !@mdmbt/editor/adapter.dump().contains("- [ ] 已完成任务") {
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
    if @mdmbt/editor/adapter.dump().contains("# 规则标题") {
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
      @mdmbt/editor/adapter.build_tree(0),
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
  let _ = @mdmbt/editor/adapter.dispatch(
    @nakake/gpui-bindings.ABI_VERSION,
    @nakake/gpui-bindings.EVENT_KEY,
    0,
    'a'.to_int(),
    @nakake/gpui-bindings.MOD_PLATFORM,
  )
  let _ = @mdmbt/editor/adapter.dispatch(
    @nakake/gpui-bindings.ABI_VERSION,
    @nakake/gpui-bindings.EVENT_KEY,
    0,
    'b'.to_int(),
    @nakake/gpui-bindings.MOD_PLATFORM,
  )
  if @mdmbt/editor/adapter.dump().contains("**md_mbt 编辑器演示**") {
    println("  ok: Cmd+A + Cmd+B bolded whole doc")
  } else {
    println("BAD: Cmd+B did not bold selection")
    failed.push(1)
  }
  let _ = @mdmbt/editor/adapter.dispatch(
    @nakake/gpui-bindings.ABI_VERSION,
    @nakake/gpui-bindings.EVENT_KEY,
    0,
    'z'.to_int(),
    @nakake/gpui-bindings.MOD_PLATFORM,
  )
  if !@mdmbt/editor/adapter.dump().contains("**md_mbt 编辑器演示**") {
    println("  ok: Cmd+Z undid bold")
  } else {
    println("BAD: undo did not restore bold state")
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
