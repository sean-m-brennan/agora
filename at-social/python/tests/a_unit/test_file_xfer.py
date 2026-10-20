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
"""The pure half of DM file sharing, Python side (social/_python/file_xfer.py).

The name table is the same one c/social/test/file_xfer_test.c holds: a peer's
name becomes a path on this disk in both runtimes, so they must agree byte for
byte. The protocol itself is pinned by the conformance scenarios
(scenarios/social/file-*.yaml), which both runtimes run.
"""
import base64
import hashlib

import pytest

from autonomous_trust.social import file_xfer as fx

ID = '0123456789abcdef0123456789abcdef'


@pytest.mark.parametrize('raw, want', [
    ('report.pdf', 'report.pdf'),
    ('/etc/passwd', 'passwd'),
    ('../../.ssh/authorized_keys', 'authorized_keys'),
    ('..\\..\\boot.ini', 'boot.ini'),
    ('..', 'file'),
    ('.', 'file'),
    ('', 'file'),
    (None, 'file'),
    ('dir/', 'file'),
    ('a\nb\tc\x7f.txt', 'abc.txt'),
    ('what?<now>:"|*.txt', 'what__now_____.txt'),
    ('trailing.  ', 'trailing'),
    ('NUL.txt', 'file'),
    ('com1', 'file'),
    ('console.log', 'console.log'),
    ('.bashrc', '.bashrc'),
])
def test_a_name_is_never_a_path(raw, want):
    assert fx.sanitize_name(raw) == want


def test_a_long_name_is_cut_on_a_character_boundary():
    name = fx.sanitize_name('a' * 254 + '€')
    assert name == 'a' * 254


def test_an_offer_whose_numbers_disagree_is_refused():
    good = {'id': ID, 'name': '../x.bin', 'size': 40000, 'chunk': 16384,
            'total': 3, 'hash': 'a' * 64, 'ts': 1.0}
    assert fx.offer_from_json(good)['name'] == 'x.bin'
    for k, v in (('total', 1000000), ('chunk', 16), ('size', -1),
                 ('hash', 'not-hex'), ('id', ID.upper()), ('ts', True)):
        assert fx.offer_from_json(dict(good, **{k: v})) is None, k


def test_a_peer_reason_is_a_token():
    assert fx.ctl_from_json({'id': ID, 'op': 'fail',
                             'reason': 'Hash Mismatch!; rm -rf'}) \
        == (ID, fx.OP_FAIL, 'ashismatchrmrf')
    assert fx.ctl_from_json({'id': ID, 'op': 'explode'}) is None


def test_requests_and_chunks_are_bounded():
    assert fx.req_from_json({'id': ID, 'first': 7, 'count': 16}) == (ID, 7, 16)
    assert fx.req_from_json({'id': ID, 'first': 0, 'count': 0}) is None
    assert fx.req_from_json({'id': ID, 'first': 0, 'count': fx.REQ_MAX + 1}) is None
    data = bytes(range(256)) * 4
    body = {'id': ID, 'i': 2, 'data': base64.b64encode(data).decode()}
    assert fx.chunk_from_json(body) == (ID, 2, data)
    assert fx.chunk_from_json(body, buf_max=999) is None
    assert fx.chunk_from_json(dict(body, data='!!!!')) is None


def test_the_hash_is_libsodiums(tmp_path):
    # crypto_generichash with a 32-byte output is unkeyed BLAKE2b-256.
    p = tmp_path / 'f'
    p.write_bytes(b'hello')
    assert fx.hash_file(str(p), 5) == hashlib.blake2b(b'hello', digest_size=32).hexdigest()
    assert fx.hash_file(str(p), 6) is None


def test_the_store_round_trips_and_skips_bad_records(tmp_path):
    rec = {'id': ID, 'peer': '12345678-1234-5678-1234-567812345678', 'dir': 'out',
           'state': fx.ACCEPTED, 'name': 'a.bin', 'path': '/home/me/a.bin',
           'reason': '', 'size': 40000, 'mtime': 1234, 'chunk': 16384,
           'total': 3, 'hash': 'b' * 64, 'created': 10.0, 'updated': 11.0}
    fx.store_save([rec], str(tmp_path))
    assert fx.store_load(str(tmp_path)) == [rec]
    fx.store_save([rec, dict(rec, total=99)], str(tmp_path))
    assert fx.store_load(str(tmp_path)) == [rec]
    (tmp_path / fx.STORE_FILENAME).write_text('{not json')
    assert fx.store_load(str(tmp_path)) is None
