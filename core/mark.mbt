///|
/// 行内文本样式（标记集）。纯逻辑类型，零依赖。
pub(all) struct Marks {
  bold : Bool
  italic : Bool
  strike : Bool
  code : Bool
} derive(Eq, Debug, Default)

///|
pub fn Marks::is_plain(self : Marks) -> Bool {
  !self.bold && !self.italic && !self.strike && !self.code
}

///|
/// 合并两个标记集（按位或）。
pub fn Marks::union(self : Marks, other : Marks) -> Marks {
  {
    bold: self.bold || other.bold,
    italic: self.italic || other.italic,
    strike: self.strike || other.strike,
    code: self.code || other.code,
  }
}
