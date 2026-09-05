/// GPUI 适配层（应用装配）：编辑器状态、事件分发、build_tree。
///
/// 消费端形态与 counter 示例一致：main 里 register_dispatch(adapter.dispatch)
/// → adapter.build_tree(0) → run_window。本包不 import `link`，因此可以带
/// `moon test`（真正触 FFI 的只有 build_tree/dispatch 路径）。

///|
pub let store : @gpui.Store = @gpui.Store::new()

///|
let rev_cell : @gpui.CellId[Int] = store.new_cell(0)

///|
let rev : @gpui.Signal[Int] = store.signal(rev_cell)

///|
/// 编辑器状态（core 的快照式 Editor，写时复制）。
pub let ed : @core.Editor = @core.Editor::new([@core.Paragraph([])])

///|
/// 内容变更信号：作废高度缓存并触发重建。
fn bump() -> Unit {
  cache_valid.val = false
  rev.set(store, rev.get(store) + 1)
}

///|
/// 纯选区/视图信号（光标、选区、组词预览、滚动窗口移动）：只触发重建。
/// 块数组没变，高度前缀和缓存保持有效，重建直接复用。
fn bump_sel() -> Unit {
  rev.set(store, rev.get(store) + 1)
}

// --- 虚拟窗口状态 -----------------------------------------------------------
// 渲染只提交可视块 ± WINDOW_PAD（渲染前用高度前缀和定位窗口）。滚动条
// 行程由窗口两侧 spacer 撑出；GPUI 的 ScrollHandle 保持原生偏移，跨重建
// 由 set_key("scroll") 保位。对齐 md_editor gpui v1 的做法（v1 用固定行
// 高，md_mbt 保真渲染改用估算高度前缀和）。

///|
/// 上下各留 256px 过扫描：视口 800 + 2×256 ≈ 1312px 提交量。pad 越大，
/// gpui 每帧 taffy 重排的元素越多（frame_work 随挂载行数线性增长）；
/// ±480px 滚轮步进在 256px pad 下仍每步触发窗口更新，几何探针与 spacer
/// 机制不变。
const WINDOW_PAD : Float = 256.0

///|
let viewport_h : Ref[Float] = { val: 800.0 }

///|
/// 设定滚动视口高度（demo 窗口与基准 1280x800 窗口不同）。
pub fn set_viewport_height(h : Float) -> Unit {
  viewport_h.val = h
}

///|
let scroll_y : Ref[Float] = { val: 0.0 }

///|
let win_lo : Ref[Int] = { val: 0 }

///|
let win_hi : Ref[Int] = { val: 0 }

// 高度/单元前缀和缓存（长度 n+1）。只在文档版本 bump 后更新；纯滚动/选区
// 重建（bump_sel）直接复用。bump 后的更新走块级内容指纹：指纹没变的块
// 复用上次估高（典型键入只有 1 个块变化），块数变化时全量对齐重算——
// 指纹本身 O(结构节点数)，全文一遍也只读结构不读文本。

///|
let cache_valid : Ref[Bool] = { val: false }

///|
let cache_cum : Ref[Array[Float]] = { val: [] }

///|
let cache_units : Ref[Array[Int]] = { val: [] }

// 逐块估高 / 单元数 / 内容指纹（与 blocks 等长，随每次缓存更新重建）。
///|
let cache_heights : Ref[Array[Float]] = { val: [] }

///|
let cache_block_units : Ref[Array[Int]] = { val: [] }

///|
let cache_fp : Ref[Array[UInt64]] = { val: [] }

