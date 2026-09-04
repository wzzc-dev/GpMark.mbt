/// 系统文件选择框：经 adapter/filedialog_stub.c（native-stub）驱动子进程
/// 弹出系统对话框——macOS 用 /usr/bin/osascript 的 AppleScript
/// `choose file` / `choose file name`（即系统 NSOpenPanel / NSSavePanel），
/// Windows 用 powershell.exe 的 System.Windows.Forms 通用对话框；
/// 与 clipboard_stub.c 的 pbcopy/pbpaste 同一「绕开框架、子进程成桥」形态
/// （库包不能加 cc-link-flags，直接链 AppKit 会连累测试可执行文件）。
/// 弹出期间本进程同步阻塞在管道读上，等价模态；取消/出错返回 None。

///|
#borrow(buf)
extern "c" fn gpui_pick_file_ffi(buf : Bytes, cap : Int) -> Int = "gpui_pick_file"

///|
#borrow(buf)
extern "c" fn gpui_pick_save_file_ffi(buf : Bytes, cap : Int) -> Int = "gpui_pick_save_file"

///|
/// 弹出系统打开文件框。选中返回 POSIX 路径；取消/失败返回 None。
pub fn pick_file() -> String? {
  let buf = Bytes::make(4096, b'\x00')
  let n = gpui_pick_file_ffi(buf, 4096)
  if n <= 0 {
    return None
  }
  let s = @utf8.decode(buf[0:n]) catch { _ => return None }
  Some(s)
}

///|
/// 弹出系统保存文件框（默认名 Untitled.md，供未关联文档的 Cmd+S）。
pub fn pick_save_file() -> String? {
  let buf = Bytes::make(4096, b'\x00')
  let n = gpui_pick_save_file_ffi(buf, 4096)
  if n <= 0 {
    return None
  }
  let s = @utf8.decode(buf[0:n]) catch { _ => return None }
  Some(s)
}
