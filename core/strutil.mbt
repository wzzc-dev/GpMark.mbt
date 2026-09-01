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
  let mut out = ""
  for p in parts {
    out = out + p
  }
  out
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
pub fn join_lines_str(lines : Array[String]) -> String {
  let mut out = ""
  let mut first = true
  for l in lines {
    if first {
      out = l
      first = false
    } else {
      out = out + "\n" + l
    }
  }
  out
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
  let mut out = ""
  let mut first = true
  for p in parts {
    if first {
      out = p
      first = false
    } else {
      out = out + " | " + p
    }
  }
  out
}

///|
fn repeat_arr_str(s : String, n : Int) -> Array[String] {
  let out : Array[String] = []
  for _ in 0..<n {
    out.push(s)
  }
  out
}
