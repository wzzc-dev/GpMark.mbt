/// GPUI 适配层（应用装配）：编辑器状态、事件分发、build_tree。
///
/// 消费端形态与 counter 示例一致：main 里 register_dispatch(adapter.dispatch)
/// → adapter.build_tree(0) → run_window。本包不 import `link`，因此可以带
/// `moon test`（真正触 FFI 的只有 build_tree/dispatch 路径）。

///|
pub let store : @gpui.Store = @gpui.Store::new()

let rev_cell : @gpui.CellId[Int] = store.new_cell(0)
let rev : @gpui.Signal[Int] = store.signal(rev_cell)

///|
/// 编辑器状态（core 的快照式 Editor，写时复制）。
pub let ed : @core.Editor = @core.Editor::new([@core.Paragraph([])])

fn bump() -> Unit {
  rev.set(store, rev.get(store) + 1)
}

///|
/// 载入文档（demo 启动 / 外部注入）。
pub fn load(src : String) -> Unit {
  ed.blocks = @core.doc_ensure(@core.parse_doc(src))
  ed.sel = @core.collapsed_sel(@core.Caret::{ unit: 0, offset: 0 })
}

///|
/// 导出当前文档为规范 Markdown。
pub fn dump() -> String {
  @core.serialize_doc(ed.blocks)
}

///|
/// demo 用的示例文档（标题/列表/任务/引用/代码/表格/图片/HR/行内样式/链接/Raw）。
pub fn demo_sample() -> String {
  "# md_mbt 编辑器演示\n" + "\n这是 **GPUI 后端** 的 MoonBit *Markdown* WYSIWYG 核心。\n" + "直接键入编辑，Cmd+Z 撤销，点击任意块聚焦（光标落到块尾）。\n" + "\n## 列表与任务\n" + "- 无序项 alpha\n" + "  - 嵌套子项\n" + "1. 有序一\n" + "2. 有序二\n" + "- [x] 已完成任务\n" + "- [ ] 待办任务\n" + "\n> 引用块：**粗体**、`代码`、[链接](https://moonbitlang.dev) 都在同一段里。\n" + "\n```moonbit\nfn greet(name : String) -> String {\n  \"hello \" + name\n}\n```\n" + "\n## 表格\n" + "| 层 | 角色 | 说明 |\n" + "| --- | --- | --- |\n" + "| core | 纯逻辑 | 块树 / 解析 / 编辑 / undo，零 FFI |\n" + "| adapter | 适配 | 块树 → gpui 节点树 + 事件回灌 |\n" + "| main | 装配 | 链接 Rust staticlib，进入事件循环 |\n" + "\n![moon](moon.png)\n" + "\n---\n" + "\n<div class=\"raw-block\">不在稳定子集的语法保留为原样块，导出时零损失。</div>\n"
}

// --- 点击聚焦 ---------------------------------------------------------------
// click 事件不带坐标（framework gap）：点击 = 聚焦该块、光标移到块尾。
// 每个渲染槽复用一个固定 click id，重渲染时更新「槽 → 顶层块下标」映射。

const CLICK_POOL : Int = 128

// 注意：MoonBit 顶层 let 只在被引用时求值——初始化必须内联在初始化器里，
// 不能用「副作用型 _init let」（那种从未被引用的 let 根本不会执行）。
let click_slot : Array[Int] = Array::make(CLICK_POOL, 0)

let handlers : @gpui.HandlerRegistry = {
  let r = @gpui.HandlerRegistry::new()
  let _ = r.on_key(fn(code, mods) { on_key(code, mods) })
  let _ = r.on_named_key(fn(id, mods) { on_named_key(id, mods) })
  let _ = r.on_text(fn(t) { on_text(t) })
  r
}

let click_ids : Array[@gpui.HandlerId] = {
  let ids : Array[@gpui.HandlerId] = []
  for k in 0..<CLICK_POOL {
    ids.push(handlers.on_click(fn(_view) { on_block_click(k) }))
  }
  ids
}

///|
/// 渲染槽 `slot` 写入命令缓冲的实际 click handler id（自检/测试注入事件用）。
pub fn click_id_of(slot : Int) -> Int {
  if slot >= 0 && slot < click_ids.length() {
    click_ids[slot].to_int()
  } else {
    -1
  }
}

fn on_block_click(slot : Int) -> Unit {
  if slot >= click_slot.length() {
    return
  }
  let top = click_slot[slot]
  let us = @core.collect_units(ed.blocks)
  let mut last = -1
  for i = 0; i < us.length(); i = i + 1 {
    if us[i].top_index == top {
      last = i
    }
  }
  if last < 0 {
    return
  }
  let off = us[last].plain.to_array().length()
  ed.set_sel(@core.collapsed_sel(@core.Caret::{ unit: last, offset: off }))
  bump()
}

