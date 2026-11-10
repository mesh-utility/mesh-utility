#!/usr/bin/env python3
"""Names-only restore planner. Does not print name text. No BEGIN/PRAGMA/TEMP."""
from __future__ import annotations

import json
import re
import sqlite3
import sys
from collections import Counter, defaultdict
from pathlib import Path

HEX_RE = re.compile(r"^[0-9A-Fa-f]+$")
NODE_PAIR = re.compile(r'"nodeId"\s*:\s*"([^"]+)"\s*,\s*"name"\s*:\s*"((?:\\.|[^"\\])*)"')
# also name-before-nodeId, uncommon
NAME_FIRST = re.compile(r'"name"\s*:\s*"((?:\\.|[^"\\])*)"\s*,\s*"nodeId"\s*:\s*"([^"]+)"')
HEX_NODE = re.compile(
    r'"(?:i|id|nodeId)"\s*:\s*"([^"]+)"[^}]{0,800}?"(?:n|name)"\s*:\s*"((?:\\.|[^"\\])*)"'
)
INSERT_SCAN = re.compile(r'INSERT INTO "?scans"?.*?VALUES\s*\(', re.I)


def compact_hex(value: str) -> str:
    return re.sub(r"[\s:\-_]", "", value).upper()


def is_placeholder(name: str, node_id: str = "") -> bool:
    trimmed = (name or "").strip()
    if not trimmed:
        return True
    lower = trimmed.lower()
    if lower == "unknown" or lower.startswith("unknown ("):
        return True
    compact = compact_hex(trimmed)
    if len(compact) < 8 or len(compact) > 64 or not HEX_RE.match(compact):
        return False
    # hex-only short/full id
    return True


def unescape_json_str(value: str) -> str:
    try:
        return json.loads(f'"{value}"')
    except Exception:
        return value.replace(r"\"", '"').replace(r"\\", "\\")


def add_name(catalog: dict[str, str], node_id: str, name: str) -> None:
    nid = (node_id or "").strip().upper()
    nm = unescape_json_str(name or "").strip()
    if not nid or is_placeholder(nm, nid):
        return
    if nid in catalog:
        return  # keep first real name
    catalog[nid] = nm
    if len(nid) >= 8:
        pref = nid[:8]
        if pref not in catalog:
            catalog[pref] = nm


def harvest_line(catalog: dict[str, str], line: str) -> int:
    added = 0
    before = len(catalog)
    for nid, name in NODE_PAIR.findall(line):
        add_name(catalog, nid, name)
    for name, nid in NAME_FIRST.findall(line):
        add_name(catalog, nid, name)
    if "nodes_json" in line or '"n":' in line:
        for nid, name in HEX_NODE.findall(line):
            add_name(catalog, nid, name)
    return len(catalog) - before


def harvest_file(path: Path, catalog: dict[str, str]) -> int:
    added = 0
    with path.open("r", errors="replace") as fh:
        for line in fh:
            if '"name"' not in line and '"n":' not in line:
                continue
            harvest_line(catalog, line)
    return len(catalog)


def parse_scan_insert(line: str):
    """Return (id, nodes_json) or None."""
    if "INSERT INTO" not in line or "scans" not in line.lower():
        return None
    # VALUES(id,'radioId',timestamp,lat,lng,alt,'[nodes]',committed,createdAt)
    m = re.search(r"VALUES\s*\(\s*(\d+)\s*,", line, re.I)
    if not m:
        return None
    scan_id = int(m.group(1))
    # nodes is the first JSON array in the line
    start = line.find("'[")
    if start < 0:
        start = line.find("\"[")
    if start < 0:
        return None
    quote = line[start]
    i = start + 1
    buf = []
    escape = False
    while i < len(line):
        ch = line[i]
        if escape:
            buf.append(ch)
            escape = False
        elif ch == "\\":
            buf.append(ch)
            escape = True
        elif ch == quote:
            break
        else:
            buf.append(ch)
        i += 1
    raw = "".join(buf)
    # SQL escaped quotes: ''
    if quote == "'":
        raw = raw.replace("''", "'")
    try:
        nodes = json.loads(raw)
    except Exception:
        return None
    if not isinstance(nodes, list):
        return None
    return scan_id, nodes


