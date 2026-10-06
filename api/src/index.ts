import { DurableObject } from "cloudflare:workers";

interface Env {
  TRACKER: DurableObjectNamespace<BridgeTracker>;
  BRIDGE_ID: string;
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

    if (url.pathname === "/v1/kick") return new Response("ok");
    return new Response("Not found", { status: 404 });
  }
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

    const { pathname } = new URL(request.url);
    if (pathname === "/") {
      return Response.json(
        {
          name: "Brickell Bridge API",
          source: "https://github.com/antondkg/brickell-bridge",
          endpoints: ["/v1/status", "/v1/openings?days=35"],
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
