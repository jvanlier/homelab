---
name: z2m-ota
description: Run staggered OTA firmware updates on the home Zigbee2MQTT bridge (pi502) over MQTT. Use when the user asks to update zigbee/z2m devices or device firmware.
---

Staggered OTA updates for the home Zigbee2MQTT bridge. Z2M 2.x has **no REST API** (`/api/*` on the UI port 404s by design); drive the same MQTT API the Z2M UI uses, through the runner script.

## Facts

- Z2M runs in container `zigbee2mqtt` (image `koenkk/zigbee2mqtt` 2.x) on `pi502` (192.168.1.138, ssh alias `pi502` in ~/.ssh/config). UI: http://192.168.1.138:8002.
- MQTT broker: container `mqtt` (eclipse-mosquitto, no auth) on pi502, bound to **127.0.0.1:1883 — loopback only**, not reachable from the LAN. Always work through an ssh port forward.
- MQTT base topic: `zigbee2mqtt`.
- Make no changes to the homelab repo or on the Pi; all work happens in `/tmp/z2m-ota` on the machine running this skill.

## Runner

[reference/ota-runner.mjs](reference/ota-runner.mjs) — implements discovery, staggering, all waiting, and log-based reporting. Env knobs (defaults are correct, only change on request): `CONCURRENCY_MAINS` (5), `CONCURRENCY_BATTERY` (2), `TIMEOUT_MIN` (45), `CHECK_TIMEOUT_S` (60).

## Workflow

### 1. Setup

```bash
ssh -N -f -L 1883:127.0.0.1:1883 pi502   # broker tunnel; killed in step 5
mkdir -p /tmp/z2m-ota && cd /tmp/z2m-ota
cp <skill-dir>/reference/ota-runner.mjs .
npm init -y >/dev/null 2>&1 && npm install mqtt --no-audit --no-fund
```

### 2. Discover (read-only), then get a go/no-go

```bash
nohup node ota-runner.mjs check --json > check.log 2>&1 &
```

Takes a few minutes (one read-only check per device; asleep battery devices run until timeout). Tail `check.log`; when you see `END`, present to the user: pending count, per-`PLAN` groups (name, size, concurrency, non-mains count), and the `PENDING` lines (device, installed → latest). Also flag any `check-failed` devices. **Wait for explicit approval before step 3.**

### 3. Run (background, unattended)

```bash
nohup node ota-runner.mjs run > run.log 2>&1 &
```

The script does all the waiting itself: one prefix group (first word of the friendly name) at a time, alphabetical; max 5 in flight per group (2 if it contains any non-mains device); a device completes when the MQTT update response arrives, or its state topic flips `updating`→`idle` (ok) / back to `available` (failed), or after 45 min (stalled). Slots free as devices finish. It automatically excludes the coordinator, disabled, interviewing, and non-OTA-capable devices. A failed battery-device OTA usually self-heals on its next wake; worst case is re-pairing.

### 4. Poll and report (you do this)

Poll `run.log` (e.g. `tail -25 run.log`) every 5–10 minutes. Report to the user:

- at start: the plan (groups, sizes, expected duration)
- after each `GROUP` line: which group finished, its ok/failed/stalled counts, elapsed
- immediately on any `DONE … failed` or `stalled`
- every 15 min while a group is still running: the latest `STATUS` line (in-flight devices + progress %), elapsed, rough remaining
- at `END`: the full `RESULT` table (device, status, from→to version, duration) plus the list of failed/stalled devices

### 5. Verify and clean up

```bash
nohup node ota-runner.mjs check > recheck.log 2>&1 &   # authoritative verification
pkill -f "ssh -N -f -L 1883"                            # after the re-check
```

The re-check `PENDING` list must be empty (or match intentionally skipped devices). If the run had failures/stalls, tell the user they remain on their old firmware and offer a retry pass — a plain `run` re-checks first, so only stragglers get updated.

## MQTT reference (only if the script fails and you must debug)

- Device list: retained topic `zigbee2mqtt/bridge/devices` → JSON array with `friendly_name`, `ieee_address`, `type` (`"Coordinator"` is the coordinator), `disabled`, `power_source` (`"Battery"` / `"Mains (single phase)"`), `interviewing`, `definition.supports_ota`.
- Check: publish `{"id": "<friendly_name>"}` to `zigbee2mqtt/bridge/request/device/ota_update/check` → response on `zigbee2mqtt/bridge/response/device/ota_update/check`: `{status:"ok", data:{id, update_available, …}}` or `{status:"error", data:{}, error:"… 'Device Name' …"}`.
- Update: publish `{"id": "<friendly_name>"}` to `zigbee2mqtt/bridge/request/device/ota_update/update` → response on `zigbee2mqtt/bridge/response/device/ota_update/update`: ok → `{status:"ok", data:{id, from:{file_version}, to:{file_version}}}`; error → `data` is empty, the device name is only in the `error` text (last quoted token).
- State: `zigbee2mqtt/<friendly_name>` → `update: {state:"idle"|"available"|"updating"|"scheduled", progress, remaining, installed_version, latest_version, latest_release_notes}`. Not retained; published on change; `progress` is a 0–100 percentage.
- Z2M has **no cross-device update queue** — all concurrency control lives in the runner.
