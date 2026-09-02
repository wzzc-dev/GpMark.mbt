// 系统剪贴板桥：经 /usr/bin/pbcopy、/usr/bin/pbpaste 同步读写纯文本。
// 不直接引用 objc/AppKit——adapter 的测试可执行文件不带框架链接参数，
// 走子进程最省依赖（与 moonbitlang/x/fs 的 native-stub 同一形态）。仅 macOS。

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
  FILE *p = popen("/usr/bin/pbpaste 2>/dev/null", "r");
  if (!p) {
    return;
  }
  size_t cap = 4096;
  size_t n = 0;
  char *buf = (char *)malloc(cap);
  if (!buf) {
    pclose(p);
    return;
  }
  for (;;) {
    if (n + 1024 > cap) {
      cap *= 2;
      char *grown = (char *)realloc(buf, cap);
      if (!grown) {
        free(buf);
        pclose(p);
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
  int rc = pclose(p);
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
  FILE *p = popen("/usr/bin/pbcopy", "w");
  if (!p) {
    return -1;
  }
  if (len > 0) {
    fwrite(ptr, 1, (size_t)len, p);
  }
  int rc = pclose(p);
  cache_reset(); // 下次读要反映刚写入的内容
  return rc == 0 ? 0 : -1;
}
