/**
 * ShittyFriends Cloud Functions.
 *
 * Three jobs, nothing else:
 *  1. Push fan-out (FCM): "💩 @lee is pooping", Poop With Me invites/joins, party invites, friend
 *     requests/acceptances, group join requests/approvals. Preferences (per friend / per group levels,
 *     global switches, quiet hours, private lock screen) are applied here, server-side, so a device
 *     never receives an alert it opted out of.
 *  2. Group membership that sticks: join requests, owner approval/decline, kicks (with a ban list),
 *     leaving, deleting a group. Security rules keep `memberIDs` / `bannedIDs` read-only for clients.
 *  3. Account deletion: everything the user wrote, their memberships and their Auth user.
 *
 * Deploy: `cd firebase && firebase deploy --only functions,firestore` (see docs/SETUP.md).
 */
import { initializeApp } from "firebase-admin/app";
import { FieldValue, Firestore, getFirestore, Timestamp, DocumentReference } from "firebase-admin/firestore";
import { getAuth } from "firebase-admin/auth";
import { getMessaging, Message } from "firebase-admin/messaging";
import { onDocumentCreated, onDocumentWritten, Change, DocumentSnapshot } from "firebase-functions/v2/firestore";
import { onCall, HttpsError, CallableRequest } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { logger, setGlobalOptions } from "firebase-functions/v2";

initializeApp();
setGlobalOptions({ region: "asia-northeast1", maxInstances: 20 });

const db: Firestore = getFirestore();
const APP_NAME = "ShittyFriends";

// ---------------------------------------------------------------------------------------------
// Types mirrored from the Swift models (only the fields the server needs)
// ---------------------------------------------------------------------------------------------

type Person = { id: string; handle: string; color?: string; avatar?: unknown; cosmetic?: string; pinShine?: string };

type Settings = {
  notifyFriendPoops?: boolean;
  notifyPWM?: boolean;
  notifyParties?: boolean;
  quietHoursEnabled?: boolean;
  quietStartMinutes?: number;
  quietEndMinutes?: number;
  lockScreenPrivate?: boolean;
  timeZoneID?: string;
  blockedUserIDs?: string[];
};

type Kind =
  | "poopStart" | "poopInstant"
  | "pwmInvite" | "pwmJoin"
  | "partyInvite"
  | "friendRequest" | "friendComplete"
  | "groupJoinRequest" | "groupJoined";

type Alert = {
  kind: Kind;
  sender?: string;         // handle without "@"
  groupName?: string;
  groupID?: string;
  spaceID?: string;
  sessionID?: string;
  partyID?: string;
  partyTitle?: string;
};

// ---------------------------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------------------------

function pairID(a: string, b: string): string { return a < b ? `${a}_${b}` : `${b}_${a}`; }

async function settingsOf(uid: string): Promise<Settings> {
  const snap = await db.doc(`users/${uid}/private/settings`).get();
  return (snap.data() as Settings | undefined) ?? {};
}

async function handleOf(uid: string): Promise<string> {
  const snap = await db.doc(`users/${uid}`).get();
  return (snap.data()?.handle as string | undefined) ?? "a shitty friend";
}

async function friendIDs(uid: string): Promise<string[]> {
  const q = await db.collection("friendships").where("members", "array-contains", uid).get();
  const out: string[] = [];
  for (const d of q.docs) {
    for (const m of (d.data().members as string[])) if (m !== uid) out.push(m);
  }
  return out;
}

/** Per-friend alert level `recipient` set for `about`. Defaults to "every" (handoff §23). */
async function friendLevel(recipient: string, about: string): Promise<"every" | "pwmOnly" | "off"> {
  const q = await db.collection(`users/${recipient}/friendLinks`).where("userID", "==", about).limit(1).get();
  if (q.empty) return "every";
  return (q.docs[0].data().notify as "every" | "pwmOnly" | "off") ?? "every";
}

