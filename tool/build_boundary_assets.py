#!/usr/bin/env python3
"""Build compact public-domain boundary assets for the scan cache.

Sources (downloaded separately; not committed):
  Natural Earth 1:10m cultural admin-1, public domain
    https://naciscdn.org/naturalearth/10m/cultural/ne_10m_admin_1_states_provinces.zip
  US Census Bureau cartographic counties, 1:20,000,000, public domain
    https://www2.census.gov/geo/tiger/GENZ2023/shp/cb_2023_us_county_20m.zip

Rings are unwrapped across the antimeridian, outer rings only (holes dropped),
Douglas-Peucker simplified, quantized, and delta-encoded. Admin-1 is split
per country. Counties are US-only and split per state postal code.

No small public-domain admin-2 dataset was found for other countries
(Natural Earth has no admin-2; geoBoundaries is CC-BY; GADM is not public
domain), so non-US counties are omitted.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from collections import defaultdict
from pathlib import Path

ADMIN1_EPS = 0.12
ADMIN1_SCALE = 100
COUNTY_EPS = 0.02
COUNTY_SCALE = 1000

ADMIN1_SOURCE = (
    "Natural Earth 1:10m admin-1 states and provinces, public domain, "
    f"Douglas-Peucker {ADMIN1_EPS} degrees (tighter on small areas), "
    "quantized to 0.01 degree. Holes are not subtracted."
)
COUNTY_SOURCE = (
    "US Census Bureau 2023 cartographic counties (cb_2023_us_county_20m), "
    "public domain, "
    f"Douglas-Peucker {COUNTY_EPS} degrees, quantized to 0.001 degree. "
    "United States only. Holes are not subtracted."
)


def unwrap_ring(ring: list[tuple[float, float]]) -> list[tuple[float, float]]:
    if not ring:
        return []
    out = [(float(ring[0][0]), float(ring[0][1]))]
    offset = 0.0
    prev = float(ring[0][0])
    for x, y in ring[1:]:
        x = float(x) + offset
        y = float(y)
        while x - prev > 180:
            x -= 360
            offset -= 360
        while prev - x > 180:
            x += 360
            offset += 360
        out.append((x, y))
        prev = x
    return out


def signed_area(ring: list[tuple[float, float]]) -> float:
    area = 0.0
    for i in range(len(ring) - 1):
        x1, y1 = ring[i]
        x2, y2 = ring[i + 1]
        area += x1 * y2 - x2 * y1
    return area / 2.0


def rdp(points: list[tuple[float, float]], epsilon: float) -> list[tuple[float, float]]:
    if len(points) < 3:
        return list(points)

    def distance(point, start, end) -> float:
        x, y = point
        x1, y1 = start
        x2, y2 = end
        dx, dy = x2 - x1, y2 - y1
        if dx == 0 and dy == 0:
            return math.hypot(x - x1, y - y1)
        t = ((x - x1) * dx + (y - y1) * dy) / (dx * dx + dy * dy)
        if t < 0:
            t = 0
        elif t > 1:
            t = 1
        return math.hypot(x - (x1 + t * dx), y - (y1 + t * dy))

    def simplify(pts: list[tuple[float, float]]) -> list[tuple[float, float]]:
        if len(pts) < 3:
            return pts
        start, end = pts[0], pts[-1]
        index = -1
        max_dist = -1.0
        for i in range(1, len(pts) - 1):
            dist = distance(pts[i], start, end)
            if dist > max_dist:
                max_dist = dist
                index = i
        if max_dist > epsilon and index > 0:
            left = simplify(pts[: index + 1])
            right = simplify(pts[index:])
            return left[:-1] + right
        return [start, end]

    open_pts = points[:-1] if points[0] == points[-1] and len(points) > 1 else list(points)
    if len(open_pts) < 3:
        return list(points)
    simplified = simplify(open_pts + [open_pts[0]])
    if simplified[0] != simplified[-1]:
        simplified.append(simplified[0])
    return simplified


def quantize_ring(
    ring: list[tuple[float, float]], scale: int
) -> list[tuple[int, int]] | None:
    quantized: list[tuple[int, int]] = []
    for x, y in ring:
        point = (int(round(x * scale)), int(round(y * scale)))
        if not quantized or quantized[-1] != point:
            quantized.append(point)
    if len(quantized) >= 2 and quantized[0] != quantized[-1]:
        quantized.append(quantized[0])
    if len(quantized) < 4:
        return None
    xs = [p[0] for p in quantized]
    ys = [p[1] for p in quantized]
    if max(xs) == min(xs) or max(ys) == min(ys):
        return None
    return quantized


def bbox_ring(
    ring: list[tuple[float, float]], scale: int
) -> list[tuple[int, int]] | None:
    xs = [p[0] for p in ring]
    ys = [p[1] for p in ring]
    min_x, max_x = min(xs), max(xs)
    min_y, max_y = min(ys), max(ys)
    if max_x - min_x > 300:
        return None
    return quantize_ring(
        [
            (min_x, min_y),
            (max_x, min_y),
            (max_x, max_y),
            (min_x, max_y),
            (min_x, min_y),
        ],
        scale,
    )


def encode_ring(points: list[tuple[int, int]]) -> str:
    parts = [f"{points[0][0]},{points[0][1]}"]
    prev_x, prev_y = points[0]
    for x, y in points[1:]:
        parts.append(f"{x - prev_x},{y - prev_y}")
        prev_x, prev_y = x, y
    return " ".join(parts)


def epsilon_for(ring: list[tuple[float, float]], base: float) -> float:
    """Keep small islands from losing their populated shorelines."""
    xs = [point[0] for point in ring]
    ys = [point[1] for point in ring]
    span = max(max(xs) - min(xs), max(ys) - min(ys))
    if span < 4:
        return min(base, max(span / 12.0, 0.02))
    return base


def simplify_outers(
    rings: list[list[tuple[float, float]]], epsilon: float, scale: int
) -> list[str]:
    encoded: list[str] = []
    for ring in rings:
        if len(ring) < 4:
            continue
        unwrapped = unwrap_ring(ring)
        if len(unwrapped) < 4:
            continue
        if signed_area(unwrapped) >= 0:
            continue
        simplified = rdp(unwrapped, epsilon_for(unwrapped, epsilon))
        quantized = quantize_ring(simplified, scale) or bbox_ring(unwrapped, scale)
        if quantized is None:
            continue
        encoded.append(encode_ring(quantized))
    return encoded


def shape_rings(shape) -> list[list[tuple[float, float]]]:
    points = shape.points
    parts = list(shape.parts) + [len(points)]
    rings = []
    for index in range(len(parts) - 1):
        ring = [(float(x), float(y)) for x, y in points[parts[index] : parts[index + 1]]]
        if len(ring) >= 4:
            rings.append(ring)
    return rings


def slug(value: str) -> str:
    text = re.sub(r"[^a-z0-9]+", "-", (value or "").lower()).strip("-")
    return text[:48] or "x"


def country_code(record: dict) -> str:
    iso = (record.get("iso_a2") or "").strip().upper()
    if len(iso) == 2 and iso.isalpha():
        return iso
    adm = (record.get("adm0_a3") or "").strip().upper()
    if re.fullmatch(r"[A-Z0-9]{2,3}", adm):
        return adm
    return "ZZ"


def write_json(path: Path, payload) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, separators=(",", ":"), ensure_ascii=False), encoding="utf-8")


def build_admin1(shp_path: Path, out_dir: Path) -> dict:
    import shapefile

    reader = shapefile.Reader(str(shp_path))
    rows = []
    iso_counts: dict[str, int] = defaultdict(int)
    for record in reader.records():
        data = record.as_dict()
        iso = (data.get("iso_3166_2") or "").strip()
        iso_counts[iso] += 1
        rows.append(data)

    seen_ids: set[str] = set()
    by_country: dict[str, dict] = {}
    countries: dict[str, str] = {}
    divisions = []

    reader = shapefile.Reader(str(shp_path))
    for shape_record in reader.iterShapeRecords():
        data = shape_record.record.as_dict()
        code = country_code(data)
        name = (data.get("name_en") or data.get("name") or "").strip() or "Unnamed"
        country_name = (data.get("admin") or code).strip() or code
        iso = (data.get("iso_3166_2") or "").strip() or data.get("adm1_code") or name
        if iso_counts[iso] == 1 and iso and not iso.startswith("-99"):
            key = iso
        else:
            key = f"{iso}~{slug(name)}"
            if not iso or iso.startswith("-99"):
                key = f"{data.get('adm1_code') or slug(name)}"
        full_id = f"{code}:{key}"
        if full_id in seen_ids:
            full_id = f"{code}:{key}~{slug(str(data.get('adm1_code') or ''))}"
            key = full_id.split(":", 1)[1]
        seen_ids.add(full_id)
        countries[code] = country_name
        encoded = simplify_outers(shape_rings(shape_record.shape), ADMIN1_EPS, ADMIN1_SCALE)
        if not encoded:
            continue
        bucket = by_country.setdefault(code, {})
        polys = bucket.setdefault(key, [])
        for ring in encoded:
            polys.append([ring])
        divisions.append({"i": full_id, "c": code, "n": name})

    country_rows = [{"c": code, "n": countries[code]} for code in countries]
    country_rows.sort(key=lambda row: (row["n"].lower(), row["c"]))
    order = {row["c"]: index for index, row in enumerate(country_rows)}
    divisions.sort(key=lambda row: (order.get(row["c"], 9999), row["n"].lower(), row["i"]))

    countries_dir = out_dir / "admin1" / "countries"
    if countries_dir.exists():
        for child in countries_dir.glob("*.json"):
            child.unlink()
    for code, divisions_geom in by_country.items():
        write_json(
            countries_dir / f"{code}.json",
            {"s": ADMIN1_SCALE, "d": divisions_geom},
        )
    write_json(
        out_dir / "admin1" / "index.json",
        {
            "v": 1,
            "source": ADMIN1_SOURCE,
            "countries": country_rows,
            "divisions": divisions,
        },
    )
    return {
        "countries": len(country_rows),
        "divisions": len(divisions),
        "files": len(by_country),
    }


def build_counties(shp_path: Path, out_dir: Path) -> dict:
    import shapefile

    by_state: dict[str, dict] = {}
    state_names: dict[str, str] = {}
    divisions = []
    reader = shapefile.Reader(str(shp_path))
    for shape_record in reader.iterShapeRecords():
        data = shape_record.record.as_dict()
        postal = (data.get("STUSPS") or "").strip().upper()
        geoid = str(data.get("GEOID") or "").strip().zfill(5)
        name = (data.get("NAMELSAD") or data.get("NAME") or geoid).strip()
        state_name = (data.get("STATE_NAME") or postal).strip()
        if not re.fullmatch(r"[A-Z]{2}", postal) or not re.fullmatch(r"\d{5}", geoid):
            continue
        encoded = simplify_outers(shape_rings(shape_record.shape), COUNTY_EPS, COUNTY_SCALE)
        if not encoded:
            continue
        state_names[postal] = state_name
        bucket = by_state.setdefault(postal, {})
        polys = bucket.setdefault(geoid, [])
        for ring in encoded:
            polys.append([ring])
        divisions.append({"i": f"{postal}:{geoid}", "c": postal, "n": name, "s": state_name})

    divisions.sort(key=lambda row: (row["s"].lower(), row["n"].lower(), row["i"]))
    states = [{"c": code, "n": state_names[code]} for code in state_names]
    states.sort(key=lambda row: row["n"].lower())
    states_dir = out_dir / "admin2" / "us" / "states"
    if states_dir.exists():
        for child in states_dir.glob("*.json"):
            child.unlink()
    for code, geom in by_state.items():
        write_json(states_dir / f"{code}.json", {"s": COUNTY_SCALE, "d": geom})
    write_json(
        out_dir / "admin2" / "us" / "index.json",
        {
            "v": 1,
            "source": COUNTY_SOURCE,
            "countries": [{"c": "US", "n": "United States"}],
            "states": states,
            "divisions": divisions,
        },
    )
    return {"states": len(states), "counties": len(divisions)}


def decode_ring(encoded: str, scale: int) -> list[tuple[float, float]]:
    points = []
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


def point_in_ring(lng: float, lat: float, ring: list[tuple[float, float]]) -> bool:
    inside = False
    j = len(ring) - 1
    for i in range(len(ring)):
        xi, yi = ring[i]
        xj, yj = ring[j]
        if (yi > lat) != (yj > lat):
            denom = yj - yi
            if denom != 0:
                x_cross = (xj - xi) * (lat - yi) / denom + xi
                if lng < x_cross:
                    inside = not inside
        j = i
    return inside


def load_geometries(path: Path) -> dict[str, list[list[tuple[float, float]]]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    scale = int(payload["s"])
    out = {}
    for key, polys in payload["d"].items():
        rings = []
        for poly in polys:
            if not poly:
                continue
            rings.append(decode_ring(poly[0], scale))
        out[key] = rings
    return out


def contains(geoms: dict, full_id: str, lng: float, lat: float, root: Path, kind: str) -> bool:
    prefix, key = full_id.split(":", 1)
    if kind == "admin1":
        path = root / "admin1" / "countries" / f"{prefix}.json"
    else:
        path = root / "admin2" / "us" / "states" / f"{prefix}.json"
    geoms_cache = geoms.setdefault(str(path), load_geometries(path))
    for ring in geoms_cache.get(key, []):
        if point_in_ring(lng, lat, ring):
            return True
    return False


def validate(out_dir: Path) -> None:
    geoms: dict = {}
    checks = [
        ("admin1", "US:US-CA", 34.05, -118.24, True, "Los Angeles in California"),
        ("admin1", "US:US-CA", 47.606, -122.332, False, "Seattle not in California"),
        ("admin1", "US:US-AK", 61.218, -149.900, True, "Anchorage in Alaska"),
        ("admin1", "US:US-AK", 47.606, -122.332, False, "Seattle not in Alaska"),
        ("admin1", "US:US-HI", 21.307, -157.858, True, "Honolulu in Hawaii"),
        ("admin1", "JP:JP-13", 35.6812, 139.7671, True, "Tokyo station in Tokyo"),
        ("admin1", "CA:CA-ON", 43.653, -79.383, True, "Toronto in Ontario"),
        ("admin1", "US:US-NV", 36.170, -115.140, True, "Las Vegas in Nevada"),
        ("admin2", "CA:06075", 37.7749, -122.4194, True, "San Francisco in SF county"),
        ("admin2", "CA:06037", 34.052, -118.244, True, "Los Angeles in LA county"),
        ("admin2", "CA:06075", 34.052, -118.244, False, "Los Angeles not in SF county"),
        ("admin1", "US:US-CA", 0.0, -160.0, False, "mid-Pacific not in California"),
    ]
    failed = False
    for kind, full_id, lat, lng, expected, label in checks:
        actual = contains(geoms, full_id, lng, lat, out_dir, kind)
        status = "ok" if actual == expected else "FAIL"
        if actual != expected:
            failed = True
        print(f"  {status}: {label}")
    if failed:
        raise SystemExit("boundary validation failed")


def directory_bytes(path: Path) -> int:
    return sum(file.stat().st_size for file in path.rglob("*") if file.is_file())


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--admin1-shp", required=True)
    parser.add_argument("--counties-shp", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    out_dir = Path(args.out)
    print("building admin-1")
    admin_stats = build_admin1(Path(args.admin1_shp), out_dir)
    print("building counties")
    county_stats = build_counties(Path(args.counties_shp), out_dir)
    print("validating")
    validate(out_dir)
    admin_bytes = directory_bytes(out_dir / "admin1")
    county_bytes = directory_bytes(out_dir / "admin2")
    print("admin1", admin_stats, "bytes", admin_bytes)
    print("counties", county_stats, "bytes", county_bytes)
    index_bytes = (out_dir / "admin1" / "index.json").stat().st_size
    county_index = (out_dir / "admin2" / "us" / "index.json").stat().st_size
    print("admin1_index_bytes", index_bytes)
    print("county_index_bytes", county_index)


if __name__ == "__main__":
    sys.exit(main())
