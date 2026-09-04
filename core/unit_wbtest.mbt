/// unit_ref_at / total_units 与 collect_units 的等价性锚定：轻量定位必须
/// 给出同样的单元视图与同样的整文档补丁结果。

test "unit_ref_at agrees with collect_units on every unit" {
  let doc =
    "# Title\n\nSome **bold** text with a [link](http://x) and `code`.\n\n> quoted one\n> quoted two\n\n- one\n- two\n- three\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n```moonbit\nfn main() {}\n```\n\n---\n\nlast para\n"
  let bs = doc_ensure(parse_doc(doc))
  let us = collect_units(bs)
  assert_true(us.length() >= 12)
  for ui in 0..<us.length() {
    match unit_ref_at(bs, ui) {
      Some((top, _local, r)) => {
        assert_eq(r.kind, us[ui].kind)
        assert_eq(r.plain, us[ui].plain)
        assert_eq(r.top_index, us[ui].top_index)
        assert_true(top >= 0 && top < bs.length())
        assert_eq((r.set_plain)("ZZZ"), (us[ui].set_plain)("ZZZ"))
        let ni = [Run("Q", Marks::default())]
        assert_eq((r.set_inlines)(ni), (us[ui].set_inlines)(ni))
      }
      None => fail("unit_ref_at lost unit \{ui}")
    }
  }
  assert_true(unit_ref_at(bs, -1).is_none())
  assert_true(unit_ref_at(bs, us.length()).is_none())
  assert_eq(total_units(bs), us.length())
}

///|
test "unit_plain_len matches collect_units plain lengths" {
  let doc = "# H\n\npara one\n\n- item a\n- item b\n\ncode\n"
  let bs = doc_ensure(parse_doc(doc))
  let us = collect_units(bs)
  for ui in 0..<us.length() {
    assert_eq(
      unit_plain_len(bs, ui),
      us[ui].plain.to_array().length(),
    )
  }
  assert_eq(unit_plain_len(bs, us.length()), 0)
}
