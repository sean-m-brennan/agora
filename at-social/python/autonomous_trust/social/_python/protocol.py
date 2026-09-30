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
"""The social verbs (FEATURE_SPLIT_PLAN Phase 5), moved out of
``IdentityProtocol`` with their strings unchanged: they ride the identity
process, so on the wire and over IPC nothing differs. The C twins are the
``AT_APP_*`` / message-type names in src/c/extensions/social/.
"""
from autonomous_trust.core._python.protocol import Protocol


class SocialProtocol(Protocol):
    """The verbs the social extension registers on the identity process."""
    # Opt-in coarse position (Increment 2, the "with-distance" feature). Mirrors
    # the caps directed exchange above: a confirmed peer asks for our coarse
    # geohash bucket; we answer ONLY if the operator opted in (own_geohash set),
    # with a freshness-stamped, group-encrypted {'pos', 'seq'} response. STRICTLY
    # OPT-IN — absent an own position we answer nothing, so no geographic datum
    # leaves the node. The geohash is opaque here (the app decodes it and computes
    # distance); a received one is untrusted, charset- and length-validated on the
    # way in. Both flow reliably via group/TCP like caps, not UDP broadcast.
    position_query = 'peer_position_query'  # msg.obj <- '' (sender just asks)
    position_response = 'peer_position_response'  # msg.obj <- json {'pos','seq'}
    # Opt-in agora.profile (Increment 3): same directed shape as position, plus a
    # detached Ed25519 signature over the canonical profile form so a profile is
    # self-verifying beyond the transport. A confirmed peer asks; we answer ONLY
    # if opted in (own_profile set) with {'profile','sig','seq'}. STRICTLY OPT-IN.
    # Not plaintext (rides group/TCP like caps), so NOT in UNENCRYPTED_VERBS.
    profile_query = 'peer_profile_query'  # msg.obj <- '' (sender just asks)
    profile_response = 'peer_profile_response'  # msg.obj <- json {'profile','sig','seq'}
    # Explicit connection edge-state (Increment 5): an EXPLICIT, revocable,
    # bilateral edge kept SEPARATE from reputation. The request is a bare ask;
    # the response carries a detached Ed25519 signature over the canonical
    # (requester, accepter, decision, seq) form (codec.connection_*), so
    # the requester verifies it before setting connected/declined. USER-INITIATED
    # (not auto-sent on confirm). Encrypted directed, so NOT in UNENCRYPTED_VERBS.
    connection_request = 'peer_connection_request'  # msg.obj <- '' (bare ask)
    connection_response = 'peer_connection_response'  # msg.obj <- json {'decision','sig','seq'}
    # Direct message (Increment 6): a single one-way peer->peer text message
    # carrying {text, seq, ts}. crypto_box authenticates the sender, so there is
    # NO signature (unlike connection accept). NO request/response, NO gossip,
    # NO roster replay -- delivered on arrival. Encrypted directed, so NOT in
    # UNENCRYPTED_VERBS. `seq` is a per-sender freshness/replay guard.
    dm = 'peer_dm'  # msg.obj <- json {'text','seq','ts'}
    # Feed post (Increment 7): a signed, content-addressed feed item distributed
    # by encrypted GROUP MULTICAST and gossip-forwarded a bounded number of hops.
    # UNLIKE a DM, a post is relayed by peers other than its author, so authorship
    # comes from a detached Ed25519 signature over the canonical (author, seq, ts,
    # required_tier, body) form (codec.post_*), verified before the tier-
    # gate/dedup/emit. Group-encrypted, so NOT in UNENCRYPTED_VERBS.
    post = 'peer_post'  # msg.obj <- json {author,author_pk,seq,ts,tier,body,sig,hops}
    # Post reaction (Increment 8): the return signal a fire-and-forget post lacks.
    # A directed, ENCRYPTED reactor->author message {post_id, seq, ts}, exactly
    # like a DM (crypto_box authenticates the reactor). It lets both peers submit a
    # reputation score for the same post-derived task, so the engagement accrues.
    # Encrypted, so NOT in UNENCRYPTED_VERBS.
    reaction = 'peer_reaction'  # msg.obj <- json {post_id, seq, ts}
    # First-person report (Phase 4 P4.1). Directed + ENCRYPTED like a reaction,
    # carrying {seq, ts} and NOTHING ELSE -- a reason on the wire would make a
    # score a published accusation. The reported node stages its half of the
    # bilateral transaction and tells its app nothing. NOT in UNENCRYPTED_VERBS.
    report = 'peer_report'  # msg.obj <- json {seq, ts}
    # Private-proximity probe/reply (Phase 2): two CONNECTED peers exchange
    # multi-resolution grid tags keyed by the pairwise box secret (proximity.py)
    # so each learns only a coarse distance BAND (near/mid/far), never
    # coordinates. Directed + ENCRYPTED (the tags are already opaque without the
    # key, but the directed leg is encrypted like a DM), so NOT in
    # UNENCRYPTED_VERBS. proximity_trigger is a LOCAL-ONLY IPC verb (like
    # attest_trigger): a consumer asks us to probe one connected peer.
    # Business ad (Phase 3 P3.2): one business page — an opaque, SELF-VERIFYING
    # Ethne bundle — plus the signed statement of the node advertising it.
    # Group-encrypted like a post, so NOT in UNENCRYPTED_VERBS. UNLIKE a post it
    # is NEVER relayed and carries no hop count: only a CUSTOMER carries a
    # business's page, and a customer re-advertises from its own cache in the
    # FIRST PERSON (own key, own satisfaction) rather than forwarding someone
    # else's ad. A business's reach is therefore exactly the sum of its
    # customers' voices. The bundle is opaque to the runtime — the app verifies
    # polity-root -> envoy -> page; what the runtime verifies is the detached
    # Ed25519 signature binding who vouched, how happy, for which page bytes.
    business_ad = 'peer_business_ad'  # msg.obj <- json {advertiser,advertiser_pk,polity,sat,seq,ts,bundle,sig}

    # Business post (Phase 3 P3.4): the polity SPEAKING, where the page is what
    # it IS. Group multicast, and UNLIKE an ad it is RELAYED a bounded number of
    # hops — its authority is the ENVOY signature sealed inside the opaque
    # {post,delegation} bundle, so passing it along cannot launder it and
    # altering a word breaks two signatures at once. The signature here
    # authenticates only WHO SENT THIS COPY. A receiver drops a post from a
    # polity it holds no page for, and does not relay it.
    business_post = 'peer_business_post'  # msg.obj <- json {author,author_pk,polity,seq,ts,bundle,sig,hops}
    # Detached co-signing (Phase 3 P3.3): a staff roll act — admitting,
    # expelling, designating a machine, moving or releasing its guardian —
    # decided by several people who are not at the same keyboard. The record
    # travels; their PRIVATE KEYS DO NOT. One node exports the record's
    # canonical bytes, each required signer signs those bytes where its key
    # already lives, and the authoring node reassembles the signatures onto the
    # payload. Both verbs are directed and ENCRYPTED, like a DM (crypto_box
    # authenticates each end), so neither carries a signature of its own and
    # neither is in UNENCRYPTED_VERBS. `seq` is a per-sender freshness/replay
    # guard.
    #
    # This runtime is a COURIER here and nothing more: it holds no Ethne, so it
    # cannot know what `bytes` means, and it does not hold the payload, so it
    # cannot check a returned signature. It bounds and shape-checks
    # (codec.cosign_*), and the app answers whether this node is even a
    # required signer.
    #
    # WHAT DELIBERATELY DOES NOT CROSS: the human-legible DESCRIPTION of what is
    # being signed. The signer's own node derives it from the bytes. Carrying it
    # would let the ASKING node choose both what you sign and what you are told
    # you are signing — a friendly sentence over hostile bytes, with a real
    # signature on the end.
    cosign_request = 'peer_cosign_request'  # msg.obj <- json {record,op,polity,cid,bytes,seq,ts}
    cosign_sig = 'peer_cosign_sig'  # msg.obj <- json {cid,signer,sig,seq,ts}
    # STORE-AND-FORWARD (Agora Phase 4 DDIL). A post is a fire-and-forget
    # multicast, so a node off the segment when it went out (the other island of
    # a partition) never hears it. The digest (group, encrypted) advertises the
    # content ids of our recent stored posts; the want (directed, encrypted)
    # asks the digest's sender for the ones we lack; the backfill (directed,
    # encrypted) carries one stored post's ORIGINAL signed envelope, which the
    # receiver re-verifies and gates exactly as the original, and never relays.
    # None is in UNENCRYPTED_VERBS. Twins of C ID_POST_DIGEST / ID_POST_WANT /
    # ID_POST_BACKFILL.
    post_digest = 'peer_post_digest'      # msg.obj <- json {'feed': [ids], 'biz': [ids]}
    post_want = 'peer_post_want'          # msg.obj <- json {'feed': [ids], 'biz': [ids]}
    post_backfill = 'peer_post_backfill'  # msg.obj <- json {'kind': 'feed'|'biz', 'post': {...}}
    # COMMUNITIES (Phase 4, Ethne D37). A community's root-signed content
    # policy, CARRIED IN THE FIRST PERSON by a node that follows it (never
    # relayed, like a business ad), and a moderator's member-signed labels on
    # one post (relayed a bounded number of hops by followers, like a business
    # post). Both bundles are opaque to this runtime; the app verifies them and
    # decides what a label does. Group-encrypted, so NOT in UNENCRYPTED_VERBS.
    # Twins of C ID_COMMUNITY_POLICY / ID_POST_LABEL.
    community_policy = 'peer_community_policy'  # msg.obj <- json {carrier,carrier_pk,community,seq,ts,bundle,sig}
    post_label = 'peer_post_label'  # msg.obj <- json {author,author_pk,community,post_id,seq,ts,bundle,sig,hops}
    proximity_probe = 'peer_proximity_probe'      # msg.obj <- json {'salt','tags'}
    proximity_reply = 'peer_proximity_reply'      # msg.obj <- json {'salt','tags'}
    proximity_trigger = 'peer_proximity_trigger'  # local IPC: {'target': uuid_str}
