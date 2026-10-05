# Agora: design

*The design Agora is built on. Working codename **Agora** (Gk. ἀγορά, the
gathering-place that is at once assembly and marketplace — people and businesses
in one square). This was the body of the build plan, `SOCIAL_APP_PLAN.md`, kept
when the plan was retired on 2026-10-01 with every phase built.*

Paths in backticks are relative to the tier they name: `doc/architecture/…` and
`src/…` are AutonomousTrust's (`lib/muudd/lib/autonomous_trust/`); `../ethne/doc/…`
is Ethne's (`lib/muudd/lib/ethne/doc/`).

---

## 1. What we are building, and why the stack already fits

A Facebook-like application — profiles, connections, a feed, pages for
businesses, messaging, discovery — with **no central server, no central
identity provider, and no central policy authority**. Instead of a company
owning the graph, each participant runs a node that owns its own identity and
decides for itself whom it trusts and what it shares.

The reason this is tractable rather than a research project from zero is that the
two tiers below already supply most of what a social network needs and normally
has to reinvent badly:

| Social-network need | Already provided by | Where |
|---|---|---|
| Self-owned identity, no central IdP | AT identity (Ed25519/X25519 + UUID, self-generated) | `doc/architecture/identity-protocol.md` |
| Sybil-resistant "who gets in" | AT admission-by-vote on the encrypted channel | same |
| Human-readable names without a registry | Zooko-triangle nickname (global, self-asserted) / petname (local) | same |
| "Friends" as a live, revocable relationship | AT bilateral reputation, re-evaluated continuously | `doc/architecture/reputation.md` |
| Post audiences (public / acquaintance / friend / close) | AT four-level trust→access gradient | `README.md`, `doc/architecture/trust-tiers.md` |
| "Is this a real person? who answers for this account?" | AT operator-attended signals (`operator_bound`, `operator_attested_at`, guardian binding) | `doc/architecture/operator-attended.md` |
| Encrypted DMs and group chat | AT encrypted P2P and group channels | `doc/architecture/identity-protocol.md` |
| **Where are you** (local discovery, proximity) | AT peer **position** service (geopy/UTM distance) | `src/autonomous-trust-services/autonomous_trust/services/peer/position.py` |
| Content streams between peers | AT `services.data` server/client pattern | `doc/api.md` |
| **A business as a first-class, persistent entity** | **Ethne polity** (charter, roll, offices, envoy, guardianship) | `../ethne/doc/charter.md` |

The single most important design decision falls straight out of that table and
answers the user's "find people **and** businesses **separately**" requirement
directly:

> **A person is an AutonomousTrust node. A business is an Ethne polity.**

They are different *kinds* of entity in the substrate, not two flavors of one
"account" table with a boolean. That is what makes them separable everywhere —
in discovery, in the feed, in trust semantics, and in accountability — instead
of only in the UI.

---

## 2. The two entity kinds

### 2.1 A person = an operator-attended AT node

A user's phone or laptop runs an `AutonomousTrust` subclass. Their profile is a
**capability** the node advertises (`agora.profile`). The person's identity is
the node identity: they self-generate keys, they are admitted to their local
cohort by vote, and they are known globally by a self-chosen **nickname** and
locally by whatever **petname** each of their contacts assigns.

Crucially, a person node is *operator-attended*:

- `operator_bound` — there is a human guardian behind this account at all. A
  bot/spam account that cannot produce an operator credential chaining to the
  operator anchor is recorded as **not** operator-bound, and peers can down-rank
  or refuse it. This is our organic anti-bot lever, and it is behavioral, not a
  CAPTCHA.
- `operator_attested_at` — is a human at the console *right now* (nonce-fresh,
  pull-based). Drives "active now" / presence honestly, without a keepalive that
  lies.
- guardian public-key binding — names *which* human, so a person account is
  answerable, which we reuse when a person is also a member of a business
  polity (§2.2).

Opting out of a named guardian is free (per AT), so pseudonymous people remain
first-class; they simply carry weaker signals and earn tier the slow way.

### 2.2 A business = an Ethne polity

A business is not a node. It is a **community that acts with one voice**, which
is precisely what Ethne exists to produce out of a set of cooperating AT nodes
(`../ethne/doc/concept.md`). This gives a business, for free, exactly the
properties a "Facebook Page" fakes with a central database:

- **A charter and a roll** (`../ethne/doc/charter.md`): who is in the business,
  ratified by signature, append-only, no registry consulted. Employees join by
  majority-of-roll + their own consent; they leave self-signed; expulsion takes
  majority-plus-one. Staff turnover is a first-class, auditable operation.
- **Offices**: `envoy_authorizer`, `charter_keeper`, `convener`, `inductor`,
  plus the catch-all. The **envoy** is the one who may speak *as the business*.
  A post "from the business" is an envoy-authorized, polity-signed artifact —
  not a person posting from a shared login.
- **One voice, persistent across turnover**: the polity persists though its
  members change, so the business page survives the founder leaving. This is the
  headline reason Ethne is *necessary* here rather than optional.
- **Guardianship / answerability** (`../ethne/doc/guardianship.md`): every
  derived (machine) member answers to a named human, co-signed. "Who is
  responsible for this business account" has a structural answer.

The business's public profile ("page") is an **uplift-style border artifact**
(`../ethne/doc/uplift.md`): a signed, serialized payload the polity emits and any
consumer appends and displays. A person's app verifies the envoy signature
against the charter's self-resolving identities — no blue checkmark authority
required.

**Why this cleanly separates the two searches.** "Find people near me" queries
the person-capability namespace (`agora.profile` on operator-bound nodes). "Find
businesses near me" queries the business namespace (polity border artifacts /
`agora.business` envoy endpoints). They are different objects with different
verification paths and different trust semantics, so the separation is real all
the way down, and either can be filtered, ranked, or hidden independently.

---

## 3. Connections, and the proximity → Dunbar mechanism

This is the part the user specifically asked for: **more local ⇒ stronger
connection, so that the active network self-limits near true Dunbar numbers.**

### 3.1 A connection is a trust edge, not a row

"Friending" is not writing a row to a friends table; it is the AT admission /
reputation relationship. A connection request is proposed and accepted much as a
peer is admitted, and thereafter the edge is a **live, bilateral reputation
value** that decays without interaction and is re-evaluated continuously
(`doc/architecture/reputation.md`). A relationship you stop tending fades on its
own — which is exactly the real-world behavior Facebook's permanent friend list
refuses to model.

### 3.2 Tie strength kernel

Each directed edge carries a **strength** `S ∈ [0,1]` computed locally from three
factors:

```
S = w_t · tier(peer)            # AT trust tier / reputation, 0..1 normalized
  + w_i · recency(interaction)  # decays since last real interaction
  + w_p · p(d)                  # proximity factor (below)
```

The proximity factor uses the existing position service's distance `d` (geopy /
UTM, `services/peer/position.py`):

```
p(d) = exp( - d / d0 )
```

with `d0` a *locality scale* (a neighborhood, order ~2 km, per-user tunable).
Co-located people get `p ≈ 1`; someone across the country gets `p ≈ 0`. Local
ties are therefore *born strong*, and distance is the dominant discount.

### 3.3 The attention budget — how Dunbar emerges instead of being hard-capped

We do **not** hard-cap friends at 150. Instead each node has a finite **attention
budget** `B`, and maintaining a *strong* tie costs budget in proportion to how
much work distance implies:

```
cost(edge) = base_cost · (1 / p(d)) · (1 / recency)
```

- A local, frequently-touched tie costs ≈ `base_cost` → you can afford ~`B/base_cost`
  of them, and `B` is tuned so that number lands in Dunbar's **~150** (the
  "active network").
- A distant tie costs multiples of that, so you can hold only a handful of them —
  which is exactly how real long-distance friendships work: rare and effortful.
- Weak ties (acquaintance, recognition) are cheap and **not** proximity-gated, so
  the outer Dunbar layers (~500 acquaintances, ~1500 recognized) can be global.

The result is emergent, not decreed: the graph self-limits near Dunbar because
holding many strong ties is only affordable when they are local. This mirrors
AT's own philosophy — *ratify emergence, don't replace it* — rather than
imposing an arbitrary count.

### 3.4 Nested Dunbar circles = trust tiers

Dunbar's layered structure (5 / 15 / 50 / 150 / 500 / 1500) maps onto AT trust
tiers and post audiences directly, so we reuse existing machinery:

