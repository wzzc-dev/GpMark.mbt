/// 剪贴板：同步读写系统剪贴板（NSPasteboard），经 adapter/clipboard_stub.c
/// 直接访问 AppKit（与 moonbitlang/x/fs 的 native-stub 同一形态）。gpui 的
/// C 导出拿不到 App 上下文，这里绕开 gpui 自己成桥；纯文本、macOS。
/// 符号由 native-stub 提供定义，测试可执行文件同样能链接。

///|
#borrow(ptr)
extern "c" fn gpui_clipboard_write_text_ffi(ptr : Bytes, len : Int) -> Int = "gpui_clipboard_write_text"

///|
extern "c" fn gpui_clipboard_read_len_ffi() -> Int = "gpui_clipboard_read_len"

///|
#borrow(buf)
extern "c" fn gpui_clipboard_read_copy_ffi(buf : Bytes, cap : Int) -> Int = "gpui_clipboard_read_copy"

///|
/// 把文本写入系统剪贴板（同步生效）。
pub fn clipboard_write(text : String) -> Unit {
  let bytes = @utf8.encode(text)
  let _ = gpui_clipboard_write_text_ffi(bytes, bytes.length())
}

///|
/// 读取系统剪贴板文本；剪贴板为空/非文本时返回 ""。
pub fn clipboard_read() -> String {
  let len = gpui_clipboard_read_len_ffi()
  if len <= 0 {
    return ""
  }
  let buf = Bytes::make(len, b'\x00')
  let n = gpui_clipboard_read_copy_ffi(buf, len)
  if n <= 0 {
    return ""
  }
  @utf8.decode(buf[0:n]) catch {
    _ => ""
  }
}
