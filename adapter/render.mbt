/// GPUI 适配层（渲染侧）：块树 → gpui 命令缓冲。
///
/// 策略：每个「编辑单元」渲染成一个可点击 div（段落/标题行/列表项/表格
/// 格/代码块整体…）；任务项的 ☑/☐ 标记是独立点击区域（勾选切换）。
/// 块内文本用 `rich_text`（多 run 样式）渲染；光标（▍）通过把 run 在光标
/// 偏移处切开插入高亮段实现；选区用背景色高亮。框架的 click 事件不带坐标
/// （见 docs/framework-gaps.md），因此点击单元 = 光标落到该单元尾部——
/// 「点哪到哪」在约束内的最大逼近。
///
/// 本文件不做任何 FFI 调用（只写 CommandBuffer 字节），因此可以被
/// `moon test` 通过 `to_bytes` 直接验证。

///|
pub type Seg = (String, @gpui.RunStyle?)

let col_text : (Int, Int, Int) = (226, 230, 238)
let col_muted : (Int, Int, Int) = (140, 146, 158)
let col_link : (Int, Int, Int) = (96, 168, 255)
let col_caret : (Int, Int, Int) = (96, 210, 255)
let col_code : (Int, Int, Int) = (240, 190, 130)
let col_codebg : (Int, Int, Int) = (48, 52, 64)
let col_sel : (Int, Int, Int) = (58, 78, 122)
let col_mark : (Int, Int, Int) = (110, 190, 250)
let sel_full : Int = 1_000_000

fn rgb(c : (Int, Int, Int)) -> @gpui.Color {
  @gpui.Color::rgb(c.0, c.1, c.2)
}

fn caret_seg() -> Seg {
  ("▍", Some(@gpui.RunStyle::new(color=rgb(col_caret), weight=700)))
}

/// 把 Marks 映射为 RunStyle 覆盖；链接内文本加色+下划线。
fn style_of(m : @core.Marks, link : Bool) -> @gpui.RunStyle? {
  if !(m.bold || m.italic || m.strike || m.code || link) {
    return None
  }
  let mut color = if m.code { Some(rgb(col_code)) } else { None }
  if link {
    color = Some(rgb(col_link))
  }
  Some(@gpui.RunStyle::{
    color,
    weight: if m.bold { Some(700) } else { None },
    italic: m.italic,
    underline: link,
    strikethrough: m.strike,
    background: if m.code { Some(rgb(col_codebg)) } else { None },
  })
}

fn merge_style(base : @gpui.RunStyle?, extra : @gpui.RunStyle?) -> @gpui.RunStyle? {
  match (base, extra) {
    (None, e) => e
    (b, None) => b
    (Some(a), Some(c)) =>
      Some(@gpui.RunStyle::{
        color: if c.color is Some(_) { c.color } else { a.color },
        weight: if c.weight is Some(_) { c.weight } else { a.weight },
        italic: a.italic || c.italic,
        underline: a.underline || c.underline,
        strikethrough: a.strikethrough || c.strikethrough,
        background: if c.background is Some(_) { c.background } else { a.background },
      })
  }
}

/// st 游标数组: [0]=caret(-1 无) [1]=sel_lo [2]=sel_hi [3]=caret_done [4]=pos
fn emit_text(out : Array[Seg], text : String, st : Array[Int], base : @gpui.RunStyle?) -> Unit {
  let cs = text.to_array()
  let len = cs.length()
  let start = st[4]
  if st[3] == 0 && st[0] >= start && st[0] < start + len && st[0] == start {
    out.push(caret_seg())
    st[3] = 1
  }
  let mut i = 0
  while i < len {
    if st[3] == 0 && start + i == st[0] {
      out.push(caret_seg())
      st[3] = 1
    }
    let in_sel = st[2] > st[1] && (start + i) >= st[1] && (start + i) < st[2]
    let mut j = i + 1
    while j < len {
      let still_sel = st[2] > st[1] && (start + j) >= st[1] && (start + j) < st[2]
      let caret_at = st[3] == 0 && start + j == st[0]
      if still_sel != in_sel || caret_at {
        break
      }
      j = j + 1
    }
    let piece = String::from_array(cs[i:j])
    out.push((
      piece,
      if in_sel {
        merge_style(base, Some(@gpui.RunStyle::new(background=rgb(col_sel))))
      } else {
        base
      },
    ))
    i = j
  }
  st[4] = start + len
  if st[3] == 0 && st[0] >= start && st[4] >= st[0] {
    out.push(caret_seg())
    st[3] = 1
  }
}