| Circle | ~size | AT tier band | Post audience | Access gradient (from AT) |
|---|---|---|---|---|
| Support clique | 5 | highest | "close" | share data freely |
| Sympathy group | 15 | high | "friends" | data |
| Band | 50 | mid | — | compute, guarded data |
| Active network (Dunbar) | 150 | admitted+ | "acquaintances" | accept traffic |
| Acquaintance | 500 | low/one-off | "public" | bandwidth only |
| Recognition | 1500 | seen, not admitted | discovery only | refuse / minimal |

The four-tier access gradient AT already meters (`refuse traffic → refuse compute
→ withhold data → share data`) *is* the audience selector for a post. We are not
inventing an audience system; we are labeling the one that exists.

---

## 4. The application surface (mapping Facebook features to substrate)

| Feature | How it is built | Substrate reused |
|---|---|---|
| **Profile** | `agora.profile` capability; fields signed by the node | AT capabilities (`doc/api.md`) |
| **Business page** | Ethne polity border artifact, envoy-signed | Ethne uplift/charter |
| **Friend / connect** | Connection request → admission-style accept → reputation edge | AT identity + reputation |
| **News feed** | Content items are signed, content-addressed; distributed by gossip over the group channel; each reader **merges + ranks locally** by `S × recency` | AT group channel; `services.data` pattern |
| **Post audience** | Required tier on the content capability (public/acq/friend/close) | AT `required_tier` gating |
| **Messaging (DM)** | Encrypted peer-to-peer channel | AT P2P channel |
| **Group chat / groups** | An AT group, or a lightweight ephemeral polity for durable groups | AT groups / Ethne |
| **People You May Know** | Friend-of-friend over the trust graph, **ranked by proximity** and filtered to operator-bound nodes | reputation graph + position |
| **Find businesses** | Separate query over the business namespace, ranked by proximity | Ethne artifacts + position |
| **Presence ("active now")** | `operator_attested_at` nonce-fresh pull | AT operator-attended |
| **Events / local happenings** | Business or person polity emits a signed event artifact; discovery is proximity-first | Ethne + position |
| **Moderation / block / report** | Block = refuse traffic (tier floor). Report = negative reputation transaction. Ban from a business = polity **expulsion** (majority+1) | AT reputation + Ethne roll |
| **Account recovery / device add** | Each device is its own node, certified by the person's operator key (out of band, `src/autonomous-trust-first-contact/tools/device_cert.py`); devices with one operator **pair** and keep one address book; a verified contact files a new device under the same person; a passphrase-sealed **backup** restores the book onto a new device | AT first contact, Phase 4 (FIRST_CONTACT_PLAN) |

### 4.1 Discovery, concretely

Three range bands, degrading gracefully:

1. **Truly local (same LAN / venue):** AT's open broadcast/multicast channel
   already discovers peers with zero infrastructure — the coffee-shop / campus /
   neighborhood-mesh case. This is where the app is strongest and most novel.
2. **Neighborhood / city:** a proximity hub. The community's roll seats it as
   its RendezvousOperator for an area, and its roster rides inside the
   community's policy (Ethne D36/D38). People listed in the area find each other
   there, and only if both chose to be findable. A hub is also an AT relay, so
   people on networks with no route between them reach each other through it.
   No global index; hubs are local and replaceable.
3. **Beyond:** friend-of-friend reach and explicit nickname lookup only. There is
   deliberately no global "search everyone" — that is a feature, not a gap, and
   it is what keeps the network human-scaled.

### 4.2 Location privacy (non-negotiable)

Location is the most sensitive datum here, so:

- Peers exchange **coarse distance buckets / geohash prefixes**, not exact
  coordinates. The position service computes distance; we expose the *bucket*,
  not the point.
- Proximity is a **proof of nearness**, not a location disclosure: "we are within
  2 km" without either side learning the other's coordinates. The
  private-proximity check yields only a near/mid/far band, and it was
  live-verified in the two-node GUI cohort before any pilot.
- Sharing exact position is opt-in, per-audience, and tier-gated like any other
  data.

---

## 5. Architecture at a glance

