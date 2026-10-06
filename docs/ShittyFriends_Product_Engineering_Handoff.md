# ShittyFriends — Product & Engineering Handoff

**Status:** Product direction locked enough for implementation planning  
**Platform:** iOS  
**App name:** `ShittyFriends`  
**Bundle ID:** `com.sakara.shittyfriends`  
**App Store Connect Apple ID:** `6819505355`  
**App Store Connect API identifier:** `HLBSVSN338`  
**Important:** No API private key or secret is included in this document.

---

# 1. Product Vision

ShittyFriends is a close-friends social iOS app built around one deliberately simple action:

> **I am pooping.**

Users log poops, notify friends, compare activity, join live "Poop With Me" sessions, schedule Poop Parties, collect achievements, unlock increasingly ridiculous 3D poop cosmetics, view location-attached poop history, and browse daily/weekly/monthly highlights.

The intended feeling is:

- immediate
- absurd
- highly social
- colorful
- tactile
- funny without feeling cheap
- low-friction
- expressive rather than analytical
- intimate rather than public

The visual inspiration is the **energy and personality** of old Zenly, Setlog, and BeReal, especially:

- high contrast
- oversized typography
- saturated color
- playful layouts
- shiny / glossy 3D emoji-like objects
- exaggerated motion
- tactile buttons
- expressive friend states
- almost no "corporate dashboard" feeling

Do **not** directly copy Zenly artwork, screen layouts, icons, motion assets, or branding.

ShittyFriends should develop its own recognizable visual language.

---

# 2. Hard Product Rules

These are foundational and should not be casually changed.

## 2.1 No developer-owned user-data database

Do **not** use Firebase, Supabase, a custom PostgreSQL server, or any developer-controlled central database to store users' poop histories, locations, groups, or social activity.

Canonical personal data should live in:

1. local device storage
2. the user's own iCloud / CloudKit private database
3. CloudKit shared records when the user explicitly shares something

The developer should not operate a conventional backend containing everybody's poop history.

## 2.2 Local-first

The app should remain usable when offline.

Local state should update immediately, then reconcile with CloudKit.

The UI must never feel like it is "waiting for the server" after tapping POOPING.

## 2.3 User-owned export

Users must be able to export their data.

Recommended:

```text
ShittyFriends Export/
├── profile.json
├── poop-history.json
├── poop-history.csv
├── locations.json
├── achievements.json
├── groups.json
├── friendships.json
├── poop-with-me-sessions.json
└── README.txt
```

Import should also be supported eventually.

## 2.4 Invite-only social graph

There is no global ShittyFriends directory.

Adding friends should be through:

- QR code
- invite link
- iOS Share Sheet
- AirDrop
- Messages / LINE / WhatsApp / etc.
- group invite

This fits the no-central-user-directory architecture.

## 2.5 No global username uniqueness requirement

A user identity consists of:

- `@handle`
- avatar

There is no required real/display name.

Handles only need to make sense socially, not be globally unique.

---

# 3. Core User Identity

Each account/profile has:

```text
handle
avatar
profile/color identity
cosmetic poop collection
notification preferences
privacy preferences
```

Example:

```text
@lee
[avatar]
```

No separate display name is required.

## 3.1 Duplicate handles inside a group

If two users in the same group use the exact same handle:

```text
@lee (1)
@lee (2)
```

This suffix exists **only for disambiguation in that group**.

Rules:

- suffixes are dynamic
- suffix is not part of the underlying handle
- if one person changes handle and the conflict disappears, remove `(1)` / `(2)`
- suffix numbering should be deterministic within the group
- duplicate handles outside that specific group do not matter

Example:

```text
Group members:
@lee
@lee

Rendered:
@lee (1)
@lee (2)
```

Then one changes to:

```text
@leew
```

Rendered:

```text
@lee
@leew
```

---

# 4. Primary Action: POOPING

The core action should be visually dominant.

The main screen should have a large, tactile:

# POOPING

button.

There are two different interactions.

---

# 5. POOPING Button Interaction

## 5.1 Single tap

**Single tap = start a timed poop session.**

Immediately:

- record +1 poop
- save timestamp
- optionally attach current location
- mark user as `currently pooping`
- start timer
- display currently-pooping bubble/status to permitted friends
- show live session UI
- expose "Poop With Me"
- enable point-tapping mechanic
- send applicable notifications

The count increases immediately when the session starts.

The timer is not used to decide whether the poop counts.

## 5.2 Double tap

**Double tap = instant poop log.**

Use this when the user does not want to run a session.

Immediately:

- record +1
- save timestamp
- optionally save location
- do not require live timer
- no long live "currently pooping" session
- produce the normal friend notification unless disabled

A brief animation / status can still show that it was recorded.

## 5.3 Mistakes

Provide a short-lived Undo after logging.

Also allow later editing/deletion from history.

---

# 6. Timed Poop Session

A timed session starts from single-tapping POOPING.

Suggested live layout:

```text
        CURRENTLY POOPING

             04:32

           [ BIG 3D 💩 ]

        tap tap tap tap tap

       +18 points this session

        [ POOP WITH ME ]

             DONE
```

## 6.1 Timer rules

The timer:

- starts immediately
- keeps running until DONE
- may continue if the app backgrounds
- can be reconstructed from stored timestamps
- should not rely on a foreground-only timer
- can be manually corrected later if the user forgot to stop it

The user may later edit:

- start time
- end time / duration
- location
- whether it was manually added
- potentially visibility, if product design supports it

## 6.2 Forgotten timer

If the user forgets to press DONE:

The history editor must allow correcting the timer.

Do not punish the user or invalidate the poop.

Recommended future quality-of-life feature:

- unusually long timer warning
- e.g. "Still pooping?"
- never auto-delete the session

Exact threshold remains tunable.

---

# 7. Currently Pooping Presence

During an active timed session, friends who are allowed to see it should get a live presence indicator.

Examples:

```text
@lee
💩 Currently pooping · 04:32
```

or a floating bubble on the friend screen/map.

This status disappears when:

- user taps DONE
- corrected session is ended
- session is manually cancelled

The historical poop remains.

---

# 8. Poop Tap Points

During a timed poop session, a large shiny 3D poop sits on screen.

The user taps it to earn points.

The tap interaction should feel extremely tactile:

- squash
- stretch
- bounce
- haptic feedback
- particles
- shine
- small combo animation
- escalating visual ridiculousness

Points are used to unlock **better / rarer poop visuals for chat/reactions/social expression**.

Example progression:

```text
Basic Poop
Glossy Poop
Golden Poop
Chrome Poop
Crystal Poop
Fire Poop
Galaxy Poop
Royal Poop
Radioactive Poop
Animated Legendary Poop
```

## 8.1 Important design constraint

The point mechanic should reward interacting during an existing timed session.

It should **not** reward having more bowel movements.

This avoids making the achievement system encourage artificially increasing poop frequency.

## 8.2 Anti-farming decision still required

Unlimited tapping would be extremely easy to farm.

Recommended implementation:

- points per tap have a session cap
- diminishing return after a threshold
- occasional bonus / critical taps
- daily point ceiling
- cosmetics should not require unhealthy behavior

Exact balancing can be tuned later.

Suggested prototype:

```text
First 30 taps: 1 point each
31–60: 0.5 effective points each
Session cap: 50 points
Daily cap: 150 points
```

This is provisional, not yet a locked product rule.

---

# 9. Poop With Me

This is a major feature, not a secondary extra.

## 9.1 Starting it

During an active timed poop session:

```text
[ POOP WITH ME ]
```

User chooses friends or a group.

Example:

```text
POOP WITH ME

○ @sam
● @josh
● @aiden
○ @emily

[ INVITE 2 ]
```

## 9.2 Invite

Invite should feel playful.

Example notification:

```text
💩 @lee wants to poop with you

JOIN
```

Avoid full chat-style complexity in v1.

## 9.3 Joining

When another user presses JOIN:

- immediately records +1 poop for them
- starts their own timer
- marks them currently pooping
- optionally records their location
- enters the same Poop With Me session
- activates their own point-tapping poop
- gives them a DONE button

Therefore:

> JOIN means "I am actually pooping now."

## 9.4 Live session

Example:

```text
        POOP WITH ME

@lee                 @josh
04:32                 01:12
💩                    💩

@sam
INVITED...

😂   💀   🔥   🫡   🤝   👑
```

Use quick reactions rather than full chat initially.

Possible behavior:

- tap reaction
- animated 3D reaction flies across screen
- receiver gets haptic/animation
- no permanent conversational burden required

## 9.5 Session ending

Each user's timer is independent.

If @lee finishes before @josh:

```text
@lee — DONE · 07:42
@josh — CURRENTLY POOPING · 09:11
```

The shared session can remain visible until everyone has ended.

---

# 10. Scheduled Poop Parties

Users can schedule future group pooping sessions.

Example:

```text
CREATE POOP PARTY

Friday
10:30 PM

The Boys

@lee      ✓
@josh     ✓
@sam      ?
@daniel   ✕

[ SCHEDULE ]
```

## 10.1 Party flow

Before:

```text
POOP PARTY STARTS IN 5 MINUTES
```

At start:

```text
🚨 POOP PARTY

@lee is ready
@josh is ready

[ JOIN ]
```

Joining behaves like Poop With Me:

- +1 immediately
- starts timer
- currently-pooping status
- point-tapping mechanic
- optional location

Users are never forced to join.

---

# 11. Poop History

Users have a full calendar.

Personal history can show:

- dates
- count
- timestamp
- duration
- location
- manual/logged-live status
- Poop With Me / party association
- reactions if retained
- editable metadata

Example:

```text
OCTOBER 6

💩 08:42
📍 Home
08m 14s

💩 13:21
📍 TPU
04m 51s
Poop With Me · @josh

💩 16:53
📍 Toyama Station
added later
```

---

# 12. Manual / Missed Logs

Users can add a missed poop later.

Example:

```text
ADD MISSED POOP

Date
Time

Duration (optional)
Location (optional)

[ ADD ]
```

Manual historical logs:

- increase stats
- appear in calendar
- can include location
- should be clearly marked `added later`
- should NOT send a misleading "currently pooping" notification
- should not create a live currently-pooping state

---

# 13. Location

Location is attached to individual poop events.

This is **not** continuous friend tracking.

Do not implement Zenly-style always-on friend location in v1.

## 13.1 Location behavior

When logging, location can be:

- enabled
- disabled
- optionally chosen/edited afterward

If location is shared on a poop:

- it remains permanently attached unless the user edits/deletes it
- friends with permission to view that history can see it
- map/history views can show it

## 13.2 Map direction

The map should visually feel inspired by Zenly's playful expressiveness:

- full-screen
- vivid map theme
- large avatars
- large glossy poop pins
- floating labels
- expressive camera movement
- minimal conventional map chrome
- colorful states

But do not copy Zenly's actual map styling/assets.

Example:

```text
          💩
   @lee · Toyama Station

                         💩
                     @sam · TPU

      💩
 @josh · Home
```

## 13.3 Historical poop map

Users should eventually be able to view:

- own poop map
- friend's shared poop locations
- group-visible poop locations
- clusters
- travel history

Potential fun stats:

- most-used poop location
- farthest poop from home
- cities pooped in
- countries pooped in
- "new territory"

---

# 14. Friendship Privacy

A full friend has broad access.

When a friendship is accepted:

> The new friend can see the user's **entire historical calendar**, including records from before the friendship began.

This includes permanently stored poop locations when location is part of those records.

This should be clearly communicated at friend-acceptance time.

Suggested confirmation copy:

```text
BECOME SHITTY FRIENDS?

@sam will be able to see your full poop history,
including older entries and shared poop locations.

[ ACCEPT ]
```

This is important because access is retroactive.

---

# 15. Group Privacy

Groups are different from friendship.

A user can share a group with another person **without making them a full friend**.

Group membership alone does NOT grant full personal-history access.

This enables:

```text
Group member ≠ full friend
```

## 15.1 Group-visible information

A group can include:

- current group member activity
- group leaderboard
- group poop events shared to that group
- Poop With Me sessions
- Poop Parties
- group achievements
- group highlights
- shared reactions

But a mere group member cannot open another member's complete personal historical calendar unless they are also friends.

---

