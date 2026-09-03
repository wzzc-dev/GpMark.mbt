// 系统剪贴板桥：macOS 经 /usr/bin/pbcopy、/usr/bin/pbpaste 同步读写纯文本；
// Windows 经 clip / PowerShell Get-Clipboard（同为子进程桥，UTF-8 尽力而为）；
// Linux 无可靠纯文本 CLI，读空/写失败由上层降级为空串/无操作。
// 不直接引用 objc/AppKit——adapter 的测试可执行文件不带框架链接参数，
// 走子进程最省依赖（与 moonbitlang/x/fs 的 native-stub 同一形态）。

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
// MSVC CRT 的 POSIX 对等物带前导下划线（MinGW 两者都有），命令按平台选定。
#define SUBPROC_OPEN _popen
#define SUBPROC_CLOSE _pclose
#define PASTE_CMD \
  "powershell -NoProfile -NonInteractive -Command " \
  "\"[Console]::OutputEncoding=[Text.Encoding]::UTF8;Get-Clipboard\" 2>nul"
#define COPY_CMD "clip"
#else
#define SUBPROC_OPEN popen
#define SUBPROC_CLOSE pclose
#define PASTE_CMD "/usr/bin/pbpaste 2>/dev/null"
#define COPY_CMD "/usr/bin/pbcopy"
#endif

// pbpaste 最近一次输出缓存（NUL 结尾）：len/copy 两段式 ABI 只跑一次子进程。
static char *cache = NULL;
static int cache_len = 0;

static void cache_reset(void) {
  free(cache);
  cache = NULL;
  cache_len = 0;
}

static void cache_refresh(void) {
  cache_reset();
  FILE *p = SUBPROC_OPEN(PASTE_CMD, "r");
  if (!p) {
    return;
  }
  size_t cap = 4096;
  size_t n = 0;
  char *buf = (char *)malloc(cap);
  if (!buf) {
    SUBPROC_CLOSE(p);
    return;
  }
  for (;;) {
    if (n + 1024 > cap) {
      cap *= 2;
      char *grown = (char *)realloc(buf, cap);
      if (!grown) {
        free(buf);
        SUBPROC_CLOSE(p);
        return;
      }
      buf = grown;
    }
    size_t got = fread(buf + n, 1, cap - n - 1, p);
    if (got == 0) {
      break;
    }
    n += got;
  }
  int rc = SUBPROC_CLOSE(p);
  if (rc != 0) {
    free(buf);
    return;
  }
  buf[n] = '\0';
  cache = buf;
  cache_len = (int)n;
}

int gpui_clipboard_read_len(void) {
  cache_refresh();
  return cache_len;
}

int gpui_clipboard_read_copy(unsigned char *buf, int cap) {
  if (!buf || cap <= 0) {
    return -1;
  }
  if (!cache) {
    cache_refresh();
  }
  if (!cache) {
    return 0;
  }
  int n = cache_len < cap ? cache_len : cap;
  memcpy(buf, cache, (size_t)n);
  return n;
}

int gpui_clipboard_write_text(const unsigned char *ptr, int len) {
  if (!ptr || len < 0) {
    return -1;
  }
  FILE *p = SUBPROC_OPEN(COPY_CMD, "w");
  if (!p) {
    return -1;
  }
  if (len > 0) {
    fwrite(ptr, 1, (size_t)len, p);
  }
  int rc = SUBPROC_CLOSE(p);
  cache_reset(); // 下次读要反映刚写入的内容
  return rc == 0 ? 0 : -1;
}
