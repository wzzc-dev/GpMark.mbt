/// 编辑器状态 + 快照式 undo/redo。所有编辑动作通过 Editor::apply 走一遍，
/// 自动记录撤销点；数据写时复制，快照保存的是块数组引用，成本 O(顶层块数)。

///|
pub(all) struct Snapshot {
  blocks : Array[Block]
  sel : Sel
} derive(Eq, Debug)

///|
const UNDO_LIMIT : Int = 200

///|
pub(all) struct Editor {
  mut blocks : Array[Block]
  mut sel : Sel
  mut undo_stack : Array[Snapshot]
  mut redo_stack : Array[Snapshot]
  // 「合并窗口」键：连续同键 apply_text 只压一次快照（velotype
  // CoalescibleText 语义）。结构操作 / undo / redo / set_sel 之外均重置。
  mut merge_key : String
}

///|
pub fn Editor::new(blocks : Array[Block]) -> Editor {
  let b = doc_ensure(blocks)
  {
    blocks: b,
    sel: collapsed_sel(Caret::{ unit: 0, offset: 0 }),
    undo_stack: [],
    redo_stack: [],
    merge_key: "",
  }
}

///|
/// 应用一个编辑动作（自动记录撤销点、清空重做栈）。
pub fn Editor::apply(
  self : Editor,
  op : (Array[Block], Sel) -> (Array[Block], Sel),
) -> Unit {
  push_bounded(self.undo_stack, { blocks: self.blocks, sel: self.sel })
  self.redo_stack.clear()
  self.merge_key = ""
  let (b, s) = op(self.blocks, self.sel)
  self.blocks = b
  self.sel = s
}

///|
/// 可合并的编辑动作（键入/退格）：`key` 相同则视为同一股连续输入，
/// 只在键变化的那一次压快照——一次 undo 撤销整段连续输入。
pub fn Editor::apply_text(
  self : Editor,
  key : String,
  op : (Array[Block], Sel) -> (Array[Block], Sel),
) -> Unit {
  if key != self.merge_key {
    push_bounded(self.undo_stack, { blocks: self.blocks, sel: self.sel })
    self.redo_stack.clear()
    self.merge_key = key
  } else {
    self.redo_stack.clear()
  }
  let (b, s) = op(self.blocks, self.sel)
  self.blocks = b
  self.sel = s
}

///|
/// 只改选区，不进撤销栈。
pub fn Editor::set_sel(self : Editor, s : Sel) -> Unit {
  self.sel = s
}

///|
pub fn Editor::undo(self : Editor) -> Unit {
  self.merge_key = ""
  match self.undo_stack.pop() {
    None => ()
    Some(snap) => {
      push_bounded(self.redo_stack, { blocks: self.blocks, sel: self.sel })
      self.blocks = snap.blocks
      self.sel = snap.sel
    }
  }
}

///|
pub fn Editor::redo(self : Editor) -> Unit {
  self.merge_key = ""
  match self.redo_stack.pop() {
    None => ()
    Some(snap) => {
      push_bounded(self.undo_stack, { blocks: self.blocks, sel: self.sel })
      self.blocks = snap.blocks
      self.sel = snap.sel
    }
  }
}

///|
pub fn Editor::can_undo(self : Editor) -> Bool {
  self.undo_stack.length() > 0
}

///|
pub fn Editor::can_redo(self : Editor) -> Bool {
  self.redo_stack.length() > 0
}

///|
fn push_bounded(stack : Array[Snapshot], item : Snapshot) -> Unit {
  stack.push(item)
  if stack.length() > UNDO_LIMIT {
    // 丢弃最旧的一个
    let _ = stack.remove(0)
  }
}
