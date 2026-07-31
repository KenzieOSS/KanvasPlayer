import { mkdir, unlink } from "node:fs/promises";
import { createWriteStream } from "node:fs";
import { join } from "node:path";
import { Readable } from "node:stream";
import { finished } from "node:stream/promises";

const HEADERS = {
  "User-Agent": "Mozilla/5.0 (X11; Linux x86_64; rv:153.0) Gecko/20100101 Firefox/153.0",
  Accept: "*/*",
  Origin: "https://open.spotify.com",
  Referer: "https://open.spotify.com/",
};

async function getAccessToken(): Promise<string> {
  if (process.env.SP_ACCESS_TOKEN) return process.env.SP_ACCESS_TOKEN;
  console.error("SP_ACCESS_TOKEN not set");
  process.exit(2);
}

interface CanvasInfo {
  origin: string; source: string; encoding: string; profile: string;
  token: string; fauth: string; tokenAk?: string; tokenCf?: string;
}

function parseUrl(url: string): { type: "segments" | "direct" } & Partial<CanvasInfo> & { url: string } {
  if (url.includes("video-cf.spotifycdn.com") && url.includes("/origins/")) {
    const u = new URL(url);
    const parts = u.pathname.split("/");
    const oi = parts.indexOf("origins");
    return {
      type: "segments",
      origin: parts[oi + 1],
      source: parts[oi + 3],
      encoding: parts[oi + 5],
      profile: parts[oi + 7],
      token: u.searchParams.get("token") ?? "",
      fauth: u.searchParams.get("fauth") ?? "",
      tokenAk: u.searchParams.get("token_ak") ?? "",
      tokenCf: u.searchParams.get("token_cf") ?? "",
      url,
    };
  }
  return { type: "direct", url };
}

async function fetchCanvasInfo(trackId: string, token: string): Promise<ReturnType<typeof parseUrl>> {
  const authHeaders = { Authorization: `Bearer ${token}`, ...HEADERS };
  let sawAuthError = false;

  for (const host of ["spclient.wg.spotify.com", "gew1-spclient.spotify.com"]) {
    for (const path of [`/canvias/v1/canvas/${trackId}`, `/canvas/v1/canvas/${trackId}`]) {
      const resp = await fetch(`https://${host}${path}`, { headers: authHeaders }).catch(() => null);
      if (resp?.ok) {
        const data = await resp.json() as any;
        const canvases = data.canvases ?? data.canvas ?? [data];
        const c = Array.isArray(canvases) ? canvases[0] : canvases;
        const d = c.file_delivery ?? c.delivery ?? c;
        return parseUrl(d.url ?? c.url);
      }
      if (resp && (resp.status === 401 || resp.status === 403)) sawAuthError = true;
    }
  }

  const uri = `spotify:track:${trackId}`;
  const uriB = new TextEncoder().encode(uri);
  const sub = new Uint8Array([0x0a, uriB.length, ...uriB]);
  const body = new Uint8Array([0x0a, sub.length, ...sub]);

  const resp = await fetch("https://gew1-spclient.spotify.com/canvaz-cache/v0/canvases", {
    method: "POST",
    headers: { "Content-Type": "application/x-protobuf", ...authHeaders },
    body,
  });
  if (!resp.ok) {
    if (resp.status === 401 || resp.status === 403) sawAuthError = true;
    console.error(`Canvas API failed (${resp.status})`);
    // Exit code 2 = auth failure (caller should refresh the token and retry).
    // Exit code 1 = anything else (e.g. no canvas for this track).
    process.exit(sawAuthError ? 2 : 1);
  }

  const raw = new Uint8Array(await resp.arrayBuffer());
  const url = scanProtobuf(raw);
  if (!url) { console.error("No canvas found"); process.exit(1); }
  return parseUrl(url);
}

function scanProtobuf(data: Uint8Array): string | null {
  let i = 0;
  const rv = () => { let v = 0, s = 0; while (i < data.length) { const b = data[i++]; v |= (b & 0x7f) << s; s += 7; if (!(b & 0x80)) return v; } return v; };
  while (i < data.length) {
    const tag = rv(), f = tag >> 3, w = tag & 7;
    if (f === 1 && w === 2) {
      const end = i + rv();
      const si = i;
      while (i < end) {
        const stag = rv(), sf = stag >> 3;
        const slen = rv();
        if (sf === 2) { const s = new TextDecoder().decode(data.slice(i, i + slen)); if (s.startsWith("http")) return s; }
        i += slen;
      }
    } else if (w === 2) { i += rv(); } else if (w === 0) { rv(); } else break;
  }
  return null;
}

async function dl(url: string, path: string, retries = 3): Promise<boolean> {
  for (let a = 1; a <= retries; a++) {
    try {
      const resp = await fetch(url, { headers: HEADERS });
      if (!resp.ok) { if (a < retries) { await new Promise((r) => setTimeout(r, 1000 * a)); continue; } return false; }
      await finished(Readable.fromWeb(resp.body! as any).pipe(createWriteStream(path)));
      return true;
    } catch { if (a < retries) await new Promise((r) => setTimeout(r, 1000)); else return false; }
  }
  return false;
}

async function downloadCanvas(canvas: ReturnType<typeof parseUrl>, output: string) {
  if (canvas.type === "direct") {
    console.log(`Downloading canvas video...`);
    if (!(await dl(canvas.url, output))) { console.error("Download failed"); process.exit(1); }
    console.log(`Done: ${output}`);
    return;
  }

  const { origin, source, encoding, profile, token, fauth, tokenAk, tokenCf } = canvas as CanvasInfo;
  const base = `https://video-cf.spotifycdn.com/segments/v1/origins/${origin}/sources/${source}/encodings/${encoding}/profiles/${profile}`;
  const params = new URLSearchParams({ token, fauth });
  if (tokenAk) params.set("token_ak", tokenAk);
  if (tokenCf) params.set("token_cf", tokenCf);
  const qs = "?" + params.toString();

  const TMP = "segments_tmp";
  await mkdir(TMP, { recursive: true });

  const initPath = join(TMP, "init.mp4");
  console.log("Downloading init...");
  if (!(await dl(`${base}/inits/mp4${qs}`, initPath))) { console.error("Init failed"); process.exit(1); }

  const segPaths: string[] = [];
  for (let i = 0; ; i++) {
    const p = join(TMP, `${i}.mp4`);
    console.log(`Segment ${i}...`);
    if (!(await dl(`${base}/${i}.mp4${qs}`, p))) {
      if (i === 0) { console.error("Segment 0 failed"); process.exit(1); }
      try { await unlink(p); } catch { }
      break;
    }
    segPaths.push(p);
  }

  console.log(`Stitching ${segPaths.length} segments...`);
  const w = Bun.file(output).writer();
  for (const p of [initPath, ...segPaths]) w.write(await Bun.file(p).bytes());
  w.end(); await w.flush();
  console.log(`Done: ${output}`);
}

function extractTrackId(input: string): string {
  const m = input.match(/track[/]([a-zA-Z0-9]+)/) ?? input.match(/^([a-zA-Z0-9]{22})$/);
  if (!m) { console.error("provide track url"); process.exit(1); }
  return m[1];
}

async function main() {
  const input = process.argv[2];
  if (!input) { process.exit(1); }
  const trackId = extractTrackId(input);
  const output = process.argv[3] === "-o" ? process.argv[4] ?? `${trackId}.mp4` : `${trackId}.mp4`;
  console.error(`Track: ${trackId}`);
  const token = await getAccessToken();
  const canvas = await fetchCanvasInfo(trackId, token);
  await downloadCanvas(canvas, output);
}

main();
