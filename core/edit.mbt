/// 编辑内核：在块树上执行插入/删除/拆分/合并/样式切换/光标移动。
/// 全部为纯函数：输入当前 (blocks, sel)，输出新状态。undo/redo 由
/// history.mbt 在外层用快照包装。

///|
pub fn doc_ensure(blocks : Array[Block]) -> Array[Block] {
  if blocks.length() == 0 {
    [Paragraph([])]
  } else {
    blocks
  }
}

///|
fn char_len(s : String) -> Int {
  s.to_array().length()
}

///|
fn str_replace_range(
  s : String,
  start : Int,
  end : Int,
  ins : String,
) -> String {
  let cs = s.to_array()
  let n = cs.length()
  let a = if start < 0 { 0 } else if start > n { n } else { start }
  let b = if end < a { a } else if end > n { n } else { end }
  String::from_array(cs[0:a]) + ins + String::from_array(cs[b:])
}

///|
/// 把选区替换为纯文本（跨单元时先删范围再插入）。
/// 光标落在普通文本上时继承左邻 run 的样式。
pub fn doc_insert(
  blocks : Array[Block],
  sel : Sel,
  text : String,
) -> (Array[Block], Sel) {
  if text == "" {
    let (bs, c) = doc_delete(blocks, sel)
    return (bs, collapsed_sel(c))
  }
  let a = sel_start(sel)
  let b = sel_end(sel)
  if a.unit != b.unit {
    let (bs2, c2) = doc_delete(blocks, sel)
    return doc_insert(bs2, collapsed_sel(c2), text)
  }
  let us = collect_units(blocks)
  if a.unit < 0 || a.unit >= us.length() {
    return (blocks, sel)
  }
  let u = us[a.unit]
  let bs = if u.kind == CodeU {
    (u.set_plain)(str_replace_range(u.plain, a.offset, b.offset, text))
  } else {
    (u.set_inlines)(
      inlines_insert(
        u.inlines,
        a.offset,
        b.offset,
        text,
        inlines_marks_before(u.inlines, a.offset),
      ),
    )
  }
  (
    doc_ensure(bs),
    collapsed_sel(Caret::{ unit: a.unit, offset: a.offset + char_len(text) }),
  )
}

///|
/// 删除选区（含跨单元）。空选区时删除光标后一个字符。
pub fn doc_delete(blocks : Array[Block], sel : Sel) -> (Array[Block], Caret) {
  let a = sel_start(sel)
  let b = sel_end(sel)
  if a == b {
    let (bs, s) = doc_delete_forward(blocks, a)
    return (bs, sel_start(s))
  }
  let mut bs = blocks
  let mut c = b
  let mut budget = 0
  while c.cmp(a) > 0 && budget < 100_000 {
    let (bs2, c2) = backspace_one(bs, c)
    budget = budget + 1
    if c2.cmp(c) >= 0 {
      break
    }
    bs = bs2
    c = c2
  }
  (doc_ensure(bs), a)
}

///|
/// Backspace：删前一个字符，或在块首合并到上一单元 / 删除原子块。
pub fn doc_backspace(blocks : Array[Block], sel : Sel) -> (Array[Block], Sel) {
  if !sel.collapsed() {
    let (bs, c) = doc_delete(blocks, sel)
    (bs, collapsed_sel(c))
  } else {
    let (bs, c) = backspace_one(blocks, sel.focus)
    (doc_ensure(bs), collapsed_sel(c))
  }
}