/** Per-group alert level `recipient` set for group `gid`. Members joining by link default to pwmAndParties. */
async function groupLevel(recipient: string, gid: string): Promise<"all" | "pwmAndParties" | "highlightsOnly" | "off"> {
  const snap = await db.doc(`users/${recipient}/groupLinks/${gid}`).get();
  return (snap.data()?.notify as "all" | "pwmAndParties" | "highlightsOnly" | "off") ?? "pwmAndParties";
}

function minutesFromMidnight(tz: string | undefined, at: Date): number {
  try {
    const parts = new Intl.DateTimeFormat("en-US", { timeZone: tz || "UTC", hour: "numeric", minute: "numeric", hour12: false }).formatToParts(at);
    const h = Number(parts.find(p => p.type === "hour")?.value ?? "0") % 24;
    const m = Number(parts.find(p => p.type === "minute")?.value ?? "0");
    return h * 60 + m;
  } catch {
    return at.getUTCHours() * 60 + at.getUTCMinutes();
  }
}

function isQuiet(s: Settings, at: Date): boolean {
  if (!s.quietHoursEnabled) return false;
  const start = s.quietStartMinutes ?? 23 * 60;
  const end = s.quietEndMinutes ?? 7 * 60;
  if (start === end) return false;
  const m = minutesFromMidnight(s.timeZoneID, at);
  return start < end ? (m >= start && m < end) : (m >= start || m < end);
}

/** Same copy as NotificationTextBuilder in the app. */
function text(a: Alert, privateMode: boolean): { title: string; body: string; category: string; thread: string } {
  const who = a.sender ? `@${a.sender}` : "A shitty friend";
  const g = a.groupName;
  let title: string;
  let body: string;
  let category = "SF_GENERAL";
  switch (a.kind) {
    case "poopStart":
      title = privateMode ? APP_NAME : `💩 ${who} is pooping`;
      body = privateMode ? `${who} checked in` : (g ? `in ${g}` : "Right now.");
      break;
    case "poopInstant":
      title = privateMode ? APP_NAME : `💩 ${who} just pooped`;
      body = privateMode ? `${who} checked in` : (g ? `in ${g}` : "Logged.");
      break;
    case "pwmInvite":
      title = privateMode ? APP_NAME : `💩 ${who} wants to poop with you`;
      body = privateMode ? `${who} sent an invite` : (g ? `JOIN · ${g}` : "JOIN");
      category = "SF_PWM_INVITE";
      break;
    case "pwmJoin":
      title = privateMode ? APP_NAME : `${who} joined you.`;
      body = privateMode ? `${who} checked in` : (g ? `You're not alone anymore. · ${g}` : "You're not alone anymore.");
      break;
    case "partyInvite":
      title = privateMode ? APP_NAME : `🚨 ${who} scheduled a Poop Party`;
      body = privateMode ? `${who} sent an invite` : (g ? `${a.partyTitle ?? "Poop Party"} · ${g}` : (a.partyTitle ?? "Poop Party"));
      category = "SF_PARTY_INVITE";
      break;
    case "friendRequest":
      title = privateMode ? APP_NAME : `${who} wants to be shitty friends`;
      body = privateMode ? `${who} sent a friend request` : "Open to accept.";
      category = "SF_FRIEND_REQUEST";
      break;
    case "friendComplete":
      title = privateMode ? APP_NAME : `You're shitty friends with ${who}`;
      body = privateMode ? `${who} is now a friend` : "Histories unlocked.";
      break;
    case "groupJoinRequest":
      title = privateMode ? APP_NAME : `${who} wants to join ${g ?? "your group"}`;
      body = privateMode ? `${who} asked to join a group` : "Open the group to approve.";
      category = "SF_GROUP_REQUEST";
      break;
    case "groupJoined":
      title = privateMode ? APP_NAME : `You're in ${g ?? "the group"}`;
      body = privateMode ? "A group let you in" : "Group activity only. Full history stays between friends.";
      break;
  }
  return { title, body, category, thread: g ?? (a.sender ? `@${a.sender}` : "shittyfriends") };
}

