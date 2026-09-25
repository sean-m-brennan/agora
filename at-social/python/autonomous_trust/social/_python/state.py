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
"""The social feature's per-process state (FEATURE_SPLIT_PLAN Phase 5).

What IdentityProcess.__init__ used to set on itself, now ``proc.social``: set
by the extension when identity registers its handlers. Plain picklable values
only, since multiproc mode ships the process to its worker.
"""
import os
from autonomous_trust.core._python.config import from_json_string

from .handlers import _geohash_valid


class SocialState:
    """Today's IdentityProcess field names, kept so the twin C fields
    (social_state in id_social.c) still line up by name."""

    @classmethod
    def from_env(cls, logger=None):
        """Seeded from $AT_OWN_GEOHASH / $AT_OWN_EXACT / $AT_OWN_PROFILE, as
        IdentityProcess.__init__ was."""
        state = cls()
        # Opt-in coarse position (Increment 2, the "with-distance" feature).
        # own_geohash: THIS node's shared bucket; empty = opted OUT, the DEFAULT,
        # so nothing geographic is advertised or answered. Seeded from
        # $AT_OWN_GEOHASH for headless/conformance parity with the C
        # _ensure_id_init seed; the Flutter UI (C runtime) sets it live via the
        # app IPC verb, which a Python node has no equivalent of. peer_positions
        # maps a peer uuid string -> its shared geohash, filled by
        # handle_position_response. See SOCIAL_APP_PLAN.md §3.2/§4.2.
        _own_geo = os.environ.get('AT_OWN_GEOHASH', '')
        state.own_geohash = _own_geo if _geohash_valid(_own_geo) else ''
        state.peer_positions: dict = {}
        # Opt-in EXACT position (Phase 2, private proximity): (lat, lon) degrees,
        # or None = opted out (the default). LOCAL-ONLY — never advertised; it
        # feeds only the pairwise distance-band probe with connected peers. Seeded
        # from $AT_OWN_EXACT ("lat,lon") for headless/conformance parity with C
        # (the app IPC set-path is C-only, like own_geohash). peer_proximity maps
        # a peer uuid string -> the last band learned (int; see proximity.ProxBand),
        # the conformance surface (get_peer_proximity), twin of the C emit.
        state.own_exact = None
        _own_exact_raw = os.environ.get('AT_OWN_EXACT', '')
        if _own_exact_raw:
            try:
                _la, _lo = (float(v) for v in _own_exact_raw.split(',', 1))
                if -90.0 <= _la <= 90.0 and -180.0 <= _lo <= 180.0:
                    state.own_exact = (_la, _lo)
            except (ValueError, TypeError):
                state.own_exact = None
        state.peer_proximity: dict = {}
        # Opt-in agora.profile (Increment 3): own_profile is THIS node's shared,
        # signed profile fields; empty = opted OUT (the default). Seeded from
        # $AT_OWN_PROFILE (a JSON object) for headless/conformance parity with C
        # _ensure_id_init; the app IPC set-path is C-only. peer_profiles maps a
        # peer uuid string -> its shared (verified) profile dict, filled by
        # handle_profile_response.
        state.own_profile: dict = {}
        _own_prof_raw = os.environ.get('AT_OWN_PROFILE', '')
        if _own_prof_raw:
            try:
                from .codec import sanitize_profile
                parsed = from_json_string(_own_prof_raw)
                if isinstance(parsed, dict):
                    state.own_profile = sanitize_profile(parsed)
            except Exception:  # noqa: BLE001 — bad env seed => opted out
                state.own_profile = {}
        state.peer_profiles: dict = {}
        # Explicit connections (Increment 5): peer uuid string -> edge state int
        # (an EXPLICIT, revocable edge SEPARATE from reputation; none=0,
        # pending_out=1, pending_in=2, connected=3, declined=4). Filled by
        # handle_connection_request/response. The app-driven request/respond
        # verbs and app-event emission are C-only (as with position/profile);
        # a Python node maintains the edge map (get_connection_state, the
        # conformance surface). USER-INITIATED: nothing is auto-sent on confirm.
        state.connection_edges: dict = {}
        # Direct messages (Increment 6): the most-recent DM received per sender,
        # peer uuid string -> {'seq','ts','text'}. A DM is a LIVE STREAM
        # delivered to the app on arrival, so this is NOT roster state (it is
        # never replayed); it exists purely as the conformance/observability
        # surface for get_last_dm, the twin of C identity_get_last_dm. The
        # app-driven send verb and app-event emission are C-only (as with
        # position/profile/connection). Filled by handle_dm after freshness.
        state.last_dm: dict = {}
        # Feed posts (Increment 7): the most-recent post accepted per AUTHOR uuid
        # string -> {'post_id','seq','ts','tier','body'} (get_last_post, twin of C
        # identity_get_last_post), and the bounded app-content dedup ring of
        # accepted content ids (twin of C id_state.seen_post_ids). Both are the
        # observability surface; a post is a live stream, never roster-replayed.
        state.last_post: dict = {}
        state._seen_post_ids: list = []
        # Businesses (Phase 3 P3.2). business_customers is THIS node's own
        # customer edges (polity did -> {'sat','since','bundle','seq'}); it is
        # the RELAY GATE and the only thing that authorizes this node to carry a
        # page — no entry, no ad. business_pages is what we have LEARNED (polity
        # did -> {'bundle','seq','ts','endorsers'}); newest page wins by seq,
        # endorsers merge. _seen_business_ad_ids is the bounded ad-content-id
        # dedup ring. The bundles held here are OPAQUE: this runtime never parses
        # Ethne, the app does. Twins of C id_state.business_customers /
        # business_pages / seen_business_ads.
        state.business_customers: dict = {}
        state.business_pages: dict = {}
        state._seen_business_ad_ids: list = []
        # Business posts (Phase 3 P3.4). _seen_business_post_ids is the
        # post-content dedup ring (what stops a relayed post echoing round the
        # group); _business_post_seq is THIS node's own publish counter;
        # last_business_post is the assertion surface, keyed by POLITY DID —
        # a post belongs to the business, not to whoever relayed it. Twins of C
        # id_state.seen_business_posts / business_post_seq /
        # last_business_post_map.
        state._seen_business_post_ids: list = []
        state._business_post_seq: int = 0
        state.last_business_post: dict = {}
        # Store-and-forward (Agora Phase 4 DDIL): the recent signed posts this
        # node can backfill, one store per kind (content id -> {'ts','author',
        # 'env'}, oldest first, capped at POST_STORE_CAP); when our last digest
        # went out (0 == due now); and, per peer uuid, when we last sent it a
        # want and last served one of its wants (the two rate limits). Twins
        # of C social_state.feed_store / biz_store / last_digest_at /
        # want_sent_at / want_served_at.
        from collections import OrderedDict
        state.feed_store = OrderedDict()
        state.biz_store = OrderedDict()
        state.last_digest_at: float = 0.0
        state.want_sent_at: dict = {}
        state.want_served_at: dict = {}
        # Detached co-signing (Phase 3 P3.3). The most recent ask received from
        # each peer, and the most recent signature each peer returned — a live
        # stream, never roster-replayed, exactly like a DM. Nothing here is
        # judged or verified: the payload is opaque Ethne bytes and the app
        # answers both "am I a required signer" and "is this signature good".
        state.last_cosign_request: dict = {}
        state.last_cosign_sig: dict = {}
        # Social-interaction reputation accrual (Increment 8). Per-edge bookkeeping
        # (peer uuid str -> {'count','last_out','last_in','day','day_count'}) drives
        # the diminishing S_pos(count) and the bilateral_recent + daily-cap gate,
        # exactly as C id_state.social_edges. social_tx_last (subject uuid str ->
        # {'task','score','channel','n'}) is the deterministic accrual observable,
        # where n counts every score staged about the subject; recorded at the
        # moment we would move a peer's reputation (twin of C
        # identity_get_last_social_tx; conformance asserts via social_tx_last).
        # social_blocks clamps a peer's local tier to 0 (twin of C social_blocks).
        state.social_edges: dict = {}
        state.social_tx_last: dict = {}
        # First-person reports (Phase 4 P4.1): peer uuid str -> {'day','out','in'},
        # how many reports WE made about that peer today and how many FROM it we
        # paired. Separate from social_edges, exactly as C id_state.social_reports.
        state.social_reports: dict = {}
        # {uuid_str: at_epoch_float}. A DICT, not a set, since Phase 4 P4.1:
        # "blocked" is still membership, but the value carries WHEN so the
        # durable store has something to write back. Mirrors the C map, whose
        # value is likewise the timestamp rather than a flag.
        state.social_blocks: dict = {}
        state._social_day: int = 0
        state._social_day_count: int = 0
        return state
