import { DurableObject } from "cloudflare:workers";
import { AIS_BOX, assess, parseMessage, type Vessel } from "./ais";
import { RIVER_BRIDGES, SOUTH_MIAMI, estimateSouthMiami, inferSouthMiami, learnTravelMin, type Live, type Opening } from "./river";

interface Env {
  TRACKER: DurableObjectNamespace<BridgeTracker>;
  ASSETS: Fetcher;
  BRIDGE_ID: string;
  GOOGLE_TILES_KEY?: string;
  AISSTREAM_KEY?: string;
}

type State = "up" | "down" | "unknown";

const FL511_LIST =
  "https://fl511.com/List/GetData/Bridge?lang=en-US&query=" +
  encodeURIComponent(JSON.stringify({ columns: [{ data: null, name: "" }], start: 0, length: 100, search: { value: "" } }));
const USER_AGENT = "Mozilla/5.0 (compatible; brickell-bridge; +https://github.com/antondkg/brickell-bridge)";
const POLL_MS = 15_000;
// An opening longer than this means a close was missed, so it's dropped instead of skewing stats.
const MAX_OPENING_S = 3 * 3600;
const MAX_DAYS = 120;
// AIS: listen for this long, then rest, to keep the Durable Object well inside the free tier.
const AIS_LISTEN_MS = 25_000;
const AIS_EVERY_S = 60;

/** aisstream sends JSON as binary frames, which arrive as a Blob or ArrayBuffer depending on the runtime. */
async function messageText(data: unknown): Promise<string> {
  if (typeof data === "string") return data;
  if (data instanceof ArrayBuffer || ArrayBuffer.isView(data)) return new TextDecoder().decode(data as ArrayBuffer);
  if (data && typeof (data as Blob).text === "function") return (data as Blob).text();
  return "";
}

const iso = (s: number | null) => (s == null ? null : new Date(s * 1000).toISOString().replace(".000Z", "Z"));
const nowS = () => Math.floor(Date.now() / 1000);

function parseState(status: string): State {
  const s = status.toLowerCase();
  if (s.includes("up")) return "up";
  if (s.includes("down")) return "down";
  return "unknown";
}

