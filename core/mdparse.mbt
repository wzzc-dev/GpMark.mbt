/// Markdown → 块树解析。稳定子集结构化为块；不稳定构造（HTML 块、未闭合
/// 围栏等）保留原始源文为 Raw 块。

///|
pub fn parse_doc(src : String) -> Array[Block] {
  parse_blocks_impl(split_lines_view(src), deferred=false)
}

///|
/// 打开路径的延迟解析：块边界与 parse_doc 完全一致，但叶子内容（段落/
/// 标题/列表项/表格单元格）不解析 inline，用单个 plain Run 承载原文。
/// plain = 原文使单元数、光标偏移空间、serialize 往返与即时解析形态
/// 保持一致；渲染窗口内的块由 Block::activate 物化成真实 run。
pub fn parse_doc_deferred(src : String) -> Array[Block] {
  parse_blocks_impl(split_lines_view(src), deferred=true)
}

///|
/// 单个叶子内容的 inline 构造：defer 时原文成为一个 plain Run，
/// plain 语义与解析结果一致（inline_src(plain run) = 原文，幂等）。
fn inlines_of(src : StringView, deferred~ : Bool) -> Array[Inline] {
  if deferred {
    [Run(src.to_owned(), Marks::default())]
  } else {
    parse_inline(src.to_owned())
  }
}

///|
/// 视图切片 + 单趟 trim 的单次拷贝：取代 sub().to_owned().trim()
/// .to_owned() 的双重拷贝（marker rest / 标题文本 / fence info）。
fn sub_trimmed(t : StringView, start~ : Int) -> String {
  sub_trimmed_range(t, start~, end=t.length())
}

///|
fn sub_trimmed_range(t : StringView, start~ : Int, end~ : Int) -> String {
  let n = end
  let mut lo = start
  while lo < n && {
    let c = t.get_char(lo).unwrap_or(' ')
    c == ' ' || c == '\t'
  } {
    lo = lo + 1
  }
  let mut hi = n
  while hi > lo && {
    let c = t.get_char(hi - 1).unwrap_or(' ')
    c == ' ' || c == '\t'
  } {
    hi = hi - 1
  }
  t.sub(start=lo, end=hi).to_owned()
}

///|
/// 软换行段落的叶子内容：defer 时按空格连接直接物化单个 plain Run
/// （\n→空格 归一与连接合为一趟拷贝，取代 join+replace+owned 三趟）。
fn paragraph_inlines_of_views(
  body : Array[StringView],
  deferred~ : Bool,
) -> Array[Inline] {
  if deferred {
    let b = StringBuilder()
    let mut first = true
    for v in body {
      if first {
        first = false
      } else {
        b.write_char(' ')
      }
      append_view(b, v)
    }
    [Run(b.to_string(), Marks::default())]
  } else {
    inlines_of(join_views_spaced(body), deferred~)
  }
}

///|
fn blank(line : StringView) -> Bool {
  // 无分配：trim 返回 view，逐行判定的分配是大文档打开的主要成本。
  line.trim().length() == 0
}

///|
///|
fn indent_of(line : StringView) -> Int {
  let mut n = 0
  for c in line {
    match c {
      ' ' => n = n + 1
      '\t' => n = n + 4
      _ => break
    }
  }
  n
}

///|
fn is_heading(line : StringView) -> Int? {
  let t = line.trim()
  let len = t.length()
  let mut n = 0
  while n < len && t.get_char(n).unwrap_or(' ') == '#' {
    n = n + 1
  }
  if n >= 1 && n <= 6 && (len == n || t.get_char(n).unwrap_or(' ') == ' ') {
    Some(n)
  } else {
    None
  }
}

///|
fn heading_text(line : StringView) -> String {
  let t = line.trim()
  let len = t.length()
  let mut n = 0
  while n < len && t.get_char(n).unwrap_or(' ') == '#' {
    n = n + 1
  }
  if n >= 1 && n <= len {
    sub_trimmed(t, start=n)
  } else {
    t.to_owned()
  }
}