/** Sends one alert to every device of `uid`, honouring their settings. Never throws. */
async function push(uid: string, a: Alert, opts: { silent?: boolean } = {}): Promise<void> {
  try {
    const [settings, devices] = await Promise.all([settingsOf(uid), db.collection(`users/${uid}/devices`).get()]);
    if (devices.empty) return;
    const privateMode = settings.lockScreenPrivate === true;
    const quiet = opts.silent === true || isQuiet(settings, new Date());
    const t = text(a, privateMode);
    const data: Record<string, string> = { sf_kind: a.kind };
    if (a.sender) data.sf_sender = a.sender;
    if (a.groupName) data.sf_group = a.groupName;
    if (a.groupID) data.sf_group_id = a.groupID;
    if (a.spaceID) data.sf_space = a.spaceID;
    if (a.sessionID) data.sf_session = a.sessionID;
    if (a.partyID) data.sf_party = a.partyID;
    if (a.partyTitle) data.sf_title = a.partyTitle;
    const stale: DocumentReference[] = [];
    await Promise.all(devices.docs.map(async d => {
      const message: Message = {
        token: d.id,
        data,
        apns: {
          headers: { "apns-push-type": "alert", "apns-priority": quiet ? "5" : "10" },
          payload: {
            aps: {
              alert: { title: t.title, body: t.body },
              sound: quiet ? undefined : "default",
              category: t.category,
              threadId: t.thread,
              mutableContent: true,
              ...(quiet ? { "interruption-level": "passive" } : {}),
            },
          },
        },
      };
      try {
        await getMessaging().send(message);
      } catch (e: unknown) {
        const code = (e as { code?: string }).code ?? "";
        if (code.includes("registration-token-not-registered") || code.includes("invalid-argument")) stale.push(d.ref);
        else logger.warn("push failed", { uid, code });
      }
    }));
    for (const ref of stale) await ref.delete().catch(() => undefined);
  } catch (e) {
    logger.error("push error", { uid, e: String(e) });
  }
}

// ---------------------------------------------------------------------------------------------
// 1. Poop alerts: fired when the client sets `announce` on an event after the Undo window
// ---------------------------------------------------------------------------------------------

export const onPoopAnnounced = onDocumentWritten("users/{uid}/events/{eventID}", async (event) => {
  const before = event.data?.before.data();
  const after = event.data?.after.data();
  if (!after || after.announce !== true || before?.announce === true) return;
  const uid = event.params.uid as string;
  const source = after.source as string;
  if (source === "manual" || after.imported === true) return;
  const kind: Kind = source === "timed" ? "poopStart" : "poopInstant";
  const sender = await handleOf(uid);
  const notified = new Set<string>([uid]);

  // Friends: their per-friend level for me must be "every", and friend poop alerts on.
  for (const f of await friendIDs(uid)) {
    if (notified.has(f)) continue;
    notified.add(f);
    const [s, level] = await Promise.all([settingsOf(f), friendLevel(f, uid)]);
    if (s.notifyFriendPoops === false || level !== "every") continue;
    if ((s.blockedUserIDs ?? []).includes(uid)) continue;
    await push(f, { kind, sender });
  }

  // Group co-members (not friends): group level "all", and the poop is shared to that group.
  if (after.sharedToGroups === false) return;
  const links = await db.collection(`users/${uid}/groupLinks`).where("shareEvents", "==", true).get();
  for (const link of links.docs) {
    const gid = link.id;
    const group = await db.doc(`groups/${gid}`).get();
    if (!group.exists) continue;
    const members = (group.data()?.memberIDs as string[]) ?? [];
    if (!members.includes(uid)) continue;
    const name = group.data()?.name as string | undefined;
    for (const m of members) {
      if (notified.has(m)) continue;
      notified.add(m);
      const [s, level] = await Promise.all([settingsOf(m), groupLevel(m, gid)]);
      if (s.notifyFriendPoops === false || level !== "all") continue;
      await push(m, { kind, sender, groupName: name, groupID: gid });
    }
  }
});

// ---------------------------------------------------------------------------------------------
// 2. Poop With Me: invites and joins (groups and ad-hoc spaces share one handler)
// ---------------------------------------------------------------------------------------------

