#!/usr/bin/env python3
"""Preflight for ShittyFriends App Store signing, including the notification extension.

Codemagic's ios_signing downloads profiles; xcode-project use-profiles applies them.
This script inspects the ACTUAL installed profiles and optionally the Release
build settings for the generated Xcode project. No credentials are requested or
printed, and no profiles are modified.
"""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import plistlib
import subprocess
import sys

APP_ID = "com.sakara.shittyfriends"
EXTENSION_ID = APP_ID + ".NotificationService"
LIVE_ACTIVITY_ID = APP_ID + ".PoopingLiveActivity"
APP_GROUP = "group.com.sakara.shittyfriends"
# Sign in with Apple is requested by the app target (Firebase Auth); the provisioning profile must carry it.
APPLE_SIGN_IN_ENTITLEMENT = "com.apple.developer.applesignin"
TARGET_IDS = {"ShittyFriends": APP_ID, "NotificationService": EXTENSION_ID, "PoopingLiveActivity": LIVE_ACTIVITY_ID}
PROFILE_SUFFIXES = {".mobileprovision", ".provisionprofile"}


def profile_directories():
    home = Path.home()
    return [
        home / "Library/Developer/Xcode/UserData/Provisioning Profiles",
        home / "Library/MobileDevice/Provisioning Profiles",
    ]


def load_profiles(directories):
    profiles = []
    unreadable = 0
    seen = set()
    for directory in directories:
        if not directory.is_dir():
            continue
        for path in sorted(directory.iterdir()):
            if path.suffix not in PROFILE_SUFFIXES or path.resolve() in seen:
                continue
            seen.add(path.resolve())
            try:
                decoded = subprocess.run(
                    ["security", "cms", "-D", "-i", str(path)],
                    check=True, capture_output=True,
                )
                info = plistlib.loads(decoded.stdout)
                profiles.append(info)
            except (OSError, subprocess.CalledProcessError, ValueError, TypeError) as error:
                unreadable += 1
                print(f"WARN: Cannot read installed profile {path.name}: {type(error).__name__}", file=sys.stderr)
    return profiles, unreadable


def profile_bundle_id(profile):
    ent = profile.get("Entitlements", {})
    raw = ent.get("application-identifier") or ent.get("com.apple.application-identifier") or ""
    return raw.split(".", 1)[1] if "." in raw else ""


def profile_team(profile):
    team = profile.get("TeamIdentifier", [])
    return team[0] if isinstance(team, list) and team else (team if isinstance(team, str) else "")


def entitlement_values(value):
    """Normalize entitlement allowlists from provisioning profiles.

    Apple provisioning profiles may encode some entitlement allowlists as an
    array (for example ["Default"]) or as the wildcard string "*". The
    latter means the profile allows all values for that entitlement. Treating
    "*" as a literal array item caused the old preflight to reject valid
    App Store profiles.
    """
    if value is None:
        return []
    if isinstance(value, (list, tuple, set)):
        return [str(item) for item in value]
    return [str(value)]


def entitlement_allows(value, required):
    values = entitlement_values(value)
    return "*" in values or required in values


def profile_problems(profile, target_id, expected_team=None):
    ent = profile.get("Entitlements", {})
    problems = []
    if profile_bundle_id(profile) != target_id:
        problems.append("wrong bundle identifier")
    if expected_team and profile_team(profile) != expected_team:
        problems.append(f"wrong Apple team (expected {expected_team})")
    if profile.get("ExpirationDate") is not None:
        expiry = profile["ExpirationDate"]
        if expiry.tzinfo is None:
            expiry = expiry.replace(tzinfo=timezone.utc)
        if expiry <= datetime.now(timezone.utc):
            problems.append("profile expired")
    if ent.get("get-task-allow") is not False:
        problems.append("not a distribution/App Store profile (get-task-allow)")
    if "ProvisionedDevices" in profile or profile.get("ProvisionsAllDevices", False):
        problems.append("Ad Hoc/Enterprise profile; need App Store profile")
    if not entitlement_allows(ent.get("com.apple.security.application-groups"), APP_GROUP):
        problems.append(f"App Groups entitlement missing {APP_GROUP}")
    if target_id == APP_ID:
        if not entitlement_allows(ent.get(APPLE_SIGN_IN_ENTITLEMENT), "Default"):
            problems.append("Sign in with Apple capability not provisioned")
        if ent.get("aps-environment") != "production":
            problems.append("production Push Notifications capability not provisioned")
    return problems


