#!/usr/bin/env node
/**
 * Zigbee2MQTT 2.x staggered OTA runner (MQTT API — Z2M 2.x has no REST API).
 *
 * Prerequisite:  ssh -N -f -L 1883:127.0.0.1:1883 pi502
 *
 * Usage:
 *   node ota-runner.mjs check [--json]   read-only: which devices have pending updates
 *   node ota-runner.mjs run [--dry-run]  staggered update run
 *
 * Scheduling: one prefix group (first word of friendly name) at a time,
 * alphabetical. Max CONCURRENCY_MAINS in flight (CONCURRENCY_BATTERY if the
 * group contains any non-Mains device). A device is done when: the update
 * response arrives, its state topic flips updating->idle (ok) or
 * updating->available (failed), or TIMEOUT_MIN elapses (stalled). Z2M has no
 * cross-device queue; this script enforces it.
 *
 * Excluded: coordinator, disabled, interviewing, !supports_ota.
 *
 * Env: MQTT_URL (mqtt://127.0.0.1:1883), MQTT_BASE_TOPIC (zigbee2mqtt),
 *      CONCURRENCY_MAINS (5), CONCURRENCY_BATTERY (2), CHECK_CONCURRENCY (5),
 *      TIMEOUT_MIN (45), CHECK_TIMEOUT_S (60), REPORT_EVERY_MS (60000)
 *
 * Log protocol (one TAG per line):
 *   CONNECTED LIST CHECK CHECK_RESULT PLAN PENDING GROUP START DONE STATUS RESULT END ERROR
 * Exit codes: 0 = ok, 1 = setup/connection error, 3 = run completed with failures.
 */

import mqtt from "mqtt";

const BASE = process.env.MQTT_BASE_TOPIC || "zigbee2mqtt";
const URL = process.env.MQTT_URL || "mqtt://127.0.0.1:1883";
const MAINS_CONC = Number(process.env.CONCURRENCY_MAINS || 5);
const BATTERY_CONC = Number(process.env.CONCURRENCY_BATTERY || 2);
const CHECK_CONC = Number(process.env.CHECK_CONCURRENCY || 5);
const UPDATE_TIMEOUT_MS = Number(process.env.TIMEOUT_MIN || 45) * 60_000;
const CHECK_TIMEOUT_MS = Number(process.env.CHECK_TIMEOUT_S || 60) * 1000;
const REPORT_EVERY_MS = Number(process.env.REPORT_EVERY_MS || 60_000);

const mode = process.argv[2] ?? "check";
const dryRun = process.argv.includes("--dry-run");
const asJson = process.argv.includes("--json");
if (!["check", "run"].includes(mode)) {
  console.error("usage: ota-runner.mjs check|run [--dry-run] [--json]");
  process.exit(2);
}

const log = (tag, ...args) => console.log(tag, ...args.filter((a) => a !== "" && a !== undefined).join(" "));
const startedAt = Date.now();
const elapsed = () => {
  const s = Math.floor((Date.now() - startedAt) / 1000);
  return `${Math.floor(s / 60)}m${String(s % 60).padStart(2, "0")}s`;
};

/** Zigbee2MQTT error strings carry the device name as the last quoted token. */
function lastQuotedName(err) {
  if (!err) return null;
  const m = [...err.matchAll(/'([^']+)'/g)].map((x) => x[1]);
  return m.length ? m[m.length - 1] : null;
}

let phase = "setup"; // setup -> checking -> plan -> running -> done
let gotDeviceList = false;
let listTimer = null;

const devices = [];        // retained bridge/devices payload
const meta = new Map();    // name -> { power, model, manufacturer }
const checkState = new Map(); // name -> { update_available, skipped?, error?, installed_version?, latest_version?, release_notes? }
const checkQueued = new Set();
const checkInFlight = new Set();
const checkTimers = new Map();
const inFlight = new Map(); // name -> { startedAt, progress, lastState, timer }
const results = new Map();  // name -> { status: ok|failed|stalled, from?, to?, error?, via, durationMs }
const groups = [];          // [{ prefix, names, queue, conc, battery }]
let gi = 0;

