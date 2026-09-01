/// 渲染层纯逻辑测试（不触 FFI）。

fn run_render(src : String) -> Unit {
  let bs = @core.parse_doc(src)
  let cb = @gpui.CommandBuffer::new()
  cb.div()
  cb.set_flex_col()
  render_doc(cb, bs, @core.collapsed_sel(@core.Caret::{ unit: 0, offset: 0 }), fn(u) { u + 1 }, fn(u) { u + 2 })
  cb.set_root()
}

test "渲染命令缓冲含合法 GPUI 头" {
  let bs = @core.parse_doc("# H\n\ntext\n")
  let cb = @gpui.CommandBuffer::new()
  cb.div()
  render_doc(cb, bs, @core.collapsed_sel(@core.Caret::{ unit: 0, offset: 1 }), fn(u) { u + 1 }, fn(u) { u + 2 })
  let bytes = cb.to_bytes()
  assert_true(bytes.length() > 8)
  assert_true(bytes[0] == b'G')
  assert_true(bytes[1] == b'P')
  assert_true(bytes[2] == b'U')
  assert_true(bytes[3] == b'I')
}

test "渲染全元素文档不崩溃" {
  let doc =
    "# T\n\n- a\n  - b\n1. x\n- [ ] t\n\n> q\n\n```py\nx=1\n```\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n![i](u.png)\n\n---\n\n<span>raw</span>\n"
  run_render(doc)
}

test "count_units_of 与 collect_units 一致" {
  let doc =
    "# T\n\n- a\n  - b\n\n> q\n\n| a | b |\n| --- | --- |\n\nx\n"
  let bs = @core.parse_doc(doc)
  let mut total = 0
  for b in bs {
    total = total + count_units_of(b)
  }
  assert_eq(total, @core.collect_units(bs).length())
}

test "行内段含样式与光标" {
  let ns = @core.parse_inline("a**b**")
  let segs = inline_segments(ns, 1, -1, -1)
  let mut found_caret = false
  let mut found_bold = false
  for seg in segs {
    if seg.0 == "▍" {
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
