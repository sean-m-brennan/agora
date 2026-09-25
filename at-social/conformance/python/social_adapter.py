# ******************
#  Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
# ******************
"""Conformance adapter for the social extension (FEATURE_SPLIT_PLAN Phase 5).

Social rides the identity process, so a ``social`` scenario is an identity
scenario with more to say: ``SocialAdapter`` is ``IdentityAdapter`` plus the
social fixtures, trigger pseudo-functions, inbound builders and expected-state
keys, attached through the identity adapter's four extension points
(``FIXTURE_HOOKS``, ``TRIGGERS``, ``INBOUND_BUILDERS``, ``STATE_CHECKS``). Every
block below moved here verbatim from adapters/identity.py; the identity adapter
now imports the core only. The runner registers this adapter only where
``autonomous_trust.social`` imports, so a core-only run skips the protocol.
The C twin is src/c/conformance/adapters/social.c.
"""

from __future__ import annotations

from typing import Any

from autonomous_trust.core.config import to_json_string, from_json_string
from autonomous_trust.core.identity import Identity
from autonomous_trust.core.network import Message
from autonomous_trust.core.system import CfgIds
from autonomous_trust.social import handlers as social_handlers
from autonomous_trust.social.protocol import SocialProtocol

from conformance.harness.python.adapters.identity import IdentityAdapter, _Participant

# Pseudo-function: locally block the peer named in the step payload
# (`{"peer": <pid>}`). Block is an APP verb (AT_APP_BLOCK), not a wire message,
# so there is no inbound to dispatch -- the step drives the production
# block_peer() call, which records the peer so get_peer_tier clamps it to 0.
# Purely local (no emit, no reputation tx). The C adapter recognizes the same
# string and calls identity_block_peer. See block-local-clamp.
_TRIGGER_BLOCK = 'trigger_block'
_TRIGGER_UNBLOCK = 'trigger_unblock'
_TRIGGER_SOCIAL_RELOAD = 'trigger_social_reload'
# Pseudo-function: the step's `to` participant REPORTS the peer named in the
# payload (`{"peer": <pid>}`, Phase 4 P4.1), end to end. Report is an app verb,
# so the step drives the production report_peer(); the emitted peer_report
# (whose seq the reporter's own freshness counter chose, so no YAML step could
# name it) is then delivered to the reported participant's real handler, which
# stages its half. Mirrors the C adapter's trigger_report. See
# report-pairs-bilaterally.
_TRIGGER_REPORT = 'trigger_report'

# Pseudo-function: drive one private-proximity probe (Phase 2) from the step's
# `to` participant (the INITIATOR) against the peer named in the payload
# (`{"target": <pid>}`), end to end — the local trigger emits an encrypted
# probe, the target computes its distance BAND and replies, the initiator
# computes the same band from the reply. A pseudo-step rather than two wire
# steps because the probe/reply payloads are handler-COMPUTED keyed tags: the
# salt and the tag set do not exist until the real handler runs, so no YAML
# step could name them (contrast position, whose bucket is a fixture). The C
# adapter recognizes the same string and drives identity_request_proximity +
# the two directed handlers. See proximity-band-near / proximity-absent-is-normal.
_TRIGGER_PROXIMITY_PROBE = 'trigger_proximity_probe'

# Pseudo-function: the business named in the step's payload publishes its own
# page (Phase 3 P3.2). Advertising is an APP verb, not a wire message, so there
# is nothing to dispatch — the step drives the production advertise_business()
# and the resulting peer_business_ad emission is what travels. The C adapter
# recognizes the same string and calls identity_advertise_business.
# See business-ad-shared / business-ad-customer-relays.
_TRIGGER_ADVERTISE_BUSINESS = 'trigger_advertise_business'


# -- expected_state keys (moved from _Participant._check_expected_state) -- #

def _check_peer_position(self: _Participant, key: str, expected: Any) -> None:
    # {peer_id: geohash} -- the coarse position this participant
    # recorded for another peer, via get_peer_position. '' means
    # "none recorded" (the peer opted out, or the response was
    # dropped/refused) -- the ordinary default. C mirrors via
    # identity_get_peer_position keyed by the same uuid.
    for peer_id, want in expected.items():
        peer_uuid = self._uuid_for_pid(peer_id)
        actual = social_handlers.get_peer_position(self.process, peer_uuid)
        if actual != want:
            raise AssertionError(
                f'{self.id}: peer_position[{peer_id!r}]={actual!r}, '
                f'expected {want!r}')

def _check_peer_profile(self: _Participant, key: str, expected: Any) -> None:
    # {peer_id: {profile fields}} (Increment 3) -- the profile this
    # participant recorded for another, via get_peer_profile (a dict),
    # compared structurally. {} means none recorded (opted out, or
    # dropped on bad signature / over-bound field / replay). C mirrors
    # via identity_get_peer_profile keyed by the same uuid.
    for peer_id, want in expected.items():
        peer_uuid = self._uuid_for_pid(peer_id)
        actual = social_handlers.get_peer_profile(self.process, peer_uuid)
        want_obj = want if isinstance(want, dict) else {}
        if actual != want_obj:
            raise AssertionError(
                f'{self.id}: peer_profile[{peer_id!r}]={actual!r}, '
                f'expected {want_obj!r}')

def _check_peer_proximity(self: _Participant, key: str, expected: Any) -> None:
    # {peer_id: <int band>} (Phase 2) -- the coarse distance BAND
    # this participant last learned toward another CONNECTED peer,
    # via get_peer_proximity: unknown=0, near=1, mid=2, far=3. 0 is
    # the ordinary default (never probed, opted out, or the probe
    # was refused). No coordinates cross; the corpus pins the band
    # the keyed-tag intersection yields. C mirrors this via the band
    # recorded by identity_emit_peer_proximity, keyed by the same
    # uuid.
    for peer_id, want in expected.items():
        peer_uuid = self._uuid_for_pid(peer_id)
        actual = social_handlers.get_peer_proximity(self.process, peer_uuid)
        if int(actual) != int(want):
            raise AssertionError(
                f'{self.id}: peer_proximity[{peer_id!r}]={int(actual)}, '
                f'expected {int(want)}')

