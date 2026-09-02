///|
/// 编辑内核与 undo/redo 测试。
fn cs(unit : Int, offset : Int) -> Sel {
  collapsed_sel(Caret::{ unit, offset })
}

///|
fn plain_doc(bs : Array[Block]) -> Array[String] {
  bs.map(block_plain)
}

///|
test "插入纯文本并继承左侧样式" {
  let bs0 = parse_doc("**bold**tail\n")
  let (bs, s) = doc_insert(bs0, cs(0, 4), "X")
  match bs[0] {
    Paragraph(ns) =>
      assert_eq(ns, [
        Run("boldX", Marks::{
          bold: true,
          italic: false,
          strike: false,
          code: false,
        }),
        Run("tail", Marks::{
          bold: false,
          italic: false,
          strike: false,
          code: false,
        }),
      ])
    _ => fail("expect paragraph")
  }
  assert_eq(s, cs(0, 5))
}

///|
test "Enter 拆分段落的 / 标题" {
  let bs0 = parse_doc("hello world\n")
  let (bs, s) = doc_enter(bs0, cs(0, 5))
  assert_eq(plain_doc(bs), ["hello", " world"])
  assert_eq(s, cs(1, 0))

  let h0 = parse_doc("## a b\n")
  let (h, hs) = doc_enter(h0, cs(0, 1))
  assert_eq(plain_doc(h), ["a", " b"])
  assert_eq(hs, cs(1, 0))
  match h[1] {
    Paragraph(_) => ()
    _ => fail("second half should be paragraph")
  }
}

///|
test "Backspace 合并跨块 / 删除原子块" {
  let bs0 = parse_doc("one\n\ntwo\n")
  let (bs, s) = doc_backspace(bs0, cs(1, 0))
  assert_eq(plain_doc(bs), ["onetwo"])
  assert_eq(s, cs(0, 3))

  let ir0 = parse_doc("para\n\n---\n")
  let (ir, is_) = doc_backspace(ir0, cs(1, 0)) // 光标在 Hr 单元开头 → 删除 Hr
  assert_eq(plain_doc(ir), ["para"])
  assert_eq(is_, cs(0, 4))
}

///|
test "Backspace 删除空列表项" {
  let bs0 = parse_doc("- a\n- \n")
  // 光标在第二项开头
  let (bs, _) = doc_backspace(bs0, cs(1, 0))
  assert_eq(bs.length(), 1)
  match bs[0] {
    ListBlock(Bullet, items) => {
      assert_eq(items.length(), 1)
      assert_eq(inlines_plain(items[0].content), "a")
    }
    _ => fail("expect single-item bullet list")
  }
}

///|
test "Enter 拆分列表项" {
  let bs0 = parse_doc("- ab\n")
  let (bs, s) = doc_enter(bs0, cs(0, 1))
  match bs[0] {
    ListBlock(Bullet, items) => {
      assert_eq(items.length(), 2)
      assert_eq(inlines_plain(items[0].content), "a")
      assert_eq(inlines_plain(items[1].content), "b")
    }
    _ => fail("expect bullet list")
  }
  assert_eq(s, cs(1, 0))

  let t0 = parse_doc("- [x] ab\n")
  let (t, _) = doc_enter(t0, cs(0, 1))
  match t[0] {
    ListBlock(Task, items) => assert_eq(items[1].checked, Some(false))
    _ => fail("expect task list")
  }
}

///|
test "Delete 向前删除与跨单元删除" {
  let bs0 = parse_doc("ab\n\ncd\n")
  let (bs, s) = doc_delete_forward(bs0, Caret::{ unit: 0, offset: 0 })
  assert_eq(plain_doc(bs), ["b", "cd"])
  assert_eq(s, cs(0, 0))

  // 单元末尾 Delete → 合并下一单元
  let (m, _) = doc_delete_forward(bs0, Caret::{ unit: 0, offset: 2 })
  assert_eq(plain_doc(m), ["abcd"])
}

///|
test "跨单元选区删除" {
  let bs0 = parse_doc("one\n\ntwo\n\nthree\n")
  let sel = Sel::{
    anchor: Caret::{ unit: 0, offset: 2 },
    focus: Caret::{ unit: 2, offset: 1 },
  }
  let (bs, s) = doc_delete(bs0, sel)
  assert_eq(plain_doc(bs), ["onhree"])
  assert_eq(s, Caret::{ unit: 0, offset: 2 })

  let (bs2, _) = doc_insert(bs, collapsed_sel(s), "!")
  assert_eq(plain_doc(bs2), ["on!hree"])
}

///|
test "代码块编辑走 set_plain" {
  let bs0 = parse_doc("```py\nprint\n```\n")
  let (bs, s) = doc_insert(bs0, cs(0, 5), "()")
  assert_eq(bs[0], CodeBlock("py", "print()"))
  assert_eq(s, cs(0, 7))
  let (bd, _) = doc_backspace(bs, cs(0, 7))
  assert_eq(bd[0], CodeBlock("py", "print("))
}

