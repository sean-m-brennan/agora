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
"""SocialProtocol, the verbs that left IdentityProtocol (FEATURE_SPLIT_PLAN
Phase 5) with their strings unchanged."""
from autonomous_trust.core.identity.protocol import IdentityProtocol
from autonomous_trust.social.protocol import SocialProtocol


def test_the_20_verbs():
    """Iterates the social verbs.

        - opt-in coarse position, the "with-distance" feature
          (position_query, position_response)
        - opt-in signed agora.profile, Increment 3
          (profile_query, profile_response)
        - explicit, revocable connection edges, Increment 5
          (connection_request, connection_response)
        - directed encrypted direct messages, Increment 6 (dm)
        - signed, content-addressed feed posts, Increment 7 (post)
        - directed encrypted post reactions, Increment 8 (reaction)
        - opt-in private proximity: two connected peers swap
          key-derived grid tags to learn only a coarse distance
          band (proximity_probe, proximity_reply, and its
          local-only trigger proximity_trigger)
        - business pages carried by their own customers, Phase 3
          (business_ad) — every ad on the wire is first-person, so
          one verb covers the business advertising itself and a
          happy customer re-advertising what it learned
        - detached co-signing of staff roll acts, Phase 3 P3.3
          (cosign_request, cosign_sig) — the record's bytes travel
          and the signers' private keys do not, so it takes two
          verbs: the ask carrying the exported payload, and the
          signature coming back. The human-legible description of
          what is being signed is deliberately NOT a field on
          either: the signer's own node derives it from the bytes.
        - business POSTS, Phase 3 P3.4 (business_post) — the polity
          speaking, where the page is what it is. One verb, not two:
          unlike an ad it IS relayed, and a relay forwards the
          publisher's own envelope untouched and bumps only the hop
          count, so a carried post is the same message rather than a
          second one. Its authority is the envoy signature sealed in
          the opaque bundle, which this tier never opens.
        - first-person reports, Phase 4 P4.1 (report) — directed and
          encrypted like a reaction, {seq, ts} only. No reason travels:
          on the wire it would make a score a published accusation.
        - store-and-forward, Phase 4 DDIL (post_digest, post_want,
          post_backfill) — a post is a fire-and-forget multicast, so a
          node off the segment when it went out (the other island of a
          partition) asks for it afterwards. Three verbs, not one: the
          periodic digest of ids, the directed want for the missing ones,
          and the directed backfill carrying one post's ORIGINAL signed
          envelope, which the receiver re-verifies and never relays.
        Asserting the exact count here pins the wire contract — a
        new verb without intent will fail this and force a deliberate
        update.
    """
    values = list(SocialProtocol)
    assert len(values) == 20
    for verb in ('report', 'business_ad', 'business_post', 'cosign_request',
                 'cosign_sig', 'dm', 'proximity_trigger', 'post_digest',
                 'post_want', 'post_backfill'):
        assert verb in values, verb


def test_strings_are_unchanged():
    # What the C side (social_msg_types.h) and every peer already speak.
    assert SocialProtocol.dm == 'peer_dm'
    assert SocialProtocol.post == 'peer_post'
    assert SocialProtocol.report == 'peer_report'
    assert SocialProtocol.position_query == 'peer_position_query'
    assert SocialProtocol.proximity_trigger == 'peer_proximity_trigger'
    assert SocialProtocol.cosign_sig == 'peer_cosign_sig'


def test_disjoint_from_identity():
    ours = {getattr(SocialProtocol, v) for v in SocialProtocol}
    core = {getattr(IdentityProtocol, v) for v in IdentityProtocol}
    assert not ours & core
    assert not set(SocialProtocol) & set(IdentityProtocol)