///|
fn ensure_height_cache() -> Unit {
  let blocks = ed.blocks
  let n = blocks.length()
  if cache_valid.val && cache_cum.val.length() == n + 1 {
    return
  }
  // 块数不变时全部数组原地改写：每键零分配（指纹数组若每次新建，
  // 5 份 n 长数组/键的分配压力会在 stress 文档上诱发 GC 尖峰）。
  let reuse =
    cache_fp.val.length() == n &&
    cache_heights.val.length() == n &&
    cache_block_units.val.length() == n &&
    cache_cum.val.length() == n + 1 &&
    cache_units.val.length() == n + 1
  let cum : Array[Float] = if reuse { cache_cum.val } else { [0.0] }
  let units : Array[Int] = if reuse { cache_units.val } else { [0] }
  let heights : Array[Float] = if reuse { cache_heights.val } else { [] }
  let block_units : Array[Int] =
    if reuse { cache_block_units.val } else { [] }
  let fps : Array[UInt64] = if reuse { cache_fp.val } else { [] }
  let mut h : Float = 0.0
  let mut u = 0
  for i = 0; i < n; i = i + 1 {
    let b = blocks[i]
    // 滚动容器 set_gap(6.0)：块间间隙计入滚动行程。
    if i > 0 {
      h = h + 6.0
    }
    let f = block_fingerprint(b)
    let (bh, bu) = if reuse && fps[i] == f {
      (heights[i], block_units[i])
    } else {
      (estimate_slot_height(b, base_avail), count_units_of(b))
    }
    h = h + bh
    u = u + bu
    if reuse {
      cum[i + 1] = h
      units[i + 1] = u
      heights[i] = bh
      block_units[i] = bu
      fps[i] = f
    } else {
      cum.push(h)
      units.push(u)
      heights.push(bh)
      block_units.push(bu)
      fps.push(f)
    }
  }
  cache_cum.val = cum
  cache_units.val = units
  cache_heights.val = heights
  cache_block_units.val = block_units
  cache_fp.val = fps
  cache_valid.val = true
}

///|
/// 可视块区间 [lo, hi)：cum 前缀和与 scroll_y ± viewport ± overscan 相交。
/// cum 随块高严格递增，两端各做一次二分代替线性扫描。
fn compute_window(y : Float) -> (Int, Int) {
  let n = ed.blocks.length()
  let cum = cache_cum.val
  if cum.length() != n + 1 {
    return (0, n)
  }
  let top = y - WINDOW_PAD
  let bottom = y + viewport_h.val + WINDOW_PAD
  // 首个「底边越过窗口顶」的块：cum[lo+1] > top
  let mut a = 0
  let mut b = n
  while a < b {
    let m = (a + b) / 2
    if cum[m + 1] > top {
      b = m
    } else {
      a = m + 1
    }
  }
  let lo = a
  // 首个「顶边到达窗口底以下」的块：cum[hi] >= bottom
  let mut c = lo
  let mut d = n
  while c < d {
    let m = (c + d) / 2
    if cum[m] >= bottom {
      d = m
    } else {
      c = m + 1
    }
  }
  (lo, c)
}

///|
/// 载入文档（demo 启动 / 打开文件）。切换文档即新会话：undo 历史、
/// 关联文件一并复位。
pub fn load(src : String) -> Unit {
  ed.blocks = @core.doc_ensure(@core.parse_doc(src))
  ed.sel = @core.collapsed_sel(@core.Caret::{ unit: 0, offset: 0 })
  ed.undo_stack.clear()
  ed.redo_stack.clear()
  ed.merge_key = ""
  scroll_y.val = 0.0
  win_lo.val = 0
  win_hi.val = 0
  cache_valid.val = false
  current_file.val = ""
}

///|
/// 导出当前文档为规范 Markdown。
pub fn dump() -> String {
  @core.serialize_doc(ed.blocks)
}

// --- 打开 / 保存文件（Cmd+O / Cmd+S）----------------------------------------
// Cmd+O（顶栏 Open 按钮同款）经 filedialog_stub.c 弹出系统文件选择框
// （NSOpenPanel，子进程 osascript choose file 承载，弹出期间本进程阻塞
// 等价模态），选中即 open_path 读文件替换文档并记住路径；取消无操作。
// 已关联文件的文档 Cmd+S 规范导出回写同一路径；未关联文档（新建/demo）
// 弹出系统保存框选定目的地，写入成功才建立关联。路径支持 `~` 展开；
// 读入统一 CRLF→LF。

///|
let current_file : Ref[String] = { val: "" }

