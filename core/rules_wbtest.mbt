///|
/// 输入规则引擎测试：空格转块、Enter 规则、粘贴拆分、词移动、
/// 任务勾选、缩进/反缩进、表格行操作。
fn csel(unit : Int, offset : Int) -> Sel {
  collapsed_sel(Caret::{ unit, offset })
}

///|
fn pl(bs : Array[Block]) -> Array[String] {
  bs.map(block_plain)
}

///|
fn kind_of(bs : Array[Block], i : Int) -> String {
  match bs[i] {
    Heading(l, _) => "h" + l.to_string()
    Paragraph(_) => "p"
    CodeBlock(lang, _) => "code:" + lang
    Quote(_) => "quote"
    ListBlock(Bullet, _) => "bullet"
    ListBlock(Ordered(n), _) => "ordered" + n.to_string()
    ListBlock(Task, _) => "task"
    TableBlock(_) => "table"
    ImageBlock(_, _) => "img"
    Hr => "hr"
    Raw(_) => "raw"
  }
}

///|
test "空格规则：标题/列表/有序/引用/任务" {
  let mk = fn(s : String) -> (Array[Block], Sel, Bool) {
    let bs : Array[Block] = [Paragraph(parse_inline(s))]
    let cs = inlines_plain(parse_inline(s)).to_array()
    let mut n = 0
    for k = 0; k < cs.length(); k = k + 1 {
      if cs[k] == ' ' {
        n = k + 1
      }
    }
    doc_apply_space_rule(bs, csel(0, n))
  }
  let (b1, s1, ok1) = mk("# 标题")
  assert_true(ok1)
  assert_eq(kind_of(b1, 0), "h1")
  assert_eq(s1, csel(0, 0)) // 光标落在内容起点

  let (b2, _, ok2) = mk("### x")
  assert_true(ok2 && kind_of(b2, 0) == "h3")

  let (b3, _, ok3) = mk("- 条目")
  assert_true(ok3 && kind_of(b3, 0) == "bullet")
  assert_eq(pl(b3), ["条目"])

  let (b4, _, ok4) = mk("* 乙")
  assert_true(ok4 && kind_of(b4, 0) == "bullet")
  let (b5, _, ok5) = mk("+ 丙")
  assert_true(ok5 && kind_of(b5, 0) == "bullet")

  let (b6, _, ok6) = mk("12. 项")
  assert_true(ok6 && kind_of(b6, 0) == "ordered12")

  let (b7, _, ok7) = mk("> 引用")
  assert_true(ok7 && kind_of(b7, 0) == "quote")
  assert_eq(pl(b7), ["引用"])

  let (b8, _, ok8) = mk("[ ] 任务")
  assert_true(ok8 && kind_of(b8, 0) == "task")
  match b8[0] {
    ListBlock(Task, its) => assert_eq(its[0].checked, Some(false))
    _ => fail("task list")
  }
  let (b9, _, ok9) = mk("[x] 完成")
  assert_true(ok9 && kind_of(b9, 0) == "task")
  match b9[0] {
    ListBlock(Task, its) => assert_eq(its[0].checked, Some(true))
    _ => fail("task list")
  }
}

///|
test "空格规则守卫：非标记/样式前缀/代码块/选区不触发" {
  // 「** 」不是 bullet（双星无规则）
  let bs = parse_doc("** x ")
  let (_, _, ok0) = doc_apply_space_rule(bs, csel(0, 4))
  assert_true(!ok0)
  // 「a# 不是标题
  let bs2 = parse_doc("a# x ")
  let (_, _, ok1) = doc_apply_space_rule(bs2, csel(0, 4))
  assert_true(!ok1)
  // 代码块里键入 "# " 不触发
  let cbd = parse_doc("```txt\n# not heading\n```")
  let us = collect_units(cbd)
  let mut cu = -1
  for k = 0; k < us.length(); k = k + 1 {
    if us[k].kind == CodeU {
      cu = k
    }
  }
  assert_true(cu >= 0)
  let clen = us[cu].plain.to_array().length()
  let (_, _, ok2) = doc_apply_space_rule(cbd, csel(cu, clen))
  assert_true(!ok2)
  // 折叠前必须正好停在标记+空格处：中间态不触发
  let bs3 = parse_doc("- a ")
  let (_, _, ok3) = doc_apply_space_rule(bs3, csel(0, 2))
  assert_true(!ok3)
  // 选区状态不触发
  let bs4 = parse_doc("- a ")
  let sel4 = Sel::{
    anchor: Caret::{ unit: 0, offset: 0 },
    focus: Caret::{ unit: 0, offset: 4 },
  }
  let (_, _, ok4) = doc_apply_space_rule(bs4, sel4)
  assert_true(!ok4)
}

