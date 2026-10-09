> **2026-10-09:** the app no longer uses iCloud/CloudKit. The app target's entitlements are App Groups, Push Notifications and **Sign in with Apple** (`com.apple.developer.applesignin`); `scripts/verify_signing_profiles.py` checks those. Where this document says CloudKit, read Sign in with Apple.

# App Groups provisioning failure (NotificationService) — 2026-10-07

## Reported error

Xcode 26.6 failed during `ios-testflight` archive:

```
"NotificationService" requires a provisioning profile with the App Groups feature.
```

This is **not a missing Swift capability or CloudKit management token**. Both app
and notification extension already specify **the same** App Group entitlement in
the source project:

- App: `com.sakara.shittyfriends`
- Extension: `com.sakara.shittyfriends.NotificationService`
- Shared App Group: `group.com.sakara.shittyfriends`

The specific reason is external to the archive: the extension's *selected*
provisioning profile either doesn't have this App Group, is an older profile
created before the App ID capability was updated, or is the wrong profile.
The project ZIP cannot alter App IDs or profiles held in your Apple Developer account.

## What to do in Apple's portal (required once)

1. Sign in to **Apple Developer → Certificates, Identifiers & Profiles → Identifiers**.
2. Under **App Groups**, ensure `group.com.sakara.shittyfriends` exists. Create it if absent.
3. Under **App IDs**, open **`com.sakara.shittyfriends`**. Enable **App Groups**, configure it
   to use **`group.com.sakara.shittyfriends`**, and save. Keep **iCloud/CloudKit**
   with `iCloud.com.sakara.shittyfriends` plus **Push Notifications** enabled.
4. Under **App IDs**, open **`com.sakara.shittyfriends.NotificationService`**. If it
   doesn't exist, register an *explicit* App ID for the extension. Enable
   **App Groups** and assign the **same** `group.com.sakara.shittyfriends`.
   The extension does not need its own CloudKit capability for current source code.
5. Under **Profiles**, create or regenerate **two distinct iOS App Store distribution**
   profiles: one for the main bundle ID and one for the extension. Use the same
   Apple Distribution signing certificate/team for both. Profiles minted *before*
   App Group was enabled won't gain the entitlement automatically.
6. In **Codemagic → Team settings → Code signing identities → iOS provisioning profiles**,
   upload/fetch **both newly generated profiles**. Retire stale profiles or replace
   them in Codemagic to prevent Xcode from choosing the wrong one. Ensure a matching
   Apple Distribution certificate is also in Code signing identities.
7. Push this ZIP's updated `codemagic.yaml` plus `scripts/verify_signing_profiles.py`.
   Run **`ios-testflight`**, not the unrelated `cloudkit-schema` workflow.

## What changed in the project

- Keep App Group entitlements intact for app and extension; do **not** remove them
  to silence signing errors, because that breaks encrypted notification lookups.
- Run `verify_signing_profiles.py` **before** applying profiles. It decodes the
  installed profiles via macOS `security cms` and checks bundle IDs, App Groups,
  App Store distribution type, and the main app's CloudKit/Push entitlement.
- Invoke `xcode-project use-profiles --project "$XCODE_PROJECT" --archive-method app-store`
  so Codemagic doesn't select an ad hoc/development signing profile by accident.
- Run `verify_signing_profiles.py --check-assignments` **after** applying them. It
  queries each target's Release/iphoneos signing settings and ensures **both targets** are assigned
  valid App Store profiles that include the shared App Group.
- Neither signing secrets nor provisioning profiles are included in the ZIP.


## 2026-10-07 follow-up: CloudKit false positive fixed

The first version of the preflight assumed `com.apple.developer.icloud-services`
would always be an array containing the literal value `CloudKit`. Apple can also
encode a provisioning profile's entitlement allowlist as the wildcard `*`. In
that case the profile *does* allow CloudKit, but the old script reported:

```
CloudKit capability not provisioned
```

The preflight now accepts both the explicit `CloudKit` value and Apple's `*`
allowlist form. It still requires the configured iCloud container, production
push entitlement, App Group, App Store distribution type, correct bundle ID,
and correct team.

The separate `NotificationService: No installed App Store provisioning profile`
message is **not** a false positive. A registered extension Bundle ID is not a
provisioning profile. Codemagic must have a distinct App Store profile stored for
`com.sakara.shittyfriends.NotificationService`; once it is present, the existing
`ios_signing.bundle_identifier: com.sakara.shittyfriends` rule will also fetch
matching `com.sakara.shittyfriends.*` extension profiles.

## Interpreting the new build results

`ERROR: NotificationService: No valid provisioning profile ... App Groups entitlement missing`
→ Update extension App ID capability in Apple Portal, regenerate **extension**
App Store profile, then refetch it in Codemagic.

`ERROR: NotificationService: No installed App Store provisioning profile`
→ Codemagic is not supplying an extension profile; fetch or upload it under
Code signing identities. The `ios_signing.bundle_identifier` setting already
covers profiles for embedded extensions **if the matching profiles are stored**.

`ERROR: NotificationService: Assigned profile ... is not valid`
→ An old/wrong profile is actually selected in the generated Release project.
Replace stale profiles in Codemagic; inspect which name was selected.

`PASS: Both targets have the required App Store signing profiles.`
→ Profile/entitlement mismatch has been ruled out locally, but the archive
must still be run on Codemagic/Xcode to confirm end-to-end signing.

## References

- Apple: https://developer.apple.com/help/account/identifiers/enable-app-capabilities/
- Codemagic: https://docs.codemagic.io/yaml-code-signing/signing-ios/

## 2026-10-07 follow-up: false `No Release build settings` fixed

After the extension App Store profile was added, the preflight reported both
profiles as valid but then failed with:

```
ERROR: NotificationService: No Release build settings found after use-profiles.
```

That message was a verifier bug, not evidence that the extension profile had
vanished. The verifier asked Xcode for `-scheme ShittyFriends -showBuildSettings`.
An embedded app-extension dependency can be built for archive without appearing
as a separate row in that scheme-level build-settings JSON.

The assignment check now queries the **ShittyFriends** and **NotificationService**
targets individually with `-configuration Release -sdk iphoneos`. This inspects
the actual device/App Store signing settings after `xcode-project use-profiles`.
If the extension really has no assigned profile, the verifier will now report
`No profile assigned to the Release build` instead of falsely claiming that the
target has no Release settings.
