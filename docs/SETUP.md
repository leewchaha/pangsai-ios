# ShittyFriends — Setup (Apple Developer, Firebase, Codemagic)

Do these once, in order. The backend is one Firebase project you own: Authentication, Cloud Firestore,
Cloud Functions and Cloud Messaging. Users' data lives on their device first and in their account on
that project, visible only to the friends and groups they chose (`firebase/firestore.rules`).

Identifiers used everywhere (must match exactly):

| What | Value |
|---|---|
| App bundle ID | `com.sakara.shittyfriends` |
| Notification extension bundle ID | `com.sakara.shittyfriends.NotificationService` |
| Live Activity extension bundle ID | `com.sakara.shittyfriends.PoopingLiveActivity` |
| App Group | `group.com.sakara.shittyfriends` |
| App Store Connect Apple ID | `6819505355` |
| Cloud Functions region | `asia-northeast1` (change in `firebase/functions/src/index.ts` **and** `FirebaseConfig.functionsRegion`) |

An **individual** Apple Developer account supports everything here. Firebase's free (Spark) plan
does not run Cloud Functions; the **Blaze** (pay as you go) plan is required. At the sizes this app
targets (close friends, no feed) usage stays inside the free quotas.

---

## 1. Apple Developer portal (developer.apple.com → Certificates, Identifiers & Profiles)

> ⚠️ Do steps 1.1–1.5 **before** the first signed Codemagic build. The `ios-testflight` workflow
> uses existing signing identities in Codemagic; it does not register App IDs or capabilities.

1. **Identifiers → `+` → App Groups**: create `group.com.sakara.shittyfriends` (if not done before).
2. **Identifiers → App IDs → `com.sakara.shittyfriends`**. Enable and configure:
   - **Sign in with Apple** (enable; "Enable as a primary App ID").
   - **Push Notifications** (no certificate needed; Firebase uses an APNs **key**, step 2.4).
   - **App Groups** → select `group.com.sakara.shittyfriends`.
   - iCloud is **no longer needed**; leave it off (or remove it).
   - Save.
3. App IDs for `com.sakara.shittyfriends.NotificationService` and `com.sakara.shittyfriends.PoopingLiveActivity`
   with **App Groups** → the same group (both exist from earlier builds; check the group is ticked).
4. **Keys → `+`**: create an **APNs key** (Apple Push Notifications service). Download the `.p8` once,
   note the **Key ID** and your **Team ID**. This goes into Firebase (2.4), never into the repo.
5. **Profiles**: regenerate the **App Store** distribution profiles for all three bundle IDs after
   changing capabilities (the app profile now carries Sign in with Apple instead of iCloud). Fetch/upload
   them into Codemagic's **Code signing identities** and retire stale ones. `scripts/verify_signing_profiles.py`
   checks App Groups, Sign in with Apple and production push on the installed profiles.

⚠️ Never commit `.p8` keys, certificates, profiles, `GoogleService-Info.plist` or service-account JSON.
`.gitignore` blocks them.

---

## 2. Firebase project (console.firebase.google.com)

### 2.1 Create the project and the iOS app
1. **Add project** (any name; note the **project ID**). Analytics can stay off.
2. Upgrade to the **Blaze** plan (Cloud Functions need it).
3. **Add app → iOS**: bundle ID `com.sakara.shittyfriends`, App Store ID `6819505355`.
   Download **`GoogleService-Info.plist`**. Keep it outside the repo; it is injected at build time (3.2).

### 2.2 Authentication
**Build → Authentication → Sign-in method**:
- Enable **Apple**. Nothing else to fill in for the native iOS flow.
- Optional: enable **Google**. Then re-download `GoogleService-Info.plist` (it now contains
  `CLIENT_ID` / `REVERSED_CLIENT_ID`). The app shows the Google button only when that CLIENT_ID is
  present; Codemagic inserts the reversed client id into `Info.plist` automatically (3.2). For a local
  Xcode build, replace `REVERSED_CLIENT_ID_PLACEHOLDER` in `ShittyFriends/Info.plist` by hand.

### 2.3 Firestore
**Build → Firestore Database → Create database** → production mode, pick a region close to your users
(e.g. `asia-northeast1`). Rules and indexes are deployed from the repo (2.5), not typed in the console.

### 2.4 Cloud Messaging (APNs)
**Project settings → Cloud Messaging → Apple app configuration → APNs Authentication Key**: upload the
`.p8` from 1.4 with its Key ID and your Team ID. Without this, no alerts arrive.

### 2.5 Deploy rules + functions
Either run the Codemagic workflow **firebase-deploy** (3.3) or, on any machine with Node 20:

```bash
npm install -g firebase-tools
firebase login
cd firebase
firebase use <project-id>              # also fix firebase/.firebaserc
cd functions && npm ci && npm run build && cd ..
firebase deploy --only firestore:rules,firestore:indexes,functions
```

Re-deploy whenever `firestore.rules`, `firestore.indexes.json` or `functions/src` change.

### 2.6 Service account (for Codemagic deploys only)
**Project settings → Service accounts → Generate new private key** (JSON). Store it only as the
Codemagic secret `FIREBASE_SERVICE_ACCOUNT` (3.1).

