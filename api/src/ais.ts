// Live boat positions from AIS (aisstream.io), used to predict openings before they happen.
//
// Larger vessels broadcast AIS: tugs, freighters on the Miami River, most big yachts and many sailboats.
// Small boats often don't, so this catches many openings but not all of them.

export const BRIDGE = { lat: 25.769925, lon: -80.19003 };
// The Miami River upstream of the bridge plus the bay approaches.
export const AIS_BOX: [[number, number], [number, number]] = [[25.735, -80.255], [25.805, -80.14]];
const NEAR_M = 3000;          // only vessels within this distance of the bridge are interesting
const STALE_S = 15 * 60;      // ignore positions older than this

export interface Vessel {
  mmsi: number;
  name: string | null;
  type: number | null;        // AIS ship type code
  length: number | null;      // meters
  lat: number;
  lon: number;
  sog: number;                // speed over ground, knots
  cog: number;                // course over ground, degrees
  updated: number;            // unix seconds
}

export interface Approach {
  mmsi: number;
  name: string | null;
  kind: string;
  length: number | null;
  distanceM: number;
  speedKn: number;
  etaMin: number | null;
  approaching: boolean;
  needsOpening: boolean;
  side: "river" | "bay";
  updated: string;
}

const toRad = (d: number) => (d * Math.PI) / 180;

export function distanceM(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const dLat = toRad(lat2 - lat1), dLon = toRad(lon2 - lon1);
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return 6371000 * 2 * Math.asin(Math.sqrt(a));
}

function bearing(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const y = Math.sin(toRad(lon2 - lon1)) * Math.cos(toRad(lat2));
  const x = Math.cos(toRad(lat1)) * Math.sin(toRad(lat2)) - Math.sin(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.cos(toRad(lon2 - lon1));
  return ((Math.atan2(y, x) * 180) / Math.PI + 360) % 360;
}

export function kindOf(type: number | null): string {
  if (type == null) return "vessel";
  if (type === 31 || type === 32 || type === 52) return "tug";
  if (type === 36) return "sailboat";
  if (type === 37) return "pleasure boat";
  if (type >= 60 && type <= 69) return "passenger vessel";
  if (type >= 70 && type <= 79) return "cargo ship";
  if (type >= 80 && type <= 89) return "tanker";
  if (type === 35 || type === 55) return "government vessel";
  if (type === 30) return "fishing boat";
  return "vessel";
}

/** The closed bridge clears small boats; masts, tugs and freighters need it raised. */
export function needsOpening(type: number | null, length: number | null): boolean {
  const kind = kindOf(type);
  if (["sailboat", "tug", "cargo ship", "tanker", "passenger vessel", "government vessel"].includes(kind)) return true;
  return (length ?? 0) >= 24;
}

export function assess(v: Vessel, now: number): Approach | null {
  if (now - v.updated > STALE_S) return null;
  const dist = distanceM(v.lat, v.lon, BRIDGE.lat, BRIDGE.lon);
  if (dist > NEAR_M) return null;
  // West of the bridge is the river; east is the river mouth and the bay.
  const side = v.lon < BRIDGE.lon ? "river" : "bay";
  const toBridge = bearing(v.lat, v.lon, BRIDGE.lat, BRIDGE.lon);
  const off = Math.abs(((v.cog - toBridge + 540) % 360) - 180);
  // The river bends, so allow a wide cone upstream; in the bay the course should point at the mouth.
  const approaching = v.sog >= 0.5 && off < (side === "river" ? 75 : 45) && dist > 30;
  const etaMin = approaching ? Math.round(dist / (v.sog * 0.5144) / 60) : null;
  return {
    mmsi: v.mmsi,
    name: v.name,
    kind: kindOf(v.type),
    length: v.length,
    distanceM: Math.round(dist),
    speedKn: Math.round(v.sog * 10) / 10,
    etaMin,
    approaching,
    needsOpening: needsOpening(v.type, v.length),
    side,
    updated: new Date(v.updated * 1000).toISOString().replace(/\.\d+Z$/, "Z"),
  };
}

/** Pull the fields we care about out of one aisstream message. */
export function parseMessage(raw: string): Partial<Vessel> & { mmsi: number } | null {
  let msg: any;
  try { msg = JSON.parse(raw); } catch { return null; }
  const meta = msg?.MetaData;
  if (!meta?.MMSI) return null;
  const body = msg.Message ?? {};
  const out: Partial<Vessel> & { mmsi: number } = { mmsi: meta.MMSI };
  const clean = (s?: string) => (s ? s.replace(/@+/g, "").trim() || null : null);
  if (meta.ShipName) out.name = clean(meta.ShipName);

  const pos = body.PositionReport ?? body.StandardClassBPositionReport ?? body.ExtendedClassBPositionReport;
  if (pos && pos.Valid !== false && Math.abs(pos.Latitude) <= 90) {
    out.lat = pos.Latitude;
    out.lon = pos.Longitude;
    out.sog = pos.Sog >= 102.3 ? 0 : pos.Sog;
    out.cog = pos.Cog >= 360 ? 0 : pos.Cog;
    out.updated = Math.floor(Date.now() / 1000);
  }
  const stat = body.ShipStaticData;
  if (stat) {
    out.name = clean(stat.Name) ?? out.name;
    out.type = stat.Type ?? null;
    const d = stat.Dimension;
    if (d) out.length = (d.A ?? 0) + (d.B ?? 0) || null;
  }
  const rep = body.StaticDataReport;
  if (rep) {
    if (rep.ReportA?.Valid) out.name = clean(rep.ReportA.Name) ?? out.name;
    if (rep.ReportB?.Valid) {
      out.type = rep.ReportB.ShipType ?? null;
      const d = rep.ReportB.Dimension;
      if (d) out.length = (d.A ?? 0) + (d.B ?? 0) || null;
    }
  }
  return out;
}
