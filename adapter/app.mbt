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
  "# md_mbt 编辑器演示\n" + "\n这是 **GPUI 后端** 的 MoonBit *Markdown* WYSIWYG 核心。\n" + "直接键入编辑，Cmd+Z 撤销，点击任意文字处定位光标。\n" + "\n## 列表与任务\n" + "- 无序项 alpha\n" + "  - 嵌套子项\n" + "1. 有序一\n" + "2. 有序二\n" + "- [x] 已完成任务\n" + "- [ ] 待办任务\n" + "\n> 引用块：**粗体**、`代码`、[链接](https://moonbitlang.dev) 都在同一段里。\n" + "\n```moonbit\nfn greet(name : String) -> String {\n  \"hello \" + name\n}\n```\n" + "\n## 表格\n" + "| 层 | 角色 | 说明 |\n" + "| --- | --- | --- |\n" + "| core | 纯逻辑 | 块树 / 解析 / 编辑 / undo，零 FFI |\n" + "| adapter | 适配 | 块树 → gpui 节点树 + 事件回灌 |\n" + "| main | 装配 | 链接 Rust staticlib，进入事件循环 |\n" + "\n![moon](moon.png)\n" + "\n---\n" + "\n<div class=\"raw-block\">不在稳定子集的语法保留为原样块，导出时零损失。</div>\n"
}

// --- 逐编辑单元点击 ---------------------------------------------------------
// click 事件不带坐标（framework gap）：文本单元渲染为 token（CJK 逐字、拉丁
// 逐词），点击 token = 光标落该 token 起点（textlayout/render 的 token 布局
// 表）；行尾空白区 = 单元尾。任务 ☑/☐ 标记独立点击区 = 勾选切换。
// handler id 池按需增长（历史遗留的固定 128 槽会越界全部指向末块）。id 按
// (单元, token 下标) 注册一次永久复用：闭包捕获的是下标，点击时读「当前」
// 渲染留下的布局表，编辑导致的内容位移天然正确。
// 注意：MoonBit 顶层 let 只在被引用时求值——初始化必须内联在初始化器里。
let unit_ids : Array[@gpui.HandlerId] = []
let box_ids : Array[@gpui.HandlerId] = []
let tok_ids : Array[Array[@gpui.HandlerId]] = []

let handlers : @gpui.HandlerRegistry = {
  let r = @gpui.HandlerRegistry::new()
  let _ = r.on_key(fn(code, mods) { on_key(code, mods) })
  let _ = r.on_named_key(fn(id, mods) { on_named_key(id, mods) })
  let _ = r.on_text(fn(t) { on_text(t) })
  r
}

fn reg_unit(unit : Int) -> Int {
  while unit_ids.length() <= unit {
    let k = unit_ids.length()
    unit_ids.push(handlers.on_click(fn(_view) { on_unit_click(k) }))
  }
  unit_ids[unit].to_int()
}

fn reg_box(unit : Int) -> Int {
  while box_ids.length() <= unit {
    let k = box_ids.length()
    box_ids.push(handlers.on_click(fn(_view) { on_box_click(k) }))
  }
  box_ids[unit].to_int()
}

fn reg_token(unit : Int, ti : Int) -> Int {
  while tok_ids.length() <= unit {
    tok_ids.push([])
  }
  let arr = tok_ids[unit]
  while arr.length() <= ti {
    let u = unit
    let i = arr.length()
    arr.push(handlers.on_click(fn(_view) { on_token_click(u, i) }))
  }
  arr[ti].to_int()
}

///|
/// 单元 `unit` 的实际 click handler id（自检/测试注入事件用）。
pub fn click_id_of(unit : Int) -> Int {
  if unit < 0 {
    -1
  } else {
    reg_unit(unit)
  }
}

///|
/// 单元 `unit` 任务框的 click handler id。
pub fn box_id_of(unit : Int) -> Int {
  if unit < 0 {
    -1
  } else {
    reg_box(unit)
  }
}

///|
/// 单元 `unit` 第 `ti` 个 token（或 token 数 = 行尾空白区）的 click handler id。
pub fn token_click_id_of(unit : Int, ti : Int) -> Int {
  reg_token(unit, ti)
}

