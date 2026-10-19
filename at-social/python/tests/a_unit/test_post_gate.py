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
"""The receive tier gate drops an under-tier post with a line at INFO.

A post dropped by the gate and a post lost on the wire looked the same at INFO
(moderation cohort mod-2555501, phase 6), so the cohort could not tell which
had happened. The drop is logged at INFO in both runtimes (C `_ingest_post`).
"""
import logging
import threading
import types
import uuid

from nacl.signing import SigningKey

from autonomous_trust.social import codec
from autonomous_trust.social._python.handlers import _ingest_post

AUTHOR = str(uuid.UUID(bytes=bytes(range(16))))
KEY = SigningKey(bytes(range(1, 33)))


def _post(tier):
    sig = codec.post_sign(KEY, AUTHOR, 7, 0.0, tier, "hi")
    return {'author': AUTHOR, 'author_pk': bytes(KEY.verify_key).hex(),
            'seq': 7, 'ts': 0.0, 'tier': tier, 'body': "hi", 'sig': sig,
            'hops': 0}


def _proc(peer_tier, known):
    peer = types.SimpleNamespace(
        signature=types.SimpleNamespace(public=KEY.verify_key))
    peers = types.SimpleNamespace(
        find_by_uuid=lambda u: peer if u == AUTHOR else None)
    return types.SimpleNamespace(
        peers=peers if known else None,
        logger=logging.getLogger('test_post_gate'),
        get_peer_tier=lambda u: peer_tier,
        lock=threading.RLock(),
        social=types.SimpleNamespace(_seen_post_ids=[]))


def _gate_lines(caplog):
    return [r for r in caplog.records if 'tier-gated' in r.getMessage()]


def test_known_author_under_the_post_tier_is_dropped_at_info(caplog):
    proc = _proc(peer_tier=2, known=True)
    with caplog.at_level(logging.INFO, logger='test_post_gate'):
        assert _ingest_post(proc, None, _post(3), True) is True
    lines = _gate_lines(caplog)
    assert len(lines) == 1
    assert lines[0].levelno == logging.INFO
    assert lines[0].getMessage() == \
        'peer_post from %s tier-gated (need 3, have 2)' % AUTHOR[:8]
    assert proc.social._seen_post_ids == []


def test_unknown_author_reads_as_tier_0_and_is_dropped_at_info(caplog):
    proc = _proc(peer_tier=4, known=False)
    with caplog.at_level(logging.INFO, logger='test_post_gate'):
        assert _ingest_post(proc, None, _post(1), True) is True
    lines = _gate_lines(caplog)
    assert len(lines) == 1
    assert lines[0].levelno == logging.INFO
    assert 'need 1, have 0' in lines[0].getMessage()
