#include "vb_protocol.h"

#include <stdlib.h>
#include <string.h>

// --- a very small JSON reader ------------------------------------------------
//
// Deliberately not a general parser: it walks one object, finds the keys this
// box knows, and skips everything else. Values are spans [begin, end), end
// exclusive and just past the value (past the closing quote for strings).

static const char *skip_ws(const char *p, const char *e) {
  while (p < e && (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')) p++;
  return p;
}

static const char *skip_str(const char *p, const char *e) {
  p++;  // opening quote
  while (p < e) {
    if (*p == '\\') {
      p += 2;
      continue;
    }
    if (*p == '"') return p + 1;
    p++;
  }
  return e;
}

static const char *skip_val(const char *p, const char *e, int depth) {
  p = skip_ws(p, e);
  if (p >= e || depth > 8) return e;
  if (*p == '"') return skip_str(p, e);
  if (*p == '{' || *p == '[') {
    const char close = (*p == '{') ? '}' : ']';
    p++;
    while (p < e) {
      p = skip_ws(p, e);
      if (p >= e) return e;
      if (*p == close) return p + 1;
      if (close == '}') {
        if (*p != '"') return e;
        p = skip_str(p, e);
        p = skip_ws(p, e);
        if (p >= e || *p != ':') return e;
        p++;
      }
      p = skip_val(p, e, depth + 1);
      p = skip_ws(p, e);
      if (p < e && *p == ',') p++;
    }
    return e;
  }
  while (p < e && *p != ',' && *p != '}' && *p != ']') p++;
  return p;
}

// Finds `key` in the object that starts at `b`; hands back its value's span.
static bool obj_find(const char *b, const char *e, const char *key,
                     const char **vb, const char **ve) {
  b = skip_ws(b, e);
  if (b >= e || *b != '{') return false;
  const char *p = b + 1;
  const size_t klen = strlen(key);
  while (p < e) {
    p = skip_ws(p, e);
    if (p >= e || *p == '}' || *p != '"') return false;
    const char *key_end = skip_str(p, e);
    const size_t len = (size_t)(key_end - p - 2);
    const bool match = len == klen && strncmp(p + 1, key, klen) == 0;
    p = skip_ws(key_end, e);
    if (p >= e || *p != ':') return false;
    p++;
    const char *value_begin = skip_ws(p, e);
    const char *value_end = skip_val(value_begin, e, 0);
    if (match) {
      *vb = value_begin;
      *ve = value_end;
      return true;
    }
    p = skip_ws(value_end, e);
    if (p < e && *p == ',') {
      p++;
      continue;
    }
    return false;
  }
  return false;
}

static void append_utf8(char *out, int &o, int cap, unsigned cp) {
  if (cp < 0x80) {
    if (o < cap - 1) out[o++] = (char)cp;
  } else if (cp < 0x800) {
    if (o < cap - 2) {
      out[o++] = (char)(0xC0 | (cp >> 6));
      out[o++] = (char)(0x80 | (cp & 0x3F));
    }
  } else {
    if (o < cap - 3) {
      out[o++] = (char)(0xE0 | (cp >> 12));
      out[o++] = (char)(0x80 | ((cp >> 6) & 0x3F));
      out[o++] = (char)(0x80 | (cp & 0x3F));
    }
  }
}

// Copies a JSON string (the span starts at its opening quote) into `out`.
static void read_str(const char *b, const char *e, char *out, int cap) {
  int o = 0;
  if (cap <= 0) return;
  out[0] = 0;
  if (b >= e || *b != '"') return;
  b++;
  while (b < e && *b != '"') {
    char c = *b;
    if (c == '\\' && b + 1 < e) {
      b++;
      switch (*b) {
        case 'n': c = '\n'; break;
        case 't': c = '\t'; break;
        case 'r': c = '\r'; break;
        case 'b': c = '\b'; break;
        case 'f': c = '\f'; break;
        case 'u': {
          unsigned cp = 0;
          if (b + 5 <= e) {
            for (int i = 1; i <= 4; i++) {
              const char h = b[i];
              cp <<= 4;
              if (h >= '0' && h <= '9') cp |= (unsigned)(h - '0');
              else if (h >= 'a' && h <= 'f') cp |= (unsigned)(h - 'a' + 10);
              else if (h >= 'A' && h <= 'F') cp |= (unsigned)(h - 'A' + 10);
            }
            b += 4;
          }
          append_utf8(out, o, cap, cp);
          b++;
          continue;
        }
        default: c = *b; break;
      }
    }
    if (o < cap - 1) out[o++] = c;
    b++;
  }
  out[o] = 0;
}

static bool read_long(const char *b, const char *e, long &out) {
  b = skip_ws(b, e);
  if (b >= e) return false;
  char tmp[16];
  int n = 0;
  while (b < e && n < (int)sizeof(tmp) - 1 &&
         ((*b >= '0' && *b <= '9') || (*b == '-' && n == 0))) {
    tmp[n++] = *b++;
  }
  if (n == 0) return false;
  tmp[n] = 0;
  out = strtol(tmp, nullptr, 10);
  return true;
}

struct ArrIter {
  const char *p;
  const char *e;
};

static bool arr_next(ArrIter &it, const char **ib, const char **ie) {
  it.p = skip_ws(it.p, it.e);
  if (it.p >= it.e || *it.p == ']') return false;
  *ib = it.p;
  *ie = skip_val(it.p, it.e, 0);
  it.p = skip_ws(*ie, it.e);
  if (it.p < it.e && *it.p == ',') it.p++;
  return true;
}

bool vb_parse_event(const char *line, VbEvent &out) {
  memset(&out, 0, sizeof(out));
  out.hour = -1;

  const char *b = strchr(line, '{');
  if (b == nullptr) return false;
  const char *e = line + strlen(line);
  const char *vb = nullptr;
  const char *ve = nullptr;

  long version = 0;
  if (!obj_find(b, e, "version", &vb, &ve)) return false;
  if (!read_long(vb, ve, version) || version != 1) return false;

  if (!obj_find(b, e, "event", &vb, &ve)) return false;
  read_str(vb, ve, out.event, (int)sizeof(out.event));
  if (out.event[0] == 0) return false;

  if (obj_find(b, e, "title", &vb, &ve)) {
    read_str(vb, ve, out.title, (int)sizeof(out.title));
  }

  long n = 0;
  if (obj_find(b, e, "tasks_total", &vb, &ve) && read_long(vb, ve, n)) {
    out.tasksTotal = (int)n;
  }

  if (obj_find(b, e, "tasks", &vb, &ve) && *vb == '[') {
    ArrIter it{vb + 1, ve};
    const char *ib;
    const char *ie;
    while (out.taskCount < VB_MAX_TASKS && arr_next(it, &ib, &ie)) {
      VbTask &t = out.tasks[out.taskCount];
      const char *fb;
      const char *fe;
      if (obj_find(ib, ie, "id", &fb, &fe)) read_str(fb, fe, t.id, (int)sizeof(t.id));
      if (obj_find(ib, ie, "agent", &fb, &fe)) read_str(fb, fe, t.agent, (int)sizeof(t.agent));
      if (obj_find(ib, ie, "title", &fb, &fe)) read_str(fb, fe, t.title, (int)sizeof(t.title));
      if (obj_find(ib, ie, "project", &fb, &fe)) read_str(fb, fe, t.project, (int)sizeof(t.project));
      if (obj_find(ib, ie, "status", &fb, &fe)) read_str(fb, fe, t.status, (int)sizeof(t.status));
      if (obj_find(ib, ie, "elapsed_s", &fb, &fe)) read_long(fb, fe, t.elapsedS);
      out.taskCount++;
    }
    if (out.tasksTotal < out.taskCount) out.tasksTotal = out.taskCount;
  }

  if (obj_find(b, e, "stats", &vb, &ve) && *vb == '[') {
    ArrIter it{vb + 1, ve};
    const char *ib;
    const char *ie;
    while (out.statCount < 3 && arr_next(it, &ib, &ie)) {
      read_str(ib, ie, out.stats[out.statCount], VB_STAT_LEN);
      out.statCount++;
    }
  }

  if (obj_find(b, e, "hour", &vb, &ve) && read_long(vb, ve, n)) out.hour = (int)n;
  if (obj_find(b, e, "day", &vb, &ve) && read_long(vb, ve, n)) out.day = (int)n;

  if (out.title[0] == 0 && out.taskCount > 0) {
    snprintf(out.title, sizeof(out.title), "%s", out.tasks[0].title);
  }
  return true;
}
