// 系统文件选择框桥：macOS 经 /usr/bin/osascript（AppleScript choose file /
// choose file name）弹出系统 NSOpenPanel / NSSavePanel；Windows 经
// powershell.exe 的 System.Windows.Forms 对话框（Win32 通用对话框）。
// 对话框由独立子进程承载——不引用 objc/AppKit，adapter 的测试
// 可执行文件零框架链接依赖（与 clipboard_stub.c 的 pbcopy/pbpaste 同一
// 形态）。对话框打开期间本进程阻塞在 popen 上（模态语义），取消/出错
// 返回 -1。其余平台按「取消」返回。

#ifdef __APPLE__

#include <stdio.h>
#include <string.h>

// 跑一条 AppleScript 表达式，把 stdout 首行（POSIX 路径）拷进 buf。
// 返回路径长度；取消（rc != 0，AppleScript -128）/无输出/超长返回 -1。
static int run_pick_script(const char *script, char *buf, int cap) {
  if (!buf || cap <= 0) {
    return -1;
  }
  buf[0] = '\0';
  char cmd[1024];
  snprintf(cmd, sizeof(cmd), "/usr/bin/osascript -e '%s' 2>/dev/null", script);
  FILE *p = popen(cmd, "r");
  if (!p) {
    return -1;
  }
  char line[4096];
  int len = -1;
  if (fgets(line, sizeof(line), p)) {
    size_t n = strlen(line);
    while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r')) {
      line[--n] = '\0';
    }
    if (n > 0 && n < (size_t)cap) {
      memcpy(buf, line, n + 1);
      len = (int)n;
    }
  }
  if (pclose(p) != 0) {
    return -1;
  }
  return len;
}

// 打开面板：choose file。选中时 buf 收到 POSIX 路径。
int gpui_pick_file(char *buf, int cap) {
  return run_pick_script(
      "POSIX path of (choose file with prompt \"打开文件\")", buf, cap);
}

// 保存面板：choose file name（未关联文档 Cmd+S 的目的地，默认名 Untitled.md）。
int gpui_pick_save_file(char *buf, int cap) {
  return run_pick_script(
      "POSIX path of (choose file name default name \"Untitled.md\" with "
      "prompt \"保存文件\")",
      buf, cap);
}

#else  // !__APPLE__

#ifdef _WIN32

#include <stdio.h>
#include <string.h>

// MSVC CRT 只有 POSIX 管道的下划线别名（_popen/_pclose），没有 popen/
// pclose 裸名（clipboard_stub.c 在非 macOS 是 no-op，桩里第一个真用它的）。
#define popen _popen
#define pclose _pclose

// Windows 分支：子进程桥同 macOS——powershell.exe 调 System.Windows.Forms
// 的 OpenFileDialog / SaveFileDialog（Win32 通用对话框的托管门面），模态
// 语义靠本进程阻塞在管道读上实现，与 osascript 分支同形态、零链接依赖。
// 取消/无输出/PowerShell 缺失都返回 -1（上层视为「取消」）。
// 脚本必须纯 ASCII：cmd.exe 按 OEM 代码页解析命令行，UTF-8 中文会变乱码；
// 对话框 UI 文案本身由系统本地化。stdout 强制 UTF-8（[Console]::Output-
// Encoding），含非 ASCII 的路径才能被上层 @utf8 解码。
static int run_pick_powershell(const char *script, char *buf, int cap) {
  if (!buf || cap <= 0) {
    return -1;
  }
  buf[0] = '\0';
  char cmd[2048];
  snprintf(cmd, sizeof(cmd),
           "powershell -NoProfile -WindowStyle Hidden -Command \"%s\" 2>nul",
           script);
  FILE *p = popen(cmd, "r");
  if (!p) {
    return -1;
  }
  char line[4096];
  int len = -1;
  if (fgets(line, sizeof(line), p)) {
    size_t n = strlen(line);
    while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r')) {
      line[--n] = '\0';
    }
    if (n > 0 && n < (size_t)cap) {
      memcpy(buf, line, n + 1);
      len = (int)n;
    }
  }
  pclose(p);
  return len;
}

// 打开面板。取消时 PowerShell 无输出，len 保持 -1。
int gpui_pick_file(char *buf, int cap) {
  return run_pick_powershell(
      "[Console]::OutputEncoding=[Text.Encoding]::UTF8;"
      "Add-Type -AssemblyName System.Windows.Forms;"
      "$d=New-Object Windows.Forms.OpenFileDialog;"
      "$d.Title='Open File';"
      "if($d.ShowDialog() -eq [Windows.Forms.DialogResult]::OK)"
      "{Write-Output $d.FileName}",
      buf, cap);
}

// 保存面板：默认名 Untitled.md（未关联文档的保存目的地）。
int gpui_pick_save_file(char *buf, int cap) {
  return run_pick_powershell(
      "[Console]::OutputEncoding=[Text.Encoding]::UTF8;"
      "Add-Type -AssemblyName System.Windows.Forms;"
      "$d=New-Object Windows.Forms.SaveFileDialog;"
      "$d.Title='Save File';$d.FileName='Untitled.md';"
      "$d.Filter='Markdown (*.md)|*.md|All Files (*.*)|*.*';"
      "if($d.ShowDialog() -eq [Windows.Forms.DialogResult]::OK)"
      "{Write-Output $d.FileName}",
      buf, cap);
}

#else  // !_WIN32

// 其余平台（Linux 等）：无对应子进程桥，两个入口都按「取消」返回，
// 上层得到 None。
int gpui_pick_file(char *buf, int cap) {
  (void)buf;
  (void)cap;
  return -1;
}

int gpui_pick_save_file(char *buf, int cap) {
  (void)buf;
  (void)cap;
  return -1;
}

#endif  // _WIN32

#endif  // __APPLE__
