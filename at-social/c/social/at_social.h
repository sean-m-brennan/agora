/********************
 *  Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors
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

#ifndef AT_SOCIAL_LINK_H
#define AT_SOCIAL_LINK_H

/**
 * @file at_social.h
 * @brief The social feature (FEATURE_SPLIT_PLAN Phase 5): position, proximity,
 *        profile, connections, DMs, posts, reactions, reports and blocks,
 *        business ads and posts, cosign.
 *
 * Linking it registers, from load-time constructors, the identity hooks
 * (identity/id_ext.h), its 34 identity verbs (processes/extension.h), its 12
 * message types and 18 app verbs, and the app-event decoders behind at_agora.h.
 * Present means on: a node that links it has social; one that does not carries
 * none of it, and refuses to start if $AT_OWN_GEOHASH, $AT_OWN_EXACT or
 * $AT_OWN_PROFILE is set.
 *
 * A shared link registers it when the library loads, but only if the program
 * keeps it: nothing references a constructor-registered library, so under
 * --as-needed a consumer calls at_social_link() (or links it with
 * --no-as-needed). A static link keeps it only if something references the
 * object, so a program that links it without --whole-archive calls
 * at_social_link() once.
 *
 * See doc/architecture/extensions.md.
 */

/** Keeps the social feature's registrations in the link. No-op at run time. */
void at_social_link(void);

#endif /* AT_SOCIAL_LINK_H */