///|
fn is_hr(line : StringView) -> Bool {
  // 语义与旧实现一致：trim 后忽略空格，其余字符须全部同为你 -/*/_
  // 之一（内部制表符不等价于空格，保持原判定）。
  let t = line.trim()
  let mut n = 0
  let mut c0 : Char? = None
  for ch in t {
    if ch == ' ' {
      continue
    }
    match c0 {
      None => {
        c0 = Some(ch)
        n = 1
      }
      Some(c) =>
        if ch != c {
          return false
        } else {
          n = n + 1
        }
    }
  }
  n >= 3 && c0 is Some('-'|'*'|'_')
}

///|
fn fence_lang(line : StringView) -> String? {
  let t = line.trim()
  if t.length() >= 3 &&
    t.get_char(0).unwrap_or(' ') == '`' &&
    t.get_char(1).unwrap_or(' ') == '`' &&
    t.get_char(2).unwrap_or(' ') == '`' {
    Some(sub_trimmed(t, start=3))
  } else {
    None
  }
}

///|
fn is_fence_close(line : StringView) -> Bool {
  line.trim() == "```"
}

///|
fn is_quote(line : StringView) -> Bool {
  let t = line.trim()
  t.length() > 0 && t.get_char(0).unwrap_or(' ') == '>'
}

///|
fn strip_quote(line : StringView) -> String {
  let t = line.trim()
  let rest = t.sub(start=1, end=t.length())
  if rest.length() > 0 && rest.get_char(0).unwrap_or(' ') == ' ' {
    rest.sub(start=1, end=rest.length()).to_owned()
  } else {
    rest.to_owned()
  }
}

///|
priv struct Marker {
  ordered_start : Int? // None = bullet
  checked : Bool?
  rest : String
}

///|
fn task_marker_char(c : Char) -> Bool {
  c == ' ' || c == 'x' || c == 'X'
}

///|
fn parse_marker(line : StringView) -> Marker? {
  let ind = indent_of(line)
  if ind >= 4 {
    return None
  }
  let t = line.trim()
  let n = t.length()
  let at = fn(i : Int) -> Char { t.get_char(i).unwrap_or(' ') }
  // 任务 - [ ] / - [x]
  if n >= 6 &&
    at(0) == '-' &&
    at(1) == ' ' &&
    at(2) == '[' &&
    at(4) == ']' &&
    at(5) == ' ' &&
    task_marker_char(at(3)) {
    return Some(Marker::{
      ordered_start: None,
      checked: Some(at(3) != ' '),
      rest: sub_trimmed(t, start=6),
    })
  }
  // 无序 -
  if n >= 1 && at(0) == '-' && !is_hr(line) && (n == 1 || at(1) == ' ') {
    let rest = if n >= 2 {
      sub_trimmed(t, start=2)
    } else {
      ""
    }
    return Some(Marker::{ ordered_start: None, checked: None, rest })
  }
  // 无序 * / +（* 需排除 hr）
  if n >= 2 &&
    (at(0) == '*' || at(0) == '+') &&
    at(1) == ' ' &&
    !(at(0) == '*' && is_hr(line)) {
    return Some(Marker::{
      ordered_start: None,
      checked: None,
      rest: sub_trimmed(t, start=2),
    })
  }
  // 有序 N. / N)
  let mut d = 0
  while d < n && is_digit(at(d)) {
    d = d + 1
  }
  if d >= 1 && d + 1 < n && (at(d) == '.' || at(d) == ')') && at(d + 1) == ' ' {
    let p = parse_int(t.sub(start=0, end=d))
    return Some(Marker::{
      ordered_start: Some(if p == 0 { 1 } else { p }),
      checked: None,
      rest: sub_trimmed(t, start=d + 2),
    })
  }
  None
}

