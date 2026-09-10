import fs from "node:fs";

export function readText(path) {
  return fs.readFileSync(path, "utf8").replace(/^\uFEFF/, "");
}

export function extractInlineScripts(source) {
  const blocks = [];
  const re = /<script\b([^>]*)>([\s\S]*?)<\/script>/gi;
  let match;
  while ((match = re.exec(source)) !== null) {
    if (!/\bsrc\s*=/.test(match[1])) blocks.push(match[2]);
  }
  return blocks;
}

export function neutralizeAsp(source) {
  const matches = source.match(/<%[\s\S]*?%>/g) || [];
  const opens = (source.match(/<%/g) || []).length;
  const closes = (source.match(/%>/g) || []).length;
  if (opens !== closes || opens !== matches.length) {
    throw new Error(`unbalanced ASP directives: opens=${opens} closes=${closes} complete=${matches.length}`);
  }
  return source.replace(/<%[\s\S]*?%>/g, "0");
}

function regexStartsAfter(source, slashIndex) {
  let i = slashIndex - 1;
  while (i >= 0 && /\s/.test(source[i])) i--;
  if (i < 0) return true;
  if (/[([{,:;=!?&|+\-*%^~<>]/.test(source[i])) return true;

  const prefix = source.slice(0, i + 1);
  const word = prefix.match(/([A-Za-z_$][A-Za-z0-9_$]*)$/)?.[1] || "";
  return ["return", "case", "throw", "typeof", "instanceof", "in", "of", "delete", "void", "new"].includes(word);
}

function findClosingBrace(source, openIndex) {
  let depth = 1;
  let state = "normal";
  let regexClass = false;

  for (let i = openIndex + 1; i < source.length; i++) {
    const ch = source[i];
    const next = source[i + 1];

    if (state === "line-comment") {
      if (ch === "\n") state = "normal";
      continue;
    }
    if (state === "block-comment") {
      if (ch === "*" && next === "/") { state = "normal"; i++; }
      continue;
    }
    if (state === "single" || state === "double" || state === "template") {
      const quote = state === "single" ? "'" : state === "double" ? '"' : "`";
      if (ch === "\\") { i++; continue; }
      if (ch === quote) state = "normal";
      continue;
    }
    if (state === "regex") {
      if (ch === "\\") { i++; continue; }
      if (ch === "[") { regexClass = true; continue; }
      if (ch === "]" && regexClass) { regexClass = false; continue; }
      if (ch === "/" && !regexClass) {
        state = "normal";
        while (/[A-Za-z]/.test(source[i + 1] || "")) i++;
      }
      continue;
    }

    if (ch === "/" && next === "/") { state = "line-comment"; i++; continue; }
    if (ch === "/" && next === "*") { state = "block-comment"; i++; continue; }
    if (ch === "'") { state = "single"; continue; }
    if (ch === '"') { state = "double"; continue; }
    if (ch === "`") { state = "template"; continue; }
    if (ch === "/" && regexStartsAfter(source, i)) { state = "regex"; regexClass = false; continue; }
    if (ch === "{") depth++;
    if (ch === "}") {
      depth--;
      if (depth === 0) return i;
    }
  }
  throw new Error("unterminated function body");
}

export function extractFunction(source, name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const re = new RegExp(`^function\\s+${escaped}\\s*\\(`, "gm");
  const matches = [...source.matchAll(re)];
  if (matches.length !== 1) {
    throw new Error(`expected function ${name} exactly once, found ${matches.length}`);
  }
  const start = matches[0].index;
  const open = source.indexOf("{", start);
  if (open < 0) throw new Error(`function ${name} has no body`);
  const close = findClosingBrace(source, open);
  return source.slice(start, close + 1);
}
