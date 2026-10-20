# at-social: AutonomousTrust's social extension, owned by Agora

Social is the Agora feature set, built as an AutonomousTrust extension library
(C) and distribution (Python), plus its conformance protocol. It lived in the AT
repository until 2026-09-25 (FEATURE_SPLIT_PLAN Phase 5b), under
`src/c/extensions/social/`, `src/autonomous-trust-social/` and
`conformance/scenarios/social/`; that history is in AT's git log. Agora is its
only consumer, so it moved here. AT keeps only generic mechanism: the identity
hooks, the names-only `$AT_OWN_*` refusal, the reserved message-type range
(1000–1999) and app-event kinds 4–15, the `"social"` schema enum name, and the
identity adapters' extension points.

```
at-social/
  c/social/            libat_social: sources, CMakeLists.txt, test/ (21 ctest)
  python/              the autonomous_trust.social distribution (pyproject, tests)
  conformance/         AT harness plug-in: scenarios/social/, conformance_plugin.py,
                       python/social_adapter.py, c/social_adapter.{c,h}
  test-conformance.sh  AT's conformance run with this plug-in
```

AT is the `lib/autonomous_trust` submodule of muudd (`../../../lib/autonomous_trust`
from here). How an outside directory plugs into AT is AT's
`doc/architecture/extensions.md`, "External extensions and conformance plug-ins".

## Build and test

**C.** `c/social` is not a standalone CMake project. It is built inside AT's,
named in `AT_EXTERNAL_EXTENSIONS`, so it sees what an in-tree extension does.
Agora's `native/CMakeLists.txt` sets that before it adds AT. To run the
extension's own tests, configure AT with it:

```
cmake -S ../../../lib/autonomous_trust/src/c -B /tmp/at-social-build \
      -DAT_EXTERNAL_EXTENSIONS=$PWD/c/social
cmake --build /tmp/at-social-build -j
ctest --test-dir /tmp/at-social-build/extensions/social   # this directory's 17
```

The library lands at `<build>/extensions/social/libat_social.so`, as it did
in-tree, so Agora's rpath and bundle lines are unchanged.

**Python.** `python/run-tests.sh`. The tests find AT's core through `$AT_PY_SRC`
or by walking up to the submodule.

**Conformance.** `./test-conformance.sh` (flags as AT's
`scripts/test-conformance.sh`). It runs AT's full corpus, 250 core cases plus
this protocol's 56, in both harnesses, and diffs them.

## Design


Social is the Agora feature set: opt-in position and private proximity, signed
profiles, explicit connections, direct messages, feed posts and reactions,
first-person reports and local blocks, business ads and posts, and detached
co-signing. Since FEATURE_SPLIT_PLAN Phase 5 it is an extension in both
runtimes, and **present means on**: a node that links `libat_social`, or has
the `autonomous_trust.social` distribution on its path, has social; one that
does not carries none of it. There is no runtime switch, and AT has no option
for it: a build has social when `AT_EXTERNAL_EXTENSIONS` names `c/social` (below).

**C.** `c/social/` builds `libat_social` (`at_social`,
`at_social_static`, through `at_extension_library`). Linking it registers,
from load-time constructors:

