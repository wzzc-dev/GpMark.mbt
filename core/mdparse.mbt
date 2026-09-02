/// Markdown → 块树解析。稳定子集结构化为块；不稳定构造（HTML 块、未闭合
/// 围栏等）保留原始源文为 Raw 块。

///|
pub fn parse_doc(src : String) -> Array[Block] {
  parse_blocks(split_lines_str(src))
}

///|
fn blank(line : String) -> Bool {
  trim_str(line) == ""
}

///|
fn indent_of(line : String) -> Int {
  let mut n = 0
  for c in line.to_array() {
    match c {
      ' ' => n = n + 1
      '\t' => n = n + 4
      _ => break
    }
  }
  n
}

///|
fn is_heading(line : String) -> Int? {
  let t = trim_str(line)
  let cs = t.to_array()
  if cs.length() == 0 || cs[0] != '#' {
    return None
  }
  let mut n = 0
  for c in cs {
    if c == '#' {
      n = n + 1
    } else {
      break
    }
  }
  if n >= 1 && n <= 6 && (cs.length() == n || cs[n] == ' ') {
    Some(n)
  } else {
    None
  }
}

///|
fn heading_text(line : String) -> String {
  let t = trim_str(line)
  let cs = t.to_array()
  let mut n = 0
  for c in cs {
    if c == '#' {
      n = n + 1
    } else {
      break
    }
  }
  if n >= 1 && n <= cs.length() {
    trim_str(String::from_array(cs[n:]))
  } else {
    t
  }
}

///|
fn all_char(s : String, c : Char) -> Bool {
  if s.length() == 0 {
    return false
  }
  for ch in s.to_array() {
    if ch != c {
      return false
    }
  }
  true
}

///|
fn is_hr(line : String) -> Bool {
  let t = replace_all_str(trim_str(line), " ", "")
  t.length() >= 3 && (all_char(t, '-') || all_char(t, '*') || all_char(t, '_'))
}

///|
fn fence_lang(line : String) -> String? {
  let t = trim_str(line)
  if starts_with_str(t, "```") {
    Some(trim_str(t[3:].to_owned()))
  } else {
    None
  }
}

///|
fn is_fence_close(line : String) -> Bool {
  trim_str(line) == "```"
}

///|
fn is_quote(line : String) -> Bool {
  starts_with_str(trim_str(line), ">")
}