///|
test "空格规则：标题改级别；样式前缀不触发" {
  // 标题块只允许 HLevel 规则：level2 敲 "### " → h3
  let bs2 : Array[Block] = [Heading(2, parse_inline("### 标题 x"))]
  let (b2, s2, ok2) = doc_apply_space_rule(bs2, csel(0, 4))
  assert_true(ok2)
  assert_eq(kind_of(b2, 0), "h3")
  assert_eq(s2.focus.unit, 0)
  // 同级重敲不触发
  let same : Array[Block] = [Heading(3, parse_inline("### y "))]
  let (_, _, ok2b) = doc_apply_space_rule(same, csel(0, 4))
  assert_true(!ok2b)
  // 样式化前缀（加粗的 "- "）不触发
  let styled = [
    Paragraph([
      Run("- ", Marks::{ bold: true, italic: false, strike: false, code: false }),
      Run("甲", Marks::{
        bold: false,
        italic: false,
        strike: false,
        code: false,
      }),
    ]),
  ]
  let (_, _, ok3) = doc_apply_space_rule(styled, csel(0, 2))
  assert_true(!ok3)
}

///|
test "Enter 规则：围栏建代码块（含末块陷阱修复）/ --- 转分隔线" {
  let bs : Array[Block] = [Paragraph([Run("```moon", Marks::default())])]
  let r = doc_apply_enter_rules(bs, csel(0, 7))
  match r {
    Some((b, s)) => {
      assert_eq(kind_of(b, 0), "code:moon")
      assert_eq(s, csel(0, 0))
      assert_eq(b.length(), 2) // 末尾补了可打字段落
      assert_eq(kind_of(b, 1), "p")
    }
    None => fail("围栏应触发")
  }
  let bs2 : Array[Block] = [Paragraph([Run("~~~", Marks::default())])]
  match doc_apply_enter_rules(bs2, csel(0, 3)) {
    Some((b, _)) => assert_eq(kind_of(b, 0), "code:")
    None => fail("~~~ 应触发")
  }
  // 围栏不在行尾 / 含非法语言字符不触发
  let bs3 : Array[Block] = [Paragraph([Run("``` x", Marks::default())])]
  assert_true(doc_apply_enter_rules(bs3, csel(0, 5)).is_none())
  // --- 转分隔线
  let bs4 : Array[Block] = [Paragraph([Run("---", Marks::default())])]
  match doc_apply_enter_rules(bs4, csel(0, 3)) {
    Some((b, s)) => {
      assert_eq(kind_of(b, 0), "hr")
      assert_eq(kind_of(b, 1), "p")
      assert_eq(s, csel(1, 0))
    }
    None => fail("--- 应触发")
  }
  let bs5 : Array[Block] = [Paragraph([Run("--x", Marks::default())])]
  assert_true(doc_apply_enter_rules(bs5, csel(0, 3)).is_none())
}

///|
test "Enter 规则：空列表项退出列表（单项/多项/嵌套守卫）" {
  // 单项 → 列表整体变段落
  let one = [ListBlock(Bullet, [{ checked: None, content: [], children: [] }])]
  match doc_apply_enter_rules(one, csel(0, 0)) {
    Some((b, s)) => {
      assert_eq(kind_of(b, 0), "p")
      assert_eq(b.length(), 1)
      assert_eq(s, csel(0, 0))
    }
    None => fail("单项空列表应退出")
  }
  // 多项：空项退出为段落，前后列表拆分
  let many = [
    ListBlock(Bullet, [
      { checked: None, content: [Run("甲", Marks::default())], children: [] },
      { checked: None, content: [], children: [] },
      { checked: None, content: [Run("丙", Marks::default())], children: [] },
    ]),
  ]
  // 单元：0=甲 1=空 2=丙
  match doc_apply_enter_rules(many, csel(1, 0)) {
    Some((b, s)) => {
      assert_eq([kind_of(b, 0), kind_of(b, 1), kind_of(b, 2)], [
        "bullet", "p", "bullet",
      ])
      assert_eq(s, csel(1, 0))
    }
    None => fail("多项空项应退出")
  }
  // 嵌套子项不触发（落回普通 Enter 拆分）
  let nested = [
    ListBlock(Bullet, [
      {
        checked: None,
        content: [Run("父", Marks::default())],
        children: [
          ListBlock(Bullet, [{ checked: None, content: [], children: [] }]),
        ],
      },
    ]),
  ]
  // 单元：0=父 1=子
  assert_true(doc_apply_enter_rules(nested, csel(1, 0)).is_none())
}

