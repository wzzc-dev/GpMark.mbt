/// 行内内容模型：扁平的样式 run 数组 + 少量原子节点。
/// 编辑（插入/删除/样式 toggle）都在这个表示上进行；Markdown 语法只在
/// 导入/导出时出现（见 mdparse/mdwrite）。
/// 容器统一用 Array（本工具链下 prelude 不再提供 cons List），写路径
/// 全部 copy-on-write，不原地改已入档的数据。

///|
pub(all) enum Inline {
  Run(String, Marks)
  // 链接：(url, 内层 run)。内层不允许再嵌链接。
  Link(String, Array[Inline])
  // 行内图片：(alt, url)。原子节点，光标不可切入其内部。
  Image(String, String)
  // 脚注引用 [^name]
  Footnote(String)
} derive(Eq, Debug)

///|
pub fn inline_plain(n : Inline) -> String {
  match n {
    Run(s, _) => s
    Link(_, inner) => inlines_plain(inner)
    Image(alt, url) => "![" + alt + "](" + url + ")"
    Footnote(nm) => "[^" + nm + "]"
  }
}

///|
pub fn inlines_plain(ns : Array[Inline]) -> String {
  let parts : Array[String] = []
  for n in ns {
    parts.push(inline_plain(n))
  }
  parts.join("")
}

///|
/// 渲染态的字符数（光标偏移以此为计，非字节数）。
pub fn inlines_len(ns : Array[Inline]) -> Int {
  inlines_plain(ns).to_array().length()
}

///|
/// 规范化：删除空 run、合并相邻且样式相同的 run。
pub fn normalize_inlines(ns : Array[Inline]) -> Array[Inline] {
  let out : Array[Inline] = []
  for n in ns {
    match n {
      Run("", _) => ()
      Run(s, m) =>
        if out.length() > 0 {
          match out[out.length() - 1] {
            Run(s0, m0) =>
              if m0 == m {
                out[out.length() - 1] = Run(s0 + s, m)
              } else {
                out.push(Run(s, m))
              }
            _ => out.push(Run(s, m))
          }
        } else {
          out.push(Run(s, m))
        }
      _ => out.push(n)
    }
  }
  out
}

///|
/// 在字符偏移 `off` 处把 run 数组切成两半（返回两半，原数组不动）。
/// 原子节点不可切分，整体归入一侧（偏移落在其内部时吸附到其右边界之后）。
pub fn inlines_split_at(
  ns : Array[Inline],
  off : Int,
) -> (Array[Inline], Array[Inline]) {
  let left : Array[Inline] = []
  let right : Array[Inline] = []
  let mut remaining = if off < 0 { 0 } else { off }
  let mut i = 0
  while i < ns.length() {
    let n = ns[i]
    let len = inline_plain(n).to_array().length()
    if remaining >= len {
      left.push(n)
      remaining = remaining - len
    } else if remaining == 0 {
      right.push(n)
    } else {
      // 0 < remaining < len: 只有 Run 可切
      match n {
        Run(s, m) => {
          let cs = s.to_array()
          left.push(Run(String::from_array(cs[0:remaining]), m))
          right.push(Run(String::from_array(cs[remaining:]), m))
        }
        _ => left.push(n) // 吸附到节点之后
      }
      remaining = 0
    }
    i = i + 1
  }
  (left, right)
}

///|
/// 把 `[start, end)` 范围替换为 `text`（纯文本，带 `marks`）。
pub fn inlines_insert(
  ns : Array[Inline],
  start : Int,
  end : Int,
  text : String,
  marks : Marks,
) -> Array[Inline] {
  let (a, bc) = inlines_split_at(ns, start)
  let (_, c) = inlines_split_at(bc, end - start)
  let out : Array[Inline] = []
  for n in a {
    out.push(n)
  }
  if text != "" {
    out.push(Run(text, marks))
  }
  for n in c {
    out.push(n)
  }
  normalize_inlines(out)
}

///|
/// 对 `[start, end)` 范围内的 run 应用样式更新（原子节点不受影响）。
pub fn inlines_toggle(
  ns : Array[Inline],
  start : Int,
  end : Int,
  upd : (Marks) -> Marks,
) -> Array[Inline] {
  let (a, bc) = inlines_split_at(ns, start)
  let (mid, c) = inlines_split_at(bc, end - start)
  let out : Array[Inline] = []
  for n in a {
    out.push(n)
  }
  for n in mid {
    match n {
      Run(s, m) => out.push(Run(s, upd(m)))
      _ => out.push(n)
    }
  }
  for n in c {
    out.push(n)
  }
  normalize_inlines(out)
}

///|
/// 拼接两组 run。
pub fn inlines_concat(a : Array[Inline], b : Array[Inline]) -> Array[Inline] {
  let out : Array[Inline] = []
  for n in a {
    out.push(n)
  }
  for n in b {
    out.push(n)
  }
  normalize_inlines(out)
}

///|
/// `[start, end)` 处的纯文本（越界自动裁剪）。
pub fn inlines_slice_plain(
  ns : Array[Inline],
  start : Int,
  end : Int,
) -> String {
  let cs = inlines_plain(ns).to_array()
  let n = cs.length()
  let s = if start < 0 { 0 } else if start > n { n } else { start }
  let e = if end < s { s } else if end > n { n } else { end }
  String::from_array(cs[s:e])
}

///|
/// 取 `off` 位置左侧相邻 run 的样式（键入时继承左邻格式）；无左邻则 default。
pub fn inlines_marks_before(ns : Array[Inline], off : Int) -> Marks {
  if off <= 0 {
    return Marks::default()
  }
  let (left, _) = inlines_split_at(ns, off)
  match left.length() {
    0 => Marks::default()
    k =>
      match left[k - 1] {
        Run(_, m) => m
        _ => Marks::default()
      }
  }
}
