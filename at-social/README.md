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
  c/social/            libat_social: sources, CMakeLists.txt, test/ (17 ctest)
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
- its 34 identity verbs, 16 from the wire and 18 from the app, through
  `processes/extension.h` on "identity" only;
- its 12 message types and 18 `AT_APP_*` verbs (`social/social_msg_types.h`);
- the app-event decoders behind `at_agora.h`.

The app-facing API kept its names: `at_agora.h`, `at_app_events_*`,
`at_agora_event_*` and event kinds 4–15. The Agora shim and the Dart bindings
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
`$AT_OWN_GEOHASH` or `$AT_OWN_PROFILE` is set and non-empty and no identity
extension named "social" is registered (`identity_ext_check_env`). A node told
to publish its position that silently published nothing would look healthy
while failing its operator.

**Python.** The distribution is `python/`
(`autonomous_trust.social`, `_python` beside an empty `_native`, redirector
prefix `autonomous_trust.social.`), found by its entry point or its
`_at_extension.py` marker. The modules are:

- `protocol` holds `SocialProtocol`, the 17 verbs moved off `IdentityProtocol`
  with their strings unchanged;
- `extension` is the `Extension`;
- `handlers` holds the handlers and senders, as module functions `f(proc, …)`;
- `state` holds `SocialState`, on `proc.social`;
- `codec`, `proximity` and `social_store` are the canonical forms, grid tags
  and durable store.

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