def _check_business_page(self: _Participant, key: str, expected: Any) -> None:
    # {polity_did: {seq, endorsers}} (Phase 3 P3.2) -- what this
    # participant LEARNED about a business, via get_business_page.
    # `seq` is the page version it holds; `endorsers` the number of
    # CUSTOMERS that have vouched for it (a business's own ad is not
    # an endorsement, so a page nobody patronizes has 0). {} means no
    # page held at all -- which, for a non-customer that never
    # received an ad, is the correct silent outcome. C mirrors via
    # identity_get_business_page keyed by the same did.
    for did, want in expected.items():
        actual = social_handlers.get_business_page(self.process, did)
        if not isinstance(want, dict) or not want:
            if actual:
                raise AssertionError(
                    f'{self.id}: business_page[{did!r}]={actual!r}, '
                    f'expected none')
            continue
        if not actual:
            raise AssertionError(
                f'{self.id}: business_page[{did!r}] missing, '
                f'expected {want!r}')
        if 'seq' in want and int(actual.get('seq', -1)) != int(want['seq']):
            raise AssertionError(
                f'{self.id}: business_page[{did!r}].seq='
                f'{actual.get("seq")}, expected {want["seq"]}')
        if 'endorsers' in want:
            got_n = len(actual.get('endorsers', {}))
            if got_n != int(want['endorsers']):
                raise AssertionError(
                    f'{self.id}: business_page[{did!r}].endorsers='
                    f'{got_n}, expected {want["endorsers"]}')
        if 'bundle' in want and actual.get('bundle') != want['bundle']:
            raise AssertionError(
                f'{self.id}: business_page[{did!r}].bundle='
                f'{actual.get("bundle")!r}, expected '
                f'{want["bundle"]!r}')

def _check_customer_satisfaction(self: _Participant, key: str, expected: Any) -> None:
    # {polity_did: <int>} (Phase 3 P3.2) -- this participant's OWN
    # customer edge, via get_customer_satisfaction: 0..4, or -1 when
    # it holds none and therefore CARRIES NOTHING for that business.
    # C mirrors via identity_get_customer_satisfaction.
    for did, want in expected.items():
        actual = social_handlers.get_customer_satisfaction(self.process, did)
        if int(actual) != int(want):
            raise AssertionError(
                f'{self.id}: customer_satisfaction[{did!r}]='
                f'{int(actual)}, expected {int(want)}')

def _check_business_ads_emitted(self: _Participant, key: str, expected: Any) -> None:
    # peer_business_ad emissions by this participant (Phase 3 P3.2).
    # THE GATE ASSERTION: a CUSTOMER that receives an ad re-advertises
    # (>=1), a non-customer stays SILENT (0). This is what makes the
    # page travel only through people who actually patronize the
    # business. C mirrors by counting the same emission.
    actual = self.emit_tally.get(SocialProtocol.business_ad, 0)
    if actual != int(expected):
        raise AssertionError(
            f'{self.id}: business_ads_emitted={actual}, '
            f'expected {int(expected)}')

def _check_business_post_last(self: _Participant, key: str, expected: Any) -> None:
    # {polity_did: {seq, hops, bundle}} (Phase 3 P3.4) -- the most
    # recent business post this participant ACCEPTED for that
    # polity, via get_last_business_post. Filled only AFTER the
    # signature check, THE PAGE GATE and dedup, so an expected {}
    # is the assertion that one of those three refused it. Keyed by
    # the POLITY, never the sender: the post is the business's and
    # the carrier is incidental. C mirrors via
    # identity_get_last_business_post keyed by the same did.
    for did, want in expected.items():
        actual = social_handlers.get_last_business_post(self.process, did)
        if not want:
            if actual:
                raise AssertionError(
                    f'{self.id}: business_post_last[{did!r}]='
                    f'{actual!r}, expected none')
            continue
        if not actual:
            raise AssertionError(
                f'{self.id}: business_post_last[{did!r}] missing, '
                f'expected {want!r}')
        if 'seq' in want and int(actual.get('seq', -1)) != int(want['seq']):
            raise AssertionError(
                f'{self.id}: business_post_last[{did!r}].seq='
                f'{actual.get("seq")}, expected {want["seq"]}')
        if 'hops' in want and int(actual.get('hops', -1)) != int(want['hops']):
            raise AssertionError(
                f'{self.id}: business_post_last[{did!r}].hops='
                f'{actual.get("hops")}, expected {want["hops"]}')
        if 'bundle' in want and actual.get('bundle') != want['bundle']:
            raise AssertionError(
                f'{self.id}: business_post_last[{did!r}].bundle='
                f'{actual.get("bundle")!r}, expected '
                f'{want["bundle"]!r}')

def _check_business_posts_emitted(self: _Participant, key: str, expected: Any) -> None:
    # peer_business_post emissions by this participant (Phase 3
    # P3.4). THE RELAY ASSERTION, twin of business_ads_emitted: a
    # node that HOLDS THE PAGE relays once (1), a node that does not
    # stays silent (0) -- the audience gate made observable rather
    # than argued for. C mirrors by counting the same emission.
    actual = self.emit_tally.get(SocialProtocol.business_post, 0)
    if actual != int(expected):
        raise AssertionError(
            f'{self.id}: business_posts_emitted={actual}, '
            f'expected {int(expected)}')

def _check_connection_state(self: _Participant, key: str, expected: Any) -> None:
    # {peer_id: <int>} (Increment 5) -- the connection edge state
    # this participant holds toward another, via
    # get_connection_state: none=0, pending_out=1, pending_in=2,
    # connected=3, declined=4. C mirrors via
    # identity_get_connection_state keyed by the same uuid.
    for peer_id, want in expected.items():
        peer_uuid = self._uuid_for_pid(peer_id)
        actual = social_handlers.get_connection_state(self.process, peer_uuid)
        if actual != want:
            raise AssertionError(
                f'{self.id}: connection_state[{peer_id!r}]={actual!r}, '
                f'expected {want!r}')

def _check_dm_last(self: _Participant, key: str, expected: Any) -> None:
    # {peer_id: {seq, text} | {absent: true}} (Increment 6) -- the
    # most-recent DM this participant received from another, via
    # get_last_dm. `absent: true` asserts that NO DM is held, which
    # a DM dropped at the block gate produces (Phase 4 P4.1); an
    # unexpectedly absent DM still fails. C mirrors this via
    # identity_get_last_dm keyed by the same uuid.
    for peer_id, want in expected.items():
        peer_uuid = self._uuid_for_pid(peer_id)
        actual = social_handlers.get_last_dm(self.process, peer_uuid)
        want_obj0 = want if isinstance(want, dict) else {}
        if want_obj0.get('absent'):
            if actual:
                raise AssertionError(
                    f'{self.id}: dm_last[{peer_id!r}] present '
                    f'(text={actual.get("text")!r}), expected ABSENT')
            continue
        if not actual:
            raise AssertionError(
                f'{self.id}: dm_last[{peer_id!r}] absent, expected a DM')
        want_obj = want if isinstance(want, dict) else {}
        for fk, fv in want_obj.items():
            if actual.get(fk) != fv:
                raise AssertionError(
                    f'{self.id}: dm_last[{peer_id!r}].{fk}='
                    f'{actual.get(fk)!r}, expected {fv!r}')

