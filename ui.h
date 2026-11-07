// The box's only screen: 400x300, one bit per pixel, reflective.
//
// Everything is drawn on an Adafruit GFXcanvas1 and then pushed into the
// panel's own byte layout by the Waveshare driver (display_bsp). Ink is 1,
// paper is 0, which matches what the clock sketch this project grew out of did.
#pragma once

#include <Arduino.h>

enum VbStatus : uint8_t {
  VB_READY = 0,
  VB_WORKING,
  VB_INPUT,
  VB_DONE,
  VB_FAILED,
};

struct VbCard {
  char agent[8];  // CX, CC, OC, CP, PI, CI
  char title[64];
  char project[40];
  VbStatus status;
  long elapsed;            // seconds already elapsed when the line arrived
  unsigned long baseMs;    // millis() at that moment
};

struct VbUi {
  bool noLink;
  VbStatus status;         // used when there are no cards
  char headline[64];       // the title of that state
  long headlineElapsed;
  unsigned long headlineBaseMs;
  int cardCount;           // cards actually shown (at most 3)
  VbCard cards[3];
  int tasksTotal;          // tasks the daemon knows about
  int statCount;
  char stats[3][40];
  int hour;                // -1 when no heartbeat has arrived yet
  bool blink;              // the sketch flips this while a task needs input
};

void ui_begin();
void ui_render(const VbUi &ui);