///|
/// Delete：删后一个字符，或合并到下一单元 / 删除原子块。
pub fn doc_delete_forward(
  blocks : Array[Block],
  c : Caret,
) -> (Array[Block], Sel) {
  let us = collect_units(blocks)
  if c.unit < 0 || c.unit >= us.length() {
    return (blocks, collapsed_sel(c))
  }
  let u = us[c.unit]
  if u.kind == AtomicU {
    // 原子块整体删除
    let bs = map_top_block(blocks, u.top_index, fn(_) { None })
    let us2 = collect_units(bs)
    let cu = if c.unit >= us2.length() { us2.length() - 1 } else { c.unit }
    let off = if cu >= 0 && cu < us2.length() {
      char_len(us2[cu].plain)
    } else {
      0
    }
    (
      doc_ensure(bs),
      collapsed_sel(Caret::{ unit: if cu < 0 { 0 } else { cu }, offset: off }),
    )
  } else if u.kind == CellU && c.offset >= char_len(u.plain) && c.unit + 1 < us.length() && us[c.unit + 1].kind == CellU {
    // 格尾前向删除：光标移到下一格首，不动内容
    (blocks, collapsed_sel(Caret::{ unit: c.unit + 1, offset: 0 }))
  } else if c.offset < char_len(u.plain) {
    let bs = if u.kind == CodeU {
      (u.set_plain)(str_replace_range(u.plain, c.offset, c.offset + 1, ""))
    } else {
      (u.set_inlines)(
        inlines_insert(u.inlines, c.offset, c.offset + 1, "", Marks::default()),
      )
    }
    (doc_ensure(bs), collapsed_sel(c))
  } else if c.unit + 1 < us.length() {
    // 单元末尾: 等价于把下一单元合并进来（对下一单元起点 backspace）
    let (bs, c2) = backspace_one(blocks, Caret::{ unit: c.unit + 1, offset: 0 })
    (doc_ensure(bs), collapsed_sel(c2))
  } else {
    (blocks, collapsed_sel(c))
  }
}

// 删除 caret 前的一个字符 / 一个原子块 / 执行一次合并。

///|
fn backspace_one(blocks : Array[Block], c : Caret) -> (Array[Block], Caret) {
  let us = collect_units(blocks)
  if c.unit < 0 || c.unit >= us.length() {
    return (blocks, c)
  }
  let u = us[c.unit]
  if c.offset > 0 {
    let bs = if u.kind == CodeU {
      (u.set_plain)(str_replace_range(u.plain, c.offset - 1, c.offset, ""))
    } else {
      (u.set_inlines)(
        inlines_insert(u.inlines, c.offset - 1, c.offset, "", Marks::default()),
      )
    }
    (doc_ensure(bs), Caret::{ unit: c.unit, offset: c.offset - 1 })
  } else if u.kind == AtomicU {
    let bs = map_top_block(blocks, u.top_index, fn(_) { None })
    let us2 = collect_units(bs)
    let target = if c.unit > 0 { (c.unit - 1).min(us2.length() - 1) } else { 0 }
    let off = if us2.length() > 0 {
      char_len(us2[if target >= 0 { target } else { 0 }].plain)
    } else {
      0
    }
    (
      doc_ensure(bs),
      Caret::{ unit: if target >= 0 { target } else { 0 }, offset: off },
    )
  } else if u.kind == CellU && c.unit > 0 && us[c.unit - 1].kind == CellU {
    // 格首退格：只把光标移进上一格尾，不并内容（避免搬空留幽灵格）
    (blocks, Caret::{ unit: c.unit - 1, offset: char_len(us[c.unit - 1].plain) })
  } else if c.unit == 0 {
    (blocks, c)
  } else {
    // 块首合并（同块内与跨块统一算法）:
    //   1) 前单元吸收当前单元文本（单补丁）
    //   2) 在补丁后的文档上重新 collect，用 remove_self 移除当前单元
    //      （列表项连同 children 删除、末项删除时整个列表块消失）
    let prev = us[c.unit - 1]
    let joined = if prev.kind == CodeU || u.kind == CodeU {
      (prev.set_plain)(prev.plain + "\n" + u.plain)
    } else {
      (prev.set_inlines)(inlines_concat(prev.inlines, u.inlines))
    }
    let us2 = collect_units(joined)
    let bs = if c.unit < us2.length() {
      let here = us2[c.unit]
      match here.remove_self {
        Some(f) => f()
        None =>
          if here.kind == CodeU {
            (here.set_plain)("")
          } else {
            (here.set_inlines)([])
          }
      }
    } else {
      joined
    }
    (doc_ensure(bs), Caret::{ unit: c.unit - 1, offset: char_len(prev.plain) })
  }
}

///|
/// Enter: 拆分当前单元。
pub fn doc_enter(blocks : Array[Block], sel : Sel) -> (Array[Block], Sel) {
  let (bs, c) = if sel.collapsed() {
    (blocks, sel.focus)
  } else {
    doc_delete(blocks, sel)
  }
  let us = collect_units(bs)
  if c.unit < 0 || c.unit >= us.length() {
    return (bs, collapsed_sel(c))
  }
  let u = us[c.unit]
  match (u.split)(c.offset) {
    Some((bs2, delta)) => {
      let caret = Caret::{
        unit: c.unit + delta,
        offset: if delta == 0 {
          c.offset + 1
        } else {
          0
        },
      }
      (doc_ensure(bs2), collapsed_sel(caret))
    }
    None => (bs, collapsed_sel(c))
  }
}

