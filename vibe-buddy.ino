// VibeBuddy on a Waveshare ESP32-S3-RLCD-4.2 (no touch).
//
// The box speaks VibeBuddy Protocol v1 over the native USB serial port and
// draws a handful of card screens on the 400x300 one-bit reflective LCD.
// vibebuddyd does all the agent watching; this firmware only renders what it
// sends. Protocol notes: docs/protocol.md in second-state/vibebuddy.

#include <Arduino.h>

#include "ui.h"
#include "vb_protocol.h"

#define VB_DEBUG_RX 0  // print every received line, handy while bringing up

// The daemon treats a device that shows nothing for 15 s as gone.
static const uint32_t LINK_TIMEOUT_MS = 15000;
static const uint32_t DONE_LINGER_MS = 5000;
static const uint32_t BLINK_MS = 550;
static const uint32_t TICK_MS = 1000;

// Printed at boot and again in answer to device.hello. The marker "DISPLAY
// READY BUILD " is how vibebuddyd decides this is its own firmware; without it
// the box is left alone as foreign firmware.
static const char *const FIRMWARE_BUILD = "rlcd-0.1";
static const char *const FIRMWARE_VERSION = "0.6.1"; // report current, so no update is offered

static VbUi ui;
static VbEvent event;

static char line_buf[2048];
static size_t line_len = 0;
static bool line_overflow = false;

static uint32_t last_rx_ms = 0;
static uint32_t last_tick_ms = 0;
static uint32_t last_blink_ms = 0;
static uint32_t done_until = 0;  // 0 = no lingering done/failed screen
static bool dirty = true;

// --- serial ------------------------------------------------------------------

static void print_banner() {
  Serial.print("DISPLAY READY BUILD ");
  Serial.println(FIRMWARE_BUILD);
  Serial.print("FIRMWARE VERSION ");
  Serial.println(FIRMWARE_VERSION);
  Serial.println("MODE DUTY");
  Serial.println("VOLUME 60");
  Serial.println("TOUCH NONE");
}

// --- turning events into screens ---------------------------------------------

static VbStatus status_of(const char *s) {
  if (strcmp(s, "input_required") == 0) return VB_INPUT;
  if (strcmp(s, "done") == 0) return VB_DONE;
  if (strcmp(s, "failed") == 0) return VB_FAILED;
  if (strcmp(s, "working") == 0) return VB_WORKING;
  return VB_READY;
}

static VbStatus status_from_name(const char *name) {
  if (strcmp(name, "task.start") == 0) return VB_WORKING;
  if (strcmp(name, "agent.input_required") == 0) return VB_INPUT;
  if (strcmp(name, "task.done") == 0) return VB_DONE;
  if (strcmp(name, "task.error") == 0 || strcmp(name, "agent.blocked") == 0) return VB_FAILED;
  return VB_READY;  // agent.idle and anything newer
}

static bool is_state_event(const char *name) {
  return strcmp(name, "task.start") == 0 || strcmp(name, "task.done") == 0 ||
         strcmp(name, "task.error") == 0 || strcmp(name, "agent.input_required") == 0 ||
         strcmp(name, "agent.idle") == 0 || strcmp(name, "agent.blocked") == 0;
}

static void agent_tag(const char *agent, char *out) {
  if (strcmp(agent, "claude-code") == 0) strcpy(out, "CC");
  else if (strcmp(agent, "codex") == 0) strcpy(out, "CX");
  else if (strcmp(agent, "opencode") == 0) strcpy(out, "OC");
  else if (strcmp(agent, "copilot") == 0) strcpy(out, "CP");
  else if (strcmp(agent, "pi") == 0) strcpy(out, "PI");
  else if (strcmp(agent, "github-actions") == 0) strcpy(out, "CI");
  else strcpy(out, "AI");
}

