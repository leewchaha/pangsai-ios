# ShittyFriends — Setup (Apple Developer, CloudKit, Codemagic)

Do these once, in order. Nothing here involves a server you run: all user data lives on-device and in
each user's own iCloud. The only developer-side pieces are the iCloud container's **schema** and the
**public-database "Ping" channel** (anonymous, sealed, self-expiring notification records).

Identifiers used everywhere (must match exactly):

| What | Value |
|---|---|
| App bundle ID | `com.sakara.shittyfriends` |
| Notification extension bundle ID | `com.sakara.shittyfriends.NotificationService` |
| iCloud container | `iCloud.com.sakara.shittyfriends` |
| App Group | `group.com.sakara.shittyfriends` |
| App Store Connect Apple ID | `6819505355` |

An **individual** Apple Developer account supports everything here (iCloud/CloudKit, Push, App Groups,
TestFlight).

---

## 1. Apple Developer portal (developer.apple.com → Certificates, Identifiers & Profiles)

> ⚠️ Do steps 1.1–1.4 **before** the first signed Codemagic build. The `ios-testflight`
> workflow **uses existing signing identities in Codemagic**; it does not automatically
> register App IDs, enable capabilities, or regenerate out-of-date profiles.

1. **Identifiers → `+` → iCloud Containers**: create `iCloud.com.sakara.shittyfriends`.
2. **Identifiers → `+` → App Groups**: create `group.com.sakara.shittyfriends`.
3. **Identifiers → App IDs → `com.sakara.shittyfriends`** (it already exists from App Store Connect).
   Enable and configure:
   - **iCloud** → check *CloudKit* → *Configure* → select `iCloud.com.sakara.shittyfriends`.
   - **Push Notifications** (no certificate needed; CloudKit uses token auth).
   - **App Groups** → *Configure* → select `group.com.sakara.shittyfriends`.
   - Save.
4. **Identifiers → `+` → App IDs → App** with bundle ID `com.sakara.shittyfriends.NotificationService`
   (description e.g. "ShittyFriends Notifications"). Enable **App Groups** → select the same group. Save.
5. **Profiles**: after the capabilities are enabled, **create/regenerate two separate App Store
   distribution provisioning profiles**, one for each bundle ID. Earlier profiles do not
   gain newly enabled App Groups/CloudKit/Push entitlements. Fetch/upload the new profiles
   into Codemagic's **Code signing identities**, and retire stale ones there to avoid
   accidentally selecting them. Codemagic's current YAML workflow does **not** generate
   these missing profiles. See `docs/APP_GROUPS_SIGNING_FIX.md`.

⚠️ Safety: never commit the `.p8` API key, certificates or profiles. `.gitignore` already blocks them.

---

## 2. App Store Connect API key (for Codemagic)