```
┌──────────────────────────────────────────────────────────────┐
│  Agora app (Flutter UI, Dart)                                  │
│   • models: tie strength + attention budget (§3), feed, book   │
│   • node: peer stream, community policy, compact engine        │
├──────────────────────────┬───────────────────────────────────┤
│  libagora_shim (dart:ffi)│  libethne_agora (dart:ffi, Rust)   │
│   app-events client      │   Ethne charter logs, policies,    │
│                          │   co-signing; the KC border (kc.rs)│
├──────────────────────────┴───────────────────────────────────┤
│  agorad — the AT node in its own process                       │
│   AutonomousTrust C core: identity · admission · reputation ·  │
│   trust tiers · operator-attended · P2P/group · position       │
│   + at-social (Agora's extension): posts, DMs, businesses,     │
│     communities, hubs, co-sign courier, compact views          │
└──────────────────────────────────────────────────────────────┘
                     physical mesh / IP transport
```

The first draft of this plan had the UI embed the **Python** node over
`q_in`/`q_out`. §5.1 records why that was superseded.

**New code lives in a new package**, not in AT or Ethne core. **Decided home:**
`lib/muudd/apps/agora/` (its own submodule,
`git@github.com:sean-m-brennan/agora.git`). AT and Ethne stay clean; Agora
depends on them, never the reverse — consistent with Ethne's own decoupling
discipline.

## 5.1 Runtime & client architecture (decided)

The original plan left the client platform open (the plan's open question on the client platform) and assumed the UI would
embed the **Python** node over `q_in`/`q_out`. That is **superseded**. Agora
drives the **AutonomousTrust C core directly — no Python layer** — behind a
**Flutter** UI, and ships **Linux + macOS first**, with Windows and iOS/Android
as follow-on ports. The reasoning, and the constraints this commits us to, are
recorded here because they are load-bearing for everything below.

### Why C-direct + Flutter

- **Why the C core, not Python.** The eventual target set is five platforms
  (Linux, macOS, Windows, iOS, Android). Shipping a CPython runtime — and AT's
  default `multiproc=True` process-per-subsystem model — onto iOS/Android is
  hostile (App Store forbids spawning persistent daemons; mobile OSes forbid
  arbitrary child processes). The C core sidesteps the Python packaging problem,
  at the cost of a cross-platform **C** port burden (below).
- **Why Flutter.** With no Python in the loop, the UI links the C library
  directly. The realistic cross-platform-native choices are **Qt (C++)** or
  **Flutter (Dart via `dart:ffi`)**. Flutter wins here on two axes that matter
  for this project: a **permissive BSD license** (Qt is LGPL/commercial, and its
  static-link requirement bites on mobile distribution) and the **strongest
  iOS/Android story**. The costs we accept: an **FFI seam** to maintain and
  **non-native rendering** (Material/Cupertino, not per-OS widgets — Qt Quick is
  the same).
- **Why Linux + macOS first.** Linux is AT's only proven C target; macOS is
  POSIX and likely close. Windows and mobile need AT-*core* changes we are not
  making in the first increment.

### The C embed surface (what Agora calls)

From `../autonomous_trust/src/c` (`autonomous_trust.h`, `node.h`, `app_events.h`):

- **Lifecycle:** `at_node_init / at_node_start / at_node_run / at_node_shutdown`.
  `at_node_start` **forks** a daemon child. Daemon entry is
  `run_autonomous_trust(q_in, q_out, capabilities, cap_len, log_level,
  log_file)`; a node advertises `agora.profile` by passing a serialized
  **capabilities** buffer.
- **Read model:** `at_app_events_open() / at_app_events_poll() /
  at_app_events_request_roster() / at_app_events_close()` — a **non-blocking
  poll**, a natural fit for a UI render loop. `at_app_events_open()` is pure
  AF_UNIX socket-client I/O (no fork), which is what Agora uses.

**Embedding choice (avoids fork inside the GUI):** Agora does **not** call the
forking `at_node_start` from inside the Flutter process. It launches a small
standalone **`agorad`** daemon (which calls `run_autonomous_trust`) as a **child
process**, and the Flutter app connects to it purely as an app-events client via
FFI. This matches the "foreign consumer" design app_events.h documents (the
Ethne adapter binds it the same way).

### The C event surface, as Phase 1 built it

Later phases added more kinds (business pages and posts, co-sign asks and
signatures, community policies and labels, hub listings, the address book);
`native/at_agora_shim.h` is the current list. In Phase 1, `at_app_event_kind_t`
carried **nine kinds**, and the "profile + proximity"
gap the earlier drafts deferred to AT-core is **closed** — Increments 1–3 (read
model), Increment 5 (connections), Increment 6 (DMs), and Increment 7 (feed) are
landed, with the AT-core and Agora test suites all green:

- `AT_APP_EVENT_PEER_OBSERVED` / `AT_APP_EVENT_PEER_REPUTATION` — the original
  surface. `at_app_peer_t`: `peer_uuid`, `signing_pubkey`, `rank`, and the
  **operator-attended signals** `operator_bound`, `operator_attested_at`,
  `operator_pubkey`; `at_app_reputation_t`: `score`, `rated`.
- `AT_APP_EVENT_PEER_RTT` (Increment 1) — a round-trip-latency proximity
  *proxy* in milliseconds. Not a geographic distance, and **not** opt-in gated
  (it is a measured network property, exempt from the location opt-in).
- `AT_APP_EVENT_PEER_POSITION` (Increment 2) — a peer's **opt-in** coarse
  position as an `at_app_position_t.geohash` bucket (~5 chars, ~5 km
  "neighborhood"; empty string = the peer shared none, which is the default).
  The consumer decodes it against *its own* opted-in bucket to compute distance,
  so §4.2's "coarse buckets, never coordinates" privacy floor is enforced in the
  substrate rather than only in the UI. Set via `at_app_events_set_position()`.
- `AT_APP_EVENT_PEER_PROFILE` (Increment 3) — a peer's **opt-in, signed**
  `agora.profile` as compact field JSON (`at_app_profile_t.profile_json`;
  fields `{display_name, handle, bio, avatar_ref, links}`; empty = shared none).
  The identity process verifies the signature; a bad-signature or replayed
  profile is rejected (covered by the `profile-*` conformance scenarios). Set
  via `at_app_events_set_profile()`.
- `AT_APP_EVENT_CONNECTION_REQUEST` / `AT_APP_EVENT_CONNECTION_STATE`
  (Increment 5) — the explicit, revocable bilateral **connection** edge
  (`at_app_connection_t.state`: none/pending_out/pending_in/connected/declined),
  authored from the app via `at_app_events_connect_request()` /
  `at_app_events_connect_respond()` (the first app→AT *authoring* verbs beyond
  set-position/profile). The acceptance carries an Ed25519 detached signature
  over `requester||accepter||decision||seq`, freshness-guarded and
  signature-verified on receipt (`connection-*` conformance scenarios). This edge
  is SEPARATE from reputation and is what the tie-strength kernel reads for a
  tended tie.
- `AT_APP_EVENT_DM` (Increment 6) — a directed, **encrypted** direct message
  (`at_app_dm_t{peer_uuid, seq, ts, text}`), authored via
  `at_app_events_send_dm()`. It rides AT's P2P unicast (`crypto_box`, which
  authenticates the sender — no signature), is freshness-guarded against replay,
  and is a **live stream**: no gossip and no roster replay (the app echoes its own
  outgoing messages locally).