type Scope = { kind: "group"; gid: string } | { kind: "space"; sid: string };

async function scopeInfo(scope: Scope): Promise<{ name?: string; memberIDs: string[]; groupID?: string; spaceID?: string }> {
  if (scope.kind === "group") {
    const g = await db.doc(`groups/${scope.gid}`).get();
    return { name: g.data()?.name, memberIDs: (g.data()?.memberIDs as string[]) ?? [], groupID: scope.gid };
  }
  const s = await db.doc(`spaces/${scope.sid}`).get();
  return { memberIDs: (s.data()?.memberIDs as string[]) ?? [], spaceID: scope.sid };
}

async function wantsSocial(uid: string, scope: Scope, about: string, what: "pwm" | "party"): Promise<boolean> {
  const s = await settingsOf(uid);
  if (what === "pwm" && s.notifyPWM === false) return false;
  if (what === "party" && s.notifyParties === false) return false;
  if ((s.blockedUserIDs ?? []).includes(about)) return false;
  if (scope.kind === "group") {
    const level = await groupLevel(uid, scope.gid);
    if (level === "off" || level === "highlightsOnly") {
      // Still reachable as a friend, if they are one with the level on.
      const asFriend = (await db.doc(`friendships/${pairID(uid, about)}`).get()).exists && (await friendLevel(uid, about)) !== "off";
      return asFriend;
    }
    return true;
  }
  return (await friendLevel(uid, about)) !== "off";
}

async function participantWritten(scope: Scope, change: Change<DocumentSnapshot> | undefined): Promise<void> {
  const before = change?.before.data();
  const after = change?.after.data();
  if (!after) return;
  const person = after.person as Person | undefined;
  const sessionID = after.sessionID as string | undefined;
  if (!person || !sessionID) return;
  const root = scope.kind === "group" ? `groups/${scope.gid}` : `spaces/${scope.sid}`;
  const session = await db.doc(`${root}/sessions/${sessionID}`).get();
  const creatorID = session.data()?.creatorID as string | undefined;
  if (!creatorID) return;
  const info = await scopeInfo(scope);

  // Invited (new row with status invited, written by the creator): tell that person.
  if (!before && after.status === "invited" && person.id !== creatorID) {
    if (!(await wantsSocial(person.id, scope, creatorID, "pwm"))) return;
    await push(person.id, { kind: "pwmInvite", sender: await handleOf(creatorID), groupName: info.name, groupID: info.groupID, spaceID: info.spaceID, sessionID });
    return;
  }
  // Joined (status became joined, written by the person): tell the creator and everyone else pooping.
  if (after.status === "joined" && before?.status !== "joined") {
    const others = await db.collection(`${root}/participants`).where("sessionID", "==", sessionID).get();
    const recipients = new Set<string>([creatorID]);
    for (const p of others.docs) if (p.data().status === "joined") recipients.add((p.data().person as Person).id);
    recipients.delete(person.id);
    for (const r of recipients) {
      if (!(await wantsSocial(r, scope, person.id, "pwm"))) continue;
      await push(r, { kind: "pwmJoin", sender: person.handle, groupName: info.name, groupID: info.groupID, spaceID: info.spaceID, sessionID });
    }
  }
}

export const onGroupParticipantWritten = onDocumentWritten("groups/{gid}/participants/{id}", async (e) =>
  participantWritten({ kind: "group", gid: e.params.gid as string }, e.data));
export const onSpaceParticipantWritten = onDocumentWritten("spaces/{sid}/participants/{id}", async (e) =>
  participantWritten({ kind: "space", sid: e.params.sid as string }, e.data));

// ---------------------------------------------------------------------------------------------
// 3. Party invites (an RSVP row the creator writes for someone else)
// ---------------------------------------------------------------------------------------------