fn emit_inlines(out : Array[Seg], ns : Array[@core.Inline], st : Array[Int]) -> Unit {
  for n in ns {
    match n {
      @core.Run(s, m) => emit_text(out, s, st, style_of(m, false))
      @core.Link(_, inner) => {
        let sub : Array[Seg] = []
        let st2 = [st[0], st[1], st[2], 0, st[4]]
        emit_inlines(sub, inner, st2)
        let link_style = style_of(@core.Marks::default(), true)
        for seg in sub {
          out.push((seg.0, merge_style(link_style, seg.1)))
        }
        if st2[3] == 1 {
          st[3] = 1
        }
        st[4] = st2[4]
      }
      @core.Image(_, _) =>
        emit_text(out, @core.inline_plain(n), st, Some(
          @gpui.RunStyle::new(color=rgb(col_mark), italic=true),
        ))
      @core.Footnote(nm) =>
        emit_text(out, "[^" + nm + "]", st, Some(@gpui.RunStyle::new(color=rgb(col_link))))
    }
  }
  if st[3] == 0 && st[4] >= st[0] && st[0] >= 0 {
    out.push(caret_seg())
    st[3] = 1
  }
}

///|
/// 一组 inline → 渲染段。`caret`/`sel_lo`/`sel_hi` 是相对 `ns` 的字符偏移
/// （负数表示不存在；sel 空时 lo==hi==-1）。
pub fn inline_segments(
  ns : Array[@core.Inline],
  caret : Int,
  sel_lo : Int,
  sel_hi : Int,
) -> Array[Seg] {
  let out : Array[Seg] = []
  let st = [caret, sel_lo, sel_hi, 0, 0]
  emit_inlines(out, ns, st)
  if st[3] == 0 && st[0] >= 0 {
    out.push(caret_seg())
  }
  out
}

fn heading_size(level : Int) -> Float {
  match level {
    1 => 30.0
    2 => 25.0
    3 => 21.0
    4 => 18.0
    5 => 16.0
    _ => 15.0
  }
}

///|
/// 一个块产出的编辑单元数（与 core::collect_units 的顺序契约一致）。
pub fn count_units_of(b : @core.Block) -> Int {
  match b {
    @core.Heading(_, _) | @core.Paragraph(_) | @core.CodeBlock(_, _) | @core.Hr | @core.ImageBlock(_, _) | @core.Raw(_) => 1
    @core.Quote(inner) => sum_int(inner.map(count_units_of))
    @core.ListBlock(_, items) =>
      sum_int(items.map(it => 1 + sum_int(it.children.map(count_units_of))))
    @core.TableBlock(t) => sum_int(t.rows.map(row => row.length()))
  }
}

/// 选区规范化端点 → 当前单元 (cursor, lo, hi)
fn unit_sel_window(sel_a : @core.Caret, sel_b : @core.Caret, cur : Int) -> (Int, Int, Int) {
  if sel_a == sel_b {
    return (if sel_a.unit == cur { sel_a.offset } else { -1 }, -1, -1)
  }
  // 有选区：光标显示在 focus（sel_b）所在单元
  let caret = if sel_b.unit == cur { sel_b.offset } else { -1 }
  let lo =
    if sel_a.unit < cur && cur < sel_b.unit {
      0
    } else if sel_a.unit == cur {
      sel_a.offset
    } else {
      -1
    }
  let hi =
    if cur < sel_b.unit {
      if lo == 0 || lo > 0 { sel_full } else { -1 }
    } else if cur == sel_b.unit {
      if lo >= 0 { sel_b.offset } else { -1 }
    } else {
      -1
    }
  (caret, lo, hi)
}

fn push_rich(
  cb : @gpui.CommandBuffer,
  segs : Array[Seg],
  size : Float,
  mono : Bool,
) -> Unit {
  if segs.length() == 0 {
    cb.text(" ", col_text.0, col_text.1, col_text.2, size)
    cb.add_child()
    return
  }
  if mono {
    cb.set_font_family("ui-monospace")
  }
  cb.rich_text(segs, col_text.0, col_text.1, col_text.2, size)
  cb.add_child()
}

///|
/// 把整个文档渲染进命令缓冲（不含根 div；调用方已 push 根）。
pub fn render_doc(
  cb : @gpui.CommandBuffer,
  blocks : Array[@core.Block],
  sel : @core.Sel,
  reg : (Int) -> Int,
  rbox : (Int) -> Int,
) -> Unit {
  let sel_a = @core.sel_start(sel)
  let sel_b = @core.sel_end(sel)
  let mut cur = 0
  for i = 0; i < blocks.length(); i = i + 1 {
    render_slot(cb, blocks[i], cur, sel_a, sel_b, reg, rbox)
    cur = cur + count_units_of(blocks[i])
  }
}

