// 系统文件选择框桥：经 /usr/bin/osascript（AppleScript choose file /
// choose file name）弹出系统 NSOpenPanel / NSSavePanel 并同步等待结果。
// 对话框由独立 osascript 进程承载——不引用 objc/AppKit，adapter 的测试
// 可执行文件零框架链接依赖（与 clipboard_stub.c 的 pbcopy/pbpaste 同一
// 形态）。对话框打开期间本进程阻塞在 popen 上（模态语义），取消/出错
// 返回 -1。仅 macOS。

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