fn on_token_click(unit : Int, ti : Int) -> Unit {
  let us = @core.collect_units(ed.blocks)
  if unit < 0 || unit >= us.length() {
    return
  }
  let starts = tok_starts_of(unit)
  if starts.length() == 0 {
    on_unit_click(unit) // 该单元当前不是 token 渲染：退化为落块尾
    return
  }
  // 编辑后 token 变少：下标越界钳到单元末尾
  let off = if ti < starts.length() { starts[ti] } else { starts[starts.length() - 1] }
  ed.set_sel(@core.collapsed_sel(@core.Caret::{ unit, offset: off }))
  bump()
}

fn on_unit_click(unit : Int) -> Unit {
  let us = @core.collect_units(ed.blocks)
  if unit < 0 || unit >= us.length() {
    return
  }
  let off = us[unit].plain.to_array().length()
  ed.set_sel(@core.collapsed_sel(@core.Caret::{ unit, offset: off }))
  bump()
}

fn on_box_click(unit : Int) -> Unit {
  let us = @core.collect_units(ed.blocks)
  if unit < 0 || unit >= us.length() {
    return
  }
  ed.apply(fn(b, s) {
    @core.doc_toggle_task(b, @core.collapsed_sel(@core.Caret::{ unit, offset: 0 }))
  })
  bump()
}

// --- 键入 / 编辑事件 --------------------------------------------------------

// 框架缺口（见 docs/framework-gaps.md）：gpui-sys 的 typed_text 不看修饰键，
// Cmd/Ctrl/Alt 组合键在发 EVENT_KEY 之后还会补发一条 EVENT_TEXT 字符事件。
// EVENT_TEXT 信封不带 mods，无法自判，采用「代际计数」：每次 keydown 递增
// key_seq；带修饰键的 keydown 记下 swallow_seq；on_text 只有当 swallow_seq
// 仍等于当前代际时才吞——任何后续按键都会使过期的吞标志失效，避免一次性
// 布尔标志误吞普通键入。
let key_gen : Array[Int] = [0]
let swallow_gen : Array[Int] = [-1]

fn bump_key_gen(mods : Int) -> Unit {
  key_gen[0] = key_gen[0] + 1
  if (mods & (@gpui.MOD_PLATFORM | @gpui.MOD_CTRL | @gpui.MOD_ALT)) != 0 {
    swallow_gen[0] = key_gen[0]
  } else {
    swallow_gen[0] = -1
  }
}

fn on_text(t : String) -> Unit {
  if swallow_gen[0] == key_gen[0] {
    swallow_gen[0] = -1
    return
  }
  // 多行粘贴拆段 + 「标记+空格」规则 + 活行内转换
  // （同单元连续键入合并 undo：字面标记变样式与键入本身同一撤销点）
  let unit = ed.sel.focus.unit.to_string()
  ed.apply_text("t" + unit, fn(b, s) {
    let (b2, s2) = @core.doc_paste(b, s, t)
    let (b3, s3, _) = @core.doc_apply_space_rule(b2, s2)
    if !@core.reparse_trigger(t) {
      return (b3, s3)
    }
    let us = @core.collect_units(b3)
    let c = s3.focus
    if c.unit < 0 || c.unit >= us.length() {
      return (b3, s3)
    }
    let u = us[c.unit]
    let ed_ =
      match u.kind {
        @core.ParagraphU | @core.HeadingU(_) | @core.ListItemU | @core.CellU | @core.QuoteU => true
        _ => false
      }
    if !ed_ {
      return (b3, s3)
    }
    let (ni, no, changed) = @core.reparse_inlines(u.inlines, c.offset)
    if !changed {
      return (b3, s3)
    }
    (
      (u.set_inlines)(ni),
      @core.collapsed_sel(@core.Caret::{ unit: c.unit, offset: no }),
    )
  })
  bump()
}

let langs : Array[String] = [
  "", "moonbit", "rust", "python", "javascript", "json", "bash", "text",
]

fn code_hit(code : Int, c : Char) -> Bool {
  code == c.to_int()
}

fn set_mark(self_bold : Bool, it_italic : Bool, st : Bool, cd : Bool) -> Unit {
  ed.apply(fn(b, s) {
    @core.doc_toggle_mark(
      b,
      s,
      fn(m) {
        @core.Marks::{
          bold: if self_bold { !m.bold } else { m.bold },
          italic: if it_italic { !m.italic } else { m.italic },
          strike: if st { !m.strike } else { m.strike },
          code: if cd { !m.code } else { m.code },
        }
      },
    )
  })
  bump()
}