// 叶子块 = 单元点击区；容器块（引用/列表/表格）由 render_block 给内部
// 每个单元自带点击区，外层 div 不响应点击。
fn render_slot(
  cb : @gpui.CommandBuffer,
  b : @core.Block,
  cur : Int,
  sel_a : @core.Caret,
  sel_b : @core.Caret,
  reg : (Int) -> Int,
  rbox : (Int) -> Int,
) -> Unit {
  let container = match b {
    @core.Quote(_) | @core.ListBlock(_, _) | @core.TableBlock(_) => true
    _ => false
  }
  cb.div()
  if !container {
    cb.set_cursor(@gpui.CURSOR_TEXT)
    cb.set_whitespace(@gpui.WHITESPACE_PRE_WRAP)
    cb.set_padding_sides(2, 6, 2, 6)
    cb.set_on_click(reg(cur))
  }
  render_block(cb, b, cur, sel_a, sel_b, reg, rbox)
  cb.add_child()
}

fn header_bold(segs : Array[Seg]) -> Array[Seg] {
  segs.map(sg => (sg.0, merge_style(sg.1, Some(@gpui.RunStyle::new(weight=700)))))
}

fn render_block(
  cb : @gpui.CommandBuffer,
  b : @core.Block,
  cur : Int,
  sel_a : @core.Caret,
  sel_b : @core.Caret,
  reg : (Int) -> Int,
  rbox : (Int) -> Int,
) -> Unit {
  // 叶子块的单元就是 cur；容器块（列表/表格）内每个单元各自重算窗口
  let (caret, lo, hi) = unit_sel_window(sel_a, sel_b, cur)
  match b {
    @core.Heading(l, inls) => {
      cb.set_font_weight(700)
      push_rich(cb, inline_segments(inls, caret, lo, hi), heading_size(l), false)
    }
    @core.Paragraph(inls) => push_rich(
      cb,
      inline_segments(inls, caret, lo, hi),
      15.0,
      false,
    )
    @core.CodeBlock(lang, code) => {
      if lang != "" {
        cb.text(lang, col_muted.0, col_muted.1, col_muted.2, 11.0)
        cb.add_child()
      }
      render_code(cb, code, caret, lo, hi)
    }
    @core.Quote(inner) => {
      cb.set_bg_color(@gpui.Color::rgb(36, 39, 48))
      cb.set_border_color(2.0, @gpui.Color::rgb(80, 90, 110))
      cb.set_rounded(6.0)
      cb.set_padding_sides(6, 12, 6, 12)
      cb.set_flex_col()
      cb.set_gap(4.0)
      let mut c2 = cur
      for ib in inner {
        render_slot(cb, ib, c2, sel_a, sel_b, reg, rbox)
        c2 = c2 + count_units_of(ib)
      }
    }
    @core.ListBlock(kind, items) => {
      cb.set_flex_col()
      cb.set_gap(2.0)
      let mut c2 = cur
      let mut idx = 0
      for it in items {
        cb.div()
        cb.set_flex_row()
        cb.set_gap(6.0)
        let marker = match kind {
          @core.Bullet => "•"
          @core.Ordered(s0) => (s0 + idx).to_string() + "."
          @core.Task =>
            match it.checked {
              Some(true) => "☑"
              _ => "☐"
            }
        }
        if kind == @core.Task {
          // 任务框：独立点击区 → 勾选切换
          cb.div()
          cb.set_cursor(@gpui.CURSOR_POINTER)
          cb.set_padding_sides(0, 4, 0, 2)
          cb.set_on_click(rbox(c2))
          cb.text(marker, col_mark.0, col_mark.1, col_mark.2, 15.0)
          cb.add_child()
          cb.add_child()
        } else {
          cb.text(marker, col_mark.0, col_mark.1, col_mark.2, 15.0)
          cb.add_child()
        }
        cb.div()
        cb.set_flex(1.0, 1.0, 0.0)
        cb.set_cursor(@gpui.CURSOR_TEXT)
        cb.set_whitespace(@gpui.WHITESPACE_PRE_WRAP)
        cb.set_on_click(reg(c2))
        let (ic, ilo, ihi) = unit_sel_window(sel_a, sel_b, c2)
        push_rich(cb, inline_segments(it.content, ic, ilo, ihi), 15.0, false)
        cb.add_child()
        cb.add_child() // row
        if it.children.length() > 0 {
          cb.div()
          cb.set_padding_sides(2, 0, 2, 22)
          cb.set_flex_col()
          cb.set_gap(2.0)
          c2 = c2 + 1
          for ch in it.children {
            render_slot(cb, ch, c2, sel_a, sel_b, reg, rbox)
            c2 = c2 + count_units_of(ch)
          }
          cb.add_child()
        } else {
          c2 = c2 + 1
        }
        idx = idx + 1
      }
    }
    @core.TableBlock(t) => {
      cb.set_flex_col()
      let mut c2 = cur
      let mut ri = 0
      for row in t.rows {
        cb.div()
        cb.set_flex_row()
        for cell in row {
          cb.div()
          cb.set_cursor(@gpui.CURSOR_TEXT)
          cb.set_border_color(1.0, @gpui.Color::rgb(70, 76, 92))
          cb.set_padding_sides(4, 10, 4, 10)
          cb.set_min_size(60, 0)
          cb.set_on_click(reg(c2))
          let (cc, clo, chi) = unit_sel_window(sel_a, sel_b, c2)
          let segs = inline_segments(cell, cc, clo, chi)
          push_rich(
            cb,
            if t.has_header && ri == 0 { header_bold(segs) } else { segs },
            14.0,
            false,
          )
          cb.add_child()
          c2 = c2 + 1
        }
        cb.add_child()
        ri = ri + 1
      }
    }
    @core.ImageBlock(alt, url) => {
      cb.set_flex_row()
      cb.set_gap(8.0)
      cb.text("⛁", col_mark.0, col_mark.1, col_mark.2, 16.0)
      cb.add_child()
      cb.text(alt + "  ·  " + url, col_muted.0, col_muted.1, col_muted.2, 13.0)
      cb.add_child()
    }
    @core.Hr => {
      cb.set_padding_sides(6, 6, 6, 6)
      cb.div()
      cb.set_bg_color(@gpui.Color::rgb(70, 76, 92))
      cb.set_min_size(0, 2)
      cb.add_child()
    }
    @core.Raw(_) => {
      cb.set_font_family("ui-monospace")
      let segs : Array[Seg] = [
        (
          "⚠ 原样保留  ",
          Some(@gpui.RunStyle::new(color=rgb(col_muted), italic=true)),
        ),
      ]
      let st = [caret, lo, hi, 0, 0]
      emit_text(segs, @core.block_plain(b), st, Some(
        @gpui.RunStyle::new(color=rgb(col_muted), background=rgb(col_codebg)),
      ))
      if st[3] == 0 && caret >= 0 {
        segs.push(caret_seg())
      }
      push_rich(cb, segs, 13.0, true)
    }
  }
}