def _check_post_last(self: _Participant, key: str, expected: Any) -> None:
    # {author_id: {seq, tier, body} | {absent: true}} (Increment 7) --
    # the most-recent feed post this participant accepted from another
    # AUTHOR, via get_last_post. A post that never arrived, was dropped
    # by the signature/tier-gate, or was deduped away is ABSENT;
    # `absent: true` asserts that. C mirrors this via
    # identity_get_last_post keyed by the same author uuid.
    for author_id, want in expected.items():
        author_uuid = self._uuid_for_pid(author_id)
        actual = social_handlers.get_last_post(self.process, author_uuid)
        want_obj = want if isinstance(want, dict) else {}
        if want_obj.get('absent'):
            if actual:
                raise AssertionError(
                    f'{self.id}: post_last[{author_id!r}] present '
                    f'(body={actual.get("body")!r}), expected ABSENT')
            continue
        if not actual:
            raise AssertionError(
                f'{self.id}: post_last[{author_id!r}] absent, '
                f'expected a post')
        for fk, fv in want_obj.items():
            if actual.get(fk) != fv:
                raise AssertionError(
                    f'{self.id}: post_last[{author_id!r}].{fk}='
                    f'{actual.get(fk)!r}, expected {fv!r}')

def _check_cosign_request_last(self: _Participant, key: str, expected: Any) -> None:
    # {requester_id: {record, op, cid, bytes, seq} | {absent: true}}
    # (Phase 3 P3.3) -- the most-recent co-signing ask this
    # participant received from another, via
    # get_last_cosign_request. An ask refused by the shape gate
    # (unknown act, a payload no exporter produced) or by the replay
    # gate is ABSENT; `absent: true` asserts that, and it is what
    # makes the refusal scenarios load-bearing rather than merely
    # non-crashing. C mirrors via identity_get_last_cosign_request
    # keyed by the same uuid.
    for peer_id, want in expected.items():
        peer_uuid = self._uuid_for_pid(peer_id)
        actual = social_handlers.get_last_cosign_request(self.process, peer_uuid)
        want_obj = want if isinstance(want, dict) else {}
        if want_obj.get('absent'):
            if actual:
                raise AssertionError(
                    f'{self.id}: cosign_request_last[{peer_id!r}] '
                    f'present ({actual.get("record")}/'
                    f'{actual.get("op")}), expected ABSENT')
            continue
        if not actual:
            raise AssertionError(
                f'{self.id}: cosign_request_last[{peer_id!r}] '
                f'absent, expected an ask')
        for fk, fv in want_obj.items():
            if actual.get(fk) != fv:
                raise AssertionError(
                    f'{self.id}: cosign_request_last[{peer_id!r}]'
                    f'.{fk}={actual.get(fk)!r}, expected {fv!r}')

def _check_cosign_sig_last(self: _Participant, key: str, expected: Any) -> None:
    # {signer_id: {cid, signer, sig, seq} | {absent: true}} (Phase 3
    # P3.3) -- the most-recent co-signature this participant received
    # back, via get_last_cosign_sig. The runtime does NOT verify it
    # (it does not hold the payload the signature is over), so what is
    # pinned here is carriage and the replay gate, not validity. C
    # mirrors via identity_get_last_cosign_sig.
    for peer_id, want in expected.items():
        peer_uuid = self._uuid_for_pid(peer_id)
        actual = social_handlers.get_last_cosign_sig(self.process, peer_uuid)
        want_obj = want if isinstance(want, dict) else {}
        if want_obj.get('absent'):
            if actual:
                raise AssertionError(
                    f'{self.id}: cosign_sig_last[{peer_id!r}] present '
                    f'(cid={actual.get("cid")!r}), expected ABSENT')
            continue
        if not actual:
            raise AssertionError(
                f'{self.id}: cosign_sig_last[{peer_id!r}] absent, '
                f'expected a signature')
        for fk, fv in want_obj.items():
            if actual.get(fk) != fv:
                raise AssertionError(
                    f'{self.id}: cosign_sig_last[{peer_id!r}].{fk}='
                    f'{actual.get(fk)!r}, expected {fv!r}')

def _check_social_tx_last(self: _Participant, key: str, expected: Any) -> None:
    # {subject_id: {score} | {absent: true}} (Increment 8) -- the last
    # interaction reputation score this participant STAGED about another
    # peer, via get_last_social_tx. A one-way interaction (bilateral gate
    # unmet) or a capped one stages NOTHING -> ABSENT; `absent: true`
    # asserts that. The score is the deterministic accrual observable,
    # independent of the Paxos round. C mirrors this via
    # identity_get_last_social_tx keyed by the same subject uuid. The
    # `task` id is also comparable (both runtimes derive it identically),
    # but the score alone pins the gating/diminishing behavior the
    # scenarios exercise.
    for subject_id, want in expected.items():
        subject_uuid = self._uuid_for_pid(subject_id)
        actual = social_handlers.get_last_social_tx(self.process, subject_uuid)
        want_obj = want if isinstance(want, dict) else {}
        if want_obj.get('absent'):
            if actual:
                raise AssertionError(
                    f'{self.id}: social_tx_last[{subject_id!r}] present '
                    f'(score={actual.get("score")}), expected ABSENT')
            continue
        if not actual:
            raise AssertionError(
                f'{self.id}: social_tx_last[{subject_id!r}] absent, '
                f'expected a staged score')
        for fk, fv in want_obj.items():
            av = actual.get(fk)
            if fk == 'same_task_as':
                # {participant, subject} (Phase 4 P4.1): the task we
                # staged must be THE SAME task that participant
                # staged about that subject -- the two halves of one
                # bilateral transaction. The seq in the task is
                # chosen at run time, so equality is the only pin.
                other = self.peers_by_pid.get(str(fv.get('participant')))
                if other is None:
                    raise AssertionError(
                        f'{self.id}: same_task_as names unknown '
                        f'participant {fv.get("participant")!r}')
                theirs = social_handlers.get_last_social_tx(other.process, 
                    other._uuid_for_pid(str(fv.get('subject'))))
                if not theirs or theirs.get('task') != actual.get('task'):
                    raise AssertionError(
                        f'{self.id}: social_tx_last[{subject_id!r}].task='
                        f'{actual.get("task")!r}, but '
                        f'{fv.get("participant")} staged '
                        f'{theirs.get("task") if theirs else None!r} '
                        f'about {fv.get("subject")} -- the halves '
                        f'would not pair')
                continue
            if fk == 'score' and isinstance(av, (int, float)) \
                    and isinstance(fv, (int, float)):
                if abs(float(av) - float(fv)) > 1e-6:
                    raise AssertionError(
                        f'{self.id}: social_tx_last[{subject_id!r}].score='
                        f'{av}, expected {fv}')
            elif av != fv:
                raise AssertionError(
                    f'{self.id}: social_tx_last[{subject_id!r}].{fk}='
                    f'{av!r}, expected {fv!r}')