const client = mqtt.connect(URL, { reconnectPeriod: 2000, resubscribe: true });

client.on("error", (e) => log("ERROR", `mqtt: ${e.message}`));
setTimeout(() => die("not connected to MQTT broker within 30s — is the ssh tunnel up? (ssh -N -f -L 1883:127.0.0.1:1883 pi502)"), 30_000);

client.on("connect", () => {
  client.subscribe([
    `${BASE}/bridge/devices`,
    `${BASE}/+`,
    `${BASE}/bridge/response/device/ota_update/check`,
    `${BASE}/bridge/response/device/ota_update/update`,
  ]);
  log("CONNECTED");
  if (!gotDeviceList) listTimer = setTimeout(() => die(`no retained ${BASE}/bridge/devices received within 30s`), 30_000);
});

client.on("message", (topic, payload) => {
  const body = payload.toString();
  if (topic === `${BASE}/bridge/devices`) return onDeviceList(body);
  if (topic === `${BASE}/bridge/response/device/ota_update/check`) return onJson(body, onCheckResponse);
  if (topic === `${BASE}/bridge/response/device/ota_update/update`) return onJson(body, onUpdateResponse);
  const m = topic.match(new RegExp(`^${BASE}/([^/]+)$`));
  if (m) onDeviceState(m[1], body);
});

function onJson(body, fn) {
  try { fn(JSON.parse(body)); } catch { /* ignore malformed */ }
}

function die(msg) {
  log("ERROR", msg);
  process.exit(1);
}

function onDeviceList(body) {
  if (gotDeviceList) return; // retained redelivery after reconnect
  let list;
  try { list = JSON.parse(body); } catch (e) { return log("ERROR", `bridge/devices: bad JSON: ${e.message}`); }
  gotDeviceList = true;
  if (listTimer) clearTimeout(listTimer);
  for (const d of list) {
    devices.push(d);
    meta.set(d.friendly_name, { power: d.power_source, model: d.model_id, manufacturer: d.manufacturer });
    log("LIST", d.friendly_name, `model=${d.model_id}`, `power=${d.power_source}`, `supports_ota=${d.definition?.supports_ota ?? false}`, `disabled=${d.disabled}`);
  }
  log("LIST", `total=${list.length}`);
  if (phase === "setup") beginChecks();
}

// ---------------------------------------------------------------- discovery

function beginChecks() {
  phase = "checking";
  for (const d of devices) {
    const name = d.friendly_name;
    if (d.type === "Coordinator" || d.disabled || d.interviewing || !d.definition?.supports_ota) {
      checkState.set(name, { update_available: false, skipped: true });
      continue;
    }
    checkQueued.add(name);
  }
  log("CHECK", `starting eligible=${checkQueued.size}`);
  pumpChecks();
}

function pumpChecks() {
  if (phase !== "checking") return;
  for (const name of [...checkQueued]) {
    if (checkInFlight.size >= CHECK_CONC) break;
    checkQueued.delete(name);
    checkInFlight.add(name);
    client.publish(`${BASE}/bridge/request/device/ota_update/check`, JSON.stringify({ id: name }));
    checkTimers.set(name, setTimeout(
      () => resolveCheck(name, { update_available: false, error: "check timeout" }),
      CHECK_TIMEOUT_MS,
    ));
    log("CHECK", name);
  }
  if (!checkQueued.size && !checkInFlight.size) finishChecks();
}

function resolveCheck(name, state) {
  if (!checkInFlight.has(name)) return;
  checkInFlight.delete(name);
  const t = checkTimers.get(name);
  if (t) clearTimeout(t);
  const prev = checkState.get(name) || {};
  checkState.set(name, { ...prev, ...state });
  pumpChecks();
}

function onCheckResponse(obj) {
  if (obj.status === "ok" && obj.data?.id) {
    resolveCheck(obj.data.id, {
      update_available: !!obj.data.update_available,
      release_notes: obj.data.release_notes,
    });
  } else if (obj.status === "error") {
    const name = lastQuotedName(obj.error);
    if (name) resolveCheck(name, { update_available: false, error: obj.error });
  }
}

