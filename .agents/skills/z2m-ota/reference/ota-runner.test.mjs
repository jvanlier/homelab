import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { after, before, test } from "node:test";

const runner = join(dirname(fileURLToPath(import.meta.url)), "ota-runner.mjs");
let dir;

before(async () => {
  dir = await mkdtemp(join(tmpdir(), "z2m-ota-test-"));
  await writeFile(join(dir, "loader.mjs"), `
    export async function resolve(specifier, context, nextResolve) {
      if (specifier === "mqtt") return { url: new URL("./mqtt.mjs", import.meta.url).href, shortCircuit: true };
      return nextResolve(specifier, context);
    }
  `);
  await writeFile(join(dir, "mqtt.mjs"), `
    import { EventEmitter } from "node:events";
    export default { connect() {
      const client = new EventEmitter();
      const base = "zigbee2mqtt";
      const devices = ["Light A", "Light New", "Switch B"].map(friendly_name => ({
        friendly_name, type: "Router", power_source: "Mains (single phase)", definition: { supports_ota: true },
        disabled: friendly_name === "Light A" && process.env.SCENARIO === "ineligible"
      }));
      const send = (topic, body) => client.emit("message", topic, Buffer.from(JSON.stringify(body)));
      client.subscribe = () => setImmediate(() => send(base + "/bridge/devices", devices));
      client.publish = (topic, payload) => {
        const { id } = JSON.parse(payload);
        if (topic.endsWith("/check")) setImmediate(() => {
          if (id === "Light A" && ["preflight-error", "preflight-timeout", "external-failed"].includes(process.env.SCENARIO)) {
            if (process.env.SCENARIO === "external-failed") send(base + "/" + id, { update: { state: "updating", progress: 10 } });
            if (process.env.SCENARIO !== "preflight-timeout") send(base + "/bridge/response/device/ota_update/check", { status: "error", error: "Failed to check '" + id + "'" });
            return;
          }
          if (id === "Light A" && process.env.SCENARIO === "external-preflight") send(base + "/Switch B", { update: { state: "updating", progress: 10 } });
          if (id === "Light A" && process.env.SCENARIO === "transition") send(base + "/" + id, { update: { state: "available", installed_version: 1 } });
          send(base + "/bridge/response/device/ota_update/check", { status: "ok", data: { id, update_available: true } });
        });
        if (topic.endsWith("/update")) {
          console.log("MOCK_UPDATE", id);
          const state = update => send(base + "/" + id, { update });
          if (process.env.SCENARIO === "idle" || process.env.SCENARIO === "unchanged") {
            const update = process.env.SCENARIO === "idle" ? { state: "idle" } : { state: "updating", progress: 25 };
            setInterval(() => state(update), 20);
          } else if (process.env.SCENARIO === "progress") {
            let progress = 0;
            const timer = setInterval(() => state({ state: "updating", progress: ++progress }), 50);
            setTimeout(() => {
              clearInterval(timer);
              send(base + "/bridge/response/device/ota_update/update", { status: "ok", data: { id } });
            }, 600);
          } else if (process.env.SCENARIO === "external-running") {
            setTimeout(() => send(base + "/Switch B", { update: { state: "updating", progress: 10 } }), 10);
          } else if (process.env.SCENARIO === "transition") {
            setTimeout(() => state({ state: "updating", progress: 50 }), 10);
            setTimeout(() => state({ state: "idle", installed_version: 2 }), 30);
          } else {
            setImmediate(() => send(base + "/bridge/response/device/ota_update/update", { status: "ok", data: { id, from: { file_version: 1 }, to: { file_version: 2 } } }));
          }
        }
      };
      setImmediate(() => client.emit("connect"));
      return client;
    }};
  `);
  await writeFile(join(dir, "check.log"), `JSON ${JSON.stringify({ pending: [{ name: "Light A" }, { name: "Switch B" }] })}\nEND check complete pending=2 check_failed=0\n`);
  await writeFile(join(dir, "two-lights.log"), `JSON ${JSON.stringify({ pending: [{ name: "Light A" }, { name: "Light New" }] })}\nEND check complete pending=2 check_failed=0\n`);
  await writeFile(join(dir, "missing-device.log"), `JSON ${JSON.stringify({ pending: [{ name: "Light A" }, { name: "Light Missing" }] })}\nEND check complete pending=2 check_failed=0\n`);
});

after(async () => rm(dir, { recursive: true, force: true }));

function run(args, scenario = "success") {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ["--no-warnings", "--experimental-loader", pathToFileURL(join(dir, "loader.mjs")).href, runner, ...args], {
      env: { ...process.env, SCENARIO: scenario, CONCURRENCY_MAINS: "1", TIMEOUT_MIN: "0.003", STALL_SILENCE_MIN: "0.004", CHECK_TIMEOUT_S: "0.08", REPORT_EVERY_MS: "20" },
    });
    let output = "";
    child.stdout.on("data", (data) => { output += data; });
    child.stderr.on("data", (data) => { output += data; });
    const timeout = setTimeout(() => { child.kill(); reject(new Error(`runner timed out:\n${output}`)); }, 5000);
    child.on("error", reject);
    child.on("close", (code) => { clearTimeout(timeout); resolve({ code, output }); });
  });
}

