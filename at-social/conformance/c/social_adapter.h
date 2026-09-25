/********************
 *  Copyright 2024 TekFive, Inc., Sean M. Brennan, and contributors
 *
 *   Licensed under the Apache License, Version 2.0 (the "License");
 *   you may not use this file except in compliance with the License.
 *   You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 *   Unless required by applicable law or agreed to in writing, software
 *   distributed under the License is distributed on an "AS IS" BASIS,
 *   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *   See the License for the specific language governing permissions and
 *   limitations under the License.
 *******************/

#ifndef AT_CONFORMANCE_SOCIAL_ADAPTER_H
#define AT_CONFORMANCE_SOCIAL_ADAPTER_H

#include "scenario_loader.h"
#include "case_result.h"

/* protocol: social (FEATURE_SPLIT_PLAN Phase 5), built under AT_CONF_SOCIAL. */
void at_social_run(const at_case_t *c, at_case_result_t *out);

#endif /* AT_CONFORMANCE_SOCIAL_ADAPTER_H */
