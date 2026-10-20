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
"""The social feature as the core finds it (FEATURE_SPLIT_PLAN Phase 5).

Pins: discovery finds this distribution with nothing but the source tree on
the path (its ``_at_extension.py`` marker); social is then an Extension like
first contact, always on where present -- its 20 verbs, its state on
proc.social, and the IdentityHooks the core calls. The hook machinery itself
is tested in the core (tests/a_unit/test_extensions.py), and a node without
this distribution by the core's test_identity_without_social.py.
"""
import pickle
import types

import pytest

from autonomous_trust.core.system import CfgIds, PackageHash
from autonomous_trust.core.config import Configuration
from autonomous_trust.core.identity import Identity, Peers
from autonomous_trust.core.capabilities import PeerCapabilities
from autonomous_trust.core.processes import ProcessTracker
from autonomous_trust.core._python import extensions
from autonomous_trust.core._python.identity.idprocess import IdentityProcess
from autonomous_trust.social.protocol import SocialProtocol


@pytest.fixture(autouse=True)
def _isolate_data_dir(monkeypatch, tmp_path):
    """Social's durable store goes to a per-test temp dir."""
    monkeypatch.setenv(Configuration.ROOT_VARIABLE_NAME, str(tmp_path))


def _identity_process():
    configurations = {
        CfgIds.identity: Identity.initialize('alice@ex', 'alice@ex', '10.0.0.1'),
        CfgIds.peers: Peers(),
        CfgIds.capabilities: PeerCapabilities(),
        PackageHash.key: 'test',
        'processes': [types.SimpleNamespace(name=CfgIds.network)],
    }
    return IdentityProcess(configurations, ProcessTracker(), log_q=None,
                           suppress_log=True)


def test_discovery_finds_this_distribution():
    from autonomous_trust.social._at_extension import EXTENSION
    exts = [e for e in extensions.all_extensions() if e.name == 'social']
    assert exts == [EXTENSION]     # found once, however many ways



SOCIAL_VERBS = (
    'position_query', 'position_response', 'business_ad', 'business_post',
    'cosign_request', 'cosign_sig', 'proximity_trigger', 'proximity_probe',
    'proximity_reply', 'profile_query', 'profile_response',
    'connection_request', 'connection_response', 'dm', 'post', 'reaction',
    'report', 'post_digest', 'post_want', 'post_backfill',
    'file_offer', 'file_ctl', 'file_req', 'file_chunk')


def test_social_registers_its_24_verbs_on_identity_only():
    proc = _identity_process()
    assert 'social' in proc._extensions
    for verb in SOCIAL_VERBS:
        assert getattr(SocialProtocol, verb) in proc.protocol.handlers, verb
    other = types.SimpleNamespace(
        protocol=types.SimpleNamespace(handlers={},
                                       register_handler=lambda v, h: None))
    from autonomous_trust.social._python import extension
    extension._register(other, 'reputation')
    assert not hasattr(other, 'social')


def test_identity_process_with_social_pickles():
    """proc.social rides the pickle with the process, and every handler is
    bound to the clone, as first contact's are."""
    proc = _identity_process()
    proc.social.own_geohash = '9q8yy'
    clone = pickle.loads(pickle.dumps(proc))
    assert clone.social is not proc.social
    assert clone.social.own_geohash == '9q8yy'
    handler = clone.protocol.handlers[SocialProtocol.dm]
    assert handler.args[0] is clone


def test_the_tier_clamp_asks_the_block_hook():
    import threading
    from autonomous_trust.core._python.extensions import identity_hooks
    proc = _identity_process()
    proc.lock = threading.Lock()   # plain Lock, as in production: the hook
    peer = Identity.initialize('bob@ex', 'bob@ex', '10.0.0.2')  # runs under it
    assert any(h.is_blocked_locked for h in identity_hooks(proc))
    proc.social.social_blocks[str(peer.uuid)] = 1.0
    assert proc.get_peer_tier(peer.uuid) == 0


