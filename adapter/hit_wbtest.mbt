/// 命中测试逻辑测试（不触 FFI：几何用假探针注入）。

///|
/// key 尾两段数字（unit, ti）：键形如 "probe:r{gen}:{unit}:{ti}"，
/// 手工从右向左数冒号解析，契约见 render.probe_part_key。
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
/// 假 metrics：恒 None（无已绘布局）→ 全走线性插值回退路径，钉住旧行为。
fn no_metrics(_k : String, _x : Float, _y : Float) -> Int? { None }

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
  // 超宽段落：行级合并后单元 0 有多个探针段（每行一段），够断言插值
  let mut long : String = ""
  for i = 0; i < 30; i = i + 1 {
    long = long + "The quick brown fox "
  }
  let us = hit_render(long + "\n\n第二段文字\n")
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
    caret_at_point(145, 60, 0, us.length(), us, fake_probe, no_metrics),
    0,
    expect1,
    "token 中点插值",
  )
  // 远右 → 行尾（单元长度）；越左 → 行首 0
  expect_hit(
    caret_at_point(999999, 60, 0, us.length(), us, fake_probe, no_metrics),
    0,
    ulen0,
    "行右外",
  )
  expect_hit(
    caret_at_point(0, 60, 0, us.length(), us, fake_probe, no_metrics),
    0,
    0,
    "行左外",
  )
  // 第二单元行（y=74..98）；vy 远在版面下方（>一行量级）→ 空白不落点；
  // 行缝近旁（y=49，距首行 1px）仍吸附到首行。
  expect_hit(
    caret_at_point(999999, 86, 0, us.length(), us, fake_probe, no_metrics),
    1,
    ulen1,
    "第二单元行",
  )
  assert_true(
    caret_at_point(105, 5000, 0, us.length(), us, fake_probe, no_metrics).is_none(),
  )
  // 行缝近旁（y=49，距首行 1px）吸附首行；x=105 在首 token（30px 宽、
  // span=starts[1]-starts[0]）的 1/6 处，按比例插值。
  let span0 = starts[1] - starts[0]
  let near_off =
    starts[0] +
      (((5.0 : Float) / 30.0) * span0.to_float() + 0.5).floor().to_int()
  expect_hit(
    caret_at_point(105, 49, 0, us.length(), us, fake_probe, no_metrics),
    0,
    near_off,
    "行缝近旁吸附",
  )
  // 窗口裁剪：只给第 0 单元的几何区间，命中不得跑到第 1 单元
  expect_hit(
    caret_at_point(999999, 86, 0, 1, us, fake_probe, no_metrics),
    0,
    ulen0,
    "窗口外单元不可命中",
  )
  // 无任何当帧几何（未 paint）→ None
  let nothing = fn(_k : String) -> (Float, Float, Float, Float)? { None }
  assert_true(caret_at_point(200, 60, 0, us.length(), us, nothing, no_metrics).is_none())
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
  let needle = @utf8.encode("probe:r")
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

///|
/// 字节流里找 UTF-8 序列（负向断言用）。
fn bytes_contain(bytes : Bytes, needle : Bytes) -> Bool {
  let mut i = 0
  while i + needle.length() <= bytes.length() {
    let mut eq = true
    let mut j = 0
    while j < needle.length() {
      if bytes[i + j] != needle[j] {
        eq = false
        j = needle.length()
      } else {
        j = j + 1
      }
    }
    if eq {
      return true
    }
    i = i + 1
  }
  false
}