// --- IME 组合中文字（preedit）-----------------------------------------------
// gpui-sys 的 ImeBridge 在组词更新时经 EVENT_ASYNC 推 0xEE 标记 + UTF-8 组合
// 文本；提交文本走 EVENT_TEXT 并在 on_text 顶部先清空本状态（提交替代组合）。

///|
let preedit : Ref[String] = { val: "" }

///|
fn on_preedit(payload : Bytes) -> Unit {
  if payload.length() > 0 && payload[0] == 0xEE {
    preedit.val = if payload.length() > 1 {
      @utf8.decode(payload[1:payload.length()]) catch {
        _ => ""
      }
    } else {
      ""
    }
    bump_sel()
  }
}

// --- 鼠标拖拽选区 -----------------------------------------------------------
// gpui-sys 根节点的鼠标监听把左键按下/拖拽移动/释放转成 EVENT_ASYNC 0xEF
// 负载（hit.decode_mouse 解析；移动仅在左键按住时发来）。按下在命中点落
// 光标并锚定选区；拖拽把选区从锚点扩到命中点（几何命中见 hit.mbt：读渲染
// 层的探针矩形，与点击定位同源）；释放结束拖拽。
// 桥层在按下-释放后照常合成 token/unit click：拖拽过的用 drag_moved 拦截
// （不抹掉刚拖出的选区）；没拖拽的按下已按像素比例精确落点，用 mouse_placed
// 拦截一次（click 手势只到行段起点，不能让粗定位覆盖精确定位）。

///|
let drag_anchor : Ref[@core.Caret?] = { val: None }

///|
let drag_moved : Ref[Bool] = { val: false }

///|
let mouse_placed : Ref[Bool] = { val: false }

///|
/// metrics 通道生产实现（text-row ABI）：回读上一帧镜像的行真实布局，
/// 窗口坐标 → 段内字符下标。无已绘布局返回 None，caret_at_point 回退
/// 段宽线性插值（headless、首帧前等场景）。
fn row_metrics(key : String, x : Float, y : Float) -> Int? {
  @gpui.text_char_for_position(key, x, y)
}

///|
fn hit_caret(x : Int, y : Int) -> @core.Caret? {
  ensure_height_cache()
  let us = @core.collect_units(ed.blocks)
  let cu = cache_units.val
  let u0 = if win_lo.val >= 0 && win_lo.val < cu.length() {
    cu[win_lo.val]
  } else {
    0
  }
  let u1 = if win_hi.val > win_lo.val && win_hi.val < cu.length() {
    cu[win_hi.val]
  } else {
    us.length()
  }
  caret_at_point(x, y, u0, u1, us, probe_rect, row_metrics)
}

///|
fn caret_eq(a : @core.Caret, b : @core.Caret) -> Bool {
  // Caret 结构体 == 是引用相等，必须逐字段比。
  a.unit == b.unit && a.offset == b.offset
}

///|
fn on_mouse(phase : Int, x : Int, y : Int) -> Unit {
  if phase == 0 {
    drag_moved.val = false
    let anchor = hit_caret(x, y)
    drag_anchor.val = anchor
    mouse_placed.val = anchor.is_some()
    match anchor {
      Some(c) => {
        ed.set_sel(@core.collapsed_sel(c))
        bump_sel()
      }
      None => ()
    }
  } else if phase == 1 {
    match drag_anchor.val {
      Some(a) =>
        match hit_caret(x, y) {
          Some(c) => {
            if caret_eq(ed.sel.focus, c) && caret_eq(ed.sel.anchor, a) {
              return ()
            }
            ed.set_sel(@core.Sel::{ anchor: a, focus: c })
            drag_moved.val = true
            bump_sel()
          }
          None => ()
        }
      None => ()
    }
  } else {
    drag_anchor.val = None // 释放；drag_moved 保留给紧随其后的合成 click
  }
}

