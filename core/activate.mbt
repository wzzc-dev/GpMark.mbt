/// 延迟 inline 的物化（激活）。打开路径用 parse_doc_deferred 产出
/// plain-Run 形态的叶子内容；渲染窗口内的块在每次重建时激活成真实 run。
/// 激活对已物化块幂等：inline_src → parse_inline 往返不变（reparse.mbt
/// 的 parse→serialize→parse 幂等契约），所以重复调用只付一次解析成本，
/// 不会改变已编辑块的内容。

///|
fn activate_inlines(ns : Array[Inline]) -> Array[Inline] {
  normalize_inlines(parse_inline(inline_src(ns)))
}

///|
fn activate_item(it : Item) -> Item {
  { ..it, content: activate_inlines(it.content) }
}

///|
/// 深度激活一个块的所有叶子 inline。窗口外的块保持延迟形态：
/// plain = 原文，单元数与序列化行为与激活态一致。
pub fn Block::activate(self : Block) -> Block {
  match self {
    Heading(lv, inls) => Heading(lv, activate_inlines(inls))
    Paragraph(inls) => Paragraph(activate_inlines(inls))
    CodeBlock(_, _) | Hr | ImageBlock(_, _) | Raw(_) => self
    Quote(inner) => Quote(inner.map(fn(b) { b.activate() }))
    ListBlock(kind, items) => ListBlock(kind, items.map(activate_item))
    TableBlock(t) =>
      TableBlock(
        Table::{
          rows: t.rows.map(fn(row) {
            row.map(fn(cell) { activate_inlines(cell) })
          }),
          has_header: t.has_header,
        },
      )
  }
}
