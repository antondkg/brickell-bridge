#!/usr/bin/env python3
"""Turn OpenStreetMap data around the Brickell Avenue Bridge into public/city.json.

Coordinates are meters in a local frame centered on the bascule span:
x = east, z = south (so north is -z, matching three.js with y up).

Usage:
  python3 scripts/build_city.py --fetch        # download OSM data into scripts/osm/ (Overpass)
  python3 scripts/build_city.py                # build public/city.json from scripts/osm/

Data (c) OpenStreetMap contributors, ODbL. Requires: pip install shapely
"""
import json
import math
import sys
import subprocess
import time
from pathlib import Path

from shapely.geometry import LineString, MultiLineString, Point, Polygon, box
from shapely.ops import linemerge, polygonize, unary_union

ROOT = Path(__file__).resolve().parent
OSM_DIR = ROOT / "osm"
OUT = ROOT.parent / "public" / "city.json"

LAT0, LON0 = 25.769925, -80.19003            # center of the Brickell Avenue bascule span
M_PER_LAT = 110574.0
M_PER_LON = 111320.0 * math.cos(math.radians(LAT0))
VIEW = box(-2600, -3200, 3400, 2600)          # local meters kept in the scene
BUILDING_RADIUS = 1900

QUERIES = {
    "buildings": """[out:json][timeout:90];
(way["building"](25.752,-80.208,25.788,-80.176);relation["building"](25.752,-80.208,25.788,-80.176););
out body geom;""",
    "water": """[out:json][timeout:90];
(way["waterway"="river"](25.74,-80.215,25.80,-80.165);
 relation["natural"="water"](25.74,-80.215,25.80,-80.165);
 way["natural"="water"](25.74,-80.215,25.80,-80.165);
 way["natural"="coastline"](25.70,-80.25,25.84,-80.12););
out body geom;""",
    "roads": """[out:json][timeout:90];
(way["highway"~"^(motorway|trunk|primary|secondary|tertiary|residential|unclassified|motorway_link|trunk_link|primary_link|secondary_link|service)$"](25.752,-80.208,25.788,-80.176););
out body geom;""",
}

# Points we know are open water, used to tell bay pieces from land pieces after splitting by the coastline.
WATER_SEEDS = [(25.765, -80.175), (25.780, -80.172), (25.752, -80.180), (25.790, -80.178), (25.745, -80.17)]

ROAD_WIDTH = {"motorway": 16, "trunk": 14, "primary": 13, "secondary": 11, "tertiary": 9, "residential": 7,
              "unclassified": 7, "motorway_link": 8, "trunk_link": 8, "primary_link": 8, "secondary_link": 7, "service": 4.5}


def fetch():
    OSM_DIR.mkdir(exist_ok=True)
    for name, q in QUERIES.items():
        for attempt in range(5):
            try:
                body = subprocess.run(["curl", "-sf", "--max-time", "150", "-A", "brickell-bridge (github.com/antondkg/brickell-bridge)",
                                       "--data-urlencode", f"data={q}", "https://overpass-api.de/api/interpreter"],
                                      check=True, capture_output=True).stdout
                json.loads(body)
                (OSM_DIR / f"{name}.json").write_bytes(body)
                print("fetched", name)
                break
            except Exception as err:  # Overpass rate limits often; back off and retry
                print("retry", name, err)
                time.sleep(20)
        else:
            sys.exit(f"could not fetch {name}")


def xz(lat, lon):
    return ((lon - LON0) * M_PER_LON, (LAT0 - lat) * M_PER_LAT)


def line_of(geom):
    return [xz(p["lat"], p["lon"]) for p in geom]


def height_of(tags):
    for key in ("height", "building:height"):
        if key in tags:
            try:
                return float(tags[key].split()[0].rstrip("m"))
            except ValueError:
                pass
    if "building:levels" in tags:
        try:
            return float(tags["building:levels"]) * 3.4 + 2
        except ValueError:
            pass
    return None


def min_height_of(tags):
    if "min_height" in tags:
        try:
            return float(tags["min_height"].split()[0].rstrip("m"))
        except ValueError:
            pass
    if "building:min_level" in tags:
        try:
            return float(tags["building:min_level"]) * 3.4
        except ValueError:
            pass
    return 0.0


def ring(poly):
    coords = list(poly.exterior.coords)[:-1]
    if Polygon(coords).exterior.is_ccw:
        coords.reverse()
    return [round(v, 1) for p in coords for v in p]


def build_buildings(data):
    out = []
    for e in data["elements"]:
        tags = e.get("tags", {})
        polys = []
        if e["type"] == "way" and len(e.get("geometry", [])) >= 4:
            polys.append(Polygon(line_of(e["geometry"])))
        elif e["type"] == "relation":
            outers = [LineString(line_of(m["geometry"])) for m in e.get("members", []) if m.get("role") == "outer" and m.get("geometry")]
            polys += list(polygonize(linemerge(outers))) if outers else []
        h = height_of(tags)
        for p in polys:
            if not p.is_valid:
                p = p.buffer(0)
            if p.is_empty or p.area < 12 or p.centroid.distance(Point(0, 0)) > BUILDING_RADIUS:
                continue
            p = p.simplify(0.5, preserve_topology=True)
            if p.geom_type != "Polygon":
                continue
            height = h if h else round(7 + (abs(hash(e["id"])) % 70) / 10, 1)   # unknown: low-rise 7 to 14 m
            item = [round(height, 1), round(min_height_of(tags), 1), ring(p)]
            name = tags.get("name")
            if name and height > 60:
                item.append(name)
            out.append(item)
    out.sort(key=lambda b: -b[0])
    return out


