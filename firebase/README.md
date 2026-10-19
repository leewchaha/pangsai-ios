# ShittyFriends backend (Firebase)

One Firebase project: **Authentication** (Sign in with Apple, Google), **Cloud Firestore** (sync,
friends, groups, sessions), **Cloud Functions** (push fan-out, group membership that sticks, account
deletion) and **Cloud Messaging** (alerts via APNs).

```
firebase/
├── firebase.json            project layout (rules, indexes, functions)
├── .firebaserc              project id placeholder — set yours
├── firestore.rules          the visibility model, enforced server-side
├── firestore.indexes.json   composite indexes the queries need
└── functions/               TypeScript Cloud Functions (Node 20, firebase-functions v2)
    └── src/index.ts
```

Deploy (see `docs/SETUP.md` §2 for the one-time project setup):

```bash
cd firebase
firebase use <your-project-id>
cd functions && npm ci && npm run build && cd ..
firebase deploy --only firestore:rules,firestore:indexes,functions
```

or run the Codemagic workflow **firebase-deploy**.

## Data model

Paths are what the iOS app writes (`FirestorePaths` in `ShittyFriends/Services/Firebase/FirebaseConfig.swift`).
Every record is the Swift model encoded with real fields (dates as Timestamps).

| Path | Record | Who reads | Who writes |
|---|---|---|---|
| `users/{uid}` | `UserProfile` | me, my friends | me |
| `users/{uid}/events/{eventID}` | `PoopEvent` (+ `announce`) | me, my friends | me |
| `users/{uid}/achievements/{id}`, `/cosmetics/{id}` | unlocks | me, my friends | me |
| `users/{uid}/private/settings` | `AppSettings` (+ `timeZoneID`) | me (functions) | me |
| `users/{uid}/friendLinks/{id}`, `/groupLinks/{gid}`, `/spaceLinks/{sid}`, `/invites/{token}` | my private links / prefs | me (functions) | me |
| `users/{uid}/devices/{fcmToken}` | `{platform, updatedAt}` | functions | me |
| `users/{uid}/blocks/{otherUID}` | `{at}` | me, rules | me |
| `invites/{token}` | `{uid, expiresAt}` | any signed-in user | the inviter |
| `friendRequests/{id}` | `{from, to, inviteToken, fromPerson, status, createdAt}` | from, to | from (create), either (delete) |
| `friendships/{a_b}` | `{members: [a, b], acceptedBy, requestID, createdAt}` | members | the receiver of a pending request (create), either (delete) |
| `groups/{gid}` | `GroupInfo` + `ownerID`, `memberIDs`, `bannedIDs` | members, pending requesters | owner (name/icon/colour); functions (lists) |
| `groups/{gid}/members/{uid}` | `GroupMember` | members | functions (join/kick/leave), the member (own row) |
| `groups/{gid}/requests/{uid}` | `GroupJoinRequest` | owner, requester | functions |
| `groups/{gid}/events/{eventID}` | `GroupEvent` (a poop copy) | members | its owner |
| `groups/{gid}/sessions`, `/participants/{sid_uid}`, `/reactions`, `/parties`, `/rsvps/{pid_uid}` | Poop With Me / parties | members | creator / the person the row is about |
| `groupInvites/{code}` | `{gid, ownerID, name, object, color}` | any signed-in user | owner |
| `spaces/{sid}` + the same live subcollections | ad-hoc Poop With Me / party between friends | `memberIDs` | owner |

Visibility (handoff §30): friends read a user's whole history; group members read only the copies
shared into the group; nobody else reads anything. Blocks veto requests and friendships on both sides.

## Alerts

`onPoopAnnounced` fires when the client sets `announce: true` on a poop (after the 6 s Undo window,
throttled to one per 2 min) and pushes "💩 @lee is pooping" / "just pooped" to friends (per-friend
level **Every poop**) and to co-members of groups the poop was shared to (group level **All activity**),
each person once. Poop With Me invites/joins, party invites, friend requests/acceptances and group
join requests/approvals are pushed when their records land. The server applies global switches,
per-friend / per-group levels, quiet hours (using `timeZoneID`) and the private lock screen; the
Notification Service Extension re-applies private mode and quiet hours from the device's own settings.

## Membership that sticks

`requestJoinGroup(code)` → `groups/{gid}/requests/{uid}` (refused when banned) → owner sees it →
`approveJoin` writes the member row and `memberIDs` → the member's listeners open. `kickMember` removes
the row, their poop copies and adds them to `bannedIDs`; rules make `memberIDs` / `bannedIDs`
read-only for clients. `leaveGroup`, `deleteGroup`, `cancelJoinRequest`, `unbanMember` likewise.

## Account deletion

`deleteAccount` deletes friendships, requests, invites, group memberships (and groups the user owns),
spaces, everything under `users/{uid}` and finally the Auth user. The app wipes the device afterwards.

## Housekeeping

`cleanupExpired` (daily) removes expired invites, expired spaces (recursively) and week-old requests.
