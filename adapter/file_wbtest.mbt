/// 打开/保存文件（Cmd+O 路径栏状态机 + open_path/save_current_file）
/// 的纯逻辑单测。fs 调用走真实文件系统（临时文件在 /tmp），不触 FFI。

fn bytes_has(hay : Bytes, needle : String) -> Bool {
  let n = @utf8.encode(needle)
  let hl = hay.length() - n.length()
  let mut i = 0
  while i <= hl {
    let mut j = 0
    while j < n.length() && hay[i + j] == n[j] {
      j = j + 1
    }
    if j == n.length() {
      return true
    }
    i = i + 1
  }
  false
}

///|
test "路径栏状态机：Cmd+O 开 / 键入 / 退格 / Esc 关 / 再按 Cmd+O 关" {
  load(demo_sample())
  assert_false(dialog_open.val)
  // Cmd+O 打开；keydown 后框架会补发一条同字符 TEXT（os 行为），先吞掉
  on_key('o'.to_int(), @gpui.MOD_PLATFORM)
  assert_true(dialog_open.val)
  assert_true(path_buf.val == "~/")
  on_text("o") // 修饰键补发的字符事件：被吞，不进缓冲区
  assert_true(path_buf.val == "~/")
  on_text("tmp/x.m")
  assert_true(path_buf.val == "~/tmp/x.m")
  on_named_key(@gpui.KEY_BACKSPACE, 0)
  assert_true(path_buf.val == "~/tmp/x.")
  on_named_key(@gpui.KEY_ESCAPE, 0)
  assert_false(dialog_open.val)
  // 重开 → 再按 Cmd+O 直接关
  on_key('o'.to_int(), @gpui.MOD_PLATFORM)
  on_text("o")
  assert_true(dialog_open.val)
  on_key('o'.to_int(), @gpui.MOD_PLATFORM)
  on_text("o")
  assert_false(dialog_open.val)
  let _ = open_path("/tmp") // 目录：path_exists 通过但读会失败——兜底 Err 路径
}

///|
test "路径栏打开时吞掉编辑键，不动文档" {
  load("# 固定\n\n正文\n")
  let before = dump()
  on_key('o'.to_int(), @gpui.MOD_PLATFORM)
  on_text("o")
  on_text("hello 世界")
  assert_true(path_buf.val == "~/hello 世界")
  on_named_key(@gpui.KEY_DOWN, 0) // 方向键被对话框吞掉
  on_key('b'.to_int(), @gpui.MOD_PLATFORM) // 组合键被吞（Cmd+B 不生效）
  on_text("b")
  assert_true(dump() == before)
  on_named_key(@gpui.KEY_ESCAPE, 0)
}

///|
test "open_path 失败路径给出可读错误" {
  load(demo_sample())
  match open_path("") {
    Err(e) => assert_true(e.contains("空"))
    Ok(_) => abort("empty path should fail")
  }
  match open_path("/tmp/mdmbt_definitely_missing_file.md") {
    Err(e) => assert_true(e.contains("不存在"))
    Ok(_) => abort("missing file should fail")
  }
  assert_false(dialog_open.val)
}

///|
test "open_path 读取替换文档；save_current_file 回写；tilde 展开" {
  let path = "/tmp/mdmbt_open_wbtest.md"
  let ok = write_text(path, "# 打开的文件\n\n正文内容。\n")
  assert_true(ok)
  load(demo_sample())
  match open_path(path) {
    Ok(_) => ()
    Err(e) => abort("open_path failed: " + e)
  }
  assert_true(current_path() == path)
  assert_false(dialog_open.val)
  assert_true(dump().contains("# 打开的文件"))
  assert_true(!dump().contains("md_mbt 编辑器演示"))
  // 打开后编辑 → 回写 → 磁盘内容含新增
  let us = @core.collect_units(ed.blocks)
  let last = us.length() - 1
  ed.set_sel(@core.collapsed_sel(@core.Caret::{
    unit: last,
    offset: us[last].plain.to_array().length(),
  }))
  ed.apply_text("wbtest-save", fn(b, s) { @core.doc_insert(b, s, "回写标记") })
  match save_current_file() {
    Ok(_) => ()
    Err(e) => abort("save failed: " + e)
  }
  assert_true(read_text(path).unwrap_or("").contains("回写标记"))
  // 载入新文档会复位关联文件；未关联时保存报错
  load("# 新会话\n")
  assert_true(current_path() == "")
  match save_current_file() {
    Err(e) => assert_true(e.contains("未关联"))
    Ok(_) => abort("save on unassociated doc should fail")
  }
  // 打开新会话后 undo 历史是空的
  assert_false(ed.can_undo())
  // tilde 展开（纯函数）
  assert_true(expand_tilde("~/a.md") == home_dir() + "/a.md")
  assert_true(expand_tilde("/abs/a.md") == "/abs/a.md")
  let _ = @fs.remove_file(path) catch { _ => () }
}

///|
test "CRLF 归一化" {
  assert_true(normalize_eol("a\r\nb\rc\nd") == "a\nb\nc\nd")
  assert_true(normalize_eol("plain") == "plain")
}

///|
test "路径栏渲染：命令缓冲字节含提示与路径" {
  let cb = @gpui.CommandBuffer::new()
  cb.div()
  render_path_bar(cb, "/tmp/some.md", "文件不存在")
  cb.add_child()
  cb.set_root()
  let bytes = cb.to_bytes()
  assert_true(bytes.length() > 0)
  assert_true(bytes_has(bytes, "打开文件"))
  assert_true(bytes_has(bytes, "/tmp/some.md"))
  assert_true(bytes_has(bytes, "文件不存在"))
}
