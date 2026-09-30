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

"""The policy ad and the post label (Phase 4, Ethne D37). Pins the canonical
bytes and ids that C ``test/community_test.c`` pins, literal for literal."""
from nacl.signing import SigningKey

from autonomous_trust.social import codec

WHO = bytes(range(0, 16))
DID = 'did:key:z6MkvZr75pe3PnPy11ixErx25xJ83E6MkqQQc4JpRogj3ytJ'
POST = 'a' * 64

POLICY_CANON_HEX = (
    '000102030405060708090a0b0c0d0e0f'
    '38000000'
    '6469643a6b65793a7a364d6b765a723735706533506e5079313169784572783235784a38'
    '3345364d6b71515163344a70526f676a3379744a'
    '0300000000000000'
    '0000000000000000'
    '07000000' '7b2270223a317d'
)
POLICY_ID = '2366865e4adc460c0c88b27a0d8f28ab0b39b72920689dd6c844d8f9cc8886bd'
LABEL_CANON_HEX = (
    '000102030405060708090a0b0c0d0e0f'
    '38000000'
    '6469643a6b65793a7a364d6b765a723735706533506e5079313169784572783235784a38'
    '3345364d6b71515163344a70526f676a3379744a'
    + '61' * 64 +
    '0200000000000000'
    '0000000000000000'
    '07000000' '7b226c223a317d'
)
LABEL_ID = 'c01a4cf23de76552d184a670c9f79a0b1d9ae0ff4ac0a4cd20ee79a08531f505'


def test_policy_ad_matches_the_c_vector():
    assert codec.policy_ad_canonical(WHO, DID, 3, 0.0, '{"p":1}').hex() \
        == POLICY_CANON_HEX
    assert codec.policy_ad_id(WHO, DID, 3, 0.0, '{"p":1}') == POLICY_ID


def test_post_label_matches_the_c_vector():
    assert codec.post_label_canonical(WHO, DID, POST, 2, 0.0, '{"l":1}').hex() \
        == LABEL_CANON_HEX
    assert codec.post_label_id(WHO, DID, POST, 2, 0.0, '{"l":1}') == LABEL_ID


def test_signatures_bind_every_field():
    sk = SigningKey(bytes(range(1, 33)))
    vk = sk.verify_key
    sig = codec.policy_ad_sign(sk, WHO, DID, 3, 0.0, '{"p":1}')
    assert codec.policy_ad_verify(vk, WHO, DID, 3, 0.0, '{"p":1}', sig)
    assert not codec.policy_ad_verify(vk, WHO, DID, 4, 0.0, '{"p":1}', sig)
    assert not codec.policy_ad_verify(vk, WHO, DID, 3, 0.0, '{"p":2}', sig)
    sig = codec.post_label_sign(sk, WHO, DID, POST, 2, 0.0, '{"l":1}')
    assert codec.post_label_verify(vk, WHO, DID, POST, 2, 0.0, '{"l":1}', sig)
    assert not codec.post_label_verify(vk, WHO, DID, 'b' * 64, 2, 0.0,
                                       '{"l":1}', sig)


def test_post_ids_are_64_lowercase_hex():
    assert codec.community_post_id_valid(POST)
    for bad in ('A' * 64, 'a' * 63, 'g' * 64, None, 7):
        assert not codec.community_post_id_valid(bad)
