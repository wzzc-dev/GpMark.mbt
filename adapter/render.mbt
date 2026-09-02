/// GPUI 适配层（渲染侧）：块树 → gpui 命令缓冲。
///
/// 策略：每个「编辑单元」拆成 token 渲染（CJK 一字一 token、拉丁词一词，
/// 见 textlayout.mbt）。token 是独立点击区：点击 = 光标落该 token 起点，
/// 实现「点哪停哪」的近似（框架 click 不带坐标，framework gap §1）；折行
/// 由 MoonBit 按估算宽度自算（无文本度量接口，gap §4）。任务项 ☑/☐ 是独立
/// 点击区（勾选切换）；表格列宽全表统一（min+max size 锁宽）保证对齐。
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

// demo 窗口宽 960；滚动容器左右 padding 28*2；单元左右 padding 6*2。
// 折行按这个估算宽度进行（窗口缩放不会重新折行——已知限制）。
let base_avail : Float = 960.0 - 56.0 - 14.0

fn rgb(c : (Int, Int, Int)) -> @gpui.Color {
  @gpui.Color::rgb(c.0, c.1, c.2)
}

fn caret_seg() -> Seg {
  ("▏", Some(@gpui.RunStyle::new(color=rgb(col_caret))))
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

// --- 字符级样式流（token 渲染路径用，字符序与 core::inlines_plain 一致）---

fn push_run_chars(
  out : Array[@gpui.RunStyle?],
  s : String,
  lo : Int,
  hi : Int,
  base : @gpui.RunStyle?,
  pos : Array[Int],
) -> Unit {
  let cs = s.to_array()
  let mut j = 0
  while j < cs.length() {
    let p = pos[0]
    out.push(
      if hi > lo && p >= lo && p < hi {
        merge_style(base, Some(@gpui.RunStyle::new(background=rgb(col_sel))))
      } else {
        base
      },
    )
    pos[0] = p + 1
    j = j + 1
  }
}

fn push_char_styles(
  out : Array[(@gpui.RunStyle)?],
  ns : Array[@core.Inline],
  lo : Int,
  hi : Int,
  base : @gpui.RunStyle?,
  pos : Array[Int],
) -> Unit {
  for n in ns {
    match n {
      @core.Run(s, m) =>
        push_run_chars(out, s, lo, hi, merge_style(base, style_of(m, false)), pos)
      @core.Link(_, inner) =>
        push_char_styles(
          out,
          inner,
          lo,
          hi,
          merge_style(base, style_of(@core.Marks::default(), true)),
          pos,
        )
      @core.Image(_, _) =>
        push_run_chars(
          out,
          @core.inline_plain(n),
          lo,
          hi,
          merge_style(base, Some(@gpui.RunStyle::new(color=rgb(col_mark), italic=true))),
          pos,
        )
      @core.Footnote(nm) =>
        push_run_chars(
          out,
          "[^" + nm + "]",
          lo,
          hi,
          merge_style(base, Some(@gpui.RunStyle::new(color=rgb(col_link)))),
          pos,
        )
    }
  }
}

fn char_styles(
  ns : Array[@core.Inline],
  lo : Int,
  hi : Int,
  bold : Bool,
) -> Array[(@gpui.RunStyle)?] {
  let out : Array[(@gpui.RunStyle)?] = []
  let base = if bold { Some(@gpui.RunStyle::new(weight=700)) } else { None }
  push_char_styles(out, ns, lo, hi, base, [0])
  out
}

// --- token 布局表（点击定位契约：app 侧按单元下标查 token 起点）-----------

let unit_starts : Array[Array[Int]] = []

fn remember_starts(unit : Int, starts : Array[Int]) -> Unit {
  while unit_starts.length() <= unit {
    unit_starts.push([])
  }
  unit_starts[unit] = starts
}

///|
/// 单元 `unit` 各 token 的起始字符偏移 + 末尾单元长度（作为「行尾空白区」
/// 的虚拟 token）。空数组表示该单元不是 token 渲染的（代码块等）。
pub fn tok_starts_of(unit : Int) -> Array[Int] {
  if unit >= 0 && unit < unit_starts.length() {
    unit_starts[unit]
  } else {
    []
  }
}

fn col_eq(a : @gpui.Color, b : @gpui.Color) -> Bool {
  a.red == b.red && a.green == b.green && a.blue == b.blue && a.alpha == b.alpha
}

fn copt_eq(a : (@gpui.Color)?, b : (@gpui.Color)?) -> Bool {
  match (a, b) {
    (None, None) => true
    (Some(x), Some(y)) => col_eq(x, y)
    _ => false
  }
}

fn sty_eq(a : (@gpui.RunStyle)?, b : (@gpui.RunStyle)?) -> Bool {
  match (a, b) {
    (None, None) => true
    (Some(x), Some(y)) =>
      copt_eq(x.color, y.color) &&
        x.weight == y.weight &&
        x.italic == y.italic &&
        x.underline == y.underline &&
        x.strikethrough == y.strikethrough &&
        copt_eq(x.background, y.background)
    _ => false
  }
}

// token 字符范围 → 渲染段（同样式相邻字符合并；光标恰好插在偏移处）
fn token_segs(
  chars : Array[Char],
  styles : Array[(@gpui.RunStyle)?],
  s : Int,
  e : Int,
) -> Array[Seg] {
  let out : Array[Seg] = []
  let mut i = s
  while i < e {
    let mut j = i + 1
    while j < e && sty_eq(styles[j], styles[i]) {
      j = j + 1
    }
    out.push((String::from_array(chars[i:j]), styles[i]))
    i = j
  }
  out
}

// --- IME 组词内联预览 -------------------------------------------------------
// 组词文本由 app.rebuild 每次重建前推入（set_preedit）。渲染在挂 token
// div 左缘的浮动行上（绝对定位，不占宽度、不推文字）：行内先是下划线组词
// 文本、后是光标条——插入点在组词文本之后。取代旧的顶栏「输入中」组合条。
// 浮动行 key="caret"，桥层（gpui-sys）据此捕获其窗口矩形做候选窗锚点。

let preedit_text : Ref[String] = { val: "" }

///|
/// 推入当前组词文本（空串 = 无组词）。须在 render_doc_window 之前调用。
pub fn set_preedit(text : String) -> Unit { preedit_text.val = text }

/// 零宽光标：绝对定位的 2px 光标条，挂在 token div 内左缘——脱离排版
/// 流，不占宽度、不推走后面的字；top/bottom=0 使高度自动等于行高。
/// 它自己带同款点击 handler，2px 条带上的点击不会落空。
/// 组词中时整个覆盖层是一行 `[组词文本][光标条]`：光标条顺排在下划线
/// 组词文本之后（输入法的插入点在组词文本末尾），行底用页面色垫住。
/// 覆盖层 key="caret"：桥层据此捕获其窗口矩形，作为 IME 候选窗锚点。
fn caret_overlay(
  cb : @gpui.CommandBuffer,
  unit : Int,
  ti : Int,
  rtok : (Int, Int) -> Int,
  size : Float,
) -> Unit {
  if preedit_text.val == "" {
    cb.div()
    cb.set_position(@gpui.POSITION_ABSOLUTE)
    cb.set_inset(0, -1, 0, 0)
    cb.set_min_size(2, -1)
    cb.set_bg_color(rgb(col_caret))
    cb.set_on_click(rtok(unit, ti))
    cb.set_key("caret")
    cb.add_child()
  } else {
    cb.div()
    cb.set_position(@gpui.POSITION_ABSOLUTE)
    cb.set_inset(0, -1, 0, 0)
    cb.set_flex_row()
    cb.set_bg_color(@gpui.Color::rgb(28, 30, 38))
    cb.set_on_click(rtok(unit, ti))
    cb.set_key("caret")
    cb.rich_text(
      [(
        preedit_text.val,
        Some(@gpui.RunStyle::new(underline=true, color=rgb(col_caret))),
      )],
      col_text.0,
      col_text.1,
      col_text.2,
      size,
    )
    cb.add_child()
    cb.div()
    cb.set_min_size(2, -1)
    cb.set_bg_color(rgb(col_caret))
    cb.add_child()
    cb.add_child()
  }
}

fn tail_zone(
  cb : @gpui.CommandBuffer,
  unit : Int,
  ti : Int,
  rtok : (Int, Int) -> Int,
  show_caret : Bool,
  size : Float,
) -> Unit {
  cb.div()
  cb.set_flex(1.0, 0.0, 0.0)
  cb.set_cursor(@gpui.CURSOR_TEXT)
  cb.set_on_click(rtok(unit, ti))
  if show_caret {
    caret_overlay(cb, unit, ti, rtok, size)
  }
  cb.add_child()
}

/// 一段 inline 文本 → 折行的 token 行。caret/lo/hi 语义同 inline_segments。
fn push_text(
  cb : @gpui.CommandBuffer,
  ns : Array[@core.Inline],
  caret : Int,
  lo : Int,
  hi : Int,
  size : Float,
  avail : Float,
  unit : Int,
  rtok : (Int, Int) -> Int,
  bold : Bool,
) -> Unit {
  let chars = @core.inlines_plain(ns).to_array()
  let styles = char_styles(ns, lo, hi, bold)
  let lays = layout_text(chars, size, avail)
  if lays.toks.length() == 0 {
    // 空单元：占位 token（点击/光标都在 0），外加行尾空白区
    remember_starts(unit, [0, 0])
    cb.div()
    cb.set_flex_col()
    cb.div()
    cb.set_flex_row()
    cb.div()
    cb.set_cursor(@gpui.CURSOR_TEXT)
    cb.set_whitespace(@gpui.WHITESPACE_PRE_WRAP)
    cb.set_on_click(rtok(unit, 0))
    cb.rich_text([(" ", None)], col_text.0, col_text.1, col_text.2, size)
    cb.add_child() // rich_text → token div
    if caret == 0 {
      caret_overlay(cb, unit, 0, rtok, size)
    }
    cb.add_child() // token div → row
    tail_zone(cb, unit, 1, rtok, false, size)
    cb.add_child() // row → container
    cb.add_child() // container → slot
    return
  }
  // 光标落在 token 内部时把该 token 切成两个子 token——右半段的左缘正是
  // 光标位置，零宽光标条就画在那里（不插字符、不推文字）。
  let sub_rows : Array[Array[(Int, Int, Int)]] = [] // (start, len, 全局子 token 下标)
  let starts : Array[Int] = []
  let mut si = 0
  for row in lays.rows {
    let r : Array[(Int, Int, Int)] = []
    for ti in row {
      let t = lays.toks[ti]
      if caret > t.0 && caret < t.0 + t.1 {
        r.push((t.0, caret - t.0, si))
        starts.push(t.0)
        si = si + 1
        r.push((caret, t.0 + t.1 - caret, si))
        starts.push(caret)
        si = si + 1
      } else {
        r.push((t.0, t.1, si))
        starts.push(t.0)
        si = si + 1
      }
    }
    sub_rows.push(r)
  }
  starts.push(chars.length()) // 行尾空白区 = 下标 si，点击/光标 = 单元尾
  remember_starts(unit, starts)
  cb.div()
  cb.set_flex_col()
  let nrows = sub_rows.length()
  let mut ri = 0
  for row in sub_rows {
    cb.div()
    cb.set_flex_row()
    for t in row {
      cb.div()
      cb.set_cursor(@gpui.CURSOR_TEXT)
      cb.set_whitespace(@gpui.WHITESPACE_PRE_WRAP)
      cb.set_on_click(rtok(unit, t.2))
      cb.rich_text(
        token_segs(chars, styles, t.0, t.0 + t.1),
        col_text.0,
        col_text.1,
        col_text.2,
        size,
      )
      cb.add_child() // rich_text → token div
      if t.0 == caret {
        caret_overlay(cb, unit, t.2, rtok, size)
      }
      cb.add_child() // token div → row
    }
    if ri == nrows - 1 {
      tail_zone(cb, unit, si, rtok, caret == chars.length(), size)
    }
    cb.add_child()
    ri = ri + 1
  }
  cb.add_child()
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
  rtok : (Int, Int) -> Int,
) -> Unit {
  render_doc_window(cb, blocks, 0, blocks.length(), 0, sel, reg, rbox, rtok)
}

///|
/// 窗口化渲染：blocks[lo..hi)，cur 从 cur0 起算。app.rebuild 只提交可视
/// 窗口（上下留 overscan），窗口外块由 app 层的两个 spacer div 撑出滚动
/// 行程；全树提交会让 GPUI 对整个文档做 layout，成本随总块数线性增长。
pub fn render_doc_window(
  cb : @gpui.CommandBuffer,
  blocks : Array[@core.Block],
  lo : Int,
  hi : Int,
  cur0 : Int,
  sel : @core.Sel,
  reg : (Int) -> Int,
  rbox : (Int) -> Int,
  rtok : (Int, Int) -> Int,
) -> Unit {
  let sel_a = @core.sel_start(sel)
  let sel_b = @core.sel_end(sel)
  let mut cur = cur0
  for i = lo; i < hi; i = i + 1 {
    render_slot(cb, blocks[i], cur, sel_a, sel_b, reg, rbox, rtok, base_avail)
    cur = cur + count_units_of(blocks[i])
  }
}

// --- 高度估算（虚拟窗口）----------------------------------------------------
// 与渲染共用同一个折行估算器（textlayout::layout_text），各块类型的附加
// 常数与 render_block 的分支一一对应，spacer 高度因此 ≈ 实际渲染高度
// （宽度估算本身有 ±10% 级别出入，见 framework-gaps §4，滚动行程为近似）。

fn line_h(size : Float) -> Float { size * 1.63 }

fn text_rows(ns : Array[@core.Inline], size : Float, avail : Float) -> Int {
  let n = layout_text(@core.inlines_plain(ns).to_array(), size, avail).rows.length()
  if n == 0 { 1 } else { n }
}

///|
/// 单块的渲染高度（含 render_slot 的非容器 padding），avail 为块级可用宽。
pub fn estimate_slot_height(b : @core.Block, avail : Float) -> Float {
  let inner = estimate_block_height(b, avail - 12.0)
  match b {
    @core.Quote(_) | @core.ListBlock(_, _) | @core.TableBlock(_) => inner
    _ => inner + 4.0
  }
}

fn estimate_block_height(b : @core.Block, avail : Float) -> Float {
  match b {
    @core.Heading(l, inls) =>
      Float::from_int(text_rows(inls, heading_size(l), avail)) * line_h(heading_size(l))
    @core.Paragraph(inls) => Float::from_int(text_rows(inls, 15.0, avail)) * line_h(15.0)
    @core.CodeBlock(lang, code) => {
      let label : Float = if lang != "" { line_h(11.0) } else { 0.0 }
      let lines = @core.split_lines_str(code).length()
      let body : Float =
        if lines == 0 { 22.0 } else { Float::from_int(lines) * line_h(13.5) }
      label + 20.0 + body
    }
    @core.Quote(inner) => {
      let mut h : Float = 12.0
      for ib in inner {
        h = h + estimate_slot_height(ib, avail - 28.0)
      }
      if inner.length() > 1 {
        h = h + 4.0 * Float::from_int(inner.length() - 1)
      }
      h
    }
    @core.ListBlock(_, items) => {
      let mut h : Float = 0.0
      for it in items {
        let mut item_h =
          Float::from_int(text_rows(it.content, 15.0, avail - 30.0)) * line_h(15.0)
        if item_h < line_h(15.0) {
          item_h = line_h(15.0)
        }
        if it.children.length() > 0 {
          item_h = item_h + 4.0
          for ch in it.children {
            item_h = item_h + estimate_slot_height(ch, avail - 22.0)
          }
          if it.children.length() > 1 {
            item_h = item_h + 2.0 * Float::from_int(it.children.length() - 1)
          }
        }
        h = h + item_h
      }
      if items.length() > 1 {
        h = h + 2.0 * Float::from_int(items.length() - 1)
      }
      h
    }
    @core.TableBlock(t) => {
      // 列宽推导与 render_block 的表格分支一致：内容估算宽夹到 [60, 360]。
      let mut ncols = 0
      for row in t.rows {
        if row.length() > ncols {
          ncols = row.length()
        }
      }
      let colw : Array[Float] = []
      for c = 0; c < ncols; c = c + 1 {
        let mut w : Float = 60.0
        for ri = 0; ri < t.rows.length(); ri = ri + 1 {
          let row = t.rows[ri]
          if c < row.length() {
            let cw = cell_px(@core.inlines_plain(row[c]).to_array(), 14.0, t.has_header && ri == 0)
            if cw > w {
              w = cw
            }
          }
        }
        if w > 360.0 {
          w = 360.0
        }
        colw.push(w)
      }
      let mut h : Float = 0.0
      for row in t.rows {
        let mut rh : Float = 0.0
        for ci = 0; ci < row.length(); ci = ci + 1 {
          let cell_h =
            Float::from_int(text_rows(row[ci], 14.0, colw[ci] - 24.0)) * line_h(14.0) + 8.0
          if cell_h > rh {
            rh = cell_h
          }
        }
        h = h + rh
      }
      h
    }
    @core.ImageBlock(_, _) => line_h(16.0)
    @core.Hr => 14.0
    @core.Raw(_) => {
      let cs = @core.block_plain(b).to_array()
      Float::from_int(layout_text(cs, 13.0, avail).rows.length()).max(1.0) * line_h(13.0)
    }
  }
}

// 叶子块：标题/段落走 token 点击区；代码块/HR/图片/Raw 保留整块点击
// （光标落块尾）。容器块（引用/列表/表格）内每个单元自带点击区。
fn render_slot(
  cb : @gpui.CommandBuffer,
  b : @core.Block,
  cur : Int,
  sel_a : @core.Caret,
  sel_b : @core.Caret,
  reg : (Int) -> Int,
  rbox : (Int) -> Int,
  rtok : (Int, Int) -> Int,
  avail : Float,
) -> Unit {
  let container = match b {
    @core.Quote(_) | @core.ListBlock(_, _) | @core.TableBlock(_) => true
    _ => false
  }
  let tok_leaf = match b {
    @core.Heading(_, _) | @core.Paragraph(_) => true
    _ => false
  }
  cb.div()
  if !container {
    cb.set_padding_sides(2, 6, 2, 6)
    if !tok_leaf {
      cb.set_cursor(@gpui.CURSOR_TEXT)
      cb.set_whitespace(@gpui.WHITESPACE_PRE_WRAP)
      cb.set_on_click(reg(cur))
    }
  }
  render_block(cb, b, cur, sel_a, sel_b, reg, rbox, rtok, avail - 12.0)
  cb.add_child()
}

fn render_block(
  cb : @gpui.CommandBuffer,
  b : @core.Block,
  cur : Int,
  sel_a : @core.Caret,
  sel_b : @core.Caret,
  reg : (Int) -> Int,
  rbox : (Int) -> Int,
  rtok : (Int, Int) -> Int,
  avail : Float,
) -> Unit {
  // 叶子块的单元就是 cur；容器块（列表/表格）内每个单元各自重算窗口
  let (caret, lo, hi) = unit_sel_window(sel_a, sel_b, cur)
  match b {
    @core.Heading(l, inls) => push_text(
      cb,
      inls,
      caret,
      lo,
      hi,
      heading_size(l),
      avail,
      cur,
      rtok,
      true,
    )
    @core.Paragraph(inls) => push_text(cb, inls, caret, lo, hi, 15.0, avail, cur, rtok, false)
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
        render_slot(cb, ib, c2, sel_a, sel_b, reg, rbox, rtok, avail - 28.0)
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
        let (ic, ilo, ihi) = unit_sel_window(sel_a, sel_b, c2)
        push_text(cb, it.content, ic, ilo, ihi, 15.0, avail - 30.0, c2, rtok, false)
        cb.add_child()
        cb.add_child() // row
        if it.children.length() > 0 {
          cb.div()
          cb.set_padding_sides(2, 0, 2, 22)
          cb.set_flex_col()
          cb.set_gap(2.0)
          c2 = c2 + 1
          for ch in it.children {
            render_slot(cb, ch, c2, sel_a, sel_b, reg, rbox, rtok, avail - 22.0)
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
      // 全表统一的列宽：max(内容估算宽) 夹到 [60, 360]，min+max size 锁死，
      // 保证跨行列边框严格对齐；超宽内容在格内折行。
      let mut ncols = 0
      for row in t.rows {
        if row.length() > ncols {
          ncols = row.length()
        }
      }
      let colw : Array[Int] = []
      for c = 0; c < ncols; c = c + 1 {
        let mut w : Float = 60.0
        let mut ri = 0
        for row in t.rows {
          if c < row.length() {
            let hb = t.has_header && ri == 0
            let cw = cell_px(@core.inlines_plain(row[c]).to_array(), 14.0, hb)
            if cw > w {
              w = cw
            }
          }
          ri = ri + 1
        }
        let mut wi = w.ceil().to_int()
        if wi > 360 {
          wi = 360
        }
        colw.push(wi)
      }
      let mut c2 = cur
      let mut ri = 0
      for row in t.rows {
        cb.div()
        cb.set_flex_row()
        for ci = 0; ci < row.length(); ci = ci + 1 {
          cb.div()
          cb.set_border_color(1.0, @gpui.Color::rgb(70, 76, 92))
          cb.set_padding_sides(4, 10, 4, 10)
          cb.set_min_size(colw[ci], 0)
          cb.set_max_size(colw[ci], -1)
          let (cc, clo, chi) = unit_sel_window(sel_a, sel_b, c2)
          push_text(
            cb,
            row[ci],
            cc,
            clo,
            chi,
            14.0,
            Float::from_int(colw[ci] - 24),
            c2,
            rtok,
            t.has_header && ri == 0,
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

// --- 顶栏 -------------------------------------------------------------------
// 窗口最上面一排（用户指定的布局）：左侧应用名 + 文件名（未关联为
// Untitled.md），右侧 New / Open / Save 按钮。按钮是带边框的小 div +
// 文本，点击 id 由 app::reg_bar 发放。

///|
/// 顶栏（调用方已 push root div）。`rbar` 为按钮槽位（0=New 1=Open 2=Save）
/// 取点击 handler id。
pub fn render_top_bar(
  cb : @gpui.CommandBuffer,
  name : String,
  rbar : (Int) -> Int,
) -> Unit {
  cb.div()
  cb.set_flex_row()
  cb.set_gap(10.0)
  cb.set_padding_sides(10, 14, 10, 14)
  cb.set_bg_color(@gpui.Color::rgb(24, 26, 33))
  cb.text("md_mbt", col_muted.0, col_muted.1, col_muted.2, 13.0)
  cb.add_child()
  cb.text(name, col_text.0, col_text.1, col_text.2, 13.0)
  cb.add_child()
  cb.div()
  cb.set_flex(1.0, 0.0, 0.0)
  cb.add_child()
  top_button(cb, 0, "New", rbar)
  top_button(cb, 1, "Open", rbar)
  top_button(cb, 2, "Save", rbar)
  cb.add_child() // bar → root
}

fn top_button(
  cb : @gpui.CommandBuffer,
  slot : Int,
  label : String,
  rbar : (Int) -> Int,
) -> Unit {
  cb.div()
  cb.set_cursor(@gpui.CURSOR_POINTER)
  cb.set_padding_sides(3, 12, 3, 12)
  cb.set_border_color(1.0, @gpui.Color::rgb(70, 76, 92))
  cb.set_rounded(6.0)
  cb.set_on_click(rbar(slot))
  cb.text(label, col_text.0, col_text.1, col_text.2, 13.0)
  cb.add_child()
  cb.add_child()
}