fn render_code(
  cb : @gpui.CommandBuffer,
  code : String,
  caret : Int,
  lo : Int,
  hi : Int,
) -> Unit {
  cb.set_bg_color(@gpui.Color::rgb(22, 24, 30))
  cb.set_rounded(8.0)
  cb.set_padding_sides(10, 14, 10, 14)
  cb.set_flex_col()
  cb.set_font_family("ui-monospace")
  cb.set_whitespace(@gpui.WHITESPACE_PRE_WRAP)
  let lines = @core.split_lines_str(code)
  let mut line_start = 0
  if lines.length() == 0 {
    cb.set_min_size(0, 22)
    return
  }
  for line in lines {
    let len = line.to_array().length()
    let (lc, ll, lh) = line_window(caret, lo, hi, line_start, len)
    let st = [lc, ll, lh, 0, 0]
    let segs : Array[Seg] = []
    emit_text(segs, if line == "" { " " } else { line }, st, Some(
      @gpui.RunStyle::new(color=rgb(col_code)),
    ))
    if st[3] == 0 && lc >= 0 {
      segs.push(caret_seg())
    }
    cb.rich_text(segs, col_text.0, col_text.1, col_text.2, 13.5)
    cb.add_child()
    line_start = line_start + len + 1
  }
}

// 全局字符范围映射到行内范围
fn line_window(caret : Int, lo : Int, hi : Int, ls : Int, len : Int) -> (Int, Int, Int) {
  let le = ls + len
  let c = if caret >= ls && caret <= le { caret - ls } else { -1 }
  let mut l = -1
  let mut h = -1
  if hi > lo {
    let a = (if lo < ls { ls } else { lo }) - ls
    let b = (if hi > le { le } else { hi }) - ls
    if b > a {
      l = a
      h = b
    } else if lo <= ls && hi >= le {
      l = 0
      h = len
    }
  }
  (c, l, h)
}

fn sum_int(xs : Array[Int]) -> Int {
  let mut s = 0
  for x in xs {
    s = s + x
  }
  s
}
