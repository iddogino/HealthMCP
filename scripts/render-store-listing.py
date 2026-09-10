#!/usr/bin/env python3
"""Render App Store wrappers with pinned Koubou, one process per image.

Run with artifacts/appstore-shots-venv/bin/python scripts/render-store-listing.py.
The small batches bound Koubou's peak memory when rendering full-size frames.
"""
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import yaml


ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / ".asc/store-listing.yaml"
SOURCE = yaml.safe_load(CONFIG.read_text())
DEST = (CONFIG.parent / SOURCE["project"]["output_dir"]).resolve()
WORK = DEST.parents[1] / "render-work"


def render_preview(env):
    preview_source = ROOT / ".asc/store-preview.yaml"
    data = yaml.safe_load(preview_source.read_text())
    preview_out = WORK / "preview"
    data["project"]["output_dir"] = str(preview_out)
    for item in data["screenshots"]["preview"]["content"]:
        if item.get("asset"):
            item["asset"] = str((preview_source.parent / item["asset"]).resolve())
    config = WORK / "preview.yaml"
    config.write_text(yaml.safe_dump(data, sort_keys=False, allow_unicode=True))
    with (WORK / "preview.log").open("w") as log:
        subprocess.run(["kou", "generate", str(config), "--output", "json"], env=env, cwd=ROOT,
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    matches = list(preview_out.rglob("preview.png"))
    if len(matches) != 1:
        raise SystemExit("Expected exactly one contact sheet.")
    target = DEST.parents[1] / "preview.png"
    shutil.copyfile(matches[0], target)
    print(f"Saved {target.relative_to(ROOT)}", flush=True)


def main():
    DEST.mkdir(parents=True, exist_ok=True)
    WORK.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env["PATH"] = str(Path(sys.executable).parent) + os.pathsep + env["PATH"]
    version = subprocess.check_output(["kou", "--version"], env=env, text=True)
    if "v0.18.1" not in version:
        raise SystemExit("Install koubou==0.18.1 before rendering.")
    if sys.argv[1:] == ["--preview-only"]:
        render_preview(env)
        return
    if sys.argv[1:]:
        raise SystemExit("Usage: render-store-listing.py [--preview-only]")
    manifest = []
    for name, screenshot in SOURCE["screenshots"].items():
        data = copy.deepcopy(SOURCE)
        shot = copy.deepcopy(screenshot)
        assets = []
        for item in shot["content"]:
            if item.get("asset"):
                asset = (CONFIG.parent / item["asset"]).resolve()
                if not asset.is_file():
                    raise SystemExit(f"Missing capture: {asset}")
                item["asset"] = str(asset)
                assets.append({"path": str(asset.relative_to(ROOT)), "sha256": hashlib.sha256(asset.read_bytes()).hexdigest()})
        data["screenshots"] = {name: shot}
        output = WORK / name
        data["project"]["output_dir"] = str(output)
        config = WORK / f"{name}.yaml"
        config.write_text(yaml.safe_dump(data, sort_keys=False, allow_unicode=True))
        print(f"Rendering {name}…", flush=True)
        with (WORK / f"{name}.log").open("w") as log:
            subprocess.run(["asc", "screenshots", "frame", "--config", str(config), "--output-path", str(WORK / f"asc-{name}.png"), "--output", "json"],
                           env=env, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
        matches = list(output.rglob(f"{name}.png"))
        if len(matches) != 1:
            raise SystemExit(f"Expected one image for {name}, found {len(matches)}")
        target = DEST / f"{name}.png"
        shutil.copyfile(matches[0], target)
        subprocess.run(["sips", "--embedProfileIfNone", "/System/Library/ColorSync/Profiles/sRGB Profile.icc", str(target)],
                       stdout=subprocess.DEVNULL, check=True)
        review_raw = DEST.parents[1] / "review-raw" / "en-US" / f"{name}.png"
        review_raw.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / assets[0]["path"], review_raw)
        manifest.append({"file": target.name, "sha256": hashlib.sha256(target.read_bytes()).hexdigest(), "sources": assets})
        print(f"Saved {target.relative_to(ROOT)}", flush=True)
    (DEST.parents[1] / "manifest.json").write_text(json.dumps({"build": "1.0.0 (13)", "device": SOURCE["project"]["device"], "size": SOURCE["project"]["output_size"], "locale": "en-US", "data": "Fictional simulator fixtures; no personal health data or keys", "renderer": "Koubou 0.18.1 through asc screenshots frame", "images": manifest}, indent=2) + "\n")
    render_preview(env)


if __name__ == "__main__":
    main()