async function rsvpCreated(scope: Scope, snap: DocumentSnapshot | undefined): Promise<void> {
  const data = snap?.data();
  if (!data) return;
  const person = data.person as Person | undefined;
  const partyID = data.partyID as string | undefined;
  if (!person || !partyID || data.joinedAt) return;
  const root = scope.kind === "group" ? `groups/${scope.gid}` : `spaces/${scope.sid}`;
  const party = await db.doc(`${root}/parties/${partyID}`).get();
  const creatorID = party.data()?.creatorID as string | undefined;
  if (!creatorID || creatorID === person.id) return;
  if (!(await wantsSocial(person.id, scope, creatorID, "party"))) return;
  const info = await scopeInfo(scope);
  await push(person.id, {
    kind: "partyInvite", sender: await handleOf(creatorID), groupName: info.name, groupID: info.groupID, spaceID: info.spaceID,
    partyID, partyTitle: party.data()?.title as string | undefined,
  });
}

export const onGroupRSVPCreated = onDocumentCreated("groups/{gid}/rsvps/{id}", async (e) =>
  rsvpCreated({ kind: "group", gid: e.params.gid as string }, e.data));
export const onSpaceRSVPCreated = onDocumentCreated("spaces/{sid}/rsvps/{id}", async (e) =>
  rsvpCreated({ kind: "space", sid: e.params.sid as string }, e.data));

// ---------------------------------------------------------------------------------------------
// 4. Friends
// ---------------------------------------------------------------------------------------------

export const onFriendRequestCreated = onDocumentCreated("friendRequests/{id}", async (e) => {
  const d = e.data?.data();
  if (!d) return;
  const to = d.to as string;
  const from = d.fromPerson as Person | undefined;
  const s = await settingsOf(to);
  if ((s.blockedUserIDs ?? []).includes(d.from as string)) return;
  await push(to, { kind: "friendRequest", sender: from?.handle ?? (await handleOf(d.from as string)) });
});

export const onFriendshipCreated = onDocumentCreated("friendships/{pair}", async (e) => {
  const d = e.data?.data();
  if (!d) return;
  const members = d.members as string[];
  const acceptedBy = d.acceptedBy as string;
  const other = members.find(m => m !== acceptedBy);
  if (!other) return;
  // The request is finished: remove it (rules forbid the accepter from leaving it behind by accident).
  if (typeof d.requestID === "string") await db.doc(`friendRequests/${d.requestID}`).delete().catch(() => undefined);
  await push(other, { kind: "friendComplete", sender: await handleOf(acceptedBy) });
});

// ---------------------------------------------------------------------------------------------
// 5. Groups: membership that sticks (owner approves; kicked people stay out)
// ---------------------------------------------------------------------------------------------

function requireAuth(req: CallableRequest<unknown>): string {
  const uid = req.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");
  return uid;
}

function str(v: unknown, name: string): string {
  if (typeof v !== "string" || v.length === 0 || v.length > 200) throw new HttpsError("invalid-argument", `${name} missing`);
  return v;
}

async function personOf(uid: string): Promise<Person> {
  const u = await db.doc(`users/${uid}`).get();
  const d = u.data() ?? {};
  return { id: uid, handle: (d.handle as string) ?? "friend", color: d.color as string, avatar: d.avatar, cosmetic: d.equippedCosmetic as string, pinShine: d.equippedPinShine as string };
}

/** Anyone with the group link asks to join; the owner decides. Banned people are refused here. */
export const requestJoinGroup = onCall(async (req) => {
  const uid = requireAuth(req);
  const code = str((req.data as { code?: unknown })?.code, "code");
  const invite = await db.doc(`groupInvites/${code}`).get();
  if (!invite.exists) throw new HttpsError("not-found", "That invite link is no longer valid.");
  const gid = invite.data()?.gid as string;
  const group = await db.doc(`groups/${gid}`).get();
  if (!group.exists) throw new HttpsError("not-found", "That group no longer exists.");
  const g = group.data()!;
  if ((g.memberIDs as string[]).includes(uid)) return { gid, status: "member", name: g.name, object: g.object, color: g.color, ownerID: g.ownerID };
  if ((g.bannedIDs as string[]).includes(uid)) throw new HttpsError("permission-denied", "The owner removed you from this group.");
  await db.doc(`groups/${gid}/requests/${uid}`).set({ person: await personOf(uid), createdAt: FieldValue.serverTimestamp() });
  return { gid, status: "requested", name: g.name, object: g.object, color: g.color, ownerID: g.ownerID };
});

