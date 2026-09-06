/// 鼠标坐标命中测试：窗口像素坐标 → 插入点 (unit, offset)。
///
/// 渲染层给每个探针段 / 行尾空白区 div 挂探针 key（render.mbt），gpui-sys
/// 在 paint 时记录其真实布局矩形，这里经 gpui_probe_rect 拉回并按行/列映
/// 射为光标位置。与点击定位同源（都读同一份探针段布局），拖拽光标不会和
/// 点击光标互相矛盾；用真实布局矩形而非高度/宽度估算，落点精确。
///
/// 本文件是 adapter 里放鼠标/探针 extern 声明的位置（render.mbt 契约：不
/// 做任何 FFI 调用）；符号由 gpui-sys 静态库提供，可执行文件链接时解析，
/// 与 bindings.mbt 其余 @gpui extern 同一形态（moon test 容忍未定义符号）。

///|
#borrow(buf, out)
extern "c" fn gpui_probe_rect_ffi(buf : Bytes, len : Int, out : Bytes) -> Int = "gpui_probe_rect"

///|
fn le_i32(bs : Bytes, i : Int) -> Int {
  let v = (bs[i].to_int() & 0xff) |
    ((bs[i + 1].to_int() & 0xff) << 8) |
    ((bs[i + 2].to_int() & 0xff) << 16) |
    ((bs[i + 3].to_int() & 0xff) << 24)
  if v >= 1 << 31 {
    v - (1 << 32)
  } else {
    v
  }
}

///|
/// 探针 key 的当帧布局矩形 (x, y, w, h)，窗口坐标、取整像素。
/// None = 该 key 本帧没有绘制（窗口外 / 未渲染）。
pub fn probe_rect(key : String) -> (Float, Float, Float, Float)? {
  let bs = @utf8.encode(key)
  let out = Bytes::make(16, b'\x00')
  if gpui_probe_rect_ffi(bs, bs.length(), out) == 0 {
    Some(
      (
        le_i32(out, 0).to_float(),
        le_i32(out, 4).to_float(),
        le_i32(out, 8).to_float(),
        le_i32(out, 12).to_float(),
      ),
    )
  } else {
    None
  }
}

///|
/// 解码桥层 0xEF 鼠标负载 [tag, phase, x i32LE, y i32LE]。
/// phase：0 按下 / 1 拖拽移动 / 2 释放。非鼠标负载返回 None。
pub fn decode_mouse(payload : Bytes) -> (Int, Int, Int)? {
  if payload.length() >= 10 && payload[0] == 0xEF {
    Some((payload[1].to_int() & 0xff, le_i32(payload, 2), le_i32(payload, 6)))
  } else {
    None
  }
}

///|
/// 候选矩形：探针段或行尾空白区。(x, y, x1, y1, unit, lo, hi, key, is_tail)——
/// [lo, hi] 是该矩形水平覆盖的可寻字符偏移闭区间；key 是行声明（text-row
/// ABI）的探针 key，is_tail 标记行尾空白区（无行内布局，命中即单元尾）。
type Hit = (Float, Float, Float, Float, Int, Int, Int, String, Bool)

///|
/// 行内 metrics 查询：探针 key + 窗口坐标 → 段内字符下标（text-row ABI 的
/// gpui_text_char_for_position，最近字符边界语义：点在字符左半 → 边界在其
/// 前，右半 → 其后，与光标 quad 的 position_for_index 同源一致）。
/// None = 本帧没有该行的已绘布局（headless /
/// 未 paint / 窗口外），调用方回退线性插值。
type RowMetrics = (String, Float, Float) -> Int?