///|
/// EVENT_ASYNC 负载分发：按首字节 tag 路由（0xEE=组词文本，0xEF=鼠标）。
fn on_async_payload(payload : Bytes) -> Unit {
  if payload.length() > 0 && payload[0] == 0xEE {
    on_preedit(payload)
  } else {
    match decode_mouse(payload) {
      Some((phase, x, y)) => on_mouse(phase, x, y)
      None => ()
    }
  }
}

///|
/// 当前文档关联的文件路径（空串 = 未关联，如 demo 文档）。
pub fn current_path() -> String {
  current_file.val
}

///|
fn home_dir() -> String {
  // HOME 在 Windows 上通常不存在（仅 Git Bash 进程注入），回退 USERPROFILE。
  match @env.get_env_var("HOME") {
    Some(h) if h != "" => h
    _ =>
      match @env.get_env_var("USERPROFILE") {
        Some(h) if h != "" => h
        _ => "~"
      }
  }
}

///|
fn expand_tilde(p : String) -> String {
  if p == "~" {
    home_dir()
  } else if p.has_prefix("~/") {
    home_dir() + String::from_array(p.to_array()[1:])
  } else {
    p
  }
}

///|
fn normalize_eol(s : String) -> String {
  let cs = s.to_array()
  let out : Array[Char] = []
  let mut i = 0
  while i < cs.length() {
    if cs[i] == '\r' {
      out.push('\n')
      if i + 1 < cs.length() && cs[i + 1] == '\n' {
        i = i + 1
      }
    } else {
      out.push(cs[i])
    }
    i = i + 1
  }
  String::from_array(out)
}

///|
fn read_text(p : String) -> String? {
  let s = @fs.read_file_to_string(p) catch { _ => return None }
  Some(s)
}

///|
fn write_text(p : String, s : String) -> Bool {
  @fs.write_string_to_file(p, s) catch {
    _ => return false
  }
  true
}

///|
/// 按路径打开 Markdown 文件并替换当前文档（`~` 展开、CRLF 归一、
/// 清空 undo 历史、记住 current_file 供 Cmd+S 回写）。失败返回可读错误。
pub fn open_path(p : String) -> Result[Unit, String] {
  let full = expand_tilde(p.trim().to_owned())
  if full == "" || full == "~" || full == "~/" {
    Err("路径为空")
  } else if !@fs.path_exists(full) {
    Err("文件不存在：" + full)
  } else {
    match read_text(full) {
      None => Err("读取失败：" + full)
      Some(text) => {
        load(normalize_eol(text))
        current_file.val = full
        Ok(())
      }
    }
  }
}

///|
/// 规范导出当前文档，回写到已关联文件。未关联/写失败返回错误。
pub fn save_current_file() -> Result[Unit, String] {
  let p = current_file.val
  if p == "" {
    Err("当前文档未关联文件（先 Cmd+O 打开一个文件）")
  } else if write_text(p, dump()) {
    Ok(())
  } else {
    Err("写入失败：" + p)
  }
}

///|
/// 弹出系统文件选择框选择并打开文件（Cmd+O / 顶栏 Open）。取消无操作；
/// 选中后读入失败（极少见）打日志并保留当前文档。
fn open_via_dialog() -> Unit {
  match pick_file() {
    Some(p) =>
      match open_path(p) {
        Ok(_) => ()
        Err(e) => println("open failed: " + e)
      }
    None => ()
  }
}

///|
/// 保存入口（Cmd+S / 顶栏 Save）：已关联文件直接回写；未关联文档弹系统
/// 保存框选定目的地，写入成功才建立关联（取消无操作）。
fn save_via_dialog() -> Unit {
  if current_file.val == "" {
    match pick_save_file() {
      Some(p) =>
        if write_text(p, dump()) {
          current_file.val = p
        } else {
          println("写入失败：" + p)
        }
      None => ()
    }
  } else {
    match save_current_file() {
      Ok(_) => ()
      Err(e) => println(e)
    }
  }
}

// --- 顶栏（文件名 + New / Open / Save 按钮）----------------------------------
// 用户指定的布局：最上面一排左侧显示文件名，右侧打开文件按钮（外加 New/Save，
// 对齐 mockup）。按钮沿用 handler id 机制：id 一次注册永久复用，重建只重写。