def fill_nodes(nodes: list, catalog: dict[str, str]) -> tuple[list, int, set[str]]:
    changed = 0
    ids = set()
    out = []
    for node in nodes:
        if not isinstance(node, dict):
            out.append(node)
            continue
        nid = str(node.get("nodeId") or node.get("i") or node.get("id") or "").strip()
        if not nid:
            out.append(node)
            continue
        current = str(node.get("name") or node.get("n") or "").strip()
        if not is_placeholder(current, nid):
            out.append(node)
            continue
        key = nid.upper()
        pref = key[:8] if len(key) >= 8 else key
        real = catalog.get(key) or catalog.get(pref)
        if not real:
            out.append(node)
            continue
        new_node = dict(node)
        new_node["name"] = real
        out.append(new_node)
        changed += 1
        ids.add(key)
    return out, changed, ids


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "plan"
    out_dir = Path("/workspace/mesh-utility/logs/names-repair-sql")
    out_dir.mkdir(parents=True, exist_ok=True)
    catalog_path = out_dir / "catalog-ids.json"  # ids only + counts, no names
    catalog_full = out_dir / "catalog-private.json"  # has names, do not print
    plan_path = out_dir / "plan-summary.json"
    updates_dir = out_dir / "batches"
    updates_dir.mkdir(exist_ok=True)

    source_backups = [
        Path("/workspace/mesh-utility/backups/mesh-utility-db-pre-hexgrid-names-20261110-002129.sql"),
        Path("/workspace/mesh-utility/backups/mesh-utility-db-pre-0006-hex-detail-20261109-233011.sql"),
        Path("/workspace/mesh-utility/backups/mesh-utility-db-pre-hex-detail-20261109-223352.sql"),
        Path("/workspace/mesh-utility/backups/mesh-utility-db-pre-alpha25-20261109-175342.sql"),
        Path("/workspace/mesh-utility/backups/mesh-utility-db-pre-unique-scan-index-20261110-044203.sql"),
    ]
    live_backup = Path("/workspace/mesh-utility/backups/mesh-utility-db-pre-names-repair-20261110-120346.sql")

    catalog: dict[str, str] = {}
    source_stats = []
    for path in source_backups:
        if not path.exists():
            source_stats.append({"path": path.name, "missing": True})
            continue
        before = len(catalog)
        harvest_file(path, catalog)
        source_stats.append({"path": path.name, "catalog_size_after": len(catalog), "added": len(catalog) - before})
        print(f"harvest {path.name}: catalog={len(catalog)} added={len(catalog)-before}", flush=True)

    # Only keep entries that look like node ids (hex)
    id_keys = [k for k in catalog if HEX_RE.match(k)]
    print(f"catalog real names={len(catalog)} hex_ids={len(id_keys)}", flush=True)
    catalog_path.write_text(json.dumps({"ids": sorted(id_keys), "count": len(id_keys)}, indent=2))
    catalog_full.write_text(json.dumps(catalog))

    if cmd == "catalog":
        json.dump({"sources": source_stats, "count": len(catalog)}, sys.stdout)
        return

    updates = []
    rows_touched = 0
    ids_restored: Counter = Counter()
    max_id = 0
    scan_rows = 0
    with live_backup.open("r", errors="replace") as fh:
        for line in fh:
            parsed = parse_scan_insert(line)
            if not parsed:
                continue
            scan_id, nodes = parsed
            scan_rows += 1
            if scan_id > max_id:
                max_id = scan_id
            new_nodes, changed, ids = fill_nodes(nodes, catalog)
            if not changed:
                continue
            rows_touched += 1
            for i in ids:
                ids_restored[i] += 1
            payload = json.dumps(new_nodes, separators=(",", ":"))
            updates.append((scan_id, payload))

    summary = {
        "live_backup": live_backup.name,
        "scan_rows_seen": scan_rows,
        "max_id": max_id,
        "rows_to_update": rows_touched,
        "distinct_ids": len(ids_restored),
        "id_row_counts": dict(ids_restored),
        "sources": source_stats,
        "catalog_names": len(catalog),
    }
    plan_path.write_text(json.dumps(summary, indent=2))
    print(
        f"plan rows={rows_touched} distinct_ids={len(ids_restored)} scan_rows={scan_rows} max_id={max_id}",
        flush=True,
    )

    # Write SQL batches of 80 updates (no BEGIN/PRAGMA/TEMP)
    batch_size = 80
    batch_files = []
    for i in range(0, len(updates), batch_size):
        chunk = updates[i : i + batch_size]
        fp = updates_dir / f"update-{i//batch_size:04d}.sql"
        with fp.open("w") as out:
            for scan_id, payload in chunk:
                out.write(f"UPDATE scans SET nodes = {sql_literal(payload)} WHERE id = {scan_id};\n")
        batch_files.append(str(fp))
    (out_dir / "batch-files.json").write_text(json.dumps(batch_files, indent=2))
    print(f"wrote {len(batch_files)} sql batch files", flush=True)


if __name__ == "__main__":
    main()
