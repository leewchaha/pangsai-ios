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

> ⚠️ Do steps 1.1–1.4 **before** the first signed Codemagic build. Codemagic creates certificates and
> provisioning profiles, but it does **not** create bundle IDs or turn on their capabilities.

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
5. **Profiles**: if any App Store profile for these two bundle IDs already exists from before step 3/4,
   **delete it**. A profile created before the capabilities were enabled lacks them and the build fails
   with "Provisioning profile doesn't include the iCloud / App Groups capability". Codemagic will create
   fresh ones.

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

### 3.2 Environment variable groups
Codemagic app → **Environment variables**. Mark every value **Secure**.

Group **`appstore_credentials`** (used by `ios-testflight`):

| Variable | Value |
|---|---|
| `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID from step 2 |
| `APP_STORE_CONNECT_KEY_IDENTIFIER` | Key ID from step 2 |
| `APP_STORE_CONNECT_PRIVATE_KEY` | Full contents of the `.p8` file, including the BEGIN/END lines |
| `CERTIFICATE_PRIVATE_KEY` | An RSA private key Codemagic uses to create/reuse your distribution certificate (see below) |

Generate `CERTIFICATE_PRIVATE_KEY` once on any Mac/Linux machine and **keep the file safe**: reusing it
lets every build reuse the same distribution certificate instead of creating a new one each time.

```bash
ssh-keygen -t rsa -b 2048 -m PEM -f shittyfriends_cert_key -q -N ""
cat shittyfriends_cert_key        # paste this whole output into CERTIFICATE_PRIVATE_KEY
```

Group **`cloudkit`** (used by `cloudkit-schema`, optional; see 4.2):

| Variable | Value |
|---|---|
| `CLOUDKIT_MANAGEMENT_TOKEN` | CloudKit Console → your account menu → *Manage Tokens* → create a **management** token |
| `TEAM_ID` | Your 10-character Team ID (Membership details) |

### 3.3 Workflows (in `codemagic.yaml`)

| Workflow | What it does | Needs |
|---|---|---|
| `ios-check` | Generates the project with XcodeGen, builds, runs all unit tests on a simulator. No signing. | nothing |
| `ios-testflight` | Signed App Store build → uploads to TestFlight. Creates/fetches profiles for the app **and** the notification extension, and sets the build number to latest TestFlight + 1. | `appstore_credentials`, steps 1–2 |
| `cloudkit-schema` | Validates `CloudKit/schema.ckdb` and imports it into the **Development** environment. | `cloudkit` group |

**Run `ios-check` first.** If it fails, the log ends with a block titled
`ERRORS (paste these to Claude)` → paste that block back.

---

## 4. CloudKit schema (must be in **Production** before TestFlight works)

TestFlight and App Store builds talk to the **Production** CloudKit environment, which can't
auto-create record types. The schema has to be imported into Development, then deployed.

### 4.1 Import into Development (pick one)
- **Codemagic:** run the `cloudkit-schema` workflow (needs the `cloudkit` group).
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
