///|
/// 渲染层纯逻辑测试（不触 FFI）。
fn run_render(src : String) -> Unit {
  let bs = @core.parse_doc(src)
  let cb = @gpui.CommandBuffer::new()
  cb.div()
  cb.set_flex_col()
  render_doc(
    cb,
    bs,
    @core.collapsed_sel(@core.Caret::{ unit: 0, offset: 0 }),
    fn(_) { 1 },
    fn(_) { 2 },
    fn(_, _) { 3 },
  )
  cb.set_root()
}

///|
test "渲染命令缓冲含合法 GPUI 头" {
  let bs = @core.parse_doc("# H\n\ntext\n")
  let cb = @gpui.CommandBuffer::new()
  cb.div()
  render_doc(
    cb,
    bs,
    @core.collapsed_sel(@core.Caret::{ unit: 0, offset: 1 }),
    fn(_) { 1 },
    fn(_) { 2 },
    fn(_, _) { 3 },
  )
  let bytes = cb.to_bytes()
  assert_true(bytes.length() > 8)
  assert_true(bytes[0] == b'G')
  assert_true(bytes[1] == b'P')
  assert_true(bytes[2] == b'U')
  assert_true(bytes[3] == b'I')
}

///|
test "渲染全元素文档不崩溃" {
  let doc = "# T\n\n- a\n  - b\n1. x\n- [ ] t\n\n> q\n\n```py\nx=1\n```\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n![i](u.png)\n\n---\n\n<span>raw</span>\n"
  run_render(doc)
}

///|
test "count_units_of 与 collect_units 一致" {
  let doc = "# T\n\n- a\n  - b\n\n> q\n\n| a | b |\n| --- | --- |\n\nx\n"
  let bs = @core.parse_doc(doc)
  let mut total = 0
  for b in bs {
    total = total + count_units_of(b)
  }
  assert_eq(total, @core.collect_units(bs).length())
}

///|
test "行内段含样式与光标" {
  let ns = @core.parse_inline("a**b**")
  let segs = inline_segments(ns, 1, -1, -1)
  let mut found_caret = false
  let mut found_bold = false
  for seg in segs {
    if seg.0 == "▏" {
      found_caret = true
    }
    match seg.1 {
      Some(st) =>
        if st.weight == Some(700) && seg.0 == "b" {
          found_bold = true
        }
      None => ()
    }
  }
  assert_true(found_caret)
  assert_true(found_bold)
}

///|
test "选区段带背景高亮" {
  let ns = @core.parse_inline("hello")
  let segs = inline_segments(ns, -1, 1, 3)
  let mut bg = 0
  for seg in segs {
    match seg.1 {
      Some(st) =>
        if st.background is Some(_) {
          bg = bg + seg.0.to_array().length()
        }
      None => ()
    }
  }
  assert_eq(bg, 2)
}

///|
test "探针段表：行级合并 + 行尾虚拟段" {
  // 「甲乙」宽折一行 → 单段 [0,2) + 行尾哨兵 2
  let bs = @core.parse_doc("甲乙\n")
  let cb = @gpui.CommandBuffer::new()
  cb.div()
  render_doc(
    cb,
    bs,
    @core.collapsed_sel(@core.Caret::{ unit: 0, offset: 0 }),
    fn(_) { 1 },
    fn(_) { 2 },
    fn(_, _) { 3 },
  )
  assert_eq(tok_starts_of(0), [0, 2])
}

///|
test "探针段表：光标所在行分裂为两段" {
  // "hello world" 折一行 [0,11)；光标在 3 → 行劈成两段 [0,3) [3,11)，
  // 段起点表 [0,3,11]，右段左缘 = 零宽光标位置
  let bs = @core.parse_doc("hello world\n")
  let cb = @gpui.CommandBuffer::new()
  cb.div()
  render_doc(
    cb,
    bs,
    @core.collapsed_sel(@core.Caret::{ unit: 0, offset: 3 }),
    fn(_) { 1 },
    fn(_) { 2 },
    fn(_, _) { 3 },
  )
  assert_eq(tok_starts_of(0), [0, 3, 11])
}

