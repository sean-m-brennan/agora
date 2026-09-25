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
"""The social protocol as an AutonomousTrust conformance plug-in.

AT's Python harness loads this file when its directory is named in
$AT_CONFORMANCE_PLUGINS (conformance/harness/python/runner.py): the corpus is
scenarios/social/, the adapter is python/social_adapter.py, and the social
distribution (../python) goes on sys.path first. The C adapter is
c/social_adapter.c, registered by c/social's CMakeLists.txt. Run both through
../test-conformance.sh.
"""

#: Prepended to sys.path, relative to this directory, before adapters().
SYS_PATH = ['python', '../python']


def adapters():
    from social_adapter import SocialAdapter
    return {'social': SocialAdapter}