# 16. Friends

Friends can see:

- avatar
- handle
- current pooping state
- today's count
- historical calendar
- permanent shared poop locations
- weekly/monthly activity
- achievements
- cosmetics
- applicable Poop With Me activity
- applicable group activity

Friendship should be bidirectional.

---

# 17. Groups

Groups are designed for close social circles.

Examples:

- The Boys
- Class
- Housemates
- Dorm
- Couple
- Trip
- Club

Recommended initial group sizes are small, but avoid a very restrictive hard cap unless technically necessary.

Suggested soft design target:

```text
3–12 members
```

Groups can have:

- name
- icon/3D object
- theme color
- members
- group calendar/activity
- leaderboard
- group achievements
- Poop Parties
- Poop With Me targeting
- notification preferences

---

# 18. Group Leaderboards

Support both:

- individual friend comparisons
- group rankings

Example:

```text
THE BOYS
THIS WEEK

👑 @josh      16
🥈 @lee       14
🥉 @ryan      11
   @sam        8
   @john       6

TOTAL 55 💩
```

Leaderboards report behavior.

They should not turn "poop more" into a progression requirement.

---

# 19. Highlights

Provide:

- daily highlights
- weekly highlights
- monthly highlights

Do not make them look like dry dashboards.

Aim for shareable, animated cards.

Example:

```text
THE WEEK IN SHIT

👑 THRONE OCCUPANT
@sam
14 logs

🤝 POOP BUDDIES
@lee + @sam
4 times within 10 min

🌅 EARLY BIRD
@lee
6 before 08:00

🌙 NIGHT SHIFT
@josh
4 after midnight

🔥 THE GREAT TUESDAY INCIDENT
11 group logs
```

Monthly highlight sequences can use a Spotify-Wrapped-like pacing without copying Spotify's visuals.

---

# 20. Achievements

Achievements should be playful glossy 3D objects.

Examples:

## Streak / consistency

**7 Day Shitter**  
At least one log on seven consecutive days.

**Monthly Regular**  
Logged on 25 different days in a month.

**Clockwork**  
Repeated similar-time logs over multiple days.

## Social

**Poop Pals**  
Complete 10 Poop With Me sessions.

**Party Animal**  
Join X Poop Parties.

**Perfect Attendance**  
Join every accepted Poop Party within a period.

## Location

**Traveller**  
Poop in 5 different places.

**International Shitter**  
Log in two countries.

**New Territory**  
First log in a new city/region.

## Time

**Early Bird**  
Early morning log.

**Night Shift**  
Late-night log.

## Collection

Achievements should look like objects:

- golden toilet
- jeweled toilet paper
- crown
- chrome poop
- melting clock
- twin toilets
- passport poop
- flaming throne
- crystal roll

Avoid achievements that explicitly tell users to increase bowel frequency.

---

# 21. Cosmetic Poop System

Point-earned poop visuals are primarily used for:

- social reactions
- Poop With Me interactions
- profile collection
- achievement presentation
- possibly message-like reaction surfaces

Examples:

```text
Common
Rare
Epic
Legendary
```

Possible poop styles:

- classic
- glossy
- soft-serve
- gold
- chrome
- glass
- lava
- ice
- galaxy
- radioactive
- royal
- angel
- devil
- disco
- holographic

The entire system should be intentionally absurd and collectible.

---

# 22. Chat / Communication Direction

Do NOT build a full conventional messaging platform for v1.

Use:

- preset reactions
- 3D poop cosmetics
- quick social actions
- Poop With Me
- party invites
- group activity

This reduces moderation burden and keeps the product focused.

If text chat is added later, treat it as a major scope expansion.

---

# 23. Notifications

Default friend poop notifications are ON.

Users can opt out later.

Notifications should be configurable:

## Per friend

```text
Every poop
Poop With Me only
Off
```

## Per group

```text
All activity
Poop With Me / Parties only
Highlights only
Off
```

## Global

```text
Friend poop notifications
Poop With Me
Poop Parties
Achievements
Daily summary
Weekly Shit Report
Monthly highlights
Quiet hours
```

Lock-screen privacy mode should be considered.

Private version:

```text
ShittyFriends
@lee checked in
```

