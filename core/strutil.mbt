/// 字符串小工具：封装新版 slim core 的 String/StringView API 差异，
/// 解析器/序列化器统一走这里，避免语义漂移。

///|
pub fn trim_str(s : String) -> String {
  s.trim().to_owned()
}

///|
pub fn starts_with_str(s : String, p : StringView) -> Bool {
  match s.find(p) {
    Some(0) => true
    _ => false
  }
}

///|
pub fn ends_with_str(s : String, p : String) -> Bool {
  let n = s.length()
  let m = p.length()
  m <= n && s.substring(start=n - m) == p
}

///|
pub fn replace_all_str(s : String, old : StringView, new : String) -> String {
  if old.length() == 0 {
    return s
  }
  let parts : Array[String] = []
  let mut rest = s
  let mut go = true
  while go {
    match rest.find(old) {
      None => {
        parts.push(rest)
        go = false
      }
      Some(i) => {
        parts.push(rest.substring(end=i))
        parts.push(new)
        rest = rest.substring(start=i + old.length())
      }
    }
  }
  concat_str(parts)
}

///|
pub fn concat_str(parts : Array[String]) -> String {
  parts.join("")
}

///|
pub fn split_lines_str(s : String) -> Array[String] {
  let out : Array[String] = []
  if s == "" {
    return out
  }
  let t = if ends_with_str(s, "\n") {
    s.substring(end=s.length() - 1)
  } else {
    s
  }
  for sv in t.split("\n") {
    let line = sv.to_owned()
    out.push(
      if ends_with_str(line, "\r") {
        line.substring(end=line.length() - 1)
      } else {
        line
      },
    )
  }
  out
}

///|
/// 零拷贝行视图切分：解析管线的行扫描用。每行一个 view（不物化 owned
/// 字符串）——24 万行的 owned 化是大文档结构扫描的主要分配源。切分
/// 边界都在 \n / \r 上（BMP），不会切开代理对。
pub fn split_lines_view(s : String) -> Array[StringView] {
  let out : Array[StringView] = []
  if s == "" {
    return out
  }
  let n = s.length()
  let mut start = 0
  let mut unit = 0
  let mut prev_is_cr = false
  for ch in s {
    if ch == '\n' {
      let end = if prev_is_cr && unit > start { unit - 1 } else { unit }
      out.push(s.sub(start=start, end=end))
      prev_is_cr = false
      start = unit + 1
    } else {
      prev_is_cr = ch == '\r'
    }
    unit = unit + ch.utf16_len()
  }
  if start < n {
    let end = if prev_is_cr && n > start { n - 1 } else { n }
    out.push(s.sub(start=start, end=end))
  }
  out
}

///|
/// 把 StringView 追加进 StringBuilder（不物化中间字符串）。
fn append_view(b : StringBuilder, v : StringView) -> Unit {
  for ch in v {
    b.write_char(ch)
  }
}

///|
/// 行视图按空格连接为单个 owned 字符串（单次拷贝）：软换行段落的
/// \n→空格 归一与连接合为一趟，取代 join+replace_all 的两趟拷贝。
fn join_views_spaced(parts : Array[StringView]) -> String {
  let b = StringBuilder()
  let mut first = true
  for v in parts {
    if first {
      first = false
    } else {
      b.write_char(' ')
    }
    append_view(b, v)
  }
  b.to_string()
}

///|
pub fn join_lines_str(lines : Array[String]) -> String {
  lines.join("\n")
}

///|
pub fn repeat_str(s : String, n : Int) -> String {
  if n <= 0 {
    ""
  } else {
    s.repeat(n)
  }
}

///|
fn join_cells_str(parts : Array[String]) -> String {
  parts.join(" | ")
}

///|
fn repeat_arr_str(s : String, n : Int) -> Array[String] {
  let out : Array[String] = []
  for _ in 0..<n {
    out.push(s)
  }
  out
}

///|
pub fn join_views_str(parts : Array[StringView], sep : String) -> String {
  let b = StringBuilder()
  let mut first = true
  for v in parts {
    if first {
      first = false
    } else {
      b.write_string(sep)
    }
    append_view(b, v)
  }
  b.to_string()
}