- the identity hooks (AT's `identity/id_ext.h`, below);
- its 50 identity verbs, 25 from the wire and 25 from the app, through
  `processes/extension.h` on "identity" only;
- its 15 message types and 25 `AT_APP_*` verbs (`social/social_msg_types.h`);
- the app-event decoders behind `at_agora.h`.

The app-facing API kept its names: `at_agora.h`, `at_app_events_*`,
`at_agora_event_*` and event kinds 4–15, to which Agora has appended 16 and 17
(Phase 4 communities) and 18 (file sharing). The Agora shim and the Dart bindings
changed only their link and include lines. The anchor is `at_social_link()`
(`social/at_social.h`).

**The identity hooks.** `identity_ext_t` (`identity/id_ext.h`, at most
`IDENTITY_EXT_MAX` = 4, registered by `IDENTITY_EXT_REGISTER`) is how a feature
follows the identity process without the process naming it. Every member may
be NULL, and with nothing registered every dispatcher is a no-op and every
query false, which is exactly a node without the feature. `id_proc.c` calls
each through its dispatcher:

| Hook | Called from (`id_proc.c`) | Social uses it for |
|---|---|---|
| `init` | identity's own init | its state; seeds `$AT_OWN_*` |
| `reset` | `identity_reset_state`, after the final unlock | dropping all state |
| `run_start` | `identity_run`, after the handlers register | restoring the blocks from `social.cfg.json` before traffic |
| `peer_confirmed` | `handle_confirm_peer` | the position and profile queries |
| `group_update_seen` | `handle_group_update`, before any adopt | recording the peer's group |
| `periodic_resync` | `identity_periodic_caps_resync`, after the core sweep | re-asking position- and profile-less peers |
| `roster_replay` | `handle_peer_roster_request` | replaying its own events; says whether it logged |
| `peer_in_group` | `identity_emit_peer_observed` | PEER_OBSERVED's `in_group` |
| `peer_blocked` | `identity_emit_peer_observed`; `identity_get_peer_tier` | `blocked`, and a blocked peer's tier reads 0 |

**The C lock rule.** Social keeps its state behind its own leaf lock
(`social_state.lock`). The order is peers rwlock → identity lock → social
lock. The core dispatches every hook **with no lock held**, not the identity
lock and not a peers lock, so a hook may call back into exported identity
functions. The converse binds social: while it holds its own lock it calls
only map, string, `social_store_*` and log functions, never anything that
locks or dispatches. `identity_get_peer_tier` reads the tier under the identity
lock, unlocks, and only then asks `peer_blocked`, so a tier and a block are two
snapshots rather than one. What social needs from identity it calls through
exports in `identity/id_proc_priv.h`: `identity_state_ensure_init`, the
freshness pair, `identity_find_peer_pub`, `identity_send_to_network`,
`identity_emit_peer_observed`, `identity_request_attestation`,
`identity_is_local_app_verb` and `identity_refuse_remote_app_verb`.

**What stayed in the core.** Peer standing and the tier read are identity's:
a governance standing is not an Agora idea, and `get_peer_tier` asks the
extension only whether a peer is blocked. `net_msg_t.group_multicast` and
`RECIPIENT_GROUP` are unconditional core. The JSON key is still written only
when true, so the IPC bytes did not change. The local-app-verb guard
(`identity_is_local_app_verb`) is core, because core verbs use it too.

**The refusal.** The core keeps the names-only table beside the oracle table.
`identity_run` refuses, with an ERROR naming the library, when
`$AT_OWN_GEOHASH`, `$AT_OWN_EXACT` or `$AT_OWN_PROFILE` is set and non-empty
and no identity extension named "social" is registered
(`identity_ext_check_env`), the same three Python refuses on. A node told
to publish its position that silently published nothing would look healthy
while failing its operator.

**Python.** The distribution is `python/`
(`autonomous_trust.social`, `_python` beside an empty `_native`, redirector
prefix `autonomous_trust.social.`), found by its entry point or its
`_at_extension.py` marker. The modules are:

- `protocol` holds `SocialProtocol`: the 17 verbs moved off `IdentityProtocol`
  with their strings unchanged, the three store-and-forward verbs, the two
  community verbs, and the four file verbs;
- `extension` is the `Extension`;
- `handlers` holds the handlers and senders, as module functions `f(proc, …)`;
- `state` holds `SocialState`, on `proc.social`;
- `codec`, `proximity` and `social_store` are the canonical forms, grid tags
  and durable store;
- `file_xfer` is file sharing: wire forms, names, the bitmap and store, and
  the state machine.

Handlers register as `functools.partial(fn, proc)`, so the process still
pickles. The core's identity process calls the extension through
`IdentityHooks` on `Extension.identity`, fewer than C has, because Python has
no app-event carrier:

| Hook | Called from (`idprocess.py`) | Lock |
|---|---|---|
| `on_peer_confirmed(proc, queues, peer)` | `handle_confirm_peer` | not held |
| `periodic_resync(proc, queues)` | `_periodic_caps_resync`, inside its `try` | not held |
| `is_blocked_locked(proc, uuid_str)` | `get_peer_tier` | **held**: must not take `proc.lock` |

`Extension.post_fork` is Python's `run_start`. It restores the blocks before
the process takes traffic. `load_extensions` records a loaded name on every
process it runs for, so the hook acts only where `proc.social` exists (the
identity process). **Python keeps the single `proc.lock`**, where C has a
second lock: accrual runs under it, and a second lock would buy Python nothing
it can use. `AutonomousTrust.__init__` calls `extensions.check_env` after
`oracles.check_env` and raises `ExtensionMissingError` when any
`$AT_OWN_GEOHASH`/`$AT_OWN_EXACT`/`$AT_OWN_PROFILE` is set without social. It
logs the loaded extensions at INFO.

**Conformance.** Social is its own protocol, `social` (56 scenarios under
`conformance/scenarios/social/`). Social rides the identity process, so each harness's
social adapter is its identity adapter plus hooks:

- Python: `conformance/python/social_adapter.py`, `SocialAdapter(IdentityAdapter)`, through
  `FIXTURE_HOOKS`, `TRIGGERS`, `INBOUND_BUILDERS` and `STATE_CHECKS`.
- C: `conformance/c/social_adapter.c`, an `ic_ext_t` (AT's
  `src/c/conformance/adapters/identity_priv.h`: fixtures,
  inbound, dispatch, check_key, on_send, impl_free) run by
  `at_identity_run_ext`.

Both are plugged into AT's harnesses from here, and AT names neither. The C
adapter is registered by `at_conformance_adapter(...)` in `c/social/CMakeLists.txt`,
and the Python one by `conformance/conformance_plugin.py`, which AT's runner loads
when `$AT_CONFORMANCE_PLUGINS` names `conformance/`. Without them AT's corpus has
no `social` cases at all. The identity adapters name nothing social.
`tools/at_diagram.py` lets a plug-in scenario use its base protocol's verbs
(`_PROTOCOL_BASES`).

## Store-and-forward (Phase 4 DDIL)

A post is a group multicast, and a multicast is fire-and-forget: a node that is
not on the segment when it goes out never hears it. Across a partition that was
every post the other island made, lost for good at the heal, because no node
kept a post's body past delivering it. Now each node keeps its recent posts and
the network repairs itself, with no partition detection, because the first
step is periodic.

| Verb | Channel | Carries |
|---|---|---|
| `peer_post_digest` | group multicast, encrypted | the content ids of our recent stored posts, `{"feed":[...], "biz":[...]}` |
| `peer_post_want` | directed, encrypted | the ids from a digest that our dedup rings do not hold, back to its sender |
| `peer_post_backfill` | directed, encrypted | one stored post's ORIGINAL signed envelope, `{"kind":"feed"\|"biz","post":{...}}` |

**Nothing is taken on trust.** A backfilled post goes through the same inbound
path as the original (`_ingest_post` / `_ingest_business_post`): the author's
signature is re-verified, the tier gate or the business page gate applies, and
dedup is by the same content id. The node serving it vouches for nothing. Two
things only the group channel does: record co-membership (a backfill did not
decrypt with the group key) and relay (a backfill is terminal, or every heal
would re-flood the group). A digest or a want is honored only from an admitted
peer, and a post is never backfilled to its own author.

**Bounds.**
- `POST_STORE_CAP` 256 posts per kind (`post_store.h`), oldest evicted.
- A digest offers only posts younger than 24 h, by their own signed timestamp.
- At most 32 ids per kind per want, and 32 posts per kind per backfill.
- One want sent to, and one served for, each peer per 10 s.
- The digest goes out at most every `$AT_SOCIAL_DIGEST_SEC` (default 60),
  checked on identity's ~20 s resync sweep, and at the next sweep after a peer
  is confirmed.
- A full digest, 256 + 256 ids, is ~46 KB on the wire (base64), under the 65,507-byte
  UDP limit (`post_store_test`).

**Limits, stated.**
- The store is in memory. A restarted node cannot backfill what it held before
  the restart.
- A blocked author's posts are stored and served (a personal block governs what
  we see, not what our neighbors may: the reason the relay still runs).
