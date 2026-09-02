/// 命中测试逻辑测试（不触 FFI：几何用假探针注入）。

///|
/// key 尾两段数字（unit, ti）：键形如 "probe:t{gen}:{unit}:{ti}"，
/// 手工从右向左数冒号解析，契约见 render.probe_token_key。
fn digits(cs : Array[Char], a : Int, b : Int) -> Int? {
  if a >= b {
    return None
  }
  let mut v = 0
  let mut i = a
  while i < b {
    let d = cs[i].to_int() - '0'.to_int()
    if d < 0 || d > 9 {
      return None
    }
    v = v * 10 + d
    i = i + 1
  }
  Some(v)
}

///|
/// 按 (unit, ti) 合成版面：每单元一行、行高 24px、
/// token 自 x=100 起每个 30px 宽。
fn fake_probe(key : String) -> (Float, Float, Float, Float)? {
  let cs = key.to_array()
  let mut c1 = -1 // 倒数第二个冒号
  let mut c2 = -1 // 最后一个冒号
  let mut ncols = 0
  let mut i = cs.length() - 1
  while i >= 0 {
    if cs[i] == ':' {
      ncols = ncols + 1
      if ncols == 1 {
        c2 = i
      } else if ncols == 2 {
        c1 = i
      }
    }
    i = i - 1
  }
  if ncols != 3 {
    return None
  }
  match (digits(cs, c1 + 1, c2), digits(cs, c2 + 1, cs.length())) {
    (Some(u), Some(ti)) =>
      Some(
        (100.0 + ti.to_float() * 30.0, 50.0 + u.to_float() * 24.0, 30.0, 24.0),
      )
    _ => None
  }
}

///|
fn hit_render(src : String) -> Array[@core.UnitRef] {
  let bs = @core.parse_doc(src)
  let cb = @gpui.CommandBuffer::new()
  cb.div()
  render_doc(
    cb,
    bs,
    @core.collapsed_sel(@core.Caret::{ unit: 0, offset: 0 }),
    fn(_) { 1 },
    fn(_) { 2 },
    fn(_, _) { 3 },
  )
  cb.set_root()
  @core.collect_units(bs)
}

///|
fn expect_hit(
  c : @core.Caret?,
  unit : Int,
  offset : Int,
  what : String,
) -> Unit {
  match c {
    Some(cc) =>
      if cc.unit != unit || cc.offset != offset {
        abort(
          "命中偏差（" +
          what +
          "）：期望 " +
          unit.to_string() +
          ":" +
          offset.to_string() +
          "，实得 " +
          cc.unit.to_string() +
          ":" +
          cc.offset.to_string(),
        )
      }
    None => abort("命中失败（" + what + "）：应命中却无结果")
  }
}

///|
test "命中：行内按比例 / 左右越界 / 跨单元行 / 无几何" {
  let us = hit_render("hello world 你好\n\n第二段文字\n")
  assert_eq(us.length(), 2)
  let ulen0 = us[0].plain.to_array().length()
  let ulen1 = us[1].plain.to_array().length()
  let starts = tok_starts_of(0)
  let ntok = starts.length() - 1
  assert_true(ntok >= 2)
  // 第 1 个 token（x=130..160，span 见 starts）中点：偏移 = 起点 + 半跨
  let span1 = starts[2] - starts[1]
  let expect1 = starts[1] +
    ((0.5 : Float) * span1.to_float() + 0.5).floor().to_int()
  expect_hit(
    caret_at_point(145, 60, 0, us.length(), us, fake_probe),
    0,
    expect1,
    "token 中点插值",
  )
  // 远右 → 行尾（单元长度）；越左 → 行首 0
  expect_hit(
    caret_at_point(999999, 60, 0, us.length(), us, fake_probe),
    0,
    ulen0,
    "行右外",
  )
  expect_hit(
    caret_at_point(0, 60, 0, us.length(), us, fake_probe),
    0,
    0,
    "行左外",
  )
  // 第二单元行（y=74..98）；vy 远在版面下方（>一行量级）→ 空白不落点；
  // 行缝近旁（y=49，距首行 1px）仍吸附到首行。
  expect_hit(
    caret_at_point(999999, 86, 0, us.length(), us, fake_probe),
    1,
    ulen1,
    "第二单元行",
  )
  assert_true(
    caret_at_point(105, 5000, 0, us.length(), us, fake_probe).is_none(),
  )
  // 行缝近旁（y=49，距首行 1px）吸附首行；x=105 在首 token（30px 宽、
  // span=starts[1]-starts[0]）的 1/6 处，按比例插值。
  let span0 = starts[1] - starts[0]
  let near_off =
    starts[0] +
      (((5.0 : Float) / 30.0) * span0.to_float() + 0.5).floor().to_int()
  expect_hit(
    caret_at_point(105, 49, 0, us.length(), us, fake_probe),
    0,
    near_off,
    "行缝近旁吸附",
  )
  // 窗口裁剪：只给第 0 单元的几何区间，命中不得跑到第 1 单元
  expect_hit(
    caret_at_point(999999, 86, 0, 1, us, fake_probe),
    0,
    ulen0,
    "窗口外单元不可命中",
  )
  // 无任何当帧几何（未 paint）→ None
  let nothing = fn(_k : String) -> (Float, Float, Float, Float)? { None }
  assert_true(caret_at_point(200, 60, 0, us.length(), us, nothing).is_none())
}

///|
test "渲染输出携带探针 key" {
  let bs = @core.parse_doc("abc\n")
  let cb = @gpui.CommandBuffer::new()
  cb.div()
  render_doc(
    cb,
    bs,
    @core.collapsed_sel(@core.Caret::{ unit: 0, offset: 0 }),
    fn(_) { 1 },
    fn(_) { 2 },
    fn(_, _) { 3 },
  )
  let bytes = cb.to_bytes()
  let needle = @utf8.encode("probe:t")
  let mut found = false
  let mut i = 0
  while i + needle.length() <= bytes.length() {
    let mut j = 0
    let mut eq = true
    while j < needle.length() {
      if bytes[i + j] != needle[j] {
        eq = false
        j = needle.length()
      } else {
        j = j + 1
      }
    }
    if eq {
      found = true
      i = bytes.length()
    }
    i = i + 1
  }
  assert_true(found)
}