/** The requester changed their mind before the owner answered. */
export const cancelJoinRequest = onCall(async (req) => {
  const me = requireAuth(req);
  const gid = str((req.data as { gid?: unknown })?.gid, "gid");
  await db.doc(`groups/${gid}/requests/${me}`).delete().catch(() => undefined);
  return { ok: true };
});

export const onGroupJoinRequestCreated = onDocumentCreated("groups/{gid}/requests/{uid}", async (e) => {
  const gid = e.params.gid as string;
  const group = await db.doc(`groups/${gid}`).get();
  const owner = group.data()?.ownerID as string | undefined;
  if (!owner) return;
  const person = e.data?.data()?.person as Person | undefined;
  await push(owner, { kind: "groupJoinRequest", sender: person?.handle, groupName: group.data()?.name, groupID: gid });
});

async function ownerAndGroup(req: CallableRequest<unknown>): Promise<{ me: string; gid: string; g: FirebaseFirestore.DocumentData }> {
  const me = requireAuth(req);
  const gid = str((req.data as { gid?: unknown })?.gid, "gid");
  const group = await db.doc(`groups/${gid}`).get();
  if (!group.exists) throw new HttpsError("not-found", "Group not found.");
  const g = group.data()!;
  if (g.ownerID !== me) throw new HttpsError("permission-denied", "Only the owner can do that.");
  return { me, gid, g };
}

export const approveJoin = onCall(async (req) => {
  const { gid } = await ownerAndGroup(req);
  const uid = str((req.data as { uid?: unknown })?.uid, "uid");
  const request = await db.doc(`groups/${gid}/requests/${uid}`).get();
  if (!request.exists) throw new HttpsError("not-found", "No such request.");
  const person = (request.data()?.person as Person | undefined) ?? (await personOf(uid));
  const now = FieldValue.serverTimestamp();
  const batch = db.batch();
  batch.set(db.doc(`groups/${gid}/members/${uid}`), { person, role: "member", joinedAt: now, updatedAt: now });
  batch.update(db.doc(`groups/${gid}`), { memberIDs: FieldValue.arrayUnion(uid), bannedIDs: FieldValue.arrayRemove(uid), updatedAt: now });
  batch.delete(request.ref);
  await batch.commit();
  const group = await db.doc(`groups/${gid}`).get();
  await push(uid, { kind: "groupJoined", groupName: group.data()?.name, groupID: gid });
  return { ok: true };
});

export const declineJoin = onCall(async (req) => {
  const { gid } = await ownerAndGroup(req);
  const uid = str((req.data as { uid?: unknown })?.uid, "uid");
  await db.doc(`groups/${gid}/requests/${uid}`).delete();
  return { ok: true };
});

async function removeMemberRecords(gid: string, uid: string): Promise<void> {
  const root = `groups/${gid}`;
  const batch = db.batch();
  batch.delete(db.doc(`${root}/members/${uid}`));
  const events = await db.collection(`${root}/events`).where("ownerID", "==", uid).get();
  for (const d of events.docs) batch.delete(d.ref);
  await batch.commit();
}

/** Owner removes a member. They lose access at once and cannot rejoin with the link (ban list). */
export const kickMember = onCall(async (req) => {
  const { me, gid } = await ownerAndGroup(req);
  const uid = str((req.data as { uid?: unknown })?.uid, "uid");
  if (uid === me) throw new HttpsError("invalid-argument", "You can't remove yourself; delete the group instead.");
  await db.doc(`groups/${gid}`).update({ memberIDs: FieldValue.arrayRemove(uid), bannedIDs: FieldValue.arrayUnion(uid), updatedAt: FieldValue.serverTimestamp() });
  await removeMemberRecords(gid, uid);
  await db.doc(`groups/${gid}/requests/${uid}`).delete().catch(() => undefined);
  return { ok: true };
});

