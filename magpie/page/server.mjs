// The Magpie page: the hub's status, the Mac download, and a fresh setup
// link for the first device. Runs on Chicago under `launch` (private to the
// owner); asks the hub on Frankfurt over ssh, through the sudoers rule that
// lets ubuntu run magpie-hubd as magpie.
//
//   PORT                  where to listen (launch sets it)
//   MAGPIE_PAGE_SAMPLE=1  sample data for screenshots, no ssh (=first: before any device)
import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import http from "node:http";
import net from "node:net";

const HERE = new URL(".", import.meta.url).pathname;
const SAMPLE = ["1", "first"].includes(process.env.MAGPIE_PAGE_SAMPLE);
const SAMPLE_FIRST = process.env.MAGPIE_PAGE_SAMPLE === "first";
const HUB_ADDR = { host: "92.5.139.56", port: 22000 };
const DMG = "https://github.com/mandipadk/magpie/releases/download/mac-latest/Magpie.dmg";
// Internal TestFlight has no public link: the owner is in the "Owner" group,
// so the app waits in the TestFlight app on their iPhone.
const TESTFLIGHT = process.env.MAGPIE_TESTFLIGHT_URL || "https://apps.apple.com/app/testflight/id899247664";
const HUBD = ["frankfurt", "sudo", "-n", "-u", "magpie", "/opt/magpie/current/magpie-hubd"];

function hubd(...args) {
  return new Promise((resolve, reject) => {
    execFile("ssh", [...HUBD, args[0], "--home", "/var/lib/magpie", ...args.slice(1)], { timeout: 15000 }, (err, out, errOut) => {
      if (err) reject(new Error((errOut || err.message).trim().split("\n").pop()));
      else resolve(out.trim());
    });
  });
}

// Whether devices out on the internet can reach the hub (Oracle's rules and
// Frankfurt's firewall both have to let 22000 in).
function reachable() {
  return new Promise((resolve) => {
    const s = net.connect({ ...HUB_ADDR, timeout: 4000 });
    const done = (ok) => { s.destroy(); resolve(ok); };
    s.on("connect", () => done(true));
    s.on("timeout", () => done(false));
    s.on("error", () => done(false));
  });
}

async function macRelease() {
  try {
    const r = await fetch("https://api.github.com/repos/mandipadk/magpie/releases/tags/mac-latest", {
      headers: { "User-Agent": "magpie-page" }, signal: AbortSignal.timeout(8000),
    });
    if (!r.ok) return null;
    const rel = await r.json();
    const dmg = rel.assets?.find((a) => a.name === "Magpie.dmg");
    if (!dmg) return null;
    // The version is in the Sparkle appcast published beside the disk image.
    let version = "";
    const feed = rel.assets.find((a) => a.name === "appcast.xml");
    if (feed) {
      const xml = await (await fetch(feed.browser_download_url, { signal: AbortSignal.timeout(8000) })).text();
      const short = xml.match(/<sparkle:shortVersionString>([^<]+)</)?.[1];
      const build = xml.match(/<sparkle:version>([^<]+)</)?.[1];
      if (short) version = build ? `${short} (${build})` : short;
    }
    return { url: DMG, version, size: dmg.size, updated: dmg.updated_at };
  } catch {
    return null;
  }
}

let cache = { at: 0, value: null };

function body(req) {
  return new Promise((resolve, reject) => {
    let data = "";
    req.on("data", (c) => { data += c; if (data.length > 4096) req.destroy(); });
    req.on("end", () => resolve(data));
    req.on("error", reject);
  });
}
async function state() {
  if (SAMPLE) return sample();
  if (Date.now() - cache.at < 10000 && cache.value) return cache.value;
  const [hub, open, mac] = await Promise.all([
    hubd("status").then(JSON.parse).catch((e) => ({ error: e.message })),
    reachable(),
    macRelease(),
  ]);
  const value = { hub, open, mac, iphone: TESTFLIGHT ? { url: TESTFLIGHT } : null, sample: false };
  cache = { at: Date.now(), value };
  return value;
}

function sample() {
  const ago = (m) => new Date(Date.now() - m * 60000).toISOString();
  if (SAMPLE_FIRST) return {
    sample: true, open: true,
    hub: { hubID: "SAMPLE", version: "v2.1.7-magpie", uptimeS: 1500, encrypted: true, files: 0, bytes: 0, historyBytes: 0, historyFiles: 0, folderErrors: 0, devices: null },
    mac: { url: DMG, version: "1.0 (14)", size: 9400000, updated: ago(60) },
    iphone: null,
  };
  return {
    sample: true,
    open: true,
    hub: {
      hubID: "SAMPLE", version: "v2.1.7-magpie", uptimeS: 9 * 86400, encrypted: true,
      files: 1284, bytes: 6650000000, historyBytes: 412000000, historyFiles: 96, historyLatest: ago(40), folderErrors: 0,
      devices: [
        { id: "SAMPLEA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA", name: "MacBook Air", connected: true, lastSeen: ago(0), client: "magpie" },
        { id: "SAMPLEB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB", name: "iPhone", connected: false, lastSeen: ago(12), client: "magpie" },
      ],
    },
    mac: { url: DMG, version: "1.0 (14)", size: 9400000, updated: ago(60 * 26) },
    iphone: { url: "https://testflight.apple.com/" },
  };
}

const types = { ".html": "text/html; charset=utf-8", ".png": "image/png", ".js": "text/javascript" };

http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://x");
  const send = (code, body, type = "application/json") => {
    res.writeHead(code, { "Content-Type": type, "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" });
    res.end(typeof body === "string" || Buffer.isBuffer(body) ? body : JSON.stringify(body));
  };
  try {
    if (req.method === "GET" && url.pathname === "/api/state") return send(200, await state());
    // Changes need the page's own header, which another site can't send
    // without a CORS preflight this server never answers.
    if (req.method === "POST" && req.headers["x-magpie"] !== "1") return send(403, { error: "not from this page" });
    if (req.method === "POST" && url.pathname === "/api/remove") {
      const { id } = JSON.parse((await body(req)) || "{}");
      if (!/^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$/.test(id || "")) return send(400, { error: "that isn't a device ID" });
      if (SAMPLE) return send(200, { ok: true });
      await hubd("remove", id);
      cache = { at: 0, value: null };
      return send(200, { ok: true });
    }
    if (req.method === "POST" && url.pathname === "/api/setup-link") {
      if (SAMPLE) return send(200, { link: "magpie1:join?a=203.0.113.7%3A22000&f=magpie&h=SAMPLE-SAMPLE-SAMPLE-SAMPLE&k=c2FtcGxlLWtleQ&t=c2FtcGxlLXRva2Vu", expires: new Date(Date.now() + 15 * 60000).toISOString() });
      const link = await hubd("setup-link");
      if (!link.startsWith("magpie1:join?")) throw new Error("the server didn't make a link");
      return send(200, { link, expires: new Date(Date.now() + 15 * 60000).toISOString() });
    }
    if (req.method === "GET") {
      const name = url.pathname === "/" ? "index.html" : url.pathname.slice(1);
      if (!/^[\w.-]+$/.test(name) || !types[name.slice(name.lastIndexOf("."))]) return send(404, "not found", "text/plain");
      return send(200, await readFile(HERE + name), types[name.slice(name.lastIndexOf("."))]);
    }
    send(405, "no", "text/plain");
  } catch (e) {
    send(502, { error: e.message });
  }
}).listen(Number(process.env.PORT || 8790), "127.0.0.1");
