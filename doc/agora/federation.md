# Communities in compact

**Claim (Agora Phase 5; [design](design.md) §6):** communities enter relations with each
other through kith-covenant (KC) compacts, over the wire, without a private key
leaving its node. A reader sees how the communities they follow stand with
every other one, and a community's own policy can act on that standing.

## The model

A community is an Ethne polity. A **compact** is KC's unit of relation between
communities. A community comes into a compact by its own sealed rite, five
signed anti-spiral claims that the others accept, a sponsor, and an examining
panel. Founding a compact needs no sponsor and no panel. KC reads each
community's **standing** out of the compact's archive: `in_compact`,
`probationary`, `denied` or `anathema`. No score crosses the boundary.

Nothing at the border is done on one member's say:

- **The roll decides every compact act** (Ethne D40). Join, Admit, Sponsor and
  Lift need a majority of the roll. Refuse and Anathematize need majority + 1.
  The act is a co-signed charter entry (`compact/<op>`). The envoy signs at the
  border only under an act in force, and the FFI checks it before it signs.
- **Ceremonies cross nodes by detached co-signing.** The bytes to sign travel
  in a co-sign ask, a signature comes back, and every key stays home.
- **Every member's verifier uses the same constants**: KC's default quorum (2)
  and its default panel minimum (3). KC lets the verifier choose these, so
  `ethne_ffi` fixes them.

## Who is where

| Node | Holds | Does |
|---|---|---|
| Governance node | the polity root key and the envoy's member key | publishes the border (identity, envoy, witness registry), seals the rite, presents claims, gives verdicts, sponsors, seats examiners, convenes seals, reports conduct, mints the compact view |
| The Inductor's device | the Inductor's member key | signs the rite's recitation (`kc_attest/recite`) |
| A witness's device | that member's key | signs its rite attestation (`kc_attest/attest`) |
| An examiner's device | that member's key, and a replica | rebuilds and signs the seals it examines (`kc_seal/sign`) |
| Any reader | nothing of the community's | verifies the compact view against the community's root key |

**The envoy is never the Inductor.** KC resolves one delegation per speaker,
and the latest one wins. A member who is first made envoy and then Reciter
stops being the envoy, and every claim and seal it signs afterwards fails with
"no authorized signer". So a community's Inductor is a member other than its
envoy, and the Compacts page offers only those. The recitation reaches the
Inductor's device as a co-sign ask.

**An examiner's node needs every community's records, not just its own.** It
rebuilds each seal it is asked to sign from its own replica. So the governance
node relays its whole replica to its seated examiners' nodes
(`ethne_kc_deliveries`: every record, then every seal as the note it travelled
as), and passes on each record that lands later.

## What travels

Every record is canonical CBOR in hex, inside a co-sign ask (at most 6144 hex
characters).

| Carrier | `record/op` | What | Size (measured) |
|---|---|---|---|
| co-sign ask | `compact/{join,admit,sponsor,refuse,anathema,lift}` | the roll's act, for the deciders' signatures | — |
| co-sign ask | `rite/{movement,affirm}`, `commitment/amend` | the polity's own rite in its charter log (a founding needs commitments in force) | — |
| co-sign ask | `kc_record/deliver` | one KC record to every member community's governance node and to the community's own examiners; a receipt over `agora-kc-receipt-v1\|<cid>` comes back, never a signature over the record | identity 828, delegation ~1010, rite ~3.6K, examiner registry ≤ 1514, sponsorship 1048, claim 892, verdict 810, conduct (2 reporters) 1760 |
| co-sign ask | `kc_attest/{attest,recite}` | a rite attestation for a witness, or the recitation for the Inductor | — |
| co-sign ask | `kc_seal/sign` | the seal's manifest (label, participants, CIDs of every rite, claim and verdict); each replica rebuilds the seal from it and signs | 1924 (2 participants), 3810 (3) |
| co-sign ask | `kc_seal/sealed` | the manifest plus every signature; each replica rebuilds and lands it | 4836 (3 participants, 4 signatures) |
| co-sign ask | `kc_conduct/sign` | a conduct record for a co-reporter | — |
| policy carrier | key `<did>#compact` | the compact view | ≤ 4096 bytes; worst case 3806 (22 standings, 4 compacts) |