def _check_position_responses_emitted(self: _Participant, key: str, expected: Any) -> None:
    # Number of peer_position_response messages this participant
    # emitted (Increment 2). The observable for the opt-in guard:
    # an opted-OUT node emits 0 (position-absent-is-normal), an
    # opted-IN one emits 1 per query answered. This is what makes
    # the opt-out case non-vacuous — dropping the guard would emit a
    # response even with no own position. C mirrors by scanning
    # captured[] for (from==self, peer_position_response).
    actual = self.emit_tally.get(SocialProtocol.position_response, 0)
    if actual != expected:
        raise AssertionError(
            f'{self.id}: position_responses_emitted={actual}, '
            f'expected {expected}'
        )

def _check_profile_responses_emitted(self: _Participant, key: str, expected: Any) -> None:
    # peer_profile_response emissions by this participant (Increment
    # 3) -- same opt-in-guard observable as position: 0 when opted
    # out, 1 per answered query when opted in. C mirrors by scanning
    # captured[] for (from==self, peer_profile_response).
    actual = self.emit_tally.get(SocialProtocol.profile_response, 0)
    if actual != expected:
        raise AssertionError(
            f'{self.id}: profile_responses_emitted={actual}, '
            f'expected {expected}'
        )

def _check_proximity_probes_emitted(self: _Participant, key: str, expected: Any) -> None:
    # peer_proximity_probe emissions by this participant (Phase 2).
    # The initiator's opt-in guard observable: an opted-OUT initiator
    # emits 0 (proximity-absent-is-normal), an opted-IN one emits 1
    # per trigger. This is what makes the opt-out case non-vacuous —
    # dropping the guard would emit a probe with no own position. C
    # mirrors by scanning captured[] for (from==self, proximity_probe).
    actual = self.emit_tally.get(SocialProtocol.proximity_probe, 0)
    if actual != expected:
        raise AssertionError(
            f'{self.id}: proximity_probes_emitted={actual}, '
            f'expected {expected}'
        )

def _check_proximity_replies_emitted(self: _Participant, key: str, expected: Any) -> None:
    # peer_proximity_reply emissions by this participant (Phase 2) --
    # the RESPONDER's opt-in observable: a probed node that opted out
    # emits 0 (it surfaces UNKNOWN and sends nothing back), an opted-in
    # one emits 1 per probe answered. C mirrors by scanning captured[]
    # for (from==self, proximity_reply).
    actual = self.emit_tally.get(SocialProtocol.proximity_reply, 0)
    if actual != expected:
        raise AssertionError(
            f'{self.id}: proximity_replies_emitted={actual}, '
            f'expected {expected}'
        )


# -- fixtures (moved from IdentityAdapter._build_participants) ---------- #

def _fixtures(self: IdentityAdapter, participant: _Participant, pid: str,
              fixtures: dict[str, Any], identities: dict[str, Identity]) -> None:
    # Install own coarse position from fixtures.positions (Increment 2,
    # the "with-distance" feature); mirrors the C adapter's
    # `identity_set_own_geohash` seam. An opted-in participant's
    # handle_position_query answers with this geohash; absent or empty,
    # the participant is opted OUT (the default) and answers nothing.
    pos_fix: dict[str, str] = fixtures.get('positions', {}) or {}
    if pid in pos_fix:
        participant.process.social.own_geohash = str(pos_fix[pid] or '')
    # Install own agora.profile from fixtures.profiles (Increment 3);
    # mirrors the C adapter's `identity_set_own_profile` seam. An opted-in
    # participant's handle_profile_query answers with this (sanitized,
    # signed) profile; absent/empty, it is opted OUT (the default).
    prof_fix: dict[str, dict] = fixtures.get('profiles', {}) or {}
    if pid in prof_fix:
        from autonomous_trust.social.codec import (
            sanitize_profile)
        raw = prof_fix[pid] if isinstance(prof_fix[pid], dict) else {}
        participant.process.social.own_profile = sanitize_profile(raw)
    # Install own opt-in EXACT position from fixtures.exact_positions
    # (Phase 2, private proximity), as {pid: [lat, lon]}; mirrors the C
    # adapter's `identity_set_exact_position` seam. LOCAL-ONLY — it never
    # advertises, and feeds only the pairwise distance-band probe. Absent
    # (the default) leaves own_exact None: opted OUT, no probe, no band.
    exact_fix: dict[str, Any] = fixtures.get('exact_positions', {}) or {}
    if pid in exact_fix:
        coord = exact_fix[pid]
        if (isinstance(coord, (list, tuple)) and len(coord) == 2):
            participant.process.social.own_exact = (float(coord[0]),
                                             float(coord[1]))
    # Pre-seed CONNECTED edges from fixtures.connections, as
    # {pid: [other_pid, ...]}: sets connection_edges[other]=CONNECTED
    # directly, standing in for a completed request/accept exchange so a
    # scenario that only exercises a DOWNSTREAM feature (proximity, which
    # is connected-peers-only) need not re-run the connection handshake.
    # Mirrors the C adapter's identity_set_connection_state seam.
    conn_fix: dict[str, list] = fixtures.get('connections', {}) or {}
    if pid in conn_fix:
        from autonomous_trust.social.codec import (
            CONN_CONNECTED)
        for other_pid in conn_fix[pid]:
            if other_pid not in identities:
                raise AssertionError(
                    f'fixtures.connections names unknown participant '
                    f'{other_pid!r}')
            other_uuid = str(identities[other_pid].uuid)
            participant.process.social.connection_edges[other_uuid] = CONN_CONNECTED
    # Install CUSTOMER edges from fixtures.customers (Phase 3 P3.2), as
    # {pid: {polity_did: {'sat': int, 'bundle': str, 'seq': int}}}. The
    # customer edge is the RELAY GATE: only a node holding one carries a
    # business's page, so this fixture is what separates a relaying
    # customer from a silent bystander in the scenarios. Mirrors the C
    # adapter's identity_set_customer seam. Absent (the default) leaves
    # the node with no edges — it will hold pages but never re-advertise.
    cust_fix: dict[str, dict] = fixtures.get('customers', {}) or {}
    if pid in cust_fix:
        for did, spec in (cust_fix[pid] or {}).items():
            spec = spec if isinstance(spec, dict) else {}
            social_handlers.set_customer(participant.process, 
                did, int(spec.get('sat', 0)),
                bundle=str(spec.get('bundle', '')),
                seq=int(spec.get('seq', 0)))