function isPending(d) {
  const cs = checkState.get(d.friendly_name);
  return !d.disabled && d.type !== "Coordinator" && !d.interviewing && cs?.update_available === true;
}

function finishChecks() {
  phase = "plan";
  const pending = devices.filter(isPending).map((d) => d.friendly_name);

  const gmap = new Map();
  for (const name of pending) {
    const prefix = name.split(" ")[0];
    if (!gmap.has(prefix)) gmap.set(prefix, []);
    gmap.get(prefix).push(name);
  }
  for (const [prefix, names] of gmap) {
    const battery = names.filter((n) => meta.get(n)?.power !== "Mains (single phase)").length;
    groups.push({ prefix, names, queue: [...names], conc: battery ? BATTERY_CONC : MAINS_CONC, battery });
  }
  groups.sort((a, b) => a.prefix.localeCompare(b.prefix));

  for (const d of devices) {
    const cs = checkState.get(d.friendly_name) || {};
    const st = cs.skipped ? "skipped" : cs.error ? `check-failed(${cs.error})` : cs.update_available ? "PENDING" : "up-to-date";
    log("CHECK_RESULT", d.friendly_name, st, `installed=${cs.installed_version ?? "?"}`, `latest=${cs.latest_version ?? "?"}`, d.model_id);
  }
  log("PLAN", `pending=${pending.length} groups=${groups.length}`);
  for (const g of groups) log("PLAN", `group=${g.prefix} count=${g.names.length} concurrency=${g.conc} non_mains=${g.battery}`);

  if (mode === "check") {
    for (const name of pending) {
      const d = devices.find((x) => x.friendly_name === name);
      const cs = checkState.get(name);
      log("PENDING", name, `model=${d?.model_id}`, `power=${d?.power_source}`, `installed=${cs?.installed_version ?? "?"}`, `latest=${cs?.latest_version ?? "?"}`, cs?.release_notes ?? "");
    }
    if (asJson) {
      console.log("JSON", JSON.stringify(pending.map((name) => {
        const d = devices.find((x) => x.friendly_name === name);
        const cs = checkState.get(name) || {};
        return {
          name, model: d?.model_id, power_source: d?.power_source,
          installed_version: cs.installed_version ?? null, latest_version: cs.latest_version ?? null,
          release_notes: cs.release_notes ?? null, group: name.split(" ")[0],
        };
      })));
    }
    log("END", `check complete pending=${pending.length} took=${elapsed()}`);
    process.exit(0);
  }

  if (dryRun) {
    log("END", "dry-run: no updates made");
    process.exit(0);
  }

  phase = "running";
  // Devices already updating (e.g. started from the UI) count against the budget.
  for (const [name, f] of inFlight) {
    const g = groups.find((g) => g.queue.includes(name));
    if (g) g.queue = g.queue.filter((n) => n !== name);
    log("START", name, "(already in progress, adopted)");
  }
  pump();
}

// ------------------------------------------------------------------- update

function fire(name) {
  inFlight.set(name, {
    startedAt: Date.now(),
    progress: 0,
    lastState: "available",
    timer: setTimeout(() => complete(name, "stalled", { error: `no completion signal within ${Math.round(UPDATE_TIMEOUT_MS / 60000)}m` }), UPDATE_TIMEOUT_MS),
  });
  client.publish(`${BASE}/bridge/request/device/ota_update/update`, JSON.stringify({ id: name }));
  log("START", name);
}

function complete(name, status, extra = {}) {
  if (results.has(name)) return;
  const f = inFlight.get(name);
  if (f) {
    clearTimeout(f.timer);
    inFlight.delete(name);
  }
  const durationMs = f ? Date.now() - f.startedAt : 0;
  results.set(name, { status, via: "signal", ...extra, durationMs });
  log("DONE", name, status, extra.from !== undefined && extra.to !== undefined ? `${extra.from}->${extra.to}` : "", extra.error ? `error=${extra.error}` : "", `took=${Math.round(durationMs / 1000)}s`);
  pump();
}