///|
test "样式切换 bold 双向" {
  let bs0 = parse_doc("hello\n")
  let sel = Sel::{
    anchor: Caret::{ unit: 0, offset: 0 },
    focus: Caret::{ unit: 0, offset: 5 },
  }
  let bold_upd = fn(m : Marks) {
    Marks::{ bold: !m.bold, italic: m.italic, strike: m.strike, code: m.code }
  }
  let (b1, _) = doc_toggle_mark(bs0, sel, bold_upd)
  assert_eq(
    b1[0],
    Paragraph([
      Run("hello", Marks::{
        bold: true,
        italic: false,
        strike: false,
        code: false,
      }),
    ]),
  )
  let (b2, _) = doc_toggle_mark(b1, sel, bold_upd)
  assert_eq(b2, bs0)

  // 部分选区只影响覆盖的 run 片段
  let bs3 = parse_doc("hello\n")
  let sel2 = Sel::{
    anchor: Caret::{ unit: 0, offset: 0 },
    focus: Caret::{ unit: 0, offset: 2 },
  }
  let (b3, _) = doc_toggle_mark(bs3, sel2, bold_upd)
  match b3[0] {
    Paragraph(ns) => {
      assert_eq(ns.length(), 2)
      assert_eq(marks_of(ns[0]).bold, true)
      assert_eq(marks_of(ns[1]).bold, false)
    }
    _ => fail("expect paragraph")
  }
}

///|
test "光标移动与选区扩展" {
  let bs = parse_doc("ab\n\ncd\n")
  let start = cs(0, 0)
  assert_eq(doc_move(bs, start, Right, false), cs(0, 1))
  assert_eq(doc_move(bs, cs(0, 2), Right, false), cs(1, 0)) // 跨单元
  assert_eq(doc_move(bs, cs(1, 1), Left, false), cs(1, 0))
  assert_eq(doc_move(bs, cs(0, 1), Up, false), cs(0, 1)) // 顶单元 Up 不动
  assert_eq(doc_move(bs, cs(0, 1), Down, false), cs(1, 1))
  assert_eq(doc_move(bs, cs(1, 2), Home, false), cs(1, 0))
  assert_eq(doc_move(bs, cs(0, 0), End, false), cs(0, 2))
  // 扩展选区
  let ext = doc_move(bs, cs(0, 0), Right, true)
  assert_eq(ext.anchor, cs(0, 0).focus)
  assert_eq(ext.focus, cs(0, 1).focus)
  let all = doc_select_all(bs)
  assert_eq(all.anchor, Caret::{ unit: 0, offset: 0 })
  assert_eq(all.focus, Caret::{ unit: 1, offset: 2 })
}

///|
test "块级类型转换" {
  let bs0 = parse_doc("text\n")
  let (h1, _) = doc_block_op(bs0, cs(0, 0), SetHeading(2))
  assert_eq(plain_doc(h1), ["text"])
  match h1[0] {
    Heading(2, _) => ()
    _ => fail("expect h2")
  }
  let (h2, _) = doc_block_op(h1, cs(0, 0), SetHeading(2)) // 同级 → 转回段落
  match h2[0] {
    Paragraph(_) => ()
    _ => fail("expect paragraph back")
  }
  let (l1, _) = doc_block_op(bs0, cs(0, 0), ToggleBullet)
  match l1[0] {
    ListBlock(Bullet, items) => assert_eq(items.length(), 1)
    _ => fail("expect bullet")
  }
  let (l2, _) = doc_block_op(l1, cs(0, 0), ToggleBullet)
  match l2[0] {
    Paragraph(_) => ()
    _ => fail("expect paragraph back")
  }
}

///|
test "undo / redo 快照" {
  let bs0 = parse_doc("start\n")
  let ed = Editor::new(bs0)
  assert_eq(ed.can_undo(), false)
  ed.apply(fn(b, s) { doc_insert(b, s, "!!") })
  assert_eq(plain_doc(ed.blocks), ["!!start"])
  assert_eq(ed.can_undo(), true)
  ed.undo()
  assert_eq(plain_doc(ed.blocks), ["start"])
  assert_eq(ed.can_redo(), true)
  ed.redo()
  assert_eq(plain_doc(ed.blocks), ["!!start"])
  // 新编辑清空 redo 栈
  ed.undo()
  ed.apply(fn(b, s) { doc_insert(b, s, "?") })
  assert_eq(ed.can_redo(), false)
  assert_eq(plain_doc(ed.blocks), ["?start"])
}

///|
test "undo 恢复选区" {
  let bs0 = parse_doc("abc\n")
  let ed = Editor::new(bs0)
  ed.set_sel(cs(0, 3))
  ed.apply(fn(b, s) { doc_insert(b, s, "d") })
  assert_eq(ed.sel, cs(0, 4))
  ed.undo()
  assert_eq(ed.sel, cs(0, 3))
  assert_eq(plain_doc(ed.blocks), ["abc"])
}

///|
test "编辑后文档仍可序列化且再解析稳定" {
  let bs0 = parse_doc("# t\n\nbody\n")
  let (bs, _) = doc_insert(bs0, cs(1, 4), " tail")
  let src = serialize_doc(bs)
  assert_eq(parse_doc(src), bs)
}