- Python has no feed publish verb, so its store holds received posts only.
- The digest is a group multicast, so it reaches the other island only once
  both hold one group key again: posts are the group's, and this is by design.
- A digest per node per minute is fine at Dunbar scale. Its cost at city scale
  belongs to the relay work (Agora Phase 4, `../doc/agora/design.md` §4.1).

**Tests.**
- `c/social/test/post_store_test.c` and `python/tests/a_unit/test_post_store.py`
  cover the store.
- 13 conformance scenarios cover the verbs: `post-digest-*`, `post-want-*`,
  `post-backfill-*` and `business-post-backfill-*`. The C adapter's social state
  is a singleton shared by every participant, so each scenario tests ONE hop.
- `../test/cohort/partition_cohort.sh` runs the whole chain live across a real
  split.

## Communities (Phase 4, Ethne D37)

A community is an Ethne polity, and how content posted in its name is moderated
is its roll's decision: what an author must meet (operator-bound, a lowest
tier, a daily post cap) and what each label does (allow, warn, hide). The roll
tightens the policy at a majority and loosens it only above one; a Moderator it
seats labels posts alone. This library carries all of that and decides none
of it. The policy and every label are opaque Ethne artifacts here, verified by
the app, and the verdict for a post is the app's (`ethne_content_policy_verdict`
in Agora's cdylib). A reader who does not follow a community sees its posts
unmoderated.

