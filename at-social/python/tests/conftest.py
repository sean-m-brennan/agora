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
"""Run from a checkout: this distribution and the AutonomousTrust core on
sys.path. The core is $AT_PY_SRC if set, else found by walking up from here:
AT's own tree (src/autonomous-trust) or the muudd layout, where this lives in
apps/agora and AT is the lib/autonomous_trust submodule."""
import os
import sys

_here = os.path.dirname(os.path.abspath(__file__))
_dist = os.path.dirname(_here)


def _find_core():
    env = os.environ.get('AT_PY_SRC')
    if env:
        return env
    d = _dist
    while True:
        for rel in (('src', 'autonomous-trust'),
                    ('lib', 'autonomous_trust', 'src', 'autonomous-trust')):
            cand = os.path.join(d, *rel)
            if os.path.isdir(os.path.join(cand, 'autonomous_trust', 'core')):
                return cand
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


for _pkg in (_find_core(), _dist):
    if _pkg and _pkg not in sys.path and os.path.isdir(_pkg):
        sys.path.insert(0, _pkg)