///|
test "探针段表：拉丁词聚合折一行一段" {
  let bs = @core.parse_doc("hello world\n")
  let cb = @gpui.CommandBuffer::new()
  cb.div()
  render_doc(
    cb,
    bs,
    @core.collapsed_sel(@core.Caret::{ unit: 0, offset: 0 }),
    fn(_) { 1 },
    fn(_) { 2 },
    fn(_, _) { 3 },
  )
  assert_eq(tok_starts_of(0), [0, 11])
}

///|
test "探针段表：超宽段落按行切段、起点严格递增、末端为单元长" {
  // 重复短语超出渲染宽度 → 多行；每行一段，段表 = 各行起点 + 长度哨兵
  let mut long : String = ""
  for i = 0; i < 40; i = i + 1 {
    long = long + "The quick brown fox "
  }
  let bs = @core.parse_doc(long + "\n")
  let ulen = @core.collect_units(bs)[0].plain.to_array().length()
  let cb = @gpui.CommandBuffer::new()
  cb.div()
  render_doc(
    cb,
    bs,
    @core.collapsed_sel(@core.Caret::{ unit: 0, offset: 0 }),
    fn(_) { 1 },
    fn(_) { 2 },
    fn(_, _) { 3 },
  )
  let starts = tok_starts_of(0)
  assert_true(starts.length() > 3) // 多行
  assert_eq(starts[0], 0)
  assert_eq(starts[starts.length() - 1], ulen)
  for i in 1..<starts.length() {
    assert_true(starts[i] > starts[i - 1])
  }
}

///|
test "token 布局表：空单元也有点击区" {
  // doc_ensure 会在文末补空段落作为最后一个单元
  let bs = @core.doc_ensure(@core.parse_doc(""))
  let empty_u = @core.collect_units(bs).length() - 1
  let cb = @gpui.CommandBuffer::new()
  cb.div()
  render_doc(
    cb,
    bs,
    @core.collapsed_sel(@core.Caret::{ unit: empty_u, offset: 0 }),
    fn(_) { 1 },
    fn(_) { 2 },
    fn(_, _) { 3 },
  )
  assert_eq(tok_starts_of(empty_u), [0, 0])
}

///|
fn cb_contains(hay : Bytes, needle : String) -> Bool {
  let n = @utf8.encode(needle)
  let hl = hay.length() - n.length()
  let mut i = 0
  while i <= hl {
    let mut j = 0
    while j < n.length() && hay[i + j] == n[j] {
      j = j + 1
    }
    if j == n.length() {
      return true
    }
    i = i + 1
  }
  false
}

///|
test "组词预览：set_preedit 后光标处命令缓冲浮动渲染组词文本" {
  let bs = @core.parse_doc("正文\n")
  let sel = @core.collapsed_sel(@core.Caret::{ unit: 0, offset: 0 })
  set_preedit("nihao")
  let cb = @gpui.CommandBuffer::new()
  cb.div()
  render_doc(cb, bs, sel, fn(_) { 1 }, fn(_) { 2 }, fn(_, _) { 3 })
  assert_true(cb_contains(cb.to_bytes(), "nihao"))
  // 覆盖层必须带 caret key：桥层 CaretBoundsProbe 据此捕获候选窗锚点矩形
  assert_true(cb_contains(cb.to_bytes(), "caret"))
  // 清空组词后光标处恢复干净（提交/取消路径）
  set_preedit("")
  let cb2 = @gpui.CommandBuffer::new()
  cb2.div()
  render_doc(cb2, bs, sel, fn(_) { 1 }, fn(_) { 2 }, fn(_, _) { 3 })
  assert_true(!cb_contains(cb2.to_bytes(), "nihao"))
  assert_true(cb_contains(cb2.to_bytes(), "caret"))
}