def test_a_social_declaration_without_social_is_refused(monkeypatch):
    real = extensions.all_extensions
    monkeypatch.setattr(extensions, 'all_extensions',
                        lambda: [e for e in real() if e.name != 'social'])
    monkeypatch.delenv('AT_OWN_GEOHASH', raising=False)
    monkeypatch.delenv('AT_OWN_EXACT', raising=False)
    monkeypatch.setenv('AT_OWN_PROFILE', '{"display_name": "x"}')
    with pytest.raises(extensions.ExtensionMissingError, match='AT_OWN_PROFILE'):
        extensions.check_env()
    monkeypatch.setenv('AT_OWN_PROFILE', '')
    extensions.check_env()
    monkeypatch.setattr(extensions, 'all_extensions', real)
    monkeypatch.setenv('AT_OWN_PROFILE', '{"display_name": "x"}')
    extensions.check_env()


def test_social_sends_nothing_in_the_clear():
    """The twin of test_unencrypted_verbs for the moved code: no social
    Message is built with encrypt=False (a feed post is group-encrypted, the
    rest directed-encrypted)."""
    import ast
    import pathlib
    from autonomous_trust.social import _python as social
    for path in pathlib.Path(social.__file__).parent.glob('*.py'):
        for node in ast.walk(ast.parse(path.read_text())):
            if isinstance(node, ast.Call) and getattr(node.func, 'id', None) == 'Message':
                for kw in node.keywords:
                    assert not (kw.arg == 'encrypt' and isinstance(kw.value, ast.Constant)
                                and kw.value.value is False), f'{path.name}:{node.lineno}'



def test_social_declares_no_plaintext_verbs():
    """Since AT's plaintext-verbs split (FEATURE_SPLIT_PLAN D8) a feature's
    DECLARED verbs are what an operator's unencrypted_verbs.cfg.json may grant
    in the clear. Social declares none, so no file can downgrade a social verb;
    the per-verb tests (test_*_exchange) check the core set."""
    from autonomous_trust.social.extension import EXTENSION
    assert tuple(EXTENSION.plaintext_verbs) == ()


# -- blocks restored at start (Phase 5 step 6; twin of C _social_run_start) -- #

def _saved_blocks(*uuids):
    from autonomous_trust.social.social_store import social_store_save
    social_store_save({u: 1700000000.0 for u in uuids},
                      Configuration.get_cfg_dir())


def test_blocks_are_restored_before_the_process_takes_traffic():
    """A block the operator set survives a restart: the file written by the
    last run is loaded by post_fork, which the process runs before its
    message loop, and the tier clamp sees it at once."""
    peer = Identity.initialize('bob@ex', 'bob@ex', '10.0.0.2')
    _saved_blocks(str(peer.uuid))
    proc = _started(_identity_process())
    assert proc.social.social_blocks == {}     # construction reads nothing
    extensions.run_post_fork(proc)
    assert proc.social.social_blocks == {str(peer.uuid): 1700000000.0}
    assert proc.get_peer_tier(peer.uuid) == 0


def _started(proc):
    # As process() does just before run_post_fork: the lock is made there,
    # after the pickle.
    import threading
    proc.lock = threading.Lock()
    return proc


def _logged(proc):
    # The process's own logger (suppress_log) does not reach caplog.
    import logging
    proc.logger = logging.getLogger('test_social_registration')
    return _started(proc)


def test_the_restore_is_logged_only_when_there_is_something(caplog):
    import logging
    proc = _logged(_identity_process())
    with caplog.at_level(logging.INFO):
        extensions.run_post_fork(proc)
    assert 'restored' not in caplog.text
    _saved_blocks('00000000-0000-0000-0000-00000000000a',
                  '00000000-0000-0000-0000-00000000000b')
    with caplog.at_level(logging.INFO):
        extensions.run_post_fork(proc)
    assert 'restored 2 local block(s)' in caplog.text


def test_an_unreadable_file_starts_with_no_blocks(caplog):
    """Fails toward "nobody is blocked", with a warning, never toward an
    arbitrary subset (the C twin's rc != 0 branch)."""
    import os
    from autonomous_trust.social.social_store import social_store_path
    path = social_store_path(Configuration.get_cfg_dir())
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        f.write('{"version": 1, "blocks": "not an object"}')
    proc = _logged(_identity_process())
    extensions.run_post_fork(proc)
    assert proc.social.social_blocks == {}
    assert 'starting with NO blocks' in caplog.text


def test_post_fork_leaves_other_processes_alone():
    """load_extensions records social on every process it runs for; only the
    identity process carries proc.social, and only it restores."""
    _saved_blocks('00000000-0000-0000-0000-00000000000a')
    other = types.SimpleNamespace(_extensions=['social'])
    extensions.run_post_fork(other)
    assert not hasattr(other, 'social')
