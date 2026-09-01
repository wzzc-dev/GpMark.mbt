///|
/// undo 合并（apply_text）测试。
fn csel2(unit : Int, offset : Int) -> Sel {
  collapsed_sel(Caret::{ unit, offset })
}

///|
test "连续键入折叠为一次 undo" {
  let ed = Editor::new([Paragraph([])])
  for k = 0; k < 10; k = k + 1 {
      ed.apply_text("t0", fn(b, s) { doc_insert(b, s, "字") })
    assert_true(ed.undo_stack.length() == 1)
  }
  assert_eq(block_plain(ed.blocks[0]), "字字字字字字字字字字")
  ed.undo()
  assert_eq(block_plain(ed.blocks[0]), "")
  ed.redo()
  assert_eq(block_plain(ed.blocks[0]), "字字字字字字字字字字")
}

///|
test "换单元 / 结构操作打断合并窗口" {
  let ed = Editor::new([Paragraph([])])
  ed.apply_text("t0", fn(b, s) { doc_insert(b, s, "ab") })
  ed.apply_text("t1", fn(b, s) { doc_insert(b, s, "cd") })
  assert_true(ed.undo_stack.length() == 2)
  ed.undo()
  assert_eq(block_plain(ed.blocks[0]), "ab")
  // 结构操作（apply）必然新压快照并重置窗口
  ed.apply(fn(b, s) { doc_enter(b, s) })
  ed.apply_text("t1", fn(b, s) { doc_insert(b, s, "e") })
  assert_true(ed.undo_stack.length() == 3)
  ed.undo()
  assert_eq(block_plain(ed.blocks[1]), "")
}
