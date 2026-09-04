/// 编辑单元（unit）抽象：把块树摊平成线性的可编辑文本单元序列，
/// 每个单元携带「改写自己并重建整个文档」的补丁闭包。
/// 数据全部不可变（写时复制）、补丁基于收集时的当前快照构造，编辑操作
/// 因此可以统一写成 collect → patch，不需要维护路径。

///|
pub(all) struct Caret {
  unit : Int
  offset : Int
} derive(Eq, Debug)

///|
pub fn Caret::cmp(self : Caret, other : Caret) -> Int {
  if self.unit < other.unit {
    -1
  } else if self.unit > other.unit {
    1
  } else {
    self.offset - other.offset
  }
}

///|
pub(all) struct Sel {
  anchor : Caret
  focus : Caret
} derive(Eq, Debug)

///|
pub fn Sel::collapsed(self : Sel) -> Bool {
  self.anchor == self.focus
}

///|
/// 规范化范围的起点（字典序较小者）。
pub fn sel_start(s : Sel) -> Caret {
  if s.anchor.cmp(s.focus) <= 0 {
    s.anchor
  } else {
    s.focus
  }
}

///|
/// 规范化范围的终点。
pub fn sel_end(s : Sel) -> Caret {
  if s.anchor.cmp(s.focus) <= 0 {
    s.focus
  } else {
    s.anchor
  }
}

///|
pub fn collapsed_sel(c : Caret) -> Sel {
  { anchor: c, focus: c }
}

///|
pub(all) enum UnitKind {
  ParagraphU
  HeadingU(Int)
  CodeU
  ListItemU
  CellU
  QuoteU // 空 quote 的占位编辑落点
  AtomicU // Hr / ImageBlock / Raw
} derive(Eq, Debug)

///|
/// 一个可编辑单元 + 它的就地补丁能力。所有闭包返回「新的整文档块数组」。
pub(all) struct UnitRef {
  kind : UnitKind
  plain : String // 渲染态纯文本（光标偏移以字符计）
  inlines : Array[Inline] // 非 code 单元的结构化内容
  top_index : Int // 所属顶层块下标（用于块级类型转换）
  is_block_start : Bool // 是否是所属顶层块产出的首个单元
  set_inlines : (Array[Inline]) -> Array[Block]
  set_plain : (String) -> Array[Block] // code 单元的整段替换
  // 移除本单元（列表项→连同 children 删项，末项则删整个列表块；普通块→
  // 删块；单元格→None，只能清空）。基于本快照构造，可在上一步补丁结果上
  // 重新 collect 后安全使用。
  remove_self : (() -> Array[Block])?
  // Enter 在偏移处拆分该单元所属块；返回 (新块数组, 光标单元位移)
  split : (Int) -> (Array[Block], Int)?
}

///|
type Rebuild = (Array[Block]) -> Array[Block]

///|
pub fn collect_units(bs : Array[Block]) -> Array[UnitRef] {
  let acc : Array[UnitRef] = []
  collect_list(bs, fn(x) { x }, -1, acc)
  acc
}

///|
pub fn unit_at(bs : Array[Block], u : Int) -> UnitRef? {
  let us = collect_units(bs)
  if u >= 0 && u < us.length() {
    Some(us[u])
  } else {
    None
  }
}

///|
/// 轻量单元定位：不摊平全文。先按 count_units_of 前缀累计找到包含单元 u
/// 的顶层块，再只展开该块，返回 (顶层下标, 块内单元序号, 单元)。补丁闭包
/// 以「把该块的新块序列拼回原数组」为重建上下文，与 collect_units 全量
/// 结果里同一单元的闭包产出完全一致的新文档。越界返回 None。
pub fn unit_ref_at(bs : Array[Block], u : Int) -> (Int, Int, UnitRef)? {
  if u < 0 {
    return None
  }
  let n = bs.length()
  let mut top = 0
  let mut prefix = 0
  while top < n {
    let c = count_units_of(bs[top])
    if u < prefix + c {
      break
    }
    prefix = prefix + c
    top = top + 1
  }
  if top >= n {
    return None
  }
  let t = top
  let splice : Rebuild = fn(inner) {
    let out : Array[Block] = []
    for k = 0; k < n; k = k + 1 {
      if k == t {
        for x in inner {
          out.push(x)
        }
      } else {
        out.push(bs[k])
      }
    }
    out
  }
  let acc : Array[UnitRef] = []
  collect_list([bs[t]], splice, t, acc)
  let idx = u - prefix
  if idx < 0 || idx >= acc.length() {
    None
  } else {
    Some((t, idx, acc[idx]))
  }
}

