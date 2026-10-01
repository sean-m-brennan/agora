# Live cohort tests

These scripts run **real `agorad` nodes** against each other on a virtual L2
segment and drive them through the real app-event queues, the way the Flutter
app does. They check what unit tests and conformance cannot: a single-process
conformance run asserts stored state, but not what crosses the wire, what
reaches another node's app queue, or how two nodes disagree about the same
broadcast.

Each script's header comment is the full account of what it proves and why.
This file is the index.

## Before you run one

- **Build first.** Every script runs the binaries `./build.sh` produced
  (`native/build/agorad`, `libagora_shim.so`, `at_core/libautonomous_trust.so`,
  the extension libraries, and, for the Ethne scripts, `libethne_agora.so`).
  Nothing is rebuilt inside a namespace or a container.
- **Run on a host, not in a sandbox.** Each node needs its own network stack,
  because AT's open discovery is UDP broadcast on one fixed port (27787). That
  needs either root with a kernel that permits `CLONE_NEWNET` (`netns`
  backend) or a usable docker daemon (`docker` backend). Most containers and
  CI runners allow neither. `drive_ethne_half.sh` is the exception: it needs
  no network at all.
- **Keep your PATH under sudo.** Plain `sudo` resets PATH through
  `secure_path`, and the scripts that need `dart` then die in preflight. Use
  `sudo -E env "PATH=$PATH" ./test/cohort/<script>.sh`.
- **Run from anywhere.** The agora directory is found relative to the script;
  `AGORA_DIR` overrides it.

Exit status is 0 on PASS and non-zero on the first failed phase, except for
`drive_ethne_half.sh`, which counts failures (see below).

## Running them all

```
./test/cohort/run_all.sh                        # every cohort, in a fixed order
./test/cohort/run_all.sh hub moderation         # only these
./test/cohort/run_all.sh --skip partition,staff
./test/cohort/run_all.sh --fail-fast            # stop at the first failure
./test/cohort/run_all.sh --list                 # the run order
```

Run it as yourself. It re-runs itself under `sudo -E env "PATH=$PATH"` and adds
`/usr/sbin` and `/sbin` to PATH. It runs every cohort even when one fails,
prints a PASS/FAIL table, and exits with the number that failed. Each
script's output is in `.coh/run-all-<pid>/<name>.log`. Env knobs such as `WAIT`
or `KEEP` pass through to every script. A new `*_cohort.sh` is picked up
automatically. `two_node_gui.sh` is left out because it needs a display and
asserts nothing. Build first: the runner only checks that `native/build/agorad`
exists.

## The tests