Explicit version:

```text
💩 @lee is pooping
```

---

# 24. Suggested Main Navigation

Recommended initial structure:

```text
TODAY
MAP
GROUPS
CALENDAR
YOU
```

This is not final, but is a strong starting point.

## TODAY

Core social/presence screen.

Contains:

- current friends
- current poop states
- today counts
- giant POOPING control
- Poop With Me entry
- active session
- highlights

## MAP

Poop-location map.

Contains:

- historical pins
- friends' visible poop pins
- group activity
- colorful avatars
- map filters

## GROUPS

Contains:

- groups
- rankings
- group highlights
- Poop Parties
- shared Poop With Me sessions

## CALENDAR

Personal full history.

Potential switch to friends' calendars where permission exists.

## YOU

Contains:

- avatar
- @handle
- achievements
- poop cosmetic collection
- stats
- export
- notification/privacy settings

---

# 25. Home / Today Direction

Avoid a conventional social feed.

Friends should feel visually alive.

Example concept:

```text
          TUESDAY

   @sam                @lee
   💩 2                💩 3

             @josh
              💩 0

        [ giant 3D poop ]

          POOPING
```

Active friend:

```text
@sam
CURRENTLY POOPING
03:12
```

Use motion and state changes rather than a chronological feed.

---

# 26. Visual Language

ShittyFriends should be colorful at the system level.

Do not reduce it to:

> black app + orange accent.

Each friend can have a strong identity color.

Example:

```text
@lee   radioactive lime
@sam   electric blue
@josh  hot pink
@emily violet
```

3D objects can use independent materials:

```text
poop       glossy brown / wild variants
toilet     white ceramic + chrome
paper      soft white
crown      reflective gold
fire       translucent orange
crystal    refractive / iridescent
```

## UI characteristics

- very high contrast
- huge labels
- minimal tiny icons
- playful geometry
- asymmetric layouts
- strong use of scale
- large touch targets
- juicy spring animation
- deformation on touch
- layered 3D graphics
- intentionally exaggerated transitions
- friendly rather than gross realism

---

# 27. Motion Language

Examples:

## Logging

`2 → 3`

Do not simply update text.

Potential sequence:

1. button compresses
2. heavy haptic
3. 3D poop shoots upward
4. counter flips/slams from 2 to 3
5. surrounding avatars bounce
6. currently-pooping state appears
7. Poop With Me becomes available

## Point poop

Tap:

- squash
- particles
- rotation
- shine sweep
- score pop
- escalating combo intensity

## Reactions

3D reaction can:

- launch
- bounce
- collide
- splash
- pop
- spin

The motion system is a core part of the brand.

---

# 28. Data Model — Conceptual

Exact CloudKit record design can evolve, but these are the conceptual entities.

## UserProfile

```text
userID
handle
avatarAsset
themeIdentity
createdAt
updatedAt
```

## Friendship

```text
friendshipID
participantA
participantB
createdAt
status
```

## Group

```text
groupID
name
icon
theme
createdBy
createdAt
```

## GroupMembership

```text
groupID
userID
joinedAt
role
```

## PoopEvent

```text
eventID
ownerID
timestamp
source:
  - timed
  - instant
  - manual
duration
startTime
endTime
location
locationEnabled
createdAt
updatedAt
sessionID?
partyID?
manuallyAdjusted
```

## ActivePoopSession

```text
sessionID
ownerID
poopEventID
startedAt
endedAt?
status
pointsEarned
```

## PoopWithMeSession

```text
sessionID
creatorID
createdAt
participantIDs
invitedIDs
state
```

## PoopParty

```text
partyID
creatorID
groupID?
scheduledAt
participantIDs
inviteeIDs
status
```

## ReactionEvent

```text
reactionID
senderID
targetSessionID
reactionType
cosmeticID?
timestamp
```

## CosmeticUnlock

```text
cosmeticID
userID
unlockedAt
unlockSource
```

## AchievementUnlock

```text
achievementID
userID
unlockedAt
metadata
```

---

# 29. CloudKit Architecture Direction

Recommended:

