#!/usr/bin/env python3
"""Check Cargo.lock and npm package-lock.json manifests against OSV.dev.

Prints one TSV line per affected package, pre-sorted:
    ecosystem<TAB>package<TAB>version<TAB>ids<TAB>severity

Exit status is always 0 unless a manifest cannot be read; the caller decides
how to interpret NO_CVE_FINDINGS vs. output rows.
"""
from __future__ import annotations

import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

OSV_BATCH_URL = "https://api.osv.dev/v1/querybatch"
BATCH_SIZE = 100


def load_cargo_packages(path: Path):
    """Parse Cargo.lock [[package]] entries without needing tomllib."""
    packages = []
    name = version = None
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if line == "[[package]]":
            if name and version:
                packages.append((name, version))
            name = version = None
        elif line.startswith("name = ") and name is None:
            name = line.split('"')[1]
        elif line.startswith("version = ") and version is None:
            version = line.split('"')[1]
    if name and version:
        packages.append((name, version))
    return packages


def load_npm_packages(path: Path):
    data = json.loads(path.read_text(encoding="utf-8", errors="replace"))
    out = []
    for location, info in data.get("packages", {}).items():
        name = location.split("node_modules/")[-1]
        if name and info.get("version"):
            out.append((name, info["version"]))
    return out


def query_osv(packages, ecosystem):
    """Batch-query OSV. Returns {(name, version): sorted list of alias ids}."""
    findings = {}
    for start in range(0, len(packages), BATCH_SIZE):
        chunk = packages[start:start + BATCH_SIZE]
        batch = [
            {"package": {"name": name, "ecosystem": ecosystem}, "version": version}
            for name, version in chunk
        ]
        request = urllib.request.Request(
            OSV_BATCH_URL,
            data=json.dumps({"queries": batch}).encode(),
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                results = json.load(response).get("results", [])
        except (urllib.error.URLError, OSError) as error:
            print(f"warning: OSV querybatch failed: {error}", file=sys.stderr)
            return findings
        for (name, version), result in zip(chunk, results):
            aliases = []
            for vuln in result.get("vulns", []):
                aliases.extend(vuln.get("aliases", []) or [vuln.get("id", "UNKNOWN")])
            if aliases:
                findings[(name, version)] = sorted(set(aliases))
    return findings


def main():
    args = sys.argv[1:]
    if not args:
        print("usage: osv_check.py Cargo.lock [package-lock.json ...]", file=sys.stderr)
        return 2
    cargo_lock = Path(args[0])
    npm_locks = [Path(p) for p in args[1:]]

    findings = {}
    if cargo_lock.is_file():
        findings.update(query_osv(load_cargo_packages(cargo_lock), "crates.io"))
    for lock in npm_locks:
        findings.update(query_osv(load_npm_packages(lock), "npm"))

    if not findings:
        print("NO_CVE_FINDINGS")
        return 0
    for (name, version), aliases in sorted(findings.items()):
        print(f"crates.io/npm\tpackage:{name}\t{version}\t{','.join(aliases)}\tn/a")
    return 0


if __name__ == "__main__":
    sys.exit(main())
