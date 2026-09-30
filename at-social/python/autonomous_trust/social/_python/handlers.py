# ******************
#  Copyright 2023 TekFive, Inc., Sean M. Brennan, and contributors
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
"""The social feature's handlers and state operations on the identity process.

Moved verbatim from IdentityProcess (FEATURE_SPLIT_PLAN Phase 5): each method
is a module function taking the process as ``proc``; the feature's own state is
``proc.social`` (``state.SocialState``) and everything else still lives on the
process. The Python twin of src/c/extensions/social/id_social.c; see
extensions.md, "Social".
"""
import os
import time
from queue import Full
from . import proximity
from .social_store import (social_store_load, social_store_load_communities,
                           social_store_save)
from autonomous_trust.core._python.config import to_json_string, from_json_string
from autonomous_trust.core._python.network import Message
from .protocol import SocialProtocol
from autonomous_trust.core._python.system import CfgIds


# ------------------------------------------------------------------
# Opt-in coarse position (Increment 2, the "with-distance" feature).
#
# Twin of the C block in id_social.c (handle_position_query/_response,
# _send_position_query). Mirrors the caps directed exchange above: a node
# shares its own coarse geohash bucket ONLY with admitted peers that ask,
# over a freshness-stamped, group-encrypted {'pos','seq'} response. STRICTLY
# OPT-IN: ``own_geohash`` is empty by default, and while empty
# ``handle_position_query`` answers nothing — no geographic datum leaves the
# node. The geohash is opaque here (the app decodes it and computes
# distance); a received one is untrusted peer input, charset- and
# length-validated on the way in. The app-facing surface (set/clear own
# position over IPC, and the PEER_POSITION_OBSERVED app event) is C-only —
# the app-events carrier is C (SOCIAL_APP_PLAN.md §5.1); a Python node sets
# its own position only via $AT_OWN_GEOHASH, the same headless seed C uses.
# ------------------------------------------------------------------

#: Max geohash length carried on the wire. MUST match C AT_GEOHASH_MAX_LEN
#: (msg_types.h): a ~5-char geohash is the ~5km "neighborhood" bucket; the
#: bound allows finer precision later without a wire change.
_GEOHASH_MAX_LEN = 12

def _geohash_valid(s) -> bool:
    """True iff `s` is a non-empty, length-bounded geohash base32 string.

    Base32 alphabet is 0-9 plus b-z excluding a/i/l/o (the geohash
    alphabet). Validation only — the string is never decoded here. Mirrors
    C ``_geohash_valid``; a peer's geohash is untrusted, so this gates it on
    the way in exactly as the C twin does.
    """
    if not isinstance(s, str):
        return False
    n = len(s)
    if n == 0 or n > _GEOHASH_MAX_LEN:
        return False
    for c in s:
        if not (('0' <= c <= '9')
                or ('b' <= c <= 'z' and c not in ('i', 'l', 'o'))):
            return False
    return True

def _send_position_query(proc, queues, peer):
    """Ask `peer` directly for its coarse position (mirrors
    ``_send_caps_query`` and C ``_send_position_query``).

    Sent to a confirmed peer over the reliable group/TCP channel, so it is
    group-encrypted like caps_query — NOT a plaintext pre-admission verb,
    hence not in ``UNENCRYPTED_VERBS``. Fire-and-forget: an opted-out or
    unreachable peer simply yields no response, and the resync sweep re-asks.
    """
    try:
        message = Message(proc.name, SocialProtocol.position_query,
                          '', to_whom=peer)
        queues[CfgIds.network].put(message, block=True,
                                   timeout=proc.q_cadence)
    except Full:
        proc.logger.error('_send_position_query: Network queue full')

def handle_position_query(proc, queues, message):
    """Respond to a peer's position_query with our own coarse position —
    but ONLY if the operator opted in. Empty ``own_geohash`` (the default)
    answers nothing, so no position is ever disclosed unbidden."""
    if message.function != SocialProtocol.position_query:
        return False
    sender = getattr(message, 'from_whom', None)
    if sender is None:
        return True
    with proc.lock:
        own = proc.social.own_geohash
    if not own:
        proc.logger.debug(
            'position_query from %s; opted out, no answer',
            str(getattr(sender, 'uuid', ''))[:8])
        return True   # opted out: share nothing
    try:
        # Envelope {pos, seq}: stamped so a captured response cannot be
        # replayed (freshness.accept refuses a non-increasing seq), matching
        # the caps_response contract and the C handler.
        payload = to_json_string({'pos': own,
                                  'seq': proc.freshness.stamp()})
        reply = Message(proc.name, SocialProtocol.position_response,
                        payload, to_whom=sender)
        queues[CfgIds.network].put(reply, block=True,
                                   timeout=proc.q_cadence)
    except Full:
        proc.logger.error('handle_position_query: Network queue full')
    except Exception as err:
        proc.report_exception(err, 'handle_position_query')
    return True

def handle_position_response(proc, queues, message):
    """Record a peer's coarse position from a {'pos','seq'} response:
    freshness-checked (replay-refused) and geohash-validated, then stored in
    ``proc.social.peer_positions`` keyed by the sender's uuid string.

    No app emission here — surfacing to the app (PEER_POSITION_OBSERVED) is
    the C runtime's job; a Python node only maintains the peer map, which is
    the conformance-observable surface (``get_peer_position``)."""
    if message.function != SocialProtocol.position_response:
        return False
    sender = getattr(message, 'from_whom', None)
    if sender is None:
        return True
    try:
        body = from_json_string(message.obj)
        if not isinstance(body, dict):
            return True
        # Unstamped/replayed is refused, not accepted as legacy — same rule
        # as caps_response (doc/architecture/reputation.md).
        if not proc.freshness.accept(str(getattr(sender, 'uuid', None)),
                                     SocialProtocol.position_response,
                                     body.get('seq')):
            proc.logger.debug(
                'position_response from %s refused (replay/unstamped)',
                str(getattr(sender, 'uuid', ''))[:8])
            return True
        pos = body.get('pos')
        if not _geohash_valid(pos):
            proc.logger.warning(
                'position_response from %s: invalid geohash, dropping',
                str(getattr(sender, 'uuid', ''))[:8])
            return True
        with proc.lock:
            proc.social.peer_positions[str(sender.uuid)] = pos
        proc.logger.debug('recorded position for peer %s',
                          str(sender.uuid)[:8])
    except Exception as err:
        proc.report_exception(err, 'handle_position_response')
    return True

def get_peer_position(proc, uuid_str):
    """The stored coarse geohash for a peer uuid, or '' if none recorded.
    Conformance/assertion surface; twin of C ``identity_get_peer_position``."""
    with proc.lock:
        return proc.social.peer_positions.get(str(uuid_str), '')

# ------------------------------------------------------------------
# Private proximity (Phase 2): two CONNECTED peers learn a coarse distance
# BAND (near / mid / far) without revealing coordinates. Twin of the C block
# in id_social.c (handle_request_proximity / handle_proximity_probe /
# handle_proximity_reply). The tag math lives in proximity.py and is a
# byte-identical cross-language contract with proximity.c.
#
# STRICTLY OPT-IN and LOCAL-ONLY: own_exact (set via $AT_OWN_EXACT here, the
# app IPC set-path being C-only) never leaves this node — it feeds only the
# pairwise keyed tags. Unlike the position/profile exchange there is NO
# freshness/seq: the per-probe random salt is the anti-replay, so a captured
# {salt, tags} reveals nothing and re-injecting it recomputes the same band.
# As with position, the app-facing PEER_PROXIMITY_OBSERVED emit is the C
# runtime's job; a Python node maintains peer_proximity (the conformance
# surface, get_peer_proximity, twin of the C emit's recorded band).
# proximity_trigger is a LOCAL-ONLY IPC verb (twin of attest_trigger): a
# consumer asks us to probe one connected peer.
# ------------------------------------------------------------------

def _proximity_peer_connected(proc, uuid_str):
    """True iff we hold a CONNECTED edge toward the peer (Increment 5).
    Proximity only ever runs against a peer both sides consented to
    connect with; twin of C ``_proximity_peer_connected``."""
    from .codec import CONN_CONNECTED
    return get_connection_state(proc, uuid_str) == CONN_CONNECTED

def _proximity_own_tags(proc, peer, salt):
    """This node's proximity tag set toward ``peer`` under ``salt``, from our
    opt-in exact position and the pairwise box secret (beforenm over our
    X25519 secret and the peer's public key). Returns the tag list, or None
    if we opted out (no exact position) or key/tag derivation fails. The
    exact position never leaves here. Twin of C ``_proximity_own_tags``."""
    with proc.lock:
        own = proc.social.own_exact
    if own is None:
        return None
    lat, lon = own
    try:
        key = proximity.derive_key(peer.encryptor.public,
                                   proc.identity.encryptor.private)
        return proximity.compute_tags(lat, lon, key, salt)
    except Exception as err:
        proc.report_exception(err, '_proximity_own_tags')
        return None

def _send_proximity_msg(proc, queues, peer, verb, salt, tags):
    """Send a directed, ENCRYPTED proximity message ({salt, tags}) to ``peer``
    under ``verb`` (proximity_probe or proximity_reply). Twin of C
    ``_send_proximity_msg``."""
    try:
        payload = to_json_string({'salt': salt.hex(),
                                  'tags': proximity.tags_to_hex(tags)})
        out = Message(proc.name, verb, payload,
                      to_whom=peer, from_whom=proc.identity, encrypt=True)
        queues[CfgIds.network].put(out, block=True, timeout=proc.q_cadence)
    except Full:
        proc.logger.error('_send_proximity_msg: Network queue full')
    except Exception as err:
        proc.report_exception(err, '_send_proximity_msg')

def _proximity_parse(proc, message):
    """Parse {salt, tags} from a probe/reply body. Returns (salt_bytes,
    their_tags) on a well-formed message, else (None, None). Twin of C
    ``_proximity_parse``."""
    try:
        body = from_json_string(message.obj)
    except Exception:
        return None, None
    if not isinstance(body, dict):
        return None, None
    salt_hex = body.get('salt')
    if not isinstance(salt_hex, str):
        return None, None
    try:
        salt = bytes.fromhex(salt_hex)
    except (ValueError, TypeError):
        return None, None
    if len(salt) != proximity.SALT_LEN:
        return None, None
    their_tags = proximity.tags_from_hex(body.get('tags'))
    if their_tags is None:
        return None, None
    return salt, their_tags

def handle_proximity_trigger(proc, queues, message):
    """A consumer asked us to run a private-proximity probe against one
    CONNECTED peer. Local-only verb (never leaves this node); twin of C
    ``handle_request_proximity``. Payload {'target': '<uuid_str>'}."""
    if message.function != SocialProtocol.proximity_trigger:
        return False
    try:
        payload = message.obj
        if isinstance(payload, str):
            payload = from_json_string(payload)
        if not isinstance(payload, dict):
            return True
        target_uuid = payload.get('target')
        if not target_uuid:
            return True
        if not _proximity_peer_connected(proc, target_uuid):
            proc.logger.warning(
                'proximity_trigger: %s not connected; refusing',
                str(target_uuid)[:8])
            return True
        peer = None
        try:
            peer = proc.peers.find_by_uuid(str(target_uuid)) if proc.peers else None
        except Exception:
            peer = None
        if peer is None:
            return True
        salt = os.urandom(proximity.SALT_LEN)
        tags = _proximity_own_tags(proc, peer, salt)
        if tags is None:
            proc.logger.info(
                'proximity_trigger: no own exact position; opted out')
            return True
        _send_proximity_msg(proc, queues, peer,
                                 SocialProtocol.proximity_probe, salt, tags)
        proc.logger.debug('sent proximity probe to %s',
                          str(target_uuid)[:8])
    except Exception as err:
        proc.report_exception(err, 'handle_proximity_trigger')
    return True

def handle_proximity_probe(proc, queues, message):
    """Responder: a connected peer's proximity probe. Compute our band from
    our tags + theirs under the probe's salt, record it, and reply with our
    tags so the initiator learns the same band. Twin of C
    ``handle_proximity_probe``."""
    if message.function != SocialProtocol.proximity_probe:
        return False
    sender = getattr(message, 'from_whom', None)
    if sender is None:
        return True
    key = str(getattr(sender, 'uuid', None))
    if not _proximity_peer_connected(proc, key):
        proc.logger.debug(
            'proximity_probe from non-connected %s; ignoring', key[:8])
        return True
    try:
        salt, their_tags = _proximity_parse(proc, message)
        if salt is None:
            proc.logger.warning('malformed proximity_probe from %s', key[:8])
            return True
        our_tags = _proximity_own_tags(proc, sender, salt)
        if our_tags is None:
            # Opted out of exact position: cannot compute a band. Record
            # unknown for our side; do not reply (nothing to compare).
            with proc.lock:
                proc.social.peer_proximity[key] = int(proximity.ProxBand.UNKNOWN)
            return True
        band = proximity.band(our_tags, their_tags)
        with proc.lock:
            proc.social.peer_proximity[key] = int(band)
        _send_proximity_msg(proc, queues, sender,
                                 SocialProtocol.proximity_reply,
                                 salt, our_tags)
        proc.logger.debug('proximity band %d with %s (probe)',
                          int(band), key[:8])
    except Exception as err:
        proc.report_exception(err, 'handle_proximity_probe')
    return True

