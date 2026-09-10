import assert from "node:assert/strict";
import test from "node:test";
import vm from "node:vm";
import { extractFunction, extractInlineScripts, readText } from "../tools/webui-source.mjs";

const asp = readText(new URL("../flexqos.asp", import.meta.url));
const shell = readText(new URL("../flexqos.sh", import.meta.url));
const inlineScripts = extractInlineScripts(asp);
assert.equal(inlineScripts.length, 1, "test harness requires exactly one inline script");
const script = inlineScripts[0];

function loadFunctions(names, globals = {}) {
  const source = names.map((name) => extractFunction(script, name)).join("\n\n");
  const context = vm.createContext({ ...globals });
  new vm.Script(source, { filename: `flexqos.asp:${names.join(",")}` }).runInContext(context);
  return context;
}

function json(value) {
  return JSON.parse(JSON.stringify(value));
}

function schedulerSettingsCase(saved, initialSchedule = []) {
  const enabled = { checked: true };
  let toggles = 0;
  let renders = 0;
  const custom_settings = saved === undefined ? {} : { flexqos_schedule: saved };
  const ctx = loadFunctions(
    ["_sched_trim", "daysSpecValid", "parseDaysSpec", "timeValid", "schedParse", "schedPopulateFromSettings"],
    {
      SCHED: initialSchedule,
      custom_settings,
      document: { getElementById: (id) => (id === "sched_enabled" ? enabled : null) },
      schedToggleUI: () => { toggles += 1; },
      sched_render_rules: () => { renders += 1; },
    },
  );
  ctx.schedPopulateFromSettings();
  return { schedule: json(ctx.SCHED), enabled: enabled.checked, toggles, renders };
}

test("WebUI version metadata matches the backend", () => {
  const webMeta = asp.match(/FlexQoS v([^\s]+) released ([0-9-]+)/);
  assert.ok(webMeta);
  assert.equal(webMeta[1], shell.match(/^version=([^\s]+)$/m)[1]);
  assert.equal(webMeta[2], shell.match(/^release=([^\s]+)$/m)[1]);
});

test("scheduler DOW validator accepts only shell-compatible syntax", () => {
  const { daysSpecValid } = loadFunctions(["daysSpecValid"]);
  const cases = [
    [true, ["*", "0", "7", "1,3,5", "1-5", "5-1", "0-7", "7-2"]],
    [false, ["", ",", "1,", ",1", "1,,2", "8", "1-8", "1-2-3", "a", "1 2", "1, 2", "1foo", "2-", "-2"]],
  ];
  for (const [expected, values] of cases) {
    for (const value of values) assert.equal(daysSpecValid(value), expected, value);
  }
});

test("scheduler DOW ranges exhaustively match an independent day model", () => {
  const { parseDaysSpec, daysSpecValid } = loadFunctions(["daysSpecValid", "parseDaysSpec"]);
  for (let start = 0; start <= 7; start += 1) {
    for (let end = 0; end <= 7; end += 1) {
      const spec = `${start}-${end}`;
      assert.equal(daysSpecValid(spec), true, spec);
      const actual = new Set(Array.from(parseDaysSpec(spec)));
      const expected = new Set();
      if (spec === "0-7") {
        for (let day = 0; day <= 6; day += 1) expected.add(day);
      } else {
        const first = start === 7 ? 0 : start;
        const last = end === 7 ? 0 : end;
        if (first <= last) {
          for (let day = first; day <= last; day += 1) expected.add(day);
        } else {
          for (let day = first; day <= 6; day += 1) expected.add(day);
          for (let day = 0; day <= last; day += 1) expected.add(day);
        }
      }
      assert.deepEqual([...actual].sort(), [...expected].sort(), spec);
    }
  }
});

test("scheduler serialization is canonical and round-trips", () => {
  const ctx = loadFunctions([
    "daysSpecValid", "parseDaysSpec", "stringifyDays", "timeValid", "schedParse", "schedStringify",
  ]);
  assert.equal(ctx.stringifyDays([6, 0, 1, 1, -1, 7]), "0,1,6");
  assert.equal(ctx.stringifyDays([6, 5, 4, 3, 2, 1, 0]), "0-6");

  const windows = [
    { days: [1, 2, 3, 4, 5], start: "07:00", end: "20:00" },
    { days: [0, 6], start: "22:00", end: "06:00" },
    { days: [2], start: "00:00", end: "23:59" },
  ];
  for (const win of windows) {
    assert.deepEqual(json(ctx.schedParse(ctx.schedStringify(win))), { enabled: true, ...win });
  }
});

test("scheduler time validation enforces exact HH:MM boundaries", () => {
  const { timeValid } = loadFunctions(["timeValid"]);
  const cases = [
    [true, ["00:00", "07:05", "12:30", "23:59"]],
    [false, ["", "7:00", "07:5", "24:00", "12:60", "-1:00", "aa:bb", "12:30:00"]],
  ];
  for (const [expected, values] of cases) {
    for (const value of values) assert.equal(timeValid(value), expected, value);
  }
});