| Verb | Channel | Carries |
|---|---|---|
| `peer_post` (scoped) | group multicast | a post in a community's name: `"community"` and the author's `"labels"`, SIGNED — the canonical form gains a trailer only when a community is named, so every other post keeps its bytes and its id (`post.h`) |
| `peer_community_policy` | group multicast, encrypted | the community's root-signed policy, carried in the FIRST PERSON by a node that follows it; never relayed (`community.h`) |
| `peer_post_label` | group multicast, encrypted | a moderator's member-signed labels on one post; relayed under `POST_MAX_HOPS` by nodes that follow the community (`community.h`) |
| `app_follow_community` / `app_unfollow_community` | app, local only | follow a community holding a policy the app verified; the core carries it and persists the follow |
| `app_publish_post_label` | app | put a moderator's label on the wire; confers nothing |

**The core never follows, replaces or trusts a policy from the wire.** A policy
ad is signature-checked against its CARRIER, deduped, and handed to the app;
the app verifies the community's root signature and, if it follows, hands the
newer bundle back through `app_follow_community`. A carrier claiming a higher
seq cannot freeze or roll back what a node holds.

**The follow gate.** A label is dropped unread and unrelayed by a node that does
not follow its community — the business-post page gate's twin — because a label
matters only where the policy applies. Labels are stored for backfill, and a
digest offers each one WITH its community, so a node that does not follow it
never asks: it would only drop it, and a dropped label never enters the dedup
ring, so it would ask again at every digest.

**Persistence.** Follows live in `etc/at/social.cfg.json` beside the blocks, as
`"communities": {"<did>": {"bundle", "seq"}}`, written only when non-empty, so a
node that follows nothing writes the same bytes as before. Holders re-carry
every `$AT_SOCIAL_POLICY_SEC` (default 300) and at the next sweep after a peer
is confirmed.

**Co-signing.** The courier's allowlist gains `content_policy`/`amend` and
`office`/`confer`, `office`/`revoke`, so the roll acts behind a policy travel
the same detached exchange an expulsion does.

**Tests.** `post_scope_test.c` and `community_test.c` pin the canonical forms,
literal for literal with `test_post_scope.py` and `test_community_codec.py`; 23
conformance scenarios (`community-*`, `post-label-*`, `post-digest-label-*`,
`post-digest-offers-a-stored-label`, `cosign-ask-content-policy-delivered`,
`cosign-ask-office-conferral-delivered`) cover the verbs on both runtimes;
`../test/cohort/community_policy_cohort.sh` runs it live.

**Limits, stated.** A members-only posting rule is not here: it needs an author
to prove that its node is a member, which nothing yet builds. The label store is
in memory, like the post store.