/** Owner lets a previously removed person ask again. */
export const unbanMember = onCall(async (req) => {
  const { gid } = await ownerAndGroup(req);
  const uid = str((req.data as { uid?: unknown })?.uid, "uid");
  await db.doc(`groups/${gid}`).update({ bannedIDs: FieldValue.arrayRemove(uid), updatedAt: FieldValue.serverTimestamp() });
  return { ok: true };
});

export const leaveGroup = onCall(async (req) => {
  const me = requireAuth(req);
  const gid = str((req.data as { gid?: unknown })?.gid, "gid");
  const group = await db.doc(`groups/${gid}`).get();
  if (!group.exists) return { ok: true };
  if (group.data()?.ownerID === me) throw new HttpsError("failed-precondition", "The owner deletes the group instead of leaving it.");
  await db.doc(`groups/${gid}`).update({ memberIDs: FieldValue.arrayRemove(me), updatedAt: FieldValue.serverTimestamp() });
  await removeMemberRecords(gid, me);
  return { ok: true };
});

async function deleteGroupTree(gid: string): Promise<void> {
  const invites = await db.collection("groupInvites").where("gid", "==", gid).get();
  for (const d of invites.docs) await d.ref.delete();
  await db.recursiveDelete(db.doc(`groups/${gid}`));
}

export const deleteGroup = onCall(async (req) => {
  const { gid } = await ownerAndGroup(req);
  await deleteGroupTree(gid);
  return { ok: true };
});

// ---------------------------------------------------------------------------------------------
// 6. Account deletion (server-side, complete)
// ---------------------------------------------------------------------------------------------

export const deleteAccount = onCall(async (req) => {
  const me = requireAuth(req);
  logger.info("deleteAccount", { me });
  // Friendships + requests.
  for (const d of (await db.collection("friendships").where("members", "array-contains", me).get()).docs) await d.ref.delete();
  for (const d of (await db.collection("friendRequests").where("from", "==", me).get()).docs) await d.ref.delete();
  for (const d of (await db.collection("friendRequests").where("to", "==", me).get()).docs) await d.ref.delete();
  for (const d of (await db.collection("invites").where("uid", "==", me).get()).docs) await d.ref.delete();
  // Groups: owned ones go entirely; others lose my membership and my poop copies.
  for (const d of (await db.collection("groups").where("ownerID", "==", me).get()).docs) await deleteGroupTree(d.id);
  for (const d of (await db.collection("groups").where("memberIDs", "array-contains", me).get()).docs) {
    await d.ref.update({ memberIDs: FieldValue.arrayRemove(me) });
    await removeMemberRecords(d.id, me);
  }
  // Spaces: owned ones go; others just drop me.
  for (const d of (await db.collection("spaces").where("ownerID", "==", me).get()).docs) await db.recursiveDelete(d.ref);
  for (const d of (await db.collection("spaces").where("memberIDs", "array-contains", me).get()).docs) {
    await d.ref.update({ memberIDs: FieldValue.arrayRemove(me) });
  }
  // Everything under users/{me}: history, achievements, cosmetics, settings, links, devices, blocks.
  await db.recursiveDelete(db.doc(`users/${me}`));
  await getAuth().deleteUser(me).catch(e => logger.warn("auth delete", { e: String(e) }));
  return { ok: true };
});

// ---------------------------------------------------------------------------------------------
// 7. Housekeeping: expired invites, expired spaces, stale requests
// ---------------------------------------------------------------------------------------------

export const cleanupExpired = onSchedule("every 24 hours", async () => {
  const now = Timestamp.now();
  for (const d of (await db.collection("invites").where("expiresAt", "<", now).limit(500).get()).docs) await d.ref.delete();
  for (const d of (await db.collection("spaces").where("expiresAt", "<", now).limit(200).get()).docs) await db.recursiveDelete(d.ref);
  const weekAgo = Timestamp.fromMillis(Date.now() - 7 * 24 * 3600 * 1000);
  for (const d of (await db.collection("friendRequests").where("createdAt", "<", weekAgo).limit(500).get()).docs) await d.ref.delete();
});