def handle_proximity_reply(proc, queues, message):
    """Initiator: the reply to our probe. Recompute our tags under the
    (echoed) salt, compare with theirs, record the band. Twin of C
    ``handle_proximity_reply``."""
    if message.function != SocialProtocol.proximity_reply:
        return False
    sender = getattr(message, 'from_whom', None)
    if sender is None:
        return True
    key = str(getattr(sender, 'uuid', None))
    if not _proximity_peer_connected(proc, key):
        return True
    try:
        salt, their_tags = _proximity_parse(proc, message)
        if salt is None:
            proc.logger.warning('malformed proximity_reply from %s', key[:8])
            return True
        our_tags = _proximity_own_tags(proc, sender, salt)
        if our_tags is None:
            with proc.lock:
                proc.social.peer_proximity[key] = int(proximity.ProxBand.UNKNOWN)
            return True
        band = proximity.band(our_tags, their_tags)
        with proc.lock:
            proc.social.peer_proximity[key] = int(band)
        proc.logger.debug('proximity band %d with %s (reply)',
                          int(band), key[:8])
    except Exception as err:
        proc.report_exception(err, 'handle_proximity_reply')
    return True

def get_peer_proximity(proc, uuid_str):
    """The last coarse distance band learned for a peer uuid, or UNKNOWN (0)
    if none. Conformance/assertion surface; twin of the C emit's recorded
    band (identity_emit_peer_proximity)."""
    with proc.lock:
        return proc.social.peer_proximity.get(str(uuid_str),
                                       int(proximity.ProxBand.UNKNOWN))

# ------------------------------------------------------------------
# Opt-in agora.profile (Increment 3): SIGNED directed exchange.
#
# Twin of the C block in id_social.c (handle_profile_query/_response,
# _send_profile_query). Same directed shape as the position exchange, plus a
# detached Ed25519 SIGNATURE over a canonical serialization of the profile
# (codec.profile_canonical) so a profile is self-verifying beyond the
# transport. STRICTLY OPT-IN: ``own_profile`` empty (the default) answers
# nothing. On receive the fields are bound-validated (an over-bound field is
# dropped, like an invalid geohash) and the signature verified against the
# SENDER's signing key before storing. As with position, the app-facing
# surface is C-only; a Python node maintains peer_profiles (the conformance
# surface, get_peer_profile) and sets its own via $AT_OWN_PROFILE.
# ------------------------------------------------------------------

def _send_profile_query(proc, queues, peer):
    """Ask `peer` directly for its agora.profile (mirrors
    ``_send_position_query`` and C ``_send_profile_query``)."""
    try:
        message = Message(proc.name, SocialProtocol.profile_query,
                          '', to_whom=peer)
        queues[CfgIds.network].put(message, block=True,
                                   timeout=proc.q_cadence)
    except Full:
        proc.logger.error('_send_profile_query: Network queue full')

def handle_profile_query(proc, queues, message):
    """Respond to a peer's profile_query with our own profile — but ONLY if
    the operator opted in. Empty ``own_profile`` (the default) answers
    nothing. The reply carries {profile, sig, seq}: the signature is computed
    fresh from our identity key over the canonical profile form."""
    if message.function != SocialProtocol.profile_query:
        return False
    sender = getattr(message, 'from_whom', None)
    if sender is None:
        return True
    with proc.lock:
        own = dict(proc.social.own_profile)
    if not own:
        proc.logger.debug(
            'profile_query from %s; opted out, no answer',
            str(getattr(sender, 'uuid', ''))[:8])
        return True   # opted out: share nothing
    try:
        from .codec import profile_sign
        sig = profile_sign(proc.identity.signature.private,
                           proc.identity.uuid, own)
        payload = to_json_string({'profile': own, 'sig': sig,
                                  'seq': proc.freshness.stamp()})
        reply = Message(proc.name, SocialProtocol.profile_response,
                        payload, to_whom=sender)
        queues[CfgIds.network].put(reply, block=True,
                                   timeout=proc.q_cadence)
    except Full:
        proc.logger.error('handle_profile_query: Network queue full')
    except Exception as err:
        proc.report_exception(err, 'handle_profile_query')
    return True

def handle_profile_response(proc, queues, message):
    """Record a peer's profile from a {'profile','sig','seq'} response:
    freshness-checked, bound-validated, and SIGNATURE-verified against the
    sender's signing key, then stored in ``proc.social.peer_profiles`` keyed by the
    sender's uuid string. No app emission here (C runtime's job)."""
    if message.function != SocialProtocol.profile_response:
        return False
    sender = getattr(message, 'from_whom', None)
    if sender is None:
        return True
    try:
        body = from_json_string(message.obj)
        if not isinstance(body, dict):
            return True
        if not proc.freshness.accept(str(getattr(sender, 'uuid', None)),
                                     SocialProtocol.profile_response,
                                     body.get('seq')):
            proc.logger.debug(
                'profile_response from %s refused (replay/unstamped)',
                str(getattr(sender, 'uuid', ''))[:8])
            return True
        profile = body.get('profile')
        sig = body.get('sig')
        if not isinstance(profile, dict) or not isinstance(sig, str):
            return True
        from .codec import profile_valid_bounded, profile_verify
        if not profile_valid_bounded(profile):
            proc.logger.warning(
                'profile_response from %s: over-bound/invalid field, dropping',
                str(getattr(sender, 'uuid', ''))[:8])
            return True
        if not profile_verify(sender.signature.public,
                              sender.uuid, profile, sig):
            proc.logger.warning(
                'profile_response from %s: BAD SIGNATURE, dropping',
                str(getattr(sender, 'uuid', ''))[:8])
            return True
        with proc.lock:
            proc.social.peer_profiles[str(sender.uuid)] = profile
        proc.logger.debug('recorded profile for peer %s',
                          str(sender.uuid)[:8])
    except Exception as err:
        proc.report_exception(err, 'handle_profile_response')
    return True

def get_peer_profile(proc, uuid_str):
    """The stored profile dict for a peer uuid, or {} if none recorded.
    Conformance/assertion surface; twin of C ``identity_get_peer_profile``."""
    with proc.lock:
        return dict(proc.social.peer_profiles.get(str(uuid_str), {}))

# ------------------------------------------------------------------
# Explicit connections (Increment 5): an EXPLICIT, revocable edge SEPARATE
# from reputation. Twin of the C block in id_social.c
# (handle_connection_request/_response). The request is a bare ask that sets
# our edge to pending_in; the response carries a detached Ed25519 SIGNATURE
# over the canonical (requester, accepter, decision, seq) form
# (codec.connection_canonical) so a captured accept cannot be replayed
# or re-attributed. USER-INITIATED: nothing is auto-sent on confirm. The
# app-driven request/respond verbs and app-event emission are C-only; a
# Python node maintains the edge map (get_connection_state).
# ------------------------------------------------------------------

def handle_connection_request(proc, queues, message):
    """A peer asks to connect: set our edge toward it to pending_in (an
    already-connected edge is left alone; a re-ask is idempotent). No wire
    response — connections are user-initiated (the app decides)."""
    if message.function != SocialProtocol.connection_request:
        return False
    sender = getattr(message, 'from_whom', None)
    if sender is None:
        return True
    from .codec import CONN_CONNECTED, CONN_PENDING_IN
    key = str(getattr(sender, 'uuid', None))
    with proc.lock:
        # A blocked peer cannot ask (Phase 4 P4.1). DROPPED: letting it
        # through would move our edge to pending_in and put a decision in
        # front of the person who blocked them. CONN_DECLINED is re-askable
        # by design, so without this a blocked peer could ask forever.
        # The LOCKED predicate: proc.lock is held here. Twin of C.
        if _is_blocked_locked(proc, key):
            proc.logger.debug(
                'connection_request from %s dropped (locally blocked)',
                key[:8])
            return True
        if proc.social.connection_edges.get(key) == CONN_CONNECTED:
            return True
        proc.social.connection_edges[key] = CONN_PENDING_IN
    proc.logger.debug('connection request from peer %s', key[:8])
    return True

def handle_connection_response(proc, queues, message):
    """The accepter's answer to OUR request — {decision, sig, seq}:
    freshness-checked (replay-refused) and SIGNATURE-verified against the
    accepter's signing key over the canonical (requester=us, accepter=sender,
    decision, seq) form, then our edge is set connected/declined. No app
    emission here (C runtime's job)."""
    if message.function != SocialProtocol.connection_response:
        return False
    sender = getattr(message, 'from_whom', None)
    if sender is None:
        return True
    try:
        body = from_json_string(message.obj)
        if not isinstance(body, dict):
            return True
        decision = body.get('decision')
        sig = body.get('sig')
        if not isinstance(decision, int) or not isinstance(sig, str):
            return True
        if not proc.freshness.accept(str(getattr(sender, 'uuid', None)),
                                     SocialProtocol.connection_response,
                                     body.get('seq')):
            proc.logger.debug(
                'connection_response from %s refused (replay/unstamped)',
                str(getattr(sender, 'uuid', ''))[:8])
            return True
        from .codec import (connection_verify, CONN_CONNECTED,
                                    CONN_DECLINED)
        if not connection_verify(sender.signature.public,
                                 proc.identity.uuid, sender.uuid,
                                 1 if decision else 0, int(body.get('seq')),
                                 sig):
            proc.logger.warning(
                'connection_response from %s: BAD SIGNATURE, dropping',
                str(getattr(sender, 'uuid', ''))[:8])
            return True
        new_state = CONN_CONNECTED if decision else CONN_DECLINED
        with proc.lock:
            proc.social.connection_edges[str(sender.uuid)] = new_state
            # Increment 8 accrual (requester side): same signed {requester=us,
            # accepter=sender, decision, seq} tuple both peers hold, so the
            # order-independent task pairs the two submissions.
            _social_accrue_connection(proc, proc.identity.uuid, sender.uuid,
                                           int(body.get('seq')), bool(decision))
        proc.logger.debug('connection with peer %s -> %s',
                          str(sender.uuid)[:8],
                          'connected' if decision else 'declined')
    except Exception as err:
        proc.report_exception(err, 'handle_connection_response')
    return True

def get_connection_state(proc, uuid_str):
    """The connection edge state toward a peer uuid, or 0 (none) if no edge.
    Conformance/assertion surface; twin of C
    ``identity_get_connection_state``."""
    with proc.lock:
        return proc.social.connection_edges.get(str(uuid_str), 0)

# ------------------------------------------------------------------
# Direct messages (Increment 6): a single one-way, directed ENCRYPTED
# peer->peer text message carrying {text, seq, ts}. crypto_box authenticates
# the sender on the wire, so — UNLIKE the connection accept — there is NO
# signature. NO request/response, NO gossip, NO roster replay: delivered on
# arrival. Twin of the C block in id_social.c (handle_dm). The app-driven send
# verb and app-event emission are C-only; a Python node records the most
# recent DM per sender (get_last_dm) for the conformance observable.
# ------------------------------------------------------------------

def handle_dm(proc, queues, message):
    """An inbound directed DM from a peer — {text, seq, ts}: freshness-checked
    (per-sender replay guard), body bound-truncated, then recorded as the most
    recent DM from that sender. No app emission here (C runtime's job)."""
    if message.function != SocialProtocol.dm:
        return False
    sender = getattr(message, 'from_whom', None)
    if sender is None:
        return True
    try:
        body = from_json_string(message.obj)
        if not isinstance(body, dict):
            return True
        seq = body.get('seq')
        text = body.get('text')
        ts = body.get('ts')
        # seq must be an int and text a str; a stripped/mistyped field is
        # refused (the replay guard needs the seq), mirroring the C handler.
        if not isinstance(seq, int) or not isinstance(text, str) \
                or not isinstance(ts, (int, float)):
            proc.logger.warning('peer_dm unstamped/malformed, refusing')
            return True
        if not proc.freshness.accept(str(getattr(sender, 'uuid', None)),
                                     SocialProtocol.dm, seq):
            proc.logger.debug(
                'peer_dm from %s refused (replay/unstamped)',
                str(getattr(sender, 'uuid', ''))[:8])
            return True
        # A blocked peer cannot reach us (Phase 4 P4.1). DROPPED, not
        # hidden: a DM has no third party whose interest is served by our
        # keeping it. AFTER the freshness check, never before, or every DM
        # sent during a block replays the moment it is lifted. Twin of C
        # handle_dm's gate.
        if _is_blocked(proc, sender.uuid):
            proc.logger.debug('peer_dm from %s dropped (locally blocked)',
                              str(sender.uuid)[:8])
            return True
        from .codec import bound_dm_text
        with proc.lock:
            proc.social.last_dm[str(sender.uuid)] = {
                'seq': int(seq),
                'ts': float(ts),
                'text': bound_dm_text(text),
            }
            # Increment 8 accrual (inbound stamp; gated on bilateral recency).
            _social_accrue_dm(proc, sender.uuid, True)
        proc.logger.debug('DM received from peer %s',
                          str(sender.uuid)[:8])
    except Exception as err:
        proc.report_exception(err, 'handle_dm')
    return True

def get_last_dm(proc, uuid_str):
    """The most-recent DM received from a peer uuid, as {'seq','ts','text'},
    or {} if none. Conformance/assertion surface; twin of C
    ``identity_get_last_dm``."""
    with proc.lock:
        return dict(proc.social.last_dm.get(str(uuid_str), {}))

# ------------------------------------------------------------------
# Social-interaction reputation accrual (Increment 8). Mirrors the C block in
# id_social.c: a qualifying interaction stages a diminishing S_pos(count) score
# for the SAME bilateral task both peers derive (codec.social_task_uuid),
# so a commit — and the reputation move it carries — happens only when both
# take part. Here, the conformance twin, we record the staged score as the
# deterministic observable (get_last_social_tx); the real Paxos round and the
# PEER_REPUTATION emit are the C runtime's job. The caller holds proc.lock.
# ------------------------------------------------------------------