def build_water(data):
    river = []
    for e in data["elements"]:
        tags = e.get("tags", {})
        if e["type"] == "relation" and tags.get("natural") == "water":
            outers = [LineString(line_of(m["geometry"])) for m in e["members"] if m.get("role") == "outer" and m.get("geometry")]
            inners = [LineString(line_of(m["geometry"])) for m in e["members"] if m.get("role") == "inner" and m.get("geometry")]
            shape = unary_union(list(polygonize(linemerge(outers))))
            if inners:
                shape = shape.difference(unary_union(list(polygonize(linemerge(inners)))))
            river.append(shape)
        elif e["type"] == "way" and tags.get("natural") == "water" and len(e.get("geometry", [])) >= 4:
            river.append(Polygon(line_of(e["geometry"])).buffer(0))

    coast = [LineString(line_of(e["geometry"])) for e in data["elements"] if e.get("tags", {}).get("natural") == "coastline"]
    frame = box(-4500, -6500, 6500, 6500)  # must sit inside the coastline query so every coast line crosses it
    pieces = polygonize(unary_union(coast + [frame.exterior]))
    seeds = [Point(*xz(lat, lon)) for lat, lon in WATER_SEEDS]
    bay = [p for p in pieces if any(p.contains(s) for s in seeds)]

    water = unary_union(river + bay).buffer(0).intersection(VIEW).simplify(0.8)
    polys = [water] if water.geom_type == "Polygon" else list(water.geoms)
    out = []
    for p in polys:
        if p.area < 50:
            continue
        out.append({"outer": ring(p), "holes": [[round(v, 1) for pt in list(h.coords)[:-1] for v in pt] for h in p.interiors if Polygon(h).area > 30]})

    centerline = None
    for e in data["elements"]:
        t = e.get("tags", {})
        if e["type"] == "way" and t.get("waterway") == "river" and len(e.get("geometry", [])) > 10:
            centerline = [round(v, 1) for pt in line_of(e["geometry"]) for v in pt]
    return out, centerline


def build_roads(data):
    out = []
    for e in data["elements"]:
        t = e.get("tags", {})
        if "highway" not in t or t.get("bridge:movable") or t.get("tunnel") or t.get("area") == "yes":
            continue
        line = LineString(line_of(e["geometry"])).simplify(0.6)
        if line.length < 5:
            continue
        width = ROAD_WIDTH.get(t.get("highway"), 6)
        layer = 1 if t.get("bridge") else 0
        out.append([width, layer, [round(v, 1) for pt in line.coords for v in pt]])
    return out


def build_route(data):
    """Centerline of Brickell Avenue and its continuation north of the bridge, sampled every 10 m of z."""
    segs = []
    for e in data["elements"]:
        t = e.get("tags", {})
        if t.get("highway") in ("primary", "trunk", "secondary") and len(e.get("geometry", [])) >= 2:
            pts = line_of(e["geometry"])
            segs += list(zip(pts, pts[1:]))
    route, x = [], 0.0
    for z in range(-700, 1101, 10):
        best = None
        for (ax, az), (bx, bz) in segs:
            if (az - z) * (bz - z) > 0 or az == bz:
                continue
            cx = ax + (bx - ax) * (z - az) / (bz - az)
            if abs(cx - x) < 45 and (best is None or abs(cx - x) < abs(best - x)):
                best = cx
        x = best if best is not None else x
        route.append([round(x, 1), z])
    # Two-way roads are mapped as two one-way lines; smooth to the middle.
    sm = []
    for i in range(len(route)):
        w = route[max(0, i - 3): i + 4]
        sm += [round(sum(p[0] for p in w) / len(w), 1), route[i][1]]
    return sm


def main():
    if "--fetch" in sys.argv:
        fetch()
    load = lambda n: json.loads((OSM_DIR / f"{n}.json").read_text())
    buildings = build_buildings(load("buildings"))
    water, river = build_water(load("water"))
    roads = build_roads(load("roads"))
    route = build_route(load("roads"))
    city = {
        "attribution": "Map data (c) OpenStreetMap contributors, ODbL",
        "origin": [LAT0, LON0],
        "view": [round(v) for v in VIEW.bounds],
        "bridge": {"hinges": [round(xz(25.76974, LON0)[1], 1), round(xz(25.77011, LON0)[1], 1)], "width": 28},
        "buildings": buildings,
        "water": water,
        "river": river,
        "roads": roads,
        "route": route,
    }
    OUT.write_text(json.dumps(city, separators=(",", ":")))
    print(f"{len(buildings)} buildings, {len(water)} water polygons, {len(roads)} roads -> {OUT} ({OUT.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