# -- trigger pseudo-functions (moved from IdentityAdapter._dispatch) ---- #

def _trigger_social_reload(self: IdentityAdapter, participant: _Participant, inbound: Message):
    # Pseudo-function: save the block set and load it back -- the round
    # trip a restart performs, without needing one. A conformance step
    # cannot restart a process, and asserting on the in-memory dict
    # alone would pass with no file written at all. Mirrors the C
    # adapter's trigger_social_reload -> identity_reload_social_blocks.
    # A WRITABLE dir, explicitly. The harness's default config root
    # may not be writable (C's is /etc/at), and a reload that could not
    # write would be a no-op that PASSED — proving nothing while
    # looking green. Same temp dir shape as the C adapter.
    import tempfile
    reload_dir = tempfile.mkdtemp(prefix='at-conf-social-')
    social_handlers.reload_social_blocks(participant.process, reload_dir)
    return participant.drain_outbox()

def _trigger_report(self: IdentityAdapter, participant: _Participant, inbound: Message):
    # `participant` is the REPORTER. Run the production report_peer(),
    # then hand every peer_report it emitted to the reported
    # participant's real handler. A refused report emits nothing, so
    # nothing is delivered -- which is what the cap scenario relies on.
    spec = from_json_string(inbound.obj) if inbound.obj else {}
    target_pid = str(spec.get('peer', ''))
    target = participant.peers_by_pid.get(target_pid)
    if target is None:
        raise AssertionError(f'trigger_report: unknown peer {target_pid!r}')
    social_handlers.report_peer(participant.process, participant.queues,
                                    str(target.identity.uuid))
    rest = []
    for c in participant.drain_outbox():
        if c.function == SocialProtocol.report:
            target.process.protocol.run_message_handlers(target.queues,
                                                         c.raw)
            target.drain_outbox()
        else:
            rest.append(c)
    return rest

def _trigger_unblock(self: IdentityAdapter, participant: _Participant, inbound: Message):
    # Pseudo-function: lift the block on the peer the step names.
    # Unblock is an app verb, not a wire message, so there is nothing to
    # dispatch -- run the production unblock_peer() call. Mirrors the C
    # adapter's trigger_unblock -> identity_unblock_peer.
    spec = from_json_string(inbound.obj) if inbound.obj else {}
    peer_uuid = participant._uuid_for_pid(str(spec.get('peer', '')))
    social_handlers.unblock_peer(participant.process, str(peer_uuid))
    return participant.drain_outbox()

def _trigger_block(self: IdentityAdapter, participant: _Participant, inbound: Message):
    # Pseudo-function: locally block the peer the step names. Block is an
    # app verb, not a wire message, so there is nothing to dispatch -- run
    # the production block_peer() call; the clamp is observed via
    # peer_tier. Mirrors the C adapter's trigger_block ->
    # identity_block_peer.
    spec = from_json_string(inbound.obj) if inbound.obj else {}
    peer_uuid = participant._uuid_for_pid(str(spec.get('peer', '')))
    social_handlers.block_peer(participant.process, str(peer_uuid))
    return participant.drain_outbox()

def _trigger_proximity_probe(self: IdentityAdapter, participant: _Participant, inbound: Message):
    # `participant` is the probe TARGET; from_whom is the INITIATOR (the
    # step's `from`). Run the whole probe/reply round trip through the
    # real handlers, so the band both sides record is the one the
    # keyed-tag intersection actually yields — the payloads are computed,
    # not harness-supplied. Mirrors the trigger_attest_pull shape.
    initiator = self._roster_by_uuid.get(str(inbound.from_whom.uuid))
    if initiator is None:
        raise AssertionError('proximity probe: unknown initiator')
    self._run_proximity_probe(initiator, participant)
    return participant.drain_outbox()

def _trigger_advertise_business(self: IdentityAdapter, participant: _Participant, inbound: Message):
    # Pseudo-function: `participant` is the BUSINESS; the step's payload
    # names its polity and page. Advertising is an app verb, not a wire
    # message, so run the production advertise_business() and let the
    # emitted peer_business_ad be delivered by the engine. Mirrors the C
    # adapter's trigger_advertise_business.
    spec = from_json_string(inbound.obj) if inbound.obj else {}
    social_handlers.advertise_business(participant.process, 
        participant.queues, str(spec.get('polity', '')),
        str(spec.get('bundle', '')), int(spec.get('seq', 0)))
    return participant.drain_outbox()


# -- inbound builders (moved from IdentityAdapter._build_inbound) -------- #

def _build_position_query(self: IdentityAdapter, participants, sender: _Participant,
        sender_identity, *, from_id: str, to_id: str, function: str,
        payload: dict[str, Any]) -> str:
    # handle_position_query reads no payload -- it answers with our own
    # coarse position IFF opted in (own_geohash set, via
    # fixtures.positions), else nothing. Empty obj, parseable but unused
    # (mirrors caps_query). C's builder likewise takes the generic path.
    obj = ''
    return obj

def _build_position_response(self: IdentityAdapter, participants, sender: _Participant,
        sender_identity, *, from_id: str, to_id: str, function: str,
        payload: dict[str, Any]) -> str:
    # handle_position_response parses {pos: geohash, seq: N}. `seq` is
    # the responder's freshness sequence; `unstamped: true` omits it,
    # modelling a stripped field, which must be refused rather than
    # stored. Mirrors the C peer_position_response builder.
    body = {'pos': payload.get('pos', '') if isinstance(payload, dict) else ''}
    if not (isinstance(payload, dict) and payload.get('unstamped')):
        body['seq'] = int(payload.get('seq', 1)) if isinstance(payload, dict) else 1
    obj = to_json_string(body)
    return obj

def _build_profile_query(self: IdentityAdapter, participants, sender: _Participant,
        sender_identity, *, from_id: str, to_id: str, function: str,
        payload: dict[str, Any]) -> str:
    # handle_profile_query reads no payload -- answers with our own
    # profile IFF opted in (own_profile set, via fixtures.profiles).
    obj = ''
    return obj