```text
SwiftUI
SwiftData / local persistence
CloudKit private database
CKShare / shared records
CloudKit notifications
MapKit
CoreLocation
UserNotifications
WidgetKit later
ActivityKit later
```

## Principle

```text
Local database = immediate UX
CloudKit = sync / backup / sharing
```

Do not build screens that depend on immediate network completion.

## Private data

Personal canonical records should primarily originate in the user's private CloudKit database.

## Shared data

Use CloudKit sharing for:

- friendships
- shared visibility
- groups
- shared activity
- party/session metadata

Actual partitioning needs careful implementation design because friends and groups have different visibility semantics.

---

# 30. Data Visibility Model

Very important distinction:

## Private

Only owner:

- local drafts
- private settings
- unshared records

## Friend-visible

Full friend:

- entire poop history
- historical locations
- current status
- achievements
- full calendar

## Group-visible

Group member:

- group-shared events
- group leaderboard
- active/group social events
- group highlights

But NOT:

- complete personal history unless also a friend

The storage/share design must preserve this distinction.

---

# 31. Location Data Model

Each poop can hold optional location.

Suggested conceptual shape:

```text
latitude
longitude
placeName?
locality?
country?
accuracy?
capturedAt
```

Avoid continuous location tracking.

Location sharing is tied to poop records.

If included, it stays visible with that record permanently until the owner edits/deletes it.

---

# 32. Privacy / Permission Flow

Location must be optional.

Suggested first-use flow:

```text
ADD WHERE YOU POOP?

ShittyFriends can attach your location to a poop
so friends can see where it happened.

[ ALLOW LOCATION ]
[ NOT NOW ]
```

Avoid asking for location immediately on first launch unless the user actually uses the map/location feature.

Friend acceptance must clearly explain retroactive history access.

Group join must explain that group membership is not the same as full friendship.

---

# 33. Onboarding

Suggested onboarding:

## Screen 1

```text
SHITTYFRIENDS

A serious app for unserious business.
```

## Screen 2

Choose:

```text
@handle
avatar
```

## Screen 3

```text
ADD YOUR SHITTY FRIENDS

[ Show QR ]
[ Share Invite ]
```

## Screen 4

Explain:

```text
ONE TAP = TIMER
DOUBLE TAP = INSTANT LOG
```

## Screen 5

Notification opt-in.

## Screen 6

Optional location explanation.

Then enter TODAY.

---

# 34. Friend Invites

Recommended methods:

```text
QR
Universal Link
Share Sheet
AirDrop
```

Possible invite message:

```text
Become shitty friends with @lee 💩
```

Invitation should connect through the CloudKit sharing architecture.

No central username lookup is required.

---

# 35. Calendar

Full calendar is a core feature.

Potential monthly visual:

```text
OCTOBER 2026

M  T  W  T  F  S  S
         1  2  3  4
5  6  7  8  9 10 11
```

Days should not look clinical.

Possible visual encoding:

- one blob = one poop
- stacked blobs
- count badge
- avatar/theme color
- location marker
- social-session marker

Tap day to expand events.

---

# 36. Friends' Calendar Access

For full friends:

A user can open:

```text
@sam
CALENDAR
```

and view the full historical calendar, including pre-friendship records and permanent attached locations.

Group-only relationships do not receive this access.

---

# 37. Daily / Weekly / Monthly Statistics

Useful metrics:

- total poop count
- active days
- average per active day
- most common time window
- longest timed session
- shortest timed session
- most-used location
- number of unique places
- Poop With Me count
- Poop Party participation
- group contribution
- streaks

Avoid presenting medical diagnosis.

The app is primarily social/entertainment, not a diagnostic health product.

---

# 38. Moderation Scope

Keep v1 user-generated content constrained.

Recommended allowed content:

- handle
- avatar
- group names
- preset reactions
- invite/social events

Avoid in v1:

- photo posting
- public feed
- stranger discovery
- unrestricted image uploads
- feces photos
- anonymous public content

This keeps moderation and App Review risk substantially lower.

---

# 39. Target Audience

Primary:

```text
13–29
```

Especially:

- teenagers 13+
- university students
- young adults
- roommates
- couples
- friend groups

Do not intentionally target under-13 users.

---

# 40. App Store Naming

