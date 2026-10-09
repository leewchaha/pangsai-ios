# CloudKit sharing production bootstrap

## Symptom

A TestFlight / App Store build can show an internal CloudKit error containing:

`Cannot create new type cloudkit.share in production schema`

The app must never surface that raw server text to end users. The UI now maps CloudKit failures to a short user-facing message and keeps detailed diagnostics in logs.

## Why this happens

`cloudkit.share` is an Apple-managed system record type used by `CKShare`. Unlike the custom ShittyFriends record types in `CloudKit/schema.ckdb`, it is created only after a real share is successfully saved while the container is using the **Development** CloudKit environment. Production does not auto-create record types.

Importing `CloudKit/schema.ckdb` alone therefore does not guarantee that `cloudkit.share` exists.

## One-time fix before friend history / group sharing can work in TestFlight

1. Install/run a **development-signed Debug build** that points at the Development CloudKit environment on an iCloud-signed-in device.
2. Launch ShittyFriends. Debug builds now automatically originate the private history share once after CloudKit starts (`bootstrapDevelopmentSharingSchema()`), which creates the Apple `cloudkit.share` system type in Development. It is harmless if the share already exists.
3. In CloudKit Console, open `iCloud.com.sakara.shittyfriends` and verify that sharing schema changes exist in **Development**.
4. Use **Deploy Schema Changes to Production**.
5. Re-test friend acceptance/history sharing from TestFlight on two iCloud accounts.

The normal Add Friends QR no longer needs a `CKShare` merely to display/share an invitation. It uses the app's existing signed invite payload/deep-link flow. A `CKShare` is still required when both people accept and history access is actually granted, so the Production sharing bootstrap above remains required.

## Regression checks

- Opening Add Friends in TestFlight must not try to create an invite-card `CKShare`.
- Raw `CKRecordID`, zone IDs, server schema text, and `cloudkit.share` errors must never render in app UI.
- Existing/old iCloud invite-card URLs remain readable for compatibility.
- Friend history shares remain private and participant-specific.

## Without a Mac (Codemagic `ios-dev-bootstrap`)

1. Developer portal → Devices: register the iPhone (UDID).
2. Codemagic → Team settings → Code signing identities: generate/upload an **Apple Development**
   certificate, then fetch/upload **iOS App Development** profiles for `com.sakara.shittyfriends`,
   `com.sakara.shittyfriends.NotificationService` and `com.sakara.shittyfriends.PoopingLiveActivity`
   (each must include that iPhone).
3. Run **ios-dev-bootstrap**, install the `.ipa` on that iPhone, turn on Developer Mode when iOS asks,
   open the app once while signed in to iCloud and wait ~30 s.
4. CloudKit Console → Development → Record Types should now list `cloudkit.share`.
   Then Deploy Schema Changes to Production.