///|
fn strip_quote(line : String) -> String {
  let t = trim_str(line)
  let rest = t[1:].to_owned()
  if starts_with_str(rest, " ") {
    rest[1:].to_owned()
  } else {
    rest
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
fn parse_marker(line : String) -> Marker? {
  let ind = indent_of(line)
  if ind >= 4 {
    return None
  }
  let t = trim_str(line)
  let cs = t.to_array()
  let n = cs.length()
  // 任务 - [ ] / - [x]
  let task_ok = n >= 6 &&
    cs[0] == '-' &&
    cs[1] == ' ' &&
    cs[2] == '[' &&
    cs[4] == ']' &&
    cs[5] == ' ' &&
    task_marker_char(cs[3])
  if task_ok {
    return Some(Marker::{
      ordered_start: None,
      checked: Some(cs[3] != ' '),
      rest: trim_str(t[6:].to_owned()),
    })
  }
  // 无序 -
  if n >= 1 && cs[0] == '-' && !is_hr(line) && (n == 1 || cs[1] == ' ') {
    let rest = if n >= 2 { trim_str(t[2:].to_owned()) } else { "" }
    return Some(Marker::{ ordered_start: None, checked: None, rest })
  }
  // 无序 * / +（* 需排除 hr）
  if n >= 2 &&
    (cs[0] == '*' || cs[0] == '+') &&
    cs[1] == ' ' &&
    !(cs[0] == '*' && is_hr(line)) {
    return Some(Marker::{
      ordered_start: None,
      checked: None,
      rest: trim_str(t[2:].to_owned()),
    })
  }
  // 有序 N. / N)
  let mut d = 0
  while d < n && is_digit(cs[d]) {
    d = d + 1
  }
  if d >= 1 && d + 1 < n && (cs[d] == '.' || cs[d] == ')') && cs[d + 1] == ' ' {
    let p = parse_int(String::from_array(cs[0:d]))
    return Some(Marker::{
      ordered_start: Some(if p == 0 { 1 } else { p }),
      checked: None,
      rest: trim_str(t[d + 2:].to_owned()),
    })
  }
  None
}

///|
fn is_digit(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
fn parse_int(s : String) -> Int {
  let mut v = 0
  for c in s.to_array() {
    if is_digit(c) {
      v = v * 10 + (c.to_int() - '0'.to_int())
    }
  }
  v
}

///|
fn is_table_sep(line : String) -> Bool {
  let t = trim_str(line)
  if !t.contains("|") || !t.contains("-") {
    return false
  }
  let mut ok = true
  for ch in t.to_array() {
    if !(ch == '|' || ch == '-' || ch == ':' || ch == ' ') {
      ok = false
      break
    }
  }
  ok
}

///|
fn is_table_row(line : String) -> Bool {
  !blank(line) && line.contains("|")
}

///|
fn split_cells(line : String) -> Array[String] {
  let mut t = trim_str(line)
  if starts_with_str(t, "|") {
    t = t[1:].to_owned()
  }
  if ends_with_str(t, "|") {
    t = t[:t.length() - 1].to_owned()
  }
  let out : Array[String] = []
  for sv in t.split("|") {
    out.push(trim_str(sv.to_owned()))
  }
  out
}

///|
fn is_block_start(line : String) -> Bool {
  is_heading(line) is Some(_) ||
  fence_lang(line) is Some(_) ||
  is_hr(line) ||
  is_quote(line) ||
  parse_marker(line) is Some(_)
}

///|
fn dedent(lines : Array[String], n : Int) -> Array[String] {
  let out : Array[String] = []
  for l in lines {
    out.push(dedent_line(l, n))
  }
  out
}

///|
fn dedent_line(line : String, n : Int) -> String {
  if indent_of(line) >= n {
    line[n:].to_owned()
  } else {
    trim_str(line)
  }
}

///|
fn first_trim_char(line : String) -> Char? {
  let cs = trim_str(line).to_array()
  if cs.length() > 0 {
    Some(cs[0])
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
          let body : Array[String] = []
          for k = i + 1; k < j; k = k + 1 {
            body.push(lines[k])
          }
          out.push(CodeBlock(lang, join_lines_str(body)))
          i = j + 1
        } else {
          let body : Array[String] = []
          for k = i; k < n; k = k + 1 {
            body.push(lines[k])
          }
          out.push(Raw(join_lines_str(body)))
          i = n
        }
        continue
      }
      None => ()
    }
    // 标题
    match is_heading(line) {
      Some(lv) => {
        out.push(Heading(lv, parse_inline(heading_text(line))))
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
      let inner : Array[String] = []
      while j < n && is_quote(lines[j]) {
        inner.push(strip_quote(lines[j]))
        j = j + 1
      }
      out.push(Quote(parse_blocks(inner)))
      i = j
      continue
    }
    // HTML 块 → Raw
    if indent_of(line) < 4 && first_trim_char(line) == Some('<') {
      let mut j = i
      let body : Array[String] = []
      while j < n && !blank(lines[j]) {
        body.push(lines[j])
        j = j + 1
      }
      out.push(Raw(join_lines_str(body)))
      i = j
      continue
    }
    // 表格
    if i + 1 < n && is_table_row(line) && is_table_sep(lines[i + 1]) {
      let rows : Array[Array[Array[Inline]]] = []
      rows.push(cells_row(split_cells(line)))
      let mut j = i + 2
      while j < n && is_table_row(lines[j]) && !is_block_start(lines[j]) {
        rows.push(cells_row(split_cells(lines[j])))
        j = j + 1
      }
      out.push(TableBlock(Table::{ rows, has_header: true }))
      i = j
      continue
    }
    // 列表
    if parse_marker(line) is Some(_) {
      let (list, next) = parse_list(lines, i)
      out.push(list)
      i = next
      continue
    }
    // 独占一行的图片
    if is_standalone_image(line) {
      let (alt, url) = parse_image_target(trim_str(line))
      out.push(ImageBlock(alt, url))
      i = i + 1
      continue
    }
    // 段落
    let mut j = i
    let body : Array[String] = []
    while j < n && !blank(lines[j]) && !is_block_start(lines[j]) {
      body.push(lines[j])
      j = j + 1
    }
    if j == i {
      body.push(lines[i])
      j = i + 1
    }
    out.push(
      Paragraph(parse_inline(replace_all_str(join_lines_str(body), "\n", " "))),
    )
    i = j
  }
  out
}

// 一行表格 → 每格一组 inline

///|
fn cells_row(cells : Array[String]) -> Array[Array[Inline]] {
  let out : Array[Array[Inline]] = []
  for c in cells {
    out.push(parse_inline(c))
  }
  out
}

///|
fn is_standalone_image(line : String) -> Bool {
  let t = trim_str(line)
  let target = parse_image_target(t)
  starts_with_str(t, "![") && ends_with_str(t, ")") && target.1 != ""
}

///|
fn parse_image_target(s : String) -> (String, String) {
  let cs = s.to_array()
  let n = cs.length()
  if n < 5 || cs[0] != '!' || cs[1] != '[' {
    return ("", "")
  }
  let mut i = 2
  let mut alt = ""
  let mut found_alt = false
  while i < n {
    if cs[i] == ']' {
      found_alt = true
      break
    }
    alt = alt + cs[i].to_string()
    i = i + 1
  }
  if !found_alt || i + 1 >= n || cs[i + 1] != '(' {
    return ("", "")
  }
  i = i + 2
  let mut url = ""
  let mut found_url = false
  while i < n {
    if cs[i] == ')' {
      found_url = true
      break
    }
    url = url + cs[i].to_string()
    i = i + 1
  }
  if !found_url || i != n - 1 {
    return ("", "")
  }
  (alt, url)
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
fn parse_list(lines : Array[String], start : Int) -> (Block, Int) {
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
        let content_text : Array[String] = [m.rest]
        let mut j = i + 1
        let cont_or_child : Array[String] = []
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
        let tail : Array[String] = []
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
            content_text.push(trim_str(cont_or_child[ci]))
            ci = ci + 1
          }
        }
        let children = if tail.length() > 0 {
          parse_blocks(dedent(tail, base + 2))
        } else {
          []
        }
        items.push(Item::{
          checked: m.checked,
          content: parse_inline(
            replace_all_str(join_lines_str(content_text), "\n", " "),
          ),
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
