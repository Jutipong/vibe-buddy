// OpenCode plugin: tells vibebuddy-bridge what this session is doing.
//
// It is deliberately small. All the drawing and the serial link live in
// tools\bridge.ps1; this only turns OpenCode's signals into the five events
// that bridge understands: working, needs_input, done, stopped, session_end.
// A bridge that isn't running costs nothing: every post is fire-and-forget.
import { Plugin } from "@opencode/plugin";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const BRIDGE = process.env.VIBEBUDDY_BRIDGE || "http://127.0.0.1:7331";
const LOG_FILE = path.join(os.homedir(), ".config", "opencode", "plugins", "vibebuddy.log");

// Output speed, the same way go-usage measures it: the runtime streams text and
// reasoning deltas but no token counters until a step ends, so a two-second
// window of delta characters is divided by a chars-per-token factor.
const CHARS_PER_TOKEN = 3.5;
const SPEED_WINDOW_MS = 2000;
const SPEED_FRESH_MS = 1500;
const SPEED_MIN_SPAN_MS = 500;
const SPEED_POST_EVERY_MS = 1000;

function log(...args) {
  try {
    if (fs.existsSync(LOG_FILE) && fs.statSync(LOG_FILE).size > 512 * 1024) {
      fs.writeFileSync(LOG_FILE, "");
    }
    fs.appendFileSync(LOG_FILE, `${new Date().toISOString()} ${args.join(" ")}\n`);
  } catch {
    // never let logging break the agent
  }
}

function post(body) {
  // No await: OpenCode must not wait on a box, a cable, or a bridge.
  void fetch(`${BRIDGE}/v1/agent-hooks`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  }).catch(() => {});
}

export default Plugin.define({
  id: "vibebuddy",
  async setup(ctx) {
    // ctx.location is where this plugin host lives, not where each session
    // lives: on a shared OpenCode service every session would be labelled with
    // one project. Events carry their own location, so prefer that and only
    // fall back when the event has none.
    const fallback = (ctx.location && ctx.location.directory) || null;
    const send = (event, sessionID, directory) => {
      if (!sessionID) return;
      const cwd = directory || fallback || undefined;
      log("send", event, sessionID, cwd || "?");
      post({ agent: "opencode", session_id: sessionID, event, cwd });
    };

    // --- output speed -----------------------------------------------------
    const speed = new Map(); // session id -> { events: [{at, chars}], posted }
    // Sessions whose turn is still open. The bridge drops a session that has
    // not been heard from for 90 s, so these get a heartbeat while they live.
    const active = new Map(); // session id -> directory
    const HEARTBEAT_MS = 30000;

    const track = (sid, dir) => {
      if (sid) active.set(sid, dir || fallback || undefined);
    };
    const untrack = (sid) => {
      if (sid) active.delete(sid);
    };

    const heartbeat = setInterval(() => {
      for (const [sid, cwd] of active) {
        post({ agent: "opencode", session_id: sid, event: "working", cwd });
      }
    }, HEARTBEAT_MS);
    if (heartbeat.unref) heartbeat.unref();

    const speedStart = (sid) => {
      if (sid) speed.set(sid, { events: [], posted: 0 });
    };

    const speedPush = (sid, chars) => {
      if (!sid) return;
      const amount = Number(chars);
      if (!Number.isFinite(amount) || amount <= 0) return;
      let bucket = speed.get(sid);
      if (!bucket) {
        bucket = { events: [], posted: 0 };
        speed.set(sid, bucket);
      }
      const now = Date.now();
      bucket.events.push({ at: now, chars: amount });
      const floor = now - SPEED_WINDOW_MS;
      if (bucket.events.length > 64) {
        bucket.events = bucket.events.filter((event) => event.at >= floor);
      }
    };

    const speedRate = (sid) => {
      const bucket = speed.get(sid);
      if (!bucket || bucket.events.length === 0) return null;
      const now = Date.now();
      const events = bucket.events.filter((event) => event.at >= now - SPEED_WINDOW_MS);
      if (events.length === 0) return null;
      if (now - events[events.length - 1].at > SPEED_FRESH_MS) return null;
      const chars = events.reduce((total, event) => total + event.chars, 0);
      const span = Math.max(SPEED_MIN_SPAN_MS, events[events.length - 1].at - events[0].at);
      const rate = (chars / CHARS_PER_TOKEN / span) * 1000;
      return rate > 0 ? Math.round(rate * 10) / 10 : null;
    };

    const speedPost = (sid, directory) => {
      const bucket = speed.get(sid);
      if (!bucket) return;
      const now = Date.now();
      if (now - bucket.posted < SPEED_POST_EVERY_MS) return;
      const rate = speedRate(sid);
      if (rate == null) return;
      bucket.posted = now;
      post({
        agent: "opencode",
        session_id: sid,
        event: "working",
        cwd: directory || fallback || undefined,
        tok_s: rate,
      });
    };

    // A prompt starts (or restarts) a session's turn.
    await ctx.session.hook("prompt", (input) => {
      const dir = input && input.location && input.location.directory;
      const sid = input && (input.sessionID || (input.info && input.info.id));
      speedStart(sid);
      track(sid, dir);
      send("working", sid, dir);
    });

    // Every finished tool call is still the same turn; nothing to send, but it
    // keeps the turn alive if a host asks again.
    await ctx.tool.hook("execute.after", () => {});

    // Turn lifecycle from the session event stream.
    (async () => {
      try {
        for await (const ev of ctx.event.subscribe()) {
          const type = ev && ev.type;
          const sid = ev && ev.data && ev.data.sessionID;
          const dir = ev && ev.location && ev.location.directory;
          if (typeof type !== "string" || !sid) continue;

          // A permission prompt is the one moment the box must shout: the
          // agent cannot go on until the human answers.
          if (type === "permission.asked") {
            track(sid, dir);
            send("needs_input", sid, dir);
            continue;
          }
          if (type === "permission.replied") {
            track(sid, dir);
            send("working", sid, dir);
            continue;
          }

          if (!type.startsWith("session.")) continue;
          switch (type) {
            case "session.execution.started":
            case "session.step.started":
              speedStart(sid);
              track(sid, dir);
              send("working", sid, dir);
              break;
            case "session.text.delta":
            case "session.reasoning.delta": {
              const delta = ev && ev.data && ev.data.delta;
              if (typeof delta === "string" && delta.length > 0) {
                track(sid, dir);
                speedPush(sid, delta.length);
                speedPost(sid, dir);
              }
              break;
            }
            case "session.execution.succeeded":
            case "session.idle":
              speed.delete(sid);
              untrack(sid);
              send("done", sid, dir);
              break;
            case "session.execution.failed":
            case "session.execution.interrupted":
              speed.delete(sid);
              untrack(sid);
              send("stopped", sid, dir);
              break;
            case "session.deleted":
              speed.delete(sid);
              untrack(sid);
              send("session_end", sid, dir);
              break;
            default:
              if (type.includes("permission") || type.includes("question")) {
                log("unmapped", type);
              }
              break;
          }
        }
      } catch (e) {
        log("event stream ended", String((e && e.message) || e));
      }
    })();
  },
});