def _now():
    import time as _time
    return float(int(_time.time()))

def _social_edge(proc, key):
    return proc.social.social_edges.get(
        key, {'count': 0, 'last_out': 0, 'last_in': 0, 'day': 0, 'day_count': 0})

def _social_stamp(proc, key, inbound, now):
    e = dict(_social_edge(proc, key))
    if inbound:
        e['last_in'] = now
    else:
        e['last_out'] = now
    proc.social.social_edges[key] = e

def _social_accrue(proc, key, now, require_bilateral):
    """Decide whether to accrue for an interaction with peer ``key`` now; on a
    yes, bump the edge + daily counters and return the 1-based interaction count
    to score with, else None. Twin of C ``_social_accrue``."""
    from .codec import (SOCIAL_RECENCY_WINDOW, SOCIAL_DAY_SECONDS,
                                SOCIAL_PER_EDGE_DAILY_CAP,
                                SOCIAL_GLOBAL_DAILY_CAP)
    # A blocked peer accrues nothing with us (Phase 4 P4.1). Gated HERE
    # because every positive path funnels through this function, so one
    # gate covers DMs, reactions and connections at once. Reputation is
    # BILATERAL and we have told them nothing -- a block is purely local --
    # so our half could never pair and would sit in the chain forever.
    # Twin of C _social_accrue's gate. The LOCKED form: this runs with
    # proc.lock already held.
    if _is_blocked_locked(proc, key):
        return None
    e = dict(_social_edge(proc, key))
    if require_bilateral:
        w = SOCIAL_RECENCY_WINDOW
        recent = (e['last_out'] > 0 and e['last_in'] > 0
                  and (now - e['last_out']) < w and (now - e['last_in']) < w)
        if not recent:
            return None
    today = int(now // SOCIAL_DAY_SECONDS)
    if e['day'] != today:
        e['day'] = today
        e['day_count'] = 0
    if proc.social._social_day != today:
        proc.social._social_day = today
        proc.social._social_day_count = 0
    if (e['day_count'] >= SOCIAL_PER_EDGE_DAILY_CAP
            or proc.social._social_day_count >= SOCIAL_GLOBAL_DAILY_CAP):
        return None
    e['count'] += 1
    e['day_count'] += 1
    proc.social._social_day_count += 1
    proc.social.social_edges[key] = e
    return e['count']

def _social_record_tx(proc, task, subject_key, score, channel=None):
    """Record a staged score as the observable. ``channel`` None is absent,
    which resolves to the default channel -- as C records it. Twin of the
    observed-record half of C ``_submit_interaction_score``."""
    from autonomous_trust.core._python.reputation.reputation import TX_CHANNEL_DEFAULT
    prev = proc.social.social_tx_last.get(subject_key, {})
    proc.social.social_tx_last[subject_key] = {
        'task': str(task), 'score': float(score),
        'channel': channel if channel is not None else TX_CHANNEL_DEFAULT,
        'n': int(prev.get('n', 0)) + 1}

def _social_accrue_connection(proc, self_uuid, peer_uuid, seq, connected):
    """Connected => diminishing positive (structurally bilateral, caps only);
    declined => the in-model bilateral negative. Twin of C
    ``_social_accrue_connection``."""
    from .codec import (social_task_uuid, social_pos_score,
                                SOCIAL_DOMAIN_CONN, SOCIAL_NEG_SCORE)
    task = social_task_uuid(SOCIAL_DOMAIN_CONN, self_uuid, peer_uuid,
                            int(seq).to_bytes(8, 'little'))
    key = str(peer_uuid)
    # Gated separately from _social_accrue because the DECLINE branch below
    # bypasses it entirely and records SOCIAL_NEG_SCORE unconditionally.
    # Blocking someone and then declining them must not still cost them
    # 0.30: a block is not a way to grind a peer down, and the submission
    # could never pair anyway. Twin of C _social_accrue_connection's gate.
    # The LOCKED form: this runs with proc.lock already held.
    if _is_blocked_locked(proc, key):
        return
    if connected:
        count = _social_accrue(proc, key, _now(), False)
        if count is not None:
            _social_record_tx(proc, task, key, social_pos_score(count))
    else:
        _social_record_tx(proc, task, key, SOCIAL_NEG_SCORE)

def _social_accrue_dm(proc, peer_uuid, inbound):
    """A single DM is one-directional, so accrual is gated on BOTH directions
    inside the recency window; both peers key the transaction to the same
    hourly bucket. Twin of C ``_social_accrue_dm``."""
    from .codec import (social_task_uuid, social_pos_score,
                                SOCIAL_DOMAIN_DM, SOCIAL_DM_BUCKET_SECONDS)
    now = _now()
    key = str(peer_uuid)
    _social_stamp(proc, key, inbound, now)
    bucket = int(now // SOCIAL_DM_BUCKET_SECONDS)
    task = social_task_uuid(SOCIAL_DOMAIN_DM, proc.identity.uuid, peer_uuid,
                            int(bucket).to_bytes(8, 'little'))
    count = _social_accrue(proc, key, now, True)
    if count is not None:
        _social_record_tx(proc, task, key, social_pos_score(count))

def _social_accrue_reaction(proc, self_uuid, peer_uuid, post_id_hex):
    """A reaction is structurally bilateral (the message itself makes both
    submit), so no recency gate — caps only. Twin of C
    ``_social_accrue_reaction``."""
    from .codec import (social_task_uuid, social_pos_score,
                                SOCIAL_DOMAIN_POST)
    try:
        tail = bytes.fromhex(post_id_hex[:32])
    except (ValueError, TypeError):
        return
    if len(tail) != 16:
        return
    task = social_task_uuid(SOCIAL_DOMAIN_POST, self_uuid, peer_uuid, tail)
    key = str(peer_uuid)
    count = _social_accrue(proc, key, _now(), False)
    if count is not None:
        _social_record_tx(proc, task, key, social_pos_score(count))

# ------------------------------------------------------------------
# First-person reports (Phase 4 P4.1). Twin of the C block in id_social.c: a
# report is an INTERACTION OUTCOME, so a low scalar through the ordinary
# bilateral transaction on the first_person channel -- never an authority
# finding, which is a ceiling. The reporter stages SOCIAL_REPORT_SCORE, the
# reported node SOCIAL_REPORTER_SCORE about the reporter, on one task both
# derive. Refusable by construction: a forked reported node need not stage.
# ------------------------------------------------------------------

def _social_report_ledger(proc, key, today):
    """(out, in) for ``key`` today; an earlier day reads as zeros. Caller
    holds proc.lock. Twin of C ``_social_report_get_locked``."""
    r = proc.social.social_reports.get(key)
    if not r or r.get('day') != today:
        return 0, 0
    return int(r.get('out', 0)), int(r.get('in', 0))

def _social_report_outbound(proc, key, now, spend):
    """May we report ``key`` now, and (``spend``) record that we did? The
    report cap, then the SHARED per-edge and global budget, which a report
    spends. NOT gated by the block. Caller holds proc.lock. Twin of C
    ``_social_report_outbound`` -- see there for why each bound is shaped
    as it is."""
    from .codec import (SOCIAL_DAY_SECONDS, SOCIAL_PER_EDGE_DAILY_CAP,
                                SOCIAL_GLOBAL_DAILY_CAP,
                                SOCIAL_REPORT_DAILY_CAP)
    today = int(now // SOCIAL_DAY_SECONDS)
    out_n, in_n = _social_report_ledger(proc, key, today)
    e = dict(_social_edge(proc, key))
    if e['day'] != today:
        e['day'] = today
        e['day_count'] = 0
    glob = proc.social._social_day_count if proc.social._social_day == today else 0
    if (out_n >= SOCIAL_REPORT_DAILY_CAP
            or e['day_count'] >= SOCIAL_PER_EDGE_DAILY_CAP
            or glob >= SOCIAL_GLOBAL_DAILY_CAP):
        return False
    if spend:
        proc.social.social_reports[key] = {'day': today, 'out': out_n + 1,
                                    'in': in_n}
        e['count'] += 1
        e['day_count'] += 1
        proc.social.social_edges[key] = e
        proc.social._social_day = today
        proc.social._social_day_count = glob + 1
    return True

def _social_report_inbound(proc, key, now):
    """Pair at most SOCIAL_REPORT_DAILY_CAP reports from ``key`` per day,
    recording this one when it fits. NOT charged to our shared budget, or a
    busy node would be unreportable. Caller holds proc.lock. Twin of C
    ``_social_report_inbound``."""
    from .codec import SOCIAL_DAY_SECONDS, SOCIAL_REPORT_DAILY_CAP
    today = int(now // SOCIAL_DAY_SECONDS)
    out_n, in_n = _social_report_ledger(proc, key, today)
    if in_n >= SOCIAL_REPORT_DAILY_CAP:
        return False
    proc.social.social_reports[key] = {'day': today, 'out': out_n, 'in': in_n + 1}
    return True

def _social_report_task(reporter_uuid, reported_uuid, seq):
    """The shared report task: reporter_uuid[16] || seq u64le as the tail.
    Twin of C ``_social_report_task``."""
    from .codec import (social_task_uuid, SOCIAL_DOMAIN_REPORT,
                                _uuid16)
    tail = _uuid16(reporter_uuid) + int(seq).to_bytes(8, 'little')
    return social_task_uuid(SOCIAL_DOMAIN_REPORT, reporter_uuid,
                            reported_uuid, tail)

def report_peer(proc, queues, peer_uuid):
    """The operator reports a peer: send a directed encrypted peer_report
    {seq, ts} and, ONLY IF IT WENT, stage SOCIAL_REPORT_SCORE about them on
    the first_person channel. Twin of C ``handle_app_report_peer``. No
    reason is accepted, so none can travel.

    Returns True when the report was sent and staged, False when it was
    refused (unknown peer, cap reached) or could not be sent.
    """
    from .codec import SOCIAL_REPORT_SCORE
    from autonomous_trust.core._python.reputation.reputation import TX_CHANNEL_FIRST_PERSON
    key = str(peer_uuid)
    peer = None
    try:
        peer = proc.peers.find_by_uuid(key) if proc.peers else None
    except Exception:
        peer = None
    if peer is None:
        proc.logger.warning('report_peer: unknown peer %s', key[:8])
        return False
    now = _now()
    # Checked BEFORE the frame goes and spent only AFTER it went: a refused
    # report must never reach the wire, or the reported node stages a half
    # we will never match.
    with proc.lock:
        if not _social_report_outbound(proc, key, now, False):
            proc.logger.info('report of %s refused: daily report or '
                             'accrual cap reached', key[:8])
            return False
    seq = proc.freshness.stamp()
    try:
        out = Message(proc.name, SocialProtocol.report,
                      to_json_string({'seq': int(seq),
                                      'ts': float(time.time())}),
                      to_whom=peer, from_whom=proc.identity, encrypt=True)
        queues[CfgIds.network].put(out, block=True, timeout=proc.q_cadence)
    except Full:
        proc.logger.warning('report of %s was not sent; not scoring it',
                            key[:8])
        return False
    task = _social_report_task(proc.identity.uuid, peer_uuid, seq)
    with proc.lock:
        _social_report_outbound(proc, key, now, True)
        _social_record_tx(proc, task, key, SOCIAL_REPORT_SCORE,
                               TX_CHANNEL_FIRST_PERSON)
    proc.logger.info('reported peer %s', key[:8])
    return True

def handle_peer_report(proc, queues, message):
    """A peer reported US -- {seq, ts}. Freshness-checked, dropped if we
    blocked the reporter, capped per reporter per day, then our half is
    staged so the report can commit. NOTHING reaches the app: the person
    reported is not told. Twin of C ``handle_peer_report``."""
    if message.function != SocialProtocol.report:
        return False
    sender = getattr(message, 'from_whom', None)
    if sender is None:
        return True
    try:
        from .codec import SOCIAL_REPORTER_SCORE
        body = from_json_string(message.obj)
        seq = body.get('seq') if isinstance(body, dict) else None
        if not isinstance(seq, int) or isinstance(seq, bool):
            proc.logger.warning('peer_report unstamped/malformed, refusing')
            return True
        key = str(getattr(sender, 'uuid', ''))
        if not proc.freshness.accept(key, SocialProtocol.report, seq):
            proc.logger.debug('peer_report from %s refused (replay)',
                              key[:8])
            return True
        # Directed traffic from a blocked peer is DROPPED, after the
        # freshness window advances. Their report then never pairs.
        if _is_blocked(proc, sender.uuid):
            proc.logger.debug('peer_report from %s dropped (locally '
                              'blocked)', key[:8])
            return True
        task = _social_report_task(sender.uuid, proc.identity.uuid, seq)
        with proc.lock:
            if not _social_report_inbound(proc, key, _now()):
                proc.logger.info('peer_report from %s refused: daily '
                                 'report cap', key[:8])
                return True
            _social_record_tx(proc, task, key, SOCIAL_REPORTER_SCORE)
        proc.logger.debug('report from peer %s staged', key[:8])
    except Exception as err:
        proc.report_exception(err, 'handle_peer_report')
    return True

def get_last_social_tx(proc, uuid_str):
    """The last interaction score this node STAGED about subject ``uuid_str``
    (Increment 8), as {'task','score'}, or {} if none. The deterministic
    accrual observable; twin of C ``identity_get_last_social_tx``."""
    with proc.lock:
        return dict(proc.social.social_tx_last.get(str(uuid_str), {}))

def block_peer(proc, uuid_str):
    """Locally block a peer (Increment 8): record it so ``get_peer_tier``
    clamps its tier to 0 for our own tier-gates. App-driven and PURELY LOCAL
    — nothing on the wire, no reputation transaction. Twin of C
    ``handle_app_block`` / ``identity_block_peer`` (id_social.c)."""
    with proc.lock:
        proc.social.social_blocks[str(uuid_str)] = float(int(time.time()))
    _persist_social_blocks(proc)


def _persist_social_blocks(proc, cfg_dir=None):
    """Write the block set to ``etc/at/social.cfg.json`` (Phase 4 P4.1).

    On every mutation, not at shutdown, matching C: a block that survives
    only a graceful stop is not much of a block. Failure is logged, never
    raised -- losing durability must not take moderation itself down, and
    the operator needs to know the file is not being written rather than
    discovering it after a restart.
    """
    try:
        from autonomous_trust.core._python.config.configuration import Configuration
        # The blocks AND the followed communities (Phase 4): one document, so
        # saving either writes both, or a block would forget every follow.
        social_store_save(
            dict(proc.social.social_blocks),
            cfg_dir if cfg_dir is not None else Configuration.get_cfg_dir(),
            communities=dict(proc.social.communities))
        return True
    except (OSError, IOError, ValueError) as err:
        proc.logger.warning('Could not persist social blocks: %s', err)
        return False

def load_social_blocks(proc, cfg_dir=None):
    """Restore the block set from disk. Twin of the C load at identity
    start-up, which runs BEFORE the node takes traffic: a block that only
    took effect once the app reconnected would leave a window in which the
    blocked peer's messages land."""
    try:
        from autonomous_trust.core._python.config.configuration import Configuration
        where = cfg_dir if cfg_dir is not None else Configuration.get_cfg_dir()
        restored = social_store_load(where)
        follows = social_store_load_communities(where)
    except (OSError, IOError, ValueError) as err:
        proc.logger.warning(
            'social blocks unreadable (%s) — starting with NO blocks; the '
            'operator\'s moderation state is gone, not partially applied',
            err)
        return 0
    with proc.lock:
        proc.social.social_blocks = dict(restored)
        proc.social.communities = dict(follows)
        return len(proc.social.social_blocks)

def reload_social_blocks(proc, cfg_dir=None):
    """Save the block set and load it back -- the round trip a restart
    performs, without needing one. Twin of C
    ``identity_reload_social_blocks``. A test that checked only the
    in-memory dict would pass with no file written at all.

    `cfg_dir` is where to write; None means the process's own config
    directory. A conformance step passes a writable temp dir, because the
    harness's default root may not be writable -- without which this seam
    would prove nothing while appearing to pass.

    IF THE SAVE FAILED, DO NOT LOAD. `social_store_load` REPLACES the set,
    so a failed write followed by a read of the file that is not there would
    empty it -- turning an unwritable config directory into a silent mass
    unblock.
    """
    if not _persist_social_blocks(proc, cfg_dir):
        return len(proc.social.social_blocks)
    return load_social_blocks(proc, cfg_dir)

def unblock_peer(proc, uuid_str):
    """Lift a local block (Phase 4 P4.1). Twin of C ``identity_unblock_peer``
    / ``handle_app_unblock``.

    A DISCARD, not a second flag: "blocked" IS membership of the set, so
    the record and the predicate cannot disagree and re-blocking is
    idempotent. The peer is told nothing, exactly as they were told nothing
    about the block. What they sent while blocked is gone — the inbound
    gates dropped it rather than queueing it — so an unblock restores reach
    going forward and does not replay the silence.
    """
    with proc.lock:
        proc.social.social_blocks.pop(str(uuid_str), None)
    _persist_social_blocks(proc)

def is_blocked(proc, uuid_str):
    """Conformance/observability read-back. Twin of C
    ``identity_is_blocked``."""
    with proc.lock:
        return _is_blocked_locked(proc, uuid_str)

def _is_blocked_locked(proc, uuid_str):
    """THE one place that reads social_blocks (Phase 4 P4.1). THE CALLER
    MUST HOLD ``proc.lock``. Twin of C ``_is_blocked_locked``.

    Until P4.1 the block was read only by ``get_peer_tier``, and that clamp
    was mistaken for the whole of what a block does. It is not: a block is
    a REFUSAL and a tier is a MEASUREMENT, and the clamp expresses the
    refusal only where a tier floor happens to be above zero -- which is
    why a blocked peer's PUBLIC posts (floor 0), DMs (no floor at all) and
    reactions all sailed through on both runtimes.
    """
    return str(uuid_str) in proc.social.social_blocks

def _is_blocked(proc, uuid_str):
    """Lock-taking wrapper, for handlers that hold nothing.

    The split is not decoration: ``proc.lock`` is a plain
    ``threading.Lock``, NOT an RLock, and the accrual helpers run with it
    already held (see the section comment above ``_social_edge``). Calling
    the wrapper from there would deadlock the identity process outright.
    Mirrors the same split in C.
    """
    with proc.lock:
        return _is_blocked_locked(proc, uuid_str)


def handle_reaction(proc, queues, message):
    """An inbound reaction to one of OUR posts — {post_id, seq, ts}:
    freshness-checked (per-sender replay guard), then accrued (author side).
    No app emission here (C runtime's job)."""
    if message.function != SocialProtocol.reaction:
        return False
    sender = getattr(message, 'from_whom', None)
    if sender is None:
        return True
    try:
        body = from_json_string(message.obj)
        if not isinstance(body, dict):
            return True
        post_id = body.get('post_id')
        seq = body.get('seq')
        if not isinstance(post_id, str) or not isinstance(seq, int):
            proc.logger.warning('peer_reaction unstamped/malformed, refusing')
            return True
        if not proc.freshness.accept(str(getattr(sender, 'uuid', None)),
                                     SocialProtocol.reaction, seq):
            proc.logger.debug('peer_reaction from %s refused (replay)',
                              str(getattr(sender, 'uuid', ''))[:8])
            return True
        # A blocked peer cannot reach us (Phase 4 P4.1). DROPPED after the
        # freshness window advances, for the reason handle_dm gives. This
        # path ACCRUED REPUTATION for a blocked peer before P4.1. Twin of C
        # handle_reaction's gate.
        if _is_blocked(proc, sender.uuid):
            proc.logger.debug(
                'peer_reaction from %s dropped (locally blocked)',
                str(sender.uuid)[:8])
            return True
        with proc.lock:
            _social_accrue_reaction(proc, proc.identity.uuid, sender.uuid,
                                         post_id)
        proc.logger.debug('reaction received from peer %s',
                          str(sender.uuid)[:8])
    except Exception as err:
        proc.report_exception(err, 'handle_reaction')
    return True

# ------------------------------------------------------------------
# Feed posts (Increment 7): a signed, content-addressed feed item distributed
# by encrypted GROUP MULTICAST and gossip-forwarded a bounded number of hops.
# UNLIKE a DM, a post is relayed by peers other than its author, so authorship
# comes from a detached Ed25519 signature over the canonical (author, seq, ts,
# required_tier, body) form (codec.post_*), verified before the tier-
# gate/content-id dedup/emit. Twin of the C block in id_social.c (handle_post).
# The app-driven publish verb and app-event emission are C-only; a Python node
# records the most recent post per author (get_last_post) for the conformance
# observable. Re-multicast (gossip) has no wire in the harness, so — like the C
# node's effective no-op there — it is omitted; parity is on the observable.
# ------------------------------------------------------------------

def handle_post(proc, queues, message):
    """An inbound group-multicast feed post. Verify the author's Ed25519
    signature (for a KNOWN peer the carried author_pk MUST match the stored
    signing key — impersonation guard; an unknown author is verified against
    the carried key, best-effort one-hop), tier-gate against this node's view
    of the author's tier, content-id dedup, then record it. Twin of the C
    handle_post."""
    if message.function != SocialProtocol.post:
        return False
    try:
        body = from_json_string(message.obj)
    except Exception as err:
        proc.report_exception(err, 'handle_post')
        return True
    return _ingest_post(proc, queues, body, True)


def _ingest_post(proc, queues, body, via_group):
    """The one inbound path for a feed post: the group multicast
    (``handle_post``, ``via_group`` True) or a directed backfill
    (``handle_post_backfill``, False). Python records no co-membership from a
    post and never relays one, so the flag changes nothing here but the log;
    it is kept for parity with C ``_ingest_post``, where it gates both."""
    try:
        if not isinstance(body, dict):
            return True
        author = body.get('author')
        author_pk = body.get('author_pk')
        seq = body.get('seq')
        ts = body.get('ts')
        tier = body.get('tier')
        text = body.get('body')
        sig = body.get('sig')
        hops = body.get('hops')
        if not (isinstance(author, str) and isinstance(author_pk, str)
                and isinstance(seq, int) and isinstance(ts, (int, float))
                and isinstance(tier, int) and isinstance(text, str)
                and isinstance(sig, str) and isinstance(hops, int)):
            proc.logger.warning('peer_post malformed, refusing')
            return True
        from .codec import (post_verify, post_content_id,
                                    bound_post_body, post_scope_from_json,
                                    POST_TIER_MIN, POST_TIER_MAX)
        if tier < POST_TIER_MIN or tier > POST_TIER_MAX:
            proc.logger.warning('peer_post bad tier %r, refusing', tier)
            return True
        # A post in a community's name (Phase 4) carries a signed scope;
        # anything present must be well-formed, since the signature covers it.
        scope = post_scope_from_json(body)
        if scope is None:
            proc.logger.warning('peer_post malformed scope, refusing')
            return True
        community, labels = scope
        from nacl.signing import VerifyKey
        # Resolve the verify key, binding uuid <-> key where we can.
        peer = proc.peers.find_by_uuid(author) if proc.peers else None
        if peer is not None:
            known_pk_hex = bytes(peer.signature.public).hex()
            if known_pk_hex != author_pk:
                proc.logger.warning(
                    'peer_post from %s: author_pk != known key, dropping '
                    '(impersonation)', str(author)[:8])
                return True
            vk = peer.signature.public
        else:
            try:
                vk = VerifyKey(bytes.fromhex(author_pk))
            except (ValueError, TypeError):
                proc.logger.warning(
                    'peer_post from %s: bad author_pk, dropping',
                    str(author)[:8])
                return True
        if not post_verify(vk, author, int(seq), float(ts), int(tier),
                           text, sig, community, labels):
            proc.logger.warning(
                'peer_post from %s: BAD SIGNATURE, dropping', str(author)[:8])
            return True
        # Tier-gate: deliver only if this node's view of the author's tier
        # meets the post's required audience floor (unknown author => tier 0).
        # Read THROUGH get_peer_tier so a locally blocked author is clamped to
        # 0 here exactly as C's post handler reads identity_get_peer_tier.
        author_tier = proc.get_peer_tier(author) if peer is not None else 0
        if author_tier < int(tier):
            proc.logger.debug(
                'peer_post from %s tier-gated (need %d, have %d)',
                str(author)[:8], int(tier), author_tier)
            return True
        # Content-id dedup (the app-content store): drop a repeat.
        pid = post_content_id(author, int(seq), float(ts), int(tier), text,
                              community, labels)
        with proc.lock:
            if pid in proc.social._seen_post_ids:
                proc.logger.debug('peer_post %s already seen, dropping', pid)
                return True
            proc.social._seen_post_ids.append(pid)
            if len(proc.social._seen_post_ids) > 256:
                proc.social._seen_post_ids.pop(0)
            # Kept for backfill, the blocked author's too: a personal block
            # governs what WE see, not what our neighbours may.
            _store_for_backfill_locked(proc.social.feed_store, pid, float(ts),
                                       str(author), body)
            # A blocked author's post is HIDDEN (Phase 4 P4.1): recorded in
            # the dedup ring above, but never stored for the app.
            #
            # THE TIER-GATE ABOVE CANNOT DO THIS, which is the defect this
            # increment is named for: a PUBLIC post declares tier 0, a
            # blocked peer clamps to tier 0, and 0 < 0 is false -- so every
            # public post from a blocked peer arrived, on both runtimes.
            # A block is a REFUSAL, not a low measurement.
            #
            # The LOCKED predicate: proc.lock is held here. Twin of C
            # handle_post's gate. (C additionally keeps relaying the post;
            # Python does not gossip-forward at all, so there is nothing
            # here to keep.)
            if _is_blocked_locked(proc, str(author)):
                proc.logger.debug(
                    'peer_post %s from %s hidden (locally blocked)',
                    pid, str(author)[:8])
                return True
            # Shown as any post is: the community's policy is the APP's to
            # apply, and a reader who does not follow the community sees it
            # unmoderated (Phase 4). Twin of C _last_post_store.
            proc.social.last_post[str(author)] = {
                'post_id': pid,
                'seq': int(seq),
                'ts': float(ts),
                'tier': int(tier),
                'body': bound_post_body(text),
                'community': community,
                'labels': list(labels),
            }
        # A backfilled acceptance is said at INFO: rare, and the only evidence
        # the heal delivered it when no app is attached. Mirrors C _ingest_post.
        (proc.logger.debug if via_group else proc.logger.info)(
            'post %s from %s accepted (hops=%d%s)', pid, str(author)[:8],
            int(hops), '' if via_group else ', backfilled')
    except Exception as err:
        proc.report_exception(err, 'handle_post')
    return True

def get_last_post(proc, uuid_str):
    """The most-recent post accepted from an AUTHOR uuid, as
    {'post_id','seq','ts','tier','body'}, or {} if none. Conformance/
    assertion surface; twin of C ``identity_get_last_post``."""
    with proc.lock:
        return dict(proc.social.last_post.get(str(uuid_str), {}))

# ------------------------------------------------------------------
# Businesses (Phase 3 P3.2, "businesses near me").
#
# A business is an Ethne polity; its PAGE is an opaque, self-verifying Ethne
# bundle. This runtime NEVER parses that bundle — it carries it as bytes and
# the app verifies it (polity-root -> envoy -> page). What this runtime owns
# is the AT layer: a detached Ed25519 signature binding WHO advertised, HOW
# satisfied they are, and WHICH page bytes they meant.
#
# THE CUSTOMER GATE is the whole mechanism. A business ad is never relayed
# the way a post is. Only a CUSTOMER carries a business's page, and a
# customer does not forward someone else's ad — it re-advertises from its own
# cache in the FIRST PERSON, with its own key and its own satisfaction. So a
# business's reach is exactly the sum of its customers' voices, distribution
# and reputation are the same fact, and an unhappy customer simply clears its
# edge and goes quiet (silence is the only negative signal — nothing to
# brigade with). Twin of the C block in id_social.c (handle_business_ad,
# _business_advertise, _business_is_customer).
# ------------------------------------------------------------------

def _business_ad_seen_or_record(proc, ad_id):
    """True if ``ad_id`` was ALREADY recorded (caller drops), else record it
    in the bounded ring and return False. Twin of C
    ``_business_ad_seen_or_record``; also what forecloses replay."""
    with proc.lock:
        if ad_id in proc.social._seen_business_ad_ids:
            return True
        proc.social._seen_business_ad_ids.append(ad_id)
        if len(proc.social._seen_business_ad_ids) > 256:
            proc.social._seen_business_ad_ids.pop(0)
    return False

def _business_is_customer(proc, did):
    """THE GATE: this node's customer record for ``did``, or None. A node
    with no customer edge never carries that business's page. Twin of C
    ``_business_is_customer``."""
    with proc.lock:
        rec = proc.social.business_customers.get(str(did))
        return dict(rec) if rec else None

def _business_page_store(proc, did, bundle, seq, ts, advertiser_str, sat):
    """Merge one accepted ad into the learned page store. The NEWEST page
    wins by seq, but the endorser is recorded either way — a customer still
    vouches when carrying a page version we have already bettered. A
    business's OWN ad is not an endorsement (self-vouching is free). Twin of
    C ``_business_page_store``."""
    from .codec import (bound_business_bundle, BUSINESS_SAT_SELF)
    key = str(did)
    with proc.lock:
        rec = proc.social.business_pages.get(key)
        if rec is None:
            if len(proc.social.business_pages) >= 128:  # twin of C BUSINESS_PAGE_CAP
                return
            rec = {'bundle': '', 'seq': -1, 'ts': 0.0, 'endorsers': {}}
            proc.social.business_pages[key] = rec
        if int(seq) >= int(rec.get('seq', -1)):
            rec['bundle'] = bound_business_bundle(bundle)
            rec['seq'] = int(seq)
            rec['ts'] = float(ts)
        if int(sat) != BUSINESS_SAT_SELF and advertiser_str:
            rec.setdefault('endorsers', {})[str(advertiser_str)] = int(sat)

def _business_advertise(proc, queues, did, satisfaction, seq, bundle):
    """Speak for a business IN THE FIRST PERSON: sign the canonical ad with
    THIS node's key and group-multicast it. ``satisfaction`` is our own 0..4
    rating as a customer, or BUSINESS_SAT_SELF when this node IS the
    business. Shared by advertise_business, set_customer, and the
    customer-gated re-advertisement on the inbound path — which is why there
    is no "relay": all three are this same act. Twin of C
    ``_business_advertise``."""
    from .codec import business_ad_sign, business_ad_id
    try:
        ts = float(time.time())
        sig = business_ad_sign(proc.identity.signature.private,
                               proc.identity.uuid, str(did),
                               int(satisfaction), int(seq), ts, bundle)
        pk_hex = bytes(proc.identity.signature.public).hex()
        ad_id = business_ad_id(proc.identity.uuid, str(did),
                               int(satisfaction), int(seq), ts, bundle)
        # Record BEFORE sending so a loopback copy of our own multicast is
        # deduped rather than re-emitted (and not re-advertised in a loop).
        _business_ad_seen_or_record(proc, ad_id)
        payload = to_json_string({
            'advertiser': str(proc.identity.uuid),
            'advertiser_pk': pk_hex,
            'polity': str(did),
            'sat': int(satisfaction),
            'seq': int(seq),
            'ts': ts,
            'bundle': bundle,
            'sig': sig,
        })
        out = Message(proc.name, SocialProtocol.business_ad, payload,
                      to_whom=proc.group, from_whom=proc.identity)
        queues[CfgIds.network].put(out, block=True, timeout=proc.q_cadence)
        proc.logger.debug('advertised business %s seq=%d sat=%d (%s)',
                          str(did)[:16], int(seq), int(satisfaction), ad_id)
        return ad_id
    except Full:
        proc.logger.error('_business_advertise: Network queue full')
    except Exception as err:
        proc.report_exception(err, '_business_advertise')
    return None

def advertise_business(proc, queues, did, bundle, seq=0):
    """Publish THIS node's OWN business page (twin of C
    ``handle_app_advertise_business``). The bundle is opaque here — the app
    built and signed it through Ethne, and any reader verifies it the same
    way. Reach comes from customers re-advertising, not from this call."""
    from .codec import BUSINESS_SAT_SELF
    if not did or not bundle:
        proc.logger.warning(
            'advertise_business without polity/bundle, refusing')
        return None
    return _business_advertise(proc, queues, did, BUSINESS_SAT_SELF, seq,
                                    bundle)

def set_customer(proc, did, satisfaction, bundle='', seq=0, queues=None):
    """Declare, update or clear this node's CUSTOMER edge to a business (twin
    of C ``handle_app_set_customer``).

    Declaring the edge is what authorizes this node to CARRY the page: the
    bundle is cached and, when ``queues`` is given, advertised immediately in
    the first person. A NEGATIVE ``satisfaction`` clears the edge, after
    which this node simply goes quiet about the business — it never publishes
    anything negative. An empty ``bundle`` falls back to the page already
    learned, so a person can become a customer straight from a page that
    reached them through someone else."""
    from .codec import (bound_business_bundle, BUSINESS_SAT_MAX)
    key = str(did)
    if not key:
        proc.logger.warning('set_customer without polity, refusing')
        return False
    if int(satisfaction) < 0:
        with proc.lock:
            proc.social.business_customers.pop(key, None)
        proc.logger.info('cleared customer edge to %s (going quiet)',
                         key[:16])
        return True
    sat = min(int(satisfaction), BUSINESS_SAT_MAX)
    bundle = bound_business_bundle(bundle)
    if not bundle:
        with proc.lock:
            known = proc.social.business_pages.get(key)
            if known:
                bundle = known.get('bundle', '')
                seq = known.get('seq', seq)
    if not bundle:
        proc.logger.warning(
            'set_customer for %s but no page known, refusing', key[:16])
        return False
    with proc.lock:
        proc.social.business_customers[key] = {
            'sat': sat,
            'since': float(time.time()),
            'bundle': bundle,
            'seq': int(seq),
        }
    proc.logger.info('customer of %s at satisfaction %d', key[:16], sat)
    if queues is not None:
        _business_advertise(proc, queues, key, sat, int(seq), bundle)
    return True

def handle_business_ad(proc, queues, message):
    """An inbound group-multicast business ad. Verify the advertiser's
    Ed25519 signature (for a KNOWN peer the carried advertiser_pk MUST match
    the stored signing key — impersonation guard; an unknown advertiser is
    verified against the carried key, so a page can reach beyond the
    business's own cohort), content-id dedup, store, then apply THE CUSTOMER
    GATE: if we are a customer of this business we re-advertise it ourselves,
    with OUR satisfaction. A non-customer stops here — it has the page and
    can show it to its operator, but it does not carry it onward.

    Note what is deliberately absent: no tier-gate (a business page is public
    by construction — the gate is patronage, not audience) and no hop count
    (we never forward someone else's ad). Twin of the C
    ``handle_business_ad``."""
    if message.function != SocialProtocol.business_ad:
        return False
    try:
        body = from_json_string(message.obj)
        if not isinstance(body, dict):
            return True
        advertiser = body.get('advertiser')
        adv_pk = body.get('advertiser_pk')
        did = body.get('polity')
        sat = body.get('sat')
        seq = body.get('seq')
        ts = body.get('ts')
        bundle = body.get('bundle')
        sig = body.get('sig')
        if not (isinstance(advertiser, str) and isinstance(adv_pk, str)
                and isinstance(did, str) and isinstance(sat, int)
                and isinstance(seq, int) and isinstance(ts, (int, float))
                and isinstance(bundle, str) and isinstance(sig, str)):
            proc.logger.warning('peer_business_ad malformed, refusing')
            return True
        from .codec import (business_ad_verify, business_ad_id,
                                    business_sat_valid, bound_business_did,
                                    bound_business_bundle)
        if not did:
            proc.logger.warning(
                'peer_business_ad without polity, refusing')
            return True
        if not business_sat_valid(sat):
            proc.logger.warning(
                'peer_business_ad bad satisfaction %r, refusing', sat)
            return True
        did = bound_business_did(did)
        bundle = bound_business_bundle(bundle)
        from nacl.signing import VerifyKey
        # Resolve the verify key, binding uuid <-> key where we can.
        peer = proc.peers.find_by_uuid(advertiser) if proc.peers else None
        if peer is not None:
            known_pk_hex = bytes(peer.signature.public).hex()
            if known_pk_hex != adv_pk:
                proc.logger.warning(
                    'peer_business_ad from %s: advertiser_pk != known key, '
                    'dropping (impersonation)', str(advertiser)[:8])
                return True
            vk = peer.signature.public
        else:
            try:
                vk = VerifyKey(bytes.fromhex(adv_pk))
            except (ValueError, TypeError):
                proc.logger.warning(
                    'peer_business_ad from %s: bad advertiser_pk, dropping',
                    str(advertiser)[:8])
                return True
        if not business_ad_verify(vk, advertiser, did, int(sat), int(seq),
                                  float(ts), bundle, sig):
            proc.logger.warning(
                'peer_business_ad from %s: BAD SIGNATURE, dropping',
                str(advertiser)[:8])
            return True
        # Content-id dedup: compute from the VERIFIED canonical, drop repeats
        # before storing or re-advertising.
        ad_id = business_ad_id(advertiser, did, int(sat), int(seq),
                               float(ts), bundle)
        if _business_ad_seen_or_record(proc, ad_id):
            proc.logger.debug('peer_business_ad %s already seen, dropping',
                              ad_id)
            return True
        _business_page_store(proc, did, bundle, int(seq), float(ts),
                                  str(advertiser), int(sat))
        proc.logger.debug(
            'business ad %s for %s from %s accepted (sat=%d)',
            ad_id, did[:16], str(advertiser)[:8], int(sat))
        # THE CUSTOMER GATE.
        own = _business_is_customer(proc, did)
        if own is not None:
            carry, carry_seq = own.get('bundle', ''), int(own.get('seq', 0))
            if int(seq) > carry_seq:   # the business updated its page
                carry, carry_seq = bundle, int(seq)
            _business_advertise(proc, queues, did, int(own.get('sat', 0)),
                                     carry_seq, carry)
    except Exception as err:
        proc.report_exception(err, 'handle_business_ad')
    return True

def get_business_page(proc, did):
    """What this node knows about business ``did``, as
    {'bundle','seq','ts','endorsers'}, or {} if none. The endorsers map is
    {advertiser uuid str: satisfaction} and counts CUSTOMERS only — a
    business's own ad is not an endorsement. Conformance/assertion surface;
    twin of C ``identity_get_business_page``."""
    with proc.lock:
        rec = proc.social.business_pages.get(str(did))
        if not rec:
            return {}
        out = dict(rec)
        out['endorsers'] = dict(rec.get('endorsers', {}))
        return out

def get_customer_satisfaction(proc, did):
    """This node's OWN customer satisfaction toward ``did`` (0..4), or -1
    when it holds no customer edge — and therefore carries nothing for that
    business. Conformance/assertion surface; twin of C
    ``identity_get_customer_satisfaction``."""
    rec = _business_is_customer(proc, did)
    return int(rec.get('sat', -1)) if rec else -1

# ------------------------------------------------------------------
# Business posts (Phase 3 P3.4, "the polity speaking, in the feed").
#
# A page is what the business IS; a post is what it SAYS. Two differences
# from an ad, both following from where the authority lives:
#   - A post RELAYS (POST_MAX_HOPS), because its authority is the ENVOY
#     signature sealed inside the opaque bundle and no carrier can launder
#     it. A relay forwards the ORIGINAL envelope and changes only the hop
#     count, so a post keeps ONE content id however many paths it travels.
#     An ad is first-person and is therefore never forwarded at all.
#   - A post is GATED ON THE PAGE, not on patronage: a node holding no page
#     for the polity drops it AND DOES NOT RELAY IT, so posts travel only
#     through the part of the network that already knows the business.
# What this runtime verifies is the sender's Ed25519 signature over the
# canonical bytes — that this copy arrived unaltered. WHO MAY SPEAK FOR THE
# BUSINESS is not a question it can answer; the app answers it against the
# bundle. Twin of the C block in id_social.c (handle_business_post,
# _business_post_send, _business_page_held).
# ------------------------------------------------------------------

def _business_post_seen_or_record(proc, post_id):
    """Bounded content-id dedup for business posts — what stops a relayed
    post echoing round the group. Twin of C
    ``_business_post_seen_or_record``."""
    with proc.lock:
        if post_id in proc.social._seen_business_post_ids:
            return True
        proc.social._seen_business_post_ids.append(post_id)
        if len(proc.social._seen_business_post_ids) > 256:
            proc.social._seen_business_post_ids.pop(0)
        return False

def _business_page_held(proc, did):
    """THE AUDIENCE GATE: does this node hold a page for ``did``? A post
    from a business we know nothing about is dropped unread and unrelayed.
    Twin of C ``_business_page_held``."""
    with proc.lock:
        return str(did) in proc.social.business_pages

def _business_post_publish(proc, queues, did, seq, bundle):
    """PUBLISH a business post: sign the canonical form with THIS node's key
    and group-multicast it at hops 0. Only the publishing node does this — a
    relay forwards the original envelope instead (see
    ``_business_post_forward``), because re-signing would change the content
    id and break the dedup that makes gossip converge. Twin of C
    ``_business_post_publish``."""
    from .codec import business_post_sign, business_post_id
    try:
        ts = float(time.time())
        sig = business_post_sign(proc.identity.signature.private,
                                 proc.identity.uuid, str(did), int(seq), ts,
                                 bundle)
        pk_hex = bytes(proc.identity.signature.public).hex()
        post_id = business_post_id(proc.identity.uuid, str(did), int(seq),
                                   ts, bundle)
        # Record BEFORE sending so a loopback copy of our own multicast is
        # deduped rather than re-emitted and relayed back into the group.
        _business_post_seen_or_record(proc, post_id)
        payload = to_json_string({
            'author': str(proc.identity.uuid),
            'author_pk': pk_hex,
            'polity': str(did),
            'seq': int(seq),
            'ts': ts,
            'bundle': bundle,
            'sig': sig,
            # A publish is always hop 0. This read an undefined `hops` until
            # Phase 4, so every Python publish raised NameError into the
            # handler below and never went out; nothing drove it.
            'hops': 0,
        })
        out = Message(proc.name, SocialProtocol.business_post, payload,
                      to_whom=proc.group, from_whom=proc.identity)
        queues[CfgIds.network].put(out, block=True, timeout=proc.q_cadence)
        proc.logger.info('published business post %s for %s seq=%d',
                         post_id, str(did)[:16], int(seq))
        return post_id
    except Full:
        proc.logger.error('_business_post_publish: Network queue full')
    except Exception as err:
        proc.report_exception(err, '_business_post_publish')
    return None

def _business_post_forward(proc, queues, body, hops):
    """RELAY a business post: re-emit the ORIGINAL envelope with the hop
    count bumped and everything else — publisher, key, signature, seq, ts,
    bundle — passed through untouched.

    A RELAY MUST NOT RE-SIGN. Signing as ourselves would change the
    canonical bytes and therefore the content id, so the relayed copy would
    dedup against nothing and every receiver would hold one copy per relay
    of the same words. The content address is what makes gossip CONVERGE.
    It is also why the hop count lives outside the signature. Twin of the C
    relay branch in ``handle_business_post``."""
    try:
        fwd = dict(body)
        fwd['hops'] = int(hops)
        out = Message(proc.name, SocialProtocol.business_post,
                      to_json_string(fwd), to_whom=proc.group,
                      from_whom=proc.identity)
        queues[CfgIds.network].put(out, block=True, timeout=proc.q_cadence)
        proc.logger.debug('relayed business post for %s at hops=%d',
                          str(body.get('polity'))[:16], int(hops))
        return True
    except Full:
        proc.logger.error('_business_post_forward: Network queue full')
    except Exception as err:
        proc.report_exception(err, '_business_post_forward')
    return False

def publish_business_post(proc, queues, did, bundle, seq=None):
    """Publish the business's words (twin of C
    ``handle_app_publish_business_post``). The bundle is opaque here — the
    app built and ENVOY-signed it through Ethne, and every reader checks
    that signature itself. THIS CONFERS NOTHING: a node with no delegation
    can call it and will simply have its post refused everywhere."""
    from .codec import BUSINESS_SAT_SELF
    if not did or not bundle:
        proc.logger.warning(
            'publish_business_post without polity/bundle, refusing')
        return None
    if seq is None:
        # Keep a monotonic seq of our own, so two posts with identical text
        # do not collapse to one content id.
        with proc.lock:
            proc.social._business_post_seq += 1
            seq = proc.social._business_post_seq
    else:
        with proc.lock:
            proc.social._business_post_seq = max(proc.social._business_post_seq, int(seq))
    # The business holds its own page by construction — it just wrote the
    # post — so record it before publishing. Without this the publisher's
    # own page gate would refuse a copy of its own post coming back round.
    _business_page_store(proc, did, bundle, int(seq), float(time.time()), '',
                              BUSINESS_SAT_SELF)
    return _business_post_publish(proc, queues, did, int(seq), bundle)

def handle_business_post(proc, queues, message):
    """An inbound group-multicast business post. Verify the sender's
    signature over the canonical bytes, GATE on holding this polity's page,
    dedup by content id, record, then relay one more hop.

    ORDER MATTERS: the gate sits AFTER the signature check (so a forgery is
    refused as a forgery, not as an unknown business) and BEFORE the record
    and the relay (so an ungated node neither shows nor spreads it). Twin of
    the C ``handle_business_post``."""
    if message.function != SocialProtocol.business_post:
        return False
    try:
        body = from_json_string(message.obj)
    except Exception as err:
        proc.report_exception(err, 'handle_business_post')
        return True
    return _ingest_business_post(proc, queues, body, True)


def _ingest_business_post(proc, queues, body, via_group):
    """The one inbound path for a business post: the group multicast
    (``via_group`` True) or a directed backfill (False). A backfill passes the
    same page gate and dedup and is never relayed. Twin of C
    ``_ingest_business_post``."""
    try:
        if not isinstance(body, dict):
            return True
        author = body.get('author')
        auth_pk = body.get('author_pk')
        did = body.get('polity')
        seq = body.get('seq')
        ts = body.get('ts')
        bundle = body.get('bundle')
        sig = body.get('sig')
        hops = body.get('hops')
        if not (isinstance(author, str) and isinstance(auth_pk, str)
                and isinstance(did, str) and isinstance(seq, int)
                and isinstance(ts, (int, float)) and isinstance(bundle, str)
                and isinstance(sig, str) and isinstance(hops, int)):
            proc.logger.warning('peer_business_post malformed, refusing')
            return True
        from .codec import (business_post_verify, business_post_id,
                                    bound_business_did,
                                    bound_business_post_bundle,
                                    BUSINESS_POST_MAX_HOPS)
        if not did:
            proc.logger.warning(
                'peer_business_post without polity, refusing')
            return True
        if hops < 0:
            proc.logger.warning(
                'peer_business_post with negative hops, refusing')
            return True
        did = bound_business_did(did)
        bundle = bound_business_post_bundle(bundle)
        from nacl.signing import VerifyKey
        # Resolve the verify key, binding uuid <-> key where we can.
        peer = proc.peers.find_by_uuid(author) if proc.peers else None
        if peer is not None:
            known_pk_hex = bytes(peer.signature.public).hex()
            if known_pk_hex != auth_pk:
                proc.logger.warning(
                    'peer_business_post from %s: author_pk != known key, '
                    'dropping (impersonation)', str(author)[:8])
                return True
            vk = peer.signature.public
        else:
            try:
                vk = VerifyKey(bytes.fromhex(auth_pk))
            except (ValueError, TypeError):
                proc.logger.warning(
                    'peer_business_post from %s: bad author_pk, dropping',
                    str(author)[:8])
                return True
        if not business_post_verify(vk, author, did, int(seq), float(ts),
                                    bundle, sig):
            proc.logger.warning(
                'peer_business_post from %s: BAD SIGNATURE, dropping',
                str(author)[:8])
            return True
        # THE AUDIENCE GATE: no page for this polity, no post. Dropped here
        # means not shown AND not relayed.
        if not _business_page_held(proc, did):
            proc.logger.debug(
                'business post for %s dropped - no page held for that '
                'polity', did[:16])
            return True
        post_id = business_post_id(author, did, int(seq), float(ts), bundle)
        if _business_post_seen_or_record(proc, post_id):
            proc.logger.debug(
                'peer_business_post %s already seen, dropping', post_id)
            return True
        with proc.lock:
            _store_for_backfill_locked(proc.social.biz_store, post_id,
                                       float(ts), str(author), body)
            proc.social.last_business_post[str(did)] = {
                'post_id': post_id, 'seq': int(seq), 'ts': float(ts),
                'hops': int(hops), 'bundle': bundle,
            }
        proc.logger.info(
            'business post %s for %s from %s accepted (hops=%d%s)', post_id,
            did[:16], str(author)[:8], int(hops),
            '' if via_group else ', backfilled')
        # Gossip one more hop, under the same bound as a feed post,
        # FORWARDING THE ORIGINAL ENVELOPE — see _business_post_forward for
        # why a relay must not re-sign. A backfill is never relayed.
        if via_group and int(hops) < BUSINESS_POST_MAX_HOPS:
            _business_post_forward(proc, queues, body, int(hops) + 1)
    except Exception as err:
        proc.report_exception(err, 'handle_business_post')
    return True

# ------------------------------------------------------------------
# STORE-AND-FORWARD (Agora Phase 4 DDIL). Twin of the C block in id_social.c;
# see SocialProtocol.post_digest. Bounds: POST_STORE_CAP per store, only posts
# younger than POST_BACKFILL_MAX_AGE (their own signed ts) are offered, at most
# POST_WANT_MAX ids per kind per want and posts per kind per backfill, and one
# want sent to and one served for each peer per POST_WANT_COOLDOWN seconds. The
# digest goes out at most every $AT_SOCIAL_DIGEST_SEC (default
# POST_DIGEST_DEFAULT_SEC), from the periodic resync. In memory only, and
# Python's store holds received posts only (it has no feed publish verb).
# ------------------------------------------------------------------

POST_STORE_CAP = 256
POST_BACKFILL_MAX_AGE = 24.0 * 3600.0
POST_WANT_MAX = 32
POST_WANT_COOLDOWN = 10.0
POST_DIGEST_DEFAULT_SEC = 60


def _store_for_backfill_locked(store, post_id, ts, author, body):
    """Keep one verified post's wire envelope under its content id. Caller
    holds proc.lock. A known id is left as is; a full store drops its
    oldest."""
    if post_id in store:
        return
    store[post_id] = {'ts': float(ts), 'author': str(author),
                      'env': to_json_string(body)}
    while len(store) > POST_STORE_CAP:
        store.popitem(last=False)


def _digest_interval():
    try:
        v = int(os.environ.get('AT_SOCIAL_DIGEST_SEC', ''))
        if v > 0:
            return float(v)
    except ValueError:
        pass
    return float(POST_DIGEST_DEFAULT_SEC)


def _digest_ids_locked(store, now):
    live = [(e['ts'], pid) for pid, e in store.items()
            if e['ts'] > now - POST_BACKFILL_MAX_AGE]
    live.sort(key=lambda t: -t[0])
    return [pid for _, pid in live[:POST_STORE_CAP]]


def send_post_digest(proc, queues):
    """Group-multicast the content ids of our recent stored posts. Returns 0
    when sent, 1 when there was nothing to offer, -1 on failure. Twin of C
    ``identity_send_post_digest``; also the conformance seam."""
    now = time.time()
    with proc.lock:
        feed = _digest_ids_locked(proc.social.feed_store, now)
        biz = _digest_ids_locked(proc.social.biz_store, now)
        # A label is offered WITH its community (Phase 4), so a peer that does
        # not follow it asks for nothing. Twin of C identity_send_post_digest.
        label = []
        for lid in _digest_ids_locked(proc.social.label_store, now):
            env = from_json_string(proc.social.label_store[lid]['env'])
            if isinstance(env, dict) and isinstance(env.get('community'), str):
                label.append({'id': lid, 'community': env['community']})
        proc.social.last_digest_at = now
    if not feed and not biz and not label:
        return 1
    digest = {'feed': feed, 'biz': biz}
    if label:
        digest['label'] = label
    try:
        out = Message(proc.name, SocialProtocol.post_digest,
                      to_json_string(digest),
                      to_whom=proc.group, from_whom=proc.identity)
        queues[CfgIds.network].put(out, block=True, timeout=proc.q_cadence)
        return 0
    except Full:
        proc.logger.error('send_post_digest: Network queue full')
    except Exception as err:
        proc.report_exception(err, 'send_post_digest')
    return -1


def maybe_send_post_digest(proc, queues):
    with proc.lock:
        due = time.time() - proc.social.last_digest_at >= _digest_interval()
    if due:
        send_post_digest(proc, queues)


def _cooldown_pass_locked(table, peer_str, now):
    when = table.get(peer_str)
    if when is not None and now - when < POST_WANT_COOLDOWN:
        return False
    table[peer_str] = now
    return True


def _admitted_sender(proc, message, verb):
    """A digest, want or backfill is honoured only from an admitted peer."""
    sender = getattr(message, 'from_whom', None)
    peer = (proc.peers.find_by_uuid(str(sender.uuid))
            if sender is not None and proc.peers else None)
    if peer is None:
        proc.logger.warning('%s from a peer we have not admitted, refusing',
                            verb)
    return peer


def _send_directed(proc, queues, peer, verb, payload, what):
    try:
        out = Message(proc.name, verb, to_json_string(payload),
                      to_whom=peer, from_whom=proc.identity, encrypt=True)
        queues[CfgIds.network].put(out, block=True, timeout=proc.q_cadence)
        return True
    except Full:
        proc.logger.error('%s: Network queue full', what)
    except Exception as err:
        proc.report_exception(err, what)
    return False


def handle_post_digest(proc, queues, message):
    """A peer's digest: ask it, directed, for the ids we do not hold. Twin of
    C ``handle_post_digest``."""
    if message.function != SocialProtocol.post_digest:
        return False
    sender = getattr(message, 'from_whom', None)
    if sender is not None and str(sender.uuid) == str(proc.identity.uuid):
        return True  # our own, looped back
    peer = _admitted_sender(proc, message, 'peer_post_digest')
    if peer is None:
        return True
    try:
        body = from_json_string(message.obj)
        if not isinstance(body, dict):
            return True
        with proc.lock:
            want = {}
            for kind, seen in (('feed', proc.social._seen_post_ids),
                               ('biz', proc.social._seen_business_post_ids)):
                ids = body.get(kind)
                ids = ids if isinstance(ids, list) else []
                want[kind] = [i for i in ids
                              if isinstance(i, str) and len(i) == 64
                              and i not in seen][:POST_WANT_MAX]
            # Labels: only those for communities we follow, and do not hold.
            offered = body.get('label')
            offered = offered if isinstance(offered, list) else []
            labels = [e.get('id') for e in offered
                      if isinstance(e, dict) and isinstance(e.get('id'), str)
                      and len(e['id']) == 64
                      and isinstance(e.get('community'), str)
                      and e['community'] in proc.social.communities
                      and e['id'] not in proc.social._seen_post_label_ids]
            if labels:
                want['label'] = labels[:POST_WANT_MAX]
            if not (want['feed'] or want['biz'] or want.get('label')):
                return True
            if not _cooldown_pass_locked(proc.social.want_sent_at,
                                         str(peer.uuid), time.time()):
                return True
        proc.logger.info('asking %s for %d missed post(s)', str(peer.uuid)[:8],
                         len(want['feed']) + len(want['biz'])
                         + len(want.get('label', [])))
        _send_directed(proc, queues, peer, SocialProtocol.post_want, want,
                       'handle_post_digest')
    except Exception as err:
        proc.report_exception(err, 'handle_post_digest')
    return True


def handle_post_want(proc, queues, message):
    """A peer asks for stored posts: serve each, directed, as its original
    envelope, never a post back to its own author. Twin of C
    ``handle_post_want``."""
    if message.function != SocialProtocol.post_want:
        return False
    peer = _admitted_sender(proc, message, 'peer_post_want')
    if peer is None:
        return True
    try:
        body = from_json_string(message.obj)
        if not isinstance(body, dict):
            return True
        requester = str(peer.uuid)
        serve = []
        with proc.lock:
            if not _cooldown_pass_locked(proc.social.want_served_at,
                                         requester, time.time()):
                proc.logger.debug('post want from %s within the cooldown, '
                                  'not served', requester[:8])
                return True
            for kind, store in (('feed', proc.social.feed_store),
                                ('biz', proc.social.biz_store),
                                ('label', proc.social.label_store)):
                ids = body.get(kind)
                ids = ids if isinstance(ids, list) else []
                taken = 0
                for pid in ids:
                    if taken >= POST_WANT_MAX:
                        break
                    e = store.get(pid) if isinstance(pid, str) else None
                    if e is None or e['author'] == requester:
                        continue
                    serve.append((kind, e['env']))
                    taken += 1
        for kind, env in serve:
            _send_directed(proc, queues, peer, SocialProtocol.post_backfill,
                           {'kind': kind, 'post': from_json_string(env)},
                           'handle_post_want')
        if serve:
            proc.logger.info('backfilled %d post(s) to %s', len(serve),
                             requester[:8])
    except Exception as err:
        proc.report_exception(err, 'handle_post_want')
    return True


def handle_post_backfill(proc, queues, message):
    """One backfilled post, through the same path as the original minus the
    relay. Twin of C ``handle_post_backfill``."""
    if message.function != SocialProtocol.post_backfill:
        return False
    if _admitted_sender(proc, message, 'peer_post_backfill') is None:
        return True
    try:
        body = from_json_string(message.obj)
    except Exception as err:
        proc.report_exception(err, 'handle_post_backfill')
        return True
    kind = body.get('kind') if isinstance(body, dict) else None
    post = body.get('post') if isinstance(body, dict) else None
    if not isinstance(post, dict) or kind not in ('feed', 'biz', 'label'):
        proc.logger.warning('peer_post_backfill malformed, refusing')
        return True
    if kind == 'feed':
        return _ingest_post(proc, queues, post, False)
    if kind == 'label':
        return _ingest_post_label(proc, queues, post, False)
    return _ingest_business_post(proc, queues, post, False)


def get_last_business_post(proc, did):
    """The most-recent business post this node ACCEPTED for polity ``did``,
    as {'post_id','seq','ts','hops','bundle'}, or {} if none. Keyed by the
    polity, not by whoever relayed it. Conformance/assertion surface; twin
    of C ``identity_get_last_business_post``."""
    with proc.lock:
        rec = proc.social.last_business_post.get(str(did))
        return dict(rec) if rec else {}


# ------------------------------------------------------------------
# COMMUNITIES (Phase 4, Ethne D37): a community's content policy and a
# moderator's labels. Twin of the C block in id_social.c. This runtime never
# parses a policy, never decides whether a label counts, and never hides a post
# by policy -- all of that is the app's, against a policy only it can verify.
# What it owns is carriage: holding what the app told it to follow, carrying
# that in the first person, and moving labels only to nodes that follow.
# ------------------------------------------------------------------

POLICY_AD_DEFAULT_SEC = 300


def _ring_seen_or_record_locked(ring, ident, record=True, cap=256):
    if ident in ring:
        return True
    if record:
        ring.append(ident)
        if len(ring) > cap:
            ring.pop(0)
    return False


def is_following(proc, did):
    """Whether this node follows ``did``. Twin of C ``identity_is_following``."""
    with proc.lock:
        return bool(did) and str(did) in proc.social.communities


def get_followed_community(proc, did):
    """The policy held for ``did``, {'bundle','seq'}, or {}."""
    with proc.lock:
        rec = proc.social.communities.get(str(did))
        return dict(rec) if rec else {}


def follow_community(proc, did, bundle, seq=0, queues=None):
    """Follow ``did`` holding ``bundle`` (which the app verified) at ``seq``,
    and persist; replaces a held policy. When ``queues`` is given, carry it now.
    Returns False on bad input or past COMMUNITIES_MAX. Twin of C
    ``identity_follow_community`` + ``handle_app_follow_community``."""
    from .codec import (COMMUNITY_DID_MAX, COMMUNITY_POLICY_BUNDLE_MAX,
                        COMMUNITIES_MAX)
    if (not isinstance(did, str) or not isinstance(bundle, str) or not did
            or not bundle or len(did.encode('utf-8')) > COMMUNITY_DID_MAX
            or len(bundle.encode('utf-8')) > COMMUNITY_POLICY_BUNDLE_MAX):
        proc.logger.warning('follow_community refused: bad community/bundle')
        return False
    with proc.lock:
        if (did not in proc.social.communities
                and len(proc.social.communities) >= COMMUNITIES_MAX):
            proc.logger.warning('follow_community refused: %d already followed',
                                COMMUNITIES_MAX)
            return False
        proc.social.communities[did] = {'bundle': bundle, 'seq': int(seq)}
    _persist_social_blocks(proc)
    proc.logger.info('following %s at seq %d', did[:24], int(seq))
    if queues is not None:
        _policy_advertise(proc, queues, did, int(seq), bundle)
    return True


def unfollow_community(proc, did):
    """Stop following ``did``, and persist. Twin of C
    ``identity_unfollow_community``."""
    with proc.lock:
        proc.social.communities.pop(str(did), None)
    _persist_social_blocks(proc)


def _policy_advertise(proc, queues, did, seq, bundle):
    """Carry one policy IN THE FIRST PERSON: sign as THIS node and multicast.
    Never a relay. Twin of C ``_policy_advertise``."""
    from .codec import policy_ad_sign, policy_ad_id
    try:
        ts = float(time.time())
        sig = policy_ad_sign(proc.identity.signature.private, proc.identity.uuid,
                             str(did), int(seq), ts, bundle)
        pid = policy_ad_id(proc.identity.uuid, str(did), int(seq), ts, bundle)
        with proc.lock:
            _ring_seen_or_record_locked(proc.social._seen_policy_ad_ids, pid)
        payload = to_json_string({
            'carrier': str(proc.identity.uuid),
            'carrier_pk': bytes(proc.identity.signature.public).hex(),
            'community': str(did), 'seq': int(seq), 'ts': ts,
            'bundle': bundle, 'sig': sig,
        })
        out = Message(proc.name, SocialProtocol.community_policy, payload,
                      to_whom=proc.group, from_whom=proc.identity)
        queues[CfgIds.network].put(out, block=True, timeout=proc.q_cadence)
        return pid
    except Full:
        proc.logger.error('_policy_advertise: Network queue full')
    except Exception as err:
        proc.report_exception(err, '_policy_advertise')
    return None


def _policy_ad_interval():
    try:
        v = int(os.environ.get('AT_SOCIAL_POLICY_SEC', ''))
        if v > 0:
            return float(v)
    except ValueError:
        pass
    return float(POLICY_AD_DEFAULT_SEC)


def advertise_communities(proc, queues):
    """Carry every followed policy now. Returns how many went out. Twin of C
    ``identity_advertise_communities``; also the conformance seam."""
    with proc.lock:
        proc.social.last_policy_ad_at = time.time()
        held = [(d, dict(r)) for d, r in proc.social.communities.items()]
    sent = 0
    for did, rec in held:
        if _policy_advertise(proc, queues, did, int(rec['seq']), rec['bundle']):
            sent += 1
    return sent


def maybe_advertise_communities(proc, queues):
    with proc.lock:
        due = (bool(proc.social.communities)
               and time.time() - proc.social.last_policy_ad_at >= _policy_ad_interval())
    if due:
        advertise_communities(proc, queues)


def _carried_key(proc, who, pk_hex, verb):
    """A known peer's stored key, which the carried one MUST match, else the
    carried key best-effort; None to drop. Twin of C ``_carried_key``."""
    from nacl.signing import VerifyKey
    peer = proc.peers.find_by_uuid(who) if proc.peers else None
    if peer is not None:
        if bytes(peer.signature.public).hex() != pk_hex:
            proc.logger.warning('%s from %s: key != known key, dropping '
                                '(impersonation)', verb, str(who)[:8])
            return None
        return peer.signature.public
    try:
        return VerifyKey(bytes.fromhex(pk_hex))
    except (ValueError, TypeError):
        proc.logger.warning('%s from %s: bad key, dropping', verb, str(who)[:8])
        return None


def _community_fields_ok(body, who_key, pk_key, bundle_max):
    from .codec import COMMUNITY_DID_MAX
    if not isinstance(body, dict):
        return False
    who = body.get(who_key)
    pk = body.get(pk_key)
    did = body.get('community')
    seq = body.get('seq')
    ts = body.get('ts')
    bundle = body.get('bundle')
    sig = body.get('sig')
    return (isinstance(who, str) and isinstance(pk, str) and len(pk) == 64
            and isinstance(did, str) and 0 < len(did.encode('utf-8')) <= COMMUNITY_DID_MAX
            and isinstance(seq, int) and not isinstance(seq, bool)
            and isinstance(ts, (int, float))
            and isinstance(bundle, str)
            and 0 < len(bundle.encode('utf-8')) <= bundle_max
            and isinstance(sig, str) and len(sig) == 128)


def handle_community_policy(proc, queues, message):
    """An inbound policy ad: verify, dedup, record what we heard -- and nothing
    more. We do not follow it, replace a held policy with it, or carry it on.
    Twin of C ``handle_community_policy``."""
    if message.function != SocialProtocol.community_policy:
        return False
    from .codec import (policy_ad_verify, policy_ad_id,
                        COMMUNITY_POLICY_BUNDLE_MAX)
    try:
        body = from_json_string(message.obj)
        if not _community_fields_ok(body, 'carrier', 'carrier_pk',
                                    COMMUNITY_POLICY_BUNDLE_MAX):
            proc.logger.warning('peer_community_policy malformed, refusing')
            return True
        carrier = body['carrier']
        vk = _carried_key(proc, carrier, body['carrier_pk'],
                          'peer_community_policy')
        if vk is None:
            return True
        args = (carrier, body['community'], int(body['seq']), float(body['ts']),
                body['bundle'])
        if not policy_ad_verify(vk, *args, body['sig']):
            proc.logger.warning('peer_community_policy: BAD SIGNATURE, dropping')
            return True
        pid = policy_ad_id(*args)
        with proc.lock:
            if _ring_seen_or_record_locked(proc.social._seen_policy_ad_ids, pid):
                return True
            # A carrier we blocked is not heard, as a blocked advertiser is not.
            if _is_blocked_locked(proc, carrier):
                return True
            proc.social.last_policy[body['community']] = {
                'policy_id': pid, 'seq': int(body['seq']),
                'bundle': body['bundle'], 'carrier': carrier}
    except Exception as err:
        proc.report_exception(err, 'handle_community_policy')
    return True


def get_last_community_policy(proc, did):
    """What this node last HEARD of ``did``'s policy, or {}. Twin of C
    ``identity_get_last_community_policy``."""
    with proc.lock:
        rec = proc.social.last_policy.get(str(did))
        return dict(rec) if rec else {}


def publish_post_label(proc, queues, did, post_id, seq, bundle):
    """Publish a moderator's label: sign as THIS node, keep for backfill,
    multicast at hops 0. Confers nothing. Twin of C
    ``identity_publish_post_label``."""
    from .codec import post_label_sign, post_label_id, community_post_id_valid
    if not did or not bundle or not community_post_id_valid(post_id):
        proc.logger.warning('publish_post_label refused (needs a community, a '
                            '64-hex post id and a bundle)')
        return None
    try:
        ts = float(time.time())
        sig = post_label_sign(proc.identity.signature.private, proc.identity.uuid,
                              str(did), post_id, int(seq), ts, bundle)
        lid = post_label_id(proc.identity.uuid, str(did), post_id, int(seq), ts,
                            bundle)
        env = {'author': str(proc.identity.uuid),
               'author_pk': bytes(proc.identity.signature.public).hex(),
               'community': str(did), 'post_id': post_id, 'seq': int(seq),
               'ts': ts, 'bundle': bundle, 'sig': sig, 'hops': 0}
        with proc.lock:
            _ring_seen_or_record_locked(proc.social._seen_post_label_ids, lid)
            _store_for_backfill_locked(proc.social.label_store, lid, ts,
                                       str(proc.identity.uuid), env)
        out = Message(proc.name, SocialProtocol.post_label, to_json_string(env),
                      to_whom=proc.group, from_whom=proc.identity)
        queues[CfgIds.network].put(out, block=True, timeout=proc.q_cadence)
        proc.logger.info('published label %s on %s in %s', lid, post_id,
                         str(did)[:24])
        return lid
    except Full:
        proc.logger.error('publish_post_label: Network queue full')
    except Exception as err:
        proc.report_exception(err, 'publish_post_label')
    return None


def handle_post_label(proc, queues, message):
    """An inbound group-multicast label. Twin of C ``handle_post_label``."""
    if message.function != SocialProtocol.post_label:
        return False
    try:
        body = from_json_string(message.obj)
    except Exception as err:
        proc.report_exception(err, 'handle_post_label')
        return True
    return _ingest_post_label(proc, queues, body, True)


def _ingest_post_label(proc, queues, body, via_group):
    """The one inbound path for a label: multicast (relayed while under the hop
    bound) or backfill (never relayed). THE FOLLOW GATE sits after the signature
    check and before the dedup, record and relay, where a business post's page
    gate sits. Twin of C ``_ingest_post_label``."""
    from .codec import (post_label_verify, post_label_id,
                        community_post_id_valid, POST_LABEL_BUNDLE_MAX,
                        POST_MAX_HOPS)
    try:
        if (not _community_fields_ok(body, 'author', 'author_pk',
                                     POST_LABEL_BUNDLE_MAX)
                or not community_post_id_valid(body.get('post_id'))
                or not isinstance(body.get('hops'), int)
                or isinstance(body.get('hops'), bool) or body['hops'] < 0):
            proc.logger.warning('peer_post_label malformed, refusing')
            return True
        author = body['author']
        vk = _carried_key(proc, author, body['author_pk'], 'peer_post_label')
        if vk is None:
            return True
        args = (author, body['community'], body['post_id'], int(body['seq']),
                float(body['ts']), body['bundle'])
        if not post_label_verify(vk, *args, body['sig']):
            proc.logger.warning('peer_post_label: BAD SIGNATURE, dropping')
            return True
        if not is_following(proc, body['community']):
            proc.logger.debug('peer_post_label for %s, which we do not follow: '
                              'dropped, not relayed', body['community'][:24])
            return True
        lid = post_label_id(*args)
        hops = int(body['hops'])
        with proc.lock:
            if _ring_seen_or_record_locked(proc.social._seen_post_label_ids, lid):
                return True
            _store_for_backfill_locked(proc.social.label_store, lid,
                                       float(body['ts']), author, body)
            proc.social.last_label[body['post_id']] = {
                'label_id': lid, 'community': body['community'],
                'seq': int(body['seq']), 'hops': hops, 'bundle': body['bundle']}
        (proc.logger.debug if via_group else proc.logger.info)(
            'label %s on %s accepted (hops=%d%s)', lid, body['post_id'], hops,
            '' if via_group else ', backfilled')
        if via_group and hops < POST_MAX_HOPS:
            fwd = dict(body)
            fwd['hops'] = hops + 1
            try:
                out = Message(proc.name, SocialProtocol.post_label,
                              to_json_string(fwd), to_whom=proc.group,
                              from_whom=proc.identity)
                queues[CfgIds.network].put(out, block=True, timeout=proc.q_cadence)
            except Full:
                proc.logger.error('_ingest_post_label: Network queue full')
    except Exception as err:
        proc.report_exception(err, '_ingest_post_label')
    return True


def get_last_post_label(proc, post_id):
    """The label last accepted for post ``post_id``, or {}. Twin of C
    ``identity_get_last_post_label``."""
    with proc.lock:
        rec = proc.social.last_label.get(str(post_id))
        return dict(rec) if rec else {}

# ------------------------------------------------------------------
# Detached co-signing (Phase 3 P3.3): a staff roll act decided by people who
# are not at the same keyboard. Their PRIVATE KEYS DO NOT TRAVEL — the
# record's exported bytes do, each signer signs them where its key already
# lives, and the authoring node reassembles the signatures onto the payload.
#
# Both messages are directed and ENCRYPTED, like a DM: crypto_box
# authenticates each end, so neither carries a signature of its own. This
# runtime is a COURIER. It holds no Ethne and cannot tell what the bytes
# mean; it does not hold the payload and cannot check the returned signature.
# It bounds and shape-checks, and it carries no description — see
# codec.py's cosign section for why that last one matters.
#
# Twin of the C block in id_social.c (handle_cosign_request, handle_cosign_sig,
# _send_cosign_request, _send_cosign_sig). The app-event emissions are
# C-only; a Python node records the most recent exchange per sender
# (get_last_cosign_request / get_last_cosign_sig) as the conformance
# observable, exactly as it does for a DM.
# ------------------------------------------------------------------

def request_cosign(proc, queues, peers, record, op, polity, cid, bytes_hex):
    """Ask each named peer to co-sign one record (twin of C
    ``handle_app_request_cosign``). ``peers`` are peer uuid strings; an
    unknown act or a payload no exporter produced is refused before anybody
    is interrupted to look at it. ONE freshness stamp covers the whole ask,
    so every copy of it is the same ask. Returns the number of peers the ask
    reached."""
    from .codec import cosign_request_to_json
    env = cosign_request_to_json(record, op, polity, cid, bytes_hex, 0, 0.0)
    if env is None:
        proc.logger.warning(
            'request_cosign: unknown op or bad payload, refusing')
        return 0
    seq = proc.freshness.stamp()
    if not seq or int(seq) <= 0:
        proc.logger.warning(
            'no freshness sequence; not asking to co-sign')
        return 0
    env['seq'] = int(seq)
    env['ts'] = float(int(time.time()))
    sent = 0
    total = 0
    for peer_uuid in (peers or []):
        total += 1
        peer = proc.peers.find_by_uuid(str(peer_uuid)) if proc.peers else None
        if peer is None:
            proc.logger.warning('request_cosign: unknown peer %s',
                                str(peer_uuid)[:8])
            continue
        try:
            out = Message(proc.name, SocialProtocol.cosign_request,
                          to_json_string(env), to_whom=peer,
                          from_whom=proc.identity, encrypt=True)
            queues[CfgIds.network].put(out, block=True,
                                       timeout=proc.q_cadence)
            sent += 1
        except Full:
            proc.logger.error('request_cosign: Network queue full')
        except Exception as err:
            proc.report_exception(err, 'request_cosign')
    proc.logger.info('co-signing ask (%s/%s) sent to %d of %d',
                     env['record'], env['op'], sent, total)
    return sent

def return_cosign(proc, queues, peer_uuid, cid, signer, sig):
    """Return THIS node's signature to the peer authoring the exchange (twin
    of C ``handle_app_return_cosign``). The private key never moved: the
    signature was made where it lives, and only its hex travels."""
    from .codec import cosign_sig_to_json
    env = cosign_sig_to_json(cid, signer, sig, 0, 0.0)
    if env is None:
        proc.logger.warning('return_cosign: empty field, refusing')
        return False
    peer = proc.peers.find_by_uuid(str(peer_uuid)) if proc.peers else None
    if peer is None:
        proc.logger.warning('return_cosign: unknown peer %s',
                            str(peer_uuid)[:8])
        return False
    seq = proc.freshness.stamp()
    if not seq or int(seq) <= 0:
        proc.logger.warning(
            'no freshness sequence; not returning signature')
        return False
    env['seq'] = int(seq)
    env['ts'] = float(int(time.time()))
    try:
        out = Message(proc.name, SocialProtocol.cosign_sig,
                      to_json_string(env), to_whom=peer,
                      from_whom=proc.identity, encrypt=True)
        queues[CfgIds.network].put(out, block=True, timeout=proc.q_cadence)
    except Full:
        proc.logger.error('return_cosign: Network queue full')
        return False
    except Exception as err:
        proc.report_exception(err, 'return_cosign')
        return False
    proc.logger.debug('co-signature returned to peer %s',
                      str(peer_uuid)[:8])
    return True

def handle_cosign_request(proc, queues, message):
    """An inbound co-signing ask — {record, op, polity, cid, bytes, seq, ts}:
    shape-checked, freshness-checked (per-sender replay guard), then recorded
    as the most recent ask from that sender. This runtime does NOT judge the
    request: whether this node is even a required signer is Ethne's question,
    answered on the app side against the payload itself. No app emission here
    (C runtime's job). Twin of C ``handle_cosign_request``."""
    if message.function != SocialProtocol.cosign_request:
        return False
    sender = getattr(message, 'from_whom', None)
    if sender is None:
        return True
    # A blocked peer cannot ask us to co-sign (Phase 4 P4.1). DROPPED at the
    # top: the ask lands in front of a person as a decision to make.
    # Blocking is not a governance act -- this says nothing about whether
    # the record is valid or whether this node is a required signer, only
    # that THIS person will not be asked by THAT one. Twin of C.
    if _is_blocked(proc, getattr(sender, 'uuid', None)):
        proc.logger.debug(
            'peer_cosign_request from %s dropped (locally blocked)',
            str(getattr(sender, 'uuid', ''))[:8])
        return True
    try:
        from .codec import cosign_request_from_json
        env = cosign_request_from_json(from_json_string(message.obj))
        if env is None:
            proc.logger.warning(
                'peer_cosign_request malformed/unknown op, refusing')
            return True
        if not proc.freshness.accept(str(getattr(sender, 'uuid', None)),
                                     SocialProtocol.cosign_request,
                                     env['seq']):
            proc.logger.debug(
                'peer_cosign_request from %s refused (replay/unstamped)',
                str(getattr(sender, 'uuid', ''))[:8])
            return True
        with proc.lock:
            proc.social.last_cosign_request[str(sender.uuid)] = dict(env)
        proc.logger.debug('co-signing ask (%s/%s) from peer %s',
                          env['record'], env['op'],
                          str(sender.uuid)[:8])
    except Exception as err:
        proc.report_exception(err, 'handle_cosign_request')
    return True

def handle_cosign_sig(proc, queues, message):
    """A returned signature — {cid, signer, sig, seq, ts}: shape-checked,
    freshness-checked, then recorded. This runtime does NOT verify it: it
    does not hold the payload the signature is over. The assembling node
    does, and refuses a wrong key or a tampered payload there. Twin of C
    ``handle_cosign_sig``."""
    if message.function != SocialProtocol.cosign_sig:
        return False
    sender = getattr(message, 'from_whom', None)
    if sender is None:
        return True
    try:
        from .codec import cosign_sig_from_json
        env = cosign_sig_from_json(from_json_string(message.obj))
        if env is None:
            proc.logger.warning('peer_cosign_sig malformed, refusing')
            return True
        if not proc.freshness.accept(str(getattr(sender, 'uuid', None)),
                                     SocialProtocol.cosign_sig,
                                     env['seq']):
            proc.logger.debug(
                'peer_cosign_sig from %s refused (replay/unstamped)',
                str(getattr(sender, 'uuid', ''))[:8])
            return True
        with proc.lock:
            proc.social.last_cosign_sig[str(sender.uuid)] = dict(env)
        proc.logger.debug('co-signature returned by peer %s',
                          str(sender.uuid)[:8])
    except Exception as err:
        proc.report_exception(err, 'handle_cosign_sig')
    return True

def get_last_cosign_request(proc, uuid_str):
    """The most-recent co-signing ask received from a peer uuid, as
    {'record','op','polity','cid','bytes','seq','ts'}, or {} if none.
    Conformance/assertion surface; twin of C
    ``identity_get_last_cosign_request``."""
    with proc.lock:
        return dict(proc.social.last_cosign_request.get(str(uuid_str), {}))

def get_last_cosign_sig(proc, uuid_str):
    """The most-recent co-signature returned by a peer uuid, as
    {'cid','signer','sig','seq','ts'}, or {} if none.
    Conformance/assertion surface; twin of C
    ``identity_get_last_cosign_sig``."""
    with proc.lock:
        return dict(proc.social.last_cosign_sig.get(str(uuid_str), {}))