function onUpdateResponse(obj) {
  if (obj.status === "ok" && obj.data?.id) {
    if (inFlight.has(obj.data.id)) {
      complete(obj.data.id, "ok", { from: obj.data.from?.file_version, to: obj.data.to?.file_version, via: "response" });
    }
  } else if (obj.status === "error") {
    const name = lastQuotedName(obj.error);
    if (name && inFlight.has(name)) complete(name, "failed", { error: obj.error, via: "response" });
  }
}

function onDeviceState(name, body) {
  let obj;
  try { obj = JSON.parse(body); } catch { return; }
  const u = obj.update;
  if (!u || typeof u !== "object") return;

  const rec = checkState.get(name);
  if (rec && !rec.skipped) {
    if (u.installed_version !== undefined) rec.installed_version = u.installed_version;
    if (u.latest_version !== undefined) rec.latest_version = u.latest_version;
    if (u.latest_release_notes) rec.release_notes = u.latest_release_notes;
  }

  const f = inFlight.get(name);
  if (f) {
    const prev = f.lastState;
    f.lastState = u.state;
    if (u.state === "updating" && typeof u.progress === "number") f.progress = u.progress;
    // Backstop for missed responses: updating->idle = ok, updating->available = failed.
    // (Also fires on idle reached via a missed "updating" publish; the final
    // re-check is authoritative, so an over-optimistic ok here is recoverable.)
    if (u.state === "idle" && prev !== "idle") complete(name, "ok", { to: u.installed_version, via: "state" });
    else if (u.state === "available" && prev === "updating") complete(name, "failed", { error: "update aborted (state back to available)", via: "state" });
    return;
  }

  // Adopt devices that are already updating (started from the UI) and belong to a group.
  if (u.state === "updating" && phase === "running") {
    const g = groups.find((g) => g.queue.includes(name));
    if (g) {
      g.queue = g.queue.filter((n) => n !== name);
      inFlight.set(name, {
        startedAt: Date.now(), progress: u.progress ?? 0, lastState: "updating",
        timer: setTimeout(() => complete(name, "stalled", { error: "timeout (adopted)" }), UPDATE_TIMEOUT_MS),
      });
      log("START", name, "(adopted: already updating)");
      pump();
    }
  }
}

function pump() {
  if (phase !== "running") return;
  while (gi < groups.length) {
    const g = groups[gi];
    if (!g.queue.length && inFlight.size === 0) {
      const s = { ok: 0, failed: 0, stalled: 0 };
      for (const n of g.names) {
        const r = results.get(n);
        if (r) s[r.status === "ok" ? "ok" : r.status === "stalled" ? "stalled" : "failed"]++;
      }
      log("GROUP", `${g.prefix} complete ok=${s.ok} failed=${s.failed} stalled=${s.stalled}`);
      gi++;
      continue;
    }
    while (inFlight.size < g.conc && g.queue.length) fire(g.queue.shift());
    return; // wait for completions
  }
  if (inFlight.size === 0) finishRun();
}

function finishRun() {
  phase = "done";
  for (const [name, r] of results) {
    log("RESULT", name, r.status, r.from !== undefined && r.to !== undefined ? `${r.from}->${r.to}` : "", r.error ?? "", `took=${Math.round(r.durationMs / 1000)}s`);
  }
  const failed = [...results.values()].filter((r) => r.status !== "ok");
  log("END", `ok=${results.size - failed.length} failed=${failed.length} took=${elapsed()}`);
  process.exit(failed.length ? 3 : 0);
}

// Periodic status while updates run: group, done count, in-flight progress.
setInterval(() => {
  if (phase !== "running" || !inFlight.size) return;
  const g = groups[gi];
  const done = g ? g.names.filter((n) => results.has(n)).length : 0;
  const parts = [...inFlight].map(([n, f]) => `${n}=${f.progress ?? "?"}%`).join(" ");
  log("STATUS", `group=${g?.prefix ?? "?"} done=${done}/${g?.names.length ?? "?"} in_flight=${inFlight.size} total_done=${results.size} elapsed=${elapsed()} | ${parts}`);
}, REPORT_EVERY_MS);