| Script | Nodes | Needs | What it proves |
|---|---|---|---|
| `two_node_cohort.sh` | 2 | root | Phase 0 exit: discovery, presence, RTT, and opt-in coarse position (with the opted-out node's silence as the privacy control) |
| `two_node_gui.sh` | 2 | root, a display | The same, watched in the real Flutter UI |
| `business_cohort.sh` | 3 | dart, Ethne | P3.2: a business page travels through its customers and outlives the business |
| `business_post_cohort.sh` | 3 | dart, Ethne | P3.4: a business post reaches only nodes that know the business, and the app, not the core, rejects a tampered one |
| `drive_ethne_half.sh` | 0 | dart, Ethne | P3.3 pre-flight: every polity act of the staff cohort, minus the wire |
| `staff_cohort.sh` | 3 (5 members) | dart, Ethne | P3.3: a staff polity co-signs over the wire and no private key moves |
| `reputation_cohort.sh` | 3 | a C compiler | Paxos commits, app-driven transactions commit, checkpoints reach quorum, injected slash/resolve gates open |
| `moderation_cohort.sh` | 3 | — | P4.1: block, report and the expulsion ceiling between real nodes |
| `partition_cohort.sh` | 7 | — | Phase 4 DDIL: a 3+2 split keeps both islands working, only the majority admits or finalizes, and the heal loses no post (store-and-forward) and no transaction (re-proposal) |
| `community_policy_cohort.sh` | 4 | Ethne | Phase 4 communities: a policy the roll set is carried by members, verified on arrival, and applied only by a follower; a moderator's label reaches followers only; loosening needs more than a majority; an unseated moderator stops counting |
| `hub_cohort.sh` | 5, two segments | Ethne | Phase 4 proximity hubs: two islands with no route between them meet at their community's area hub. The roll seats the hub, its roster rides inside the policy, only people listed in the area see who is, a listing outside the hub's area is refused, a request becomes a direct peer only on the other's yes, and withdrawing takes effect at once |
| `device_cohort.sh` | 5, routed /30 links | libsodium | Phase 4 multi-device: a contact added and verified by safety number, a pairing refused across operators and accepted within one, the address book following to the new device, the contact filing it under the same person (live and in the list), a DM reaching the other device, and a lost-both restore from a 0600 backup that keeps the contact verified and links a third device |

### `two_node_cohort.sh`

Two nodes in two network namespaces on one bridged /24. Node 1 opts in to
sharing a coarse geohash; node 2 opts out. PASS needs both nodes to see the
peer and its RTT event, node 2 to see node 1's position (kind 4), and node 1 to
see **no** position for node 2. netns only.

```
sudo ./test/cohort/two_node_cohort.sh
sudo WAIT=60 KEEP=1 ./test/cohort/two_node_cohort.sh
```

### `two_node_gui.sh`

The same segment, but node 1 runs the actual Flutter app so you can watch a
seeded peer ("Bob Rivera") appear in "People near me" with presence,
reputation, RTT, profile and, once you set your own bucket, distance. Needs a
reachable X11/Wayland display (`xhost +local:` if the app cannot open it) and
`flutter build linux`. netns only. It is a visual check and asserts nothing.

```
sudo -E ./test/cohort/two_node_gui.sh
sudo -E GUI2=1 ./test/cohort/two_node_gui.sh     # both nodes as GUIs
```

### `business_cohort.sh`

`biz` publishes its page with a real Ethne bundle minted by
`tool/make_business_bundle.dart`. `ada` observes it and declares a customer
edge. `biz` is then stopped, and `bob`, who never met the business, starts.
It proves that:

1. the ad lands on the app-event queue (kind 12);
2. ada's re-advertisement carries the page to bob, with satisfaction 4, ada's
   own rating, not the business's self-marker;
3. bob's bundle is byte-identical to the minted one and still verifies with
   the business offline.

### `business_post_cohort.sh`

`biz` posts with real `{post, delegation}` bundles minted by
`tool/make_business_post.dart`. It proves that:

1. a post reaches `ada`'s queue (kind 15) and verifies from the received bytes;
2. the same post does **not** reach `bob`, who holds no page for that polity,
   and that gate opens once a customer carries the page to him;
3. the post still verifies after `biz` stops;
4. a tampered bundle is carried by both cores and refused by the app-side
   verifier.

The relay hop itself is deliberately not tested: on one L2 segment every node
hears the original multicast, so a relayed copy is deduplicated. Conformance
pins the relay (`business-post-relay-bound`,
`business-post-hops-outside-the-signature`).

### `drive_ethne_half.sh`

This is `staff_cohort.sh` without the wire. Founding, seasoning, the
five-movement rite, pend/describe/sign/assemble, expulsion at majority+1,
departure, the office lapse and the member roll are all archive operations,
and this script runs them in about thirty seconds with no root, no network and
no daemons. It stands in for the co-signature exchange by handing each node the
bytes the wire would carry. Run it before a host run of `staff_cohort.sh`.

Every readout is paired with `verify()`, because `affirmationState` folds over
what the log *claims* and will read green over a log that does not verify.

Unlike the others, it does not stop at the first failure: **its exit status is
the number of failed assertions.**

```
./test/cohort/drive_ethne_half.sh
```

### `staff_cohort.sh`

A five-member staff polity (`keeper`, `ada` the envoy, `bob`, `cal`, `dee`)
carried by three nodes. `cal` has no node: he is the expulsion's target and is
asked nothing. Five members is the smallest polity where majority+1 for an
expulsion is exactly reachable from the eligible deciders. It proves that:

1. a co-signature ask lands on a peer's app queue (kind 13);
2. no private key moves in either direction; what returns is a detached
   signature and a DID;
3. no description crosses, and a signer refuses when the recomputed cid does
   not match what the asker sent;
4. the target of an expulsion refuses to sign it;
5. the member roll re-verifies with every node stopped.

Only the co-signature exchange is a network act; the rest is local to the log
holder.

### `reputation_cohort.sh`

Three nodes (`alice`, `bob`, `carol`), because a majority quorum of two is not
a quorum. It exists because the IPC hop dropped `verified`, which left every
reputation gate dead in live operation. It proves, in phases:

1. startup and discovery;
2. a Paxos round commits (`Reputation: Transaction committed`);
3. an app-driven, bilateral transaction commits: a reaction whose task uuid
   both nodes derive independently;
4. a checkpoint goes propose → co-sign → final across nodes;
5. slashing and deep resolution, which have no production originator, are
   **injected** with `tools/at_inject.c`, compiled at run time. The injector
   hands the verb to the node's own network process, so it is really signed
   and really crosses the wire. This traffic is synthetic: it proves the gates
   open, not that a deployment would send it.

### `moderation_cohort.sh`

`ada` moderates, `bob` is the target, and `carol` is the control, so every
"ada did not receive it" has a positive twin on the same segment at the same
moment. The phases:

1. discovery, and an unbounded peer's ceiling reads -1 on the wire;
2. a baseline post reaches both;
3. a block becomes visible to ada's app (`blocked=1`);
4. bob's tier-1 and tier-0 posts reach carol and not ada;
5. unblocking restores delivery, and a re-block survives ada's daemon
   restarting;
6. an authority ceiling *gates*: capped one tier below, bob's tier-P post stops
   reaching ada while a tier-(P-1) post still does;
7. reports pair bilaterally, the daily cap refuses a second report, and the cap
   is per reporter.

Tiers are earned live, so the script speeds up the rescore sweep and raises the
neutral prior (`RESCORE_SEC`, `NEUTRAL`). Bounded by open AT issues (ISSUES.md
§2.13 quorum size, §2.15 chain forks): a report is asserted bilateral on at
least one node, never on all three. The Ethne half of an expulsion is covered
by `staff_cohort.sh` and `ethne_polity_roundtrip_test.dart`, not here.

### `partition_cohort.sh`

Seven nodes. Five founders form the group; then the split makes island A
`ada`, `amy` and `dee`, and island B `bob` and `ben`. Two more start while the
network is split: `cal` in A and `eve` in B. The split is 3+2 on purpose.
Admission and checkpoint finality both need a majority of the whole group, so
three of five can admit and finalize and two of five can do neither. The split
moves island B's host-side veths to a second bridge, so no socket inside a
namespace notices. AT has no liveness, so each island keeps its full roster and
key. The phases:

1. discovery, and the group channel is live;
2. a baseline post reaches everyone;
3. a post made in each island reaches its own side and not the other;
4. both islands keep working, and only the majority grows. A admits cal (a key
   rotation). B proposes eve and must refuse, because two of five is no
   majority. Nothing crosses the split to or from either joiner: cal learns bob
   and ben as members from A's histories and sends to them, and every such
   frame must die at the split. A reaction commits bilaterally in each island.
   A (four of six) must finalize a checkpoint and B must not;
5. after the heal, fresh posts cross, bob and ben add cal, and every node adds
   eve, which can then read the group;
6. store-and-forward: the two split posts reach the other island, exactly once
   each with the original content id, through each node's periodic digest.
   This is checked in the daemons' logs ("accepted (…, backfilled)" by content
   id), because a backfill can land before any app observer is attached;