///|
/// 单元纯文本的字符数（越界 0）；只展开目标单元所在顶层块。
pub fn unit_plain_len(bs : Array[Block], u : Int) -> Int {
  match unit_ref_at(bs, u) {
    Some((_, _, r)) => r.plain.to_array().length()
    None => 0
  }
}

///|
fn push_unit(
  acc : Array[UnitRef],
  kind : UnitKind,
  inls : Array[Inline],
  plain : String,
  top : Int,
  is_start : Bool,
  set_inls : (Array[Inline]) -> Array[Block],
  set_pl : (String) -> Array[Block],
  remove_fn : (() -> Array[Block])?,
  split_fn : (Int) -> (Array[Block], Int)?,
) -> Unit {
  acc.push({
    kind,
    plain,
    inlines: inls,
    top_index: top,
    is_block_start: is_start,
    set_inlines: set_inls,
    set_plain: set_pl,
    remove_self: remove_fn,
    split: split_fn,
  })
}

///|
fn drop_at(
  arr : Array[Block],
  total : Int,
  ii : Int,
  ctx : Rebuild,
) -> Array[Block] {
  let out : Array[Block] = []
  for k = 0; k < total; k = k + 1 {
    if k != ii {
      out.push(arr[k])
    }
  }
  ctx(out)
}

///|
fn noop_split(_off : Int) -> (Array[Block], Int)? {
  None
}

///|
fn one_run(t : String) -> Array[Inline] {
  [Run(t, Marks::default())]
}