// --- 键入 / 编辑事件 --------------------------------------------------------

// 框架缺口（见 docs/framework-gaps.md）：gpui-sys 的 typed_text 不看修饰键，
// Cmd/Ctrl/Alt 组合键在发 EVENT_KEY 之后还会补发一条 EVENT_TEXT 字符事件。
// EVENT_TEXT 信封不带 mods，无法自判，所以在处理带修饰键的 keydown 时置标志，
// 吞掉紧随其后的那一条 text 事件。
let swallow_text : Array[Bool] = [false]

fn on_text(t : String) -> Unit {
  if swallow_text[0] {
    swallow_text[0] = false
    return
  }
  ed.apply(fn(b, s) { @core.doc_insert(b, s, t) })
  bump()
}

fn on_key(code : Int, mods : Int) -> Unit {
  if (mods & (@gpui.MOD_PLATFORM | @gpui.MOD_CTRL | @gpui.MOD_ALT)) != 0 {
    swallow_text[0] = true
  }
  if (mods & @gpui.MOD_PLATFORM) != 0 {
    if code == 'z'.to_int() || code == 'Z'.to_int() {
      if (mods & @gpui.MOD_SHIFT) != 0 {
        ed.redo()
      } else {
        ed.undo()
      }
      bump()
    } else if code == 'a'.to_int() || code == 'A'.to_int() {
      ed.set_sel(@core.doc_select_all(ed.blocks))
      bump()
    }
  }
}

fn on_named_key(id : Int, mods : Int) -> Unit {
  let ext = (mods & @gpui.MOD_SHIFT) != 0
  if id == @gpui.KEY_ENTER {
    ed.apply(fn(b, s) { @core.doc_enter(b, s) })
    bump()
  } else if id == @gpui.KEY_BACKSPACE {
    ed.apply(fn(b, s) { @core.doc_backspace(b, s) })
    bump()
  } else if id == @gpui.KEY_DELETE {
    ed.apply(fn(b, s) { @core.doc_delete_forward(b, s.focus) })
    bump()
  } else {
    let dir =
      if id == @gpui.KEY_LEFT {
        Some(@core.Left)
      } else if id == @gpui.KEY_RIGHT {
        Some(@core.Right)
      } else if id == @gpui.KEY_UP {
        Some(@core.Up)
      } else if id == @gpui.KEY_DOWN {
        Some(@core.Down)
      } else if id == @gpui.KEY_HOME {
        Some(@core.Home)
      } else if id == @gpui.KEY_END {
        Some(@core.End)
      } else {
        None
      }
    match dir {
      Some(d) => {
        ed.set_sel(@core.doc_move(ed.blocks, ed.sel, d, ext))
        bump()
      }
      None => ()
    }
  }
}

// --- 渲染入口 ---------------------------------------------------------------

let ctx : @gpui.RenderCtx = { view: 0, store, handlers }

///|
/// 全量重建（store dirty 时由框架调度）。
pub fn rebuild(view : Int) -> Result[Unit, Int] {
  let cb = @gpui.CommandBuffer::new()
  cb.div() // root
  cb.set_bg(28, 30, 38)
  cb.set_flex_col()
  cb.set_gap(6.0)
  cb.set_padding(28)
  let blocks = ed.blocks
  let sel_a = @core.sel_start(ed.sel)
  let sel_b = @core.sel_end(ed.sel)
  let mut cur = 0
  for i = 0; i < blocks.length(); i = i + 1 {
    let slot = if i < CLICK_POOL { i } else { CLICK_POOL - 1 }
    if slot < click_slot.length() {
      click_slot[slot] = i
    }
    cb.div()
    cb.set_cursor(@gpui.CURSOR_TEXT)
    cb.set_whitespace(@gpui.WHITESPACE_PRE_WRAP)
    cb.set_padding_sides(2, 6, 2, 6)
    cb.set_on_click(click_ids[slot].to_int())
    render_block(cb, blocks[i], cur, sel_a, sel_b)
    cb.add_child()
    cur = cur + count_units_of(blocks[i])
  }
  cb.set_root()
  @gpui.build_tree(view, cb)
}

///|
/// 与 `rebuild` 相同（保持消费端 `build_tree(view)` 的直觉名字）。
pub fn build_tree(view : Int) -> Result[Unit, Int] {
  rebuild(view)
}

///|
/// 事件入口：main 用 register_dispatch 注册后由 Rust 调用。
pub fn dispatch(version : Int, kind : Int, view : Int, data_a : Int, data_b : Int) -> Int {
  @gpui.framework_dispatch(
    ctx,
    version,
    kind,
    view,
    data_a,
    data_b,
    fn(v) { rebuild(v) },
  )
}