7. both islands' split-time tasks are two-sided (both halves) in every
   through-split member's persisted chain (`etc/at/reputation-history.cfg.json`).
   The chain is the evidence because a node that receives a finished entry by
   chain adoption logs nothing about it. Re-proposals after the heal are
   printed for information.

netns only: a docker disconnect removes the interface the discovery socket is
bound to, which is a different fault from a partition.

```
sudo -E env "PATH=$PATH" ./test/cohort/partition_cohort.sh
```

### `community_policy_cohort.sh`

Four nodes on one segment. `keeper` and `mod` are members of a three-member
community polity (the third founder is a key no node holds); `keeper` holds the
root key and authors the posts, and the roll seats `mod` as Moderator. `cal`
follows the community once it has heard and verified its policy; `dee` hears it
and does not follow. The driver plays the app: it keeps the charter log, mints
every artifact through the Ethne cdylib, and computes every verdict with
`ethne_content_policy_verdict` over the bytes the node received — the same call
the Flutter app makes. The phases:

1. discovery, one node at a time, and a live group channel;
2. policy v1 (daily cap 2, "spoiler" warns, "nsfw" hides) is carried by
   `keeper`, reaches `cal` and `dee`, and verifies out of the received bytes;
   `cal` follows, `dee` does not;
3. `keeper` posts three times in the community's name, the first labelled
   "spoiler": at `cal` the first is behind a warning, the second shows, and the
   third is over the cap and hidden; `dee` receives all three with their scope
   intact and applies nothing;
