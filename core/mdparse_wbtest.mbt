///|
/// 解析 / 序列化 / round-trip 幂等测试。
fn p(src : String) -> Array[Block] {
  parse_doc(src)
}

///|
fn w(bs : Array[Block]) -> String {
  serialize_doc(bs)
}

///|
fn _plain(b : Block) -> String {
  block_plain(b)
}

///|
test "标题 1-6 解析与序列化" {
  let bs = p("# H1\n\n### H3\n")
  assert_eq(bs.length(), 2)
  assert_eq(bs[0], Heading(1, [Run("H1", Marks::default())]))
  assert_eq(bs[1], Heading(3, [Run("H3", Marks::default())]))
  assert_eq(w(bs), "# H1\n\n### H3\n")
  // 同级标题转回段落的判据依赖此结构
  assert_eq(parse_doc(w(bs)), bs)
}

///|
test "段落与行内样式解析" {
  let bs = p("Hello **world** and *em* and `code` and ~~gone~~\n")
  assert_eq(bs.length(), 1)
  match bs[0] {
    Paragraph(ns) =>
      assert_eq(ns, [
        Run("Hello ", Marks::default()),
        Run("world", Marks::{
          bold: true,
          italic: false,
          strike: false,
          code: false,
        }),
        Run(" and ", Marks::default()),
        Run("em", Marks::{
          bold: false,
          italic: true,
          strike: false,
          code: false,
        }),
        Run(" and ", Marks::default()),
        Run("code", Marks::{
          bold: false,
          italic: false,
          strike: false,
          code: true,
        }),
        Run(" and ", Marks::default()),
        Run("gone", Marks::{
          bold: false,
          italic: false,
          strike: true,
          code: false,
        }),
      ])
    _ => fail("expect paragraph")
  }
  assert_eq(w(bs), "Hello **world** and *em* and `code` and ~~gone~~\n")
}

///|
test "粗斜体 ***x*** 与链接/图片/脚注" {
  let bs = p("***bi*** see [docs](https://e.org) ![logo](a.png) ref[^1]\n")
  match bs[0] {
    Paragraph(ns) => {
      assert_eq(
        ns[0],
        Run("bi", Marks::{
          bold: true,
          italic: true,
          strike: false,
          code: false,
        }),
      )
      assert_eq(ns[2], Link("https://e.org", [Run("docs", Marks::default())]))
      assert_eq(ns[4], Image("logo", "a.png"))
      assert_eq(ns[6], Footnote("1"))
    }
    _ => fail("expect paragraph")
  }
  assert_eq(parse_doc(w(bs)), bs)
}

///|
test "无序/有序/任务列表（含嵌套）" {
  let src = "- a\n- b\n  - b1\n"
  let bs = p(src)
  assert_eq(bs.length(), 1)
  match bs[0] {
    ListBlock(Bullet, items) => {
      assert_eq(items.length(), 2)
      assert_eq(plain_of_item(items[1]), "bb1")
      assert_eq(items[1].children.length(), 1)
    }
    _ => fail("expect bullet list")
  }
  assert_eq(parse_doc(w(bs)), bs)

  let o = p("1. one\n2. two\n")
  match o[0] {
    ListBlock(Ordered(1), items) => assert_eq(items.length(), 2)
    _ => fail("expect ordered list")
  }
  assert_eq(w(o), "1. one\n2. two\n")

  let t = p("- [x] done\n- [ ] todo\n")
  match t[0] {
    ListBlock(Task, items) => {
      assert_eq(items[0].checked, Some(true))
      assert_eq(items[1].checked, Some(false))
    }
    _ => fail("expect task list")
  }
  assert_eq(w(t), "- [x] done\n- [ ] todo\n")
}

///|
fn plain_of_item(it : Item) -> String {
  let mut s = inlines_plain(it.content)
  for c in it.children {
    s = s + block_plain(c)
  }
  s
}

///|
test "引用（含内嵌块）" {
  let bs = p("> quoted **text**\n> \n> more\n")
  assert_eq(bs.length(), 1)
  match bs[0] {
    Quote(inner) => {
      assert_eq(inner.length(), 2)
      assert_eq(inlines_plain(block_inlines(inner[0])), "quoted text")
    }
    _ => fail("expect quote")
  }
  assert_eq(parse_doc(w(bs)), bs)
}

///|
fn block_inlines(b : Block) -> Array[Inline] {
  match b {
    Heading(_, ns) | Paragraph(ns) => ns
    _ => []
  }
}

///|
test "代码块（带语言标注）" {
  let bs = p("```rust\nfn main() {}\n```\n")
  assert_eq(bs[0], CodeBlock("rust", "fn main() {}"))
  assert_eq(w(bs), "```rust\nfn main() {}\n```\n")
  assert_eq(parse_doc(w(bs)), bs)
}

///|
test "表格" {
  let bs = p("| a | b |\n| --- | --- |\n| 1 | 2 |\n")
  match bs[0] {
    TableBlock(t) => {
      assert_eq(t.rows.length(), 2)
      assert_eq(inlines_plain(t.rows[0][0]), "a")
      assert_eq(inlines_plain(t.rows[1][1]), "2")
      assert_eq(t.has_header, true)
    }
    _ => fail("expect table")
  }
  assert_eq(parse_doc(w(bs)), bs)
}

///|
test "水平线与独立图片" {
  let bs = p("![cover](c.png)\n\n---\n")
  assert_eq(bs[0], ImageBlock("cover", "c.png"))
  assert_eq(bs[1], Hr)
  assert_eq(w(bs), "![cover](c.png)\n\n---\n")
}

///|
test "Raw 回退：HTML 块与未闭合围栏原样保留" {
  let html = p("<div class=\"x\">\nhello\n</div>\n")
  assert_eq(html.length(), 1)
  match html[0] {
    Raw(s) => assert_eq(s, "<div class=\"x\">\nhello\n</div>")
    _ => fail("expect raw html")
  }
  assert_eq(w(html), "<div class=\"x\">\nhello\n</div>\n")
  assert_eq(parse_doc(w(html)), html)

  let fence = p("```\nnot closed\n")
  match fence[0] {
    Raw(s) => assert_eq(s, "```\nnot closed")
    _ => fail("expect raw for unclosed fence")
  }
  assert_eq(parse_doc(w(fence)), fence)
}

///|
test "parse→serialize→parse 在稳定子集上幂等" {
  let docs = [
    "# Title\n\nSome **bold** text with [link](u).\n", "- a\n- b\n  - b1\n", "1. one\n2. two\n",
    "- [x] done\n- [ ] todo\n", "> q1\n> q2\n", "```py\nprint(1)\n```\n", "| h1 | h2 |\n| --- | --- |\n| v1 | v2 |\n",
    "para one\n\npara two\n", "---\n", "text with `code` and ~~strike~~\n", "<span>raw</span>\n",
    "```unclosed\nbody\n",
  ]
  for src in docs {
    let once = p(src)
    let s1 = w(once)
    let twice = p(s1)
    assert_eq(twice, once)
    assert_eq(w(twice), s1)
  }
}

///|
test "整文档综合示例" {
  let src = "# Demo\n\nIntro with **bold**, *em*, `c`, [l](http://x) and ~~s~~.\n\n## Lists\n\n- item\n  - nested\n1. first\n2. second\n- [x] ok\n- [ ] no\n\n> quote **me**\n\n```js\nlet x = 1\n```\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n![img](i.png)\n\n---\n"
  let bs = p(src)
  let out = w(bs)
  assert_eq(p(out), bs)
  assert_eq(w(p(out)), out)
}
