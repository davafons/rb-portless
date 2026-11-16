#!/usr/bin/env node
// Lists every upstream test (describe path + it/test name) at a git ref of the
// upstream clone, as JSON. Parses with the TypeScript compiler so nesting,
// modifiers (.skipIf/.runIf/.skip/.each/.for) and dynamic names are exact.
//
//   node script/upstream/extract_tests.mjs [ref]      (default: HEAD)
//
// Output: [{ file, path: [describe...], name, modifier, dynamic, line }]
// `file` is relative to the upstream repo root. Names with ${...} keep the
// raw template text and are flagged dynamic.
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const upstream = path.resolve(here, "../../references/portless");
const ref = process.argv[2] || "HEAD";

const require = createRequire(import.meta.url);
const tsDir = execFileSync("sh", ["-c", "ls -d node_modules/.pnpm/typescript@5*/node_modules/typescript | tail -1"], {
  cwd: upstream,
  encoding: "utf8",
}).trim();
if (!tsDir) throw new Error("typescript 5 not found under references/portless/node_modules; run pnpm install there");
const ts = require(path.join(upstream, tsDir));

const git = (...args) => execFileSync("git", ["-C", upstream, ...args], { encoding: "utf8", maxBuffer: 64 << 20 });

const files = git("ls-tree", "-r", "--name-only", ref)
  .split("\n")
  .filter((f) => /^(packages\/portless\/src\/.*\.test\.ts|tests\/e2e\/src\/.*\.test\.ts)$/.test(f));

const TEST_FNS = new Set(["it", "test"]);

// Unwrap a callee chain into { base, modifier }: it, it.skipIf(x),
// it.each(t), it.skipIf(x).each(t), describe.skipIf(x) ... Modifiers are
// joined with "." in source order (e.g. "skipIf.each").
function classify(callee) {
  const mods = [];
  let node = callee;
  for (;;) {
    if (ts.isCallExpression(node)) node = node.expression;
    else if (ts.isPropertyAccessExpression(node)) {
      mods.unshift(node.name.text);
      node = node.expression;
    } else break;
  }
  if (!ts.isIdentifier(node)) return null;
  // A bare it(...)/describe(...) call: the callee itself is the identifier.
  // A chain must end in a call on the modifiers (it.each(t)(...)), otherwise
  // this node is an inner piece (it.skipIf(cond)) of a larger chain.
  if (mods.length && !ts.isCallExpression(callee) && !["skip", "only", "todo", "concurrent"].includes(mods.at(-1))) {
    return null;
  }
  return { base: node.text, modifier: mods.length ? mods.join(".") : null };
}

function nameOf(node, sf) {
  if (!node) return null;
  if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) return { text: node.text, dynamic: false };
  if (ts.isTemplateExpression(node)) return { text: node.getText(sf).slice(1, -1), dynamic: true };
  return { text: node.getText(sf), dynamic: true };
}

const out = [];
for (const file of files) {
  const source = git("show", `${ref}:${file}`);
  const sf = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  const visit = (node, stack) => {
    if (ts.isCallExpression(node)) {
      const kind = classify(node.expression);
      if (kind && (kind.base === "describe" || TEST_FNS.has(kind.base))) {
        const name = nameOf(node.arguments[0], sf);
        if (name) {
          const line = sf.getLineAndCharacterOfPosition(node.getStart(sf)).line + 1;
          if (kind.base === "describe") {
            const next = [...stack, name.text];
            node.arguments.slice(1).forEach((a) => ts.forEachChild(a, (c) => visit(c, next)));
            return;
          }
          out.push({ file, path: stack, name: name.text, modifier: kind.modifier, dynamic: name.dynamic, line });
          return;
        }
      }
    }
    ts.forEachChild(node, (c) => visit(c, stack));
  };
  visit(sf, []);
}

process.stdout.write(JSON.stringify(out, null, 1) + "\n");
