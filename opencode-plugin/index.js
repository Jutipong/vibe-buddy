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

    // A prompt starts (or restarts) a session's turn.
    await ctx.session.hook("prompt", (input) => {
      const dir = input && input.location && input.location.directory;
      send("working", input && (input.sessionID || (input.info && input.info.id)), dir);
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
            send("needs_input", sid, dir);
            continue;
          }
          if (type === "permission.replied") {
            send("working", sid, dir);
            continue;
          }

          if (!type.startsWith("session.")) continue;
          switch (type) {
            case "session.execution.started":
            case "session.step.started":
              send("working", sid, dir);
              break;
            case "session.execution.succeeded":
            case "session.idle":
              send("done", sid, dir);
              break;
            case "session.execution.failed":
            case "session.execution.interrupted":
              send("stopped", sid, dir);
              break;
            case "session.deleted":
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
