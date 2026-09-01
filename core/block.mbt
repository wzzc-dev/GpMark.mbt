/// 块树模型（velotype 式运行时表示）。纯逻辑类型。

///|
pub(all) enum ListKind {
  Bullet
  Ordered(Int) // 起始编号
  Task
} derive(Eq, Debug)

///|
pub(all) struct Item {
  checked : Bool? // 仅 Task 使用
  content : Array[Inline]
  children : Array[Block] // 嵌套内容（通常是嵌套列表）
} derive(Eq, Debug)

///|
pub(all) struct Table {
  rows : Array[Array[Array[Inline]]] // 每行 = 若干单元格；每格 = 一组 run
  has_header : Bool // 第一行是表头
} derive(Eq, Debug)

///|
pub(all) enum Block {
  Heading(Int, Array[Inline]) // level 1..6
  Paragraph(Array[Inline])
  CodeBlock(String, String) // (lang, code)
  Quote(Array[Block])
  ListBlock(ListKind, Array[Item])
  TableBlock(Table)
  ImageBlock(String, String) // (alt, url) 独立成块的图片
  Hr
  Raw(String) // 不稳定语法的源文回退：原样保留、原样导出
} derive(Eq, Debug)

///|
/// 块的纯文本表示（调试与尺寸计算用）。
pub fn block_plain(b : Block) -> String {
  match b {
    Heading(_, inls) | Paragraph(inls) => inlines_plain(inls)
    CodeBlock(_, code) => code
    Quote(inner) => concat_plain(inner.map(block_plain))
    ListBlock(_, items) =>
      concat_plain(
        items.map(it => {
          inlines_plain(it.content) + concat_plain(it.children.map(block_plain))
        }),
      )
    TableBlock(t) =>
      concat_plain(
        t.rows.map(row => {
          concat_plain(row.map(cell => inlines_plain(cell))) + "\n"
        }),
      )
    ImageBlock(alt, url) => "![" + alt + "](" + url + ")"
    Hr => "---"
    Raw(s) => s
  }
}

///|
/// 是否是整块原子（无内部可编辑文本）：水平线、独立图片、源文回退。
pub fn block_is_atomic(b : Block) -> Bool {
  match b {
    Hr | ImageBlock(_, _) | Raw(_) => true
    _ => false
  }
}

///|
fn concat_plain(xs : Array[String]) -> String {
  xs.join("")
}