///|
/// 方向移动。up/down 简化为跨单元移动（GPUI 无字符级几何信息，见 framework-gaps）。
pub(all) enum Dir {
  Left
  Right
  Up
  Down
  Home
  End
} derive(Eq, Debug)

///|
pub fn doc_move(
  blocks : Array[Block],
  sel : Sel,
  dir : Dir,
  doc_move_extend : Bool,
) -> Sel {
  let us = collect_units(blocks)
  let base = if doc_move_extend { sel.focus } else { sel_start(sel) }
  let n = us.length()
  if n == 0 {
    return sel
  }
  let cu = if base.unit >= n { n - 1 } else { base.unit }
  let len = char_len(us[cu].plain)
  let co = if base.offset > len { len } else { base.offset }
  let np = match dir {
    Left =>
      if co > 0 {
        Caret::{ unit: cu, offset: co - 1 }
      } else if cu > 0 {
        Caret::{ unit: cu - 1, offset: char_len(us[cu - 1].plain) }
      } else {
        base
      }
    Right =>
      if co < len {
        Caret::{ unit: cu, offset: co + 1 }
      } else if cu + 1 < n {
        Caret::{ unit: cu + 1, offset: 0 }
      } else {
        base
      }
    Up =>
      if cu > 0 {
        Caret::{ unit: cu - 1, offset: co.min(char_len(us[cu - 1].plain)) }
      } else {
        base
      }
    Down =>
      if cu + 1 < n {
        Caret::{ unit: cu + 1, offset: co.min(char_len(us[cu + 1].plain)) }
      } else {
        base
      }
    Home => Caret::{ unit: cu, offset: 0 }
    End => Caret::{ unit: cu, offset: len }
  }
  if doc_move_extend {
    { anchor: sel.anchor, focus: np }
  } else {
    collapsed_sel(np)
  }
}

///|
/// 全选。
pub fn doc_select_all(blocks : Array[Block]) -> Sel {
  let us = collect_units(blocks)
  let n = us.length()
  let last = if n > 0 { n - 1 } else { 0 }
  let end_off = if n > 0 { char_len(us[last].plain) } else { 0 }
  {
    anchor: Caret::{ unit: 0, offset: 0 },
    focus: Caret::{ unit: last, offset: end_off },
  }
}

///|
/// 对选区内的 run 应用样式更新；跨单元时逐单元应用（每次重收集，单元不增删）。
pub fn doc_toggle_mark(
  blocks : Array[Block],
  sel : Sel,
  upd : (Marks) -> Marks,
) -> (Array[Block], Sel) {
  let a = sel_start(sel)
  let b = sel_end(sel)
  if a == b {
    return (blocks, sel)
  }
  let mut bs = blocks
  let mut budget = 0
  let mut nu = a.unit
  while nu <= b.unit && budget < 1000 {
    budget = budget + 1
    let us = collect_units(bs)
    if nu >= us.length() {
      break
    }
    let u = us[nu]
    if u.kind != CodeU && u.kind != AtomicU {
      let lo = if nu == a.unit { a.offset } else { 0 }
      let hi = if nu == b.unit { b.offset } else { char_len(u.plain) }
      if hi > lo {
        bs = (u.set_inlines)(inlines_toggle(u.inlines, lo, hi, upd))
      }
    }
    nu = nu + 1
  }
  (doc_ensure(bs), sel)
}

///|
/// 块级类型转换（作用于光标所在单元所属顶层块）。
pub(all) enum BlockOp {
  SetHeading(Int) // 已是同级标题则转回段落
  ToggleBullet
  SetOrdered(Int) // 起始编号；已是有序则转回段落
  SetTask
}

///|
/// 列表整体摊平为段落序列（含每项 children），修复 ToggleBullet 丢项 bug。
pub fn list_to_paragraphs(items : Array[Item]) -> Array[Block] {
  let out : Array[Block] = []
  for it in items {
    out.push(Paragraph(it.content))
    for ch in it.children {
      out.push(ch)
    }
  }
  out
}