/** One instance per bridge. Owns the SQLite history and the 15s polling loop. */
export class BridgeTracker extends DurableObject<Env> {
  private sql: SqlStorage;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS openings (start INTEGER PRIMARY KEY, end INTEGER);
      CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
      CREATE TABLE IF NOT EXISTS river_openings (bridge TEXT, start INTEGER, end INTEGER, PRIMARY KEY (bridge, start));
      CREATE TABLE IF NOT EXISTS river_state (bridge TEXT PRIMARY KEY, name TEXT, state TEXT, since INTEGER, checked INTEGER);
      CREATE TABLE IF NOT EXISTS vessels (
        mmsi INTEGER PRIMARY KEY, name TEXT, type INTEGER, length REAL,
        lat REAL, lon REAL, sog REAL, cog REAL, updated INTEGER
      );
    `);
    if (!this.meta("tracking_since")) this.setMeta("tracking_since", String(nowS()));
  }

  private meta(key: string): string | undefined {
    return this.sql.exec<{ value: string }>("SELECT value FROM meta WHERE key = ?", key).toArray()[0]?.value;
  }

  private setMeta(key: string, value: string) {
    this.sql.exec("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", key, value);
  }

  private async ensureAlarm() {
    if ((await this.ctx.storage.getAlarm()) == null) await this.ctx.storage.setAlarm(Date.now() + 1000);
  }

  async alarm() {
    this.ctx.waitUntil(this.sampleAis().catch((err) => console.error("ais failed", err)));
    try {
      await this.poll();
    } catch (err) {
      console.error("poll failed", err);
    } finally {
      await this.ctx.storage.setAlarm(Date.now() + POLL_MS);
    }
  }

  private async poll() {
    const res = await fetch(FL511_LIST, { headers: { "User-Agent": USER_AGENT } });
    if (!res.ok) throw new Error(`FL511 ${res.status}`);
    const json = (await res.json()) as { data: Record<string, unknown>[] };
    const row = json.data.find((r) => r.DT_RowId === this.env.BRIDGE_ID);
    if (!row) throw new Error(`bridge ${this.env.BRIDGE_ID} not in FL511 list`);

    const state = parseState(String(row.status ?? ""));
    const since = Number(row.lastNotificationTime) || null;
    const now = nowS();
    this.setMeta("name", String(row.name ?? ""));
    this.setMeta("state", state);
    this.setMeta("since", since == null ? "" : String(since));
    this.setMeta("checked_at", String(now));
    this.record(state, since, now);

    // Every other Miami River bridge FL511 reports comes in the same response.
    for (const b of RIVER_BRIDGES) {
      const r = b.fl511Id && json.data.find((x) => x.DT_RowId === b.fl511Id);
      if (!r) continue;
      const st = parseState(String(r.status ?? ""));
      const sn = Number(r.lastNotificationTime) || null;
      this.sql.exec(
        "INSERT INTO river_state (bridge, name, state, since, checked) VALUES (?, ?, ?, ?, ?) ON CONFLICT(bridge) DO UPDATE SET name = excluded.name, state = excluded.state, since = excluded.since, checked = excluded.checked",
        b.key, b.name, st, sn, now,
      );
      this.recordRiver(b.key, st, sn, now);
    }
  }

  /** Same rules as record(), for any river bridge. */
  private recordRiver(bridge: string, state: State, since: number | null, now: number) {
    const at = Math.min(since ?? now, now);
    const last = this.sql
      .exec<{ start: number; end: number | null }>("SELECT start, end FROM river_openings WHERE bridge = ? ORDER BY start DESC LIMIT 1", bridge)
      .toArray()[0];
    if (state === "up") {
      if (last && last.end == null) {
        if (at - last.start <= 60) return;
        this.sql.exec("DELETE FROM river_openings WHERE bridge = ? AND start = ?", bridge, last.start);
      } else if (last && last.end != null && at <= last.end) {
        return;
      }
      this.sql.exec("INSERT OR IGNORE INTO river_openings (bridge, start, end) VALUES (?, ?, NULL)", bridge, at);
    } else if (state === "down") {
      if (!last || last.end != null) return;
      const end = Math.max(at, last.start);
      if (end - last.start > MAX_OPENING_S) this.sql.exec("DELETE FROM river_openings WHERE bridge = ? AND start = ?", bridge, last.start);
      else this.sql.exec("UPDATE river_openings SET end = ? WHERE bridge = ? AND start = ?", end, bridge, last.start);
    }
  }

  private brickellOpenings(from: number): Opening[] {
    return this.sql.exec<Opening>("SELECT start, end FROM openings WHERE start >= ? ORDER BY start", from).toArray();
  }

  private riverOpenings(bridge: string, from: number): Opening[] {
    return this.sql.exec<Opening>("SELECT start, end FROM river_openings WHERE bridge = ? AND start >= ? ORDER BY start", bridge, from).toArray();
  }

  private riverLive(bridge: string): Live {
    const r = this.sql.exec<{ state: Live["state"]; since: number | null }>("SELECT state, since FROM river_state WHERE bridge = ?", bridge).toArray()[0];
    return r ?? { state: "unknown", since: null };
  }

  /** Every river bridge's state, the South Miami Avenue estimate, and an early warning for Brickell. */
  private riverSummary() {
    const now = nowS();
    const history = now - 60 * 86400;
    const brickellHist = this.brickellOpenings(history);
    const sw2Hist = this.riverOpenings("sw-2nd-ave", history);
    const travel = learnTravelMin(brickellHist, sw2Hist);
    const brickell: Live = { state: (this.meta("state") as Live["state"]) ?? "unknown", since: Number(this.meta("since")) || null };
    const sw2 = this.riverLive("sw-2nd-ave");
    const lastB = brickellHist[brickellHist.length - 1];
    const lastS = sw2Hist[sw2Hist.length - 1];
    const boatBetween = this.sql
      .exec("SELECT 1 FROM vessels WHERE lat BETWEEN 25.767 AND 25.772 AND lon BETWEEN ? AND ? AND sog >= 0.5 AND updated > ?",
        SOUTH_MIAMI.lonWest, SOUTH_MIAMI.lonEast, now - 600)
      .toArray().length > 0;
    const southMiami = estimateSouthMiami(now, brickell, sw2, lastB, lastS, boatBetween);

    // Early warning: an upstream bridge opened and Brickell hasn't yet, so a boat is probably coming down.
    let upstream: Record<string, unknown> | null = null;
    if (brickell.state !== "up") {
      for (const [key, name, factor] of [["sw-2nd-ave", "SW 2nd Avenue", 1], ["sw-1st-st", "SW 1st Street", 2]] as const) {
        const last = this.riverOpenings(key, now - 3600).pop();
        const expected = last ? last.start + travel.minutes * factor * 60 : 0;
        if (last && now < expected + 10 * 60 && (!lastB || lastB.start < last.start)) {
          upstream = { from: name, openedAt: iso(last.start), brickellExpected: iso(expected), minutes: Math.max(0, Math.round((expected - now) / 60)) };
          break;
        }
      }
    }

    const midnightMiami = now - local(new Date(now * 1000)).minute * 60 - (now % 60);   // start of today in Miami
    const bridges = RIVER_BRIDGES.map((b) => {
      if (!b.fl511Id) {
        return { key: b.key, name: b.name, source: "estimated", ...southMiami,
          inferredToday: inferSouthMiami(brickellHist, sw2Hist).filter((o) => o.start >= midnightMiami).length };
      }
      const live = b.key === "brickell" ? brickell : this.riverLive(b.key);
      return { key: b.key, name: b.name, source: "fl511", state: live.state, since: iso(live.since),
        openingsToday: b.key === "brickell" ? brickellHist.filter((o) => o.start >= midnightMiami).length : this.riverOpenings(b.key, midnightMiami).length };
    });
    return { bridges, southMiami, upstream, travel: { sw2ToBrickellMin: travel.minutes, learnedFrom: travel.samples } };
  }

  private aisBusy = false;

  /** Open the aisstream socket for a short window and record every vessel we hear about. */
  private async sampleAis() {
    const key = this.env.AISSTREAM_KEY;
    const last = Number(this.meta("ais_started") ?? 0);
    if (!key || this.aisBusy || nowS() - last < AIS_EVERY_S) return;
    this.aisBusy = true;
    this.setMeta("ais_started", String(nowS()));
    try {
      const res = await fetch("https://stream.aisstream.io/v0/stream", { headers: { Upgrade: "websocket" } });
      const ws = res.webSocket;
      if (!ws) throw new Error(`aisstream upgrade failed: ${res.status}`);
      ws.accept();
      let count = 0;
      ws.addEventListener("close", (e) => this.setMeta("ais_last_close", `${e.code} ${e.reason}`.slice(0, 200)));
      ws.addEventListener("message", async (e) => {
        const text = await messageText(e.data);
        const v = parseMessage(text);
        if (v) { this.upsertVessel(v); count++; }
        else this.setMeta("ais_last_other", text.slice(0, 300));   // errors from aisstream arrive as plain JSON
      });
      ws.send(JSON.stringify({
        APIKey: key,
        BoundingBoxes: [AIS_BOX],
        FilterMessageTypes: ["PositionReport", "StandardClassBPositionReport", "ExtendedClassBPositionReport", "ShipStaticData", "StaticDataReport"],
      }));
      await new Promise((r) => setTimeout(r, AIS_LISTEN_MS));
      ws.close(1000, "done");
      this.setMeta("ais_checked", String(nowS()));
      this.setMeta("ais_last_count", String(count));
      this.sql.exec("DELETE FROM vessels WHERE updated < ?", nowS() - 6 * 3600);
    } finally {
      this.aisBusy = false;
    }
  }

  private upsertVessel(v: Partial<Vessel> & { mmsi: number }) {
    this.sql.exec("INSERT OR IGNORE INTO vessels (mmsi, updated) VALUES (?, 0)", v.mmsi);
    for (const col of ["name", "type", "length", "lat", "lon", "sog", "cog", "updated"] as const) {
      const value = v[col];
      if (value !== undefined && value !== null) this.sql.exec(`UPDATE vessels SET ${col} = ? WHERE mmsi = ?`, value, v.mmsi);
    }
  }

  private vessels() {
    const now = nowS();
    const rows = this.sql.exec<Vessel>("SELECT * FROM vessels WHERE lat IS NOT NULL").toArray();
    return rows
      .map((v) => assess(v, now))
      .filter((a) => a !== null)
      .sort((a, b) => (a.etaMin ?? 1e9) - (b.etaMin ?? 1e9) || a.distanceM - b.distanceM);
  }

  /** Same rules as the app's original local log: one row per opening, end is null while it's up. */
  private record(state: State, since: number | null, now: number) {
    const at = Math.min(since ?? now, now);
    const last = this.sql
      .exec<{ start: number; end: number | null }>("SELECT start, end FROM openings ORDER BY start DESC LIMIT 1")
      .toArray()[0];

    if (state === "up") {
      if (last && last.end == null) {
        // Same opening, unless FL511 reports a newer raise (a close was missed).
        if (at - last.start <= 60) return;
        this.sql.exec("DELETE FROM openings WHERE start = ?", last.start);
      } else if (last && last.end != null && at <= last.end) {
        return;
      }
      this.sql.exec("INSERT OR IGNORE INTO openings (start, end) VALUES (?, NULL)", at);
    } else if (state === "down") {
      if (!last || last.end != null) return;
      const end = Math.max(at, last.start);
      if (end - last.start > MAX_OPENING_S) this.sql.exec("DELETE FROM openings WHERE start = ?", last.start);
      else this.sql.exec("UPDATE openings SET end = ? WHERE start = ?", end, last.start);
    }
  }

  async fetch(request: Request): Promise<Response> {
    await this.ensureAlarm();
    const url = new URL(request.url);

    if (url.pathname === "/v1/status") {
      const since = this.meta("since");
      const checked = this.meta("checked_at");
      return Response.json({
        bridgeId: this.env.BRIDGE_ID,
        name: this.meta("name") ?? null,
        state: this.meta("state") ?? "unknown",
        since: since ? iso(Number(since)) : null,
        checkedAt: checked ? iso(Number(checked)) : null,
      });
    }

    if (url.pathname === "/v1/openings") {
      const days = Math.min(MAX_DAYS, Math.max(1, Number(url.searchParams.get("days")) || 35));
      const from = nowS() - days * 86400;
      const rows = this.sql
        .exec<{ start: number; end: number | null }>("SELECT start, end FROM openings WHERE start >= ? ORDER BY start", from)
        .toArray();
      return Response.json({
        bridgeId: this.env.BRIDGE_ID,
        trackingSince: iso(Number(this.meta("tracking_since"))),
        openings: rows.map((r) => ({ start: iso(r.start), end: iso(r.end) })),
      });
    }

    if (url.pathname === "/v1/vessels") {
      const checked = this.meta("ais_checked");
      return Response.json({
        tracking: !!this.env.AISSTREAM_KEY,
        checkedAt: checked ? iso(Number(checked)) : null,
        lastSampleMessages: Number(this.meta("ais_last_count") ?? 0),
        lastNotice: this.meta("ais_last_other") ?? this.meta("ais_last_close") ?? null,
        vessels: this.vessels(),
        note: "From AIS. Small boats often don't broadcast, so not every opening shows up here.",
      });
    }

    if (url.pathname === "/v1/river") return Response.json(this.riverSummary());

    if (url.pathname === "/v1/kick") return new Response("ok");
    return new Response("Not found", { status: 404 });
  }
}

// ---------------------------------------------------------------- opening schedule
// 33 CFR 117.305(d), Brickell Avenue Bridge: opens on signal, except Mon-Fri (not federal holidays)
// 7 AM to 7 PM it need only open on the hour and half hour, and it need not open 7:35-8:59 AM,
// 12:05-12:59 PM or 4:35-5:59 PM. Tugs, government vessels and emergencies are exempt.

const TZ = "America/New_York";
const BLACKOUTS: [number, number, string][] = [
  [7 * 60 + 35, 9 * 60, "morning rush hour"],
  [12 * 60 + 5, 13 * 60, "lunch hour"],
  [16 * 60 + 35, 18 * 60, "evening rush hour"],
];

function nthWeekday(year: number, month: number, weekday: number, n: number): number {
  const first = new Date(Date.UTC(year, month, 1)).getUTCDay();
  return 1 + ((weekday - first + 7) % 7) + (n - 1) * 7;
}
function lastWeekday(year: number, month: number, weekday: number): number {
  const lastDay = new Date(Date.UTC(year, month + 1, 0));
  return lastDay.getUTCDate() - ((lastDay.getUTCDay() - weekday + 7) % 7);
}
/** Federal holidays (observed) as "M-D" strings for a year. */
function federalHolidays(year: number): Set<string> {
  const fixed = (m: number, d: number) => {
    // Saturday holidays are observed Friday, Sunday holidays Monday
    const wd = new Date(Date.UTC(year, m, d)).getUTCDay();
    let shift = 0;
    if (wd === 6) shift = -1;
    if (wd === 0) shift = 1;
    const obs = new Date(Date.UTC(year, m, d + shift));
    return `${obs.getUTCMonth() + 1}-${obs.getUTCDate()}`;
  };
  return new Set([
    fixed(0, 1), `1-${nthWeekday(year, 0, 1, 3)}`, `2-${nthWeekday(year, 1, 1, 3)}`, `5-${lastWeekday(year, 4, 1)}`,
    fixed(5, 19), fixed(6, 4), `9-${nthWeekday(year, 8, 1, 1)}`, `10-${nthWeekday(year, 9, 1, 2)}`,
    fixed(10, 11), `11-${nthWeekday(year, 10, 4, 4)}`, fixed(11, 25),
  ]);
}

interface LocalTime { year: number; month: number; day: number; weekday: number; minute: number }
const WEEKDAYS: Record<string, number> = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };
const fmt = new Intl.DateTimeFormat("en-US", {
  timeZone: TZ, year: "numeric", month: "numeric", day: "numeric", weekday: "short", hour: "numeric", minute: "numeric", hourCycle: "h23",
});
function local(d: Date): LocalTime {
  const p = Object.fromEntries(fmt.formatToParts(d).map((x) => [x.type, x.value]));
  return { year: +p.year, month: +p.month, day: +p.day, weekday: WEEKDAYS[p.weekday], minute: +p.hour * 60 + +p.minute };
}

type Mode = "on-signal" | "half-hourly" | "closed-to-boats";
function modeAt(t: LocalTime): { mode: Mode; reason: string } {
  const workday = t.weekday >= 1 && t.weekday <= 5 && !federalHolidays(t.year).has(`${t.month}-${t.day}`);
  if (!workday) return { mode: "on-signal", reason: t.weekday === 0 || t.weekday === 6 ? "weekend" : "federal holiday" };
  const blackout = BLACKOUTS.find(([a, b]) => t.minute >= a && t.minute < b);
  if (blackout) return { mode: "closed-to-boats", reason: blackout[2] };
  if (t.minute >= 7 * 60 && t.minute < 19 * 60) return { mode: "half-hourly", reason: "weekday daytime" };
  return { mode: "on-signal", reason: "outside weekday restrictions" };
}

/** Where the schedule stands now and the next times the bridge is allowed to open. */
function forecast(now = new Date()) {
  const start = Math.floor(now.getTime() / 60000) * 60000;
  const current = modeAt(local(now));
  let modeUntil: number | null = null;
  const slots: number[] = [];
  for (let i = 1; i <= 36 * 60 && (modeUntil == null || slots.length < 4); i++) {
    const at = start + i * 60000;
    const lt = local(new Date(at));
    const m = modeAt(lt);
    if (modeUntil == null && m.mode !== current.mode) modeUntil = at;
    // a slot is a moment a waiting boat would get through: any minute when on signal, :00/:30 when half-hourly
    if (m.mode === "on-signal" && (slots.length === 0 || at - slots[slots.length - 1] >= 30 * 60000)) slots.push(at);
    if (m.mode === "half-hourly" && lt.minute % 30 === 0) slots.push(at);
  }
  const iso = (ms: number | null) => (ms == null ? null : new Date(ms).toISOString().replace(".000Z", "Z"));
  return {
    mode: current.mode,
    reason: current.reason,
    modeUntil: iso(modeUntil),
    nextSlots: slots.slice(0, 4).map(iso),
    rule: "33 CFR 117.305(d). Tugs, government vessels and emergencies can get an opening at any time.",
  };
}

// ---------------------------------------------------------------- short status for notifications (iOS Shortcuts)
const timeFmt = new Intl.DateTimeFormat("en-US", { timeZone: TZ, hour: "numeric", minute: "2-digit" });
const minsAgo = (iso: string | null) => (iso ? Math.max(0, Math.round((Date.now() - Date.parse(iso)) / 60000)) : null);
const ago = (m: number | null) => (m == null ? "" : m < 60 ? ` (${m} min)` : ` (${Math.floor(m / 60)}h ${m % 60}m)`);

interface SummaryInput {
  status: { state: string; since: string | null };
  river: { southMiami: { state: string }; upstream: { from: string; brickellExpected: string } | null };
  boats: { name: string | null; kind: string; etaMin: number | null }[];
  forecast: ReturnType<typeof forecast>;
}
/** One short headline plus a few lines, plain enough for a phone notification. */
function summarize({ status, river, boats, forecast: f }: SummaryInput) {
  const b = status.state;
  const since = status.since ? ` since ${timeFmt.format(new Date(status.since))}${ago(minsAgo(status.since))}` : "";
  const sm = river.southMiami.state;
  const smShort = sm === "likely-up" ? "likely UP" : sm === "opening-soon" ? "may open soon" : "likely down";
  const title = b === "up" ? `Brickell is UP · S Miami ${smShort}` : b === "down" ? `Brickell is down · S Miami ${smShort}` : "Brickell bridge status unknown";
  const lines: string[] = [];
  if (b === "up") lines.push(`Brickell Ave bridge: UP, closed to traffic${since}.`);
  else if (b === "down") lines.push(`Brickell Ave bridge: down, open to traffic${since}.`);
  lines.push(`South Miami Ave bridge: ${smShort} (estimated).`);
  const boat = boats[0];
  if (boat?.etaMin != null) lines.push(`Heads up: ${boat.name ? `${boat.kind} ${boat.name}` : `a ${boat.kind}`} is heading for Brickell, about ${boat.etaMin} min out.`);
  else if (river.upstream && b !== "up") lines.push(`Heads up: ${river.upstream.from} just opened. Brickell may open around ${timeFmt.format(new Date(river.upstream.brickellExpected))}.`);
  else if (f.mode === "closed-to-boats" && f.modeUntil) lines.push(`No boat openings until ${timeFmt.format(new Date(f.modeUntil))} (${f.reason}).`);
  return { title, body: lines.join("\n"), text: `${title}\n${lines.join("\n")}` };
}

const tracker = (env: Env) => env.TRACKER.get(env.TRACKER.idFromName(`bridge-${env.BRIDGE_ID}`));

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
};

export default {
  async fetch(request, env): Promise<Response> {
    if (request.method === "OPTIONS") return new Response(null, { headers: CORS });
    if (request.method !== "GET") return new Response("Method not allowed", { status: 405, headers: CORS });

    const url = new URL(request.url);
    const { pathname, hostname } = url;
    if (pathname === "/v1/forecast") {
      const at = url.searchParams.get("at");
      const when = at ? new Date(at) : new Date();
      if (Number.isNaN(when.getTime())) return Response.json({ error: "at must be an ISO 8601 time" }, { status: 400, headers: CORS });
      const fc: Record<string, unknown> = forecast(when);
      if (!at) {
        try {
          const v = (await (await tracker(env).fetch("https://tracker/v1/vessels")).json()) as { vessels: { approaching: boolean; needsOpening: boolean }[] };
          fc.boats = v.vessels.filter((b) => b.approaching && b.needsOpening).slice(0, 5);
          const river = (await (await tracker(env).fetch("https://tracker/v1/river")).json()) as Record<string, unknown>;
          fc.southMiami = river.southMiami;
          fc.upstream = river.upstream;
        } catch {
          fc.boats = fc.boats ?? [];
        }
      }
      return Response.json(fc, { headers: { ...CORS, "Cache-Control": "public, max-age=30" } });
    }
    if (pathname === "/v1/summary") {
      const t = tracker(env);
      const [status, river, vessels] = await Promise.all([
        t.fetch("https://tracker/v1/status").then((r) => r.json()),
        t.fetch("https://tracker/v1/river").then((r) => r.json()),
        t.fetch("https://tracker/v1/vessels").then((r) => r.json()),
      ]) as [SummaryInput["status"], SummaryInput["river"], { vessels: (SummaryInput["boats"][number] & { approaching: boolean; needsOpening: boolean })[] }];
      const sum = summarize({ status, river, boats: vessels.vessels.filter((v) => v.approaching && v.needsOpening), forecast: forecast() });
      const headers = { ...CORS, "Cache-Control": "no-store" };
      if (url.searchParams.get("format") === "json") return Response.json(sum, { headers });
      return new Response(sum.text, { headers: { ...headers, "Content-Type": "text/plain; charset=utf-8" } });
    }
    if (pathname === "/config.json") {
      return Response.json({ googleTilesKey: env.GOOGLE_TILES_KEY ?? null }, { headers: { "Cache-Control": "public, max-age=300" } });
    }
    // brickellbridge.fun and www serve the 3D page; /v1/* is the API on every host.
    if (!hostname.startsWith("api.") && !pathname.startsWith("/v1/")) return env.ASSETS.fetch(request);
    if (pathname === "/") {
      return Response.json(
        {
          name: "Brickell Bridge API",
          source: "https://github.com/antondkg/brickell-bridge",
          endpoints: ["/v1/summary", "/v1/status", "/v1/openings?days=35", "/v1/forecast", "/v1/vessels", "/v1/river"],
          note: "Unofficial. Data comes from FL511 and may lag the real world.",
        },
        { headers: CORS },
      );
    }

    const res = await tracker(env).fetch(request);
    const out = new Response(res.body, res);
    for (const [k, v] of Object.entries(CORS)) out.headers.set(k, v);
    if (res.ok) out.headers.set("Cache-Control", "public, max-age=15");
    return out;
  },

  async scheduled(_event, env) {
    await tracker(env).fetch("https://tracker/v1/kick");
  },
} satisfies ExportedHandler<Env>;