///|
fn is_digit(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
fn parse_int(s : StringView) -> Int {
  let mut v = 0
  for c in s {
    if is_digit(c) {
      v = v * 10 + (c.to_int() - '0'.to_int())
    }
  }
  v
}

///|
fn is_table_sep(line : StringView) -> Bool {
  let mut has_pipe = false
  let mut has_dash = false
  for ch in line.trim() {
    if ch == '|' {
      has_pipe = true
    } else if ch == '-' {
      has_dash = true
    } else if !(ch == ':' || ch == ' ') {
      return false
    }
  }
  has_pipe && has_dash
}

///|
fn is_table_row(line : StringView) -> Bool {
  if blank(line) {
    return false
  }
  let mut has_pipe = false
  for ch in line {
    if ch == '|' {
      has_pipe = true
      break
    }
  }
  has_pipe
}

///|
fn split_cells(line : StringView) -> Array[StringView] {
  let t = line.trim()
  let lo = if t.length() > 0 && t.get_char(0).unwrap_or(' ') == '|' {
    1
  } else {
    0
  }
  let hi = if t.length() > lo && t.get_char(t.length() - 1).unwrap_or(' ') == '|' {
    t.length() - 1
  } else {
    t.length()
  }
  let out : Array[StringView] = []
  let mut start = lo
  let mut i = lo
  while i < hi {
    if t.get_char(i).unwrap_or(' ') == '|' {
      out.push(sub_trimmed_range(t, start~, end=i))
      start = i + 1
    }
    i = i + 1
  }
  out.push(sub_trimmed_range(t, start~, end=hi))
  out
}

///|
fn is_block_start(line : StringView) -> Bool {
  is_heading(line) is Some(_) ||
  fence_lang(line) is Some(_) ||
  is_hr(line) ||
  is_quote(line) ||
  parse_marker(line) is Some(_)
}

///|
fn dedent(lines : Array[StringView], n : Int) -> Array[StringView] {
  let out : Array[StringView] = []
  for l in lines {
    out.push(dedent_line(l, n))
  }
  out
}

///|
fn dedent_line(line : StringView, n : Int) -> StringView {
  if indent_of(line) >= n {
    line.sub(start=n, end=line.length())
  } else {
    line.trim()
  }
}

///|
fn first_trim_char(line : StringView) -> Char? {
  let t = line.trim()
  if t.length() > 0 {
    Some(t.get_char(0).unwrap_or(' '))
  } else {
    None
  }
}

///|
fn _cells_inline(cells : Array[String]) -> Array[Inline] {
  let out : Array[Inline] = []
  for c in cells {
    for i in parse_inline(c) {
      out.push(i)
    }
  }
  out
}

///|
/// Markdown 块解析。
pub fn parse_blocks(lines : Array[String]) -> Array[Block] {
  let views : Array[StringView] = []
  for l in lines {
    views.push(l)
  }
  parse_blocks_impl(views, deferred=false)
}

///|
fn parse_blocks_impl(lines : Array[StringView], deferred~ : Bool) -> Array[Block] {
  let n = lines.length()
  let out : Array[Block] = []
  let mut i = 0
  while i < n {
    let line = lines[i]
    if blank(line) {
      i = i + 1
      continue
    }
    // 围栏代码块
    match fence_lang(line) {
      Some(lang) => {
        let mut j = i + 1
        let mut closed = false
        while j < n {
          if is_fence_close(lines[j]) {
            closed = true
            break
          }
          j = j + 1
        }
        if closed {
          let body : Array[StringView] = []
          for k = i + 1; k < j; k = k + 1 {
            body.push(lines[k])
          }
          out.push(CodeBlock(lang, join_views_str(body, "\n")))
          i = j + 1
        } else {
          let body : Array[StringView] = []
          for k = i; k < n; k = k + 1 {
            body.push(lines[k])
          }
          out.push(Raw(join_views_str(body, "\n")))
          i = n
        }
        continue
      }
      None => ()
    }
    // 标题
    match is_heading(line) {
      Some(lv) => {
        out.push(Heading(lv, inlines_of(heading_text(line), deferred~)))
        i = i + 1
        continue
      }
      None => ()
    }
    if is_hr(line) {
      out.push(Hr)
      i = i + 1
      continue
    }
    if is_quote(line) {
      let mut j = i
      let inner : Array[StringView] = []
      while j < n && is_quote(lines[j]) {
        inner.push(strip_quote(lines[j]))
        j = j + 1
      }
      out.push(Quote(parse_blocks_impl(inner, deferred~)))
      i = j
      continue
    }
    // HTML 块 → Raw
    if indent_of(line) < 4 && first_trim_char(line) == Some('<') {
      let mut j = i
      let body : Array[StringView] = []
      while j < n && !blank(lines[j]) {
        body.push(lines[j])
        j = j + 1
      }
      out.push(Raw(join_views_str(body, "\n")))
      i = j
      continue
    }
    // 表格
    if i + 1 < n && is_table_row(line) && is_table_sep(lines[i + 1]) {
      let rows : Array[Array[Array[Inline]]] = []
      rows.push(cells_row(split_cells(line), deferred~))
      let mut j = i + 2
      while j < n && is_table_row(lines[j]) && !is_block_start(lines[j]) {
        rows.push(cells_row(split_cells(lines[j]), deferred~))
        j = j + 1
      }
      out.push(TableBlock(Table::{ rows, has_header: true }))
      i = j
      continue
    }
    // 列表
    if parse_marker(line) is Some(_) {
      let (list, next) = parse_list(lines, i, deferred~)
      out.push(list)
      i = next
      continue
    }
    // 独占一行的图片
    if is_standalone_image(line) {
      let (alt, url) = parse_image_target(line.trim())
      out.push(ImageBlock(alt, url))
      i = i + 1
      continue
    }
    // 段落
    let mut j = i
    let body : Array[StringView] = []
    while j < n && !blank(lines[j]) && !is_block_start(lines[j]) {
      body.push(lines[j])
      j = j + 1
    }
    if j == i {
      body.push(lines[i])
      j = i + 1
    }
    out.push(
      Paragraph(
        paragraph_inlines_of_views(body, deferred~),
      ),
    )
    i = j
  }
  out
}

// 一行表格 → 每格一组 inline

///|
fn cells_row(cells : Array[StringView], deferred~ : Bool) -> Array[Array[Inline]] {
  let out : Array[Array[Inline]] = []
  for c in cells {
    out.push(inlines_of(c, deferred~))
  }
  out
}

///|
fn is_standalone_image(line : StringView) -> Bool {
  let t = line.trim()
  let n = t.length()
  let target = parse_image_target(t)
  n >= 2 &&
  t.get_char(0).unwrap_or(' ') == '!' &&
  t.get_char(1).unwrap_or(' ') == '[' &&
  t.get_char(n - 1).unwrap_or(' ') == ')' &&
  target.1 != ""
}

///|
fn parse_image_target(s : StringView) -> (String, String) {
  let n = s.length()
  let at = fn(i : Int) -> Char { s.get_char(i).unwrap_or(' ') }
  if n < 5 || at(0) != '!' || at(1) != '[' {
    return ("", "")
  }
  let mut i = 2
  let alt = StringBuilder()
  let mut found_alt = false
  while i < n {
    if at(i) == ']' {
      found_alt = true
      break
    }
    alt.write_char(at(i))
    i = i + 1
  }
  if !found_alt || i + 1 >= n || at(i + 1) != '(' {
    return ("", "")
  }
  i = i + 2
  let url = StringBuilder()
  let mut found_url = false
  while i < n {
    if at(i) == ')' {
      found_url = true
      break
    }
    url.write_char(at(i))
    i = i + 1
  }
  if !found_url || i != n - 1 {
    return ("", "")
  }
  (alt.to_string(), url.to_string())
}

///|
fn marker_same_list(a : Marker, b : Marker) -> Bool {
  if (a.ordered_start is Some(_)) != (b.ordered_start is Some(_)) {
    return false
  }
  if a.ordered_start is Some(_) {
    true
  } else {
    (a.checked is Some(_)) == (b.checked is Some(_))
  }
}

///|
fn parse_list(lines : Array[StringView], start : Int, deferred~ : Bool) -> (Block, Int) {
  let n = lines.length()
  let first_m = match parse_marker(lines[start]) {
    Some(m) => m
    None => return (Paragraph([]), start + 1)
  }
  let base = indent_of(lines[start])
  let ordered_start = first_m.ordered_start
  let items : Array[Item] = []
  let mut any_task = first_m.checked is Some(_)
  let mut i = start
  while i < n {
    let line = lines[i]
    if blank(line) {
      let mut j = i
      while j < n && blank(lines[j]) {
        j = j + 1
      }
      if j < n &&
        indent_of(lines[j]) >= base + 2 &&
        parse_marker(lines[j]) is None {
        i = j
        continue
      } else {
        break
      }
    }
    match parse_marker(line) {
      Some(m) => {
        if indent_of(line) > base || !marker_same_list(first_m, m) {
          break
        }
        if m.checked is Some(_) {
          any_task = true
        }
        let content_text : Array[StringView] = [m.rest]
        let mut j = i + 1
        let cont_or_child : Array[StringView] = []
        while j < n {
          if blank(lines[j]) {
            let mut k = j
            while k < n && blank(lines[k]) {
              k = k + 1
            }
            if k < n && indent_of(lines[k]) >= base + 2 {
              j = k
              continue
            } else {
              break
            }
          }
          if indent_of(lines[j]) >= base + 2 {
            cont_or_child.push(lines[j])
            j = j + 1
            continue
          }
          break
        }
        // 缩进行：首个 marker 之前的非块行并入本项文本，其余进子块
        let tail : Array[StringView] = []
        let mut ci = 0
        let cn = cont_or_child.length()
        while ci < cn {
          let d = dedent_line(cont_or_child[ci], base + 2)
          if parse_marker(d) is Some(_) || is_block_start(d) {
            while ci < cn {
              tail.push(cont_or_child[ci])
              ci = ci + 1
            }
          } else {
            content_text.push(cont_or_child[ci].trim())
            ci = ci + 1
          }
        }
        let children = if tail.length() > 0 {
          parse_blocks_impl(dedent(tail, base + 2), deferred~)
        } else {
          []
        }
        items.push(Item::{
          checked: m.checked,
          content: paragraph_inlines_of_views(content_text, deferred~),
          children,
        })
        i = j
      }
      None => break
    }
  }
  let kind = match ordered_start {
    Some(p) => Ordered(p)
    None => if any_task { Task } else { Bullet }
  }
  (ListBlock(kind, items), i)
}

///|
/// 行内 Markdown 解析（公开：编辑核心块内重解析使用）。
pub fn parse_inline(s : String) -> Array[Inline] {
  parse_inline_gen(s.to_array(), true)
}

///|
fn mark_of(k : Int) -> Marks {
  match k {
    1 => Marks::{ bold: false, italic: true, strike: false, code: false }
    2 => Marks::{ bold: true, italic: false, strike: false, code: false }
    _ => Marks::{ bold: true, italic: true, strike: false, code: false }
  }
}

///|
fn is_alnum_(c : Char) -> Bool {
  c == '_' ||
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9')
}

///|
fn run_len(cs : Array[Char], from : Int, c : Char) -> Int {
  let mut k = 0
  while from + k < cs.length() && cs[from + k] == c {
    k = k + 1
  }
  k
}

// 从 from 起找下一个「至少 k 个连续 c 且前一字符非空格」的位置，找不到返回 -1

///|
fn find_close(cs : Array[Char], from : Int, c : Char, k : Int) -> Int {
  let n = cs.length()
  let mut p = from
  while p + k <= n {
    if cs[p] == c && run_len(cs, p, c) >= k && (p == 0 || cs[p - 1] != ' ') {
      return p
    }
    p = p + 1
  }
  -1
}

///|
fn find_char(cs : Array[Char], from : Int, c : Char) -> Int {
  let n = cs.length()
  let mut p = from
  while p < n {
    if cs[p] == c {
      return p
    }
    p = p + 1
  }
  -1
}

///|
fn push_all(dst : Array[Inline], src : Array[Inline]) -> Unit {
  for x in src {
    dst.push(x)
  }
}

///|
fn map_marks(ns : Array[Inline], f : (Marks) -> Marks) -> Array[Inline] {
  let out : Array[Inline] = []
  for n in ns {
    match n {
      Run(s, m) => out.push(Run(s, f(m)))
      _ => out.push(n)
    }
  }
  out
}

///|
fn parse_inline_gen(cs : Array[Char], allow_link : Bool) -> Array[Inline] {
  let out : Array[Inline] = []
  let n = cs.length()
  let mut buf : Array[Char] = []
  let mut i = 0
  while i < n {
    let c = cs[i]
    // 转义
    if c == '\\' && i + 1 < n {
      buf.push(cs[i + 1])
      i = i + 2
      continue
    }
    // 行内代码
    if c == '`' {
      let k = run_len(cs, i, '`')
      let close = find_close(cs, i + k, '`', k)
      if close >= 0 {
        if buf.length() > 0 {
          out.push(Run(String::from_array(buf), Marks::default()))
          buf = []
        }
        let inner = trim_str(String::from_array(cs[i + k:close]))
        out.push(
          Run(inner, Marks::{
            bold: false,
            italic: false,
            strike: false,
            code: true,
          }),
        )
        i = close + k
        continue
      } else {
        for _ in 0..<k {
          buf.push('`')
        }
        i = i + k
        continue
      }
    }
    // 删除线 ~~
    if c == '~' && run_len(cs, i, '~') >= 2 {
      let close = find_close(cs, i + 2, '~', 2)
      if close >= 0 {
        if buf.length() > 0 {
          out.push(Run(String::from_array(buf), Marks::default()))
          buf = []
        }
        push_all(
          out,
          map_marks(parse_inline_gen(cs[i + 2:close].to_owned(), allow_link), fn(
            m,
          ) {
            Marks::{ ..m, strike: true }
          }),
        )
        i = close + 2
        continue
      }
    }
    // 强调 * / _
    if c == '*' || c == '_' {
      let k = run_len(cs, i, c)
      let kk = if k > 3 { 3 } else { k }
      let boundary_ok = if c == '_' {
        i == 0 || !is_alnum_(cs[i - 1])
      } else {
        true
      }
      let content_ok = i + kk < n && cs[i + kk] != ' '
      let close = if boundary_ok && content_ok {
        find_close(cs, i + kk, c, kk)
      } else {
        -1
      }
      if close >= 0 {
        if buf.length() > 0 {
          out.push(Run(String::from_array(buf), Marks::default()))
          buf = []
        }
        let m = mark_of(kk)
        push_all(
          out,
          map_marks(parse_inline_gen(cs[i + kk:close].to_owned(), allow_link), fn(
            mm,
          ) {
            mm.union(m)
          }),
        )
        i = close + kk
        continue
      } else {
        for _ in 0..<kk {
          buf.push(c)
        }
        i = i + kk
        continue
      }
    }
    // 图片 ![alt](url)
    if c == '!' && i + 1 < n && cs[i + 1] == '[' {
      let rb = find_char(cs, i + 2, ']')
      if rb >= 0 && rb + 1 < n && cs[rb + 1] == '(' {
        let rp = find_char(cs, rb + 2, ')')
        if rp >= 0 {
          if buf.length() > 0 {
            out.push(Run(String::from_array(buf), Marks::default()))
            buf = []
          }
          out.push(
            Image(
              String::from_array(cs[i + 2:rb]),
              String::from_array(cs[rb + 2:rp]),
            ),
          )
          i = rp + 1
          continue
        }
      }
      buf.push('!')
      i = i + 1
      continue
    }
    // 脚注引用 [^name]
    if c == '[' && i + 1 < n && cs[i + 1] == '^' {
      let rb = find_char(cs, i + 2, ']')
      if rb >= 0 {
        if buf.length() > 0 {
          out.push(Run(String::from_array(buf), Marks::default()))
          buf = []
        }
        out.push(Footnote(String::from_array(cs[i + 2:rb])))
        i = rb + 1
        continue
      }
    }
    // 链接 [text](url)
    if c == '[' && allow_link {
      let rb = find_char(cs, i + 1, ']')
      if rb >= 0 && rb + 1 < n && cs[rb + 1] == '(' {
        let rp = find_char(cs, rb + 2, ')')
        if rp >= 0 {
          if buf.length() > 0 {
            out.push(Run(String::from_array(buf), Marks::default()))
            buf = []
          }
          let inner = parse_inline_gen(cs[i + 1:rb].to_owned(), false)
          out.push(Link(String::from_array(cs[rb + 2:rp]), inner))
          i = rp + 1
          continue
        }
      }
    }
    buf.push(c)
    i = i + 1
  }
  if buf.length() > 0 {
    out.push(Run(String::from_array(buf), Marks::default()))
  }
  normalize_inlines(out)
}
