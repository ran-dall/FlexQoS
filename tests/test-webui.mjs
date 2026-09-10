import assert from "node:assert/strict";
import fs from "node:fs";
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

test("ASP document structure and version metadata match the backend", () => {
  assert.equal((asp.match(/<html\b/gi) || []).length, 1);
  assert.equal((asp.match(/<\/html>/gi) || []).length, 1);
  assert.equal((asp.match(/<head\b/gi) || []).length, 1);
  assert.equal((asp.match(/<body\b/gi) || []).length, 1);
  const webMeta = asp.match(/FlexQoS v([^\s]+) released ([0-9-]+)/);
  assert.ok(webMeta);
  assert.equal(webMeta[1], shell.match(/^version=([^\s]+)$/m)[1]);
  assert.equal(webMeta[2], shell.match(/^release=([^\s]+)$/m)[1]);
});

test("scheduler DOW validator accepts only shell-compatible syntax", () => {
  const { daysSpecValid } = loadFunctions(["daysSpecValid"]);
  for (const value of ["*", "0", "7", "1,3,5", "1-5", "5-1", "0-7", "7-2"]) {
    assert.equal(daysSpecValid(value), true, value);
  }
  for (const value of ["", ",", "1,", ",1", "1,,2", "8", "1-8", "1-2-3", "a", "1 2", "1, 2", "1foo", "2-", "-2"]) {
    assert.equal(daysSpecValid(value), false, value);
  }
});

test("scheduler DOW ranges exhaustively match an independent day model", () => {
  const { parseDaysSpec, daysSpecValid } = loadFunctions(["daysSpecValid", "parseDaysSpec"]);
  for (let start = 0; start <= 7; start++) {
    for (let end = 0; end <= 7; end++) {
      const spec = `${start}-${end}`;
      assert.equal(daysSpecValid(spec), true, spec);
      const actual = new Set(Array.from(parseDaysSpec(spec)));
      const expected = new Set();
      if (spec === "0-7") {
        for (let d = 0; d <= 6; d++) expected.add(d);
      } else {
        const s = start === 7 ? 0 : start;
        const e = end === 7 ? 0 : end;
        if (s <= e) {
          for (let d = s; d <= e; d++) expected.add(d);
        } else {
          for (let d = s; d <= 6; d++) expected.add(d);
          for (let d = 0; d <= e; d++) expected.add(d);
        }
      }
      assert.deepEqual([...actual].sort(), [...expected].sort(), spec);
    }
  }
});

test("scheduler day serialization is canonical and round-trips", () => {
  const ctx = loadFunctions(["daysSpecValid", "parseDaysSpec", "stringifyDays"]);
  assert.equal(ctx.stringifyDays([6, 0, 1, 1, -1, 7]), "0,1,6");
  assert.equal(ctx.stringifyDays([6, 5, 4, 3, 2, 1, 0]), "0-6");
  for (const days of [[1,2,3,4,5], [0,6], [5,6,0,1], [2]]) {
    const encoded = ctx.stringifyDays(days);
    assert.deepEqual(Array.from(ctx.parseDaysSpec(encoded)), [...new Set(days)].sort((a,b) => a-b));
  }
});

test("scheduler time validation enforces exact HH:MM boundaries", () => {
  const { timeValid } = loadFunctions(["timeValid"]);
  for (const value of ["00:00", "07:05", "12:30", "23:59"]) assert.equal(timeValid(value), true, value);
  for (const value of ["", "7:00", "07:5", "24:00", "12:60", "-1:00", "aa:bb", "12:30:00"]) assert.equal(timeValid(value), false, value);
});

test("persisted scheduler records reject malformed DOW and times", () => {
  const ctx = loadFunctions(["daysSpecValid", "parseDaysSpec", "timeValid", "schedParse"]);
  assert.deepEqual(json(ctx.schedParse("<1>5-1>22:00>06:00")), {
    enabled: true, days: [0,1,5,6], start: "22:00", end: "06:00",
  });
  assert.equal(json(ctx.schedParse("<0>1-5>07:00>20:00")).enabled, false);
  for (const value of [
    "<1>8>07:00>20:00",
    "<1>1-2-3>07:00>20:00",
    "<1>1-5>24:00>20:00",
    "<1>1-5>07:00>20:60",
    "<1>1-5>07:00",
    "",
  ]) assert.equal(ctx.schedParse(value), null, value);
});

test("scheduler parse and stringify round-trip canonical windows", () => {
  const ctx = loadFunctions(["daysSpecValid", "parseDaysSpec", "stringifyDays", "timeValid", "schedParse", "schedStringify"]);
  for (const win of [
    { days: [1,2,3,4,5], start: "07:00", end: "20:00" },
    { days: [0,6], start: "22:00", end: "06:00" },
    { days: [2], start: "00:00", end: "23:59" },
  ]) {
    const encoded = ctx.schedStringify(win);
    const parsed = json(ctx.schedParse(encoded));
    assert.deepEqual(parsed, { enabled: true, ...win });
  }
});

test("scheduler serialization preserves configured order", () => {
  const ctx = loadFunctions(["stringifyDays", "schedStringify", "schedSerialize"], {
    SCHED: [
      { days: [1,2,3,4,5], start: "07:00", end: "20:00" },
      { days: [0,6], start: "22:00", end: "06:00" },
    ],
  });
  assert.equal(ctx.schedSerialize(), "<1>1,2,3,4,5>07:00>20:00|<1>0,6>22:00>06:00");
});

test("QoS port validation accepts legal singles ranges lists and negation", () => {
  const { validateQoSPortSpec } = loadFunctions(["validateQoSPortSpec"]);
  for (const value of ["", "1", "65535", "!443", "1:2", "1:65535", "53,123,853", "!53,123,853"]) {
    assert.equal(validateQoSPortSpec(value).valid, true, value);
  }
  const fifteen = Array.from({length: 15}, (_, i) => String(i + 1)).join(",");
  assert.equal(validateQoSPortSpec(fifteen).valid, true);
});

test("QoS port validation rejects backend-incompatible limits and malformed forms", () => {
  const { validateQoSPortSpec } = loadFunctions(["validateQoSPortSpec"]);
  for (const value of ["0", "65536", "2:2", "3:2", "0:10", "10:65536", "1,,2", "1:2,3", "!!80", "80,"]) {
    assert.equal(validateQoSPortSpec(value).valid, false, value);
  }
  const sixteen = Array.from({length: 16}, (_, i) => String(i + 1)).join(",");
  const result = validateQoSPortSpec(sixteen);
  assert.equal(result.valid, false);
  assert.equal(result.reason, "multiport-limit");
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
    clientFromIP(ip) {
      return ip === "192.168.1.2" ? { nickName: "", name: "AlphaHost" } : null;
    },
  });

  ctx.updateTable();
  const html = elements.get("tableContainer").innerHTML;
  assert.equal((html.match(/AlphaHost/g) || []).length, 1);
  assert.match(html, />2001:db8::2<\/td>/);
  assert.doesNotMatch(html, /title="2001:db8::2"[^>]*>AlphaHost<\/td>/);
});

test("critical WebUI functions are extracted from production exactly once", () => {
  for (const name of [
    "daysSpecValid", "parseDaysSpec", "stringifyDays", "timeValid", "schedParse", "schedStringify",
    "schedSerialize", "validateQoSPortSpec", "table_sort", "updateTable",
  ]) assert.match(extractFunction(script, name), new RegExp(`function\\s+${name}\\s*\\(`));
});
