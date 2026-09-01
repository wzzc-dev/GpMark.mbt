/// 点击定位用的分词 + 宽度估算 + 手动折行（framework gap §1/§4：click 不带
/// 坐标、无文本度量接口，因此「点哪停哪」只能在 MoonBit 侧自算布局）。
///
/// 规则：CJK/全角字符一字一 token（天然可断行点），拉丁词连同一个跟随空格
/// 为一个 token；宽度按字符类别估算（宽字符 ≈1em，窄字母 ≈0.34em，普通
/// 字母 ≈0.56em），再按估算可用宽度贪心折行。折行结果（token 起点表）写回
/// render 层供点击处理器查询：点击 token = 光标落该 token 起点。

///|
pub type Tok = (Int, Int) // (字符起点, 长度)

/// CJK/全角/宽emoji——断行与宽度估算都用它判定。
pub fn is_wide(c : Char) -> Bool {
  let u = c.to_int()
  (u >= 0x1100 && u <= 0x115F) ||
    (u >= 0x2E80 && u <= 0xA4CF) ||
    (u >= 0xAC00 && u <= 0xD7A3) ||
    (u >= 0xF900 && u <= 0xFAFF) ||
    (u >= 0xFE30 && u <= 0xFE4F) ||
    (u >= 0xFF00 && u <= 0xFF60) ||
    (u >= 0xFFE0 && u <= 0xFFE6) ||
    (u >= 0x1F300 && u <= 0x1FAFF) ||
    (u >= 0x20000 && u <= 0x3FFFD)
}

/// 单字符宽度（em 倍数）。刻意取略宽估计：宁可提前折行，不可折不下溢出。
pub fn char_w(c : Char) -> Float {
  if is_wide(c) {
    1.04
  } else if c == ' ' {
    0.3
  } else if "ijltf.,;:'\"`!|/\\()-[]{}".contains_char(c) {
    0.34
  } else if (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') {
    0.64
  } else {
    0.56
  }
}

pub fn tok_px(cs : Array[Char], s : Int, len : Int, size : Float) -> Float {
  let mut w : Float = 0.0
  let mut j = 0
  while j < len {
    w = w + char_w(cs[s + j])
    j = j + 1
  }
  w * size
}

///|
/// 文本 → token 序列：宽字符逐字；拉丁词（含至多一个跟随空格）一词；
/// 独立空格串一词。拼接后恰好覆盖全部字符。
pub fn tokenize(cs : Array[Char]) -> Array[Tok] {
  let out : Array[Tok] = []
  let len = cs.length()
  let mut i = 0
  while i < len {
    let c = cs[i]
    if is_wide(c) {
      out.push((i, 1))
      i = i + 1
    } else if c == ' ' {
      let mut j = i + 1
      while j < len && cs[j] == ' ' {
        j = j + 1
      }
      out.push((i, j - i))
      i = j
    } else {
      let mut j = i + 1
      while j < len && !is_wide(cs[j]) && cs[j] != ' ' {
        j = j + 1
      }
      if j < len && cs[j] == ' ' {
        j = j + 1
      }
      out.push((i, j - i))
      i = j
    }
  }
  out
}

///|
pub struct Layout {
  toks : Array[Tok]
  widths : Array[Float]
  rows : Array[Array[Int]] // 每行的 token 下标
}

///|
/// 分词 + 宽度 + 贪心折行。超宽 token（长 URL/长词）先按字符切成子 token，
/// 保证不溢出行框。空输入 → 空 toks / 空 rows。
pub fn layout_text(cs : Array[Char], size : Float, avail : Float) -> Layout {
  let toks : Array[Tok] = []
  let widths : Array[Float] = []
  for t in tokenize(cs) {
    let w = tok_px(cs, t.0, t.1, size)
    if w <= avail || t.1 <= 1 {
      toks.push(t)
      widths.push(w)
    } else {
      let mut s = t.0
      let mut left = t.1
      while left > 0 {
        let mut k = 1
        let mut wacc = char_w(cs[s]) * size
        while k < left {
          let cw = char_w(cs[s + k]) * size
          if wacc + cw > avail {
            break
          }
          wacc = wacc + cw
          k = k + 1
        }
        toks.push((s, k))
        widths.push(wacc)
        s = s + k
        left = left - k
      }
    }
  }
  let rows : Array[Array[Int]] = []
  let mut row : Array[Int] = []
  let mut rw : Float = 0.0
  let mut i = 0
  while i < widths.length() {
    if row.length() > 0 && rw + widths[i] > avail {
      rows.push(row)
      row = []
      rw = 0.0
    }
    row.push(i)
    rw = rw + widths[i]
    i = i + 1
  }
  if row.length() > 0 {
    rows.push(row)
  }
  { toks, widths, rows }
}

/// 单元格/列宽估算：内容显示宽度（px）+ 水平内边距。
pub fn cell_px(cs : Array[Char], size : Float, bold : Bool) -> Float {
  let mut u : Float = 0.0
  for c in cs {
    u = u + char_w(c)
  }
  let f : Float = if bold { 1.07 } else { 1.0 }
  u * size * f + 24.0
}