///|
/// 顶栏左侧显示的文件名；未关联文件（demo/新建）时 Untitled.md。
pub fn display_name() -> String {
  let p = current_file.val
  if p == "" {
    "Untitled.md"
  } else {
    let cs = p.to_array()
    let mut i = cs.length() - 1
    while i > 0 && cs[i - 1] != '/' {
      i = i - 1
    }
    String::from_array(cs[i:cs.length()])
  }
}

///|
fn on_btn_new() -> Unit {
  // 新建：清空为单空段落（load 复位 undo/关联文件）。
  load("")
}

///|
fn on_btn_open() -> Unit {
  open_via_dialog()
}

///|
fn on_btn_save() -> Unit {
  save_via_dialog()
}

///|
let bar_ids : Array[@gpui.HandlerId] = []

///|
fn reg_bar(slot : Int) -> Int {
  while bar_ids.length() <= slot {
    let k = bar_ids.length()
    bar_ids.push(
      handlers.on_click(fn(_view) {
        if k == 0 {
          on_btn_new()
        } else if k == 1 {
          on_btn_open()
        } else {
          on_btn_save()
        }
        bump()
      }),
    )
  }
  bar_ids[slot].to_int()
}

///|
/// demo 用的示例文档（标题/列表/任务/引用/代码/表格/图片/HR/行内样式/链接/Raw）。
pub fn demo_sample() -> String {
  "# md_mbt 编辑器演示\n" +
  "\n这是 **GPUI 后端** 的 MoonBit *Markdown* WYSIWYG 核心。\n" +
  "直接键入编辑，Cmd+Z 撤销，点击任意文字处定位光标。\n" +
  "\n## 列表与任务\n" +
  "- 无序项 alpha\n" +
  "  - 嵌套子项\n" +
  "1. 有序一\n" +
  "2. 有序二\n" +
  "- [x] 已完成任务\n" +
  "- [ ] 待办任务\n" +
  "\n> 引用块：**粗体**、`代码`、[链接](https://moonbitlang.dev) 都在同一段里。\n" +
  "\n```moonbit\nfn greet(name : String) -> String {\n  \"hello \" + name\n}\n```\n" +
  "\n## 表格\n" +
  "| 层 | 角色 | 说明 |\n" +
  "| --- | --- | --- |\n" +
  "| core | 纯逻辑 | 块树 / 解析 / 编辑 / undo，零 FFI |\n" +
  "| adapter | 适配 | 块树 → gpui 节点树 + 事件回灌 |\n" +
  "| main | 装配 | 链接 Rust staticlib，进入事件循环 |\n" +
  "\n![moon](moon.png)\n" +
  "\n---\n" +
  "\n<div class=\"raw-block\">不在稳定子集的语法保留为原样块，导出时零损失。</div>\n"
}

// --- 逐编辑单元点击 ---------------------------------------------------------
// click 事件不带坐标（framework gap）：文本单元按行粒度渲染（7db0276），
// 点击行段 = 光标落该行行首（render 的行段布局表）；行尾空白区 = 单元尾。
// 段内逐字符的精确落点走像素路径（hit.mbt 探针矩形），click 手势只在
// 像素路径没落点时兜底。任务 ☑/☐ 标记独立点击区 = 勾选切换。
// handler id 池按需增长（历史遗留的固定 128 槽会越界全部指向末块）。id 按
// (单元, token 下标) 注册一次永久复用：闭包捕获的是下标，点击时读「当前」
// 渲染留下的布局表，编辑导致的内容位移天然正确。
// 注意：MoonBit 顶层 let 只在被引用时求值——初始化必须内联在初始化器里。

///|
let unit_ids : Array[@gpui.HandlerId] = []

///|
let box_ids : Array[@gpui.HandlerId] = []

///|
let tok_ids : Array[Array[@gpui.HandlerId]] = []