- `AT_APP_EVENT_POST` (Increment 7) — a **signed feed post**
  (`at_app_post_t{author_uuid, post_id, seq, ts, required_tier, body}`), authored
  via `at_app_events_publish_post()`. It rides a real **encrypted group multicast**
  (`RECIPIENT_GROUP` + `group_encrypt` on `NET_CHAN_GROUP`, previously dead code)
  and is **gossip-forwarded** a bounded number of hops (active network + one hop,
  the plan's feed-distribution question). Authorship is a **detached Ed25519 signature** over the canonical
  `author||seq||ts||required_tier||body` (not the wire envelope, since a post is
  relayed by peers other than its author); `post_id` is the **blake2b content
  address**. Inbound posts are **signature-verified**, **tier-gated** (dropped
  unless this node's view of the author's tier meets `required_tier`), and
  **content-id-deduped** in a new app-content store before emit. A live stream —
  the app echoes its own outgoing posts locally and merges + ranks the feed by
  S × recency (the tie-strength kernel). DMs are allowed between any admitted peers; the
  tier/audience gate is for the feed, not DMs.

The headline "people near me *with distance*, and their profile" (§4.1, §3.2) is
therefore now readable from app code directly over the C event surface: distance
derives from opt-in geohash buckets (privacy-preserving), with RTT as a
non-geographic fallback proximity signal. The proximity/Dunbar mechanism (§3)
can now be built on real peer data rather than waiting on an AT-core extension.

### Process / IPC model, and the deferred-platform constraints

(The ports are not yet done.)

- **Model:** fork + **AF_UNIX `SOCK_DGRAM`** IPC bound to a `sun_path`
  (`utilities/message.c`). Fine on **Linux/macOS**.
- **Windows (deferred).** MinGW helps the **compiler only** — it emits native PE
  and supplies winpthreads, and it is in fact the *right* Windows compiler here
  because `third_party/ryu` uses `__uint128_t` (**no MSVC**). But MinGW provides
  **neither `fork()` nor AF_UNIX `SOCK_DGRAM`** (Windows AF_UNIX is stream-only).
  The real enabler is building the core with **`FORK=0`** (run in-process on a
  thread) plus a **portable IPC transport** (UDP loopback). That same change is
  what iOS/Android need, so it is one piece of AT-core work that unlocks three
  platforms — but `FORK=0` is documented as "future use" and is **unproven**.
- **iOS/Android (deferred).** No forked daemon (store/sandbox limits) → `FORK=0`
  in-process. Some `autonomous-trust-services` (video: opencv/mediapipe) will not
  build for mobile, but Phase 0 needs only core + the position service.

### Build facts

CMake ≥ 3.23, C11/C++17, `-Werror`. `autonomous_trust` builds **SHARED**
(`libautonomous_trust.{so,dylib}`) plus a static variant. **`AT_NET_DTN` and
`AT_ZTA` are OFF by default**, so the heavy `third_party/` DTN stack (ION-DTN,
uD3TN) is **not** compiled — do not enable them. Per-platform C deps to provide:
**libsodium, libjansson, libuuid, protobuf + protobuf-c, OpenSSL**. There is **no
macOS/Darwin awareness in the CMake yet** — Linux is the only proven target, so
budget for `-Werror`/POSIX build fixes on macOS (syslog `/dev/log`,
epoll↔kqueue, abstract-socket differences).

---

## 6. What was built, phase by phase

| Phase | What | Evidence |
|---|---|---|
| 0 | Spike: the AT C core driven from Flutter through `agorad` and `libagora_shim` | `test/cohort/two_node_cohort.sh` |
| 1 | Persons: profiles, local discovery, connections, DMs, the feed | conformance (`profile-*`, `connection-*`, the post and DM scenarios) and the Dart suite |
| 2 | Dunbar mechanics and privacy: the attention budget, nested circles, coarse buckets, private proximity, presence | [`dunbar-self-limit.md`](dunbar-self-limit.md); the pilot half is still open |
| 3 | Businesses as Ethne polities: pages, posts, staff co-signing over the wire | `business_cohort.sh`, `business_post_cohort.sh`, `staff_cohort.sh` |
| 4 | Scale, safety, resilience: moderation, DDIL (store-and-forward, re-proposal), per-community policy (D37), proximity hubs (D36/D38), multi-device | `moderation_cohort.sh`, `partition_cohort.sh`, `community_policy_cohort.sh`, `hub_cohort.sh`, `device_cohort.sh`; [`multi-device.md`](multi-device.md) |
| 5 | Federation of communities through kith-covenant compacts (D39/D40) | `compact_cohort.sh`; [`federation.md`](federation.md) |

The cohorts are described in [`test/cohort/README.md`](../../test/cohort/README.md).

---

## 7. Why this is worth doing on this stack specifically

Every decentralized-social attempt (Diaspora, Mastodon, Nostr, Scuttlebutt,
Bluesky) re-solves identity, Sybil resistance, moderation, and trust from
scratch, and most punt on the hardest one — *why should I trust this account?* —
back to either a central index or nothing. This stack already answers it:
identity is self-owned, admission is Sybil-resistant by vote, trust is a live
earned value, accountability lands on a named human, and communities are
first-class persistent entities. **Agora is mostly the act of exposing what AT
and Ethne already do as a social UI, plus one genuinely new mechanism — the
proximity-weighted attention budget that makes Dunbar emerge instead of being
decreed.** That one mechanism is the research contribution; the rest is
integration.

---

*Related tiers: [AutonomousTrust](../../../../lib/autonomous_trust/README.md) (persons, trust) ·
[Ethne](../../../../lib/ethne/README.md) (businesses, community) ·
[kith-covenant](../../../../lib/kith-covenant/README.md) (community-to-community).*