The seals themselves are 18.7K hex (founding) and 40.3K (admission), so they
never travel whole. A replica rebuilds a seal with KC's own ceremony runner
(using throwaway keys), so KC still enforces its claim and acceptance rules.
Then it attaches the real signatures.

## The compact view: the trust path, stage one

Each governance node verifies its own replica in full: `verify_all`, then
`check_authority`, on a trial copy before every append. From that replica it
mints a small **compact view**, signed by the root:

- the compacts the community sits in (label, id, members);
- how every other community it knows stands with it;
- the governance node's AT uuid, so other communities know where to send asks.

The view is re-minted after every change and rides the policy carrier, where an
older seq never replaces a newer one. A reader trusts a community's view as it
trusts that community's policy. It is the community's own word, verified
against its root key.

**Stage two, recorded and not built:** readers verify the archive itself, once
AT carries payloads that size (bulk transfer).

## What a reader sees

- **Badges.** A community card, a post made in a community's name, and a
  business tile show "in compact with yours", "probationary in your compact",
  "refused by your compact" or "anathema in your compact". The reading comes
  from the views of the communities the reader follows. A denied or anathema
  reading from any of them wins over a good one.
- **Reach.** Businesses that are themselves compact members appear under "From
  your compact". The communities page lists the communities in compact with
  yours. Once one of their members carries their policy near you, you can
  follow them, which brings their hub roster with it.
- **Policy (Ethne D39).** A community's content policy can say what a post made
  in another community's name gets, by that community's standing:
  `standing: {Anathema: Hide, Probationary: Warn, …}`. The verdict
  (`ethne_compact_standing_verdict`) takes the policy and the view of the same
  followed community, and the strictest of D37 and D39 wins. A weaker standing
  action is a loosening, so it needs more than a majority.

## Limits

- A ceremony has at most **3 participants**: a founding by 2, or the admission
  of 1 by 2 sitting members. A manifest for 4 would not fit the carrier.
- **Denied** follows only a refused ceremony that the refused community
  co-signed. An admitted member never drops to denied; anathema is the only way
  down.
- A compact of two cannot anathematize its only peer, because anathema needs 2
  reporting communities. Agora requires `SecondClass` for an anathema; KC
  itself does not.
- The examining panel is drawn from each community's staffed members, not from
  a rotated pool.
- Business reach covers only businesses that are compact members themselves.
- Hub cards carry no community, so they show no standing badge.
- KC has no record for leaving a compact.

## Deviations from the plan

- The cohort has **5 nodes, not 7**. One governance node per community, plus
  Alpha's Inductor and examiner on its own device, plus a reader. Beta and
  Gamma have no second device, because the remote-signing paths (recite,
  attest, examiner seal) are already proven on `awit`.
- **Reach and badges** are checked by `test/compact_test.dart`, not live. They
  are app-side reads of the same view that the cohort checks on the wire.
- **Compact-mates' hub areas** are not offered from a compact page. They come
  with the community once it is followed.

## Evidence

- Ethne: `examples/recognition_handoff` (15 tests, with every size above);
  en-charter D39 + D40 (265), en-uplift compact helpers (39); Python twins.
- `native/ethne_ffi`: 55 tests, among them three communities exchanging only
  hex strings (founding, admission with sponsor and a panel of 3, anathema, the
  D39 verdict), an examiner's replica rebuilt from its governance node's relay,
  and a seal refused once a mandate has lapsed.
- at-social conformance: every `record/op` above on both runtimes, plus a view
  carried and surviving a reload (C 571/571, Python 616, 0 asymmetric).
- `test/compact_test.dart`: the view book, D39 in the feed, the engine
  (outbox, receipts, recite, relay to examiners), and a real-cdylib group.
- Live: `test/cohort/compact_cohort.sh`, all six phases PASS on the host (2026-10-01).