def _build_profile_response(self: IdentityAdapter, participants, sender: _Participant,
        sender_identity, *, from_id: str, to_id: str, function: str,
        payload: dict[str, Any]) -> str:
    # handle_profile_response parses {profile, sig, seq}. The signature
    # is computed over the SENDER's canonical form with the sender's key
    # -- exactly as handle_profile_query would -- so a Python or C
    # receiver verifies it. A scenario may override `sig` (bad-signature
    # drop) or set `unstamped: true` (replay/unstamped refusal). Mirrors
    # the C peer_profile_response builder.
    from autonomous_trust.social.codec import (
        profile_sign)
    profile = payload.get('profile', {}) if isinstance(payload, dict) else {}
    if not isinstance(profile, dict):
        profile = {}
    if isinstance(payload, dict) and isinstance(payload.get('sig'), str):
        sig = payload['sig']
    else:
        sig = profile_sign(sender.process.identity.signature.private,
                           sender.process.identity.uuid, profile)
    body = {'profile': profile, 'sig': sig}
    if not (isinstance(payload, dict) and payload.get('unstamped')):
        body['seq'] = int(payload.get('seq', 1)) if isinstance(payload, dict) else 1
    obj = to_json_string(body)
    return obj

def _build_connection_request(self: IdentityAdapter, participants, sender: _Participant,
        sender_identity, *, from_id: str, to_id: str, function: str,
        payload: dict[str, Any]) -> str:
    # handle_connection_request reads no payload -- it sets pending_in
    # from from_whom. Empty obj, generic path (mirrors the C builder).
    obj = ''
    return obj

def _build_connection_response(self: IdentityAdapter, participants, sender: _Participant,
        sender_identity, *, from_id: str, to_id: str, function: str,
        payload: dict[str, Any]) -> str:
    # handle_connection_response parses {decision, sig, seq}. The
    # signature is over the canonical (requester=recipient,
    # accepter=sender, decision, seq) with the sender's key -- exactly as
    # handle_app_connect_respond would -- so a Python or C receiver
    # verifies it. A scenario may override `sig` (bad-signature drop) or
    # set `unstamped: true` (replay/unstamped refusal); `accept` (bool)
    # selects the decision. Mirrors the C peer_connection_response builder.
    from autonomous_trust.social.codec import (
        connection_sign)
    decision = 1 if (isinstance(payload, dict) and payload.get('accept')) else 0
    recipient = participants[to_id].impl.identity
    seq = int(payload.get('seq', 1)) if isinstance(payload, dict) else 1
    if isinstance(payload, dict) and isinstance(payload.get('sig'), str):
        sig = payload['sig']
    else:
        sig = connection_sign(sender.process.identity.signature.private,
                              recipient.uuid,
                              sender.process.identity.uuid,
                              decision, seq)
    body = {'decision': decision, 'sig': sig}
    if not (isinstance(payload, dict) and payload.get('unstamped')):
        body['seq'] = seq
    obj = to_json_string(body)
    return obj

def _build_dm(self: IdentityAdapter, participants, sender: _Participant,
        sender_identity, *, from_id: str, to_id: str, function: str,
        payload: dict[str, Any]) -> str:
    # handle_dm parses {text, seq, ts}. A DM carries NO signature
    # (crypto_box authenticates the sender on the wire; in the harness the
    # from_whom identity stands in). `unstamped: true` drops the seq,
    # modelling a stripped field which must be refused. Mirrors the C
    # peer_dm builder.
    text = payload.get('text', '') if isinstance(payload, dict) else ''
    ts = payload.get('ts', 0.0) if isinstance(payload, dict) else 0.0
    body = {'text': text if isinstance(text, str) else '',
            'ts': float(ts) if isinstance(ts, (int, float)) else 0.0}
    if not (isinstance(payload, dict) and payload.get('unstamped')):
        body['seq'] = int(payload.get('seq', 1)) \
            if isinstance(payload, dict) else 1
    obj = to_json_string(body)
    return obj

def _build_post(self: IdentityAdapter, participants, sender: _Participant,
        sender_identity, *, from_id: str, to_id: str, function: str,
        payload: dict[str, Any]) -> str:
    # handle_post parses {author, author_pk, seq, ts, tier, body, sig,
    # hops}. The post is SIGNED with the SENDER's (author's) key over the
    # canonical (author, seq, ts, tier, body) form, exactly as
    # handle_app_publish_post would; author/author_pk name the sender. A
    # scenario may override `sig` (bad-signature drop) and `author_pk`
    # (impersonation); `unstamped: true` drops the seq. Mirrors the C
    # peer_post builder.
    from autonomous_trust.social.codec import post_sign
    text = payload.get('body') if isinstance(payload, dict) else ''
    if not isinstance(text, str):
        text = payload.get('text', '') if isinstance(payload, dict) else ''
    if not isinstance(text, str):
        text = ''
    ts = payload.get('ts', 0.0) if isinstance(payload, dict) else 0.0
    ts = float(ts) if isinstance(ts, (int, float)) else 0.0
    tier = payload.get('tier', 0) if isinstance(payload, dict) else 0
    tier = int(tier) if isinstance(tier, int) else 0
    hops = payload.get('hops', 0) if isinstance(payload, dict) else 0
    hops = int(hops) if isinstance(hops, int) else 0
    seq = int(payload.get('seq', 1)) if isinstance(payload, dict) else 1
    author_uuid = sender.process.identity.uuid
    author_str = str(author_uuid)
    if isinstance(payload, dict) and isinstance(payload.get('author_pk'), str):
        author_pk = payload['author_pk']
    else:
        author_pk = bytes(sender.process.identity.signature.public).hex()
    if isinstance(payload, dict) and isinstance(payload.get('sig'), str):
        sig = payload['sig']
    else:
        sig = post_sign(sender.process.identity.signature.private,
                        author_uuid, seq, ts, tier, text)
    obj = to_json_string({'author': author_str, 'author_pk': author_pk,
                          'seq': seq, 'ts': ts, 'tier': tier,
                          'body': text, 'sig': sig, 'hops': hops})
    return obj

