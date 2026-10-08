import plistlib
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "verify_appstore_metadata.py"
PLIST = ROOT / "ShittyFriends" / "Info.plist"


def test_orientation_metadata_matches_app_store_requirements():
    with PLIST.open("rb") as fh:
        info = plistlib.load(fh)
    assert "UISupportedInterfaceOrientations" not in info
    assert info["UISupportedInterfaceOrientations~iphone"] == ["UIInterfaceOrientationPortrait"]
    assert set(info["UISupportedInterfaceOrientations~ipad"]) == {
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationPortraitUpsideDown",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    }


def test_preflight_script_passes_current_plist():
    result = subprocess.run(
        [sys.executable, str(SCRIPT)], cwd=ROOT, capture_output=True, text=True
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "OK:" in result.stdout
