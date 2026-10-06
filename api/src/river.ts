// Miami River drawbridges, in order from the bay. A boat going up or down the river has to open them in
// sequence, so upstream openings warn about Brickell, and South Miami Avenue (which FL511 doesn't report)
// can be estimated from its two neighbors.

export interface RiverBridge {
  key: string;
  name: string;
  fl511Id?: string;   // missing = not reported by FL511, estimated instead
  mile?: number;      // USCG river mile where 33 CFR 117.305 gives one
}

export const RIVER_BRIDGES: RiverBridge[] = [
  { key: "brickell", name: "Brickell Avenue", fl511Id: "253", mile: 0.1 },
  { key: "south-miami", name: "South Miami Avenue", mile: 0.3 },
  { key: "sw-2nd-ave", name: "SW 2nd Avenue", fl511Id: "261", mile: 0.5 },
  { key: "sw-1st-st", name: "SW 1st Street", fl511Id: "264", mile: 0.9 },
  { key: "w-flagler", name: "West Flagler Street", fl511Id: "265" },
  { key: "nw-5th-st", name: "NW 5th Street", fl511Id: "263" },
  { key: "nw-12th-ave", name: "NW 12th Avenue", fl511Id: "246" },
  { key: "nw-17th-ave", name: "NW 17th Avenue", fl511Id: "5985" },
  { key: "nw-22nd-ave", name: "NW 22nd Avenue", fl511Id: "5986" },
  { key: "nw-27th-ave", name: "NW 27th Avenue", fl511Id: "262", mile: 3.7 },
];

// South Miami Avenue sits about 350 m above Brickell and 400 m below SW 2nd Avenue.
export const SOUTH_MIAMI = { lat: 25.76966, lonWest: -80.19755, lonEast: -80.19003 };
const PAIR_WINDOW_S = 25 * 60;      // Brickell and SW 2nd Ave openings this close together are the same boat
const DEFAULT_TRAVEL_MIN = 8;       // SW 2nd Ave -> Brickell until we've learned it from history

export interface Opening { start: number; end: number | null }
export interface Live { state: "up" | "down" | "unknown"; since: number | null }

/** Pair each SW 2nd Ave opening with a Brickell opening close in time: that's one boat passing both. */
export function pairOpenings(brickell: Opening[], sw2: Opening[]) {
  const pairs: { brickell: Opening; sw2: Opening; downriver: boolean }[] = [];
  const used = new Set<number>();
  for (const s of sw2) {
    let best: Opening | null = null;
    for (const b of brickell) {
      if (used.has(b.start) || Math.abs(b.start - s.start) > PAIR_WINDOW_S) continue;
      if (!best || Math.abs(b.start - s.start) < Math.abs(best.start - s.start)) best = b;
    }
    if (best) {
      used.add(best.start);
      pairs.push({ brickell: best, sw2: s, downriver: s.start <= best.start });
    }
  }
  return pairs;
}

/** Median minutes from a SW 2nd Ave opening to the Brickell opening for boats heading down to the bay. */
export function learnTravelMin(brickell: Opening[], sw2: Opening[]): { minutes: number; samples: number } {
  const gaps = pairOpenings(brickell, sw2)
    .filter((p) => p.downriver)
    .map((p) => (p.brickell.start - p.sw2.start) / 60)
    .sort((a, b) => a - b);
  if (gaps.length < 3) return { minutes: DEFAULT_TRAVEL_MIN, samples: gaps.length };
  return { minutes: Math.round(gaps[Math.floor(gaps.length / 2)]), samples: gaps.length };
}

/** South Miami Avenue openings inferred from paired Brickell and SW 2nd Ave openings (midpoint in time). */
export function inferSouthMiami(brickell: Opening[], sw2: Opening[]): Opening[] {
  return pairOpenings(brickell, sw2).map(({ brickell: b, sw2: s }) => {
    const start = Math.round((b.start + s.start) / 2);
    const durations = [b, s].filter((o) => o.end != null).map((o) => o.end! - o.start);
    const dur = durations.length ? durations.reduce((a, d) => a + d, 0) / durations.length : null;
    return { start, end: dur == null ? null : Math.round(start + dur) };
  });
}

export interface SouthMiamiEstimate {
  state: "likely-up" | "opening-soon" | "likely-down";
  confidence: "low" | "medium" | "high";
  reason: string;
}

/**
 * Best guess for South Miami Avenue right now.
 * `boatBetween` = a moving vessel on AIS between Brickell and SW 2nd Ave.
 */
export function estimateSouthMiami(now: number, brickell: Live, sw2: Live, lastBrickell: Opening | undefined, lastSw2: Opening | undefined, boatBetween: boolean): SouthMiamiEstimate {
  const recent = (o: Opening | undefined, s: number) => !!o && now - o.start < s;
  if (brickell.state === "up" && sw2.state === "up") {
    return { state: "likely-up", confidence: "high", reason: "Brickell and SW 2nd Avenue are both up, so a boat is passing between them." };
  }
  if (boatBetween && (brickell.state === "up" || sw2.state === "up")) {
    return { state: "likely-up", confidence: "medium", reason: "A boat is moving between Brickell and SW 2nd Avenue." };
  }
  if (brickell.state === "up") {
    // SW 2nd Ave opened first: the boat came down the river and has already cleared South Miami Avenue.
    if (recent(lastSw2, PAIR_WINDOW_S) && lastSw2!.start <= (lastBrickell?.start ?? now)) {
      return { state: "likely-down", confidence: "medium", reason: "The boat came down from SW 2nd Avenue and has likely already passed it." };
    }
    return { state: "opening-soon", confidence: "low", reason: "Brickell is up for a boat from the bay; if it's heading upriver, South Miami Avenue opens next." };
  }
  if (sw2.state === "up") {
    if (recent(lastBrickell, PAIR_WINDOW_S)) {
      return { state: "likely-down", confidence: "medium", reason: "The boat came up from Brickell and has likely already passed it." };
    }
    return { state: "opening-soon", confidence: "medium", reason: "SW 2nd Avenue is up for a boat heading down the river; South Miami Avenue is next." };
  }
  return { state: "likely-down", confidence: "medium", reason: "Neither neighboring bridge is up." };
}
