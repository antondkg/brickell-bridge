#!/usr/bin/env python3
"""Download Miami-Dade County's aerial imagery once and bake it into the site as two textures.

  public/ortho-core.webp   1 km around the bridge at about 0.25 m per pixel
  public/ortho-wide.webp   the whole scene at about 1.5 m per pixel

Images are requested in EPSG:4326 so pixels map linearly onto the scene's local x/z frame
(see build_city.py). Imagery (c) Miami-Dade County, 2025 aerial photography.

Usage: python3 scripts/build_imagery.py      (needs Pillow and cwebp)
"""
import io
import json
import math
import subprocess
import time
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent
PUBLIC = ROOT.parent / "public"
SERVICE = "https://gisweb.miamidade.gov/arcgis/rest/services/MapCache/MDCImagery_WebMercator/MapServer/export"

LAT0, LON0 = 25.769925, -80.19003
M_PER_LAT = 110574.0
M_PER_LON = 111320.0 * math.cos(math.radians(LAT0))
CHUNK = 2000          # pixels per request edge


def lonlat(x, z):
    return LON0 + x / M_PER_LON, LAT0 - z / M_PER_LAT


def fetch_area(x0, z0, x1, z1, mpp):
    """Stitch an image of local box [x0,x1] x [z0,z1] (z = south) at mpp meters per pixel."""
    w, h = round((x1 - x0) / mpp), round((z1 - z0) / mpp)
    out = Image.new("RGB", (w, h))
    for py in range(0, h, CHUNK):
        for px in range(0, w, CHUNK):
            cw, ch = min(CHUNK, w - px), min(CHUNK, h - py)
            ax, bx = x0 + px * mpp, x0 + (px + cw) * mpp
            az, bz = z0 + py * mpp, z0 + (py + ch) * mpp
            lon_a, lat_top = lonlat(ax, az)
            lon_b, lat_bot = lonlat(bx, bz)
            url = (f"{SERVICE}?bbox={lon_a},{lat_bot},{lon_b},{lat_top}&bboxSR=4326&imageSR=4326"
                   f"&size={cw},{ch}&format=jpg&f=image")
            for attempt in range(4):
                try:
                    # curl rather than urllib: python.org builds on macOS often lack a CA bundle
                    data = subprocess.run(["curl", "-sf", "--max-time", "120", "-A", "brickell-bridge", url], check=True, capture_output=True).stdout
                    tile = Image.open(io.BytesIO(data)).convert("RGB")
                    break
                except Exception as err:
                    print("retry", err)
                    time.sleep(5)
            else:
                raise SystemExit("imagery request failed")
            out.paste(tile.resize((cw, ch)), (px, py))
            print(f"  {px},{py} {cw}x{ch}")
    return out


def save_webp(img, name, quality):
    tmp = PUBLIC / f"{name}.png"
    img.save(tmp)
    subprocess.run(["cwebp", "-quiet", "-q", str(quality), str(tmp), "-o", str(PUBLIC / f"{name}.webp")], check=True)
    tmp.unlink()
    print(name, (PUBLIC / f"{name}.webp").stat().st_size // 1024, "KB")


def main():
    city = json.loads((PUBLIC / "city.json").read_text())
    vx0, vz0, vx1, vz1 = city["view"]
    core = (-500, -500, 500, 500)
    print("core")
    save_webp(fetch_area(*core, 0.25), "ortho-core", 72)
    print("wide")
    save_webp(fetch_area(vx0, vz0, vx1, vz1, 1.5), "ortho-wide", 70)
    meta = {"core": list(core), "wide": [vx0, vz0, vx1, vz1], "credit": "Imagery (c) Miami-Dade County"}
    (PUBLIC / "ortho.json").write_text(json.dumps(meta))


if __name__ == "__main__":
    main()