4. `mod` labels the second post "nsfw": `cal` receives the label and hides the
   post, naming `mod`; `dee` receives no label at all (the follow gate);
5. lifting the cap is refused at 2 of 3 deciders and accepted at 3; the newer
   policy is carried and replaces `cal`'s, and the third post shows;
6. the roll unseats `mod`; the next policy lists no moderators, and `mod`'s
   labels reach `cal` and count for nothing.

A label backfilled after a partition, and the reader's own "apply this policy"
switch, are covered by conformance and by `test/community_policy_test.dart`.
netns only.

```
sudo -E env "PATH=$PATH" ./test/cohort/community_policy_cohort.sh
```


### `device_cohort.sh`

One human's three devices (`annphone`, `annlaptop`, `anntablet`), a contact
(`bob`) and a device of another operator (`eve`). Each node has its own /30
link to a router namespace that forwards unicast, so broadcast discovery never
joins them into one group: every crossing is the address book's doing. The
driver plays the operator too. It signs device certs with libsodium the way
`tools/device_cert.py` does, so the operator key never enters a node. PASS needs:

1. bob's link redeemed by annphone, the same safety number on both screens,
   and bob verified by typing annphone's;
2. eve refused `not_sibling` on annphone's pairing link;
3. annlaptop paired, with bob in its book (verified, provenance `sibling`);
4. bob's node filing annlaptop under Ann (`DEVICE_LINKED`), and bob's list
   naming it under the one record;
5. with annphone stopped, a DM from bob reaching annlaptop;
6. annphone's backup (0600, generated passphrase) restored on a fresh
   anntablet with both old devices gone, bob still verified (provenance
   `backup`);
7. bob's node filing anntablet under Ann too: one record, three devices.

```
sudo -E env "PATH=$PATH" ./test/cohort/device_cohort.sh
```

Knobs: `WAIT` (120), `SUBNET` (10.9.10), `LOG_LEVEL`, `KEEP=1`.

## Options

All options are environment variables.

### Common

| Variable | Default | Scripts | Meaning |
|---|---|---|---|
| `BACKEND` | `auto` | all 3-node cohorts (`partition_cohort.sh` is netns only) | `netns`, `docker`, or `auto` (netns if usable, else docker). The two-node scripts are netns only. |
| `WAIT` | per script, below | all but `drive_ethne_half` | Per-phase timeout in seconds (discovery timeout for `two_node_cohort`) |
| `KEEP` | `0` | all | `1` leaves the network and the run directory up for inspection, and logs how to tear them down |
| `SUBNET` | per script, below | all but `drive_ethne_half` | First three octets of the /24. Each script has its own subnet and bridge name. |
| `GEO` | `u4pruy` | 3-node cohorts | The shared coarse geohash bucket the nodes advertise |
| `AGORA_DIR` | the script's `../..` | all | The agora checkout to test |
| `AGORA_ETHNE_PATH` | `native/build/libethne_agora.so` | business, business_post, staff, drive_ethne_half, community_policy, hub | The Ethne cdylib |
| `DOCKER_IMAGE` | `ubuntu:26.04` | 3-node cohorts | Image for the docker backend. The host-built `agorad` is bind-mounted and its non-base libraries are staged beside it, so a stock image works. `Dockerfile.node` builds an alternative with those libraries installed. Either way, the base must match the host's Ubuntu release. |
| `AGORA_COHORT_RUN` | see below | business_post, reputation, moderation, partition, staff, community_policy, hub, device | Run directory. Set a short path (e.g. `/tmp/ag-$$`) when a deep checkout makes the node socket paths exceed 108 bytes; the preflight refuses and says so. netns only: docker can bind-mount only paths it shares with the daemon. |