///|
let handlers : @gpui.HandlerRegistry = {
  let r = @gpui.HandlerRegistry::new()
  let _ = r.on_key(fn(code, mods) { on_key(code, mods) })
  let _ = r.on_named_key(fn(id, mods) { on_named_key(id, mods) })
  let _ = r.on_text(fn(t) { on_text(t) })
  let _ = r.on_async(fn(payload) { on_async_payload(payload) })
  r
}

///|
fn reg_unit(unit : Int) -> Int {
  while unit_ids.length() <= unit {
    let k = unit_ids.length()
    unit_ids.push(handlers.on_click(fn(_view) { on_unit_click(k) }))
  }
  unit_ids[unit].to_int()
}

///|
fn reg_box(unit : Int) -> Int {
  while box_ids.length() <= unit {
    let k = box_ids.length()
    box_ids.push(handlers.on_click(fn(_view) { on_box_click(k) }))
  }
  box_ids[unit].to_int()
}

///|
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
/// 单元 `unit` 第 `ti` 个探针段（或段数 = 行尾空白区）的 click handler id。
pub fn token_click_id_of(unit : Int, ti : Int) -> Int {
  reg_token(unit, ti)
}

///|
fn on_token_click(unit : Int, ti : Int) -> Unit {
  if drag_moved.val || mouse_placed.val {
    mouse_placed.val = false // 一次性消费
    return
  } // 拖拽后桥层合成的 click：不覆盖刚拖出的选区
  let us = @core.collect_units(ed.blocks)
  if unit < 0 || unit >= us.length() {
    return
  }
  let starts = tok_starts_of(unit)
  if starts.length() == 0 {
    on_unit_click(unit) // 该单元当前不是 token 渲染：退化为落块尾
    return
  }
  // 编辑后段数变少：下标越界钳到单元末尾
  let off = if ti < starts.length() {
    starts[ti]
  } else {
    starts[starts.length() - 1]
  }
  ed.set_sel(@core.collapsed_sel(@core.Caret::{ unit, offset: off }))
  bump_sel()
}

///|
fn on_unit_click(unit : Int) -> Unit {
  if drag_moved.val || mouse_placed.val {
    mouse_placed.val = false
    return
  }
  let us = @core.collect_units(ed.blocks)
  if unit < 0 || unit >= us.length() {
    return
  }
  let off = us[unit].plain.to_array().length()
  ed.set_sel(@core.collapsed_sel(@core.Caret::{ unit, offset: off }))
  bump_sel()
}