///|
/// 窗口坐标 (vx, vy) → 插入点。单元区间 [u0, u1) 为当前渲染窗口对应的
/// 编辑单元范围；probe 注入几何查询（生产用 probe_rect，测试用假几何）；
/// metrics 注入行内逐字符查询（生产用 @gpui.text_char_for_position，测试
/// 用假函数）。行内优先走 metrics（真实布局、比例字体精确），无数据时回退
/// 段宽线性插值。当帧无任何几何（未 paint）时返回 None。
pub fn caret_at_point(
  vx : Int,
  vy : Int,
  u0 : Int,
  u1 : Int,
  us : Array[@core.UnitRef],
  probe : (String) -> (Float, Float, Float, Float)?,
  metrics : RowMetrics,
) -> @core.Caret? {
  let vxf = vx.to_float()
  let vyf = vy.to_float()
  let hits : Array[Hit] = []
  let mut u = if u0 < 0 { 0 } else { u0 }
  let uend = if u1 > us.length() { us.length() } else { u1 }
  while u < uend {
    let starts = tok_starts_of(u)
    if starts.length() > 0 {
      let ntok = starts.length() - 1
      let ulen = us[u].plain.to_array().length()
      let mut ti = 0
      while ti <= ntok {
        let is_tail = ti >= ntok
        let key = if is_tail {
          probe_tail_key(u, ti)
        } else {
          probe_part_key(u, ti)
        }
        match probe(key) {
          Some((x, y, w, h)) => {
            let lo = starts[ti]
            let hi = if is_tail { ulen } else { starts[ti + 1] }
            hits.push(
              (x, y, x + w, y + h, u, lo, if hi > lo { hi } else { lo }, key, is_tail),
            )
          }
          None => ()
        }
        ti = ti + 1
      }
    }
    u = u + 1
  }
  if hits.length() == 0 {
    return None
  }
  // 行：优先取垂直包含 vy 的矩形；都不包含则取垂直距离最近的（行缝、
  // 段落间隙里的拖拽也吸附到邻行，行为与主流编辑器一致）。
  let mut best = 0
  let mut best_d : Float = 1000000000000000.0
  for i = 0; i < hits.length(); i = i + 1 {
    let h = hits[i]
    let d : Float = if vyf >= h.1 && vyf <= h.3 {
      -1.0
    } else if vyf < h.1 {
      h.1 - vyf
    } else {
      vyf - h.3
    }
    if d < best_d {
      best = i
      best_d = d
    }
  }
  let row = hits[best]
  if best_d > 20.0 {
    // 距任何一行都超过一行的量级（顶栏、段落间大空白）：视为点空白，
    // 不动光标——主流编辑器同样不在远处空白落点。
    return None
  }
  // 同一行 = y 起点一致（同行各 token 由同一 row div 布局，矩形等高）；
  // 行内取「左缘 ≤ vx 中最靠右」的矩形，vx 在行首之前则取行首矩形。
  let mut pi = -1
  let mut li = best
  for i = 0; i < hits.length(); i = i + 1 {
    let h = hits[i]
    if (h.1 - row.1).abs() >= 1.0 {
      continue
    }
    if h.0 < hits[li].0 {
      li = i
    }
    if h.0 <= vxf && (pi < 0 || h.0 > hits[pi].0) {
      pi = i
    }
  }
  let pick = if pi >= 0 { hits[pi] } else { hits[li] }
  // 段内落点：行尾空白区 = 区间右端；文本段优先问真实布局（逐字符精确，
  // gpui 最近字符语义含"文字右侧 = 行尾"），metrics 无数据回退段宽线性插值。
  let off = if pick.8 || vxf >= pick.2 {
    pick.6
  } else {
    match metrics(pick.7, vxf, vyf) {
      Some(idx) => {
        let mut o = pick.5 + idx
        if o > pick.6 {
          o = pick.6
        }
        if o < pick.5 {
          o = pick.5
        }
        o
      }
      None => {
        // 区间内按水平比例插值到 [lo, hi]；零宽矩形无从插值，取右端。
        let span = (pick.6 - pick.5).to_float()
        let w = pick.2 - pick.0
        if w <= 0.0 {
          pick.6
        } else {
          let frac = (vxf - pick.0) / w
          let k = (frac * span + 0.5).floor().to_int()
          pick.5 + k
        }
      }
    }
  }
  let mut o = off
  if o < pick.5 {
    o = pick.5
  }
  if o > pick.6 {
    o = pick.6
  }
  Some(@core.Caret::{ unit: pick.4, offset: o })
}