def read_build_settings(project, scheme, json_file=None):
    """Read Release/device build settings for every signed target.

    `xcodebuild -scheme ... -showBuildSettings` is not guaranteed to emit build
    settings for embedded extension dependencies.  The previous preflight used
    the scheme form and therefore falsely reported that NotificationService had
    no Release settings even though its profile was installed.

    Query each target directly instead.  `-sdk iphoneos` is intentional: these
    are the device/App Store signing settings that `build-ipa` will use.  Keep
    `scheme` in the signature for CLI compatibility with older invocations.
    """
    if json_file:
        return json.loads(Path(json_file).read_text(encoding="utf-8"))

    rows = []
    for target in TARGET_IDS:
        command = [
            "xcodebuild", "-project", project, "-target", target,
            "-configuration", "Release", "-sdk", "iphoneos",
            "-showBuildSettings", "-json",
        ]
        try:
            result = subprocess.run(command, capture_output=True, text=True, check=True)
        except (OSError, subprocess.CalledProcessError) as error:
            stderr = getattr(error, "stderr", "") or ""
            detail = stderr.strip().splitlines()[-1] if stderr.strip() else str(error)
            raise ValueError(
                f"Cannot inspect Release signing assignment for target {target}: {detail}"
            ) from error
        try:
            target_rows = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise ValueError(
                f"xcodebuild returned invalid JSON build settings for target {target}"
            ) from error
        if not isinstance(target_rows, list) or not target_rows:
            raise ValueError(f"xcodebuild returned no Release build settings for target {target}")

        exact = [row for row in target_rows if row.get("target") == target]
        row = exact[0] if exact else target_rows[0]
        if "buildSettings" not in row:
            raise ValueError(f"xcodebuild omitted buildSettings for target {target}")
        # Normalize the target name so the assignment map cannot lose the
        # extension merely because xcodebuild omitted/changed the label.
        rows.append({"target": target, "buildSettings": row["buildSettings"]})
    return rows


def selected_profile(profiles, name_or_uuid):
    return [profile for profile in profiles
            if name_or_uuid in (str(profile.get("Name", "")), str(profile.get("UUID", "")))]