///|
fn collect_list(
  bs : Array[Block],
  ctx : Rebuild,
  top : Int,
  acc : Array[UnitRef],
) -> Unit {
  let arr = bs // 已是数组，快照即可（调用方保证不原地改）
  let total = arr.length()
  for i = 0; i < total; i = i + 1 {
    // 循环可变变量的值必须快照成 let 才能安全地被闭包捕获
    let ii = i
    let b = arr[ii]
    let before = acc.length() // 本块产出单元前的位置
    let top_i = if top >= 0 { top } else { ii }
    let patch : (Block) -> Array[Block] = fn(nb) {
      let a2 = arr.copy()
      a2[ii] = nb
      ctx(a2)
    }
    let patch_list : (Array[Block]) -> Array[Block] = fn(nbs) {
      let out : Array[Block] = []
      for k = 0; k < total; k = k + 1 {
        if k == ii {
          for x in nbs {
            out.push(x)
          }
        } else {
          out.push(arr[k])
        }
      }
      ctx(out)
    }
    let is_start = acc.length() == before
    match b {
      Heading(l, inls) =>
        push_unit(
          acc,
          HeadingU(l),
          inls,
          inlines_plain(inls),
          top_i,
          is_start,
          fn(ni) { patch(Heading(l, ni)) },
          fn(t) { patch(Heading(l, one_run(t))) },
          Some(fn() { drop_at(arr, total, ii, ctx) }),
          fn(off) {
            let (lft, rgt) = inlines_split_at(inls, off)
            Some(
              (
                patch_list([
                  Heading(l, normalize_inlines(lft)),
                  Paragraph(normalize_inlines(rgt)),
                ]),
                1,
              ),
            )
          },
        )
      Paragraph(inls) =>
        push_unit(
          acc,
          ParagraphU,
          inls,
          inlines_plain(inls),
          top_i,
          is_start,
          fn(ni) { patch(Paragraph(ni)) },
          fn(t) { patch(Paragraph(one_run(t))) },
          Some(fn() { drop_at(arr, total, ii, ctx) }),
          fn(off) {
            let (lft, rgt) = inlines_split_at(inls, off)
            Some(
              (
                patch_list([
                  Paragraph(normalize_inlines(lft)),
                  Paragraph(normalize_inlines(rgt)),
                ]),
                1,
              ),
            )
          },
        )
      CodeBlock(lang, code) =>
        push_unit(
          acc,
          CodeU,
          [],
          code,
          top_i,
          is_start,
          fn(ni) { patch(CodeBlock(lang, inlines_plain(ni))) },
          fn(t) { patch(CodeBlock(lang, t)) },
          Some(fn() { drop_at(arr, total, ii, ctx) }),
          fn(off) {
            let cs = code.to_array()
            let joined = String::from_array(cs[0:off]) +
              "\n" +
              String::from_array(cs[off:])
            Some((patch_list([CodeBlock(lang, joined)]), 0))
          },
        )
      Quote(inner) => {
        // quote 本身不是单元，摊平其内部块
        collect_list(inner, fn(il) { patch(Quote(il)) }, top_i, acc)
        // 内部没有产出任何单元（空 quote）时保留一个可编辑落点
        if acc.length() == before {
          push_unit(
            acc,
            QuoteU,
            [],
            "",
            top_i,
            is_start,
            fn(ni) { patch(Quote([Paragraph(ni)])) },
            fn(t) { patch(Quote([Paragraph(one_run(t))])) },
            Some(fn() { patch_list([]) }),
            noop_split,
          )
        }
      }
      ListBlock(kind, items) => {
        let iarr = items
        let n = iarr.length()
        for j = 0; j < n; j = j + 1 {
          let jj = j
          let it = iarr[jj]
          let replace_item : (Item) -> Array[Block] = fn(nit) {
            let a2 = iarr.copy()
            a2[jj] = nit
            patch(ListBlock(kind, a2))
          }
          push_unit(
            acc,
            ListItemU,
            it.content,
            inlines_plain(it.content),
            top_i,
            is_start && jj == 0,
            fn(ni) { replace_item(Item::{ ..it, content: ni }) },
            fn(t) { replace_item(Item::{ ..it, content: one_run(t) }) },
            Some(fn() {
              let out : Array[Item] = []
              for k = 0; k < n; k = k + 1 {
                if k != jj {
                  out.push(iarr[k])
                }
              }
              if out.length() == 0 {
                patch_list([])
              } else {
                patch(ListBlock(kind, out))
              }
            }),
            fn(off) {
              let (lft, rgt) = inlines_split_at(it.content, off)
              let out : Array[Item] = []
              for k = 0; k < n; k = k + 1 {
                if k == jj {
                  out.push(Item::{ ..it, content: normalize_inlines(lft) })
                  out.push({
                    checked: if kind == Task {
                      Some(false)
                    } else {
                      None
                    },
                    content: normalize_inlines(rgt),
                    children: [],
                  })
                } else {
                  out.push(iarr[k])
                }
              }
              Some((patch_list([ListBlock(kind, out)]), 1))
            },
          )
          if it.children.length() > 0 {
            collect_list(
              it.children,
              fn(cl) {
                let a2 = iarr.copy()
                a2[jj] = Item::{ ..it, children: cl }
                patch(ListBlock(kind, a2))
              },
              top_i,
              acc,
            )
          }
        }
      }
      TableBlock(t) => {
        let rarr = t.rows
        let nr = rarr.length()
        for r = 0; r < nr; r = r + 1 {
          let rr = r
          let carr = rarr[rr]
          let nc = carr.length()
          for c = 0; c < nc; c = c + 1 {
            let cc = c
            let cell = carr[cc]
            push_unit(
              acc,
              CellU,
              cell,
              inlines_plain(cell),
              top_i,
              is_start && rr == 0 && cc == 0,
              fn(ni) {
                let ra = rarr.copy()
                let ca = carr.copy()
                ca[cc] = ni
                ra[rr] = ca
                patch(TableBlock(Table::{ ..t, rows: ra }))
              },
              fn(tx) {
                let ra = rarr.copy()
                let ca = carr.copy()
                ca[cc] = one_run(tx)
                ra[rr] = ca
                patch(TableBlock(Table::{ ..t, rows: ra }))
              },
              None,
              noop_split,
            )
          }
        }
      }
      ImageBlock(alt, url) =>
        push_unit(
          acc,
          AtomicU,
          [],
          "![" + alt + "](" + url + ")",
          top_i,
          is_start,
          fn(_) { patch(b) },
          fn(_) { patch(b) },
          Some(fn() { drop_at(arr, total, ii, ctx) }),
          fn(_) { Some((patch_list([b, Paragraph([])]), 1)) },
        )
      Hr =>
        push_unit(
          acc,
          AtomicU,
          [],
          "---",
          top_i,
          is_start,
          fn(_) { patch(b) },
          fn(_) { patch(b) },
          Some(fn() { drop_at(arr, total, ii, ctx) }),
          fn(_) { Some((patch_list([b, Paragraph([])]), 1)) },
        )
      Raw(s) =>
        push_unit(
          acc,
          AtomicU,
          [],
          s,
          top_i,
          is_start,
          fn(_) { patch(b) },
          fn(_) { patch(b) },
          Some(fn() { drop_at(arr, total, ii, ctx) }),
          fn(_) { Some((patch_list([b, Paragraph([])]), 1)) },
        )
    }
  }
}

///|
/// 用 `f` 替换下标 `i` 处的顶层块（f 返回 None 时删除该块；越界不动）。
pub fn map_top_block(
  bs : Array[Block],
  i : Int,
  f : (Block) -> Block?,
) -> Array[Block] {
  if i < 0 || i >= bs.length() {
    return bs
  }
  let out : Array[Block] = []
  for k = 0; k < bs.length(); k = k + 1 {
    if k == i {
      match f(bs[k]) {
        Some(nb) => out.push(nb)
        None => ()
      }
    } else {
      out.push(bs[k])
    }
  }
  out
}