### Per script

| Script | `WAIT` | `SUBNET` | Also |
|---|---|---|---|
| `two_node_cohort.sh` | 45 | `10.9.0` | `GEO1` (node 1's bucket, default `u4pruy`) |
| `two_node_gui.sh` | — | `10.9.0` | `GUI2=1` (node 2 as a second window); `GEO1`/`GEO2` (default `u4pruy`/`u4prv0`, a few km apart); `PROF1`/`PROF2` (the nodes' profile JSON) |
| `business_cohort.sh` | 60 | `10.9.1` | — |
| `staff_cohort.sh` | 120 | `10.9.2` | `STAGGER` (seconds between node starts, **default 0**; the header's "8" is stale, see the comment at the Phase 1 start); `DISCOVERY_WAIT` (discovery timeout, default `WAIT`) |
| `business_post_cohort.sh` | 90 | `10.9.3` | `GATE_WINDOW` (how long bob must stay silent, default 45) |
| `reputation_cohort.sh` | 90 | `10.9.4` | `CHECKPOINT_SEC` (the nodes' `AT_REP_CHECKPOINT_SEC`, default 20; production is 300) |
| `partition_cohort.sh` | 120 | `10.9.6` | `GATE_WINDOW` (default 20); `DIGEST_SEC` (the nodes' `AT_SOCIAL_DIGEST_SEC`, default 10; the digest rides identity's ~20 s sweep, so ~20 s is the real floor); `NEUTRAL`, `RESCORE_SEC`, `CHECKPOINT_SEC` (as moderation) |
| `community_policy_cohort.sh` | 120 | `10.9.7` | `GATE_WINDOW` (how long `dee` must see no label, default 30); `POLICY_SEC` (the nodes' `AT_SOCIAL_POLICY_SEC`, how often a follower re-carries its policy, default 10); `LOG_LEVEL` (default 2) |
| `hub_cohort.sh` | 120 | `10.9.8` + `10.9.9` (`SUBNET_A`, `SUBNET_B`) | `POLICY_SEC` (as community_policy, default 10); `LOG_LEVEL` (default 2). Bridges `agbr8` + `agbr9`; the hub has a leg on each with `ip_forward=0` |
| `moderation_cohort.sh` | 90 | `10.9.5` | `GATE_WINDOW` (how long a negative waits, default 20); `NEUTRAL` (`AT_REP_NEUTRAL`, default 0.70); `RESCORE_SEC` (`AT_REP_RESCORE_SEC`, default 5); `CHECKPOINT_SEC` (default 20) |
| `device_cohort.sh` | 120 | `10.9.10` (one /30 per node behind router netns `agdvrouter`) | `LOG_LEVEL` (default 2). Operator keys are random per run and never written to a node |

## Where the evidence goes

Each run writes its node roots, `agorad.log` files and driver logs to a run
directory:

- `business_post`, `reputation`, `moderation`, `partition`, `staff`, `hub`, `device`: `.coh/<tag>-<pid>/`
  under the agora directory (`staff` falls back to `/tmp/ag-<pid>` under netns
  when the checkout is too deep). **These are kept on failure** as well as with
  `KEEP=1`, so a failed host run can be read afterwards.
- `business_cohort.sh` and `drive_ethne_half.sh`: `.cohort/<tag>-<pid>/`,
  removed at exit unless `KEEP=1`.
- The two-node scripts: `/tmp/agora-cohort.XXXX` or `/tmp/agora-gui.XXXX`
  (short, for the socket-path limit), removed at exit unless `KEEP=1`.

## `tools/`

`tools/at_inject.c` is a **test-only** injector used by `reputation_cohort.sh`.
It hands one protocol verb to a running node's own network process, which signs
and sends it, for flows that have no production originator. It changes no
production code and adds nothing to the app-verb allowlist.

```
at_inject --root <sender root> --peer <target identity.cfg.json> \
          --verb "<protocol verb>" [--process reputation] --payload '<json>'
```

Exit codes: 0 sent, 2 bad usage, 3 could not read the peer, 4 send failed.