def inspect(profiles, assignments=None):
    errors = []
    for target, bundle in TARGET_IDS.items():
        candidates = [p for p in profiles if profile_bundle_id(p) == bundle]
        if not candidates:
            errors.append(f"{target}: No installed App Store provisioning profile for {bundle}.")
            continue
        valid = [p for p in candidates if not profile_problems(p, bundle)]
        if not valid:
            sample = candidates[0]
            detail = "; ".join(profile_problems(sample, bundle))
            errors.append(f"{target}: No valid provisioning profile for {bundle}. "
                          f"Example '{sample.get('Name','unnamed')}': {detail}.")
        else:
            print(f"OK: {target} has {len(valid)} matching App Store profile(s) with required entitlements.")

        if assignments is None:
            continue
        setting = assignments.get(target)
        if setting is None:
            errors.append(f"{target}: No Release build settings found after use-profiles.")
            continue
        actual_bundle = setting.get("PRODUCT_BUNDLE_IDENTIFIER")
        if actual_bundle != bundle:
            errors.append(f"{target}: Generated Xcode bundle ID is '{actual_bundle}', expected '{bundle}'.")
            continue
        if setting.get("CODE_SIGN_STYLE") != "Manual":
            errors.append(f"{target}: Release CODE_SIGN_STYLE is not Manual after use-profiles.")
        specifier = (setting.get("PROVISIONING_PROFILE_SPECIFIER") or
                     setting.get("PROVISIONING_PROFILE") or "").strip()
        if not specifier:
            errors.append(f"{target}: No profile assigned to the Release build. "
                          "Use separate App Store profiles for the app and extension.")
            continue
        matches = selected_profile(profiles, specifier)
        if not matches:
            errors.append(f"{target}: Assigned profile '{specifier}' not among installed profiles.")
            continue
        expected_team = setting.get("DEVELOPMENT_TEAM", "")
        if not any(not profile_problems(p, bundle, expected_team) for p in matches):
            details = "; ".join(profile_problems(matches[0], bundle, expected_team))
            errors.append(f"{target}: Assigned profile '{specifier}' is not valid: {details}.")
        else:
            print(f"OK: {target} Release signing selects '{specifier}' (App Groups verified).")
    return errors


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", default="ShittyFriends.xcodeproj")
    parser.add_argument("--scheme", default="ShittyFriends")
    parser.add_argument("--check-assignments", action="store_true")
    # Test/debug overrides; default locations are the same ones as Codemagic use-profiles.
    parser.add_argument("--profiles-dir", action="append", type=Path)
    parser.add_argument("--build-settings-json", help="Use captured xcodebuild JSON in tests")
    args = parser.parse_args(argv)

    print("Checking installed provisioning profiles for ALL THREE iOS targets (App Store distribution)...", flush=True)
    profiles, unreadable = load_profiles(args.profiles_dir or profile_directories())
    if unreadable:
        print(f"WARN: {unreadable} profiles could not be decoded.", file=sys.stderr)
    settings = None
    if args.check_assignments:
        try:
            raw_settings = read_build_settings(args.project, args.scheme, args.build_settings_json)
            settings = {row["target"]: row["buildSettings"] for row in raw_settings}
        except (ValueError, KeyError, TypeError, OSError) as error:
            print(f"ERROR: {error}", file=sys.stderr)
            return 2
    errors = inspect(profiles, settings)
    if errors:
        for error in errors:
            print("ERROR: " + error, file=sys.stderr)

        missing_extension = any(
            error.startswith(f"{target}: No installed App Store provisioning profile")
            for error in errors for target in ("NotificationService", "PoopingLiveActivity")
        )
        if missing_extension:
            print("FIX: Codemagic currently has no stored App Store profile for an extension.", file=sys.stderr)
            print("     A registered Bundle ID is NOT itself a provisioning profile.", file=sys.stderr)
            print("     In Codemagic > Code signing identities > iOS provisioning profiles,", file=sys.stderr)
            print("     Fetch profiles and add the App Store profile for:", file=sys.stderr)
            print("       com.sakara.shittyfriends.NotificationService", file=sys.stderr)
            print("       com.sakara.shittyfriends.PoopingLiveActivity", file=sys.stderr)
            print("     The existing ios_signing bundle rule will then fetch all app + extension profiles.", file=sys.stderr)

        capability_problem = any(
            phrase in error
            for error in errors
            for phrase in ("App Groups entitlement missing", "Sign in with Apple capability not provisioned",
                           "Push Notifications capability not provisioned")
        )
        if capability_problem:
            print("FIX: One of the installed profiles does not contain the entitlement requested by the target.", file=sys.stderr)
            print("     Check the specific error above, then regenerate/refetch only that profile if needed.", file=sys.stderr)
            print("     Do not remove App Group/Sign in with Apple entitlements merely to make signing pass.", file=sys.stderr)

        print("     See docs/APP_GROUPS_SIGNING_FIX.md for exact diagnostics.", file=sys.stderr)
        return 2
    print("PASS: All three targets have the required App Store signing profiles.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