Preferred public name:

# ShittyFriends

Keep this name for development.

However, because of App Store metadata/profanity review risk, maintain a fallback public-facing name in reserve.

Potential fallback naming should be genuinely different rather than simply censoring one letter.

Do not prematurely rename the project unless App Review or App Store Connect forces it.

Current technical identity:

```text
App: ShittyFriends
Bundle ID: com.sakara.shittyfriends
Apple ID: 6819505355
API identifier: HLBSVSN338
```

---

# 41. App Store / Account Notes

Provided project metadata:

```text
App Store Connect
Bundle ID: shittyfriends
Identifier: com.sakara.shittyfriends
Apple ID: 6819505355
API: HLBSVSN338
```

Treat `HLBSVSN338` as an identifier only.

Never commit an App Store Connect `.p8` private key or API secret into the repository.

Recommended secret handling:

- local Keychain
- Codemagic encrypted environment variable
- GitHub Actions secret, if used
- never plaintext in source
- never included in app bundle

---

# 42. Suggested Repository Structure

Example:

```text
ShittyFriends/
├── App/
│   ├── ShittyFriendsApp.swift
│   └── AppEnvironment.swift
│
├── Features/
│   ├── Today/
│   ├── PoopSession/
│   ├── PoopWithMe/
│   ├── PoopParty/
│   ├── Calendar/
│   ├── Map/
│   ├── Friends/
│   ├── Groups/
│   ├── Achievements/
│   ├── Cosmetics/
│   ├── Profile/
│   ├── Settings/
│   └── DataExport/
│
├── Models/
│   ├── UserProfile.swift
│   ├── PoopEvent.swift
│   ├── Friendship.swift
│   ├── Group.swift
│   ├── PoopSession.swift
│   ├── PoopParty.swift
│   └── Achievement.swift
│
├── Services/
│   ├── LocalStore/
│   ├── CloudKit/
│   ├── Notifications/
│   ├── Location/
│   ├── Sharing/
│   ├── Export/
│   └── Achievements/
│
├── DesignSystem/
│   ├── Typography/
│   ├── Components/
│   ├── Motion/
│   ├── Haptics/
│   ├── Materials/
│   └── 3DAssets/
│
└── Tests/
```

---

# 43. Suggested V1 Scope

Build in this order.

## Phase 1 — Core local product

- onboarding
- @handle
- avatar
- TODAY screen
- single-tap timed POOPING
- double-tap instant POOPING
- +1 immediately
- timer
- DONE
- edit duration
- manual poop
- local calendar
- local stats
- local achievements
- point-tapping prototype
- cosmetic unlock prototype

## Phase 2 — iCloud

- CloudKit private sync
- multi-device sync
- offline reconciliation
- export
- import architecture

## Phase 3 — Friends

- QR
- invite link
- CloudKit sharing
- full-history friendship
- current-pooping bubble
- friend calendar
- notification controls

## Phase 4 — Groups

- create/join group
- group-only relationship
- duplicate handle suffixing
- group leaderboard
- group highlights
- group notifications

## Phase 5 — Social live features

- Poop With Me
- JOIN = +1 + timer
- live reactions
- participant state
- session completion

## Phase 6 — Poop Parties

- scheduling
- invites
- reminders
- join flow
- party stats

## Phase 7 — Location

- per-poop location
- edit location
- permanent history
- poop map
- friend/group permissions
- map polish

## Phase 8 — Visual polish

- full 3D poop collection
- rich motion system
- glossy materials
- advanced haptics
- highlights animation
- shareable cards

---

# 44. Non-Goals for Initial Release

Do not let scope expand into:

- global social network
- follower counts
- public discoverability
- continuous Zenly location
- full text chat
- photo/video posting
- health diagnosis
- stool-image analysis
- ads based on bowel data
- developer-hosted poop-history backend

---

# 45. Potential Future Features

Ideas worth preserving, but not required for v1:

- Home Screen widgets
- Lock Screen widget
- Live Activity while currently pooping
- Apple Watch logging
- Siri / App Intents
- "Pooping now" Dynamic Island
- yearly Shit Wrapped
- travel poop map
- city/country collection
- rare cosmetic drops
- group seasons
- group trophy rooms
- reaction sound packs
- shared custom themes
- couple mode
- roommate mode
- anonymous local stats only if privacy architecture can support it without a developer database
- iPad support
- custom avatar accessories

