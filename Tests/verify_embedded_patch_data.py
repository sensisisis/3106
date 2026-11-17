#!/usr/bin/env python3
"""Verify that the embedded Swift payloads match the source patch packages."""
from __future__ import annotations

import base64
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "ThreeOneOSSix" / "BundledPatches"
SWIFT_PATH = ROOT / "ThreeOneOSSix" / "helpers" / "BundledPatchData.swift"
PROJECT_PATH = ROOT / "ThreeOneOSSix.xcodeproj" / "project.pbxproj"

assets = sorted(SOURCE_DIR.glob("*.3105"), key=lambda path: path.name)
swift = SWIFT_PATH.read_text(encoding="utf-8")
entries = re.findall(
    r'Entry\(label: "([^"]+)", chunks: \[(.*?)\]\),',
    swift,
    re.DOTALL,
)
if len(assets) != 4 or len(entries) != len(assets):
    raise SystemExit(
        f"FAIL: expected 4 source and embedded packages; got {len(assets)} and {len(entries)}"
    )

for source, (label, body) in zip(assets, entries, strict=True):
    chunks = re.findall(r'"([A-Za-z0-9+/=]+)"', body)
    try:
        embedded = base64.b64decode("".join(chunks), validate=True)
    except Exception as error:
        raise SystemExit(f"FAIL: invalid Base64 for {label}: {error}") from error
    if embedded != source.read_bytes():
        raise SystemExit(f"FAIL: embedded payload does not match {source.name}")

project = PROJECT_PATH.read_text(encoding="utf-8")
if "BundledPatches" in project:
    raise SystemExit("FAIL: Xcode project still references the visible BundledPatches folder")
if "BundledPatchData.swift in Sources" not in project:
    raise SystemExit("FAIL: BundledPatchData.swift is not compiled into the app")

print("PASS: all four patch payloads match and are compiled as Swift source, not bundle files.")
