// Runs the stick's phone page (phone.html) in Node, with just enough of a
// browser around it: the elements the page uses, fetch, the clipboard and
// timers that only move when the test says so. test_phone.py starts it
// once per case, by name, and reads what it prints.
//
// Usage: node phone-page.mjs <phone.html> <case>

import { readFileSync } from "node:fs";
import vm from "node:vm";

const [file, which] = process.argv.slice(2);
const html = readFileSync(file, "utf8");
const script = html.match(/<script>([\s\S]*)<\/script>/)[1];

class Element {
  constructor(id = "", hidden = false) {
    this.id = id;
    this.hidden = hidden;
    this.textContent = "";
    this.disabled = false;
    this.className = "";
    this.style = {};
    this.children = [];
    this.attributes = {};
    this.onclick = null;
  }
  setAttribute(name, value) { this.attributes[name] = value; }
  getAttribute(name) { return this.attributes[name]; }
  replaceChildren(...children) { this.children = children; }
  append(...children) { this.children.push(...children); }
  prepend(child) { this.children.unshift(child); }
  remove() {}
  querySelectorAll() { return []; }
  select() {}
  setSelectionRange() {}
}

// Every element with an id starts as the page's markup has it.
const elements = {};
for (const [, tag, id] of html.matchAll(/<(\w+)[^>]*\bid="([^"]+)"[^>]*>/g)) {
  const open = html.match(new RegExp(`<${tag}[^>]*\\bid="${id}"[^>]*>`))[0];
  elements[id] = new Element(id, /\shidden[\s>]/.test(open));
}
const document = {
  getElementById: (id) => elements[id] ?? (elements[id] = new Element(id)),
  querySelector: () => new Element(),
  createElement: () => new Element(),
  createRange: () => ({ selectNodeContents() {} }),
  execCommand: () => false,
  body: new Element(),
};

// Timers move only when the test says so.
let now = 0;
let timers = [];
const setTimeout = (run, ms) => { const timer = { run, at: now + ms }; timers.push(timer); return timer; };
const clearTimeout = (timer) => { timers = timers.filter((t) => t !== timer); };
async function wait(ms) {
  const until = now + ms;
  for (;;) {
    const due = timers.filter((t) => t.at <= until).sort((a, b) => a.at - b.at)[0];
    if (!due) break;
    timers = timers.filter((t) => t !== due);
    now = due.at;
    due.run();
    await settle();
  }
  now = until;
  await settle();
}
const settle = () => new Promise((done) => setImmediate(done));

// The TV's answers, by path. Each case sets what /api/first?pair=page says.
const SECRET = "A".repeat(22);
const asked = [];
let pairAnswer = { pair: { secret: SECRET, port: 3001 } };
function fetch(path, options = {}) {
  asked.push(path);
  const reply = (body, status = 200) => Promise.resolve({ ok: status < 400, status, json: async () => body });
  if (path === "/api/first?pair=page") {
    if (pairAnswer === "never") {
      return new Promise((_, fail) => options.signal?.addEventListener("abort", () => fail(new Error("aborted"))));
    }
    return reply(pairAnswer);
  }
  if (path === "/api/first/install") return reply({ ok: true });
  if (path === "/api/first/pick") return reply({ ok: true });
  return reply({ step: 1, disks: [{ path: "/dev/sda", name: "Disk", size: "1 TB" }] });
}

let copiedText = null;
const context = vm.createContext({
  document,
  fetch,
  setTimeout,
  clearTimeout,
  AbortController,
  URLSearchParams,
  location: { search: "", replace() {} },
  navigator: { clipboard: { writeText: async (text) => { copiedText = text; } } },
  getSelection: () => ({ removeAllRanges() {}, addRange() {} }),
});
vm.runInContext(script.replace("{{TOKEN}}", "token"), context);
await settle();

const state = () => ({
  asked,
  keepHidden: elements.keep.hidden,
  link: elements.link.textContent,
  installingHidden: elements.installing.hidden,
  copy: elements.copy.textContent,
  copied: copiedText,
});

if (which === "pair-answered") {
  await elements.go.onclick();
  await settle();
  await elements.copy.onclick();
} else if (which === "no-pair") {
  pairAnswer = {};
  await elements.go.onclick();
} else if (which === "pair-never-answers") {
  pairAnswer = "never";
  // Not awaited: without a limit it would never end, and the case fails
  // on what was asked rather than hanging.
  elements.go.onclick();
  await wait(2900);
  const before = asked.includes("/api/first/install");
  await wait(200);
  console.log(JSON.stringify({ ...state(), installBeforeLimit: before }));
  process.exit(0);
} else {
  console.error(`no such case: ${which}`);
  process.exit(2);
}
await settle();
console.log(JSON.stringify(state()));
process.exit(0);
