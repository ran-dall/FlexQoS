import fs from "node:fs";
import vm from "node:vm";
import { extractInlineScripts, neutralizeAsp, readText } from "./webui-source.mjs";

const aspPath = process.argv[2] || "flexqos.asp";
const outputPath = process.argv[3];
const asp = readText(aspPath);
const shell = readText("flexqos.sh");

function requireCount(label, re, expected) {
  const count = (asp.match(re) || []).length;
  if (count !== expected) throw new Error(`${label}: expected ${expected}, found ${count}`);
}

requireCount("DOCTYPE", /<!DOCTYPE\s+html\b/gi, 1);
requireCount("opening html root", /<html\b/gi, 1);
requireCount("closing html root", /<\/html>/gi, 1);
requireCount("opening head", /<head\b/gi, 1);
requireCount("closing head", /<\/head>/gi, 1);
requireCount("opening body", /<body\b/gi, 1);
requireCount("closing body", /<\/body>/gi, 1);

neutralizeAsp(asp);

const inline = extractInlineScripts(asp);
if (inline.length !== 1) throw new Error(`expected exactly one inline script block, found ${inline.length}`);
const js = neutralizeAsp(inline[0]);
new vm.Script(js, { filename: `${aspPath}:inline.js` });

const names = [...js.matchAll(/^function\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*\(/gm)].map((m) => m[1]);
const duplicates = [...new Set(names.filter((name, i) => names.indexOf(name) !== i))];
if (duplicates.length) throw new Error(`duplicate function declarations: ${duplicates.join(", ")}`);

const aspMeta = asp.match(/FlexQoS v([^\s]+) released ([0-9-]+)/);
const shellVersion = shell.match(/^version=([^\s]+)$/m)?.[1];
const shellRelease = shell.match(/^release=([^\s]+)$/m)?.[1];
if (!aspMeta || !shellVersion || !shellRelease) throw new Error("unable to read FlexQoS version metadata");
if (aspMeta[1] !== shellVersion || aspMeta[2] !== shellRelease) {
  throw new Error(`WebUI metadata ${aspMeta[1]} ${aspMeta[2]} does not match shell ${shellVersion} ${shellRelease}`);
}

if (outputPath) fs.writeFileSync(outputPath, `${js}\n`);
console.log(`ASP structure and JavaScript parse checks passed (${names.length} functions).`);
