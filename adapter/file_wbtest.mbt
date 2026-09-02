/// 打开/保存文件（系统文件选择框 + open_path/save_current_file）的纯逻辑
/// 单测。fs 调用走真实文件系统（临时文件在 /tmp）；文件选择框 FFI 不在
/// 单测中触发（会弹真对话框并阻塞进程），只测其下游 open_path。

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
  let _ = open_path("/tmp") // 目录：path_exists 通过但读会失败——兜底 Err 路径
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
