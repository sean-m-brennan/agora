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
"""The social feature as an identity extension (FEATURE_SPLIT_PLAN Phase 5).

Registers social's 17 verbs on the identity process (``functools.partial`` of
module functions, so the process still pickles), sets ``proc.social``, and
follows identity through the IdentityHooks the core calls: admission, the
periodic resync, and the blocked-peer check behind ``get_peer_tier``. Its
``post_fork`` restores the local blocks before the process takes traffic, as
C's ``run_start`` hook does. Present
means on. The Python twin of src/c/extensions/social/id_social.c's extension
tables.
"""
import functools

from autonomous_trust.core._python.extensions import Extension, IdentityHooks
from .protocol import SocialProtocol
from . import handlers
from .state import SocialState


def _enabled() -> bool:
    # Present means on: a node that has this package has social.
    return True


def _register(proc, proc_name: str) -> None:
    if proc_name != 'identity':
        return
    proc.social = SocialState.from_env(getattr(proc, 'logger', None))
    proc.protocol.register_handler(SocialProtocol.position_query,
                                   functools.partial(handlers.handle_position_query, proc))
    proc.protocol.register_handler(SocialProtocol.position_response,
                                   functools.partial(handlers.handle_position_response, proc))
    proc.protocol.register_handler(SocialProtocol.business_ad,
                                   functools.partial(handlers.handle_business_ad, proc))
    proc.protocol.register_handler(SocialProtocol.business_post,
                                   functools.partial(handlers.handle_business_post, proc))
    proc.protocol.register_handler(SocialProtocol.cosign_request,
                                   functools.partial(handlers.handle_cosign_request, proc))
    proc.protocol.register_handler(SocialProtocol.cosign_sig,
                                   functools.partial(handlers.handle_cosign_sig, proc))
    proc.protocol.register_handler(SocialProtocol.proximity_trigger,
                                   functools.partial(handlers.handle_proximity_trigger, proc))
    proc.protocol.register_handler(SocialProtocol.proximity_probe,
                                   functools.partial(handlers.handle_proximity_probe, proc))
    proc.protocol.register_handler(SocialProtocol.proximity_reply,
                                   functools.partial(handlers.handle_proximity_reply, proc))
    proc.protocol.register_handler(SocialProtocol.profile_query,
                                   functools.partial(handlers.handle_profile_query, proc))
    proc.protocol.register_handler(SocialProtocol.profile_response,
                                   functools.partial(handlers.handle_profile_response, proc))
    proc.protocol.register_handler(SocialProtocol.connection_request,
                                   functools.partial(handlers.handle_connection_request, proc))
    proc.protocol.register_handler(SocialProtocol.connection_response,
                                   functools.partial(handlers.handle_connection_response, proc))
    proc.protocol.register_handler(SocialProtocol.dm,
                                   functools.partial(handlers.handle_dm, proc))
    proc.protocol.register_handler(SocialProtocol.post,
                                   functools.partial(handlers.handle_post, proc))
    proc.protocol.register_handler(SocialProtocol.reaction,
                                   functools.partial(handlers.handle_reaction, proc))
    proc.protocol.register_handler(SocialProtocol.report,
                                   functools.partial(handlers.handle_peer_report, proc))
    proc.protocol.register_handler(SocialProtocol.post_digest,
                                   functools.partial(handlers.handle_post_digest, proc))
    proc.protocol.register_handler(SocialProtocol.post_want,
                                   functools.partial(handlers.handle_post_want, proc))
    proc.protocol.register_handler(SocialProtocol.post_backfill,
                                   functools.partial(handlers.handle_post_backfill, proc))


def _post_fork(proc) -> None:
    # Local moderation state (Phase 4 P4.1), restored BEFORE the identity
    # process takes traffic: a block that only took effect once the app had
    # reconnected and replayed it would leave a window in which the blocked
    # peer's DMs and posts land. Twin of C _social_run_start. Every process
    # that loaded social runs this; only identity carries proc.social.
    if getattr(proc, 'social', None) is None:
        return
    n = handlers.load_social_blocks(proc)
    if n:
        proc.logger.info('Identity: restored %d local block(s)', n)


def _on_peer_confirmed(proc, queues, peer) -> None:
    # Opt-in position (Increment 2, the "with-distance" feature): ask
    # every confirmed peer for its coarse position — unconditionally,
    # unlike caps_query (a recovery-only path), because position has no
    # announce-broadcast path to recover from. An opted-out peer answers
    # nothing; the resync sweep re-asks, so a peer that opts in later is
    # still picked up. Mirrors the C _send_position_query in
    # handle_confirm_peer.
    handlers._send_position_query(proc, queues, peer)
    # Opt-in profile (Increment 3): same pattern — ask every confirmed
    # peer for its agora.profile; an opted-out peer answers nothing.
    handlers._send_profile_query(proc, queues, peer)
    # Store-and-forward: a peer we just confirmed may have missed our posts
    # (a partition healing, a late joiner), so the next sweep sends a digest
    # whatever the interval says. Twin of C _social_peer_confirmed.
    with proc.lock:
        proc.social.last_digest_at = 0.0


def _periodic_resync(proc, queues) -> None:
    # Position resync (Increment 2, opt-in coarse position): re-query
    # admitted peers we hold NO stored position for. An opted-out peer
    # answers nothing and is simply re-asked next sweep; a peer that opts
    # in later is picked up here. Mirrors the C position block in
    # identity_periodic_caps_resync. Reuses the reliable directed query
    # — no new wire message, so Python/C wire parity is unaffected.
    with proc.lock:
        if proc.peers is None:
            return
        self_uuid = str(proc.identity.uuid)
        posless = [
            peer for peer in proc.peers.all
            if str(peer.uuid) != self_uuid
            and str(peer.uuid) not in proc.social.peer_positions
        ]
    psent = 0
    for peer in posless:
        if psent >= proc._CAPS_RESYNC_MAX_PER_SWEEP:
            break
        handlers._send_position_query(proc, queues, peer)
        psent += 1
    if psent:
        proc.logger.debug(
            'Position resync: re-queried %d position-less peer(s)', psent)
    # Profile resync (Increment 3): same pattern, keyed on peer_profiles.
    with proc.lock:
        if proc.peers is None:
            return
        self_uuid = str(proc.identity.uuid)
        profless = [
            peer for peer in proc.peers.all
            if str(peer.uuid) != self_uuid
            and str(peer.uuid) not in proc.social.peer_profiles
        ]
    fsent = 0
    for peer in profless:
        if fsent >= proc._CAPS_RESYNC_MAX_PER_SWEEP:
            break
        handlers._send_profile_query(proc, queues, peer)
        fsent += 1
    if fsent:
        proc.logger.debug(
            'Profile resync: re-queried %d profile-less peer(s)', fsent)
    # Store-and-forward: advertise our recent posts, at most every
    # $AT_SOCIAL_DIGEST_SEC. Twin of C _maybe_send_post_digest.
    handlers.maybe_send_post_digest(proc, queues)


def _is_blocked_locked(proc, uuid_str) -> bool:
    return handlers._is_blocked_locked(proc, uuid_str)


EXTENSION = Extension(
    name='social', enabled=_enabled, register_handlers=_register,
    post_fork=_post_fork,
    identity=IdentityHooks(on_peer_confirmed=_on_peer_confirmed,
                           periodic_resync=_periodic_resync,
                           is_blocked_locked=_is_blocked_locked))