---

## 3. Codemagic

### 3.1 Environment group `firebase`
**Codemagic → application → Environment variables**, group named exactly **`firebase`**:

| Variable | Value | Secret |
|---|---|---|
| `GOOGLE_SERVICE_INFO_PLIST` | `base64 -i GoogleService-Info.plist \| pbcopy` (one line) | yes |
| `FIREBASE_PROJECT_ID` | the project id | no |
| `FIREBASE_SERVICE_ACCOUNT` | the service-account JSON (2.6), pasted as is | yes |

`ios-check` works without any of them (the app then runs local-only in tests). `ios-testflight`
refuses to build without `GOOGLE_SERVICE_INFO_PLIST`. `firebase-deploy` needs the other two.

### 3.2 App Store Connect integration and code signing identities
Unchanged from before: the **Apple Developer Portal integration** named in `codemagic.yaml`
(`integrations: app_store_connect`), one **Apple Distribution** certificate, and **App Store** profiles
for all three bundle IDs (1.5). The `Preflight App Store provisioning profiles` step stops early with
exact instructions when a profile is missing or lacks App Groups / Sign in with Apple / push.

The `Install Firebase config` step writes `GoogleService-Info.plist` into `ShittyFriends/Resources/`
and, when the plist carries `REVERSED_CLIENT_ID`, patches the Google sign-in URL scheme into `Info.plist`.

### 3.3 Workflows (in `codemagic.yaml`)

| Workflow | What it does | Needs |
|---|---|---|
| `ios-check` | Generates the XcodeGen project and runs unsigned simulator tests | nothing (Firebase config optional) |
| `ios-testflight` | Signed build, uploads to TestFlight | integration, three App Store profiles, `GOOGLE_SERVICE_INFO_PLIST` |
| `firebase-deploy` | Deploys Firestore rules/indexes and Cloud Functions | `FIREBASE_PROJECT_ID`, `FIREBASE_SERVICE_ACCOUNT` |

**Run `ios-check` first.** If it fails, the log ends with a block titled `ERRORS (paste these to Claude)`.
Then `firebase-deploy`, then `ios-testflight`.

---

## 4. App Store Connect app record

- Name: **ShittyFriends** (keep a different fallback name ready in case review rejects it, handoff §40).
- Age rating: mild crude humor, no user-generated photos, no public chat. The app blocks under-13
  sign-up with a neutral date-of-birth check that isn't stored.
- **Sign in with Apple**: offered (required by Apple whenever Google sign-in is offered too).
- **Export compliance**: `ITSAppUsesNonExemptEncryption = NO` stays correct (HTTPS/TLS only).
- **Privacy "nutrition label"**: data is stored in the user's account on your Firebase project and
  shared only with the friends/groups they chose. Declare at least: *Identifiers (User ID) — app
  functionality*, *Location (coarse/precise, per poop) — app functionality*, *User content (handle,
  avatar, poop history) — app functionality*, *Contacts: none*. Linked to the user, not used for
  tracking. Add **Account deletion**: the app offers it (YOU → Settings → Delete my account), done
  server-side by the `deleteAccount` function.
- Privacy policy must mention Firebase (Google) as the hosting provider.

---

## 5. First device test (two iPhones, two different Apple IDs)

TestFlight build on both phones. Then:

1. Onboard both (age → **sign in with Apple** → handle/avatar). Log a double-tap poop in airplane mode,
   relaunch, go online → it syncs (Firebase console → Firestore → `users/{uid}/events`).
2. Phone A: Home → 👥 → share invite → Phone B opens the link → **SEND REQUEST** → A gets the alert,
   accepts → both see each other's full calendar (including old entries) and "currently pooping".
3. Phone A single-taps POOP NOW → after ~6 s B gets "💩 @a is pooping" (also with B's app killed).
4. Poop With Me: A invites B → B taps **JOIN** on the notification → B's +1 and timer start
   immediately → reactions fly both ways → A taps DONE → A sees "STILL GOING" and can keep watching.
5. Groups: create on A, B opens the link → **ASK TO JOIN** → A gets "@b wants to join" → **LET IN** →
   B sees the leaderboard but **not** A's full history. A removes B (⋯) → B is out and the link no
   longer lets B back in ("The owner removed you").
6. Poop Party scheduled 6 minutes ahead → 5-minute reminder → start alert with JOIN. A party only
   counts for achievements when somebody else joins too.
7. YOU → Settings → **Private lock screen** on → alerts read "ShittyFriends / @a checked in".
8. Unfriend on A → B loses A's calendar at once. Block on A → B can't request again.
9. YOU → Settings → **Export my data** → zip with all files listed in handoff §2.3. Import it on a fresh
   install: poops come back as "imported" (history only, no points, no leaderboards).
10. Sign out on A, sign in again → everything is back. **Delete my account** on A → A is back at
    onboarding; B sees the friendship gone; the Firebase console shows no `users/{a}` document.

Things that can only be verified on devices: push delivery timing, background session timers, Live
Activity, Sign in with Apple's real flow.
