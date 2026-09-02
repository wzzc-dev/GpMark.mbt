///|
/// 活行内转换（velotype 的 inline marker 引擎语义）：
/// 键入的字面 `**x**` / `` `x` `` / `~~x~~` / `[t](u)` 在触发字符落定后
/// 原地变成样式 run。原理：把当前 run 数组序列化回源码（inline_src），
/// 再 parse_inline 回来——依赖 parse→serialize→parse 的幂等性，
/// Cmd+B 等 toggle 出的样式在往返中不丢失；字面标记文本则被解析成样式。
/// 光标偏移通过「plain → 源码」映射表重映射。
fn clen(s : String) -> Int {
  s.to_array().length()
}

///|
fn run_open(m : Marks) -> Int {
  let mut n = 0
  if m.code {
    n = n + 1
  }
  if m.italic {
    n = n + 1
  }
  if m.bold {
    n = n + 2
  }
  if m.strike {
    n = n + 2
  }
  n
}

///|
/// 构造 plain 偏移 → 源码偏移 的映射表（长度 = plain 字符数 + 1）。
/// Run 的光标点落在「开标记之后」的字符边界上；Link 的 url 区不贡献
/// plain 字符，其后的光标统一吸附到链接右缘。
pub fn src_offset_map(ns : Array[Inline]) -> Array[Int] {
  let out : Array[Int] = []
  let mut src = 0
  for n in ns {
    match n {
      Run(s, m) => {
        let o = run_open(m)
        let cs = clen(s)
        for j = 0; j < cs; j = j + 1 {
          out.push(src + o + j)
        }
        src = src + o + cs + o
      }
      Link(url, inner) => {
        let sub = src_offset_map(inner)
        let m1 = sub.length() - 1
        for k = 0; k < m1; k = k + 1 {
          out.push(src + 1 + sub[k])
        }
        src = src + 1 + clen(inline_src(inner)) + 3 + clen(url) + 1
        let _ = m1
      }
      Image(alt, url) => {
        let s = "![" + alt + "](" + url + ")"
        let cs = clen(s)
        for j = 0; j < cs; j = j + 1 {
          out.push(src + j)
        }
        src = src + cs
      }
      Footnote(nm) => {
        let s = "[^" + nm + "]"
        let cs = clen(s)
        for j = 0; j < cs; j = j + 1 {
          out.push(src + j)
        }
        src = src + cs
      }
    }
  }
  out.push(src)
  out
}

///|
/// 对一组 run 做原地活转换：源码重解析后若不同则返回新 run + 新光标偏移。
/// 返回 (inlines, offset, changed)。
/// 精确性契约：光标在单元末尾（键入触发的主流程）时偏移必精确；
/// 光标落在字面标记文本内部时前缀可能不闭合，仅做长度钳制（无害近似，
/// velotype 同样只在键入字符后触发，不存在该场景的精确语义）。
pub fn reparse_inlines(
  ns : Array[Inline],
  off : Int,
) -> (Array[Inline], Int, Bool) {
  let cur = normalize_inlines(ns)
  let src = inline_src(cur)
  let parsed = normalize_inlines(parse_inline(src))
  if parsed == cur {
    return (cur, off, false)
  }
  let map = src_offset_map(cur)
  let plen = clen(inlines_plain(cur))
  let oc = if off < 0 { 0 } else if off > map.length() - 1 { plen } else { off }
  let so = map[oc]
  let scs = src.to_array()
  let cut = if so > scs.length() { scs.length() } else { so }
  let pre = String::from_array(scs[0:cut])
  let mut no = clen(inlines_plain(normalize_inlines(parse_inline(pre))))
  let nlen = clen(inlines_plain(parsed))
  if no > nlen {
    no = nlen
  }
  (parsed, no, true)
}

///|
/// 触发字符集：这些字符落定后跑一次当前单元的活转换（velotype 同款触发集）。
pub fn reparse_trigger(t : String) -> Bool {
  let mut hit = false
  for c in t.to_array() {
    if c == '*' || c == '`' || c == '~' || c == ')' || c == ' ' || c == '_' {
      hit = true
    }
  }
  hit
}