///|
test "ensure_trailing / code_escape" {
  let b = doc_ensure_trailing([CodeBlock("moon", "x")])
  assert_eq(kind_of(b, 1), "p")
  let b2 = doc_ensure_trailing([Paragraph([])])
  assert_eq(b2.length(), 1)
  let b3 = doc_ensure_trailing([])
  assert_eq(b3.length(), 1)

  let doc = parse_doc("```txt\nbody\n```")
  let us = collect_units(doc)
  let mut cu = -1
  for k = 0; k < us.length(); k = k + 1 {
    if us[k].kind == CodeU {
      cu = k
    }
  }
  let (b4, s4) = doc_code_escape(doc, csel(cu, 2))
  assert_eq(kind_of(b4, 1), "p")
  assert_eq(s4, csel(1, 0))
  // 非代码单元无操作
  let p = parse_doc("text\n")
  let (b5, s5) = doc_code_escape(p, csel(0, 1))
  assert_eq(b5, p)
  assert_eq(s5, csel(0, 1))
}

///|
test "doc_paste 多行拆分（含逐行空格规则）" {
  let bs = doc_ensure([])
  let (b, s) = doc_paste(bs, csel(0, 0), "甲\n\n丙")
  assert_eq(pl(b), ["甲", "", "丙"])
  assert_eq(s.focus.unit, 2)
  // 无换行 = 普通插入
  let (b2, _) = doc_paste(bs, csel(0, 0), "abc")
  assert_eq(pl(b2), ["abc"])
  // 「标记+空格」整段粘贴即转列表
  let (b3, _) = doc_paste(doc_ensure([]), csel(0, 0), "- ")
  assert_eq(kind_of(b3, 0), "bullet")
}

///|
test "词移动：英文词 / 中文逐字 / 跨单元" {
  let bs = parse_doc("hello world again\n")
  assert_eq(doc_move_word(bs, csel(0, 17), Right, false), csel(0, 17))
  assert_eq(doc_move_word(bs, csel(0, 0), Right, false), csel(0, 5))
  assert_eq(doc_move_word(bs, csel(0, 5), Right, false), csel(0, 11))
  assert_eq(doc_move_word(bs, csel(0, 17), Left, false), csel(0, 12))
  assert_eq(doc_move_word(bs, csel(0, 12), Left, false), csel(0, 6))
  // extend 保留 anchor
  let sel = Sel::{
    anchor: Caret::{ unit: 0, offset: 0 },
    focus: Caret::{ unit: 0, offset: 0 },
  }
  assert_eq(doc_move_word(bs, sel, Right, true), Sel::{
    anchor: Caret::{ unit: 0, offset: 0 },
    focus: Caret::{ unit: 0, offset: 5 },
  })
  // 中文逐字
  let cn = parse_doc("你好吗\n")
  assert_eq(doc_move_word(cn, csel(0, 3), Left, false), csel(0, 2))
  assert_eq(doc_move_word(cn, csel(0, 0), Right, false), csel(0, 1))
  // 跨单元：行尾 Right → 下一单元 0；行首 Left → 上一单元尾
  let two = parse_doc("one\n\ntwo\n")
  assert_eq(doc_move_word(two, csel(0, 3), Right, false), csel(1, 0))
  assert_eq(doc_move_word(two, csel(1, 0), Left, false), csel(0, 3))
}

///|
test "任务勾选切换" {
  let doc = parse_doc("- [ ] 甲\n- [x] 乙\n")
  let (b1, _) = doc_toggle_task(doc, csel(0, 0))
  match b1[0] {
    ListBlock(Task, its) => assert_eq(its[0].checked, Some(true))
    _ => fail("task")
  }
  let (b2, _) = doc_toggle_task(b1, csel(0, 0))
  match b2[0] {
    ListBlock(Task, its) => assert_eq(its[0].checked, Some(false))
    _ => fail("task")
  }
  let (b3, _) = doc_toggle_task(b2, csel(1, 0))
  match b3[0] {
    ListBlock(Task, its) => assert_eq(its[1].checked, Some(false))
    _ => fail("task")
  }
  // 非任务块无操作
  let p = parse_doc("x\n")
  let (b4, _) = doc_toggle_task(p, csel(0, 0))
  assert_eq(b4, p)
}

