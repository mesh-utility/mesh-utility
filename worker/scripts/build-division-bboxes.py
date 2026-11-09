#!/usr/bin/env python3
"""Build worker/src/division_bboxes.ts from the Flutter boundary assets.

Each division id maps to an axis-aligned box [minLat, maxLat, minLng, maxLng],
rounded outward to 0.01 degree. When the tight longitude span crosses the
antimeridian, minLng > maxLng (minLng..180 and -180..maxLng).

The worker resolves `division` query params through this table. It does not
ship polygons. Regenerate after assets/boundaries changes:

  python3 worker/scripts/build-division-bboxes.py
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BOUNDARIES = ROOT / "assets" / "boundaries"
OUT = ROOT / "worker" / "src" / "division_bboxes.ts"


def decode_ring(encoded: str, scale: int) -> list[tuple[float, float]]:
    points: list[tuple[float, float]] = []
    lng = 0
    lat = 0
    first = True
    for token in encoded.split(" "):
        if not token:
            continue
        x_text, y_text = token.split(",", 1)
        x = int(x_text)
        y = int(y_text)
        if first:
            lng, lat = x, y
            first = False
        else:
            lng += x
            lat += y
        points.append((lng / scale, lat / scale))
    return points


def iter_rings(raw) -> list[str]:
    rings: list[str] = []
    if isinstance(raw, str):
        rings.append(raw)
        return rings
    if isinstance(raw, list):
        for item in raw:
            rings.extend(iter_rings(item))
    return rings


def norm_lng(lng: float) -> float:
    x = lng
    while x > 180.0:
        x -= 360.0
    while x < -180.0:
        x += 360.0
    return x


def longitude_bounds(lngs: list[float]) -> tuple[float, float]:
    """Tightest longitude arc. start > end means the arc crosses ±180."""
    vals = sorted({round(norm_lng(x), 6) for x in lngs})
    if not vals:
        raise ValueError("no longitudes")
    if len(vals) == 1:
        return vals[0], vals[0]
    max_gap = -1.0
    max_i = 0
    for i, start in enumerate(vals):
        end = vals[0] + 360.0 if i == len(vals) - 1 else vals[i + 1]
        gap = end - start
        if gap > max_gap:
            max_gap = gap
            max_i = i
    start = vals[(max_i + 1) % len(vals)]
    end = vals[max_i]
    return start, end


def floor_centi(value: float) -> float:
    return math.floor(value * 100.0 + 1e-6) / 100.0


def ceil_centi(value: float) -> float:
    return math.ceil(value * 100.0 - 1e-6) / 100.0


def clean(value: float) -> float:
    snapped = round(value, 2)
    if snapped == 0:
        return 0.0
    return snapped


def clamp(value: float, low: float, high: float) -> float:
    if value < low:
        return low
    if value > high:
        return high
    return value


def box_for(points: list[tuple[float, float]]) -> tuple[float, float, float, float]:
    lats = [lat for _, lat in points]
    lngs = [lng for lng, _ in points]
    min_lat = clamp(floor_centi(min(lats)), -90.0, 90.0)
    max_lat = clamp(ceil_centi(max(lats)), -90.0, 90.0)
    if min_lat > max_lat:
        min_lat, max_lat = max_lat, min_lat
    start, end = longitude_bounds(lngs)
    if start <= end:
        min_lng = clamp(floor_centi(start), -180.0, 180.0)
        max_lng = clamp(ceil_centi(end), -180.0, 180.0)
        if min_lng > max_lng:
            min_lng, max_lng = -180.0, 180.0
    else:
        # Antimeridian: expand the eastern piece west and the western piece east.
        min_lng = clamp(floor_centi(start), -180.0, 180.0)
        max_lng = clamp(ceil_centi(end), -180.0, 180.0)
        if min_lng <= max_lng:
            min_lng, max_lng = -180.0, 180.0
    return (clean(min_lat), clean(max_lat), clean(min_lng), clean(max_lng))


def load_file(path: Path, id_prefix: str) -> dict[str, tuple[float, float, float, float]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    scale = int(payload.get("s") or 100)
    divisions = payload.get("d") or {}
    out: dict[str, tuple[float, float, float, float]] = {}
    for key, geom in divisions.items():
        points: list[tuple[float, float]] = []
        for ring in iter_rings(geom):
            points.extend(decode_ring(ring, scale))
        if not points:
            continue
        full_id = f"{id_prefix}:{key}" if id_prefix else str(key)
        out[full_id] = box_for(points)
    return out


def js_number(value: float) -> str:
    text = f"{value:.2f}".rstrip("0").rstrip(".")
    if text in ("-0", ""):
        return "0"
    return text


def main() -> int:
    boxes: dict[str, tuple[float, float, float, float]] = {}
    admin1_dir = BOUNDARIES / "admin1" / "countries"
    for path in sorted(admin1_dir.glob("*.json")):
        boxes.update(load_file(path, path.stem))
    admin2_dir = BOUNDARIES / "admin2" / "us" / "states"
    for path in sorted(admin2_dir.glob("*.json")):
        boxes.update(load_file(path, path.stem))

    admin1_index = json.loads((BOUNDARIES / "admin1" / "index.json").read_text(encoding="utf-8"))
    admin2_index = json.loads((BOUNDARIES / "admin2" / "us" / "index.json").read_text(encoding="utf-8"))
    expected = {row["i"] for row in admin1_index["divisions"]} | {row["i"] for row in admin2_index["divisions"]}
    missing = sorted(expected - boxes.keys())
    extra = sorted(set(boxes) - expected)
    if missing or extra:
        print(f"id mismatch missing={len(missing)} extra={len(extra)}", file=sys.stderr)
        if missing[:8]:
            print(" missing sample: " + ", ".join(missing[:8]), file=sys.stderr)
        if extra[:8]:
            print(" extra sample: " + ", ".join(extra[:8]), file=sys.stderr)
        return 1

    antimeridian = sum(1 for _min_lat, _max_lat, min_lng, max_lng in boxes.values() if min_lng > max_lng)
    lines = [
        "// Generated by worker/scripts/build-division-bboxes.py. Do not edit by hand.",
        "// id -> [minLat, maxLat, minLng, maxLng] in degrees, rounded outward to 0.01.",
        "// minLng > maxLng means the box crosses the antimeridian:",
        "// longitude is minLng..180 and -180..maxLng. The worker does not store polygons.",
        f"// {len(boxes)} divisions ({antimeridian} cross the antimeridian).",
        "export const divisionBboxes: Readonly<",
        "  Record<string, readonly [number, number, number, number]>",
        "> = {",
    ]
    for division_id in sorted(boxes):
        min_lat, max_lat, min_lng, max_lng = boxes[division_id]
        key = json.dumps(division_id, ensure_ascii=False)
        lines.append(
            f"  {key}: [{js_number(min_lat)}, {js_number(max_lat)}, {js_number(min_lng)}, {js_number(max_lng)}],"
        )
    lines.append("};")
    lines.append("")
    OUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {OUT} divisions={len(boxes)} antimeridian={antimeridian}")
    ca = boxes.get("US:US-CA")
    la = boxes.get("CA:06037")
    ak = boxes.get("US:US-AK")
    print(f"US:US-CA {ca}")
    print(f"CA:06037 {la}")
    print(f"US:US-AK {ak}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
