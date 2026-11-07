// VibeBuddy Protocol v1 reader: the few fields this box draws.
//
// Lines from vibebuddyd are single-line NDJSON, at most 1024 bytes because this
// firmware does not announce TRANSFER 1. Only the fields below are used; every
// other field and event is skipped. A hand-rolled reader keeps the sketch free
// of a JSON library.
#pragma once

#include <Arduino.h>

#define VB_MAX_TASKS 6
#define VB_TITLE_LEN 64
#define VB_PROJECT_LEN 40
#define VB_AGENT_LEN 14
#define VB_STATUS_LEN 16
#define VB_EVENT_LEN 24
#define VB_STAT_LEN 40

struct VbTask {
  char id[10];
  char agent[VB_AGENT_LEN];
  char title[VB_TITLE_LEN];
  char project[VB_PROJECT_LEN];
  char status[VB_STATUS_LEN];
  long elapsedS;
};

struct VbEvent {
  char event[VB_EVENT_LEN];
  char title[VB_TITLE_LEN];
  int tasksTotal;
  int taskCount;
  VbTask tasks[VB_MAX_TASKS];
  int statCount;
  char stats[3][VB_STAT_LEN];
  int hour;  // device.heartbeat only; -1 when missing
  int day;   // YYYYMMDD, 0 when missing
};

// Fills `out` and returns true for a well-formed v1 message. Returns false for
// anything else, including a partial line, so the caller can ignore it.
bool vb_parse_event(const char *line, VbEvent &out);