static void apply_event(const VbEvent &e) {
  // Plan usage rides along with the idle event; a state event without it (for
  // example while a task is open) leaves the last known numbers alone.
  if (is_state_event(e.event)) {
    ui.usageValid = e.usageValid;
    if (e.usageValid) {
      ui.usageHour = e.usageHour;
      ui.usageWeek = e.usageWeek;
      ui.usageMonth = e.usageMonth;
    }
    dirty = true;
  }

  if (e.statCount > 0) {
    ui.statCount = e.statCount > 3 ? 3 : e.statCount;
    for (int i = 0; i < ui.statCount; i++) {
      snprintf(ui.stats[i], sizeof(ui.stats[i]), "%s", e.stats[i]);
    }
    dirty = true;
  }

  if (!is_state_event(e.event)) return;

  if (e.taskCount > 0) {
    ui.cardCount = e.taskCount > 3 ? 3 : e.taskCount;
    const uint32_t now = millis();
    for (int i = 0; i < ui.cardCount; i++) {
      const VbTask &task = e.tasks[i];
      agent_tag(task.agent, ui.cards[i].agent);
      snprintf(ui.cards[i].title, sizeof(ui.cards[i].title), "%s", task.title);
      snprintf(ui.cards[i].project, sizeof(ui.cards[i].project), "%s", task.project);
      ui.cards[i].status = status_of(task.status);
      ui.cards[i].elapsed = task.elapsedS;
      ui.cards[i].tokS = task.tokS;
      ui.cards[i].baseMs = now;
    }
    ui.status = ui.cards[0].status;
    if (strcmp(e.event, "agent.input_required") == 0) {
      // The daemon republishes the cards while one waits; keep the alert up.
      ui.status = VB_INPUT;
      ui.cards[0].status = VB_INPUT;
    }
    ui.tasksTotal = e.tasksTotal > 0 ? e.tasksTotal : e.taskCount;
    ui.headline[0] = 0;
    done_until = 0;
  } else {
    // Nothing open any more: one quiet screen until the daemon says otherwise.
    ui.cardCount = 0;
    ui.tasksTotal = 0;
    ui.status = status_from_name(e.event);
    snprintf(ui.headline, sizeof(ui.headline), "%s", e.title);
    ui.headlineElapsed = 0;
    ui.headlineBaseMs = millis();
    done_until = (ui.status == VB_DONE || ui.status == VB_FAILED)
                     ? millis() + DONE_LINGER_MS
                     : 0;
  }
  dirty = true;
}

static void handle_line(const char *line) {
  if (line[0] == 0) return;

#if VB_DEBUG_RX
  Serial.print("RX ");
  Serial.println(line);
#endif

  if (!vb_parse_event(line, event)) return;

  last_rx_ms = millis();
  if (ui.noLink) {
    ui.noLink = false;
    dirty = true;
  }

  if (strcmp(event.event, "device.hello") == 0) {
    print_banner();
    return;
  }
  if (strcmp(event.event, "device.heartbeat") == 0) {
    if (event.hour >= 0) ui.hour = event.hour;
    return;
  }
  if (strcmp(event.event, "device.volume") == 0) {
    Serial.print("VOLUME ");
    Serial.println(60);
    return;
  }
  apply_event(event);
}

static void poll_serial() {
  while (Serial.available() > 0) {
    const int c = Serial.read();
    if (c < 0) break;
    if (c == '\n') {
      if (!line_overflow && line_len > 0) {
        line_buf[line_len] = 0;
        handle_line(line_buf);
      }
      line_len = 0;
      line_overflow = false;
    } else if (c != '\r') {
      if (line_len < sizeof(line_buf) - 1) {
        line_buf[line_len++] = (char)c;
      } else {
        line_overflow = true;
      }
    }
  }
}

// --- loop --------------------------------------------------------------------

static void advance_elapsed() {
  const uint32_t now = millis();
  for (int i = 0; i < ui.cardCount; i++) {
    ui.cards[i].elapsed += (long)((now - ui.cards[i].baseMs) / 1000);
    ui.cards[i].baseMs = now;
  }
  if (ui.headline[0]) {
    ui.headlineElapsed += (long)((now - ui.headlineBaseMs) / 1000);
    ui.headlineBaseMs = now;
  }
}

void setup() {
  // A line with six task cards is over 700 bytes. Drawing the screen blocks
  // the loop long enough that the default USB serial ring buffer overflows, and
  // a line cut in half parses as fewer cards, so give it room.
  Serial.setRxBufferSize(8192);
  Serial.begin(115200);
  delay(150);

  ui.noLink = false;
  ui.status = VB_READY;
  ui.cardCount = 0;
  ui.statCount = 0;
  ui.tasksTotal = 0;
  ui.hour = -1;
  ui.headline[0] = 0;
  ui.usageValid = false;

  print_banner();
  ui_begin();

  last_rx_ms = millis();
  last_tick_ms = millis();
  last_blink_ms = millis();
  dirty = true;
}

void loop() {
  poll_serial();

  const uint32_t now = millis();

  if (!ui.noLink && (uint32_t)(now - last_rx_ms) > LINK_TIMEOUT_MS) {
    ui.noLink = true;
    dirty = true;
  }

  if ((uint32_t)(now - last_tick_ms) >= TICK_MS) {
    last_tick_ms = now;
    dirty = true;
  }

  if (done_until != 0 && (int32_t)(now - done_until) >= 0) {
    done_until = 0;
    ui.status = VB_READY;
    ui.headline[0] = 0;
    dirty = true;
  }

  if (ui.status == VB_INPUT && (uint32_t)(now - last_blink_ms) >= BLINK_MS) {
    last_blink_ms = now;
    ui.blink = !ui.blink;
    dirty = true;
  }

  if (dirty) {
    advance_elapsed();
    ui_render(ui);
    dirty = false;
  }
}