///|
test "代码块：探针段按行注册，点击映到行/列" {
  let us = hit_render("```rust\nfn main() {\n  let x = 42;\n}\n```\n")
  assert_eq(us.length(), 1)
  let ulen = us[0].plain.to_array().length()
  assert_eq(ulen, 27) // "fn main() {\n  let x = 42;\n}"
  // 每硬行一段（行首 0/12/26）+ 末位单元长哨兵
  let starts = tok_starts_of(0)
  assert_eq(starts, [0, 12, 26, 27])
  // 行 2 段（ti=1，x=130..160）中点：span=14，线性插值 → 12+7=19
  expect_hit(
    caret_at_point(145, 60, 0, us.length(), us, fake_probe, no_metrics),
    0,
    19,
    "代码行中点插值",
  )
  // 末行尾区（ti=3）：远右点击 → 单元尾
  expect_hit(
    caret_at_point(999999, 60, 0, us.length(), us, fake_probe, no_metrics),
    0,
    ulen,
    "代码块尾区",
  )
  // 越左 → 行首
  expect_hit(
    caret_at_point(0, 60, 0, us.length(), us, fake_probe, no_metrics),
    0,
    0,
    "代码块行左外",
  )
}

///|
test "代码块光标不劈行：▏ 不进文本流，行声明承载光标" {
  // 光标在行 1 中部（offset=16）：探针段仍是每行一段（光标由桥层
  // 在 paint 期按真实布局画 quad，见 declare_row → OP_SET_TEXT_ROW），
  // 不再为光标把行劈成两段。
  let bs = @core.parse_doc("```rust\nfn main() {\n  let x = 42;\n}\n```\n")
  let cb = @gpui.CommandBuffer::new()
  cb.div()
  render_doc(
    cb,
    bs,
    @core.collapsed_sel(@core.Caret::{ unit: 0, offset: 16 }),
    fn(_) { 1 },
    fn(_) { 2 },
    fn(_, _) { 3 },
  )
  // ▏ = U+258F = E2 96 8F（历史实现曾以字符段画光标，会把后面的字推走）
  let glyph : Bytes = b"\xe2\x96\x8f"
  assert_false(bytes_contain(cb.to_bytes(), glyph))
  // 不劈行：starts 与无光标时一致 = 每硬行行首 + 末位单元长哨兵
  assert_eq(tok_starts_of(0), [0, 12, 26, 27])
}

///|
test "命中：metrics 精确通道（注入假布局）" {
  let us = hit_render("```rust\nfn main() {\n  let x = 42;\n}\n```\n")
  let starts = tok_starts_of(0)
  assert_eq(starts, [0, 12, 26, 27])
  // 假 metrics：记录被查询的 key，恒答复段内字符下标 3。
  let asked : Array[String] = []
  let fake_metrics = fn(k : String, _x : Float, _y : Float) -> Int? {
    asked.push(k)
    Some(3)
  }
  // 行 2 段（ti=1，x=130..160）内 x=145：metrics 答复 3 → 12+3=15。
  // （插值路径会得 12+7=19，见上方代码行中点用例——两者可区分。）
  expect_hit(
    caret_at_point(145, 60, 0, us.length(), us, fake_probe, fake_metrics),
    0,
    15,
    "metrics 精确落点",
  )
  assert_eq(asked.length(), 1)
  let ks = asked[0].to_array()
  let n = ks.length()
  let ok_key =
    n >= 4 &&
      ks[n - 4] == ':' && ks[n - 3] == '0' && ks[n - 2] == ':' &&
      ks[n - 1] == '1'
  if !ok_key {
    abort("metrics 必须用命中段的探针 key 查询（unit 0 段 1）")
  }
  // 答复越界钳到区间：99 → 段右端 26；-5 → 段左端 12。
  let big = fn(_k : String, _x : Float, _y : Float) -> Int? { Some(99) }
  expect_hit(
    caret_at_point(145, 60, 0, us.length(), us, fake_probe, big),
    0,
    26,
    "metrics 越右钳段尾",
  )
  let neg = fn(_k : String, _x : Float, _y : Float) -> Int? { Some(-5) }
  expect_hit(
    caret_at_point(145, 60, 0, us.length(), us, fake_probe, neg),
    0,
    12,
    "metrics 越左钳段首",
  )
  // 行尾空白区（is_tail）不问 metrics：末行尾区 ti=3（x=190..220）中点
  // 点击 = 单元尾，且 metrics 调用次数不变。
  expect_hit(
    caret_at_point(205, 60, 0, us.length(), us, fake_probe, fake_metrics),
    0,
    27,
    "尾区不查 metrics",
  )
  assert_eq(asked.length(), 1)
}