///|
fn on_box_click(unit : Int) -> Unit {
  if drag_moved.val {
    return
  }
  let us = @core.collect_units(ed.blocks)
  if unit < 0 || unit >= us.length() {
    return
  }
  ed.apply(fn(b, _s) {
    @core.doc_toggle_task(
      b,
      @core.collapsed_sel(@core.Caret::{ unit, offset: 0 }),
    )
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

///|
let key_gen : Array[Int] = [0]

///|
let swallow_gen : Array[Int] = [-1]

///|
/// 「快捷键修饰键」位掩码：macOS 是 Cmd（MOD_PLATFORM）。Windows 上
/// gpui 把 platform 映射到 Win 键（被系统全局钩子占用，几乎传不进应用），
/// 惯例的快捷键修饰是 Ctrl，故 win32 额外接受 MOD_CTRL。判定用 OS 环境
/// 变量（与 home_dir 回退 USERPROFILE 同一手法；本地 moonbit core 无
/// os.target）。macOS/Linux 上 Ctrl 组合保持原义（不触发快捷键）。
fn cmd_mask() -> Int {
  let on_windows = match @env.get_env_var("OS") {
    Some(v) => v == "Windows_NT"
    None => false
  }
  if on_windows {
    @gpui.MOD_PLATFORM | @gpui.MOD_CTRL
  } else {
    @gpui.MOD_PLATFORM
  }
}

///|
fn bump_key_gen(mods : Int) -> Unit {
  key_gen[0] = key_gen[0] + 1
  if (mods & (@gpui.MOD_PLATFORM | @gpui.MOD_CTRL | @gpui.MOD_ALT)) != 0 {
    swallow_gen[0] = key_gen[0]
  } else {
    swallow_gen[0] = -1
  }
}

///|
fn on_text(t : String) -> Unit {
  // 提交文本替代组合中的 preedit（IME commit 先于本处理清空组词预览）
  preedit.val = ""
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
    let ed_ = match u.kind {
      @core.ParagraphU
      | @core.HeadingU(_)
      | @core.ListItemU
      | @core.CellU
      | @core.QuoteU => true
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

///|
let langs : Array[String] = [
  "", "moonbit", "rust", "python", "javascript", "json", "bash", "text",
]

///|
fn code_hit(code : Int, c : Char) -> Bool {
  code == c.to_int()
}

///|
fn set_mark(self_bold : Bool, it_italic : Bool, st : Bool, cd : Bool) -> Unit {
  ed.apply(fn(b, s) {
    @core.doc_toggle_mark(b, s, fn(m) {
      @core.Marks::{
        bold: if self_bold {
          !m.bold
        } else {
          m.bold
        },
        italic: if it_italic {
          !m.italic
        } else {
          m.italic
        },
        strike: if st {
          !m.strike
        } else {
          m.strike
        },
        code: if cd {
          !m.code
        } else {
          m.code
        },
      }
    })
  })
  bump()
}

///|
fn on_key(code : Int, mods : Int) -> Unit {
  bump_key_gen(mods)
  if (mods & cmd_mask()) != 0 {
    if code_hit(code, 'o') || code_hit(code, 'O') {
      // 弹系统文件选择框（osascript NSOpenPanel），弹出期间本进程阻塞
      open_via_dialog()
      bump()
    } else if code_hit(code, 's') || code_hit(code, 'S') {
      save_via_dialog()
      bump()
    } else if code_hit(code, 'c') || code_hit(code, 'C') {
      // 复制选区（空选区无操作）
      let text = @core.doc_selection_text(ed.blocks, ed.sel)
      if text != "" {
        clipboard_write(text)
      }
      bump_sel()
    } else if code_hit(code, 'x') || code_hit(code, 'X') {
      // 剪切：复制 + 删除选区（空选区无操作）
      let text = @core.doc_selection_text(ed.blocks, ed.sel)
      if text != "" {
        clipboard_write(text)
        let unit = ed.sel.focus.unit.to_string()
        ed.apply_text("x" + unit, fn(b, s) { @core.doc_backspace(b, s) })
      }
      bump()
    } else if code_hit(code, 'v') || code_hit(code, 'V') {
      // 粘贴：同步读系统剪贴板（NSPasteboard 桩），直接走 doc_paste
      // （多行自动拆段），不经过 on_text 的键入路径。
      let text = clipboard_read()
      if text != "" {
        let unit = ed.sel.focus.unit.to_string()
        ed.apply_text("v" + unit, fn(b, s) { @core.doc_paste(b, s, text) })
      }
      bump()
    } else if code_hit(code, 'z') || code_hit(code, 'Z') {
      if (mods & @gpui.MOD_SHIFT) != 0 {
        ed.redo()
      } else {
        ed.undo()
      }
      bump()
    } else if code_hit(code, 'a') || code_hit(code, 'A') {
      ed.set_sel(@core.doc_select_all(ed.blocks))
      bump_sel()
    } else if code_hit(code, 'b') || code_hit(code, 'B') {
      set_mark(true, false, false, false)
    } else if code_hit(code, 'i') || code_hit(code, 'I') {
      set_mark(false, true, false, false)
    } else if code_hit(code, 'e') || code_hit(code, 'E') {
      set_mark(false, false, false, true)
    } else if (mods & @gpui.MOD_SHIFT) != 0 &&
      (code_hit(code, 'x') || code_hit(code, 'X')) {
      set_mark(false, false, true, false)
    } else if code_hit(code, '[') {
      ed.apply(fn(b, s) { @core.doc_outdent(b, s) })
      bump()
    } else if code_hit(code, ']') {
      ed.apply(fn(b, s) { @core.doc_indent(b, s) })
      bump()
    } else if (mods & @gpui.MOD_SHIFT) != 0 &&
      (code_hit(code, 'l') || code_hit(code, 'L')) {
      ed.apply(fn(b, s) { @core.doc_cycle_code_lang(b, s, langs) })
      bump()
    }
  }
}

///|
fn on_named_key(id : Int, mods : Int) -> Unit {
  bump_key_gen(mods)
  let ext = (mods & @gpui.MOD_SHIFT) != 0
  let cmd = (mods & cmd_mask()) != 0
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
    bump_sel()
  } else {
    let dir = if id == @gpui.KEY_LEFT {
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
        bump_sel()
      }
      None => ()
    }
  }
}

// --- 渲染入口 ---------------------------------------------------------------

///|
let ctx : @gpui.RenderCtx = { view: 0, store, handlers }

///|
/// 滚动 div 的 id：EVENT_SCROLL 公告后拉取真实偏移，仅当可视窗口
/// （可见块区间）变化时才 bump 重建——原生滚轮的高频小步移动留在
/// ScrollHandle 内，不触发 MoonBit 命令树重建。
let scroll_handle : @gpui.ScrollId = {
  let id = handlers.new_scroll_id()
  handlers.on_scroll(id, fn(view) {
    match @gpui.scroll_state(view, id.to_int()) {
      Ok(state) => {
        let next = (-state.offset_y).max(0.0)
        scroll_y.val = next
        if cache_valid.val {
          let (lo, hi) = compute_window(next)
          if lo != win_lo.val || hi != win_hi.val {
            bump_sel()
          }
        }
      }
      Err(_) => ()
    }
  })
  id
}

///|
/// 窗口化重建（store dirty 时由框架调度）：只提交可视块 ± WINDOW_PAD，
/// 窗口外用两个 spacer div 撑出滚动行程（对齐 md_editor gpui v1 策略）。
pub fn rebuild(view : Int) -> Result[Unit, Int] {
  ensure_height_cache()
  let n = ed.blocks.length()
  let (lo, hi) = compute_window(scroll_y.val)
  win_lo.val = lo
  win_hi.val = hi
  let cum = cache_cum.val
  let cb = @gpui.CommandBuffer::new()
  cb.div() // root：承载顶栏与滚动容器
  cb.set_key("root")
  cb.set_bg(28, 30, 38)
  cb.set_flex_col()
  cb.div() // 探针表帧初清空标记（零尺寸不可见；须是 root 首个子节点）
  cb.set_key("probe:clear")
  cb.set_position(@gpui.POSITION_ABSOLUTE)
  cb.set_min_size(0, 0)
  cb.add_child()
  render_top_bar(cb, display_name(), reg_bar)
  cb.div() // 滚动容器：内容超高时鼠标滚轮可滚（框架提供原生滚动）
  cb.set_key("scroll")
  cb.set_flex_col()
  cb.set_gap(6.0)
  cb.set_padding(28)
  cb.set_overflow(@gpui.OVERFLOW_VISIBLE, @gpui.OVERFLOW_SCROLL)
  cb.set_scroll_id(scroll_handle.to_int())
  cb.set_flex(1.0, 0.0, 0.0)
  if lo > 0 {
    cb.div()
    cb.set_size(1.0, cum[lo])
    cb.set_flex(0.0, 0.0, cum[lo])
    cb.add_child()
  }
  set_preedit(preedit.val) // 组词文本随光标内联渲染（render 的光标覆盖层）
  render_doc_window(
    cb,
    ed.blocks,
    lo,
    hi,
    cache_units.val[lo],
    ed.sel,
    reg_unit,
    reg_box,
    reg_token,
  )
  if hi < n {
    cb.div()
    let rest = cum[n] - cum[hi]
    cb.set_size(1.0, rest)
    cb.set_flex(0.0, 0.0, rest)
    cb.add_child()
  }
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
pub fn dispatch(
  version : Int,
  kind : Int,
  view : Int,
  data_a : Int,
  data_b : Int,
) -> Int {
  @gpui.framework_dispatch(ctx, version, kind, view, data_a, data_b, fn(v) {
    rebuild(v)
  })
}