def _build_business_ad(self: IdentityAdapter, participants, sender: _Participant,
        sender_identity, *, from_id: str, to_id: str, function: str,
        payload: dict[str, Any]) -> str:
    # handle_business_ad parses {advertiser, advertiser_pk, polity, sat,
    # seq, ts, bundle, sig}. The ad is SIGNED with the SENDER's key over
    # the canonical (advertiser, polity, sat, seq, ts, bundle) form,
    # exactly as _business_advertise would — the sender is always
    # speaking for ITSELF, since an ad is never relayed. A scenario may
    # override `sig` (bad-signature drop) and `advertiser_pk`
    # (impersonation). Mirrors the C peer_business_ad builder.
    from autonomous_trust.social.codec import (
        business_ad_sign, BUSINESS_SAT_SELF)
    payload = payload if isinstance(payload, dict) else {}
    did = payload.get('polity', '')
    did = did if isinstance(did, str) else ''
    bundle = payload.get('bundle', '')
    bundle = bundle if isinstance(bundle, str) else ''
    sat = payload.get('sat', BUSINESS_SAT_SELF)
    sat = int(sat) if isinstance(sat, int) else BUSINESS_SAT_SELF
    seq = payload.get('seq', 0)
    seq = int(seq) if isinstance(seq, int) else 0
    ts = payload.get('ts', 0.0)
    ts = float(ts) if isinstance(ts, (int, float)) else 0.0
    adv_uuid = sender.process.identity.uuid
    if isinstance(payload.get('advertiser_pk'), str):
        adv_pk = payload['advertiser_pk']
    else:
        adv_pk = bytes(sender.process.identity.signature.public).hex()
    if isinstance(payload.get('sig'), str):
        sig = payload['sig']
    else:
        sig = business_ad_sign(sender.process.identity.signature.private,
                               adv_uuid, did, sat, seq, ts, bundle)
    obj = to_json_string({'advertiser': str(adv_uuid),
                          'advertiser_pk': adv_pk, 'polity': did,
                          'sat': sat, 'seq': seq, 'ts': ts,
                          'bundle': bundle, 'sig': sig})
    return obj

def _build_business_post(self: IdentityAdapter, participants, sender: _Participant,
        sender_identity, *, from_id: str, to_id: str, function: str,
        payload: dict[str, Any]) -> str:
    # handle_business_post parses {author, author_pk, polity, seq, ts,
    # bundle, sig, hops}. The post is SIGNED with the SENDER's key over
    # the canonical (author, polity, seq, ts, bundle) form -- which is
    # what a RELAY does too, since the signature says only who sent this
    # copy. HOPS IS OUTSIDE THE SIGNATURE, so a scenario can set it to
    # drive the relay bound without breaking anything. A scenario may
    # override `sig` (bad-signature drop) and `author_pk`
    # (impersonation). Mirrors the C peer_business_post builder.
    from autonomous_trust.social.codec import (
        business_post_sign)
    payload = payload if isinstance(payload, dict) else {}
    did = payload.get('polity', '')
    did = did if isinstance(did, str) else ''
    bundle = payload.get('bundle', '')
    bundle = bundle if isinstance(bundle, str) else ''
    seq = payload.get('seq', 0)
    seq = int(seq) if isinstance(seq, int) else 0
    ts = payload.get('ts', 0.0)
    ts = float(ts) if isinstance(ts, (int, float)) else 0.0
    hops = payload.get('hops', 0)
    hops = int(hops) if isinstance(hops, int) else 0
    author_uuid = sender.process.identity.uuid
    if isinstance(payload.get('author_pk'), str):
        author_pk = payload['author_pk']
    else:
        author_pk = bytes(sender.process.identity.signature.public).hex()
    if isinstance(payload.get('sig'), str):
        sig = payload['sig']
    else:
        sig = business_post_sign(
            sender.process.identity.signature.private, author_uuid, did,
            seq, ts, bundle)
    obj = to_json_string({'author': str(author_uuid),
                          'author_pk': author_pk, 'polity': did,
                          'seq': seq, 'ts': ts, 'bundle': bundle,
                          'sig': sig, 'hops': hops})
    return obj

def _build_reaction(self: IdentityAdapter, participants, sender: _Participant,
        sender_identity, *, from_id: str, to_id: str, function: str,
        payload: dict[str, Any]) -> str:
    # handle_reaction parses {post_id, seq, ts} (Increment 8). A reaction
    # carries NO signature (crypto_box authenticates the reactor on the
    # wire; in the harness the from_whom identity stands in). The reactor is
    # the sender, the post's author is the recipient. `unstamped: true`
    # drops the seq. Mirrors the C peer_reaction builder.
    post_id = payload.get('post_id', '') if isinstance(payload, dict) else ''
    ts = payload.get('ts', 0.0) if isinstance(payload, dict) else 0.0
    body = {'post_id': post_id if isinstance(post_id, str) else '',
            'ts': float(ts) if isinstance(ts, (int, float)) else 0.0}
    if not (isinstance(payload, dict) and payload.get('unstamped')):
        body['seq'] = int(payload.get('seq', 1)) \
            if isinstance(payload, dict) else 1
    obj = to_json_string(body)
    return obj

def _build_report(self: IdentityAdapter, participants, sender: _Participant,
        sender_identity, *, from_id: str, to_id: str, function: str,
        payload: dict[str, Any]) -> str:
    # handle_peer_report parses {seq, ts} (Phase 4 P4.1) and nothing
    # else. No signature: crypto_box authenticates the reporter (in the
    # harness the from_whom identity stands in). `unstamped: true` drops
    # the seq. Mirrors the C peer_report builder.
    payload = payload if isinstance(payload, dict) else {}
    ts = payload.get('ts', 0.0)
    body = {'ts': float(ts) if isinstance(ts, (int, float)) else 0.0}
    if not payload.get('unstamped'):
        body['seq'] = int(payload.get('seq', 1))
    obj = to_json_string(body)
    return obj

def _build_cosign_request(self: IdentityAdapter, participants, sender: _Participant,
        sender_identity, *, from_id: str, to_id: str, function: str,
        payload: dict[str, Any]) -> str:
    # handle_cosign_request parses {record, op, polity, cid, bytes, seq,
    # ts} (Phase 3 P3.3). A co-signing ask carries NO signature: it is
    # directed and encrypted, so crypto_box authenticates the asker (in
    # the harness the from_whom identity stands in).
    #
    # EVERY FIELD IS PASSED THROUGH VERBATIM, deliberately. Building it
    # with cosign_request_to_json would let the BUILDER refuse a
    # malformed ask, and then the refusal scenarios would prove nothing
    # about the handler — which is the side a hostile peer actually
    # reaches. `unstamped: true` drops the seq. Mirrors the C
    # peer_cosign_request builder.
    #
    # There is no `description` field to build, and that is the point:
    # the wording of what is being signed is derived on the SIGNER's node
    # from the bytes. A scenario may smuggle one in to prove it is
    # ignored.
    payload = payload if isinstance(payload, dict) else {}
    body = {}
    for fk in ('record', 'op', 'polity', 'cid', 'bytes'):
        fv = payload.get(fk, '')
        body[fk] = fv if isinstance(fv, str) else ''
    ts = payload.get('ts', 0.0)
    body['ts'] = float(ts) if isinstance(ts, (int, float)) else 0.0
    if isinstance(payload.get('description'), str):
        body['description'] = payload['description']
    if not payload.get('unstamped'):
        body['seq'] = int(payload.get('seq', 1)) \
            if isinstance(payload.get('seq', 1), int) else 1
    obj = to_json_string(body)
    return obj

