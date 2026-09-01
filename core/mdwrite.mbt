/// 块树 → 规范化 Markdown 文本。与 mdparse 一起保证稳定子集上
/// parse → write → parse 的幂等性。

///|
pub fn serialize_doc(blocks : Array[Block]) -> String {
  let mut out = ""
  let mut first = true
  for b in blocks {
    if first {
      out = serialize_block(b)
      first = false
    } else {
      out = out + "\n\n" + serialize_block(b)
    }
  }
  if out == "" {
    out
  } else {
    out + "\n"
  }
}

///|
pub fn serialize_block(b : Block) -> String {
  match b {
    Heading(l, inls) => repeat_str("#", l) + " " + inline_src(inls)
    Paragraph(inls) => inline_src(inls)
    CodeBlock(lang, code) =>
      if code == "" {
        "```" + lang + "\n```"
      } else {
        "```" + lang + "\n" + code + "\n```"
      }
    Quote(inner) =>
      prefix_lines(trim_trailing_newline(serialize_doc(inner)), ">")
    ListBlock(kind, items) => {
      let mut out = ""
      let mut idx = 0
      for it in items {
        let marker = match kind {
          Bullet => "- "
          Task =>
            match it.checked {
              Some(true) => "- [x] "
              _ => "- [ ] "
            }
          Ordered(s0) => (s0 + idx).to_string() + ". "
        }
        let mut item_src = marker + inline_src(it.content)
        if it.children.length() > 0 {
          item_src = item_src +
            "\n" +
            prefix_lines(
              trim_trailing_newline(serialize_doc(it.children)),
              "  ",
            )
        }
        out = if out == "" { item_src } else { out + "\n" + item_src }
        idx = idx + 1
      }
      out
    }
    TableBlock(t) => {
      let cols = if t.rows.length() > 0 { t.rows[0].length() } else { 0 }
      let sep = "| " + join_cells_str(repeat_arr_str("---", cols)) + " |"
      let mut out = ""
      let mut ri = 0
      for row in t.rows {
        let parts : Array[String] = []
        for cell in row {
          parts.push(inline_src(cell))
        }
        let line = "| " + join_cells_str(parts) + " |"
        out = if ri == 0 { line + "\n" + sep } else { out + "\n" + line }
        ri = ri + 1
      }
      out
    }
    ImageBlock(alt, url) => "![" + alt + "](" + url + ")"
    Hr => "---"
    Raw(s) => s
  }
}

///|
fn trim_trailing_newline(s : String) -> String {
  if ends_with_str(s, "\n") {
    s.substring(end=s.length() - 1)
  } else {
    s
  }
}

///|
fn prefix_lines(s : String, prefix : String) -> String {
  let parts : Array[String] = []
  for line in split_lines_str(s) {
    if line == "" && prefix != "" {
      parts.push(trim_trailing_ws(prefix))
    } else {
      parts.push(prefix + line)
    }
  }
  join_lines_str(parts)
}

///|
fn trim_trailing_ws(s : String) -> String {
  let cs = s.to_array()
  let mut n = cs.length()
  while n > 0 && cs[n - 1] == ' ' {
    n = n - 1
  }
  String::from_array(cs[0:n])
}

///|
pub fn inline_src(ns : Array[Inline]) -> String {
  let mut out = ""
  for n in ns {
    out = out + inline1_src(n)
  }
  out
}

///|
fn inline1_src(n : Inline) -> String {
  match n {
    Run(s, m) => {
      let t = if m.code { "`" + s + "`" } else { s }
      let t = if m.italic { "*" + t + "*" } else { t }
      let t = if m.bold { "**" + t + "**" } else { t }
      let t = if m.strike { "~~" + t + "~~" } else { t }
      t
    }
    Link(url, inner) => "[" + inline_src(inner) + "](" + url + ")"
    Image(alt, url) => "![" + alt + "](" + url + ")"
    Footnote(nm) => "[^" + nm + "]"
  }
}