Users and Access → **Integrations** → App Store Connect API → *Team Keys* → `+`
(role **App Manager** is enough). Download the `.p8` **once** (Apple won't show it again) and note:

- **Issuer ID** (top of the page)
- **Key ID** (in the key's row). The handoff lists `HLBSVSN338` as the API identifier; if that is the
  Key ID shown next to your key, use it.

---

## 3. Codemagic

### 3.1 Repository
Codemagic builds from a Git repository. This package **includes its `.git` history**, so:

```bash
cd ShittyFriends
git remote add origin git@github.com:<you>/shittyfriends-ios.git   # create a PRIVATE repo first
git push -u origin main
```

Then in Codemagic: **Add application → connect the repo → "codemagic.yaml" workflow**.

### 3.2 App Store Connect integration and code signing identities

The **v0.1.2 Launch Fix** already uses Codemagic's built-in Apple Developer Portal
integration named `shittyfriends`. This v1.0.0 workflow now uses the **same integration
method**, instead of manually invoking `app-store-connect fetch-signing-files` with
four environment variables. The latter caused the reported error:
`argument --issuer-id: Missing value ISSUER_ID`.

In **Codemagic → Team settings → Integrations → Developer Portal**, configure the
App Store Connect API key and name it **`shittyfriends`**, exactly matching:

```yaml
integrations:
  app_store_connect: shittyfriends
```

Supply the Apple **Issuer ID**, **Key ID**, and the `.p8` private key securely in
Codemagic. The key needs adequate permissions (App Manager is recommended for
TestFlight publishing). The integration name is **not** the Key ID.

In **Codemagic → Team settings → Code signing identities**, add/fetch:

1. One valid **Apple Distribution** certificate (including its private key).
2. An **App Store** provisioning profile for `com.sakara.shittyfriends` with
   iCloud/CloudKit, Push Notifications and App Groups enabled.
3. A separate **App Store** provisioning profile for
   `com.sakara.shittyfriends.NotificationService` with App Groups enabled.

Both profiles must be on the same Apple Developer team as the certificate.
The `ios_signing` configuration loads profiles matching the app bundle identifier
**and embedded extensions**, provided they were already uploaded/fetched into
Codemagic; `xcode-project use-profiles --archive-method app-store` applies them.
The TestFlight workflow now checks both targets' installed profiles and Release
signing assignments and stops early with actionable instructions if the
App Groups entitlement is missing. See `docs/APP_GROUPS_SIGNING_FIX.md`.
**This approach selects existing Codemagic signing identities; it does not create
missing portal identifiers, capabilities, certificates, or profiles.**

You **do not** need an `appstore_credentials` environment variable group for this
workflow. Do not add Apple API secrets to the repository.

#### Optional CloudKit import workflow

The standalone `cloudkit-schema` workflow still uses the `cloudkit` environment
group, separate from TestFlight:

| Variable | Value |
|---|---|
| `CLOUDKIT_MANAGEMENT_TOKEN` | **CloudKit Console → account Settings → generate a management token** (copy it when created) |
| `TEAM_ID` | Your 10-character Apple Developer Team ID (not the App Store Connect Issuer ID or API Key ID) |

To make the `cloudkit-schema` workflow work in Codemagic:

1. Open **CloudKit Console** (`icloud.developer.apple.com`), sign in with the Apple Developer account that owns `iCloud.com.sakara.shittyfriends`, and open your **account Settings**. Generate a **Management Token** and copy it immediately; it is not shown again.
2. Open **Codemagic → ShittyFriends application → Environment variables** (or team-level Global variables and secrets if you deliberately want to reuse it). Create/use the variable group named exactly **`cloudkit`**.
3. Add variable **`CLOUDKIT_MANAGEMENT_TOKEN`**, paste the token, and mark it **Secret**. Add **`TEAM_ID`** in the **same** `cloudkit` group using your Apple Developer Team ID.
4. Commit/push `codemagic.yaml` to the branch being built; run **`cloudkit-schema`** separately. It checks credentials before contacting Apple, validates the schema, and only then imports into **Development**.
5. If this is your first CloudKit deployment, use CloudKit Console to **review and deploy changes to Production** after a successful import. The workflow deliberately does not deploy to Production.

The **CloudKit Management Token is not** the App Store Connect API `.p8` key, Issuer ID, API Key ID, or the `shittyfriends` Codemagic Developer Portal integration. CloudKit management tokens generally expire (Apple documents a default one-year lifetime); replace the Secret if it expires. Never paste the token in logs, project files, screenshots, or chat.

`ios-testflight` and `ios-check` do **not** call `cktool`. If you only want to compile/upload a build, select **`ios-testflight`**; it will not perform the schema import. However, CloudKit functionality in TestFlight still requires the schema to be present in **Production**.

### 3.3 Workflows (in `codemagic.yaml`)

| Workflow | What it does | Needs |
|---|---|---|
| `ios-check` | Generates XcodeGen project and runs unsigned simulator tests | No Apple credentials |
| `ios-testflight` | Uses stored signing identities, applies profiles for app and extension, builds IPA, uploads to TestFlight | Codemagic Developer Portal integration `shittyfriends`; App Store profiles for both bundle IDs; distribution certificate |
| `cloudkit-schema` | Imports the CloudKit schema into the Development environment | Optional `cloudkit` group |

**Run `ios-check` first.** If it fails, the log ends with a block titled
`ERRORS (paste these to Claude)`; examine the attached log.

If `ios-testflight` fails, distinguish the causes:

- **Integration not found / cannot authenticate**: connect the Developer Portal integration
  named `shittyfriends` and verify the Apple API credentials. The missing issuer-ID
  message should not occur on the old `fetch-signing-files` step because that step is removed.
- **No matching signing files / App Groups mismatch**: enable the SAME App Group
  on the parent and extension App IDs in Apple's portal; regenerate **both**
  App Store profiles after updating capabilities, then fetch/upload them into Codemagic.
  The new `Preflight App Store provisioning profiles` step diagnoses missing and stale profiles,
  and `Verify Release signing assignments` catches an old profile selected for the extension.
  See `docs/APP_GROUPS_SIGNING_FIX.md`.
- **CLI build-number lookup fails**: this workflow now fails explicitly; it no longer
  silently substitutes build number 1 on an authentication or network error.

---

## 4. CloudKit schema (must be in **Production** before TestFlight works)

TestFlight and App Store builds talk to the **Production** CloudKit environment, which can't
auto-create record types. The schema has to be imported into Development, then deployed.

### 4.1 Import into Development (pick one)
- **Codemagic:** run the `cloudkit-schema` workflow (requires `CLOUDKIT_MANAGEMENT_TOKEN` and `TEAM_ID` in the `cloudkit` group; setup in §3.2).
- **Any Mac:** `xcrun cktool import-schema --team-id <TEAM_ID> --container-id iCloud.com.sakara.shittyfriends --environment development --file CloudKit/schema.ckdb`
  (after `xcrun cktool save-token --type management`).
- **By hand:** CloudKit Console → container → Schema → create the record types/fields/indexes exactly as
  in `CloudKit/schema.ckdb`.

### 4.2 Deploy to Production
CloudKit Console (icloud.developer.apple.com) → `iCloud.com.sakara.shittyfriends` →
**Deploy Schema Changes…** → confirm. Re-deploy whenever `schema.ckdb` changes.

Check after deploying, in Production → Schema → Indexes, that **Ping** has `to` and `kind` **QUERYABLE**
and `exp` **QUERYABLE + SORTABLE**. Without them, friend/group notifications silently don't arrive.

---

## 5. App Store Connect app record

- Name: **ShittyFriends** (keep a different fallback name ready in case review rejects it, per handoff §40).
- Age rating: answer the questionnaire honestly. Mild crude humor, no user-generated photos, no public
  chat. The app itself blocks under-13 sign-up with a neutral date-of-birth check that isn't stored.
- **Export compliance**: `ITSAppUsesNonExemptEncryption = NO` is set in Info.plist. The only encryption
  is Apple's own CryptoKit (AES-GCM sealing of ping payloads) plus HTTPS, i.e. encryption provided by
  the OS. If App Store Connect asks, answer accordingly. ⚠️ You're responsible for this declaration; if
  unsure, check Apple's export-compliance guidance.
- **Privacy "nutrition label"**: data is stored in the user's own iCloud and is not collected by you.
  Location is optional, per-poop, and shared only with the user's friends/groups through their iCloud.
  Fill in "Data Not Collected", or "Location → App Functionality, not linked to tracking" if you prefer
  to be conservative.

---

## 6. First device test (two iPhones, two different Apple IDs)

TestFlight build → install on both phones (each signed in to its **own** iCloud account, iCloud Drive
on). Then go through:

1. Onboard both. Log a double-tap poop offline (airplane mode), relaunch, go online → it syncs.
2. Phone A: Today → 👥 → share invite → Phone B opens the link → request → Phone A accepts → both see
   each other's full calendar (including old entries) and "currently pooping" bubbles.
3. Phone A single-taps POOPING → Phone B gets "💩 @a is pooping" (also with B's app killed).
4. Poop With Me: A invites B → B taps **JOIN** on the notification → B's +1 and timer start
   immediately → reactions fly both ways → A taps DONE → A sees "STILL GOING" and can keep watching.
5. Groups: create on A, join on B via the link → B can see the group leaderboard but **not** A's full
   history unless they're also friends. Owner can remove a member from the member list (⋯).
6. Poop Party scheduled 6 minutes ahead → 5-minute reminder → start alert with JOIN.
7. YOU → Settings → **Private lock screen** on → alerts read "ShittyFriends / @a checked in".
8. Unfriend on A → B loses A's calendar.
9. YOU → Settings → **Export my data** → zip opens with all files listed in handoff §2.3.
10. "Delete all my data" on A → A is back at onboarding, and A's other devices wipe too.

Things that can only be verified on devices: push delivery timing, background session timers, and
CloudKit share acceptance flows.