fn on_key(code : Int, mods : Int) -> Unit {
  bump_key_gen(mods)
  if (mods & @gpui.MOD_PLATFORM) != 0 {
    if code_hit(code, 'z') || code_hit(code, 'Z') {
      if (mods & @gpui.MOD_SHIFT) != 0 {
        ed.redo()
      } else {
        ed.undo()
      }
      bump()
    } else if code_hit(code, 'a') || code_hit(code, 'A') {
      ed.set_sel(@core.doc_select_all(ed.blocks))
      bump()
    } else if code_hit(code, 'b') || code_hit(code, 'B') {
      set_mark(true, false, false, false)
    } else if code_hit(code, 'i') || code_hit(code, 'I') {
      set_mark(false, true, false, false)
    } else if code_hit(code, 'e') || code_hit(code, 'E') {
      set_mark(false, false, false, true)
    } else if (mods & @gpui.MOD_SHIFT) != 0 && (code_hit(code, 'x') || code_hit(code, 'X')) {
      set_mark(false, false, true, false)
    } else if code_hit(code, '[') {
      ed.apply(fn(b, s) { @core.doc_outdent(b, s) })
      bump()
    } else if code_hit(code, ']') {
      ed.apply(fn(b, s) { @core.doc_indent(b, s) })
      bump()
    } else if (mods & @gpui.MOD_SHIFT) != 0 && (code_hit(code, 'l') || code_hit(code, 'L')) {
      ed.apply(fn(b, s) { @core.doc_cycle_code_lang(b, s, langs) })
      bump()
    }
  }
}

fn on_named_key(id : Int, mods : Int) -> Unit {
  bump_key_gen(mods)
  let ext = (mods & @gpui.MOD_SHIFT) != 0
  let cmd = (mods & @gpui.MOD_PLATFORM) != 0
  let alt = (mods & @gpui.MOD_ALT) != 0
  if id == @gpui.KEY_ENTER && cmd {
    // Cmd+Enter：从代码块出逃（velotype 语义）
    ed.apply(fn(b, s) { @core.doc_code_escape(b, s) })
    bump()
  } else if id == @gpui.KEY_ENTER && alt {
    // Alt+Enter：表格光标行下加一行；非表格无操作
    ed.apply(fn(b, s) { @core.doc_table_add_row(b, s) })
    bump()
  } else if id == @gpui.KEY_ENTER {
    ed.apply(fn(b, s) {
      match @core.doc_apply_enter_rules(b, s) {
        Some(hit) => hit
        None => {
          let (nb, ns) = @core.doc_enter(b, s)
          (@core.doc_ensure_trailing(nb), ns)
        }
      }
    })
    bump()
  } else if id == @gpui.KEY_BACKSPACE {
    let unit = ed.sel.focus.unit.to_string()
    ed.apply_text("d" + unit, fn(b, s) { @core.doc_backspace(b, s) })
    bump()
  } else if id == @gpui.KEY_DELETE {
    ed.apply(fn(b, s) { @core.doc_delete_forward(b, s.focus) })
    bump()
  } else if alt && (id == @gpui.KEY_LEFT || id == @gpui.KEY_RIGHT) {
    let d = if id == @gpui.KEY_LEFT { @core.Left } else { @core.Right }
    ed.set_sel(@core.doc_move_word(ed.blocks, ed.sel, d, ext))
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
  cb.div() // root：仅承载底色与滚动容器
  cb.set_key("root")
  cb.set_bg(28, 30, 38)
  cb.set_flex_col()
  cb.div() // 滚动容器：内容超高时鼠标滚轮可滚（框架提供原生滚动）
  cb.set_key("scroll")
  cb.set_flex_col()
  cb.set_gap(6.0)
  cb.set_padding(28)
  cb.set_overflow(@gpui.OVERFLOW_VISIBLE, @gpui.OVERFLOW_SCROLL)
  cb.set_scroll_id(0)
  cb.set_flex(1.0, 0.0, 0.0)
  render_doc(cb, ed.blocks, ed.sel, reg_unit, reg_box, reg_token)
  cb.add_child() // scroll → root
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
