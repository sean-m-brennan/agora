#!/bin/bash
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
#
# AutonomousTrust's conformance run with the social protocol plugged in: the C
# extension (c/social, which registers the C adapter) and the Python plug-in
# (conformance/). Every argument is forwarded to AT's scripts/test-conformance.sh.
# AT is $AT_ROOT, else the muudd submodule ../../../lib/autonomous_trust.
# Directories already in either variable are kept, after these.
set -e
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AT_ROOT="${AT_ROOT:-$here/../../../lib/autonomous_trust}"
if [ ! -x "$AT_ROOT/scripts/test-conformance.sh" ]; then
  echo "AutonomousTrust not found at $AT_ROOT (set AT_ROOT, or run:" \
       "git submodule update --init --recursive)" >&2
  exit 2
fi
export AT_EXTERNAL_EXTENSIONS="$here/c/social${AT_EXTERNAL_EXTENSIONS:+:$AT_EXTERNAL_EXTENSIONS}"
export AT_CONFORMANCE_PLUGINS="$here/conformance${AT_CONFORMANCE_PLUGINS:+:$AT_CONFORMANCE_PLUGINS}"
cd "$AT_ROOT"
exec ./scripts/test-conformance.sh "$@"