///|
fn marks_of(n : Inline) -> Marks {
  match n {
    Run(_, m) => m
    _ => Marks::default()
  }
}

///|
test "BlockOp：列表转段落保住全部项；类型互转" {
  let doc = parse_doc("- 甲\n- 乙\n- 丙\n")
  let (b1, _) = doc_block_op(doc, csel(1, 0), ToggleBullet)
  assert_eq(
    b1.map(block_plain),
    ["甲", "乙", "丙"],
  )
  let (b2, _) = doc_block_op(b1, csel(0, 0), ToggleBullet)
  match b2[0] {
    ListBlock(Bullet, its) => assert_eq(its.length(), 1) // 只包光标所在段
    _ => fail("bullet")
  }
  assert_eq(b2.map(block_plain).length(), 3) // 其余段不丢
  let (b3, _) = doc_block_op(b2, csel(0, 0), SetOrdered(1))
  match b3[0] {
    ListBlock(Ordered(1), its) => assert_eq(its.length(), 1) // 换类型：整表换装
    _ => fail("ordered")
  }
  // 多项列表换类型全部保留
  let many = parse_doc("- 甲\n- 乙\n")
  let (m2, _) = doc_block_op(many, csel(0, 0), SetOrdered(1))
  match m2[0] {
    ListBlock(Ordered(1), its) => assert_eq(its.length(), 2)
    _ => fail("ordered many")
  }
  let (b4, _) = doc_block_op(b3, csel(0, 0), SetTask)
  match b4[0] {
    ListBlock(Task, its) => assert_eq(its[0].checked, Some(false))
    _ => fail("task")
  }
  // 段落 → 标题 → 同键回到段落
  let p = parse_doc("text\n")
  let (h, _) = doc_block_op(p, csel(0, 0), SetHeading(2))
  assert_eq(h[0], Heading(2, [Run("text", Marks::default())]))
  let (p2, _) = doc_block_op(h, csel(0, 0), SetHeading(2))
  match p2[0] {
    Paragraph(_) => ()
    _ => fail("back to paragraph")
  }
}

///|
test "表格格首退格/格尾前删只移光标（防幽灵格）" {
  let doc = parse_doc("| a | b |\n| - | - |\n| 1 | 2 |\n")
  // 单元 2 = 第 2 行首格（offset 0）
  let (b1, s1) = doc_backspace(doc, csel(2, 0))
  assert_eq(b1, doc) // 内容不动
  assert_eq(s1, csel(1, 1)) // 光标移入上一格尾
  // 格尾前删 → 下一格首
  let (b2, s2) = doc_delete_forward(doc, Caret::{ unit: 0, offset: 1 })
  assert_eq(b2, doc)
  assert_eq(s2, csel(1, 0))
  // 普通段落跨块退格仍合并
  let p = parse_doc("one\n\ntwo\n")
  let (b3, _) = doc_backspace(p, csel(1, 0))
  assert_true(b3 != p)
}

///|
test "代码块语言循环" {
  let langs = ["", "moonbit", "rust"]
  let doc = parse_doc("```rust\nx\n```")
  let us = collect_units(doc)
  let mut cu = -1
  for k = 0; k < us.length(); k = k + 1 {
    if us[k].kind == CodeU {
      cu = k
    }
  }
  // rust → 回到表头（空）→ moonbit
  let (b1, _) = doc_cycle_code_lang(doc, csel(cu, 0), langs)
  match b1[0] {
    CodeBlock(l, code) => {
      assert_eq(l, "")
      assert_eq(code, "x") // 代码内容不动
    }
    _ => fail("code")
  }
  let (b2, _) = doc_cycle_code_lang(b1, csel(cu, 0), langs)
  match b2[0] {
    CodeBlock(l, _) => assert_eq(l, "moonbit")
    _ => fail("code2")
  }
}

///|
test "doc_selection_text：单单元/跨单元/空选区" {
  let bs = parse_doc("hello 世界\n\nsecond para")
  // 单元内选区（第 0 单元 offset 0..5）
  let t1 = doc_selection_text(bs, mk_sel(0, 0, 0, 5))
  assert_eq(t1, "hello")
  // 跨单元：单元 0 全部到单元 1 前缀（单元间补换行）
  let t2 = doc_selection_text(bs, mk_sel(0, 0, 1, 3))
  assert_eq(t2, "hello 世界\nsec")
  // 端点 unit 越界 = 钳到文档末尾
  let t5 = doc_selection_text(bs, mk_sel(0, 0, 99, 0))
  assert_eq(t5, "hello 世界\nsecond para")
  // 空选区
  let t3 = doc_selection_text(bs, mk_sel(1, 0, 1, 0))
  assert_eq(t3, "")
  // 反向选区（anchor 在后）
  let t4 = doc_selection_text(bs, mk_sel(1, 3, 0, 0))
  assert_eq(t4, "hello 世界\nsec")
}

///|
fn mk_sel(au : Int, ao : Int, bu : Int, bo : Int) -> Sel {
  {
    anchor: Caret::{ unit: au, offset: ao },
    focus: Caret::{ unit: bu, offset: bo },
  }
}
