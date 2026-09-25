# AutonomousTrust Social

The social feature, as a distribution separate from the core
(FEATURE_SPLIT_PLAN Phase 5): opt-in position and private proximity, signed
profiles, explicit connections, direct messages, feed posts and reactions,
first-person reports and local blocks, business ads and posts, and detached
co-signing.

| Module | What |
|---|---|
| `autonomous_trust.social.protocol` | `SocialProtocol`: the 17 verbs (strings unchanged from their `IdentityProtocol` days) and the three store-and-forward verbs |
| `autonomous_trust.social.extension` | the `Extension`: registers the verbs on the identity process and follows it through `IdentityHooks` |
| `autonomous_trust.social.handlers` | the handlers and senders, module functions over the identity process |
| `autonomous_trust.social.state` | `SocialState` (`proc.social`), seeded from `$AT_OWN_GEOHASH` / `$AT_OWN_EXACT` / `$AT_OWN_PROFILE` |
| `autonomous_trust.social.codec` | canonical forms, signatures and bounds |
| `autonomous_trust.social.proximity` | multi-resolution grid tags for distance bands |
| `autonomous_trust.social.social_store` | the durable `social.cfg.json` |

Present means on: a node with this package has social, and one without it
carries none of it. The core names no feature. It finds this package through
the `autonomous_trust.extensions` entry point when installed, or through
`autonomous_trust/social/_at_extension.py` in a source tree (put
this directory on `PYTHONPATH` beside AT's `src/autonomous-trust`).
A node whose environment sets `$AT_OWN_*` without this package refuses to
start rather than silently publish nothing.

The C twin is `libat_social` under `../c/social/`; see `../README.md`.

## Tests

```
./run-tests.sh
```
