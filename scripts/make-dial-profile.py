#!/usr/bin/env python3
"""Create an original, separate Elgato profile; never access installed profiles.

Import the resulting archive through Elgato. It contains only our menu action,
no device identity, external actions, grants, saved workflow or user data.
"""
import argparse
import json
from pathlib import Path
import uuid
import zipfile


def make_profile(destination: Path) -> None:
    profile_id, page_id, action_id = [str(uuid.uuid4()).upper() for _ in range(3)]
    root = f"{profile_id}.sdProfile"
    profile = {
        "Device": {"Model": "20GBD9901", "UUID": ""},
        "Name": "NeroNook Dials",
        "Pages": {"Current": page_id, "Default": page_id, "Pages": [page_id]},
        "Version": "3.0",
    }
    manifest = json.loads((Path(__file__).resolve().parents[1] /
                           "StreamDeck/cafe.nero.neronook.sdPlugin/manifest.json").read_text())
    menu = next(a for a in manifest["Actions"] if a["UUID"] == "cafe.nero.neronook.menu")
    assert "Encoder" in menu["Controllers"]
    action = {
        "ActionID": action_id,
        "LinkedTitle": True,
        "Name": menu["Name"],
        "Plugin": {k: manifest[k] for k in ("Name", "UUID", "Version")},
        "Resources": None,
        "Settings": {},
        "State": 0,
        "States": [{"FontFamily": "", "FontSize": 12, "FontStyle": "",
                    "FontUnderline": False, "OutlineThickness": 2,
                    "ShowTitle": True, "TitleAlignment": "middle",
                    "TitleColor": "#ffffff"}],
        "UUID": menu["UUID"],
    }
    page = {"Controllers": [
        {"Actions": {}, "Type": "Keypad"},
        {"Actions": {"0,0": action}, "Background": "", "Type": "Encoder"},
    ]}
    destination.parent.mkdir(parents=True, exist_ok=True)
    # A second run must not silently overwrite a previous reviewable artifact.
    with zipfile.ZipFile(destination, "x", compression=zipfile.ZIP_DEFLATED) as archive:
        for path, data in [(f"{root}/manifest.json", profile),
                           (f"{root}/Profiles/{page_id}/manifest.json", page)]:
            archive.writestr(path, json.dumps(data, indent=2) + "\n")
    print(f"Created {destination}: one Nero menu dial, no keys or external actions")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    make_profile(parser.parse_args().destination)