---

# 46. Live Activity / Dynamic Island Opportunity

A timed poop session is a natural candidate for ActivityKit.

Potential Live Activity:

```text
💩 POOPING
06:21

@josh joined you
```

Dynamic Island:

```text
💩 06:21
```

This is a strong future feature because the user can end/check the session without reopening the full app.

Do not make it mandatory for the first prototype.

---

# 47. Critical UX Rules

1. Logging must feel instant.
2. Never show a loading spinner before +1.
3. Single tap starts timer.
4. Double tap logs instantly.
5. JOIN to Poop With Me counts +1 immediately.
6. Timers are editable afterward.
7. Manual logs do not pretend the user is currently pooping.
8. Location is optional.
9. Location belongs to individual poop records.
10. Full friends see full historical calendar.
11. Group-only members do not.
12. Friend access is retroactive to old history.
13. Shared poop locations remain in history permanently until edited/deleted.
14. No central ShittyFriends user database.
15. No global username uniqueness dependency.
16. Duplicate handles use temporary `(1)`, `(2)` labels within conflicting groups.
17. Points reward interaction, not increased bowel frequency.
18. The app must stay funny and tactile rather than clinical.
19. 3D objects and motion are a first-class product feature.
20. Notifications must be easy to silence.

---

# 48. Open Decisions — Non-Blocking

These do not prevent development from starting.

## Timer UX

Need final decision later on:

- whether active timer has an optional soft reminder after 20/30/45 min
- whether timer can run indefinitely
- how accidental long sessions are displayed in statistics

Recommended:
allow indefinite timer but mark suspiciously long durations for easy correction.

## Point economy

Need balancing:

- point-per-tap
- session cap
- daily cap
- cosmetic pricing
- streak bonus
- rarity

Do not allow the mechanic to become physically obnoxious or trivially farmable.

## Avatar system

Need later decision:

- photo
- Memoji-like builder
- 3D custom character
- preset illustrated avatars

Given the target aesthetic, a stylized avatar creator is likely stronger than ordinary profile photos.

## Friend removal

Need policy:

- what happens to previously shared history after unfriend
- revoke CloudKit access immediately
- whether cached data is purged locally

Recommended:
revoking friendship should remove future and historical access for the former friend.

## Group-leave behavior

Need define:

- whether historical group highlights retain anonymized departed-member stats
- how shared records are revoked

## Location naming

Need decide whether to store:

- raw coordinate only
- approximate place label
- Apple Maps place lookup snapshot

Recommended:
store coordinate + resolved display label, while allowing label edits.

---

# 49. Product Personality Examples

Possible copy style:

```text
YOU'RE POOPING
Excellent.
```

```text
@sam joined you.
You're not alone anymore.
```

```text
POOP COMPLETE
07:42
Respectable.
```

```text
3 TODAY
That's information.
```

```text
THE BOYS
55 poops this week.
A functioning society.
```

```text
NEW COSMETIC
GOLDEN POOP
Unnecessarily expensive looking.
```

Humor should be concise and deadpan.

Avoid forcing a joke into every label.

---

# 50. Final Product Summary

ShittyFriends should not become a sophisticated bowel-health database wearing a funny skin.

It should be:

> **a tiny social ritual that happens several times a day.**

The loop is:

```text
POOP
↓
FRIENDS KNOW
↓
OPTIONALLY POOP TOGETHER
↓
TAP / REACT / EARN
↓
HISTORY GROWS
↓
GROUP STATS + HIGHLIGHTS
↓
ACHIEVEMENTS + COSMETICS
↓
COME BACK NEXT TIME
```

Its competitive advantage should be:

- personality
- intimacy
- visual identity
- zero-friction logging
- live presence
- absurd collectibility
- user-controlled data
- no conventional developer-owned poop database

The most important product distinction is:

> **Group membership is social access. Friendship is personal-history access.**

And the most important technical principle is:

> **The user's device and iCloud own the data, not ShittyFriends' server.**
