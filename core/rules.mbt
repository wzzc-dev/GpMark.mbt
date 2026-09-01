/// 输入规则引擎（velotype 的「输入即转换」语义）：
/// - 「标记 + 空格」在块首触发 → 结构化块（标题/列表/有序/引用/任务）
/// - Enter 触发 → 代码围栏建块、--- 转分隔线、空列表项退出列表
/// - 词移动 / 多行粘贴拆分 / 代码块出逃 / 任务勾选 / 缩进 / 表格加删行
/// 全部纯函数：输入 (blocks, sel) 输出新状态；由 adapter 包进 Editor::apply。

///|
/// 空格规则解析结果（velotype detect_markdown_shortcut 的等价物）。
pub(all) enum SpaceRule {
  HLevel(Int)
  BulletR
  OrderedR(Int)
  QuoteR
  TaskR(Bool)
} derive(Eq, Debug)

fn is_space_ch(c : Char) -> Bool {
  c == ' '
}

fn is_digit_ch(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
/// 在纯文本 `plain` 上，光标恰好停在 `off` 处（= 刚敲下空格的位置）时，
/// 判定「标记+空格」前缀规则。不满足返回 None。
pub fn rule_at_plain(plain : String, off : Int) -> SpaceRule? {
  let cs = plain.to_array()
  if off < 2 || off > cs.length() {
    return None
  }
  if !is_space_ch(cs[off - 1]) {
    return None
  }
  let m = off - 1 // 不含空格的标记长度
  if m >= 1 && m <= 6 {
    let mut all_hash = true
    for k = 0; k < m; k = k + 1 {
      if cs[k] != '#' {
        all_hash = false
      }
    }
    if all_hash {
      return Some(HLevel(m))
    }
  }
  if m == 1 {
    let c = cs[0]
    if c == '-' || c == '*' || c == '+' {
      return Some(BulletR)
    }
    if c == '>' {
      return Some(QuoteR)
    }
  }
  if m == 3 && cs[0] == '[' && cs[2] == ']' {
    if cs[1] == ' ' {
      return Some(TaskR(false))
    }
    if cs[1] == 'x' || cs[1] == 'X' {
      return Some(TaskR(true))
    }
  }
  if m >= 2 && cs[m - 1] == '.' {
    let mut all_digit = true
    for k = 0; k < m - 1; k = k + 1 {
      if !is_digit_ch(cs[k]) {
        all_digit = false
      }
    }
    if all_digit {
      let mut num = 0
      for k = 0; k < m - 1; k = k + 1 {
        num = num * 10 + (cs[k].to_int() - '0'.to_int())
      }
      return Some(OrderedR(num))
    }
  }
  None
}

fn prefix_is_plain(inls : Array[Inline], n : Int) -> Bool {
  let (left, _) = inlines_split_at(inls, n)
  let mut ok = true
  for x in left {
    match x {
      Run(_, m) =>
        if !m.is_plain() {
          ok = false
        }
      _ => ok = false
    }
  }
  ok
}

///|
/// 空格触发的结构转换。守卫：折叠光标；顶层块必须是 Paragraph（标题内
/// 仅允许改级别）；前缀必须是无样式纯文本；光标恰好停在标记 + 空格之后。
pub fn doc_apply_space_rule(
  blocks : Array[Block],
  sel : Sel,
) -> (Array[Block], Sel, Bool) {
  let noop = (blocks, sel, false)
  if !sel.collapsed() {
    return noop
  }
  let us = collect_units(blocks)
  let c = sel.focus
  if c.unit < 0 || c.unit >= us.length() {
    return noop
  }
  let u = us[c.unit]
  let top = u.top_index
  if top < 0 || top >= blocks.length() {
    return noop
  }
  // 触发时机 = 刚敲下标记后的空格（光标紧贴空格右侧）；
  // 不要求行尾，粘贴/程序化置入的整行也能命中。
  match rule_at_plain(u.plain, c.offset) {
    None => noop
    Some(rule) =>
      if !prefix_is_plain(u.inlines, c.offset) {
        return noop
      } else {
        let rest = normalize_inlines(inlines_split_at(u.inlines, c.offset).1)
        let plain_len = char_len(inlines_plain(rest))
        match blocks[top] {
          Paragraph(_) => {
            let nb : Block = match rule {
              HLevel(l) => Heading(l, rest)
              BulletR =>
                ListBlock(Bullet, [{ checked: None, content: rest, children: [] }])
              OrderedR(n) =>
                ListBlock(Ordered(n), [
                  { checked: None, content: rest, children: [] },
                ])
              QuoteR => Quote([Paragraph(rest)])
              TaskR(b) =>
                ListBlock(Task, [{ checked: Some(b), content: rest, children: [] }])
            }
            let _ = plain_len
            let bs = map_top_block(blocks, top, fn(_) { Some(nb) })
            (bs, collapsed_sel(Caret::{ unit: c.unit, offset: 0 }), true)
          }
          Heading(l, _) =>
            match rule {
              HLevel(l2) =>
                if l == l2 {
                  noop
                } else {
                  let bs = map_top_block(
                    blocks,
                    top,
                    fn(_) { Some(Heading(l2, rest)) },
                  )
                  (bs, collapsed_sel(Caret::{ unit: c.unit, offset: 0 }), true)
                }
              _ => noop
            }
          _ => noop
        }
      }
  }
}

// --- Enter 规则 -------------------------------------------------------------

fn is_lang_ch(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || is_digit_ch(c) || c == '-'
}

fn fence_lang_at(plain : String, off : Int) -> String? {
  let cs = plain.to_array()
  if off != cs.length() || cs.length() < 3 {
    return None
  }
  let fence = cs[0]
  if fence != '`' && fence != '~' {
    return None
  }
  if cs[1] != fence || cs[2] != fence {
    return None
  }
  let mut lang_ok = true
  for k = 3; k < cs.length(); k = k + 1 {
    if !is_lang_ch(cs[k]) {
      lang_ok = false
    }
  }
  if lang_ok {
    Some(String::from_array(cs[3:]))
  } else {
    None
  }
}

fn is_hr_text(plain : String) -> Bool {
  let cs = plain.to_array()
  if cs.length() < 3 {
    return false
  }
  let c0 = cs[0]
  if c0 != '-' && c0 != '*' && c0 != '_' {
    return false
  }
  let mut ok = true
  for c in cs {
    if c != c0 {
      ok = false
    }
  }
  ok
}

///|
/// 单元计数（与 collect_units 的产出顺序/数量严格一致）。
pub fn count_units_of(b : Block) -> Int {
  match b {
    Heading(_, _) | Paragraph(_) | CodeBlock(_, _) | Hr | ImageBlock(_, _) | Raw(_) => 1
    Quote(inner) => {
      let mut s = 0
      for x in inner {
        s = s + count_units_of(x)
      }
      if s == 0 { 1 } else { s }
    }
    ListBlock(_, items) => {
      let mut s = 0
      for it in items {
        s = s + 1
        for ch in it.children {
          s = s + count_units_of(ch)
        }
      }
      s
    }
    TableBlock(t) => {
      let mut s = 0
      for row in t.rows {
        s = s + row.length()
      }
      s
    }
  }
}

///|
/// 定位折叠光标所在单元是否是「顶层列表项的内容单元」。
/// 返回 (顶层块下标, 项下标, 项总数)；嵌套列表项返回 None（v1 从简）。
pub fn locate_top_item(
  blocks : Array[Block],
  unit : Int,
) -> (Int, Int, Int)? {
  let us = collect_units(blocks)
  if unit < 0 || unit >= us.length() {
    return None
  }
  let u = us[unit]
  if u.kind != ListItemU {
    return None
  }
  let top = u.top_index
  if top < 0 || top >= blocks.length() {
    return None
  }
  match blocks[top] {
    ListBlock(_, items) => {
      let mut first = -1
      for k = 0; k < us.length(); k = k + 1 {
        if us[k].top_index == top {
          first = k
          break
        }
      }
      if first < 0 {
        return None
      }
      let mut rel = unit - first
      for j = 0; j < items.length(); j = j + 1 {
        if rel == 0 {
          return Some((top, j, items.length()))
        }
        let mut kids = 0
        for ch in items[j].children {
          kids = kids + count_units_of(ch)
        }
        rel = rel - 1 - kids
        if rel < 0 {
          return None
        }
      }
      None
    }
    _ => None
  }
}

///|
/// 把顶层块 `i` 替换为多块。
pub fn splice_top(bs : Array[Block], i : Int, repl : Array[Block]) -> Array[Block] {
  let out : Array[Block] = []
  for k = 0; k < bs.length(); k = k + 1 {
    if k == i {
      for r in repl {
        out.push(r)
      }
    } else {
      out.push(bs[k])
    }
  }
  out
}

///|
/// 顶层块 `i` 的首个编辑单元全局下标（无单元返回 -1）。
fn first_top_unit(bs : Array[Block], i : Int) -> Int {
  let us = collect_units(bs)
  for k = 0; k < us.length(); k = k + 1 {
    if us[k].top_index == i {
      return k
    }
  }
  -1
}

///|
/// 结构性块之后补一个空段落（velotype ensure_trailing_paragraph 语义），
/// 保证代码块/表格/分隔线位于文档末尾时仍可继续键入。
pub fn doc_ensure_trailing(bs : Array[Block]) -> Array[Block] {
  let n = bs.length()
  if n == 0 {
    return [Paragraph([])]
  }
  // 只有代码块（Enter 留在块内）与表格（格内 Enter 无效）会困住光标；
  // Hr/图片/Raw 的单元 Enter 自带「块后插段」拆分，无需补。
  let structural = match bs[n - 1] {
    CodeBlock(_, _) | TableBlock(_) => true
    _ => false
  }
  if structural {
    let out = bs.copy()
    out.push(Paragraph([]))
    out
  } else {
    bs
  }
}

///|
/// Enter 前置规则：命中返回新状态；None = 走普通拆分（doc_enter）。
pub fn doc_apply_enter_rules(
  blocks : Array[Block],
  sel : Sel,
) -> (Array[Block], Sel)? {
  if !sel.collapsed() {
    return None
  }
  let us = collect_units(blocks)
  let c = sel.focus
  if c.unit < 0 || c.unit >= us.length() {
    return None
  }
  let u = us[c.unit]
  let top = u.top_index
  // 1) 空列表项 Enter → 退出列表
  if u.kind == ListItemU && u.plain == "" && c.offset == 0 {
    match locate_top_item(blocks, c.unit) {
      Some((t, j, n)) => {
        let kind = match blocks[t] {
          ListBlock(kd, _) => kd
          _ => return None
        }
        let (before, after, children) : (Array[Item], Array[Item], Array[Block]) =
          match blocks[t] {
            ListBlock(_, items) => {
              if j >= items.length() {
                return None
              }
              let b0 : Array[Item] = []
              for k = 0; k < j; k = k + 1 {
                b0.push(items[k])
              }
              let a0 : Array[Item] = []
              for k = j + 1; k < items.length(); k = k + 1 {
                a0.push(items[k])
              }
              (b0, a0, items[j].children)
            }
            _ => return None
          }
        let nb : Array[Block] = []
        if n == 1 {
          for ch in children {
            nb.push(ch)
          }
          if nb.length() == 0 {
            nb.push(Paragraph([]))
          }
        } else {
          if before.length() > 0 {
            nb.push(ListBlock(kind, before))
          }
          nb.push(Paragraph([]))
          for ch in children {
            nb.push(ch)
          }
          if after.length() > 0 {
            nb.push(ListBlock(kind, after))
          }
        }
        let bs = doc_ensure_trailing(splice_top(blocks, t, nb))
        let extra = if n == 1 { 0 } else { before.length() }
        let careto = first_top_unit(bs, t) + extra
        Some((bs, collapsed_sel(Caret::{ unit: careto.max(0), offset: 0 })))
      }
      None => None
    }
  } else if u.kind != ParagraphU || char_len(u.plain) != c.offset {
    None
  } else {
    match blocks[top] {
      Paragraph(_) => ()
      _ => return None
    }
    // 2) ```lang + Enter → 代码块
    match fence_lang_at(u.plain, c.offset) {
      Some(lang) => {
        let bs = doc_ensure_trailing(
          map_top_block(blocks, top, fn(_) { Some(CodeBlock(lang, "")) }),
        )
        Some((bs, collapsed_sel(Caret::{ unit: c.unit, offset: 0 })))
      }
      None =>
        // 3) --- + Enter → 分隔线；光标落在其后补出的段落单元上
        if is_hr_text(u.plain) {
          let bs = splice_top(blocks, top, [Hr, Paragraph([])])
          let careto = first_top_unit(bs, top) + 1
          Some((bs, collapsed_sel(Caret::{ unit: careto.max(0), offset: 0 })))
        } else {
          None
        }
    }
  }
}

///|
/// Cmd+Enter：从代码块出逃——在代码块后插段落并聚焦。
pub fn doc_code_escape(
  blocks : Array[Block],
  sel : Sel,
) -> (Array[Block], Sel) {
  let us = collect_units(blocks)
  let c = sel.focus
  if c.unit < 0 || c.unit >= us.length() || us[c.unit].kind != CodeU {
    return (blocks, sel)
  }
  let top = us[c.unit].top_index
  let nb : Array[Block] = [blocks[top], Paragraph([])]
  let bs = doc_ensure_trailing(splice_top(blocks, top, nb))
  (bs, collapsed_sel(Caret::{ unit: c.unit + 1, offset: 0 }))
}

///|
/// 粘贴：多行文本按物理行拆段（velotype 纯文本粘贴拆分的简化版）。
pub fn doc_paste(
  blocks : Array[Block],
  sel : Sel,
  text : String,
) -> (Array[Block], Sel) {
  if !text.contains("\n") {
    let (b, s) = doc_insert(blocks, sel, text)
    let (b2, s2, _) = doc_apply_space_rule(b, s)
    return (b2, s2)
  }
  let mut bs = blocks
  let mut s = sel
  let mut first = true
  for line in split_lines_str(text) {
    if !first {
      let (b2, s2) = doc_enter(bs, s)
      bs = b2
      s = s2
    }
    first = false
    if line != "" {
      let (b3, s3) = doc_insert(bs, s, line)
      let (b4, s4, _) = doc_apply_space_rule(b3, s3)
      bs = b4
      s = s4
    }
  }
  (doc_ensure_trailing(bs), s)
}

// --- 词移动 -----------------------------------------------------------------

fn is_word_ch(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || is_digit_ch(c) || c == '_'
}

fn is_cjk_ch(c : Char) -> Bool {
  (c >= '\u{4e00}' && c <= '\u{9fff}') || (c >= '\u{3400}' && c <= '\u{4dbf}')
}

fn word_left(cs : Array[Char], o : Int) -> Int {
  let mut i = o
  while i > 0 && is_space_ch(cs[i - 1]) {
    i = i - 1
  }
  if i > 0 {
    if is_cjk_ch(cs[i - 1]) || !is_word_ch(cs[i - 1]) {
      i = i - 1
    } else {
      while i > 0 && is_word_ch(cs[i - 1]) {
        i = i - 1
      }
    }
  }
  i
}

fn word_right(cs : Array[Char], o : Int) -> Int {
  let n = cs.length()
  let mut i = o
  while i < n && is_space_ch(cs[i]) {
    i = i + 1
  }
  if i < n {
    if is_cjk_ch(cs[i]) || !is_word_ch(cs[i]) {
      i = i + 1
    } else {
      while i < n && is_word_ch(cs[i]) {
        i = i + 1
      }
    }
  }
  i
}

///|
/// 词级移动（Alt+←/→）。上下/Home/End 退化为 doc_move。
pub fn doc_move_word(
  blocks : Array[Block],
  sel : Sel,
  dir : Dir,
  extend : Bool,
) -> Sel {
  match dir {
    Left | Right => {
      let us = collect_units(blocks)
      let n = us.length()
      if n == 0 {
        return sel
      }
      let base = if extend { sel.focus } else { sel_start(sel) }
      let cu = if base.unit >= n { n - 1 } else { base.unit }
      let cs = us[cu].plain.to_array()
      let len = cs.length()
      let co = if base.offset > len { len } else { base.offset }
      let np =
        if dir == Left {
          let o = word_left(cs, co)
          if o < co {
            Caret::{ unit: cu, offset: o }
          } else if cu > 0 {
            Caret::{ unit: cu - 1, offset: char_len(us[cu - 1].plain) }
          } else {
            base
          }
        } else {
          let o = word_right(cs, co)
          if o > co {
            Caret::{ unit: cu, offset: o }
          } else if cu + 1 < n {
            Caret::{ unit: cu + 1, offset: 0 }
          } else {
            base
          }
        }
      if extend {
        { anchor: sel.anchor, focus: np }
      } else {
        collapsed_sel(np)
      }
    }
    _ => doc_move(blocks, sel, dir, extend)
  }
}

// --- 任务勾选 / 缩进 / 表格行 -----------------------------------------------

///|
/// 切换光标所在顶层任务项的勾选态。
pub fn doc_toggle_task(
  blocks : Array[Block],
  sel : Sel,
) -> (Array[Block], Sel) {
  match locate_top_item(blocks, sel.focus.unit) {
    None => (blocks, sel)
    Some((t, j, _)) =>
      match blocks[t] {
        ListBlock(Task, items) =>
          if j < items.length() {
            let nc = match items[j].checked {
              Some(true) => Some(false)
              _ => Some(true)
            }
            let bs = map_top_block(blocks, t, fn(b) {
              match b {
                ListBlock(k, its) => {
                  let a2 = its.copy()
                  a2[j] = Item::{ ..its[j], checked: nc }
                  Some(ListBlock(k, a2))
                }
                other => Some(other)
              }
            })
            (bs, sel)
          } else {
            (blocks, sel)
          }
        _ => (blocks, sel)
      }
  }
}

///|
/// 缩进：顶层列表项移入前一同级项的 children（并入同类型尾列表）。
/// collect 顺序保证单元全局下标不变（children 恰好排在本项之前）。
pub fn doc_indent(blocks : Array[Block], sel : Sel) -> (Array[Block], Sel) {
  match locate_top_item(blocks, sel.focus.unit) {
    None => (blocks, sel)
    Some((t, j, _)) =>
      if j == 0 {
        (blocks, sel)
      } else {
        let bs = map_top_block(
          blocks,
          t,
          fn(b) {
            match b {
              ListBlock(kind, items) =>
                if j < items.length() {
                  let it = items[j]
                  let prev = items[j - 1]
                  let kids = prev.children.copy()
                  let last_same =
                    if kids.length() == 0 {
                      false
                    } else {
                      match kids[kids.length() - 1] {
                        ListBlock(k, _) => k == kind
                        _ => false
                      }
                    }
                  if last_same {
                    let lk = kids.length() - 1
                    match kids[lk] {
                      ListBlock(k, its) => {
                        let a2 = its.copy()
                        a2.push(it)
                        kids[lk] = ListBlock(k, a2)
                      }
                      _ => ()
                    }
                  } else {
                    kids.push(ListBlock(kind, [it]))
                  }
                  let out : Array[Item] = []
                  for k = 0; k < items.length(); k = k + 1 {
                    if k == j - 1 {
                      out.push(Item::{ ..prev, children: kids })
                    } else if k != j {
                      out.push(items[k])
                    }
                  }
                  Some(ListBlock(kind, out))
                } else {
                  Some(b)
                }
              other => Some(other)
            }
          },
        )
        (bs, sel)
      }
  }
}

///|
/// 反缩进：顶层列表项脱离列表变为同位置段落（children 随之成为后续块）。
pub fn doc_outdent(
  blocks : Array[Block],
  sel : Sel,
) -> (Array[Block], Sel) {
  match locate_top_item(blocks, sel.focus.unit) {
    None => (blocks, sel)
    Some((t, j, _)) =>
      match blocks[t] {
        ListBlock(kind, items) => {
          if j >= items.length() {
            return (blocks, sel)
          }
          let it = items[j]
          let before : Array[Item] = []
          for k = 0; k < j; k = k + 1 {
            before.push(items[k])
          }
          let after : Array[Item] = []
          for k = j + 1; k < items.length(); k = k + 1 {
            after.push(items[k])
          }
          let nb : Array[Block] = []
          if before.length() > 0 {
            nb.push(ListBlock(kind, before))
          }
          nb.push(Paragraph(it.content))
          for ch in it.children {
            nb.push(ch)
          }
          if after.length() > 0 {
            nb.push(ListBlock(kind, after))
          }
          let bs = doc_ensure_trailing(splice_top(blocks, t, nb))
          let careto = first_top_unit(bs, t) + before.length()
          let clen = char_len(inlines_plain(it.content))
          let off = if sel.focus.offset > clen { clen } else { sel.focus.offset }
          (bs, collapsed_sel(Caret::{ unit: careto.max(0), offset: off }))
        }
        _ => (blocks, sel)
      }
  }
}

// (该顶层块的首单元, 行, 列)
fn locate_cell(
  blocks : Array[Block],
  us : Array[UnitRef],
  unit : Int,
  top : Int,
) -> (Int, Int, Int) {
  let mut first = 0
  for k = 0; k < us.length(); k = k + 1 {
    if us[k].top_index == top {
      first = k
      break
    }
  }
  let mut rel = unit - first
  let mut r = 0
  let mut col = rel
  match blocks[top] {
    TableBlock(t) => {
      for k = 0; k < t.rows.length(); k = k + 1 {
        let w = t.rows[k].length()
        if rel < w {
          r = k
          col = rel
          break
        }
        rel = rel - w
      }
    }
    _ => ()
  }
  (first, r, col)
}

///|
/// 在光标所在表格行之后插入一空行（宽度取首行）；光标落新行同列格。
pub fn doc_table_add_row(
  blocks : Array[Block],
  sel : Sel,
) -> (Array[Block], Sel) {
  let us = collect_units(blocks)
  let c = sel.focus
  if c.unit < 0 || c.unit >= us.length() || us[c.unit].kind != CellU {
    return (blocks, sel)
  }
  let top = us[c.unit].top_index
  match blocks[top] {
    TableBlock(t) => {
      let (first, r, col) = locate_cell(blocks, us, c.unit, top)
      let width = if t.rows.length() > 0 { t.rows[0].length() } else { 1 }
      let new_row : Array[Array[Inline]] = []
      for _ in 0..<width {
        new_row.push([])
      }
      let rows = t.rows.copy()
      let out : Array[Array[Array[Inline]]] = []
      for k = 0; k < rows.length(); k = k + 1 {
        out.push(rows[k])
        if k == r {
          out.push(new_row)
        }
      }
      if out.length() < rows.length() + 1 {
        out.push(new_row)
      }
      let bs = map_top_block(
        blocks,
        top,
        fn(_) { Some(TableBlock(Table::{ ..t, rows: out })) },
      )
      let mut units = 0
      for k = 0; k <= r && k < t.rows.length(); k = k + 1 {
        units = units + t.rows[k].length()
      }
      let w = width
      let oc = if col < w { col } else { w - 1 }
      (bs, collapsed_sel(Caret::{ unit: first + units + oc, offset: 0 }))
    }
    _ => (blocks, sel)
  }
}

///|
/// 删除光标所在表格行；删空整表则退化为空段落。
pub fn doc_table_delete_row(
  blocks : Array[Block],
  sel : Sel,
) -> (Array[Block], Sel) {
  let us = collect_units(blocks)
  let c = sel.focus
  if c.unit < 0 || c.unit >= us.length() || us[c.unit].kind != CellU {
    return (blocks, sel)
  }
  let top = us[c.unit].top_index
  match blocks[top] {
    TableBlock(t) => {
      let (first, r, col) = locate_cell(blocks, us, c.unit, top)
      if t.rows.length() <= 1 {
        let bs = map_top_block(blocks, top, fn(_) { Some(Paragraph([])) })
        return (bs, collapsed_sel(Caret::{ unit: first, offset: 0 }))
      }
      let out : Array[Array[Array[Inline]]] = []
      for k = 0; k < t.rows.length(); k = k + 1 {
        if k != r {
          out.push(t.rows[k])
        }
      }
      let bs = map_top_block(
        blocks,
        top,
        fn(_) { Some(TableBlock(Table::{ ..t, rows: out })) },
      )
      let target_r = if r > 0 { r - 1 } else { 0 }
      let mut units = 0
      for k = 0; k < target_r; k = k + 1 {
        units = units + out[k].length()
      }
      let w = if target_r < out.length() { out[target_r].length() } else { 1 }
      let oc = if col < w { col } else { w - 1 }
      (bs, collapsed_sel(Caret::{ unit: first + units + oc, offset: 0 }))
    }
    _ => (blocks, sel)
  }
}

///|
/// 循环光标所在代码块的语言标签（空 → 各语言 → 空）。非代码块无操作。
pub fn doc_cycle_code_lang(
  blocks : Array[Block],
  sel : Sel,
  langs : Array[String],
) -> (Array[Block], Sel) {
  let us = collect_units(blocks)
  let c = sel.focus
  if c.unit < 0 || c.unit >= us.length() || us[c.unit].kind != CodeU {
    return (blocks, sel)
  }
  let top = us[c.unit].top_index
  if langs.length() == 0 {
    return (blocks, sel)
  }
  let cur = match blocks[top] {
    CodeBlock(lang, _) => lang
    _ => return (blocks, sel)
  }
  let mut pos = 0
  for k = 0; k < langs.length(); k = k + 1 {
    if langs[k] == cur {
      pos = k
    }
  }
  let next = langs[(pos + 1) % langs.length()]
  let bs = map_top_block(blocks, top, fn(b) {
    match b {
      CodeBlock(_, code) => Some(CodeBlock(next, code))
      other => Some(other)
    }
  })
  (bs, sel)
}
