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
}

///|
pub fn Editor::new(blocks : Array[Block]) -> Editor {
  let b = doc_ensure(blocks)
  {
    blocks: b,
    sel: collapsed_sel(Caret::{ unit: 0, offset: 0 }),
    undo_stack: [],
    redo_stack: [],
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
