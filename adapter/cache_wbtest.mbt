/// 高度/单元前缀和缓存的增量正确性：bump 后按块指纹复用未变块的估高，
/// 输出必须与全量重算逐元素一致；compute_window 二分必须与线性扫描一致；
/// bump_sel 不作废缓存。

///|
fn oracle_cum(blocks : Array[@core.Block]) -> Array[Float] {
  // 全量重算参照（与本文件改造前的 ensure_height_cache 同一实现）。
  let cum : Array[Float] = [0.0]
  let mut h : Float = 0.0
  for i = 0; i < blocks.length(); i = i + 1 {
    if i > 0 {
      h = h + 6.0
    }
    h = h + estimate_slot_height(blocks[i], base_avail)
    cum.push(h)
  }
  cum
}

///|
fn oracle_units(blocks : Array[@core.Block]) -> Array[Int] {
  let units : Array[Int] = [0]
  let mut u = 0
  for b in blocks {
    u = u + count_units_of(b)
    units.push(u)
  }
  units
}

///|
fn window_linear(y : Float) -> (Int, Int) {
  // 二分化之前的线性扫描参照。
  let n = ed.blocks.length()
  let cum = cache_cum.val
  let top = y - WINDOW_PAD
  let bottom = y + viewport_h.val + WINDOW_PAD
  let mut lo = 0
  while lo < n && cum[lo + 1] <= top {
    lo = lo + 1
  }
  let mut hi = lo
  while hi < n && cum[hi] < bottom {
    hi = hi + 1
  }
  (lo, hi)
}

///|
let cache_doc : String = [
  "# Alpha",
  "",
  "First paragraph with some **bold** text that spans a reasonable width so",
  "the wrap estimate is sensitive to added characters.",
  "",
  "> a quoted paragraph",
  "> second quoted line",
  "",
  "- list item one",
  "- list item two",
  "",
  "| col a | col b |",
  "| --- | --- |",
  "| 1 | 2 |",
  "",
  "```moonbit",
  "fn main() { println(\"hi\") }",
  "```",
  "",
  "Second paragraph body.",
  "",
  "Tail paragraph.",
].join("\n")

///|
fn assert_cum_matches_oracle() -> Unit raise {
  let oracle = oracle_cum(ed.blocks)
  assert_eq(cache_cum.val.length(), oracle.length())
  for i in 0..<oracle.length() {
    assert_eq(cache_cum.val[i], oracle[i])
  }
  let ou = oracle_units(ed.blocks)
  assert_eq(cache_units.val.length(), ou.length())
  for i in 0..<ou.length() {
    assert_eq(cache_units.val[i], ou[i])
  }
}

test "height cache: keystroke reuse matches full recompute" {
  load(cache_doc)
  ensure_height_cache()
  assert_eq(cache_fp.val.length(), ed.blocks.length())
  let before = cache_heights.val
  ed.apply(fn(b, s) { @core.doc_insert(b, s, " typed text here") })
  bump()
  assert_false(cache_valid.val)
  ensure_height_cache()
  // 块数没变：除被编辑的块外，未变块的估高原样复用。
  assert_eq(cache_heights.val.length(), before.length())
  for i in 1..<before.length() {
    assert_eq(cache_heights.val[i], before[i])
  }
  assert_cum_matches_oracle()
}

///|
test "height cache: structural edit recompute matches oracle" {
  load(cache_doc)
  ensure_height_cache()
  // 在段落中段换行：顶层块数 +1，触发全量对齐重算，仍须与 oracle 一致。
  let n0 = ed.blocks.length()
  ed.sel = @core.collapsed_sel(@core.Caret::{ unit: 1, offset: 5 })
  assert_true(@core.total_units(ed.blocks) > 1)
  ed.apply(fn(b, s) { @core.doc_enter(b, s) })
  assert_true(ed.blocks.length() == n0 + 1)
  bump()
  ensure_height_cache()
  assert_cum_matches_oracle()
}

///|
test "height cache: undo back to old content matches oracle" {
  load(cache_doc)
  ensure_height_cache()
  ed.apply_text("k1", fn(b, s) { @core.doc_insert(b, s, "appended tail text") })
  bump()
  ensure_height_cache()
  ed.undo()
  bump()
  ensure_height_cache()
  assert_cum_matches_oracle()
}

///|
test "bump_sel keeps height cache valid, bumps rev" {
  load(cache_doc)
  ensure_height_cache()
  let rev0 = rev.get(store)
  bump_sel()
  assert_true(cache_valid.val)
  assert_eq(rev.get(store), rev0 + 1)
}

///|
test "compute_window binary search matches linear scan" {
  load(cache_doc)
  ensure_height_cache()
  let total = cache_cum.val[ed.blocks.length()]
  assert_true(total > 0.0)
  for k in 0..=20 {
    let y = total * (k.to_float() / 20.0)
    assert_eq(compute_window(y), window_linear(y))
  }
  // 窗口越界（文档尽头之外）也须一致。
  assert_eq(compute_window(total + 5000.0), window_linear(total + 5000.0))
}