def _build_cosign_sig(self: IdentityAdapter, participants, sender: _Participant,
        sender_identity, *, from_id: str, to_id: str, function: str,
        payload: dict[str, Any]) -> str:
    # handle_cosign_sig parses {cid, signer, sig, seq, ts} (Phase 3
    # P3.3): the signer's half coming back to the node authoring the
    # exchange. Passed through verbatim for the same reason as the ask.
    # This runtime does NOT verify the signature and cannot — it does not
    # hold the payload the signature is over. Mirrors the C
    # peer_cosign_sig builder.
    payload = payload if isinstance(payload, dict) else {}
    body = {}
    for fk in ('cid', 'signer', 'sig'):
        fv = payload.get(fk, '')
        body[fk] = fv if isinstance(fv, str) else ''
    ts = payload.get('ts', 0.0)
    body['ts'] = float(ts) if isinstance(ts, (int, float)) else 0.0
    if not payload.get('unstamped'):
        body['seq'] = int(payload.get('seq', 1)) \
            if isinstance(payload.get('seq', 1), int) else 1
    obj = to_json_string(body)
    return obj


class SocialAdapter(IdentityAdapter):
    """IdentityAdapter plus social; see the module docstring."""

    FIXTURE_HOOKS = IdentityAdapter.FIXTURE_HOOKS + (_fixtures,)
    TRIGGERS = {**IdentityAdapter.TRIGGERS,
                _TRIGGER_SOCIAL_RELOAD: _trigger_social_reload,
                _TRIGGER_REPORT: _trigger_report,
                _TRIGGER_UNBLOCK: _trigger_unblock,
                _TRIGGER_BLOCK: _trigger_block,
                _TRIGGER_PROXIMITY_PROBE: _trigger_proximity_probe,
                _TRIGGER_ADVERTISE_BUSINESS: _trigger_advertise_business,
                }
    INBOUND_BUILDERS = {**IdentityAdapter.INBOUND_BUILDERS,
                        SocialProtocol.position_query: _build_position_query,
                        SocialProtocol.position_response: _build_position_response,
                        SocialProtocol.profile_query: _build_profile_query,
                        SocialProtocol.profile_response: _build_profile_response,
                        SocialProtocol.connection_request: _build_connection_request,
                        SocialProtocol.connection_response: _build_connection_response,
                        SocialProtocol.dm: _build_dm,
                        SocialProtocol.post: _build_post,
                        SocialProtocol.business_ad: _build_business_ad,
                        SocialProtocol.business_post: _build_business_post,
                        SocialProtocol.reaction: _build_reaction,
                        SocialProtocol.report: _build_report,
                        SocialProtocol.cosign_request: _build_cosign_request,
                        SocialProtocol.cosign_sig: _build_cosign_sig,
                        }
    STATE_CHECKS = {**IdentityAdapter.STATE_CHECKS,
                    'peer_position': _check_peer_position,
                    'peer_profile': _check_peer_profile,
                    'peer_proximity': _check_peer_proximity,
                    'business_page': _check_business_page,
                    'customer_satisfaction': _check_customer_satisfaction,
                    'business_ads_emitted': _check_business_ads_emitted,
                    'business_post_last': _check_business_post_last,
                    'business_posts_emitted': _check_business_posts_emitted,
                    'connection_state': _check_connection_state,
                    'dm_last': _check_dm_last,
                    'post_last': _check_post_last,
                    'cosign_request_last': _check_cosign_request_last,
                    'cosign_sig_last': _check_cosign_sig_last,
                    'social_tx_last': _check_social_tx_last,
                    'position_responses_emitted': _check_position_responses_emitted,
                    'profile_responses_emitted': _check_profile_responses_emitted,
                    'proximity_probes_emitted': _check_proximity_probes_emitted,
                    'proximity_replies_emitted': _check_proximity_replies_emitted,
                    }

    def _run_proximity_probe(self, initiator: _Participant,
                             target: _Participant) -> None:
        """One private-proximity probe (Phase 2), end to end, inside the harness.

        The band is not a value a step can supply: each side derives keyed grid
        tags from its own opt-in exact position and the pairwise box secret, and
        the two only learn a band by INTERSECTING tag sets. So the harness drives
        the real chain of three handlers rather than pre-baking a payload:

          1. a local proximity_trigger on the initiator -> emits an encrypted
             probe ({salt, tags}) addressed to the target;
          2. the target's handle_proximity_probe records its band and, if it too
             opted in, replies with its own tags under the same salt;
          3. the initiator's handle_proximity_reply records the same band.

        Either side opting out short-circuits: an opted-out initiator emits no
        probe (nothing to compare), an opted-out target records UNKNOWN and sends
        no reply. The emit tallies (proximity_probes/replies_emitted) and the
        recorded bands (peer_proximity) are what the scenario asserts. C reaches
        the identical outcome through identity_request_proximity + its two
        directed handlers.
        """
        # Local IPC trigger on the initiator, naming the target by uuid exactly
        # as the app's AT_APP_REQUEST_PROXIMITY would.
        trig = Message(CfgIds.identity, SocialProtocol.proximity_trigger,
                       to_json_string({'target': str(target.identity.uuid)}),
                       from_whom=initiator.identity)
        initiator.process.protocol.run_message_handlers(initiator.queues, trig)
        probes = [c for c in initiator.drain_outbox()
                  if c.function == SocialProtocol.proximity_probe]
        if not probes:
            return  # initiator opted out: no probe, no band on either side
        # Deliver the encrypted probe to the target: it computes and records its
        # band, and replies with its own tags if it opted in too.
        target.process.protocol.run_message_handlers(target.queues,
                                                      probes[0].raw)
        replies = [c for c in target.drain_outbox()
                   if c.function == SocialProtocol.proximity_reply]
        if not replies:
            return  # target opted out: it surfaced UNKNOWN and sent nothing back
        # Deliver the reply to the initiator: it recomputes under the echoed salt
        # and records the same band.
        initiator.process.protocol.run_message_handlers(initiator.queues,
                                                        replies[0].raw)
        initiator.drain_outbox()
