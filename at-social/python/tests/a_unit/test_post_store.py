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
"""The store store-and-forward serves from (Agora Phase 4 DDIL). Mirrors C
post_store_test.c: bounded with the OLDEST evicted, a known id left alone, and
a digest that offers only the window, newest first by the post's own ts."""
from collections import OrderedDict

from autonomous_trust.social._python import handlers


def _id(n):
    return f'{n:064x}'


def test_store_is_bounded_and_evicts_the_oldest():
    store = OrderedDict()
    for i in range(handlers.POST_STORE_CAP + 5):
        handlers._store_for_backfill_locked(store, _id(i), 1000.0 + i, 'a',
                                            {'x': 1})
    assert len(store) == handlers.POST_STORE_CAP
    assert all(_id(i) not in store for i in range(5))
    assert _id(5) in store
    handlers._store_for_backfill_locked(store, _id(5), 1.0, 'b', {'y': 2})
    assert store[_id(5)]['author'] == 'a'  # a known id is left as it is


def test_digest_is_the_window_newest_first():
    store = OrderedDict()
    for i, ts in enumerate((500.0, 90.0, 700.0, 600.0)):
        handlers._store_for_backfill_locked(store, _id(i), ts, 'a', {})
    now = handlers.POST_BACKFILL_MAX_AGE + 400.0  # the window is ts > 400
    assert handlers._digest_ids_locked(store, now) == [_id(2), _id(3), _id(0)]
    assert handlers._digest_ids_locked(store, 1e12) == []
