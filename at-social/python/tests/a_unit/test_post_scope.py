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

"""A post in a community's name (Phase 4, Ethne D37): the signed scope.

Pins the scoped canonical form, content id and signature that C
``test/post_scope_test.c`` pins, literal for literal, and that an unscoped
post's bytes and id are unchanged.
"""
import pytest
from nacl.signing import SigningKey

from autonomous_trust.social import codec

AUTHOR = bytes(range(0, 16))
SEED = bytes(range(1, 33))
DID = 'did:key:z6MkvZr75pe3PnPy11ixErx25xJ83E6MkqQQc4JpRogj3ytJ'
LABELS = ['nsfw', 'spoiler']

SCOPED_CANON_HEX = (
    '000102030405060708090a0b0c0d0e0f'
    '0700000000000000'
    '0000000000000000'
    '02'
    '02000000' '6869'
    '01'
    '3800'
    '6469643a6b65793a7a364d6b765a723735706533506e5079313169784572783235784a38'
    '3345364d6b71515163344a70526f676a3379744a'
    '02'
    '04' '6e736677'
    '07' '73706f696c6572'
)
SCOPED_ID = '004798b4ae862cb2b45b8a52cc7fbedc3dd067fbc55c68c63955b72edda19278'
SCOPED_SIG = (
    'ddbd7c978c0085c6168f0e8560c7ed42271a1fe58c4abb23baac619f4ad8b8c0'
    '1b2a871a58c02e8f2cb0a3a0df7e2c844b79cd4d4248412c5443f93befd17d0d'
)
UNSCOPED_ID = 'cea547b388f5ad97fa994ce0cbfff1bf62b679ff5a0c4eb6202b51c4c7513e7c'


def test_scoped_canonical_matches_the_c_vector():
    assert codec.post_canonical(AUTHOR, 7, 0.0, 2, 'hi', DID, LABELS).hex() \
        == SCOPED_CANON_HEX
    assert codec.post_content_id(AUTHOR, 7, 0.0, 2, 'hi', DID, LABELS) == SCOPED_ID


def test_an_unscoped_post_is_unchanged():
    assert codec.post_content_id(AUTHOR, 7, 0.0, 2, 'hi') == UNSCOPED_ID
    assert codec.post_content_id(AUTHOR, 7, 0.0, 2, 'hi', '', []) == UNSCOPED_ID


def test_the_signature_covers_the_scope():
    sk = SigningKey(SEED)
    sig = codec.post_sign(sk, AUTHOR, 7, 0.0, 2, 'hi', DID, LABELS)
    assert sig == SCOPED_SIG
    vk = sk.verify_key
    assert codec.post_verify(vk, AUTHOR, 7, 0.0, 2, 'hi', sig, DID, LABELS)
    assert not codec.post_verify(vk, AUTHOR, 7, 0.0, 2, 'hi', sig)
    assert not codec.post_verify(vk, AUTHOR, 7, 0.0, 2, 'hi', sig, DID, ['nsfw'])
    assert not codec.post_verify(vk, AUTHOR, 7, 0.0, 2, 'hi', sig, DID,
                                 LABELS + ['gore'])
    assert not codec.post_verify(vk, AUTHOR, 7, 0.0, 2, 'hi', sig,
                                 DID.replace('z6', 'Y6'), LABELS)


def test_labels_are_bounded_and_need_a_community():
    assert codec.post_label_valid('content-warning_2')
    for bad in ('', 'NSFW', 'two words', 'a,b', 'x' * 33):
        assert not codec.post_label_valid(bad)
    assert codec.post_scope_valid('', [])
    assert not codec.post_scope_valid('', ['nsfw'])
    assert codec.post_scope_valid(DID, ['nsfw'])
    assert not codec.post_scope_valid(DID, ['l%d' % i for i in range(9)])
    with pytest.raises(ValueError):
        codec.post_canonical(AUTHOR, 7, 0.0, 2, 'hi', '', ['nsfw'])


def test_normalize_sorts_and_dedups():
    assert codec.normalize_labels(['spoiler', 'nsfw', 'spoiler', 'art']) \
        == ['art', 'nsfw', 'spoiler']


@pytest.mark.parametrize('extra', [
    {'labels': ['nsfw']},
    {'community': '', 'labels': []},
    {'community': DID, 'labels': ['NSFW']},
    {'community': DID, 'labels': 'nsfw'},
    {'community': DID, 'labels': list('abcdefghi')},
])
def test_a_malformed_scope_is_refused(extra):
    body = {'author': str(AUTHOR), 'body': 'hi'}
    body.update(extra)
    assert codec.post_scope_from_json(body) is None


def test_an_absent_scope_is_unscoped():
    assert codec.post_scope_from_json({'body': 'hi'}) == ('', [])