test("run requires a completed approved discovery", async () => {
  const missing = await run(["run"]);
  assert.equal(missing.code, 2);
  await writeFile(join(dir, "incomplete.log"), 'JSON {"pending":[]}\n');
  const incomplete = await run(["run", "--from-check", join(dir, "incomplete.log")]);
  assert.equal(incomplete.code, 2);
  assert.match(incomplete.output, /not a completed check/);
});

test("run only updates approved devices in the selected group", async () => {
  const { code, output } = await run(["run", "--from-check", join(dir, "check.log"), "--group", "Light"]);
  assert.equal(code, 0, output);
  assert.match(output, /MOCK_UPDATE Light A/);
  assert.doesNotMatch(output, /MOCK_UPDATE (Light New|Switch B)/);
  assert.match(output, /END ok=1 failed=0 stalled=0/);
});

for (const scenario of ["preflight-error", "preflight-timeout", "external-failed"]) {
  test(`${scenario} stops the run before any update starts`, async () => {
    const { code, output } = await run(["run", "--from-check", join(dir, "two-lights.log")], scenario);
    assert.equal(code, 4, output);
    assert.match(output, /RESULT Light A unconfirmed preflight check failed/);
    assert.match(output, /RESULT Light New unstarted/);
    assert.match(output, /END .*aborted=yes check_failed=1/);
    assert.doesNotMatch(output, /MOCK_UPDATE/);
  });
}

test("dry run returns a failure when a preflight check fails", async () => {
  const { code, output } = await run(["run", "--from-check", join(dir, "two-lights.log"), "--dry-run"], "preflight-error");
  assert.equal(code, 4, output);
  assert.match(output, /RESULT Light A unconfirmed preflight check failed/);
  assert.doesNotMatch(output, /MOCK_UPDATE/);
});

test("an ineligible approved device aborts preflight", async () => {
  const { code, output } = await run(["run", "--from-check", join(dir, "two-lights.log")], "ineligible");
  assert.equal(code, 4, output);
  assert.match(output, /RESULT Light A unconfirmed .*not eligible for OTA/);
  assert.match(output, /RESULT Light New unstarted/);
  assert.doesNotMatch(output, /MOCK_UPDATE/);
});

test("an approved device missing from the bridge aborts preflight", async () => {
  const { code, output } = await run(["run", "--from-check", join(dir, "missing-device.log")]);
  assert.equal(code, 4, output);
  assert.match(output, /RESULT Light Missing unconfirmed .*missing from the bridge/);
  assert.match(output, /RESULT Light A unstarted/);
  assert.doesNotMatch(output, /MOCK_UPDATE/);
});

test("an observed external transfer aborts preflight even outside the approved group", async () => {
  const { code, output } = await run(["run", "--from-check", join(dir, "two-lights.log")], "external-preflight");
  assert.equal(code, 3, output);
  assert.match(output, /RESULT Switch B unconfirmed update already in progress/);
  assert.match(output, /RESULT Light A unstarted/);
  assert.doesNotMatch(output, /MOCK_UPDATE/);
});

test("an unexpected external transfer stops an active run", async () => {
  const { code, output } = await run(["run", "--from-check", join(dir, "two-lights.log")], "external-running");
  assert.equal(code, 3, output);
  assert.match(output, /RESULT Switch B unconfirmed update started outside this runner/);
  assert.match(output, /RESULT Light A unconfirmed/);
  assert.match(output, /RESULT Light New unstarted/);
  assert.doesNotMatch(output, /MOCK_UPDATE Light New/);
});

for (const scenario of ["idle", "unchanged"]) {
  test(`repeated ${scenario} states do not confirm success or prevent a stall abort`, async () => {
    const { code, output } = await run(["run", "--from-check", join(dir, "check.log"), "--group", "Light"], scenario);
    assert.equal(code, 3, output);
    assert.match(output, /DONE Light A stalled slot held/);
    assert.match(output, /ABORT .*without update progress/);
    assert.match(output, /RESULT Light A stalled/);
    assert.doesNotMatch(output, /DONE Light A ok/);
  });
}

test("a stalled device with ongoing progress can still complete", async () => {
  const { code, output } = await run(["run", "--from-check", join(dir, "check.log"), "--group", "Light"], "progress");
  assert.equal(code, 0, output);
  assert.match(output, /DONE Light A stalled slot held/);
  assert.match(output, /DONE Light A ok .*confirmed after stall/);
  assert.doesNotMatch(output, /ABORT/);
});

test("a stalled device holds its slot and leaves queued devices unstarted", async () => {
  const { code, output } = await run(["run", "--from-check", join(dir, "two-lights.log")], "unchanged");
  assert.equal(code, 3, output);
  assert.match(output, /RESULT Light New unstarted/);
  assert.doesNotMatch(output, /MOCK_UPDATE Light New/);
});

test("an updating-to-idle transition completes an update", async () => {
  const { code, output } = await run(["run", "--from-check", join(dir, "check.log"), "--group", "Light"], "transition");
  assert.equal(code, 0, output);
  assert.match(output, /DONE Light A ok 1->2/);
  assert.match(output, /RESULT Light A ok 1->2/);
});