///|
test "缩进 / 反缩进（单元下标不变量）" {
  let doc = parse_doc("- 甲\n- 乙\n")
  // 光标在「乙」= 单元 1
  let (b1, s1) = doc_indent(doc, csel(1, 1))
  match b1[0] {
    ListBlock(Bullet, its) => {
      assert_eq(its.length(), 1)
      match its[0].children[0] {
        ListBlock(Bullet, sub) =>
          assert_eq(inlines_plain(sub[0].content), "乙")
        _ => fail("嵌套 bullet")
      }
    }
    _ => fail("bullet")
  }
  assert_eq(s1, csel(1, 1)) // 单元下标不变
  assert_eq(serialize_doc(b1).trim().to_owned(), "- 甲\n  - 乙")
  // 首项无法缩进
  let (b2, _) = doc_indent(doc, csel(0, 0))
  assert_eq(b2, doc)
  // 反缩进出列表变段落
  let (b3, s3) = doc_outdent(doc, csel(1, 1))
  assert_eq([kind_of(b3, 0), kind_of(b3, 1)], ["bullet", "p"])
  assert_eq(s3.focus.unit, 1)
  assert_eq(serialize_doc(b3).trim().to_owned(), "- 甲\n\n乙")
}

///|
test "表格加行 / 删行" {
  let doc = parse_doc("| a | b |\n| - | - |\n| 1 | 2 |\n")
  // 单元：0=a 1=b 2=1 3=2
  let (b1, s1) = doc_table_add_row(doc, csel(2, 0))
  match b1[0] {
    TableBlock(t) => assert_eq(t.rows.length(), 3)
    _ => fail("table")
  }
  assert_eq(s1, csel(4, 0)) // 光标进新行首格（加在光标行之后）
  let (b2, s2) = doc_table_delete_row(b1, csel(4, 0))
  match b2[0] {
    TableBlock(t) => assert_eq(t.rows.length(), 2)
    _ => fail("table")
  }
  assert_eq(s2.focus.unit, 2) // 回到上一行同列格
  // 删到只剩一行 → 退化段落
  let one = [
    TableBlock(Table::{
      rows: [[[Run("x", Marks::default())]]],
      has_header: false,
    }),
  ]
  let (b3, _) = doc_table_delete_row(one, csel(0, 0))
  assert_eq(kind_of(b3, 0), "p")
}

///|
test "活行内转换：字面标记原地变样式 + 光标重映射" {
  let mk2 = fn(s : String) -> Array[Inline] { [Run(s, Marks::default())] }
  // **hi** 末尾敲空格 → bold + 光标落文本尾
  let (r1, o1, c1) = reparse_inlines(mk2("**hi**"), 6)
  assert_true(c1)
  assert_eq(r1, [
    Run("hi", Marks::{ bold: true, italic: false, strike: false, code: false }),
  ])
  assert_eq(o1, 2)
  // `code` 字面
  let (r2, o2, c2) = reparse_inlines(mk2("`cd`"), 5)
  assert_true(c2)
  assert_eq(o2, 2)
  match r2[0] {
    Run(s, m) => {
      assert_eq(s, "cd")
      assert_true(m.code)
    }
    _ => fail("code run")
  }
  // 幂等：已样式化的不再变化（toggle 出的样式往返不丢）
  let styled = [
    Run("hi", Marks::{ bold: true, italic: false, strike: false, code: false }),
  ]
  let (_, _, c3) = reparse_inlines(styled, 2)
  assert_true(!c3)
  // 链接：[t](u) → Link 节点，plain 只剩 t
  let (r4, o4, c4) = reparse_inlines(mk2("[t](u)"), 6)
  assert_true(c4)
  assert_eq(inlines_plain(r4), "t")
  assert_eq(o4, 1)
  match r4[0] {
    Link(_, _) => ()
    _ => fail("link node")
  }
  // 混合：前段字面 + 后段普通，光标在末尾 → 精确
  let mix = [Run("**b**", Marks::default()), Run("tail", Marks::default())]
  let (r5, o5, c5) = reparse_inlines(mix, 9)
  assert_true(c5)
  assert_eq(inlines_plain(r5), "btail")
  assert_eq(o5, 5)
  match r5[0] {
    Run(s, m) => {
      assert_true(m.bold)
      assert_eq(s, "b")
    }
    _ => fail("bold b")
  }
  // 触发集判定
  assert_true(reparse_trigger(" "))
  assert_true(reparse_trigger("*"))
  assert_true(!reparse_trigger("ab1"))
}