test("persisted scheduler records reject malformed DOW and times", () => {
  const ctx = loadFunctions(["daysSpecValid", "parseDaysSpec", "timeValid", "schedParse"]);
  assert.deepEqual(json(ctx.schedParse("<1>5-1>22:00>06:00")), {
    enabled: true, days: [0, 1, 5, 6], start: "22:00", end: "06:00",
  });
  assert.equal(json(ctx.schedParse("<0>1-5>07:00>20:00")).enabled, false);
  for (const value of [
    "<1>8>07:00>20:00", "<1>1-2-3>07:00>20:00", "<1>1-5>24:00>20:00",
    "<1>1-5>07:00>20:60", "<1>1-5>07:00", "",
  ]) assert.equal(ctx.schedParse(value), null, value);
});

test("scheduler serialization preserves configured order", () => {
  const ctx = loadFunctions(["stringifyDays", "schedStringify", "schedSerialize"], {
    SCHED: [
      { days: [1, 2, 3, 4, 5], start: "07:00", end: "20:00" },
      { days: [0, 6], start: "22:00", end: "06:00" },
    ],
  });
  assert.equal(ctx.schedSerialize(), "<1>1,2,3,4,5>07:00>20:00|<1>0,6>22:00>06:00");
});

test("scheduler settings population derives enabled state only from restored active windows", () => {
  const cases = [
    { saved: undefined, initial: [{ days: [1], start: "01:00", end: "02:00" }], expected: [], enabled: false },
    { saved: "garbage", expected: [], enabled: false },
    { saved: "<0>1-5>07:00>20:00", expected: [], enabled: false },
    { saved: "<1>8>07:00>20:00", expected: [], enabled: false },
    {
      saved: "<0>0,6>01:00>02:00|<1>1-5>07:00>20:00|broken",
      expected: [{ days: [1, 2, 3, 4, 5], start: "07:00", end: "20:00" }],
      enabled: true,
    },
  ];

  for (const { saved, initial = [], expected, enabled } of cases) {
    const actual = schedulerSettingsCase(saved, initial);
    assert.deepEqual(actual.schedule, expected, String(saved));
    assert.equal(actual.enabled, enabled, String(saved));
    assert.equal(actual.toggles, 1, String(saved));
    assert.equal(actual.renders, 1, String(saved));
  }
});

test("QoS port validation matches backend-compatible limits", () => {
  const { validateQoSPortSpec } = loadFunctions(["validateQoSPortSpec"]);
  const cases = [
    [true, ["", "1", "65535", "!443", "1:2", "1:65535", "53,123,853", "!53,123,853"]],
    [false, ["0", "65536", "2:2", "3:2", "0:10", "10:65536", "1,,2", "1:2,3", "!!80", "80,"]],
  ];
  for (const [expected, values] of cases) {
    for (const value of values) assert.equal(validateQoSPortSpec(value).valid, expected, value);
  }

  const fifteen = Array.from({ length: 15 }, (_, i) => String(i + 1)).join(",");
  assert.equal(validateQoSPortSpec(fifteen).valid, true);
  const sixteen = Array.from({ length: 16 }, (_, i) => String(i + 1)).join(",");
  assert.deepEqual(json(validateQoSPortSpec(sixteen)), { valid: false, reason: "multiport-limit" });
});

test("tracked connection rendering never leaks a prior hostname into IPv6 rows", () => {
  const elements = new Map();
  const document = {
    getElementById(id) {
      if (!elements.has(id)) elements.set(id, { innerHTML: "", style: {} });
      return elements.get(id);
    },
  };
  const ctx = loadFunctions(["table_sort", "updateTable"], {
    document,
    tabledata: [
      ["tcp", "192.168.1.2", "1234", "8.8.8.8", "443", "0>AlphaApp", "1", "2"],
      ["udp", "2001:db8::2", "5353", "2001:4860::8888", "53", "0>BetaApp", "2", "3"],
    ],
    sortfield: 5,
    sortdir: 0,
    maxshown: 500,
    labels_array: ["Class zero"],
    ipv6clientarray: [],
    clientList: {},
    genClientList() {},
    clientFromIP: (ip) => (ip === "192.168.1.2" ? { nickName: "", name: "AlphaHost" } : null),
  });

  ctx.updateTable();
  const html = elements.get("tableContainer").innerHTML;
  assert.equal((html.match(/AlphaHost/g) || []).length, 1);
  assert.match(html, />2001:db8::2<\/td>/);
  assert.doesNotMatch(html, /title="2001:db8::2"[^>]*>AlphaHost<\/td>/);
});