///|
pub fn doc_block_op(
  blocks : Array[Block],
  sel : Sel,
  op : BlockOp,
) -> (Array[Block], Sel) {
  let us = collect_units(blocks)
  let c = sel.focus
  if c.unit < 0 || c.unit >= us.length() {
    return (blocks, sel)
  }
  let top = us[c.unit].top_index
  let cur = blocks[top]
  let one_run_list = fn(kind : ListKind, inls : Array[Inline]) -> Array[Block] {
    [
      ListBlock(kind, [
        {
          checked: if kind == Task { Some(false) } else { None },
          content: inls,
          children: [],
        },
      ]),
    ]
  }
  // 段落→列表 / 列表→段落（多块结果一律用 splice，保住全部项）
  let repl : Array[Block] = match op {
    SetHeading(lv) =>
      match cur {
        Heading(l, inls) => if l == lv { [Paragraph(inls)] } else { [Heading(lv, inls)] }
        Paragraph(inls) => [Heading(lv, inls)]
        other => [other]
      }
    ToggleBullet =>
      match cur {
        Paragraph(inls) => one_run_list(Bullet, inls)
        ListBlock(Bullet, items) => list_to_paragraphs(items)
        ListBlock(_, items) => [ListBlock(Bullet, retag(items, Bullet))]
        other => [other]
      }
    SetOrdered(n) =>
      match cur {
        Paragraph(inls) => one_run_list(Ordered(n), inls)
        ListBlock(Ordered(_), items) => list_to_paragraphs(items)
        ListBlock(_, items) => [ListBlock(Ordered(n), retag(items, Ordered(n)))]
        other => [other]
      }
    SetTask =>
      match cur {
        Paragraph(inls) => one_run_list(Task, inls)
        ListBlock(Task, items) => list_to_paragraphs(items)
        ListBlock(_, items) => [ListBlock(Task, retag(items, Task))]
        other => [other]
      }
  }
  let _ = us
  let bs = splice_top(blocks, top, repl)
  let out = doc_ensure(bs)
  let max_u = total_units(out)
  let f = sel.focus
  let a = sel.anchor
  let cl = fn(ct : Caret) -> Caret {
    if ct.unit >= max_u {
      Caret::{ unit: max_u - 1, offset: 0 }
    } else {
      ct
    }
  }
  (out, { anchor: cl(a), focus: cl(f) })
}

///|
pub fn total_units(bs : Array[Block]) -> Int {
  let mut n = 0
  for b in bs {
    n = n + count_units_of(b)
  }
  n
}

fn retag(items : Array[Item], kind : ListKind) -> Array[Item] {
  items.map(it => {
    Item::{
      ..it,
      checked: if kind == Task { Some(false) } else { None },
    }
  })
}

///|
/// 选区覆盖的纯文本；空选区返回 ""。复制/剪切用：跨单元按 collect_units
/// 顺序截取各单元 plain（单元内不含换行，单元间补 '\n'，代码块内部的
/// 换行已在 plain 里），端点偏移越界时钳到单元边界。
pub fn doc_selection_text(blocks : Array[Block], sel : Sel) -> String {
  let a0 = sel_start(sel)
  let b0 = sel_end(sel)
  if a0 == b0 {
    return ""
  }
  let us = collect_units(blocks)
  let n = us.length()
  if n == 0 {
    return ""
  }
  let lens : Array[Int] = []
  for i = 0; i < n; i = i + 1 {
    lens.push(char_len(us[i].plain))
  }
  // 端点越界钳到文档边界（unit 超出时 offset 一并取该单元尾/首）
  let clamp = fn(c : Caret) -> Caret {
    let u = if c.unit < 0 { 0 } else if c.unit >= n { n - 1 } else { c.unit }
    let o = if c.unit < 0 {
      0
    } else if c.unit >= n {
      lens[u]
    } else {
      c.offset
    }
    Caret::{ unit: u, offset: o }
  }
  let a = clamp(a0)
  let b = clamp(b0)
  let out : Array[Char] = []
  for u = a.unit; u <= b.unit; u = u + 1 {
    let len = lens[u]
    let s = if u == a.unit { a.offset } else { 0 }
    let e = if u == b.unit { b.offset } else { len }
    let s2 = if s < 0 { 0 } else if s > len { len } else { s }
    let e2 = if e < s2 { s2 } else if e > len { len } else { e }
    for i = s2; i < e2; i = i + 1 {
      out.push(us[u].plain.to_array()[i])
    }
    if u < b.unit {
      out.push('\n')
    }
  }
  String::from_array(out)
}