## Compacts between communities (Phase 5, Ethne D39/D40)

Communities enter relations with each other through kith-covenant compacts.
This library carries every step of that and judges none of it. KC's archive,
its rules and every signature are checked in the app (Agora's cdylib,
`native/ethne_ffi/src/kc.rs`). The design is in `../doc/agora/federation.md`.

**Co-signing.** The courier's allowlist gains:

| `record` | `op` | What travels |
|---|---|---|
| `compact` | `join`, `admit`, `sponsor`, `refuse`, `anathema`, `lift` | the roll's compact act (D40), for the deciders' signatures |
| `rite` | `movement`, `affirm` | the polity's own rite in its charter log |
| `commitment` | `amend` | a charter commitment (a founding needs one in force) |
| `kc_record` | `deliver` | one KC record to a member community's governance node or an examiner's node; the answer is a receipt, never a signature over the record |
| `kc_attest` | `attest`, `recite` | a rite attestation for a witness; the recitation for the Inductor, who is never the envoy |
| `kc_seal` | `sign`, `sealed` | a seal's CBOR manifest, which each replica rebuilds and signs; then the manifest with every signature |
| `kc_conduct` | `sign` | a conduct record (anathema, lift) for a co-reporter |

The bytes are opaque here and bounded like every co-sign ask
(`AT_COSIGN_BYTES_MAX`, 6144 hex characters).

**The compact view** rides the policy carrier under the key `"<did>#compact"`:
the community's root-signed account of the compacts it sits in and how each
community it knows stands with it. The core carries it as it carries a
policy, opaque, and the newer seq replaces the older. Each followed community
can now use two slots, so `COMMUNITIES_MAX` is 64 in C and Python.

**Tests.** `cosign_test.c` asserts every pair above and its near-misses. Nine
conformance scenarios (`cosign-ask-{compact-act,rite,commitment,kc-record,
kc-seal,kc-attest,kc-recite,kc-conduct}-delivered` and
`community-compact-view-carried-and-survives-reload`) cover them on both
runtimes. `../test/cohort/compact_cohort.sh` runs it live.

## File sharing in a DM thread (2026-10)

A file goes from one person to one device of another after that person
accepts; the receiver pulls it in chunks and the core, not the app, reads and
writes the bytes. The design is `../doc/agora/design.md` §4.3.

**C.** `c/social/file_xfer.{h,c}` is the pure half: bounds, the four wire
forms, name sanitizing, the chunk bitmap, BLAKE2b of a file, and the
persisted store (`etc/at/file_xfer.cfg.json`). `c/social/id_file_xfer.{h,c}`
is the state machine on the identity process, behind its own leaf lock, and
id_social.c reaches it through five calls from its register, run_start,
periodic-resync, roster-replay and reset hooks. Wire verbs: `peer_file_offer`,
`peer_file_ctl`, `peer_file_req`, `peer_file_chunk`; app verbs:
`app_file_offer`, `app_file_accept`, `app_file_decline`, `app_file_cancel`;
event: `PEER_FILE_OBSERVED` → `AT_APP_EVENT_FILE` (18), a state type, so the
roster pull replays it.

**Python.** `_python/file_xfer.py` is the twin. Its app-side functions
(`offer_file`, `accept_file`, ...) are what the conformance adapter calls, as
for the other app-driven sends; it emits no app events.

**Tests.** `file_xfer_test.c` (names, wire forms, bitmap, store) and
`file_xfer_flow_test.c` (each side through the handlers: serve, pull and place,
resume from the bitmap after a restart, wrong-peer chunks, a corrupt file, a
blocked sender, the size cap, a peer driving our app verb). `test_file_xfer.py`
holds the same name table as the C test. Six conformance scenarios (`file-*`)
run on both runtimes. Scenarios name file CONTENT (`content`, `repeat`) and
the adapters compute sizes, hashes and base64 the way the nodes do. The C
adapter gives a scenario a temp `AUTONOMOUS_TRUST_ROOT` from its first file
step, because the harness root is not writable. Resume is not a conformance
case, because it waits on a 3 s request timeout that the harness has no clock
for.
