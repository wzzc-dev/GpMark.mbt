///|
/// 分词 / 宽度估算 / 折行的纯逻辑测试。
test "tokenize：CJK 逐字、拉丁词带跟随空格" {
  let toks = tokenize("ab 世界 c".to_array())
  assert_eq(toks.length(), 5)
  assert_eq(toks[0], (0, 3)) // "ab "
  assert_eq(toks[1], (3, 1)) // 世
  assert_eq(toks[2], (4, 1)) // 界
  assert_eq(toks[3], (5, 1)) // " "
  assert_eq(toks[4], (6, 1)) // c
}

///|
test "tokenize：覆盖全部字符且不重叠" {
  let s = "moon编辑器 is nice！ 混合 text123"
  let cs = s.to_array()
  let toks = tokenize(cs)
  assert_true(toks.length() > 0)
  assert_eq(toks[0].0, 0)
  let mut covered = 0
  for t in toks {
    assert_eq(t.0, covered)
    assert_true(t.1 > 0)
    covered = covered + t.1
  }
  assert_eq(covered, cs.length())
}

///|
test "char_w：宽字符显著宽于普通字母" {
  assert_true(char_w('中') > 1.5 * char_w('m'))
  assert_true(char_w('i') < char_w('m'))
  assert_true(char_w('（') > 1.5 * char_w('m'))
}

///|
test "layout：窄可用宽度下贪心折行" {
  // 每个词宽 ≈ "xxxx "(5×0.56em)×15 ≈ 42px；avail=100 → 每行 2 词
  let cs = "xxxx xxxx xxxx xxxx".to_array()
  let lays = layout_text(cs, 15.0, 100.0)
  assert_eq(lays.toks.length(), 4)
  assert_true(lays.rows.length() >= 2)
  for row in lays.rows {
    assert_true(row.length() <= 3)
  }
}

///|
test "layout：超宽 token 按字符切分不溢出" {
  let cs = String::from_array(Array::make(120, 'x')).to_array()
  let lays = layout_text(cs, 15.0, 80.0)
  assert_true(lays.toks.length() > 4)
  for i = 0; i < lays.toks.length(); i = i + 1 {
    assert_true(lays.widths[i] <= 80.5 || lays.toks[i].1 == 1)
  }
}

///|
test "layout：空输入产生空布局" {
  let lays = layout_text("".to_array(), 15.0, 100.0)
  assert_eq(lays.toks.length(), 0)
  assert_eq(lays.rows.length(), 0)
}

///|
test "cell_px：加粗列更宽、内容长列更宽" {
  let a = cell_px("ab".to_array(), 14.0, false)
  let b = cell_px("ab".to_array(), 14.0, true)
  let c = cell_px("abcdefgh".to_array(), 14.0, false)
  assert_true(b > a)
  assert_true(c > b)
}
