// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// ethne_agora — a thin C-ABI over Ethne's Rust charter engine, so the Agora
// Flutter app can found and read an Ethne polity (a "business") via dart:ffi,
// with no Python in the loop (SOCIAL_APP_PLAN.md §2.2 / Phase 3).
//
// Design (P3.0, the integration spike):
//   * The live charter log is an OPAQUE handle — `Box<EthneArchive>` — that Dart
//     holds and passes back; the archive itself is `Mutex`-guarded so the handle
//     is safe even if Dart ever calls from more than one isolate/thread.
//   * Everything else crosses the boundary as **JSON byte buffers** (serde_json),
//     mirroring how Ethne's own PyO3 layer crosses every boundary. Keys, DIDs,
//     charters and the read-model are all serde types, so no bespoke wire format.
//   * Errors: each call returns 0 on success or negative on failure and stashes a
//     human message retrievable via `ethne_last_error()` (valid until the next
//     call on the same thread).
//
// The Ethne API is compositional (there is no "Archive.found()" method): build a
// record, wrap it with `Signed::build`, and `append` it to the archive. Reads
// (`charter_state`, `verify_all`, `check_authority`) are free functions over the
// archive. This file replicates that composition behind a flat C surface.

use std::cell::RefCell;
use std::collections::BTreeSet;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::str::FromStr;
use std::sync::Mutex;

use en_archive::Archive;
use en_charter::{
    affirmation_state, assemble, charter_state, check_authority, describe_guardian_change,
    didkey_resolver, envoy_state, guardian_state,
    majority, pending,
    check_label, content_policy_state, is_geohash_area, rendezvous_state, verify_all,
    RELAY_AREAS_MAX, Affirmation, AffirmationKind, CharterEntry,
    Commitment, ContentPolicy, ContentPolicyAmendment, Derivation, LabelAction, Office,
    OfficeChange, OfficeKind,
    EnvoyAuthorization,
    EnvoyKind, FoundingProposal, GuardianChange, GuardianEvidence, GuardianKind, MemberReading,
    MembershipChange, MembershipKind, Movement, Observation, PolityCharter, RelayEndpoint,
    RiteMovement, Substrate,
    CommitmentAmendment, CompactAct, CompactActKind,
};
use en_core::{keys, time, Alg, Cid, DidKey, PrivKey, PubKey, Signed, Timestamp};
use en_uplift::{community_identity, envoy_delegation, member_roll, rendezvous_roster};
use kc_core::canonical;
use kc_identity::{MemberRoll, SpeakerDelegation};
use serde::{Deserialize, Serialize};

/// The community at kith-covenant's border (Phase 5; Ethne D39, D40).
mod kc;

// ---------------------------------------------------------------------------
// Error plumbing
// ---------------------------------------------------------------------------

thread_local! {
    static LAST_ERR: RefCell<CString> = RefCell::new(CString::new("").unwrap());
}

fn set_err(msg: impl Into<String>) {
    let c = CString::new(msg.into())
        .unwrap_or_else(|_| CString::new("error (contained NUL)").unwrap());
    LAST_ERR.with(|e| *e.borrow_mut() = c);
}

/// The last error message on THIS thread, valid until the next `ethne_*` call.
/// Never returns NULL. The caller copies it before making another call.
#[no_mangle]
pub extern "C" fn ethne_last_error() -> *const c_char {
    LAST_ERR.with(|e| e.borrow().as_ptr())
}

/// Free a string previously returned through an out-parameter by this library.
///
/// # Safety
/// `s` must be a pointer this library handed out (or NULL).
#[no_mangle]
pub unsafe extern "C" fn ethne_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

// ---------------------------------------------------------------------------
// Small FFI helpers
// ---------------------------------------------------------------------------

/// Borrow a required UTF-8 C string argument.
///
/// # Safety
/// `p` must be NULL or a valid NUL-terminated C string.
unsafe fn arg_str<'a>(p: *const c_char) -> Result<&'a str, String> {
    if p.is_null() {
        return Err("null string argument".into());
    }
    CStr::from_ptr(p)
        .to_str()
        .map_err(|_| "argument was not valid UTF-8".to_string())
}

/// Hand an owned String back through an out-pointer (caller frees via
/// `ethne_string_free`).
///
/// # Safety
/// `out` must be a valid `*mut *mut c_char`.
unsafe fn set_out(out: *mut *mut c_char, s: String) -> Result<(), String> {
    if out.is_null() {
        return Err("null output pointer".into());
    }
    let c = CString::new(s).map_err(|_| "output contained a NUL byte".to_string())?;
    *out = c.into_raw();
    Ok(())
}

// ---------------------------------------------------------------------------
// Opaque archive handle
// ---------------------------------------------------------------------------

/// The opaque charter-log handle Dart holds. `Mutex` so concurrent Dart calls
/// (e.g. across isolates) cannot race the append path.
pub struct EthneArchive(Mutex<Archive<CharterEntry>>);

/// A fresh, empty charter log.
#[no_mangle]
pub extern "C" fn ethne_archive_new() -> *mut EthneArchive {
    Box::into_raw(Box::new(EthneArchive(Mutex::new(Archive::new()))))
}

/// Free a charter-log handle.
///
/// # Safety
/// `a` must be a handle from `ethne_archive_new`/`ethne_archive_load_json` (or NULL).
#[no_mangle]
pub unsafe extern "C" fn ethne_archive_free(a: *mut EthneArchive) {
    if !a.is_null() {
        drop(Box::from_raw(a));
    }
}

// ---------------------------------------------------------------------------
// JSON specs Dart sends in
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct SignerSpec {
    did: String,
    #[serde(rename = "priv")]
    priv_key: PrivKey,
}

#[derive(Deserialize)]
struct FoundSpec {
    polity_did: String,
    name: String,
    statement: String,
    members: Vec<String>,
    /// A majority of the founding roll, with their keys, to co-sign the genesis.
    ratifiers: Vec<SignerSpec>,
    #[serde(default)]
    commitments: Vec<Commitment>,
}

#[derive(Deserialize)]
struct AdmitSpec {
    polity_did: String,
    member_did: String,
    #[serde(default)]
    rationale: String,
    /// A majority of the current roll, with keys.
    deciders: Vec<SignerSpec>,
    /// The joiner co-signs (consent — no conscription).
    joiner: SignerSpec,
}

// ---------------------------------------------------------------------------
// Keypair generation
// ---------------------------------------------------------------------------

fn gen_keypair() -> Result<String, String> {
    let (sk, pk) = keys::generate(Alg::Ed25519).map_err(|e| e.to_string())?;
    let did = DidKey::from_pubkey(&pk).map_err(|e| e.to_string())?;
    let out = serde_json::json!({
        "did": did.as_str(),
        "priv": serde_json::to_value(&sk).map_err(|e| e.to_string())?,
        "pub": serde_json::to_value(&pk).map_err(|e| e.to_string())?,
    });
    serde_json::to_string(&out).map_err(|e| e.to_string())
}

/// Generate an Ed25519 keypair. Writes `{"did","priv","pub"}` JSON to `*out`
/// (the `priv`/`pub` are serialized `PrivKey`/`PubKey`; Dart stores them and
/// passes `priv` back to sign). Returns 0 / negative.
///
/// # Safety
/// `out` must be a valid `*mut *mut c_char`.
#[no_mangle]
pub unsafe extern "C" fn ethne_keypair_generate(out: *mut *mut c_char) -> i32 {
    match gen_keypair().and_then(|s| set_out(out, s)) {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

/// The Ethne keypair of an AT node: its own ed25519 signing seed (64 hex, as
/// AT's identity file holds it). A rendezvous operator's member key IS its
/// node's AT key (Ethne D36), so the relay a roster pins is the one that proves
/// itself with that key. Writes `{"did","priv","pub"}` as `ethne_keypair_generate`.
///
/// # Safety
/// `seed_hex`/`out` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_keypair_from_seed(seed_hex: *const c_char, out: *mut *mut c_char) -> i32 {
    let run = || -> Result<(), String> {
        let seed = hex::decode(arg_str(seed_hex)?).map_err(|_| "seed is not hex")?;
        if seed.len() != 32 {
            return Err("an ed25519 seed is 32 bytes".into());
        }
        let sk = PrivKey { alg: Alg::Ed25519, bytes: seed };
        let pk = keys::public_of(&sk).map_err(|e| e.to_string())?;
        let did = DidKey::from_pubkey(&pk).map_err(|e| e.to_string())?;
        set_out(out, serde_json::to_string(&serde_json::json!({
            "did": did.as_str(),
            "priv": serde_json::to_value(&sk).map_err(|e| e.to_string())?,
            "pub": serde_json::to_value(&pk).map_err(|e| e.to_string())?,
        })).map_err(|e| e.to_string())?)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

// ---------------------------------------------------------------------------
// Found a polity (charter genesis)
// ---------------------------------------------------------------------------

fn found_impl(a: &EthneArchive, spec: &str) -> Result<(), String> {
    let s: FoundSpec = serde_json::from_str(spec).map_err(|e| format!("bad found spec: {e}"))?;
    let polity = DidKey::from_str(&s.polity_did).map_err(|e| e.to_string())?;
    let members = s
        .members
        .iter()
        .map(|m| DidKey::from_str(m))
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())?;
    let ratifier_dids = s
        .ratifiers
        .iter()
        .map(|r| DidKey::from_str(&r.did))
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())?;

    let substrate = Substrate {
        name: s.name,
        statement: s.statement,
        anchor: None,
    };
    let proposal = FoundingProposal::convener_asserted(
        polity,
        substrate,
        s.commitments,
        members,
        Vec::new(), // no derived (machine) members in P3.0
        time::now(),
    );
    let charter = proposal
        .ratify(ratifier_dids, time::now())
        .map_err(|e| e.to_string())?;
    let signers: Vec<(&str, &PrivKey)> = s
        .ratifiers
        .iter()
        .map(|r| (r.did.as_str(), &r.priv_key))
        .collect();
    let signed = Signed::build(charter, &signers).map_err(|e| e.to_string())?;
    a.0.lock()
        .unwrap()
        .append(CharterEntry::PolityChartered(signed))
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// Found a polity: ratify a genesis charter and append it. `spec` is
/// `{"polity_did","name","statement","members":[did…],"ratifiers":[{"did","priv"}…],
/// "commitments":[…]?}`. Ratifiers must be a majority of `members`, and
/// name/statement non-empty, or a later `ethne_verify` fails the authority pass.
///
/// # Safety
/// `a` must be a valid handle; `spec` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn ethne_found_polity(a: *mut EthneArchive, spec: *const c_char) -> i32 {
    let run = || -> Result<(), String> {
        let a = a.as_ref().ok_or("null archive handle")?;
        found_impl(a, arg_str(spec)?)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

// ---------------------------------------------------------------------------
// Admit a member
// ---------------------------------------------------------------------------

fn admit_impl(a: &EthneArchive, spec: &str) -> Result<(), String> {
    let s: AdmitSpec = serde_json::from_str(spec).map_err(|e| format!("bad admit spec: {e}"))?;
    let polity = DidKey::from_str(&s.polity_did).map_err(|e| e.to_string())?;
    let member = DidKey::from_str(&s.member_did).map_err(|e| e.to_string())?;
    let decider_dids = s
        .deciders
        .iter()
        .map(|d| DidKey::from_str(&d.did))
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())?;

    let record = MembershipChange {
        polity,
        kind: MembershipKind::Admit,
        member,
        rationale: s.rationale,
        deciders: decider_dids,
        decided_at: time::now(),
    };
    // Deciders co-sign; the joiner co-signs too (consent).
    let mut signers: Vec<(&str, &PrivKey)> = s
        .deciders
        .iter()
        .map(|d| (d.did.as_str(), &d.priv_key))
        .collect();
    signers.push((s.joiner.did.as_str(), &s.joiner.priv_key));
    let signed = Signed::build(record, &signers).map_err(|e| e.to_string())?;
    a.0.lock()
        .unwrap()
        .append(CharterEntry::MembershipChanged(signed))
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// Admit a member. `spec` is `{"polity_did","member_did","rationale"?,
/// "deciders":[{"did","priv"}…],"joiner":{"did","priv"}}`.
///
/// # Safety
/// `a` must be a valid handle; `spec` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn ethne_admit_member(a: *mut EthneArchive, spec: *const c_char) -> i32 {
    let run = || -> Result<(), String> {
        let a = a.as_ref().ok_or("null archive handle")?;
        admit_impl(a, arg_str(spec)?)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

// ---------------------------------------------------------------------------
// Detached two-phase signing (D15)
//
// Every write above takes each signer's PRIVATE KEY in its spec, which is only
// tolerable when one node holds them all. It is not how a real roll works: a
// decider's key lives in their own keystore on their own node, and moving it to
// whoever is authoring is exactly the arrangement the key's location exists to
// prevent.
//
// So the payload travels instead. `ethne_pending` builds the record and exports
// its canonical bytes, their CID, and a legible DESCRIPTION; each signer runs
// `ethne_sign_detached` in their own process; `ethne_assemble` puts the
// signatures back on and VERIFIES each against the payload before appending, so
// a wrong or corrupted signature fails here rather than surfacing later as an
// unauthorized record.
//
// `en_charter::pending`/`assemble` are generic over the payload, so the same two
// calls serve guardian changes when S4 adds them. What is NOT generic is the
// description, and it is load-bearing rather than decoration: a seam that asks a
// human to sign opaque bytes has taught them to sign anything.
//
// The payload round-trips as JSON and must come back UNCHANGED — canonical CBOR
// is compared byte for byte, `decided_at` included. Nothing here re-stamps time.
// ---------------------------------------------------------------------------

/// What a membership change says, in words, for whoever is being asked to sign.
///
/// Spells out the CONSEQUENCE and the bar, not just the fields: an expulsion is
/// the one roll act done *to* somebody, and a signer should see that, see who
/// else is deciding, and see the stated reason before agreeing.
fn describe_membership_change(mc: &MembershipChange) -> String {
    let member = mc.member.as_str();
    let polity = mc.polity.as_str();
    let act = match mc.kind {
        MembershipKind::Admit => format!(
            "admit {member} to the roll — they co-sign to consent, and a majority \
             of the seasoned roll must decide it"
        ),
        MembershipKind::DepartVoluntary => {
            format!("record that {member} is leaving the roll of their own accord")
        }
        MembershipKind::Expel => format!(
            "EXPEL {member} from the roll — done TO them, not with them: they \
             neither decide nor sign, and it takes a majority PLUS ONE"
        ),
    };
    let deciders: Vec<&str> = mc.deciders.iter().map(DidKey::as_str).collect();
    format!(
        "polity {polity}: {act}.\n\
         decided at {} by {} decider(s): {}\n\
         rationale: {}",
        mc.decided_at,
        deciders.len(),
        if deciders.is_empty() { "(none)".into() } else { deciders.join(", ") },
        if mc.rationale.trim().is_empty() { "(none given)" } else { &mc.rationale },
    )
}

/// The default record class of an exchange, so a P3.2-era caller that sends no
/// `record` field still gets the membership path it was written against.
fn record_membership() -> String {
    "membership".to_string()
}

/// The wire bound on an exchange's exported bytes, in HEX CHARACTERS (so half
/// this many bytes of canonical CBOR). MUST match `AT_APP_COSIGN_BYTES_LEN` in
/// app_events.h, `AT_COSIGN_BYTES_LEN` in msg_types.h, and
/// `AGORA_COSIGN_BYTES_MAX` in the shim / cohort ctypes.
///
/// MEASURED, not guessed (see `the_wire_bound_holds_for_a_realistic_exchange`).
/// A guardian designation carrying a real observation runs 2142 hex for a small
/// polity and 4192 for a majority of thirty staff with a long rationale; five
/// readings in the cited observation takes it to 5678. What moves the number is
/// almost entirely the EVIDENCE — roughly 372 hex per extra reading — so an
/// exchange should cite an observation scoped to the member in question. The
/// wider peer-table sweep is a perfectly good record for the observation window;
/// it just has no business travelling inside a co-signing ask.
const COSIGN_BYTES_HEX_MAX: usize = 6144;

/// Refuse an exchange too large for the wire, HERE, where the authoring node can
/// still do something about it — rather than letting the C layer truncate a
/// payload whose whole purpose is to be reproduced byte for byte.
fn check_wire_bound(bytes_hex: &str) -> Result<(), String> {
    if bytes_hex.len() > COSIGN_BYTES_HEX_MAX {
        return Err(format!(
            "this exchange exports {} hex characters, over the {COSIGN_BYTES_HEX_MAX} the wire \
             carries. Almost all of that is the cited observation: cite one scoped to this \
             member rather than a whole peer-table sweep.",
            bytes_hex.len()
        ));
    }
    Ok(())
}

#[derive(Deserialize)]
struct PendingSpec {
    /// "membership" (default) or "guardian" — which record class this exchange
    /// carries. Echoed back as `record`; `ethne_assemble` needs it to know what
    /// to deserialize the payload back into.
    #[serde(default = "record_membership")]
    record: String,
    /// membership: "admit" or "expel" — a voluntary departure is self-signed by
    /// one person and needs no exchange, so it is not offered here.
    /// guardian: "designate", "rotate" or "release".
    op: String,
    polity_did: String,
    member_did: String,
    #[serde(default)]
    rationale: String,
    /// DIDs ONLY — no private key crosses this boundary. That is the point.
    #[serde(default)]
    deciders: Vec<String>,
    /// Guardian exchanges: the incoming guardian's DID (designate/rotate), or the
    /// departing one's (release on their own signature). DID only, as above.
    #[serde(default)]
    guardian_did: Option<String>,
    #[serde(default)]
    evidence_cid: Option<String>,
    #[serde(default)]
    unbacked_reason: Option<String>,
    /// content_policy exchanges: the policy the deciders will sign (D37).
    #[serde(default)]
    policy: Option<ContentPolicy>,
    /// office exchanges: which office ("Moderator", …). `member_did` is the holder.
    #[serde(default)]
    office: Option<String>,
    /// compact, rite and commitment exchanges (Phase 5): the record's own fields,
    /// without its instant, which the authoring node stamps.
    #[serde(default)]
    body: Option<serde_json::Value>,
}

fn pending_impl(a: &EthneArchive, spec: &str) -> Result<String, String> {
    let s: PendingSpec = serde_json::from_str(spec).map_err(|e| format!("bad pending spec: {e}"))?;
    match s.record.as_str() {
        "membership" => pending_membership(&s),
        // Guardian exchanges DO read the archive: evidence is cited by CID and
        // must already be in the log, and a release on the guardian's own
        // signature needs the outgoing guardian looked up rather than asserted.
        "guardian" => pending_guardian(a, &s),
        "content_policy" => pending_content_policy(&s),
        "office" => pending_office(&s),
        "compact" => pending_compact(&s),
        "rite" => pending_rite(&s),
        "commitment" => pending_commitment(&s),
        other => Err(format!(
            "unknown record class '{other}': detached signing covers 'membership', 'guardian', \
             'content_policy', 'office', 'compact', 'rite' and 'commitment'"
        )),
    }
}

fn pending_membership(s: &PendingSpec) -> Result<String, String> {
    let kind = match s.op.as_str() {
        "admit" => MembershipKind::Admit,
        "expel" => MembershipKind::Expel,
        other => {
            return Err(format!(
                "unknown op '{other}': detached signing covers 'admit' and 'expel'                  (a voluntary departure is self-signed and needs no exchange)"
            ))
        }
    };
    let member = DidKey::from_str(&s.member_did).map_err(|e| e.to_string())?;
    let deciders = s
        .deciders
        .iter()
        .map(|d| DidKey::from_str(d))
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())?;

    // Who the authority pass will require, so the caller knows whom to collect
    // from: admission adds the joiner's consent, expulsion is deciders exactly.
    let mut required: Vec<String> = s.deciders.clone();
    if kind == MembershipKind::Admit {
        required.push(s.member_did.clone());
    }

    let polity = DidKey::from_str(&s.polity_did).map_err(|e| e.to_string())?;
    // The ask on the wire names the polity the bytes commit to: a signer's node
    // resolves the act against ITS OWN log, and cannot without knowing which
    // polity to resolve it in. Carry the parsed key's own spelling, not the
    // caller's, so the wire and the payload agree character for character.
    let polity_did = polity.as_str().to_string();
    let record = MembershipChange {
        polity,
        kind,
        member,
        rationale: s.rationale.clone(),
        deciders,
        decided_at: time::now(),
    };
    let description = describe_membership_change(&record);
    let p = pending(record, description).map_err(|e| e.to_string())?;
    let bytes = hex::encode(&p.bytes);
    check_wire_bound(&bytes)?;

    serde_json::to_string(&serde_json::json!({
        "record": "membership",
        "op": s.op,
        "polity_did": polity_did,
        "payload": p.payload,
        "bytes": bytes,
        "cid": p.cid.to_string(),
        "description": p.description,
        "signers_required": required,
    }))
    .map_err(|e| e.to_string())
}

/// A guardian-change exchange. Unlike the membership path this one READS the log:
/// evidence is cited by the CID of an observation that must already be in it, and
/// a release on the departing guardian's own signature needs the outgoing
/// guardian looked up rather than taken on the caller's word.
fn pending_guardian(a: &EthneArchive, s: &PendingSpec) -> Result<String, String> {
    let polity = DidKey::from_str(&s.polity_did).map_err(|e| e.to_string())?;
    let polity_did = polity.as_str().to_string();
    let member = DidKey::from_str(&s.member_did).map_err(|e| e.to_string())?;
    let kind = match s.op.as_str() {
        "designate" => GuardianKind::Designate,
        "rotate" => GuardianKind::Rotate,
        "release" => GuardianKind::Release,
        other => {
            return Err(format!(
                "unknown guardian op '{other}': one of 'designate', 'rotate', 'release'"
            ))
        }
    };
    let guard = a.0.lock().unwrap();
    let evidence = match kind {
        GuardianKind::Release => {
            if s.evidence_cid.is_some() || s.unbacked_reason.is_some() {
                return Err("a release carries no evidence: it claims the edge is gone".into());
            }
            None
        }
        _ => resolve_evidence(&guard, s.evidence_cid.as_deref(), s.unbacked_reason.as_deref())?,
    };
    let named = s
        .guardian_did
        .as_deref()
        .map(DidKey::from_str)
        .transpose()
        .map_err(|e| e.to_string())?;
    if kind == GuardianKind::Rotate && named.is_none() {
        return Err("a rotation must name the incoming guardian, who co-signs".into());
    }

    // Whom the authority pass will require, so the caller knows whom to collect
    // from before anyone is asked to sign anything.
    let required: Vec<String> = match kind {
        GuardianKind::Designate | GuardianKind::Rotate => {
            let mut v = s.deciders.clone();
            // The named guardian consents: answerability is accepted, never
            // assigned, so their signature is required beyond the majority.
            if let Some(g) = &s.guardian_did {
                v.push(g.clone());
            }
            v
        }
        GuardianKind::Release if s.deciders.is_empty() => {
            // The guardian's own act. Resolve who that actually is from the log —
            // a release signed by the wrong "outgoing" guardian is refused by the
            // core, and finding that out after collecting signatures is worse.
            let st = guardian_state(&guard, &polity, time::now());
            match st.guardian_of(&member) {
                Some(Some(outgoing)) => vec![outgoing.as_str().to_string()],
                Some(None) => {
                    return Err(format!("{member} has no guardian edge to release"))
                }
                None => {
                    return Err(format!("{member} is not a designated derived party"))
                }
            }
        }
        GuardianKind::Release => s.deciders.clone(),
    };

    let record = GuardianChange {
        polity,
        kind,
        member,
        // A release names no incoming guardian, whatever the caller passed.
        guardian: if kind == GuardianKind::Release { None } else { named },
        evidence,
        rationale: s.rationale.clone(),
        deciders: s
            .deciders
            .iter()
            .map(|d| DidKey::from_str(d))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())?,
        decided_at: time::now(),
    };
    // Ethne's own description, not ours: the guardian path already has one
    // (detached.rs:121), and a second wording of the same act is a second thing
    // to drift.
    let description = describe_guardian_change(&record);
    let p = pending(record, description).map_err(|e| e.to_string())?;
    let bytes = hex::encode(&p.bytes);
    check_wire_bound(&bytes)?;

    serde_json::to_string(&serde_json::json!({
        "record": "guardian",
        "op": s.op,
        "polity_did": polity_did,
        "payload": p.payload,
        "bytes": bytes,
        "cid": p.cid.to_string(),
        "description": p.description,
        "signers_required": required,
    }))
    .map_err(|e| e.to_string())
}

/// Begin a detached exchange. `spec` is `{"record"?,"op","polity_did",
/// "member_did","rationale"?,"deciders":[did…]}` — DIDs only, no keys.
///
/// `record` is "membership" (the default; `op` is "admit" or "expel") or
/// "guardian" (`op` is "designate", "rotate" or "release", with `guardian_did`
/// and either `evidence_cid` or `unbacked_reason` as that op requires).
///
/// Writes `{"record","op","polity_did","payload","bytes","cid","description",
/// "signers_required"}` to `*out`. `polity_did` is echoed back because the ask
/// that goes on the wire must name the polity; the signer resolves the act in
/// its own log. Hand `bytes` and `description` to each
/// required signer, and give `payload` back to `ethne_assemble` UNCHANGED —
/// along with the same `record`, which says what it is.
///
/// # Safety
/// `a`/`spec`/`out` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_pending(
    a: *mut EthneArchive,
    spec: *const c_char,
    out: *mut *mut c_char,
) -> i32 {
    let run = || -> Result<(), String> {
        let a = a.as_ref().ok_or("null archive handle")?;
        let json = pending_impl(a, arg_str(spec)?)?;
        set_out(out, json)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

#[derive(Deserialize)]
struct SignSpec {
    #[serde(rename = "priv")]
    priv_key: PrivKey,
    /// The `bytes` field from `ethne_pending`, hex.
    bytes: String,
}

fn sign_detached_impl(spec: &str) -> Result<String, String> {
    let s: SignSpec = serde_json::from_str(spec).map_err(|e| format!("bad sign spec: {e}"))?;
    let bytes = hex::decode(&s.bytes).map_err(|e| format!("bad bytes hex: {e}"))?;
    let sig = keys::sign(&s.priv_key, &bytes).map_err(|e| e.to_string())?;
    Ok(hex::encode(sig.bytes))
}

/// Sign exported bytes with one key, in the signer's OWN process — the half that
/// never touches the polity's authoring host. `spec` is `{"priv":<key>,"bytes":
/// "<hex from ethne_pending>"}`; writes the signature hex to `*out`.
///
/// Takes no archive: a signer needs the bytes and their key, nothing else.
///
/// # Safety
/// `spec`/`out` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_sign_detached(
    spec: *const c_char,
    out: *mut *mut c_char,
) -> i32 {
    let run = || -> Result<(), String> {
        let sig = sign_detached_impl(arg_str(spec)?)?;
        set_out(out, sig)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

#[derive(Deserialize)]
struct DetachedSig {
    did: String,
    /// Hex, as `ethne_sign_detached` returned it.
    sig: String,
}

#[derive(Deserialize)]
struct AssembleSpec {
    /// The `record` `ethne_pending` returned, saying what `payload` is.
    #[serde(default = "record_membership")]
    record: String,
    /// The `payload` from `ethne_pending`, VERBATIM. Canonical CBOR is compared
    /// byte for byte, `decided_at` included, so nothing here re-stamps time.
    payload: serde_json::Value,
    signatures: Vec<DetachedSig>,
}

fn assemble_impl(a: &EthneArchive, spec: &str) -> Result<(), String> {
    let s: AssembleSpec =
        serde_json::from_str(spec).map_err(|e| format!("bad assemble spec: {e}"))?;
    let sigs = s
        .signatures
        .iter()
        .map(|d| {
            hex::decode(&d.sig)
                .map(|b| (d.did.clone(), b))
                .map_err(|e| format!("bad signature hex from {}: {e}", d.did))
        })
        .collect::<Result<Vec<_>, String>>()?;
    // `assemble` verifies every signature against the payload's own canonical
    // bytes before returning, so a wrong key or a tampered payload fails HERE.
    // It is generic over the payload; only the entry class differs.
    let entry = match s.record.as_str() {
        "membership" => {
            let payload: MembershipChange = serde_json::from_value(s.payload)
                .map_err(|e| format!("payload is not a membership change: {e}"))?;
            CharterEntry::MembershipChanged(assemble(payload, &sigs).map_err(|e| e.to_string())?)
        }
        "guardian" => {
            let payload: GuardianChange = serde_json::from_value(s.payload)
                .map_err(|e| format!("payload is not a guardian change: {e}"))?;
            CharterEntry::GuardianChanged(assemble(payload, &sigs).map_err(|e| e.to_string())?)
        }
        "content_policy" => {
            let payload: ContentPolicyAmendment = serde_json::from_value(s.payload)
                .map_err(|e| format!("payload is not a content policy amendment: {e}"))?;
            CharterEntry::ContentPolicyAmended(assemble(payload, &sigs).map_err(|e| e.to_string())?)
        }
        "office" => {
            let payload: OfficeChange = serde_json::from_value(s.payload)
                .map_err(|e| format!("payload is not an office change: {e}"))?;
            CharterEntry::OfficeChanged(assemble(payload, &sigs).map_err(|e| e.to_string())?)
        }
        "compact" => {
            let payload: CompactAct = serde_json::from_value(s.payload)
                .map_err(|e| format!("payload is not a compact act: {e}"))?;
            CharterEntry::CompactActDecided(assemble(payload, &sigs).map_err(|e| e.to_string())?)
        }
        "rite" => {
            if s.payload.get("movement").is_some() {
                let payload: RiteMovement = serde_json::from_value(s.payload)
                    .map_err(|e| format!("payload is not a rite movement: {e}"))?;
                CharterEntry::RiteMovementRecorded(assemble(payload, &sigs).map_err(|e| e.to_string())?)
            } else {
                let payload: Affirmation = serde_json::from_value(s.payload)
                    .map_err(|e| format!("payload is not an affirmation: {e}"))?;
                CharterEntry::MemberAffirmed(assemble(payload, &sigs).map_err(|e| e.to_string())?)
            }
        }
        "commitment" => {
            let payload: CommitmentAmendment = serde_json::from_value(s.payload)
                .map_err(|e| format!("payload is not a commitment amendment: {e}"))?;
            CharterEntry::CommitmentAmended(assemble(payload, &sigs).map_err(|e| e.to_string())?)
        }
        other => return Err(format!("unknown record class '{other}'")),
    };
    a.0.lock().unwrap().append(entry).map_err(|e| e.to_string())?;
    Ok(())
}

/// Close a detached exchange: attach the collected signatures and append.
/// `spec` is `{"record"?,"payload":<from ethne_pending, unchanged>,
/// "signatures":[{"did","sig"}…]}`, where `record` is the one `ethne_pending`
/// returned ("membership" when omitted).
///
/// Every signature is verified against the payload's canonical bytes before the
/// record is appended, so a wrong key, the wrong payload, or a corrupted
/// signature fails here rather than later as an unauthorized record. Whether the
/// signers actually MEET the bar is still the authority pass's call: run
/// `ethne_verify`.
///
/// # Safety
/// `a`/`spec` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_assemble(a: *mut EthneArchive, spec: *const c_char) -> i32 {
    let run = || -> Result<(), String> {
        let a = a.as_ref().ok_or("null archive handle")?;
        assemble_impl(a, arg_str(spec)?)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

// ---------------------------------------------------------------------------
// Reading an exchange back OUT of its bytes
//
// The description must NOT travel with the request. A co-signing ask crosses the
// network from whoever is authoring, and if the wording came with it, that node
// would choose both what you sign and what you are told you are signing: a
// friendly sentence over hostile bytes, and the signature is still real. Which is
// exactly the failure detached.rs:31-34 names — a seam that asks a human to sign
// opaque bytes has taught them to sign anything — reintroduced one layer up.
//
// So the signer's own node derives the description from THE BYTES IT IS ABOUT TO
// SIGN, and nothing about the wording is taken on the requester's word. The CID
// comes back too, so the caller can check it against the one it was handed.
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct DescribeSpec {
    #[serde(default = "record_membership")]
    record: String,
    /// The exact bytes to be signed, hex — as they arrived.
    bytes: String,
}

fn describe_impl(spec: &str) -> Result<String, String> {
    let s: DescribeSpec =
        serde_json::from_str(spec).map_err(|e| format!("bad describe spec: {e}"))?;
    let bytes = hex::decode(&s.bytes).map_err(|e| format!("bad bytes hex: {e}"))?;
    let cid = Cid::of_bytes(&bytes);
    let mut out = serde_json::Map::new();
    out.insert("record".into(), serde_json::json!(s.record));
    out.insert("cid".into(), serde_json::json!(cid.to_string()));
    match s.record.as_str() {
        "membership" => {
            let mc: MembershipChange = canonical::from_canonical_cbor(&bytes)
                .map_err(|e| format!("these bytes are not a membership change: {e}"))?;
            out.insert("op".into(), serde_json::json!(match mc.kind {
                MembershipKind::Admit => "admit",
                MembershipKind::DepartVoluntary => "depart",
                MembershipKind::Expel => "expel",
            }));
            out.insert("polity_did".into(), serde_json::json!(mc.polity.as_str()));
            out.insert("member_did".into(), serde_json::json!(mc.member.as_str()));
            out.insert("deciders".into(), serde_json::json!(
                mc.deciders.iter().map(DidKey::as_str).collect::<Vec<_>>()
            ));
            out.insert("description".into(), serde_json::json!(describe_membership_change(&mc)));
        }
        "guardian" => {
            let gc: GuardianChange = canonical::from_canonical_cbor(&bytes)
                .map_err(|e| format!("these bytes are not a guardian change: {e}"))?;
            out.insert("op".into(), serde_json::json!(match gc.kind {
                GuardianKind::Designate => "designate",
                GuardianKind::Rotate => "rotate",
                GuardianKind::Release => "release",
            }));
            out.insert("polity_did".into(), serde_json::json!(gc.polity.as_str()));
            out.insert("member_did".into(), serde_json::json!(gc.member.as_str()));
            out.insert("guardian_did".into(), match &gc.guardian {
                Some(g) => serde_json::json!(g.as_str()),
                None => serde_json::Value::Null,
            });
            out.insert("deciders".into(), serde_json::json!(
                gc.deciders.iter().map(DidKey::as_str).collect::<Vec<_>>()
            ));
            // What actually backs the edge, so the signer sees THAT too rather
            // than only the act. An unbacked edge says why, in its own words.
            out.insert("evidence".into(), match &gc.evidence {
                Some(GuardianEvidence::Observed(ob)) => serde_json::json!({
                    "kind": "observed",
                    "observer": ob.payload.observer.as_str(),
                    "observed_at": ob.payload.observed_at.as_second(),
                }),
                Some(GuardianEvidence::Unbacked { reason }) => serde_json::json!({
                    "kind": "unbacked", "reason": reason,
                }),
                None => serde_json::json!({ "kind": "none" }),
            });
            out.insert("description".into(), serde_json::json!(describe_guardian_change(&gc)));
        }
        "content_policy" => describe_content_policy_bytes(&bytes, &mut out)?,
        "office" => describe_office_bytes(&bytes, &mut out)?,
        "compact" => {
            let a: CompactAct = canonical::from_canonical_cbor(&bytes)
                .map_err(|e| format!("these bytes are not a compact act: {e}"))?;
            out.insert("op".into(), serde_json::json!(compact_op(a.kind)));
            out.insert("polity_did".into(), serde_json::json!(a.polity.as_str()));
            out.insert("deciders".into(), serde_json::json!(
                a.deciders.iter().map(DidKey::as_str).collect::<Vec<_>>()
            ));
            out.insert("description".into(), serde_json::json!(describe_compact_act(&a)));
        }
        "rite" => describe_rite_bytes(&bytes, &mut out)?,
        "commitment" => {
            let a: CommitmentAmendment = canonical::from_canonical_cbor(&bytes)
                .map_err(|e| format!("these bytes are not a commitment amendment: {e}"))?;
            out.insert("op".into(), serde_json::json!("amend"));
            out.insert("polity_did".into(), serde_json::json!(a.polity.as_str()));
            out.insert("deciders".into(), serde_json::json!(
                a.deciders.iter().map(DidKey::as_str).collect::<Vec<_>>()
            ));
            out.insert("description".into(), serde_json::json!(format!(
                "{:?} the commitment '{}' ({}) of {}. Decided by {} member(s).",
                a.kind, a.commitment.key, a.commitment.description, a.polity, a.deciders.len()
            )));
        }
        "kc_attest" => {
            // The Inductor's recitation, or a witness's attestation to it.
            if let Ok(r) = canonical::from_canonical_cbor::<kc_ceremony::Recitation>(&bytes) {
                out.insert("op".into(), serde_json::json!("recite"));
                out.insert("member_did".into(), serde_json::json!(r.speaker_did.as_str()));
                out.insert("description".into(), serde_json::json!(format!(
                    "Recite, as {}, the rite of {} for kith-covenant: the five movements, \
                     committing to {}.",
                    r.speaker_did,
                    r.community_did,
                    r.movement_common_virtue.keys().join(", ")
                )));
                return serde_json::to_string(&serde_json::Value::Object(out)).map_err(|e| e.to_string());
            }
            let a: kc_ceremony::intra::InternalWitnessAttestation = canonical::from_canonical_cbor(&bytes)
                .map_err(|e| format!("these bytes are not a rite attestation: {e}"))?;
            out.insert("op".into(), serde_json::json!("attest"));
            out.insert("member_did".into(), serde_json::json!(a.witness_did.as_str()));
            out.insert("description".into(), serde_json::json!(format!(
                "Witness, as {}, that the polity's rite {} was recited as you attended it, for \
                 kith-covenant.",
                a.witness_did, a.recitation_cid
            )));
        }
        "kc_conduct" => {
            let c: kc_conduct::ConductRecord = canonical::from_canonical_cbor(&bytes)
                .map_err(|e| format!("these bytes are not a conduct record: {e}"))?;
            out.insert("op".into(), serde_json::json!(format!("{:?}", c.kind)));
            out.insert("member_did".into(), serde_json::json!(c.subject_community.as_str()));
            out.insert("description".into(), serde_json::json!(format!(
                "Report {} for {:?} in the compact, together with {} reporting communit(ies): {}",
                c.subject_community, c.kind, c.reporters.len(), c.narrative
            )));
        }
        other => return Err(format!("unknown record class '{other}'")),
    }
    serde_json::to_string(&serde_json::Value::Object(out)).map_err(|e| e.to_string())
}

/// Say, in words, what a set of exported bytes actually commits to. `spec` is
/// `{"record"?,"bytes":"<hex>"}`; writes `{"record","op","polity_did",
/// "member_did","deciders",…,"cid","description"}` to `*out`.
///
/// Takes no archive and no keys: this runs on the SIGNER's node, over the bytes
/// that arrived, before anything is signed. The description is derived here and
/// never carried with the request — otherwise the asking node would choose both
/// what you sign and what you are told you are signing. Check the returned `cid`
/// against the one you were handed.
///
/// # Safety
/// `spec`/`out` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_describe(spec: *const c_char, out: *mut *mut c_char) -> i32 {
    let run = || -> Result<(), String> {
        let json = describe_impl(arg_str(spec)?)?;
        set_out(out, json)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

// ---------------------------------------------------------------------------
// Leaving the roll: self-signed departure, and expulsion at majority + 1
//
// The asymmetry is deliberate (charter.md §"The roll, and how it moves"):
// departure and expulsion are not symmetric acts, and a bare majority that can
// expel is a bare majority that can manufacture itself a supermajority one
// departure at a time.
//
// Both refuse when the polity could not self-govern afterwards, counted over
// SEASONED members — so a polity of three inducted members cannot shrink at all.
// Neither needs a new verifier: `ethne_verify` already runs `verify_all` and
// `check_authority` over every `Signed<MembershipChange>`.
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct DepartSpec {
    polity_did: String,
    /// The departing member, the SOLE signer. The roll cannot force them to stay
    /// and cannot decide on their behalf, so there are no deciders at all.
    member: SignerSpec,
    #[serde(default)]
    rationale: String,
}

fn depart_impl(a: &EthneArchive, spec: &str) -> Result<(), String> {
    let s: DepartSpec = serde_json::from_str(spec).map_err(|e| format!("bad depart spec: {e}"))?;
    let record = MembershipChange {
        polity: DidKey::from_str(&s.polity_did).map_err(|e| e.to_string())?,
        kind: MembershipKind::DepartVoluntary,
        member: DidKey::from_str(&s.member.did).map_err(|e| e.to_string())?,
        rationale: s.rationale,
        // Must be empty: the core refuses a departure that records deciders.
        deciders: Vec::new(),
        decided_at: time::now(),
    };
    let signers: Vec<(&str, &PrivKey)> = vec![(s.member.did.as_str(), &s.member.priv_key)];
    let signed = Signed::build(record, &signers).map_err(|e| e.to_string())?;
    a.0.lock()
        .unwrap()
        .append(CharterEntry::MembershipChanged(signed))
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// Resign from the roll. `spec` is `{"polity_did","member":{"did","priv"},
/// "rationale"?}`. Self-signed by the departing member alone.
///
/// Refused by the authority pass if the remaining roll could not self-govern.
///
/// # Safety
/// `a`/`spec` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_depart_member(a: *mut EthneArchive, spec: *const c_char) -> i32 {
    let run = || -> Result<(), String> {
        let a = a.as_ref().ok_or("null archive handle")?;
        depart_impl(a, arg_str(spec)?)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

#[derive(Deserialize)]
struct ExpelSpec {
    polity_did: String,
    member_did: String,
    #[serde(default)]
    rationale: String,
    /// Majority PLUS ONE of the seasoned roll, with keys. The target is excluded
    /// and does NOT sign — expulsion is the one roll act done to somebody.
    deciders: Vec<SignerSpec>,
}

fn expel_impl(a: &EthneArchive, spec: &str) -> Result<(), String> {
    let s: ExpelSpec = serde_json::from_str(spec).map_err(|e| format!("bad expel spec: {e}"))?;
    let decider_dids = s
        .deciders
        .iter()
        .map(|d| DidKey::from_str(&d.did))
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())?;
    let record = MembershipChange {
        polity: DidKey::from_str(&s.polity_did).map_err(|e| e.to_string())?,
        kind: MembershipKind::Expel,
        member: DidKey::from_str(&s.member_did).map_err(|e| e.to_string())?,
        rationale: s.rationale,
        deciders: decider_dids,
        decided_at: time::now(),
    };
    // Signers must be EXACTLY the deciders — no consent signature, by design.
    let signers: Vec<(&str, &PrivKey)> = s
        .deciders
        .iter()
        .map(|d| (d.did.as_str(), &d.priv_key))
        .collect();
    let signed = Signed::build(record, &signers).map_err(|e| e.to_string())?;
    a.0.lock()
        .unwrap()
        .append(CharterEntry::MembershipChanged(signed))
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// Expel a member. `spec` is `{"polity_did","member_did","rationale"?,
/// "deciders":[{"did","priv"}…]}`. Needs majority + 1 of the SEASONED roll, and
/// the target is neither a decider nor a signer.
///
/// # Safety
/// `a`/`spec` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_expel_member(a: *mut EthneArchive, spec: *const c_char) -> i32 {
    let run = || -> Result<(), String> {
        let a = a.as_ref().ok_or("null archive handle")?;
        expel_impl(a, arg_str(spec)?)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

// ---------------------------------------------------------------------------
// The induction rite (D29)
//
// Admission puts somebody on the roll; INDUCTION is the separate step by which
// they acquire the substrate, and only ratifiers-or-inducted members carry
// deliberative weight (`seasoned_members`, authority.rs:437). A member admitted
// and never inducted is on the roll with a vote worth nothing, forever — so
// without these two entries a polity grown through this FFI can only ever muster
// its founders as deciders, and expulsion (majority + 1) drifts out of reach.
//
// A rite is five `RiteMovement` records in order; the `Affirmation` that
// completes it must cite exactly those five CIDs, so `ethne_recite_movement`
// hands the CID back and the caller collects them.
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct ReciteSpec {
    polity_did: String,
    /// The member reciting. They recite, so they sign.
    member: SignerSpec,
    /// `Induction` (first acquisition) or `ReAffirmation` (renewal). Carried, not
    /// inferred, so the authority rule can check the claim against their state.
    kind: AffirmationKind,
    /// The movement itself, as its own JSON: `{"Substrate":{"names":…}}`,
    /// `"Fallenness"`, `"Recognition"`, `{"CommonVirtue":{"commits_to":[…]}}`,
    /// `{"NonUltimacy":{"names_anchor":…}}`.
    movement: Movement,
    /// What was said. Required non-empty — a movement is performed, and an empty
    /// one was not — but never read.
    statement: String,
    /// Members present for THIS movement, who co-sign. They must be inducted: the
    /// substrate is transmitted by those who hold it.
    #[serde(default)]
    attending: Vec<SignerSpec>,
}

fn recite_impl(a: &EthneArchive, spec: &str) -> Result<String, String> {
    let s: ReciteSpec = serde_json::from_str(spec).map_err(|e| format!("bad recite spec: {e}"))?;
    let attending = s
        .attending
        .iter()
        .map(|d| DidKey::from_str(&d.did))
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())?;
    let record = RiteMovement {
        polity: DidKey::from_str(&s.polity_did).map_err(|e| e.to_string())?,
        member: DidKey::from_str(&s.member.did).map_err(|e| e.to_string())?,
        kind: s.kind,
        movement: s.movement,
        statement: s.statement,
        attending,
        recited_at: time::now(),
    };
    // The reciter signs; everyone attending co-signs.
    let mut signers: Vec<(&str, &PrivKey)> = vec![(s.member.did.as_str(), &s.member.priv_key)];
    signers.extend(s.attending.iter().map(|d| (d.did.as_str(), &d.priv_key)));
    let signed = Signed::build(record, &signers).map_err(|e| e.to_string())?;
    let cid = a
        .0
        .lock()
        .unwrap()
        .append(CharterEntry::RiteMovementRecorded(signed))
        .map_err(|e| e.to_string())?;
    Ok(cid.to_string())
}

/// Recite one movement of a member's rite. `spec` is `{"polity_did",
/// "member":{"did","priv"},"kind":"Induction","movement":<Movement>,"statement",
/// "attending":[{"did","priv"}…]}`. Writes the new record's CID to `*out` — the
/// completing `ethne_induct_member` must cite the five, in order.
///
/// # Safety
/// `a`/`spec`/`out` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_recite_movement(
    a: *mut EthneArchive,
    spec: *const c_char,
    out: *mut *mut c_char,
) -> i32 {
    let run = || -> Result<(), String> {
        let a = a.as_ref().ok_or("null archive handle")?;
        let cid = recite_impl(a, arg_str(spec)?)?;
        set_out(out, cid)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

/// Parse a CID string. `Cid`'s Display is `b3:<hex>` while its parser wants bare
/// hex, so accept both — and accept exactly what en-pyo3's `parse_cid` accepts,
/// since the two runtimes cite the same movement records.
pub(crate) fn parse_cid(s: &str) -> Result<Cid, String> {
    Cid::from_hex(s.strip_prefix("b3:").unwrap_or(s))
        .map_err(|e| format!("bad cid '{s}': {e}"))
}

#[derive(Deserialize)]
struct InductSpec {
    polity_did: String,
    /// The inductee, who consents by signing.
    member: SignerSpec,
    /// Roll members who witness (receive) the inductee and co-sign. A witness
    /// counts only if they attended EVERY movement of the rite.
    #[serde(default)]
    witnesses: Vec<SignerSpec>,
    /// The five `ethne_recite_movement` CIDs of this member's own rite, in order.
    movements: Vec<String>,
}

fn induct_impl(a: &EthneArchive, spec: &str) -> Result<(), String> {
    let s: InductSpec = serde_json::from_str(spec).map_err(|e| format!("bad induct spec: {e}"))?;
    let witnesses = s
        .witnesses
        .iter()
        .map(|d| DidKey::from_str(&d.did))
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())?;
    let movements = s
        .movements
        .iter()
        .map(|c| parse_cid(c))
        .collect::<Result<Vec<_>, _>>()?;
    let record = Affirmation {
        polity: DidKey::from_str(&s.polity_did).map_err(|e| e.to_string())?,
        member: DidKey::from_str(&s.member.did).map_err(|e| e.to_string())?,
        kind: AffirmationKind::Induction,
        witnesses,
        movements,
        affirmed_at: time::now(),
    };
    // Witnesses co-sign; the inductee consents.
    let mut signers: Vec<(&str, &PrivKey)> = s
        .witnesses
        .iter()
        .map(|d| (d.did.as_str(), &d.priv_key))
        .collect();
    signers.push((s.member.did.as_str(), &s.member.priv_key));
    let signed = Signed::build(record, &signers).map_err(|e| e.to_string())?;
    a.0.lock()
        .unwrap()
        .append(CharterEntry::MemberAffirmed(signed))
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// Induct a member, completing their rite. `spec` is `{"polity_did",
/// "member":{"did","priv"},"witnesses":[{"did","priv"}…],"movements":[cid×5]}`.
///
/// # Safety
/// `a`/`spec` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_induct_member(a: *mut EthneArchive, spec: *const c_char) -> i32 {
    let run = || -> Result<(), String> {
        let a = a.as_ref().ok_or("null archive handle")?;
        induct_impl(a, arg_str(spec)?)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

// ---------------------------------------------------------------------------
// Who actually carries a vote, and what the bar is
// ---------------------------------------------------------------------------

fn affirmation_state_impl(a: &EthneArchive, polity_did: &str) -> Result<String, String> {
    let polity = DidKey::from_str(polity_did).map_err(|e| e.to_string())?;
    let guard = a.0.lock().unwrap();
    let now = time::now();
    let roll = charter_state(&guard, &polity, now).members.len();
    let st = affirmation_state(&guard, &polity, now);

    // `affirmation_state` seeds ratifiers as inducted and intersects with the
    // live roll, so this IS `seasoned_members` (authority.rs:437) — the set the
    // core counts majorities over.
    let seasoned = st.entries.iter().filter(|e| e.inducted).count();
    // ADVISORY READOUT ONLY. The core remains authoritative; these mirror
    // `majority` (public) and `can_self_govern` (private, = majority(n)+1 <= n)
    // so the UI can state the real bar instead of guessing.
    let contracted = seasoned.saturating_sub(1);
    let can_contract = seasoned > 0 && majority(contracted) + 1 <= contracted;

    let members: Vec<serde_json::Value> = st
        .entries
        .iter()
        .map(|e| {
            serde_json::json!({
                "did": e.member.as_str(),
                "inducted": e.inducted,
                "last_affirmed_at": e.last_affirmed_at.map(|t| t.as_second()),
            })
        })
        .collect();

    serde_json::to_string(&serde_json::json!({
        "polity_did": polity_did,
        "roll": roll,
        "seasoned": seasoned,
        "admit_need": majority(seasoned),
        "expel_need": majority(seasoned) + 1,
        "can_contract": can_contract,
        "members": members,
    }))
    .map_err(|e| e.to_string())
}

/// Who holds the substrate, and what a vote actually costs. Writes
/// `{"roll","seasoned","admit_need","expel_need","can_contract","members":[
/// {"did","inducted","last_affirmed_at"}…]}` to `*out`.
///
/// `seasoned` is the count the core counts majorities over — an admitted but
/// un-inducted member is on `roll` and not in `seasoned`. `can_contract` is false
/// when a departure or expulsion would drop the polity below the self-govern
/// floor, which is why a three-member polity cannot shrink.
///
/// # Safety
/// `a`/`polity_did`/`out` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_affirmation_state(
    a: *mut EthneArchive,
    polity_did: *const c_char,
    out: *mut *mut c_char,
) -> i32 {
    let run = || -> Result<(), String> {
        let a = a.as_ref().ok_or("null archive handle")?;
        let json = affirmation_state_impl(a, arg_str(polity_did)?)?;
        set_out(out, json)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

// ---------------------------------------------------------------------------
// Read model
// ---------------------------------------------------------------------------

fn charter_state_impl(a: &EthneArchive, polity_did: &str) -> Result<String, String> {
    let polity = DidKey::from_str(polity_did).map_err(|e| e.to_string())?;
    let guard = a.0.lock().unwrap();
    let state = charter_state(&guard, &polity, time::now());
    // CharterState is not itself Serialize; project the fields the app needs
    // (its Substrate/Commitment ARE serde types, members are DID strings).
    let members: Vec<&str> = state.members.iter().map(DidKey::as_str).collect();
    let mut obj = serde_json::Map::new();
    obj.insert("polity_did".into(), serde_json::Value::String(polity_did.to_string()));
    obj.insert("chartered".into(), serde_json::Value::Bool(state.chartered));
    obj.insert("dissolved".into(), serde_json::Value::Bool(state.dissolved));
    obj.insert(
        "substrate".into(),
        serde_json::to_value(&state.substrate).map_err(|e| e.to_string())?,
    );
    obj.insert(
        "commitments".into(),
        serde_json::to_value(&state.commitments).map_err(|e| e.to_string())?,
    );
    obj.insert(
        "members".into(),
        serde_json::to_value(&members).map_err(|e| e.to_string())?,
    );
    serde_json::to_string(&serde_json::Value::Object(obj)).map_err(|e| e.to_string())
}

/// Serialize the current `CharterState` for `polity_did` to `*out` as JSON
/// (`{"chartered","substrate","members":[did…],"commitments",…}`).
///
/// # Safety
/// `a`/`polity_did`/`out` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_charter_state(
    a: *mut EthneArchive,
    polity_did: *const c_char,
    out: *mut *mut c_char,
) -> i32 {
    let run = || -> Result<(), String> {
        let a = a.as_ref().ok_or("null archive handle")?;
        let json = charter_state_impl(a, arg_str(polity_did)?)?;
        set_out(out, json)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

// ---------------------------------------------------------------------------
// Verification (two independent passes: crypto, then governance)
// ---------------------------------------------------------------------------

fn verify_impl(a: &EthneArchive) -> Result<(), String> {
    let guard = a.0.lock().unwrap();
    verify_all(&guard).map_err(|e| format!("signature verification failed: {e}"))?;
    check_authority(&guard).map_err(|e| format!("authority check failed: {e}"))?;
    Ok(())
}

/// Verify the whole log: every signature (`verify_all`) and every governance
/// rule (`check_authority`). Returns 0 if both pass, negative otherwise (message
/// in `ethne_last_error`).
///
/// # Safety
/// `a` must be a valid handle.
#[no_mangle]
pub unsafe extern "C" fn ethne_verify(a: *mut EthneArchive) -> i32 {
    let run = || -> Result<(), String> {
        let a = a.as_ref().ok_or("null archive handle")?;
        verify_impl(a)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

// ---------------------------------------------------------------------------
// Persistence (versioned JSON envelope)
// ---------------------------------------------------------------------------

/// Dump the whole log to `*out` as the versioned JSON envelope (round-trips
/// through `ethne_archive_load_json`).
///
/// # Safety
/// `a`/`out` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_archive_dump_json(a: *mut EthneArchive, out: *mut *mut c_char) -> i32 {
    let run = || -> Result<(), String> {
        let a = a.as_ref().ok_or("null archive handle")?;
        let json = a.0.lock().unwrap().dump_json_to_string().map_err(|e| e.to_string())?;
        set_out(out, json)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

/// Load a charter log from the JSON envelope produced by `ethne_archive_dump_json`.
/// Returns a new handle, or NULL on error (message in `ethne_last_error`).
///
/// # Safety
/// `json` must be a valid C string.
#[no_mangle]
pub unsafe extern "C" fn ethne_archive_load_json(json: *const c_char) -> *mut EthneArchive {
    let run = || -> Result<Archive<CharterEntry>, String> {
        Archive::load_json_from_str(arg_str(json)?).map_err(|e| e.to_string())
    };
    match run() {
        Ok(arc) => Box::into_raw(Box::new(EthneArchive(Mutex::new(arc)))),
        Err(e) => {
            set_err(e);
            std::ptr::null_mut()
        }
    }
}

// ===========================================================================
// P3.1 — Envoy office + the business-page artifact (SOCIAL_APP_PLAN.md box 2)
// ===========================================================================
//
// An envoy is the standing that lets someone speak AS the business. A "business
// page" is a NEW agora.business border artifact (Ethne has no such type): bounded
// page content wrapped in Signed<BusinessPage> signed under the ENVOY's key. Two
// verification models (both shipped, user decision):
//   * self-contained bundle {page, delegation} — verifies polity-root → envoy →
//     page with NO charter log, for open discovery;
//   * full-log — folds the charter (verify_all + check_authority + envoy_state)
//     for the strongest, governance-re-proving check.

/// Truncate a page field to a byte-safe char budget (bounds, like agora.profile).
fn clamp(s: String, max_chars: usize) -> String {
    s.chars().take(max_chars).collect()
}

/// The genesis PolityCharter for `polity` inside the log (uplift emitters need it).
fn find_charter<'a>(
    guard: &'a Archive<CharterEntry>,
    polity: &DidKey,
) -> Option<&'a PolityCharter> {
    guard.iter().find_map(|(_, e)| match e {
        CharterEntry::PolityChartered(s) if &s.payload.polity == polity => Some(&s.payload),
        _ => None,
    })
}

/// The business page payload the envoy signs. Bounded, coarse, no coordinates
/// (locality is an opt-in geohash bucket). `seq` versions successive pages.
#[derive(Serialize, Deserialize)]
struct BusinessPage {
    polity: DidKey,
    name: String,
    category: String,
    description: String,
    locality: String,
    contact: String,
    seq: u64,
}

#[derive(Deserialize)]
struct AuthorizeEnvoySpec {
    polity_did: String,
    envoy_did: String,
    #[serde(default)]
    rationale: String,
    /// A majority of the roll (or an EnvoyAuthorizer office holder), with keys.
    authorizers: Vec<SignerSpec>,
    /// The envoy co-signs (consent — no conscription).
    envoy_priv: PrivKey,
}

#[derive(Deserialize)]
struct RootSpec {
    polity_did: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    envoy_did: String,
    /// The polity's OWN keypair (the root under which border artifacts are signed).
    root_priv: PrivKey,
    root_pub: PubKey,
}

#[derive(Deserialize)]
struct PageContent {
    polity_did: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    category: String,
    #[serde(default)]
    description: String,
    #[serde(default)]
    locality: String,
    #[serde(default)]
    contact: String,
    #[serde(default)]
    seq: u64,
}

#[derive(Deserialize)]
struct PageSignSpec {
    page: PageContent,
    envoy_did: String,
    envoy_priv: PrivKey,
}

/// The portable, self-contained business-page bundle.
#[derive(Deserialize)]
struct PageBundle {
    page: Signed<BusinessPage>,
    delegation: Signed<SpeakerDelegation>,
}

// --- Envoy authorization -----------------------------------------------------

fn authorize_envoy_impl(a: &EthneArchive, spec: &str) -> Result<(), String> {
    let s: AuthorizeEnvoySpec =
        serde_json::from_str(spec).map_err(|e| format!("bad envoy spec: {e}"))?;
    let polity = DidKey::from_str(&s.polity_did).map_err(|e| e.to_string())?;
    let envoy = DidKey::from_str(&s.envoy_did).map_err(|e| e.to_string())?;
    let envoy_pubkey = envoy.to_pubkey().map_err(|e| e.to_string())?;
    let authorizer_dids = s
        .authorizers
        .iter()
        .map(|x| DidKey::from_str(&x.did))
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())?;
    let record = EnvoyAuthorization {
        polity,
        kind: EnvoyKind::Authorize,
        envoy,
        envoy_pubkey,
        rationale: s.rationale,
        authorizers: authorizer_dids,
        expires_at: None,
        decided_at: time::now(),
    };
    // Authorizers co-sign; the envoy co-signs too (consent).
    let mut signers: Vec<(&str, &PrivKey)> = s
        .authorizers
        .iter()
        .map(|x| (x.did.as_str(), &x.priv_key))
        .collect();
    signers.push((s.envoy_did.as_str(), &s.envoy_priv));
    let signed = Signed::build(record, &signers).map_err(|e| e.to_string())?;
    a.0.lock()
        .unwrap()
        .append(CharterEntry::EnvoyAuthorized(signed))
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// Authorize an envoy. `spec` is `{"polity_did","envoy_did","rationale"?,
/// "authorizers":[{"did","priv"}…],"envoy_priv":<PrivKey>}`. Authorizers must be
/// a majority of the roll (or hold the EnvoyAuthorizer office); the envoy must be
/// a current member.
///
/// # Safety
/// `a` valid handle, `spec` valid C string.
#[no_mangle]
pub unsafe extern "C" fn ethne_authorize_envoy(a: *mut EthneArchive, spec: *const c_char) -> i32 {
    let run = || -> Result<(), String> {
        let a = a.as_ref().ok_or("null archive handle")?;
        authorize_envoy_impl(a, arg_str(spec)?)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

fn envoy_state_impl(a: &EthneArchive, polity_did: &str) -> Result<String, String> {
    let polity = DidKey::from_str(polity_did).map_err(|e| e.to_string())?;
    let guard = a.0.lock().unwrap();
    let st = envoy_state(&guard, &polity, time::now());
    let envoys: Vec<String> = st.envoys().iter().map(|d| d.as_str().to_string()).collect();
    serde_json::to_string(&serde_json::json!({ "envoys": envoys })).map_err(|e| e.to_string())
}

/// Serialize the currently-authorized envoys of `polity_did` as
/// `{"envoys":[did…]}`.
///
/// # Safety
/// `a`/`polity_did`/`out` valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_envoy_state(
    a: *mut EthneArchive,
    polity_did: *const c_char,
    out: *mut *mut c_char,
) -> i32 {
    let run = || -> Result<(), String> {
        let a = a.as_ref().ok_or("null archive handle")?;
        set_out(out, envoy_state_impl(a, arg_str(polity_did)?)?)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

// --- Border artifacts (community identity + envoy delegation) -----------------

fn community_identity_impl(a: &EthneArchive, spec: &str) -> Result<String, String> {
    let s: RootSpec = serde_json::from_str(spec).map_err(|e| format!("bad root spec: {e}"))?;
    let polity = DidKey::from_str(&s.polity_did).map_err(|e| e.to_string())?;
    let guard = a.0.lock().unwrap();
    let charter = find_charter(&guard, &polity).ok_or("polity is not chartered")?;
    let signed = community_identity(s.name, charter, &s.root_priv, s.root_pub, time::now())
        .map_err(|e| e.to_string())?;
    serde_json::to_string(&signed).map_err(|e| e.to_string())
}

/// Emit the polity's self-verifying CommunityIdentity border artifact.
/// `spec` = `{"polity_did","name","root_priv","root_pub"}`.
///
/// # Safety
/// `a`/`spec`/`out` valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_community_identity(
    a: *mut EthneArchive,
    spec: *const c_char,
    out: *mut *mut c_char,
) -> i32 {
    let run = || -> Result<(), String> {
        let a = a.as_ref().ok_or("null archive handle")?;
        set_out(out, community_identity_impl(a, arg_str(spec)?)?)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

fn envoy_delegation_impl(a: &EthneArchive, spec: &str) -> Result<String, String> {
    let s: RootSpec = serde_json::from_str(spec).map_err(|e| format!("bad root spec: {e}"))?;
    let polity = DidKey::from_str(&s.polity_did).map_err(|e| e.to_string())?;
    let envoy = DidKey::from_str(&s.envoy_did).map_err(|e| e.to_string())?;
    let guard = a.0.lock().unwrap();
    let charter = find_charter(&guard, &polity).ok_or("polity is not chartered")?;
    let envoys = envoy_state(&guard, &polity, time::now());
    let signed = envoy_delegation(charter, &envoys, &envoy, &s.root_priv, s.root_pub, time::now())
        .map_err(|e| e.to_string())?;
    serde_json::to_string(&signed).map_err(|e| e.to_string())
}

/// Emit a SpeakerDelegation (envoy credential, signed by the polity root).
/// `spec` = `{"polity_did","envoy_did","root_priv","root_pub"}`.
///
/// # Safety
/// `a`/`spec`/`out` valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_envoy_delegation(
    a: *mut EthneArchive,
    spec: *const c_char,
    out: *mut *mut c_char,
) -> i32 {
    let run = || -> Result<(), String> {
        let a = a.as_ref().ok_or("null archive handle")?;
        set_out(out, envoy_delegation_impl(a, arg_str(spec)?)?)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

// --- Business page: sign + verify --------------------------------------------

fn page_sign_impl(spec: &str) -> Result<String, String> {
    let s: PageSignSpec = serde_json::from_str(spec).map_err(|e| format!("bad page spec: {e}"))?;
    let polity = DidKey::from_str(&s.page.polity_did).map_err(|e| e.to_string())?;
    let page = BusinessPage {
        polity,
        name: clamp(s.page.name, 80),
        category: clamp(s.page.category, 40),
        description: clamp(s.page.description, 600),
        locality: clamp(s.page.locality, 12),
        contact: clamp(s.page.contact, 200),
        seq: s.page.seq,
    };
    let signed =
        Signed::build(page, &[(s.envoy_did.as_str(), &s.envoy_priv)]).map_err(|e| e.to_string())?;
    serde_json::to_string(&signed).map_err(|e| e.to_string())
}

/// Sign a business page as the envoy. `spec` = `{"page":{"polity_did","name",
/// "category","description","locality","contact","seq"},"envoy_did","envoy_priv"}`.
/// Writes the `Signed<BusinessPage>` JSON to `*out`.
///
/// # Safety
/// `spec`/`out` valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_business_page_sign(spec: *const c_char, out: *mut *mut c_char) -> i32 {
    let run = || -> Result<(), String> { set_out(out, page_sign_impl(arg_str(spec)?)?) };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

/// The signer DID recorded on a signed artifact (its first signature).
fn signer_of<T>(signed: &Signed<T>) -> Result<&str, String> {
    signed
        .signatures
        .first()
        .map(|s| s.signer_did.as_str())
        .ok_or_else(|| "artifact carries no signature".to_string())
}

fn verify_bundle_impl(bundle: &str) -> Result<(), String> {
    let b: PageBundle = serde_json::from_str(bundle).map_err(|e| format!("bad bundle: {e}"))?;
    // 1. The delegation is signed by the polity root (signer == community_did,
    //    resolvable straight from its did:key — no log needed).
    b.delegation
        .verify(didkey_resolver)
        .map_err(|e| format!("delegation signature invalid: {e}"))?;
    // 2. The page is signed by the envoy.
    b.page
        .verify(didkey_resolver)
        .map_err(|e| format!("page signature invalid: {e}"))?;
    // 3. The page's signer is exactly the delegated speaker (envoy).
    if signer_of(&b.page)? != b.delegation.payload.speaker_did.as_str() {
        return Err("page signer is not the delegated envoy".into());
    }
    // 4. The delegation is for the page's polity.
    if b.delegation.payload.community_did != b.page.payload.polity {
        return Err("delegation is for a different polity than the page".into());
    }
    // 5. The delegation is currently in force (not expired / revoked).
    if !b.delegation.payload.active_at(time::now()) {
        return Err("envoy delegation is not currently active".into());
    }
    Ok(())
}

/// Verify a SELF-CONTAINED business-page bundle `{"page","delegation"}`: proves
/// polity-root → envoy → page with no charter log. 0 if authentic, negative
/// otherwise (reason in `ethne_last_error`).
///
/// # Safety
/// `bundle` valid C string.
#[no_mangle]
pub unsafe extern "C" fn ethne_business_page_verify_bundle(bundle: *const c_char) -> i32 {
    let run = || -> Result<(), String> { verify_bundle_impl(arg_str(bundle)?) };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

fn verify_full_impl(a: &EthneArchive, page_json: &str) -> Result<(), String> {
    let page: Signed<BusinessPage> =
        serde_json::from_str(page_json).map_err(|e| format!("bad page: {e}"))?;
    page.verify(didkey_resolver)
        .map_err(|e| format!("page signature invalid: {e}"))?;
    let envoy_did = DidKey::from_str(signer_of(&page)?).map_err(|e| e.to_string())?;
    let guard = a.0.lock().unwrap();
    verify_all(&guard).map_err(|e| format!("charter signatures: {e}"))?;
    check_authority(&guard).map_err(|e| format!("charter authority: {e}"))?;
    if !envoy_state(&guard, &page.payload.polity, time::now()).is_active(&envoy_did) {
        return Err("page signer is not a current envoy of the polity".into());
    }
    Ok(())
}

/// Verify a business page against the FULL charter log `a`: page signature +
/// charter validity (verify_all + check_authority) + the signer being a current
/// authorized envoy. The strongest check; needs the polity's log. 0 / negative.
///
/// # Safety
/// `a` valid handle, `page_json` valid C string.
#[no_mangle]
pub unsafe extern "C" fn ethne_business_page_verify_full(
    a: *mut EthneArchive,
    page_json: *const c_char,
) -> i32 {
    let run = || -> Result<(), String> {
        let a = a.as_ref().ok_or("null archive handle")?;
        verify_full_impl(a, arg_str(page_json)?)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

// ===========================================================================
// P3.4 — the business-post artifact (SOCIAL_APP_PLAN.md box 5)
// ===========================================================================
//
// A page is what the business IS; a post is what it SAYS. Same authority, same
// two verification models, a different payload: bounded body text wrapped in
// Signed<BusinessPost> under the ENVOY's key and, over the wire, paired with the
// polity-root-signed delegation so a reader holding no charter log can still
// chain polity root -> envoy -> post.
//
// WHY A SEPARATE PAYLOAD TYPE rather than a page with a body field: a page is
// the business's CURRENT identity and its successor REPLACES it (seq versions
// it), while a post is a dated utterance that stands on its own and is never
// superseded. One type for both would let a page revision silently retract a
// post, and would make every post re-carry the whole page.
//
// AN EMPTY BODY IS REFUSED AT SIGNING. A page may legitimately leave fields
// blank; a post with nothing in it is not an utterance, and signing one would
// put the envoy's authority behind nothing at all.
//
// BODY BOUND, AND WHY A POST DOES NOT REUSE THE PAGE'S 3072-BYTE CAP.
// MEASURED, not guessed. The bundle's fixed cost — the polity-root delegation,
// two signature blocks and the JSON frame — is ~1514 bytes, and `clamp` counts
// CHARS while the wire counts BYTES, so the worst case a caller can hand us is
// four bytes per char. At 1024 chars that measures 5610 bytes, well over the
// page's 3072. Rather than silently shrink a business's voice to ~370 chars,
// the post carries its OWN wire cap, AT_BUSINESS_POST_BUNDLE_LEN = 4096:
//     1514 + 4 * 512 = 3562 bytes worst case, 534 bytes of headroom.
// That keeps at_app_business_post_t (~4.3 KB) under at_app_cosign_request_t's
// 6145, so at_app_event_t's union — and with it agora_events_poll's 16-event
// batch budget — does not grow at all. `the_worst_case_post_bundle_fits_the_
// wire_bound` re-measures on every run and fails the moment either number moves.
//
// Control characters are refused at signing rather than escaped: a body of raw
// control bytes expands six-fold in JSON (\u00XX), which would make the worst
// case a function of the caller's input rather than of the bound. Newline and
// tab are kept — they are what a post is written with — and escape to two bytes.

/// Char budget for a post body. See the note above: chosen against the measured
/// worst-case bundle, not picked for roundness.
const BUSINESS_POST_BODY_MAX: usize = 512;

/// The post bundle's wire cap, mirrored by AT_BUSINESS_POST_BUNDLE_LEN in the C
/// core (msg_types.h / business_post.h) and by the shim. Changing it here means
/// changing it in all four ABI mirrors.
const BUSINESS_POST_BUNDLE_MAX: usize = 4096;

/// The body bound and the wire cap are ONE decision, so tie them together where
/// the compiler can see it: the worst case is four bytes per char (the clamp
/// counts chars, the wire counts bytes) plus the bundle's fixed cost — the
/// polity-root delegation, two signature blocks and the JSON frame, measured at
/// ~1514 bytes and rounded up here. Widen the body without raising the cap and
/// this fails the BUILD, rather than waiting for a post to be truncated on the
/// wire and verify against nothing. `the_worst_case_post_bundle_fits_the_wire_
/// bound` still measures the real thing; this is the arithmetic behind it.
const _: () = assert!(
    BUSINESS_POST_BODY_MAX * 4 + 1600 <= BUSINESS_POST_BUNDLE_MAX,
    "BUSINESS_POST_BODY_MAX no longer fits BUSINESS_POST_BUNDLE_MAX at four \
     bytes per char plus the bundle's fixed cost"
);

/// The post payload the envoy signs. `seq` orders a business's own posts; it
/// does NOT version them (a post is never superseded).
#[derive(Serialize, Deserialize)]
struct BusinessPost {
    polity: DidKey,
    body: String,
    seq: u64,
}

#[derive(Deserialize)]
struct PostContent {
    polity_did: String,
    #[serde(default)]
    body: String,
    #[serde(default)]
    seq: u64,
}

#[derive(Deserialize)]
struct PostSignSpec {
    post: PostContent,
    envoy_did: String,
    envoy_priv: PrivKey,
}

/// The portable, self-contained business-post bundle.
#[derive(Deserialize)]
struct PostBundle {
    post: Signed<BusinessPost>,
    delegation: Signed<SpeakerDelegation>,
}

fn post_sign_impl(spec: &str) -> Result<String, String> {
    let s: PostSignSpec = serde_json::from_str(spec).map_err(|e| format!("bad post spec: {e}"))?;
    let polity = DidKey::from_str(&s.post.polity_did).map_err(|e| e.to_string())?;
    let body = clamp(s.post.body, BUSINESS_POST_BODY_MAX);
    if body.trim().is_empty() {
        return Err("a post with an empty body is not an utterance".into());
    }
    // See the note above the body bound: control characters would make the
    // worst-case wire size a function of the input, so they are refused rather
    // than escaped. Newline and tab are what a post is written with.
    if let Some(c) = body.chars().find(|c| c.is_control() && *c != '\n' && *c != '\t') {
        return Err(format!("a post body may not carry control character U+{:04X}", c as u32));
    }
    let post = BusinessPost { polity, body, seq: s.post.seq };
    let signed =
        Signed::build(post, &[(s.envoy_did.as_str(), &s.envoy_priv)]).map_err(|e| e.to_string())?;
    serde_json::to_string(&signed).map_err(|e| e.to_string())
}

/// Sign a business post as the envoy. `spec` = `{"post":{"polity_did","body",
/// "seq"},"envoy_did","envoy_priv"}`. Writes the `Signed<BusinessPost>` JSON to
/// `*out`. Refuses an empty body and any control character other than newline
/// or tab; the body is clamped to `BUSINESS_POST_BODY_MAX` chars.
///
/// # Safety
/// `spec`/`out` valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_business_post_sign(spec: *const c_char, out: *mut *mut c_char) -> i32 {
    let run = || -> Result<(), String> { set_out(out, post_sign_impl(arg_str(spec)?)?) };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

fn verify_post_bundle_impl(bundle: &str) -> Result<(), String> {
    let b: PostBundle = serde_json::from_str(bundle).map_err(|e| format!("bad bundle: {e}"))?;
    // The same five steps the page bundle answers, against the post payload.
    // 1. The delegation is signed by the polity root (signer == community_did,
    //    resolvable straight from its did:key — no log needed).
    b.delegation
        .verify(didkey_resolver)
        .map_err(|e| format!("delegation signature invalid: {e}"))?;
    // 2. The post is signed by the envoy.
    b.post
        .verify(didkey_resolver)
        .map_err(|e| format!("post signature invalid: {e}"))?;
    // 3. The post's signer is exactly the delegated speaker (envoy).
    if signer_of(&b.post)? != b.delegation.payload.speaker_did.as_str() {
        return Err("post signer is not the delegated envoy".into());
    }
    // 4. The delegation is for the post's polity.
    if b.delegation.payload.community_did != b.post.payload.polity {
        return Err("delegation is for a different polity than the post".into());
    }
    // 5. The delegation is currently in force (not expired / revoked).
    if !b.delegation.payload.active_at(time::now()) {
        return Err("envoy delegation is not currently active".into());
    }
    Ok(())
}

/// Verify a SELF-CONTAINED business-post bundle `{"post","delegation"}`: proves
/// polity-root -> envoy -> post with no charter log. This is the verifier a
/// READER uses — it holds the business's page, not the polity's archive. 0 if
/// authentic, negative otherwise (reason in `ethne_last_error`).
///
/// # Safety
/// `bundle` valid C string.
#[no_mangle]
pub unsafe extern "C" fn ethne_business_post_verify_bundle(bundle: *const c_char) -> i32 {
    let run = || -> Result<(), String> { verify_post_bundle_impl(arg_str(bundle)?) };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

fn verify_post_full_impl(a: &EthneArchive, post_json: &str) -> Result<(), String> {
    let post: Signed<BusinessPost> =
        serde_json::from_str(post_json).map_err(|e| format!("bad post: {e}"))?;
    post.verify(didkey_resolver)
        .map_err(|e| format!("post signature invalid: {e}"))?;
    let envoy_did = DidKey::from_str(signer_of(&post)?).map_err(|e| e.to_string())?;
    let guard = a.0.lock().unwrap();
    verify_all(&guard).map_err(|e| format!("charter signatures: {e}"))?;
    check_authority(&guard).map_err(|e| format!("charter authority: {e}"))?;
    if !envoy_state(&guard, &post.payload.polity, time::now()).is_active(&envoy_did) {
        return Err("post signer is not a current envoy of the polity".into());
    }
    Ok(())
}

/// Verify a business post against the FULL charter log `a`: post signature +
/// charter validity (verify_all + check_authority) + the signer being a current
/// authorized envoy. The strongest check; needs the polity's log, so it is what
/// the BUSINESS's own nodes use. 0 / negative.
///
/// # Safety
/// `a` valid handle, `post_json` valid C string.
#[no_mangle]
pub unsafe extern "C" fn ethne_business_post_verify_full(
    a: *mut EthneArchive,
    post_json: *const c_char,
) -> i32 {
    let run = || -> Result<(), String> {
        let a = a.as_ref().ok_or("null archive handle")?;
        verify_post_full_impl(a, arg_str(post_json)?)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

// ===========================================================================
// P3.3 — Guardianship: who a machine answers to (SOCIAL_APP_PLAN.md box 4)
// ===========================================================================
//
// A DERIVED member is a machine on the roll; its GUARDIAN is the human who
// answers for it. Three acts move that edge — designate (mark a member derived),
// rotate (point it at a new human), release (record the edge is gone) — and two
// closure rules hold across all of them: a machine cannot guard a machine, and
// nothing guards itself (authority.rs:1354-1367).
//
// EVIDENCE (D15). An edge that is *claimed* must carry what the substrate showed
// or say outright that nothing did, and the check lives in `check_authority`
// rather than only at the authoring site, because an emitter-side guard is walked
// around by a hand-built record. Two constructors, and the difference is not
// cosmetic:
//   * BACKED — a `Signed<Observation>` already in the log, cited by CID. Agora
//     mints one from its own AT peer table: `MemberReading` (record.rs:728) is
//     field-for-field what a peer record already carries — reputation, the
//     operator key as the guardian, the operator attestation stamp — so nothing
//     is invented and ethne_ffi needs no en-at dependency to produce one.
//   * UNBACKED — an override that must say WHY, recorded as the override it is.
//
// WHOSE KEY SIGNS THE OBSERVATION is not a free choice, and this layer does not
// make it a flattering one. `Derivation::is_backed` (record.rs:140) counts an
// observation only when its observer is neither the polity nor anyone on its
// roll — the same closure D23 refused for the anchor: a polity may not vouch for
// its own ground. So `ethne_observe` signs with WHOEVER ACTUALLY LOOKED, and
// reports whether that observer was off-roll instead of quietly choosing a signer
// that would grade well. A node observing its own polity gets a real, honest
// observation that does not grade as backed, and the UI says so.
// ---------------------------------------------------------------------------

/// A timestamp from epoch seconds, matching en-pyo3's `ts` (lib.rs:200) so the
/// two runtimes accept and refuse the same stamps.
fn ts(secs: i64) -> Result<Timestamp, String> {
    Timestamp::from_second(secs).map_err(|e| format!("invalid timestamp {secs}: {e}"))
}

/// Resolve the evidence half of a guardian change: a CID naming an observation
/// already in this log, or a stated reason that nothing backs the edge. Mirrors
/// en-pyo3's `resolve_evidence` (lib.rs:121), including both refusals — passing
/// neither is legal only for a release, and the authority pass decides that.
fn resolve_evidence(
    guard: &Archive<CharterEntry>,
    evidence_cid: Option<&str>,
    unbacked_reason: Option<&str>,
) -> Result<Option<GuardianEvidence>, String> {
    match (evidence_cid, unbacked_reason) {
        (Some(_), Some(_)) => Err("pass either evidence_cid or unbacked_reason, not both".into()),
        (None, None) => Ok(None),
        (None, Some(reason)) => {
            if reason.trim().is_empty() {
                return Err("unbacked_reason may not be empty: an unexplained override \
                            is what the rule exists to prevent"
                    .into());
            }
            Ok(Some(GuardianEvidence::Unbacked { reason: reason.to_string() }))
        }
        (Some(cid_str), None) => {
            let cid = parse_cid(cid_str)?;
            match guard.get(&cid) {
                Some(CharterEntry::Observed(signed)) => {
                    Ok(Some(GuardianEvidence::Observed(Box::new(signed.clone()))))
                }
                Some(_) => Err(format!(
                    "evidence_cid {cid_str} is in this charter but is not an observation"
                )),
                None => Err(format!("evidence_cid {cid_str} is not in this charter")),
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Minting an observation (what one node saw, at one instant)
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct ReadingSpec {
    member: String,
    /// The peer's reputation as the observer's own table holds it.
    #[serde(default)]
    reputation: f64,
    /// The guardian edge AS SEEN — the peer's operator key. `None` means the
    /// observer saw the member with nobody behind it, which is a different claim
    /// from not having observed it at all (a member absent from `readings`).
    #[serde(default)]
    guardian: Option<String>,
    /// When the operator was last attested present, carried through as a STAMP.
    /// Never reduced to a freshness verdict here; that judgment is the UI's.
    #[serde(default)]
    attested_at: Option<i64>,
}

#[derive(Deserialize)]
struct ObserveSpec {
    polity_did: String,
    /// Whoever actually looked, signing for themselves. An observation must be
    /// signed by EXACTLY its observer (authority.rs:598), so one cannot be put in
    /// somebody else's mouth.
    observer: SignerSpec,
    readings: Vec<ReadingSpec>,
    #[serde(default)]
    opaque_boundary: bool,
    #[serde(default)]
    observed_at: Option<i64>,
}

fn observe_impl(a: &EthneArchive, spec: &str) -> Result<String, String> {
    let s: ObserveSpec = serde_json::from_str(spec).map_err(|e| format!("bad observe spec: {e}"))?;
    let polity = DidKey::from_str(&s.polity_did).map_err(|e| e.to_string())?;
    let observer = DidKey::from_str(&s.observer.did).map_err(|e| e.to_string())?;
    let readings = s
        .readings
        .iter()
        .map(|r| -> Result<MemberReading, String> {
            Ok(MemberReading {
                member: DidKey::from_str(&r.member).map_err(|e| e.to_string())?,
                reputation: r.reputation,
                guardian: r
                    .guardian
                    .as_deref()
                    .map(DidKey::from_str)
                    .transpose()
                    .map_err(|e| e.to_string())?,
                attested_at: r.attested_at.map(ts).transpose()?,
            })
        })
        .collect::<Result<Vec<_>, String>>()?;
    let record = Observation {
        polity: polity.clone(),
        observer: observer.clone(),
        observed_at: match s.observed_at {
            Some(t) => ts(t)?,
            None => time::now(),
        },
        readings,
        opaque_boundary: s.opaque_boundary,
    };
    let signers: Vec<(&str, &PrivKey)> = vec![(s.observer.did.as_str(), &s.observer.priv_key)];
    let signed = Signed::build(record, &signers).map_err(|e| e.to_string())?;

    let mut guard = a.0.lock().unwrap();
    // Whether evidence carried FROM this observation will grade as backed. The
    // rule is `Derivation::is_backed`'s, reported and never enforced: the record
    // is honest either way, and hiding the grade is what would not be.
    let roll = charter_state(&guard, &polity, time::now()).members;
    let off_roll = observer != polity && !roll.iter().any(|m| m == &observer);
    let cid = guard
        .append(CharterEntry::Observed(signed))
        .map_err(|e| e.to_string())?;
    serde_json::to_string(&serde_json::json!({
        "cid": cid.to_string(),
        "observer_did": observer.as_str(),
        "off_roll": off_roll,
    }))
    .map_err(|e| e.to_string())
}

/// Record what this node saw, so a guardian edge can cite it. `spec` is
/// `{"polity_did","observer":{"did","priv"},"readings":[{"member","reputation",
/// "guardian"?,"attested_at"?}…],"opaque_boundary"?,"observed_at"?}`.
///
/// Writes `{"cid","observer_did","off_roll"}` to `*out`. Pass `cid` as a guardian
/// change's `evidence_cid`. `off_roll` is false when the observer is the polity
/// or sits on its roll — the observation is still recorded and still valid, but
/// evidence drawn from it will NOT grade as backed, because a polity may not
/// vouch for its own ground.
///
/// # Safety
/// `a`/`spec`/`out` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_observe(
    a: *mut EthneArchive,
    spec: *const c_char,
    out: *mut *mut c_char,
) -> i32 {
    let run = || -> Result<(), String> {
        let a = a.as_ref().ok_or("null archive handle")?;
        let json = observe_impl(a, arg_str(spec)?)?;
        set_out(out, json)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

// ---------------------------------------------------------------------------
// The three guardianship acts
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct GuardianSpec {
    polity_did: String,
    member_did: String,
    /// Designate/rotate: the INCOMING guardian, who co-signs — answerability is
    /// accepted, never assigned. Release: the OUTGOING guardian signing
    /// themselves away, in which case `deciders` must be empty.
    #[serde(default)]
    guardian: Option<SignerSpec>,
    #[serde(default)]
    deciders: Vec<SignerSpec>,
    /// A `cid` from `ethne_observe` (backed), XOR…
    #[serde(default)]
    evidence_cid: Option<String>,
    /// …why nothing backs this edge (the D15 override, which must say why).
    #[serde(default)]
    unbacked_reason: Option<String>,
    #[serde(default)]
    rationale: String,
}

impl GuardianSpec {
    fn deciders_dids(&self) -> Result<Vec<DidKey>, String> {
        self.deciders
            .iter()
            .map(|d| DidKey::from_str(&d.did))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())
    }
}

/// Build, sign and append one `GuardianChange`. `consenting` is the signer whose
/// consent the authority pass requires beyond the deciders, if any.
fn append_guardian_change(
    a: &EthneArchive,
    record: GuardianChange,
    deciders: &[SignerSpec],
    consenting: Option<&SignerSpec>,
) -> Result<(), String> {
    let mut signers: Vec<(&str, &PrivKey)> =
        deciders.iter().map(|d| (d.did.as_str(), &d.priv_key)).collect();
    if let Some(g) = consenting {
        signers.push((g.did.as_str(), &g.priv_key));
    }
    let signed = Signed::build(record, &signers).map_err(|e| e.to_string())?;
    a.0.lock()
        .unwrap()
        .append(CharterEntry::GuardianChanged(signed))
        .map_err(|e| e.to_string())?;
    Ok(())
}

fn designate_impl(a: &EthneArchive, spec: &str) -> Result<(), String> {
    let s: GuardianSpec =
        serde_json::from_str(spec).map_err(|e| format!("bad designate spec: {e}"))?;
    let evidence = {
        let guard = a.0.lock().unwrap();
        resolve_evidence(&guard, s.evidence_cid.as_deref(), s.unbacked_reason.as_deref())?
    };
    let record = GuardianChange {
        polity: DidKey::from_str(&s.polity_did).map_err(|e| e.to_string())?,
        kind: GuardianKind::Designate,
        member: DidKey::from_str(&s.member_did).map_err(|e| e.to_string())?,
        // No guardian: a machine chartered with nobody behind it. An honest
        // state, and the one the machine-majority office rule refuses an office.
        guardian: s
            .guardian
            .as_ref()
            .map(|g| DidKey::from_str(&g.did))
            .transpose()
            .map_err(|e| e.to_string())?,
        evidence,
        rationale: s.rationale.clone(),
        deciders: s.deciders_dids()?,
        decided_at: time::now(),
    };
    append_guardian_change(a, record, &s.deciders, s.guardian.as_ref())
}

/// Mark a member a derived (machine) party. `spec` is `{"polity_did",
/// "member_did","guardian":{"did","priv"}?,"deciders":[{"did","priv"}…],
/// "evidence_cid"?|"unbacked_reason"?,"rationale"?}`.
///
/// A majority of the SEASONED roll decides; the named guardian co-signs. Naming
/// no guardian charters a machine answering to nobody, and carries no evidence.
///
/// # Safety
/// `a`/`spec` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_designate_derived(
    a: *mut EthneArchive,
    spec: *const c_char,
) -> i32 {
    let run = || -> Result<(), String> {
        let a = a.as_ref().ok_or("null archive handle")?;
        designate_impl(a, arg_str(spec)?)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

fn rotate_impl(a: &EthneArchive, spec: &str) -> Result<(), String> {
    let s: GuardianSpec = serde_json::from_str(spec).map_err(|e| format!("bad rotate spec: {e}"))?;
    let guardian = s.guardian.as_ref().ok_or(
        "a rotation must name the incoming guardian, who co-signs \
         (use ethne_release_guardian to clear the edge)",
    )?;
    let evidence = {
        let guard = a.0.lock().unwrap();
        resolve_evidence(&guard, s.evidence_cid.as_deref(), s.unbacked_reason.as_deref())?
    };
    let record = GuardianChange {
        polity: DidKey::from_str(&s.polity_did).map_err(|e| e.to_string())?,
        kind: GuardianKind::Rotate,
        member: DidKey::from_str(&s.member_did).map_err(|e| e.to_string())?,
        guardian: Some(DidKey::from_str(&guardian.did).map_err(|e| e.to_string())?),
        evidence,
        rationale: s.rationale.clone(),
        deciders: s.deciders_dids()?,
        decided_at: time::now(),
    };
    // The INCOMING guardian consents; the outgoing one is released rather than
    // held, since nobody is forced to keep serving.
    append_guardian_change(a, record, &s.deciders, Some(guardian))
}

/// Point a designated member at a new guardian — its operator changed, or a
/// machine chartered with nobody behind it acquires one. Same `spec` as
/// `ethne_designate_derived`, but `guardian` is REQUIRED and a rotation always
/// claims an edge, so evidence is too.
///
/// # Safety
/// `a`/`spec` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_rotate_guardian(a: *mut EthneArchive, spec: *const c_char) -> i32 {
    let run = || -> Result<(), String> {
        let a = a.as_ref().ok_or("null archive handle")?;
        rotate_impl(a, arg_str(spec)?)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

fn release_impl(a: &EthneArchive, spec: &str) -> Result<(), String> {
    let s: GuardianSpec = serde_json::from_str(spec).map_err(|e| format!("bad release spec: {e}"))?;
    if s.evidence_cid.is_some() || s.unbacked_reason.is_some() {
        // Refused here as well as by the core: a release claims the edge is GONE,
        // and evidence of one present would argue the opposite. Evidence of an
        // ABSENT edge is a different object (D16) and is not faked.
        return Err("a release carries no evidence: it claims the edge is gone".into());
    }
    // Two routes, and they are not interchangeable — one is the guardian's own
    // act, the other is the roll recording that the human is gone.
    if s.guardian.is_some() && !s.deciders.is_empty() {
        return Err("a release is either the departing guardian's own act (guardian, \
                    no deciders) or the roll's at a majority (deciders, no guardian)"
            .into());
    }
    let record = GuardianChange {
        polity: DidKey::from_str(&s.polity_did).map_err(|e| e.to_string())?,
        kind: GuardianKind::Release,
        member: DidKey::from_str(&s.member_did).map_err(|e| e.to_string())?,
        // Always None: a release names no incoming guardian.
        guardian: None,
        evidence: None,
        rationale: s.rationale.clone(),
        deciders: s.deciders_dids()?,
        decided_at: time::now(),
    };
    match &s.guardian {
        Some(g) => append_guardian_change(a, record, &[], Some(g)),
        None => append_guardian_change(a, record, &s.deciders, None),
    }
}

/// Record that a guardian edge is gone — the machine now answers to nobody.
/// `spec` is `{"polity_did","member_did","rationale"?}` plus EITHER
/// `"guardian":{"did","priv"}` (the departing guardian steps away on their own
/// signature) OR `"deciders":[{"did","priv"}…]` (the roll records at a majority
/// that the human is gone). Never both, and never evidence.
///
/// # Safety
/// `a`/`spec` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_release_guardian(a: *mut EthneArchive, spec: *const c_char) -> i32 {
    let run = || -> Result<(), String> {
        let a = a.as_ref().ok_or("null archive handle")?;
        release_impl(a, arg_str(spec)?)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

// ---------------------------------------------------------------------------
// Guardianship read model — the edges, and what actually backs each one
// ---------------------------------------------------------------------------

/// The evidence behind each member's CURRENT edge, folded from the log.
///
/// `guardian_state` deliberately hands back `DerivedEdge`, which drops evidence:
/// an edge is the STATE, where per-record evidence has no meaning (record.rs:167).
/// But the UI has to be able to say *unbacked, and why*, so this walks the log for
/// the last record that set each edge — the founding derivation or a later
/// `GuardianChange` — and keeps what it offered.
fn edge_evidence(
    guard: &Archive<CharterEntry>,
    polity: &DidKey,
) -> std::collections::BTreeMap<String, Option<GuardianEvidence>> {
    let mut out = std::collections::BTreeMap::new();
    for (_, e) in guard.iter() {
        match e {
            CharterEntry::PolityChartered(s) if &s.payload.polity == polity => {
                for d in &s.payload.derivations {
                    out.insert(d.member.as_str().to_string(), d.evidence.clone());
                }
            }
            CharterEntry::GuardianChanged(s) if &s.payload.polity == polity => {
                out.insert(s.payload.member.as_str().to_string(), s.payload.evidence.clone());
            }
            _ => {}
        }
    }
    out
}

fn guardian_state_impl(a: &EthneArchive, polity_did: &str) -> Result<String, String> {
    let polity = DidKey::from_str(polity_did).map_err(|e| e.to_string())?;
    let guard = a.0.lock().unwrap();
    let now = time::now();
    let roll = charter_state(&guard, &polity, now).members;
    let st = guardian_state(&guard, &polity, now);
    let evidence = edge_evidence(&guard, &polity);
    let on_roll = |did: &str| roll.iter().any(|m| m.as_str() == did);

    let edges: Vec<serde_json::Value> = st
        .derivations
        .iter()
        .map(|d| {
            let ev = evidence.get(d.member.as_str()).cloned().flatten();
            // Build the record-shaped Derivation back up and ask IT, so the
            // backing rule stays defined once and the two cannot drift.
            let backed = Derivation {
                member: d.member.clone(),
                guardian: d.guardian.clone(),
                evidence: ev.clone(),
            }
            .is_backed(&polity, on_roll);
            let mut o = serde_json::Map::new();
            o.insert("member".into(), serde_json::json!(d.member.as_str()));
            o.insert("guardian".into(), match &d.guardian {
                Some(g) => serde_json::json!(g.as_str()),
                None => serde_json::Value::Null,
            });
            o.insert("guarded".into(), serde_json::json!(d.guardian.is_some()));
            o.insert("backed".into(), serde_json::json!(backed));
            match &ev {
                Some(GuardianEvidence::Observed(ob)) => {
                    o.insert("evidence".into(), serde_json::json!("observed"));
                    o.insert("observer".into(), serde_json::json!(ob.payload.observer.as_str()));
                    o.insert(
                        "observed_at".into(),
                        serde_json::json!(ob.payload.observed_at.as_second()),
                    );
                    if !backed {
                        // The one case a caller would otherwise misread: a real,
                        // signed observation that still does not ground the edge.
                        o.insert(
                            "reason".into(),
                            serde_json::json!(
                                "the observer is the polity or sits on its roll; \
                                 a polity may not vouch for its own ground"
                            ),
                        );
                    }
                    // The attendance STAMP for this member, unreduced — a stale
                    // stamp is for the UI to warn about, never to escalate.
                    if let Some(r) = ob.payload.readings.iter().find(|r| r.member == d.member) {
                        if let Some(at) = r.attested_at {
                            o.insert("attested_at".into(), serde_json::json!(at.as_second()));
                        }
                    }
                }
                Some(GuardianEvidence::Unbacked { reason }) => {
                    o.insert("evidence".into(), serde_json::json!("unbacked"));
                    o.insert("reason".into(), serde_json::json!(reason));
                }
                None => {
                    o.insert("evidence".into(), serde_json::json!("none"));
                }
            }
            serde_json::Value::Object(o)
        })
        .collect();

    serde_json::to_string(&serde_json::json!({
        "polity_did": polity_did,
        "roll": roll.len(),
        "derived": st.derivations.len(),
        // D15: where machines are a majority, every office must trace to a human.
        "machine_majority": st.is_machine_majority(roll.len()),
        "unguarded": st.unguarded_members().iter().map(|d| d.as_str()).collect::<Vec<_>>(),
        "edges": edges,
    }))
    .map_err(|e| e.to_string())
}

/// Which members are machines and who each answers to. Writes `{"roll","derived",
/// "machine_majority","unguarded":[did…],"edges":[{"member","guardian","guarded",
/// "backed","evidence":"observed"|"unbacked"|"none","reason"?,"observer"?,
/// "observed_at"?,"attested_at"?}…]}` to `*out`.
///
/// `backed` is the grade, not the validity: an edge can be perfectly valid and
/// unbacked, and the UI must show it as what it is. `attested_at` is carried as a
/// stamp — freshness is a judgment the caller makes, and a stale stamp may warn
/// but must not escalate.
///
/// # Safety
/// `a`/`polity_did`/`out` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_guardian_state(
    a: *mut EthneArchive,
    polity_did: *const c_char,
    out: *mut *mut c_char,
) -> i32 {
    let run = || -> Result<(), String> {
        let a = a.as_ref().ok_or("null archive handle")?;
        let json = guardian_state_impl(a, arg_str(polity_did)?)?;
        set_out(out, json)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

// ---------------------------------------------------------------------------
// P3.3 S9 — The member-roll border artifact (D26)
// ---------------------------------------------------------------------------
//
// Border artifact #5: the polity's roll, published under its ROOT key, so its
// members have a real anonymous channel in the compact tier. KC models
// communities and speakers and has no member roster, so an insider holding no
// delegation was in no ring at all; this is the feed that fixes that.
//
// A ROLL NEEDS NO BUNDLE. The business page needed one because the ENVOY's
// authority had to travel beside it, hence {page, delegation}. A roll is signed
// by the polity itself, and every ethne member is a did:key, so the verifying
// key comes out of `community_did` and nothing else has to travel. The artifact
// IS the bundle.
//
// TWO VERIFICATION MODELS, as P3.1 shipped for the page, and here the difference
// is the whole point:
//   * self-contained — signature and well-formedness, no log. This is exactly
//     what KC can do, and it establishes that the PUBLISHER is who it claims to
//     be and nothing more. A roll is the polity speaking about itself.
//   * full-log — additionally folds the charter and checks the roll against what
//     the log actually says its membership was at `as_of`. THIS IS THE THING KC
//     CANNOT DO: it cannot audit a charter it has no dependency on. A polity's
//     own node can, and a reader should be told which of the two they have.
//
// `as_of` IS PROVENANCE, NOT AUTHORITY (D26). Nothing gates on it. The full
// verifier uses it only to pick which snapshot of the log to compare against.

#[derive(Deserialize)]
struct MemberRollSpec {
    polity_did: String,
    /// The polity's OWN keypair. Only its holder can publish a roll, which is a
    /// fact about who may act rather than a limitation to work around.
    root_priv: PrivKey,
    root_pub: PubKey,
    /// The instant the roll is read from the log. Defaults to now.
    as_of: Option<i64>,
    /// Defaults to `as_of`, matching en-pyo3's wrapper.
    published_at: Option<i64>,
}

fn member_roll_sign_impl(a: &EthneArchive, spec: &str) -> Result<String, String> {
    let s: MemberRollSpec =
        serde_json::from_str(spec).map_err(|e| format!("bad member roll spec: {e}"))?;
    let polity = DidKey::from_str(&s.polity_did).map_err(|e| e.to_string())?;
    let as_of = match s.as_of {
        Some(v) => ts(v)?,
        None => time::now(),
    };
    let published_at = match s.published_at {
        Some(v) => ts(v)?,
        None => as_of,
    };
    let guard = a.0.lock().unwrap();
    let charter = find_charter(&guard, &polity).ok_or("polity is not chartered")?;
    // Same shape as en-pyo3's wrapper: the read model supplies the roll, and
    // en_uplift decides what may be said about it.
    let state = charter_state(&guard, &polity, as_of);
    let signed = member_roll(charter, &state.members, &s.root_priv, s.root_pub, as_of, published_at)
        .map_err(|e| e.to_string())?;
    serde_json::to_string(&signed).map_err(|e| e.to_string())
}

/// Publish this polity's roll as KC's `MemberRoll`, signed under its root key.
/// `spec` = `{"polity_did","root_priv","root_pub","as_of"?,"published_at"?}`.
/// Writes the `Signed<MemberRoll>` JSON to `*out`.
///
/// # Safety
/// `a`/`spec`/`out` valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_member_roll_sign(
    a: *mut EthneArchive,
    spec: *const c_char,
    out: *mut *mut c_char,
) -> i32 {
    let run = || -> Result<(), String> {
        let a = a.as_ref().ok_or("null archive handle")?;
        let json = member_roll_sign_impl(a, arg_str(spec)?)?;
        set_out(out, json)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

/// The checks a roll must pass with no log in hand.
///
/// THE LAST FOUR RESTATE KC'S OWN RULE (`authorize_member_roll`,
/// kc-archive/src/authority.rs). They are restated rather than called because
/// that function is private and ethne must not depend on `kc-archive`
/// (en-uplift/src/lib.rs:60-61). That makes this a place where two statements of
/// one rule can drift apart, so each is pinned by its own test below.
///
/// Three of the four hold automatically for a roll minted by `en_uplift`, which
/// filters the polity out of its own roll and derives every `member_pubkey` from
/// its DID. This verifier exists for rolls arriving from STRANGERS, who did not
/// use that function — and a duplicate member DID is not checked at mint at all.
fn member_roll_checks(roll: &Signed<MemberRoll>) -> Result<(), String> {
    roll.verify(didkey_resolver)
        .map_err(|e| format!("roll signature invalid: {e}"))?;
    // A roll is signed by the polity and by nobody else. There is no delegation
    // hop here: the signer IS the community, and its key comes out of its DID.
    if roll.signatures.len() != 1 {
        return Err(format!(
            "a member roll carries exactly one signature, its polity's; this has {}",
            roll.signatures.len()
        ));
    }
    if signer_of(roll)? != roll.payload.community_did.as_str() {
        return Err("member roll is not signed by the community it names".into());
    }
    if roll.payload.members.is_empty() {
        return Err("a member roll must name at least one member".into());
    }
    let mut seen: BTreeSet<&str> = BTreeSet::new();
    for m in &roll.payload.members {
        if !seen.insert(m.member_did.as_str()) {
            return Err(format!("member roll names {} twice", m.member_did));
        }
        // The carried key must be the one the DID resolves to. Otherwise a roll
        // names a real member against a foreign key, putting an outsider in the
        // ring under that member's name — and the ring is what bounds a reveal.
        match m.member_did.to_pubkey() {
            Ok(pk) if pk.bytes == m.member_pubkey.bytes => {}
            Ok(_) => {
                return Err(format!(
                    "member roll gives {} a key its DID does not resolve to",
                    m.member_did
                ))
            }
            Err(_) => {
                return Err(format!(
                    "member roll names {}, whose key cannot be resolved from its DID",
                    m.member_did
                ))
            }
        }
        if m.member_did == roll.payload.community_did {
            return Err("a member roll may not name the community itself as a member: its \
                        root key is already an insider, and a second entry would be a \
                        repeated ring position"
                .into());
        }
    }
    Ok(())
}

fn member_roll_verify_impl(roll_json: &str) -> Result<(), String> {
    let roll: Signed<MemberRoll> =
        serde_json::from_str(roll_json).map_err(|e| format!("bad member roll: {e}"))?;
    member_roll_checks(&roll)
}

/// Verify a SELF-CONTAINED member roll: signed by the polity it names, and
/// well-formed by KC's own rule. Needs no charter log. 0 if authentic, negative
/// otherwise (reason in `ethne_last_error`).
///
/// This proves the PUBLISHER, not the roll. A roll is the polity speaking about
/// itself, and this check cannot say whether what it says is true — only that
/// the polity is the one saying it. That is exactly the reach KC has.
///
/// # Safety
/// `roll_json` valid C string.
#[no_mangle]
pub unsafe extern "C" fn ethne_member_roll_verify(roll_json: *const c_char) -> i32 {
    let run = || -> Result<(), String> { member_roll_verify_impl(arg_str(roll_json)?) };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

fn member_roll_verify_full_impl(a: &EthneArchive, roll_json: &str) -> Result<(), String> {
    let roll: Signed<MemberRoll> =
        serde_json::from_str(roll_json).map_err(|e| format!("bad member roll: {e}"))?;
    member_roll_checks(&roll)?;
    let guard = a.0.lock().unwrap();
    verify_all(&guard).map_err(|e| format!("charter signatures: {e}"))?;
    check_authority(&guard).map_err(|e| format!("charter authority: {e}"))?;
    // `as_of` picks the snapshot. It is provenance, so it is not checked against
    // anything — it only says which reading of the log this roll claims to be.
    let state = charter_state(&guard, &roll.payload.community_did, roll.payload.as_of);
    let expected: BTreeSet<&str> = state
        .members
        .iter()
        .filter(|m| *m != &roll.payload.community_did)
        .map(|m| m.as_str())
        .collect();
    let got: BTreeSet<&str> =
        roll.payload.members.iter().map(|m| m.member_did.as_str()).collect();
    if expected != got {
        return Err(format!(
            "roll does not match the log at its as_of: it names {} member(s), the log has {}",
            got.len(),
            expected.len()
        ));
    }
    Ok(())
}

/// Verify a member roll against the FULL charter log `a`: everything
/// `ethne_member_roll_verify` checks, plus charter validity (verify_all +
/// check_authority) and the roll naming exactly the members the log says the
/// polity had at the roll's `as_of`. 0 / negative.
///
/// This is the check the compact tier CANNOT make — it holds no dependency on
/// this tier's charter, so it can only establish the publisher. A polity's own
/// node holds the log and can audit the claim itself. Callers should keep the
/// two answers apart rather than reporting one as the other.
///
/// # Safety
/// `a` valid handle, `roll_json` valid C string.
#[no_mangle]
pub unsafe extern "C" fn ethne_member_roll_verify_full(
    a: *mut EthneArchive,
    roll_json: *const c_char,
) -> i32 {
    let run = || -> Result<(), String> {
        let a = a.as_ref().ok_or("null archive handle")?;
        member_roll_verify_full_impl(a, arg_str(roll_json)?)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

// ---------------------------------------------------------------------------
// Rust-side round-trip tests (cargo test) — no FFI, exercise the composition.
// ---------------------------------------------------------------------------

// ===========================================================================
// Phase 4 — per-community content policy (Ethne D37)
// ===========================================================================
//
// A community is a polity, and how content posted in its name is moderated is
// the roll's decision (`ContentPolicy`, tightened at a majority and loosened only
// above one). Ethne keeps the RULE; this file keeps the three things the rule is
// FOR, which are Agora's and not Ethne's:
//
//   * the POLICY ARTIFACT — `Signed<CommunityPolicy>` under the polity's ROOT key,
//     naming the policy in force and the members who may label under it. It is
//     what a reader follows. A higher `seq` replaces it whole, so a revoked
//     moderator drops out of the next one with no further act (D36's rule, not
//     D26's union).
//   * the MODERATOR LABEL — `Signed<PostLabel>` under the moderator's OWN member
//     key, honoured only where the policy it is read against lists that member.
//     Per (moderator, post) the highest seq wins; an empty label set retracts.
//   * the VERDICT — show, warn or hide, with the reasons. It lives here, as a pure
//     function, so the app and the live cohort's ctypes driver run the SAME code
//     over the same received bytes, and the cohort proves the hiding itself.
//
// None of this crosses into the AT core as anything but opaque bytes: the core
// carries a policy and a label, and never parses either (business_post.h).

/// The policy artifact's wire cap, mirrored by AT_COMMUNITY_POLICY_BUNDLE_LEN in
/// at-social (social_msg_types.h, at_agora.h, the shim and the cohort ctypes).
/// `the_worst_case_policy_fits_the_wire_bound` measures it on every run.
const COMMUNITY_POLICY_BUNDLE_MAX: usize = 4096;

/// The most moderators one policy artifact lists. Chosen against the wire cap:
/// MEASURED with every bound at its maximum (32 labels of 32 bytes, 16 moderators,
/// the largest cap and seq) a policy is 2980 bytes, of which the moderators are
/// ~60 bytes each, leaving 1116 bytes of headroom under the cap.
const POLICY_MODERATORS_MAX: usize = 16;

/// The moderator label's wire cap, mirrored by AT_POST_LABEL_BUNDLE_LEN. The
/// worst case (eight 32-byte labels, the largest seq) MEASURES 969 bytes;
/// `the_worst_case_label_fits_the_wire_bound` re-measures it on every run.
const POST_LABEL_BUNDLE_MAX: usize = 1536;

/// The most labels one post, or one moderator label, carries. A post's canonical
/// form counts them in one byte (at-social post.h); eight is the product bound.
const POST_LABELS_MAX: usize = 8;

/// A post's content id: blake2b-256, lowercase hex (at-social AT_POST_ID_HEX_LEN).
const POST_ID_HEX_LEN: usize = 64;

/// The artifact a reader follows: the policy in force, and who may label.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct CommunityPolicy {
    community_did: DidKey,
    /// The charter log's length when this was minted. The log is append-only, so a
    /// later artifact always carries a larger seq, and a change of moderators with
    /// no change of policy still produces a newer one.
    seq: u64,
    policy: ContentPolicy,
    /// Inducted holders of `Moderator` at minting, sorted by DID.
    moderators: Vec<DidKey>,
    /// The community's relay roster (Ethne D36/D38), AT's own signed
    /// `at-relay-roster` file text, when the polity runs relays: how a follower
    /// learns its community's area hubs. Absent serializes as before, so a policy
    /// minted without one keeps its bytes and its signature.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    hubs: Option<String>,
}

/// AT's roster signature domain and body typename (AT relay_rosters.py).
const ROSTER_DOMAIN: &str = "at-relay-roster-v1|";
const ROSTER_TYPENAME: &str = "at-relay-roster";
/// The most relays AT accepts in one roster (en_uplift ROSTER_MAX).
const ROSTER_RELAYS_MAX: usize = 64;

/// Verify a roster carried inside a policy: signed by the community's own root key
/// under AT's domain, and shaped as AT will accept it. Returns each hub's areas,
/// keyed by its relay hint. AT verifies the file again when a follower installs
/// it; this is the reader's own check, so a bad roster never reaches that far.
fn read_hub_roster(community: &DidKey, text: &str) -> Result<serde_json::Map<String, serde_json::Value>, String> {
    let outer: serde_json::Value =
        serde_json::from_str(text).map_err(|e| format!("bad hub roster: {e}"))?;
    let body_str = outer["body"].as_str().ok_or("hub roster has no body")?;
    let sig_hex = outer["sig"].as_str().ok_or("hub roster has no sig")?;
    let root = community.to_pubkey().map_err(|e| e.to_string())?;
    let mut msg = ROSTER_DOMAIN.as_bytes().to_vec();
    msg.extend_from_slice(body_str.as_bytes());
    let sig = en_core::Signature {
        alg: Alg::Ed25519,
        bytes: hex::decode(sig_hex).map_err(|_| "hub roster sig is not hex")?,
    };
    keys::verify(&root, &msg, &sig).map_err(|_| "hub roster is not signed by its community")?;
    let body: serde_json::Value =
        serde_json::from_str(body_str).map_err(|e| format!("bad hub roster body: {e}"))?;
    if body["typename"] != ROSTER_TYPENAME || body["v"] != 1 || !body["seq"].is_u64()
        || body["issuer"] != hex::encode(&root.bytes)
    {
        return Err("hub roster is not this community's AT relay roster".into());
    }
    let relays: Vec<&str> = body["relays"]
        .as_array()
        .ok_or("hub roster has no relays")?
        .iter()
        .map(|r| r.as_str().ok_or("a roster relay is not a string"))
        .collect::<Result<_, _>>()?;
    if relays.len() > ROSTER_RELAYS_MAX {
        return Err("hub roster lists more relays than AT accepts".into());
    }
    let mut out = serde_json::Map::new();
    if let Some(areas) = body.get("areas") {
        let areas = areas.as_object().ok_or("hub roster areas is not an object")?;
        for (hint, listed) in areas {
            let listed = listed.as_array().ok_or("hub areas is not a list")?;
            if !relays.contains(&hint.as_str()) || listed.is_empty() || listed.len() > RELAY_AREAS_MAX
                || !listed.iter().all(|a| a.as_str().is_some_and(is_geohash_area))
            {
                return Err(format!("hub roster names bad areas for {hint}"));
            }
            out.insert(hint.clone(), serde_json::Value::Array(listed.clone()));
        }
    }
    Ok(out)
}

/// A moderator's labels on one post, in one community.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct PostLabel {
    community_did: DidKey,
    post_id: String,
    /// Empty retracts this moderator's earlier labels on the post.
    labels: Vec<String>,
    /// Orders one moderator's labels on one post; the highest wins.
    seq: u64,
    ts: i64,
}

fn parse_office(s: &str) -> Office {
    match s {
        "Convener" => Office::Convener,
        "Inductor" => Office::Inductor,
        "EnvoyAuthorizer" => Office::EnvoyAuthorizer,
        "CharterKeeper" => Office::CharterKeeper,
        "RendezvousOperator" => Office::RendezvousOperator,
        "Moderator" => Office::Moderator,
        "ReleaseOfficer" => Office::ReleaseOfficer,
        other => Office::Other(other.to_string()),
    }
}

fn office_name(o: &Office) -> String {
    match o {
        Office::Convener => "Convener".into(),
        Office::Inductor => "Inductor".into(),
        Office::EnvoyAuthorizer => "EnvoyAuthorizer".into(),
        Office::CharterKeeper => "CharterKeeper".into(),
        Office::RendezvousOperator => "RendezvousOperator".into(),
        Office::Moderator => "Moderator".into(),
        Office::ReleaseOfficer => "ReleaseOfficer".into(),
        Office::Other(s) => s.clone(),
    }
}

fn dids_of(v: &[String]) -> Result<Vec<DidKey>, String> {
    v.iter()
        .map(|d| DidKey::from_str(d))
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())
}

fn check_labels(labels: &[String]) -> Result<(), String> {
    if labels.len() > POST_LABELS_MAX {
        return Err(format!("{} labels exceed the {POST_LABELS_MAX} one post carries", labels.len()));
    }
    for l in labels {
        check_label(l)?;
    }
    Ok(())
}

fn describe_policy_amendment(a: &ContentPolicyAmendment) -> String {
    let p = &a.policy;
    let mut rules = vec![format!("minimum tier {}", p.min_tier)];
    if p.operator_bound_required {
        rules.push("operator-bound authors only".into());
    }
    match p.daily_post_cap {
        Some(n) => rules.push(format!("at most {n} posts per author per day")),
        None => rules.push("no daily cap".into()),
    }
    for (l, act) in &p.labels {
        rules.push(format!("'{l}' {}", match act {
            LabelAction::Allow => "allowed",
            LabelAction::Warn => "behind a warning",
            LabelAction::Hide => "hidden",
        }));
    }
    for (st, act) in &p.standing {
        rules.push(format!("posts from {} communities {}", match st {
            en_charter::CommunityStanding::Probationary => "probationary",
            en_charter::CommunityStanding::Denied => "denied",
            en_charter::CommunityStanding::Anathema => "anathema",
            en_charter::CommunityStanding::Outside => "outside our compacts",
        }, match act {
            LabelAction::Allow => "allowed",
            LabelAction::Warn => "behind a warning",
            LabelAction::Hide => "hidden",
        }));
    }
    format!(
        "Set the content policy of {} to: {}. Decided by {} member(s).",
        a.polity,
        rules.join("; "),
        a.deciders.len()
    )
}

fn describe_office_change(o: &OfficeChange) -> String {
    let what = match o.kind {
        OfficeKind::Confer => "Confer",
        OfficeKind::Resign => "Resign",
        OfficeKind::Revoke => "Revoke",
    };
    format!(
        "{what} the office {} {} {} in {}. Decided by {} member(s).",
        office_name(&o.office),
        if o.kind == OfficeKind::Confer { "on" } else { "held by" },
        o.holder,
        o.polity,
        o.deciders.len()
    )
}

// --- Charter acts, all keys in one process (tools, tests) --------------------

#[derive(Deserialize)]
struct AmendPolicySpec {
    polity_did: String,
    policy: ContentPolicy,
    #[serde(default)]
    rationale: String,
    deciders: Vec<SignerSpec>,
}

fn amend_policy_impl(a: &EthneArchive, spec: &str) -> Result<(), String> {
    let s: AmendPolicySpec =
        serde_json::from_str(spec).map_err(|e| format!("bad policy spec: {e}"))?;
    s.policy.check_shape()?;
    let record = ContentPolicyAmendment {
        polity: DidKey::from_str(&s.polity_did).map_err(|e| e.to_string())?,
        policy: s.policy,
        rationale: s.rationale,
        deciders: dids_of(&s.deciders.iter().map(|d| d.did.clone()).collect::<Vec<_>>())?,
        decided_at: time::now(),
    };
    let signers: Vec<(&str, &PrivKey)> =
        s.deciders.iter().map(|d| (d.did.as_str(), &d.priv_key)).collect();
    let signed = Signed::build(record, &signers).map_err(|e| e.to_string())?;
    a.0.lock()
        .unwrap()
        .append(CharterEntry::ContentPolicyAmended(signed))
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// Replace the polity's content policy. `spec` is `{"polity_did","policy":
/// {"operator_bound_required","min_tier","daily_post_cap","labels":{label:
/// "Allow"|"Warn"|"Hide"}},"rationale"?,"deciders":[{"did","priv"}…]}`. A majority
/// of the seasoned roll tightens; loosening anything needs a majority + 1, which
/// the authority pass decides (`ethne_verify`).
///
/// # Safety
/// `a`/`spec` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_amend_content_policy(a: *mut EthneArchive, spec: *const c_char) -> i32 {
    let run = || -> Result<(), String> {
        let a = a.as_ref().ok_or("null archive handle")?;
        amend_policy_impl(a, arg_str(spec)?)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

#[derive(Deserialize)]
struct OfficeSpec {
    polity_did: String,
    office: String,
    /// Confer: the holder with key (they consent). Revoke: the DID is enough.
    holder_did: String,
    #[serde(default)]
    holder_priv: Option<PrivKey>,
    #[serde(default)]
    rationale: String,
    deciders: Vec<SignerSpec>,
}

fn office_impl(a: &EthneArchive, spec: &str, kind: OfficeKind) -> Result<(), String> {
    let s: OfficeSpec = serde_json::from_str(spec).map_err(|e| format!("bad office spec: {e}"))?;
    let record = OfficeChange {
        polity: DidKey::from_str(&s.polity_did).map_err(|e| e.to_string())?,
        kind,
        office: parse_office(&s.office),
        holder: DidKey::from_str(&s.holder_did).map_err(|e| e.to_string())?,
        rationale: s.rationale,
        deciders: dids_of(&s.deciders.iter().map(|d| d.did.clone()).collect::<Vec<_>>())?,
        decided_at: time::now(),
    };
    let mut signers: Vec<(&str, &PrivKey)> =
        s.deciders.iter().map(|d| (d.did.as_str(), &d.priv_key)).collect();
    if kind == OfficeKind::Confer && !s.deciders.iter().any(|d| d.did == s.holder_did) {
        let k = s.holder_priv.as_ref().ok_or("a conferral needs the holder's consent (holder_priv)")?;
        signers.push((s.holder_did.as_str(), k));
    }
    let signed = Signed::build(record, &signers).map_err(|e| e.to_string())?;
    a.0.lock()
        .unwrap()
        .append(CharterEntry::OfficeChanged(signed))
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// Confer an office. `spec` is `{"polity_did","office","holder_did","holder_priv",
/// "rationale"?,"deciders":[{"did","priv"}…]}`: a majority decides, the holder
/// consents. `office` is a named office ("Moderator", …) or any other string.
///
/// # Safety
/// `a`/`spec` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_confer_office(a: *mut EthneArchive, spec: *const c_char) -> i32 {
    let run = || -> Result<(), String> {
        let a = a.as_ref().ok_or("null archive handle")?;
        office_impl(a, arg_str(spec)?, OfficeKind::Confer)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

#[derive(Deserialize)]
struct RelaySpec {
    polity_did: String,
    /// The operator, and the declaration's sole signer.
    member: SignerSpec,
    at_uuid: String,
    #[serde(default)]
    host: String,
    #[serde(default)]
    port: u16,
    /// Geohash areas the relay is a hub for (D38); empty for a plain relay.
    #[serde(default)]
    areas: Vec<String>,
    #[serde(default)]
    withdrawn: bool,
}

fn relay_impl(a: &EthneArchive, spec: &str) -> Result<(), String> {
    let s: RelaySpec = serde_json::from_str(spec).map_err(|e| format!("bad relay spec: {e}"))?;
    let record = RelayEndpoint {
        polity: DidKey::from_str(&s.polity_did).map_err(|e| e.to_string())?,
        member: DidKey::from_str(&s.member.did).map_err(|e| e.to_string())?,
        at_uuid: s.at_uuid,
        host: s.host,
        port: s.port,
        declared_at: time::now(),
        withdrawn: s.withdrawn,
        areas: s.areas,
    };
    // Refused here rather than by the authority pass alone: a declaration AT
    // could never read would sit in the log doing nothing.
    record.check_shape()?;
    let signed = Signed::build(record, &[(s.member.did.as_str(), &s.member.priv_key)])
        .map_err(|e| e.to_string())?;
    a.0.lock()
        .unwrap()
        .append(CharterEntry::RelayEndpointDeclared(signed))
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// A rendezvous operator declares where its relay listens, and which geohash
/// areas it is a hub for (Ethne D36/D38). `spec` is `{"polity_did","member":
/// {"did","priv"},"at_uuid","host","port","areas"?,"withdrawn"?}`, signed by the
/// member alone; the authority pass refuses it unless the member holds
/// `RendezvousOperator`. A policy minted with `"hubs":true` then carries the
/// polity's roster to every follower.
///
/// # Safety
/// `a`/`spec` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_declare_relay_endpoint(a: *mut EthneArchive, spec: *const c_char) -> i32 {
    let run = || -> Result<(), String> {
        let a = a.as_ref().ok_or("null archive handle")?;
        relay_impl(a, arg_str(spec)?)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

/// Revoke an office. `spec` is `{"polity_did","office","holder_did","rationale"?,
/// "deciders":[{"did","priv"}…]}`: a majority, the holder excluded.
///
/// # Safety
/// `a`/`spec` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_revoke_office(a: *mut EthneArchive, spec: *const c_char) -> i32 {
    let run = || -> Result<(), String> {
        let a = a.as_ref().ok_or("null archive handle")?;
        office_impl(a, arg_str(spec)?, OfficeKind::Revoke)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

fn policy_state_impl(a: &EthneArchive, polity_did: &str) -> Result<String, String> {
    let polity = DidKey::from_str(polity_did).map_err(|e| e.to_string())?;
    let guard = a.0.lock().unwrap();
    let st = content_policy_state(&guard, &polity, time::now());
    serde_json::to_string(&serde_json::json!({
        "policy": st.policy,
        "set_by": st.set_by.map(|c| c.to_string()),
        "moderators": st.moderators.iter().map(DidKey::as_str).collect::<Vec<_>>(),
    }))
    .map_err(|e| e.to_string())
}

/// The polity's content policy as this log says it is now: `{"policy",
/// "set_by","moderators"}`. Only accepted amendments are read, and moderators are
/// inducted holders of `Moderator` (D37).
///
/// # Safety
/// `a`/`polity_did`/`out` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_content_policy_state(
    a: *mut EthneArchive,
    polity_did: *const c_char,
    out: *mut *mut c_char,
) -> i32 {
    let run = || -> Result<(), String> {
        let a = a.as_ref().ok_or("null archive handle")?;
        set_out(out, policy_state_impl(a, arg_str(polity_did)?)?)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

// --- Detached co-signing: the policy and office classes ----------------------

fn pending_content_policy(s: &PendingSpec) -> Result<String, String> {
    if s.op != "amend" {
        return Err(format!("unknown content_policy op '{}': the one op is 'amend'", s.op));
    }
    let policy = s.policy.clone().ok_or("a content_policy exchange needs `policy`")?;
    policy.check_shape()?;
    let polity = DidKey::from_str(&s.polity_did).map_err(|e| e.to_string())?;
    let polity_did = polity.as_str().to_string();
    let record = ContentPolicyAmendment {
        polity,
        policy,
        rationale: s.rationale.clone(),
        deciders: dids_of(&s.deciders)?,
        decided_at: time::now(),
    };
    let description = describe_policy_amendment(&record);
    let p = pending(record, description).map_err(|e| e.to_string())?;
    let bytes = hex::encode(&p.bytes);
    check_wire_bound(&bytes)?;
    serde_json::to_string(&serde_json::json!({
        "record": "content_policy",
        "op": s.op,
        "polity_did": polity_did,
        "payload": p.payload,
        "bytes": bytes,
        "cid": p.cid.to_string(),
        "description": p.description,
        "signers_required": s.deciders,
    }))
    .map_err(|e| e.to_string())
}

fn pending_office(s: &PendingSpec) -> Result<String, String> {
    let kind = match s.op.as_str() {
        "confer" => OfficeKind::Confer,
        "revoke" => OfficeKind::Revoke,
        other => {
            return Err(format!(
                "unknown office op '{other}': 'confer' or 'revoke' (a resignation is self-signed)"
            ))
        }
    };
    let office = parse_office(s.office.as_deref().ok_or("an office exchange needs `office`")?);
    let polity = DidKey::from_str(&s.polity_did).map_err(|e| e.to_string())?;
    let polity_did = polity.as_str().to_string();
    // A conferral needs the holder's consent; a revocation excludes them.
    let mut required = s.deciders.clone();
    if kind == OfficeKind::Confer && !required.contains(&s.member_did) {
        required.push(s.member_did.clone());
    }
    let record = OfficeChange {
        polity,
        kind,
        office,
        holder: DidKey::from_str(&s.member_did).map_err(|e| e.to_string())?,
        rationale: s.rationale.clone(),
        deciders: dids_of(&s.deciders)?,
        decided_at: time::now(),
    };
    let description = describe_office_change(&record);
    let p = pending(record, description).map_err(|e| e.to_string())?;
    let bytes = hex::encode(&p.bytes);
    check_wire_bound(&bytes)?;
    serde_json::to_string(&serde_json::json!({
        "record": "office",
        "op": s.op,
        "polity_did": polity_did,
        "payload": p.payload,
        "bytes": bytes,
        "cid": p.cid.to_string(),
        "description": p.description,
        "signers_required": required,
    }))
    .map_err(|e| e.to_string())
}

fn describe_content_policy_bytes(
    bytes: &[u8],
    out: &mut serde_json::Map<String, serde_json::Value>,
) -> Result<(), String> {
    let a: ContentPolicyAmendment = canonical::from_canonical_cbor(bytes)
        .map_err(|e| format!("these bytes are not a content policy amendment: {e}"))?;
    out.insert("op".into(), serde_json::json!("amend"));
    out.insert("polity_did".into(), serde_json::json!(a.polity.as_str()));
    out.insert("policy".into(), serde_json::to_value(&a.policy).map_err(|e| e.to_string())?);
    out.insert("deciders".into(), serde_json::json!(
        a.deciders.iter().map(DidKey::as_str).collect::<Vec<_>>()
    ));
    out.insert("description".into(), serde_json::json!(describe_policy_amendment(&a)));
    Ok(())
}

// --- Detached co-signing: compact acts, rites and commitments (Phase 5) ------

fn compact_op(k: CompactActKind) -> &'static str {
    match k {
        CompactActKind::Join => "join",
        CompactActKind::Admit => "admit",
        CompactActKind::Sponsor => "sponsor",
        CompactActKind::Refuse => "refuse",
        CompactActKind::Anathematize => "anathema",
        CompactActKind::Lift => "lift",
    }
}

fn describe_compact_act(a: &CompactAct) -> String {
    let who = a.counterparties.iter().map(DidKey::as_str).collect::<Vec<_>>().join(", ");
    let what = match a.kind {
        CompactActKind::Join => format!("found or join the compact '{}' with {who}", a.compact),
        CompactActKind::Admit => format!("admit {who} into the compact '{}'", a.compact),
        CompactActKind::Sponsor => format!(
            "vouch for {who} entering '{}', staking our standing for {} day(s)",
            a.compact,
            a.probation_days.unwrap_or(0)
        ),
        CompactActKind::Refuse => format!("refuse {who} admission to '{}'", a.compact),
        CompactActKind::Anathematize => format!("report {who} for designation anathema in '{}'", a.compact),
        CompactActKind::Lift => format!("lift the designation of {who} in '{}'", a.compact),
    };
    format!(
        "{} decides to {what}{}. Decided by {} member(s){}.",
        a.polity,
        if a.rationale.trim().is_empty() { String::new() } else { format!(" ({})", a.rationale) },
        a.deciders.len(),
        if a.kind.is_severe() { "; this needs more than a majority" } else { "" }
    )
}

/// `body` with the instant `field` set to now: the authoring node stamps it.
fn stamped(body: &Option<serde_json::Value>, field: &str) -> Result<serde_json::Value, String> {
    let mut b = body.clone().ok_or("this exchange needs `body`")?;
    let obj = b.as_object_mut().ok_or("`body` is an object")?;
    obj.insert(field.into(), serde_json::to_value(time::now()).map_err(|e| e.to_string())?);
    Ok(b)
}

fn pending_out<T: Serialize>(
    record: &str,
    op: &str,
    polity: &DidKey,
    payload: T,
    description: String,
    required: Vec<String>,
) -> Result<String, String> {
    let p = pending(payload, description).map_err(|e| e.to_string())?;
    let bytes = hex::encode(&p.bytes);
    check_wire_bound(&bytes)?;
    serde_json::to_string(&serde_json::json!({
        "record": record,
        "op": op,
        "polity_did": polity.as_str(),
        "payload": p.payload,
        "bytes": bytes,
        "cid": p.cid.to_string(),
        "description": p.description,
        "signers_required": required,
    }))
    .map_err(|e| e.to_string())
}

fn pending_compact(s: &PendingSpec) -> Result<String, String> {
    let act: CompactAct = serde_json::from_value(stamped(&s.body, "decided_at")?)
        .map_err(|e| format!("body is not a compact act: {e}"))?;
    act.check_shape()?;
    if compact_op(act.kind) != s.op {
        return Err(format!("op '{}' does not match the act's kind {:?}", s.op, act.kind));
    }
    let description = describe_compact_act(&act);
    let required = act.deciders.iter().map(|d| d.as_str().to_string()).collect();
    let polity = act.polity.clone();
    pending_out("compact", &s.op, &polity, act, description, required)
}

fn pending_rite(s: &PendingSpec) -> Result<String, String> {
    match s.op.as_str() {
        "movement" => {
            let m: RiteMovement = serde_json::from_value(stamped(&s.body, "recited_at")?)
                .map_err(|e| format!("body is not a rite movement: {e}"))?;
            // The reciter signs; everyone attending co-signs.
            let mut required = vec![m.member.as_str().to_string()];
            required.extend(m.attending.iter().map(|d| d.as_str().to_string()));
            let description = format!(
                "Record that {} recited {:?} of the rite of {}, with {} attending.",
                m.member, m.movement, m.polity, m.attending.len()
            );
            let polity = m.polity.clone();
            pending_out("rite", "movement", &polity, m, description, required)
        }
        "affirm" => {
            // The movements are cited by the CIDs `ethne_recite_movement` returned,
            // as strings; the record holds them in their binary form.
            let mut body = stamped(&s.body, "affirmed_at")?;
            if let Some(list) = body.get_mut("movements").and_then(|v| v.as_array_mut()) {
                for m in list.iter_mut() {
                    if let Some(text) = m.as_str() {
                        *m = serde_json::to_value(parse_cid(text)?).map_err(|e| e.to_string())?;
                    }
                }
            }
            let a: Affirmation = serde_json::from_value(body)
                .map_err(|e| format!("body is not an affirmation: {e}"))?;
            let mut required: Vec<String> = Vec::new();
            if a.kind == AffirmationKind::Induction {
                required.extend(a.witnesses.iter().map(|d| d.as_str().to_string()));
            }
            required.push(a.member.as_str().to_string());
            let description = format!(
                "Complete the {:?} of {} in {}, citing {} movement(s), witnessed by {}.",
                a.kind, a.member, a.polity, a.movements.len(), a.witnesses.len()
            );
            let polity = a.polity.clone();
            pending_out("rite", "affirm", &polity, a, description, required)
        }
        other => Err(format!("unknown rite op '{other}': 'movement' or 'affirm'")),
    }
}

fn pending_commitment(s: &PendingSpec) -> Result<String, String> {
    let a: CommitmentAmendment = serde_json::from_value(stamped(&s.body, "decided_at")?)
        .map_err(|e| format!("body is not a commitment amendment: {e}"))?;
    let required = a.deciders.iter().map(|d| d.as_str().to_string()).collect();
    let description = format!(
        "{:?} the commitment '{}' ({}) of {}. Decided by {} member(s).",
        a.kind, a.commitment.key, a.commitment.description, a.polity, a.deciders.len()
    );
    let polity = a.polity.clone();
    pending_out("commitment", "amend", &polity, a, description, required)
}

fn describe_rite_bytes(
    bytes: &[u8],
    out: &mut serde_json::Map<String, serde_json::Value>,
) -> Result<(), String> {
    if let Ok(m) = canonical::from_canonical_cbor::<RiteMovement>(bytes) {
        out.insert("op".into(), serde_json::json!("movement"));
        out.insert("polity_did".into(), serde_json::json!(m.polity.as_str()));
        out.insert("member_did".into(), serde_json::json!(m.member.as_str()));
        out.insert("description".into(), serde_json::json!(format!(
            "Record that {} recited {:?} of the rite of {} (\"{}\"), with {} attending.",
            m.member, m.movement, m.polity, m.statement, m.attending.len()
        )));
        return Ok(());
    }
    let a: Affirmation = canonical::from_canonical_cbor(bytes)
        .map_err(|e| format!("these bytes are not a rite record: {e}"))?;
    out.insert("op".into(), serde_json::json!("affirm"));
    out.insert("polity_did".into(), serde_json::json!(a.polity.as_str()));
    out.insert("member_did".into(), serde_json::json!(a.member.as_str()));
    out.insert("description".into(), serde_json::json!(format!(
        "Complete the {:?} of {} in {}, citing {} movement(s).",
        a.kind, a.member, a.polity, a.movements.len()
    )));
    Ok(())
}

fn describe_office_bytes(
    bytes: &[u8],
    out: &mut serde_json::Map<String, serde_json::Value>,
) -> Result<(), String> {
    let o: OfficeChange = canonical::from_canonical_cbor(bytes)
        .map_err(|e| format!("these bytes are not an office change: {e}"))?;
    out.insert("op".into(), serde_json::json!(match o.kind {
        OfficeKind::Confer => "confer",
        OfficeKind::Resign => "resign",
        OfficeKind::Revoke => "revoke",
    }));
    out.insert("polity_did".into(), serde_json::json!(o.polity.as_str()));
    out.insert("office".into(), serde_json::json!(office_name(&o.office)));
    out.insert("member_did".into(), serde_json::json!(o.holder.as_str()));
    out.insert("deciders".into(), serde_json::json!(
        o.deciders.iter().map(DidKey::as_str).collect::<Vec<_>>()
    ));
    out.insert("description".into(), serde_json::json!(describe_office_change(&o)));
    Ok(())
}

// --- The policy artifact -------------------------------------------------------

#[derive(Deserialize)]
struct PolicySignSpec {
    polity_did: String,
    /// The polity's OWN key: the policy is the polity speaking, like its roll.
    root_priv: PrivKey,
    /// Carry the polity's relay roster (its rendezvous operators and area hubs,
    /// D36/D38) inside the policy, so followers learn their community's hubs.
    #[serde(default)]
    hubs: bool,
}

fn policy_sign_impl(a: &EthneArchive, spec: &str) -> Result<String, String> {
    let s: PolicySignSpec =
        serde_json::from_str(spec).map_err(|e| format!("bad policy sign spec: {e}"))?;
    let polity = DidKey::from_str(&s.polity_did).map_err(|e| e.to_string())?;
    let guard = a.0.lock().unwrap();
    if find_charter(&guard, &polity).is_none() {
        return Err(format!("no charter for {polity} in this log"));
    }
    let st = content_policy_state(&guard, &polity, time::now());
    if st.moderators.len() > POLICY_MODERATORS_MAX {
        return Err(format!(
            "{} moderators exceed the {POLICY_MODERATORS_MAX} one policy lists",
            st.moderators.len()
        ));
    }
    let seq = guard.iter().count() as u64;
    // The roster's seq is the log's length too: AT keeps the highest per issuer,
    // and the log only grows.
    let hubs = if s.hubs {
        let charter = find_charter(&guard, &polity).ok_or("no charter")?;
        let relays = rendezvous_state(&guard, &polity, time::now());
        let root_pub = keys::public_of(&s.root_priv).map_err(|e| e.to_string())?;
        Some(rendezvous_roster(charter, &relays, &s.root_priv, &root_pub, seq).map_err(|e| e.to_string())?)
    } else {
        None
    };
    let artifact = CommunityPolicy {
        community_did: polity.clone(),
        seq,
        policy: st.policy,
        moderators: st.moderators,
        hubs,
    };
    drop(guard);
    let signed = Signed::build(artifact, &[(polity.as_str(), &s.root_priv)]).map_err(|e| e.to_string())?;
    // Signing under the wrong key still builds; only verification can tell.
    signed
        .verify(didkey_resolver)
        .map_err(|_| "root_priv is not the polity's own key".to_string())?;
    let json = serde_json::to_string(&signed).map_err(|e| e.to_string())?;
    if json.len() > COMMUNITY_POLICY_BUNDLE_MAX {
        return Err(format!(
            "this policy is {} bytes, over the {COMMUNITY_POLICY_BUNDLE_MAX} the wire carries",
            json.len()
        ));
    }
    Ok(json)
}

/// Mint the polity's policy artifact from this log, now. `spec` is
/// `{"polity_did","root_priv"}`. Writes the `Signed<CommunityPolicy>` JSON to
/// `*out`: the policy in force, the moderators, and `seq` = the log's length.
///
/// # Safety
/// `a`/`spec`/`out` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_content_policy_sign(
    a: *mut EthneArchive,
    spec: *const c_char,
    out: *mut *mut c_char,
) -> i32 {
    let run = || -> Result<(), String> {
        let a = a.as_ref().ok_or("null archive handle")?;
        set_out(out, policy_sign_impl(a, arg_str(spec)?)?)
    };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

/// Parse and verify a policy artifact: signed by the community it names, and
/// well-shaped. What a reader trusts is exactly this, so every check is here.
fn read_policy(json: &str) -> Result<CommunityPolicy, String> {
    if json.len() > COMMUNITY_POLICY_BUNDLE_MAX {
        return Err("policy is over the wire bound".into());
    }
    let signed: Signed<CommunityPolicy> =
        serde_json::from_str(json).map_err(|e| format!("bad policy: {e}"))?;
    signed.verify(didkey_resolver).map_err(|e| format!("policy signature invalid: {e}"))?;
    if signed.signatures.len() != 1
        || signer_of(&signed)? != signed.payload.community_did.as_str()
    {
        return Err("a policy must be signed by its community alone".into());
    }
    let p = signed.payload;
    p.policy.check_shape()?;
    if p.moderators.len() > POLICY_MODERATORS_MAX {
        return Err("policy lists too many moderators".into());
    }
    if let Some(roster) = &p.hubs {
        read_hub_roster(&p.community_did, roster)?;
    }
    Ok(p)
}

fn policy_verify_impl(json: &str) -> Result<String, String> {
    let p = read_policy(json)?;
    let hub_areas = match &p.hubs {
        Some(r) => serde_json::Value::Object(read_hub_roster(&p.community_did, r)?),
        None => serde_json::json!({}),
    };
    serde_json::to_string(&serde_json::json!({
        "community_did": p.community_did.as_str(),
        "seq": p.seq,
        "policy": p.policy,
        "moderators": p.moderators.iter().map(DidKey::as_str).collect::<Vec<_>>(),
        "hubs": p.hubs,
        "hub_areas": hub_areas,
    }))
    .map_err(|e| e.to_string())
}

/// Verify a policy artifact and say what it holds: writes `{"community_did","seq",
/// "policy","moderators"}` to `*out`. Needs no log: the community's DID is its
/// root key. A reader keeps the highest `seq` per community.
///
/// # Safety
/// `json`/`out` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_content_policy_verify(json: *const c_char, out: *mut *mut c_char) -> i32 {
    let run = || -> Result<(), String> { set_out(out, policy_verify_impl(arg_str(json)?)?) };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

// --- Moderator labels -----------------------------------------------------------

#[derive(Deserialize)]
struct LabelSignSpec {
    community_did: String,
    post_id: String,
    #[serde(default)]
    labels: Vec<String>,
    seq: u64,
    moderator: SignerSpec,
}

fn check_post_id(id: &str) -> Result<(), String> {
    if id.len() != POST_ID_HEX_LEN || !id.bytes().all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c)) {
        return Err(format!("post id {id:?} is not {POST_ID_HEX_LEN} lowercase hex"));
    }
    Ok(())
}

fn label_sign_impl(spec: &str) -> Result<String, String> {
    let s: LabelSignSpec =
        serde_json::from_str(spec).map_err(|e| format!("bad label spec: {e}"))?;
    check_post_id(&s.post_id)?;
    check_labels(&s.labels)?;
    let mut labels = s.labels;
    labels.sort();
    labels.dedup();
    let label = PostLabel {
        community_did: DidKey::from_str(&s.community_did).map_err(|e| e.to_string())?,
        post_id: s.post_id,
        labels,
        seq: s.seq,
        ts: time::now().as_second(),
    };
    let signed = Signed::build(label, &[(s.moderator.did.as_str(), &s.moderator.priv_key)])
        .map_err(|e| e.to_string())?;
    signed
        .verify(didkey_resolver)
        .map_err(|_| "the moderator's key does not match their DID".to_string())?;
    let json = serde_json::to_string(&signed).map_err(|e| e.to_string())?;
    if json.len() > POST_LABEL_BUNDLE_MAX {
        return Err(format!("this label is {} bytes, over the {POST_LABEL_BUNDLE_MAX} the wire carries", json.len()));
    }
    Ok(json)
}

/// Label a post as a moderator. `spec` is `{"community_did","post_id","labels":
/// […],"seq","moderator":{"did","priv"}}`; an empty `labels` retracts this
/// moderator's earlier labels on the post. Writes the `Signed<PostLabel>` JSON.
/// Whether the label COUNTS is decided by the reader, against the policy it holds.
///
/// # Safety
/// `spec`/`out` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_post_label_sign(spec: *const c_char, out: *mut *mut c_char) -> i32 {
    let run = || -> Result<(), String> { set_out(out, label_sign_impl(arg_str(spec)?)?) };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

/// A label checked against the policy it is read under.
struct ReadLabel {
    moderator: String,
    label: PostLabel,
}

fn read_label(json: &str, policy: &CommunityPolicy) -> Result<ReadLabel, String> {
    if json.len() > POST_LABEL_BUNDLE_MAX {
        return Err("label is over the wire bound".into());
    }
    let signed: Signed<PostLabel> =
        serde_json::from_str(json).map_err(|e| format!("bad label: {e}"))?;
    signed.verify(didkey_resolver).map_err(|e| format!("label signature invalid: {e}"))?;
    if signed.signatures.len() != 1 {
        return Err("a label is signed by one moderator".into());
    }
    let moderator = signer_of(&signed)?.to_string();
    if signed.payload.community_did != policy.community_did {
        return Err("label is for a different community than the policy".into());
    }
    if !policy.moderators.iter().any(|m| m.as_str() == moderator) {
        return Err(format!("{moderator} is not a moderator under this policy"));
    }
    check_post_id(&signed.payload.post_id)?;
    check_labels(&signed.payload.labels)?;
    Ok(ReadLabel { moderator, label: signed.payload })
}

#[derive(Deserialize)]
struct LabelVerifySpec {
    label: String,
    policy: String,
}

fn label_verify_impl(spec: &str) -> Result<String, String> {
    let s: LabelVerifySpec =
        serde_json::from_str(spec).map_err(|e| format!("bad label verify spec: {e}"))?;
    let policy = read_policy(&s.policy)?;
    let r = read_label(&s.label, &policy)?;
    serde_json::to_string(&serde_json::json!({
        "moderator_did": r.moderator,
        "community_did": r.label.community_did.as_str(),
        "post_id": r.label.post_id,
        "labels": r.label.labels,
        "seq": r.label.seq,
        "ts": r.label.ts,
    }))
    .map_err(|e| e.to_string())
}

/// Verify a moderator label against a policy artifact. `spec` is `{"label":
/// "<Signed<PostLabel> JSON>","policy":"<Signed<CommunityPolicy> JSON>"}`; writes
/// `{"moderator_did","community_did","post_id","labels","seq","ts"}`. Refused
/// unless the signer is a moderator the policy lists.
///
/// # Safety
/// `spec`/`out` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_post_label_verify(spec: *const c_char, out: *mut *mut c_char) -> i32 {
    let run = || -> Result<(), String> { set_out(out, label_verify_impl(arg_str(spec)?)?) };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

// --- The verdict ------------------------------------------------------------------

#[derive(Deserialize)]
struct VerdictSpec {
    /// The `Signed<CommunityPolicy>` JSON the reader follows.
    policy: String,
    /// The post's content id; moderator labels for any other post are ignored.
    post_id: String,
    /// The labels the author put in the post's signed canonical form.
    #[serde(default)]
    author_labels: Vec<String>,
    /// Every moderator label the reader holds for this post, as received. Ones
    /// that do not verify under `policy` are skipped and counted, never trusted.
    #[serde(default)]
    labels: Vec<String>,
    /// The reader's own view of the author.
    author_tier: u8,
    author_operator_bound: bool,
    /// This post's 1-based position among the author's posts in this community
    /// today (UTC), as this reader received them.
    author_post_index_today: u32,
}

fn action_name(a: LabelAction) -> &'static str {
    match a {
        LabelAction::Allow => "show",
        LabelAction::Warn => "warn",
        LabelAction::Hide => "hide",
    }
}

fn verdict_impl(spec: &str) -> Result<String, String> {
    let s: VerdictSpec = serde_json::from_str(spec).map_err(|e| format!("bad verdict spec: {e}"))?;
    let policy = read_policy(&s.policy)?;
    let rules = &policy.policy;
    let mut action = LabelAction::Allow;
    let mut reasons: Vec<serde_json::Value> = Vec::new();

    // The requirements: failing any one hides the post.
    if rules.operator_bound_required && !s.author_operator_bound {
        action = LabelAction::Hide;
        reasons.push(serde_json::json!({"code": "operator_unbound"}));
    }
    if s.author_tier < rules.min_tier {
        action = LabelAction::Hide;
        reasons.push(serde_json::json!({
            "code": "below_min_tier", "min_tier": rules.min_tier, "tier": s.author_tier,
        }));
    }
    if let Some(cap) = rules.daily_post_cap {
        if s.author_post_index_today > cap {
            action = LabelAction::Hide;
            reasons.push(serde_json::json!({
                "code": "over_daily_cap", "cap": cap, "index": s.author_post_index_today,
            }));
        }
    }

    // Moderator labels: per moderator, only the highest seq for THIS post counts.
    let mut latest: std::collections::BTreeMap<String, PostLabel> = std::collections::BTreeMap::new();
    let mut refused = 0usize;
    for json in &s.labels {
        match read_label(json, &policy) {
            Ok(r) if r.label.post_id == s.post_id => {
                let newer = latest.get(&r.moderator).is_none_or(|prev| r.label.seq > prev.seq);
                if newer {
                    latest.insert(r.moderator, r.label);
                }
            }
            Ok(_) => {}
            Err(_) => refused += 1,
        }
    }

    // Every label that applies, and who applied it. An author's own label counts
    // exactly like a moderator's: the policy says what a label does, not who may
    // say it.
    let mut applied: Vec<(String, String)> = Vec::new();
    for l in &s.author_labels {
        if check_label(l).is_ok() {
            applied.push((l.clone(), "author".into()));
        }
    }
    for (m, lab) in &latest {
        for l in &lab.labels {
            applied.push((l.clone(), m.clone()));
        }
    }
    applied.sort();
    applied.dedup();
    let mut tags: BTreeSet<String> = BTreeSet::new();
    for (label, by) in &applied {
        tags.insert(label.clone());
        let a = rules.labels.get(label).copied().unwrap_or(LabelAction::Allow);
        if a == LabelAction::Allow {
            continue;
        }
        if a > action {
            action = a;
        }
        reasons.push(serde_json::json!({
            "code": "label", "label": label, "action": action_name(a), "by": by,
        }));
    }

    serde_json::to_string(&serde_json::json!({
        "community_did": policy.community_did.as_str(),
        "seq": policy.seq,
        "action": action_name(action),
        "reasons": reasons,
        "tags": tags,
        "labels_refused": refused,
    }))
    .map_err(|e| e.to_string())
}

/// Decide how a reader shows one post made in a community it follows. `spec` is
/// `{"policy","post_id","author_labels":[…],"labels":["<Signed<PostLabel>>"…],
/// "author_tier","author_operator_bound","author_post_index_today"}`. Writes
/// `{"community_did","seq","action":"show"|"warn"|"hide","reasons":[…],"tags":[…],
/// "labels_refused"}`.
///
/// A failed requirement hides. Each label applied by the author or by a listed
/// moderator does what the policy says, a label the policy does not name is shown
/// as a tag, and the strictest action wins. Pure: the same inputs give the same
/// verdict on every node, which is what lets the cohort check it.
///
/// # Safety
/// `spec`/`out` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_content_policy_verdict(spec: *const c_char, out: *mut *mut c_char) -> i32 {
    let run = || -> Result<(), String> { set_out(out, verdict_impl(arg_str(spec)?)?) };
    match run() {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // A generated identity we can both name (did) and sign with (priv_key).
    struct Ident {
        did: String,
        priv_key: PrivKey,
    }

    fn ident() -> Ident {
        let (sk, pk) = keys::generate(Alg::Ed25519).unwrap();
        Ident {
            did: DidKey::from_pubkey(&pk).unwrap().into_string(),
            priv_key: sk,
        }
    }

    fn signer_json(i: &Ident) -> serde_json::Value {
        serde_json::json!({ "did": i.did, "priv": serde_json::to_value(&i.priv_key).unwrap() })
    }

    // Every named office survives name -> parse; a variant added to one mapping
    // and not the other reads back as Other and loses its authority.
    #[test]
    fn office_names_roundtrip() {
        for o in [
            Office::Convener,
            Office::Inductor,
            Office::EnvoyAuthorizer,
            Office::CharterKeeper,
            Office::RendezvousOperator,
            Office::Moderator,
            Office::ReleaseOfficer,
            Office::Other("Archivist".into()),
        ] {
            assert_eq!(parse_office(&office_name(&o)), o);
        }
    }

    #[test]
    fn found_admit_read_verify_roundtrip() {
        let a = EthneArchive(Mutex::new(Archive::new()));
        let polity = ident();
        let (m1, m2, m3) = (ident(), ident(), ident());

        // Found with 3 members; ratified by a majority (2 of 3).
        let found = serde_json::json!({
            "polity_did": polity.did,
            "name": "Corner Cafe",
            "statement": "A neighborhood coffee shop.",
            "members": [m1.did, m2.did, m3.did],
            "ratifiers": [signer_json(&m1), signer_json(&m2)],
        });
        found_impl(&a, &found.to_string()).expect("found");

        // Admit a 4th; deciders = majority of the 3-roll, joiner co-signs.
        let m4 = ident();
        let admit = serde_json::json!({
            "polity_did": polity.did,
            "member_did": m4.did,
            "rationale": "new barista",
            "deciders": [signer_json(&m1), signer_json(&m2)],
            "joiner": signer_json(&m4),
        });
        admit_impl(&a, &admit.to_string()).expect("admit");

        // Read back: all four on the roll.
        let state_json = charter_state_impl(&a, &polity.did).expect("state");
        let state: serde_json::Value = serde_json::from_str(&state_json).unwrap();
        assert_eq!(state["chartered"], serde_json::json!(true));
        let members = state["members"].as_array().unwrap();
        assert_eq!(members.len(), 4, "roll should be 4 after one admit");
        for m in [&m1.did, &m2.did, &m3.did, &m4.did] {
            assert!(members.iter().any(|v| v == m), "missing member {m}");
        }
        assert_eq!(state["substrate"]["name"], serde_json::json!("Corner Cafe"));

        // Both verification passes hold.
        verify_impl(&a).expect("verify");

        // Persistence round-trips.
        let dumped = a.0.lock().unwrap().dump_json_to_string().unwrap();
        let reloaded = Archive::<CharterEntry>::load_json_from_str(&dumped).unwrap();
        let a2 = EthneArchive(Mutex::new(reloaded));
        verify_impl(&a2).expect("verify reloaded");
        let s2 = charter_state_impl(&a2, &polity.did).unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&s2).unwrap()["members"]
                .as_array()
                .unwrap()
                .len(),
            4
        );
    }

    #[test]
    fn founding_without_majority_fails_authority() {
        // 3 members but only ONE ratifier — below majority(3)=2, so the crypto
        // passes but the governance pass must reject it.
        let a = EthneArchive(Mutex::new(Archive::new()));
        let polity = ident();
        let (m1, m2, m3) = (ident(), ident(), ident());
        let found = serde_json::json!({
            "polity_did": polity.did,
            "name": "Under-ratified LLC",
            "statement": "Founded by too few.",
            "members": [m1.did, m2.did, m3.did],
            "ratifiers": [signer_json(&m1)],
        });
        found_impl(&a, &found.to_string()).expect("append still succeeds");
        assert!(
            verify_impl(&a).is_err(),
            "a sub-majority founding must fail the authority pass"
        );
    }

    // --- P3.1: envoy + business page ---------------------------------------

    /// A generated polity/root identity (did + both keys) for border artifacts.
    fn keypair() -> (String, PrivKey, PubKey) {
        let (sk, pk) = keys::generate(Alg::Ed25519).unwrap();
        (DidKey::from_pubkey(&pk).unwrap().into_string(), sk, pk)
    }

    /// Found a 3-member polity and authorize `founders[2]` as its envoy (by a
    /// majority of the roll). Returns (archive, polity_did, root keys, founders).
    fn founded_with_envoy() -> (EthneArchive, String, PrivKey, PubKey, Vec<Ident>) {
        let a = EthneArchive(Mutex::new(Archive::new()));
        let (polity_did, root_priv, root_pub) = keypair();
        let founders: Vec<Ident> = (0..3).map(|_| ident()).collect();
        let found = serde_json::json!({
            "polity_did": polity_did,
            "name": "Corner Cafe",
            "statement": "A neighborhood coffee shop.",
            "members": founders.iter().map(|f| f.did.clone()).collect::<Vec<_>>(),
            "ratifiers": [signer_json(&founders[0]), signer_json(&founders[1])],
        });
        found_impl(&a, &found.to_string()).unwrap();
        // Envoy = founders[2] (NOT an authorizer); authorized by a majority.
        let auth = serde_json::json!({
            "polity_did": polity_did,
            "envoy_did": founders[2].did,
            "authorizers": [signer_json(&founders[0]), signer_json(&founders[1])],
            "envoy_priv": serde_json::to_value(&founders[2].priv_key).unwrap(),
        });
        authorize_envoy_impl(&a, &auth.to_string()).expect("authorize envoy");
        (a, polity_did, root_priv, root_pub, founders)
    }

    fn delegation_json(a: &EthneArchive, polity: &str, envoy: &str, rp: &PrivKey, rpub: &PubKey) -> String {
        envoy_delegation_impl(
            a,
            &serde_json::json!({
                "polity_did": polity, "envoy_did": envoy,
                "root_priv": serde_json::to_value(rp).unwrap(),
                "root_pub": serde_json::to_value(rpub).unwrap(),
            })
            .to_string(),
        )
        .expect("delegation")
    }

    fn page_json(polity: &str, envoy_did: &str, envoy_priv: &PrivKey, name: &str) -> String {
        page_sign_impl(
            &serde_json::json!({
                "page": {"polity_did": polity, "name": name, "category": "cafe",
                         "description": "Best beans in town", "seq": 1},
                "envoy_did": envoy_did,
                "envoy_priv": serde_json::to_value(envoy_priv).unwrap(),
            })
            .to_string(),
        )
        .expect("page sign")
    }

    fn bundle_json(page: &str, deleg: &str) -> String {
        serde_json::json!({
            "page": serde_json::from_str::<serde_json::Value>(page).unwrap(),
            "delegation": serde_json::from_str::<serde_json::Value>(deleg).unwrap(),
        })
        .to_string()
    }

    #[test]
    fn envoy_page_verifies_both_ways() {
        let (a, polity, rp, rpub, founders) = founded_with_envoy();
        let envoy = &founders[2];
        // Charter still authority-clean after the envoy authorization.
        verify_impl(&a).expect("charter valid after envoy auth");
        // Community identity emits and (implicitly) self-verifies on build.
        community_identity_impl(
            &a,
            &serde_json::json!({
                "polity_did": polity, "name": "Corner Cafe",
                "root_priv": serde_json::to_value(&rp).unwrap(),
                "root_pub": serde_json::to_value(&rpub).unwrap(),
            })
            .to_string(),
        )
        .expect("community identity");

        let deleg = delegation_json(&a, &polity, &envoy.did, &rp, &rpub);
        let page = page_json(&polity, &envoy.did, &envoy.priv_key, "Corner Cafe");

        // Self-contained bundle (no log) AND full-log both accept.
        verify_bundle_impl(&bundle_json(&page, &deleg)).expect("self-contained bundle verifies");
        verify_full_impl(&a, &page).expect("full-log verifies");
    }

    #[test]
    fn page_signed_by_non_envoy_is_rejected() {
        let (a, polity, rp, rpub, founders) = founded_with_envoy();
        let envoy = &founders[2];
        // founders[0] is a MEMBER but not an envoy — a page it signs must fail.
        let rogue_page = page_json(&polity, &founders[0].did, &founders[0].priv_key, "Corner Cafe");
        assert!(
            verify_full_impl(&a, &rogue_page).is_err(),
            "full-log must reject a non-envoy signer"
        );
        // And the self-contained bundle, even paired with the REAL envoy's
        // delegation, must reject (page signer != delegated speaker).
        let deleg = delegation_json(&a, &polity, &envoy.did, &rp, &rpub);
        assert!(
            verify_bundle_impl(&bundle_json(&rogue_page, &deleg)).is_err(),
            "bundle must reject a page whose signer is not the delegated envoy"
        );
    }

    #[test]
    fn tampered_page_is_rejected() {
        let (a, polity, rp, rpub, founders) = founded_with_envoy();
        let envoy = &founders[2];
        let deleg = delegation_json(&a, &polity, &envoy.did, &rp, &rpub);
        let page = page_json(&polity, &envoy.did, &envoy.priv_key, "Corner Cafe");

        // Mutate the signed payload after the fact — the signature no longer covers it.
        let mut v: serde_json::Value = serde_json::from_str(&page).unwrap();
        v["payload"]["name"] = serde_json::json!("Impostor Cafe");
        let tampered = v.to_string();

        assert!(
            verify_bundle_impl(&bundle_json(&tampered, &deleg)).is_err(),
            "a tampered page must fail signature verification"
        );
        assert!(
            verify_full_impl(&a, &tampered).is_err(),
            "a tampered page must fail full-log verification too"
        );
    }

    // --- P3.4: business posts ----------------------------------------------

    fn post_json(polity: &str, envoy_did: &str, envoy_priv: &PrivKey, body: &str, seq: u64) -> String {
        post_sign_impl(
            &serde_json::json!({
                "post": {"polity_did": polity, "body": body, "seq": seq},
                "envoy_did": envoy_did,
                "envoy_priv": serde_json::to_value(envoy_priv).unwrap(),
            })
            .to_string(),
        )
        .expect("post sign")
    }

    fn post_bundle_json(post: &str, deleg: &str) -> String {
        serde_json::json!({
            "post": serde_json::from_str::<serde_json::Value>(post).unwrap(),
            "delegation": serde_json::from_str::<serde_json::Value>(deleg).unwrap(),
        })
        .to_string()
    }

    #[test]
    fn an_envoy_post_verifies_both_ways() {
        let (a, polity, rp, rpub, founders) = founded_with_envoy();
        let envoy = &founders[2];
        let deleg = delegation_json(&a, &polity, &envoy.did, &rp, &rpub);
        let post = post_json(&polity, &envoy.did, &envoy.priv_key, "Fresh croissants at seven.", 1);

        verify_post_bundle_impl(&post_bundle_json(&post, &deleg))
            .expect("self-contained bundle verifies with no log");
        verify_post_full_impl(&a, &post).expect("full-log verifies");
    }

    #[test]
    fn a_post_signed_by_a_member_who_is_not_the_envoy_is_rejected() {
        // The whole point of box 5: being ON the roll does not let you speak AS
        // the business. founders[0] is a member and not an envoy.
        let (a, polity, rp, rpub, founders) = founded_with_envoy();
        let envoy = &founders[2];
        let rogue = post_json(&polity, &founders[0].did, &founders[0].priv_key, "We are closing.", 1);

        assert!(
            verify_post_full_impl(&a, &rogue).is_err(),
            "full-log must reject a non-envoy signer"
        );
        let deleg = delegation_json(&a, &polity, &envoy.did, &rp, &rpub);
        assert!(
            verify_post_bundle_impl(&post_bundle_json(&rogue, &deleg)).is_err(),
            "bundle must reject a post whose signer is not the delegated envoy"
        );
    }

    #[test]
    fn a_tampered_post_body_is_rejected() {
        let (a, polity, rp, rpub, founders) = founded_with_envoy();
        let envoy = &founders[2];
        let deleg = delegation_json(&a, &polity, &envoy.did, &rp, &rpub);
        let post = post_json(&polity, &envoy.did, &envoy.priv_key, "Open until six.", 1);

        let mut v: serde_json::Value = serde_json::from_str(&post).unwrap();
        v["payload"]["body"] = serde_json::json!("Closed forever. Do not come.");
        let tampered = v.to_string();

        assert!(
            verify_post_bundle_impl(&post_bundle_json(&tampered, &deleg)).is_err(),
            "a tampered body must fail signature verification"
        );
        assert!(
            verify_post_full_impl(&a, &tampered).is_err(),
            "a tampered body must fail full-log verification too"
        );
    }

    #[test]
    fn a_delegation_for_another_polity_does_not_carry_a_post() {
        // Step 4 of the bundle check, which is the one a naive reader skips: both
        // signatures are real, and they belong to two different businesses.
        let (_a, polity, _rp, _rpub, founders) = founded_with_envoy();
        let envoy = &founders[2];
        let (b, _other_polity, other_rp, other_rpub, other_founders) = founded_with_envoy();
        let other_deleg = delegation_json(
            &b, &_other_polity, &other_founders[2].did, &other_rp, &other_rpub,
        );
        let post = post_json(&polity, &envoy.did, &envoy.priv_key, "A real post.", 1);

        let err = verify_post_bundle_impl(&post_bundle_json(&post, &other_deleg))
            .expect_err("a delegation from another polity must not carry this post");
        assert!(
            err.contains("different polity") || err.contains("not the delegated envoy"),
            "the refusal must name the mismatch, got {err}"
        );
        // NB no expired-delegation test: there is no revoke/expire route over the
        // FFI today (ethne_authorize_envoy only ever Authorizes), and tampering
        // with the delegation's window breaks its signature instead, which is a
        // different refusal. active_at() is exercised by en-uplift's own tests.
    }

    #[test]
    fn an_empty_post_body_is_refused_at_signing() {
        // A page may leave fields blank; a post with nothing in it would put the
        // envoy's authority behind nothing at all.
        let (_a, polity, _rp, _rpub, founders) = founded_with_envoy();
        let envoy = &founders[2];
        for body in ["", "   ", "\n\t "] {
            let err = post_sign_impl(
                &serde_json::json!({
                    "post": {"polity_did": polity, "body": body, "seq": 1},
                    "envoy_did": envoy.did,
                    "envoy_priv": serde_json::to_value(&envoy.priv_key).unwrap(),
                })
                .to_string(),
            )
            .expect_err("an empty body must be refused");
            assert!(err.contains("empty body"), "got {err}");
        }
    }

    #[test]
    fn the_worst_case_post_bundle_fits_the_wire_bound() {
        // THE BODY BOUND IS MEASURED, NOT GUESSED, and this is where it is
        // measured. BUSINESS_POST_BUNDLE_MAX is mirrored by
        // AT_BUSINESS_POST_BUNDLE_LEN in the C core and by the shim; widen the
        // body, or let the delegation grow, and this says so before the wire does.
        let (a, polity, rp, rpub, founders) = founded_with_envoy();
        let envoy = &founders[2];
        let deleg = delegation_json(&a, &polity, &envoy.did, &rp, &rpub);

        // A body AT the bound, in multi-byte characters: clamp() counts CHARS, so
        // the byte-worst case is the widest character we can be handed.
        let wide: String = "\u{1F9C1}".repeat(BUSINESS_POST_BODY_MAX + 64); // 4 bytes each
        let post = post_json(&polity, &envoy.did, &envoy.priv_key, &wide, u64::MAX);
        let bundle = post_bundle_json(&post, &deleg);

        verify_post_bundle_impl(&bundle).expect("a body at the bound still verifies");
        assert!(
            bundle.len() <= BUSINESS_POST_BUNDLE_MAX,
            "worst-case post bundle is {} bytes, over the {BUSINESS_POST_BUNDLE_MAX}-byte wire cap \
             — lower BUSINESS_POST_BODY_MAX, or raise the cap in ALL FOUR ABI mirrors",
            bundle.len()
        );
        // Say the measured number out loud (cargo test -- --nocapture), so the
        // headroom is a fact in the log rather than a claim in a comment.
        println!(
            "worst-case post bundle: {} bytes of {BUSINESS_POST_BUNDLE_MAX} ({} spare)",
            bundle.len(),
            BUSINESS_POST_BUNDLE_MAX - bundle.len()
        );
        // The clamp really did bite, so the bound is the body's and not the test's.
        let v: serde_json::Value = serde_json::from_str(&post).unwrap();
        assert_eq!(
            v["payload"]["body"].as_str().unwrap().chars().count(),
            BUSINESS_POST_BODY_MAX
        );
    }

    // --- P3.3: guardianship ------------------------------------------------

    /// Found a 3-member polity ratified by a majority. `founders[0..2]` are
    /// seasoned (ratifiers seed as inducted); `founders[2]` is the machine we
    /// designate. Returns (archive, polity_did, founders).
    fn founded_for_guardianship() -> (EthneArchive, String, Vec<Ident>) {
        let a = EthneArchive(Mutex::new(Archive::new()));
        let (polity_did, _, _) = keypair();
        let founders: Vec<Ident> = (0..3).map(|_| ident()).collect();
        let found = serde_json::json!({
            "polity_did": polity_did,
            "name": "Corner Cafe",
            "statement": "A neighborhood coffee shop.",
            "members": founders.iter().map(|f| f.did.clone()).collect::<Vec<_>>(),
            "ratifiers": [signer_json(&founders[0]), signer_json(&founders[1])],
        });
        found_impl(&a, &found.to_string()).unwrap();
        (a, polity_did, founders)
    }

    /// Record one observation of `member` guarded by `guardian`, as `observer`
    /// saw it. Returns the parsed `{"cid","observer_did","off_roll"}`.
    fn observe(
        a: &EthneArchive,
        polity: &str,
        observer: &Ident,
        member: &str,
        guardian: Option<&str>,
    ) -> serde_json::Value {
        let spec = serde_json::json!({
            "polity_did": polity,
            "observer": signer_json(observer),
            "readings": [{
                "member": member,
                "reputation": 0.8,
                "guardian": guardian,
                "attested_at": 1_700_000_000i64,
            }],
        });
        serde_json::from_str(&observe_impl(a, &spec.to_string()).expect("observe")).unwrap()
    }

    fn guardian_edges(a: &EthneArchive, polity: &str) -> serde_json::Value {
        serde_json::from_str(&guardian_state_impl(a, polity).expect("guardian state")).unwrap()
    }

    #[test]
    fn backed_edge_needs_an_observer_off_the_roll() {
        let (a, polity, founders) = founded_for_guardianship();
        let machine = &founders[2];
        let human = ident(); // the guardian: off the roll, as a guardian is
        let monitor = ident(); // whoever looked: also off the roll

        let ob = observe(&a, &polity, &monitor, &machine.did, Some(&human.did));
        assert_eq!(ob["off_roll"], serde_json::json!(true));

        designate_impl(
            &a,
            &serde_json::json!({
                "polity_did": polity,
                "member_did": machine.did,
                "guardian": signer_json(&human),
                "deciders": [signer_json(&founders[0]), signer_json(&founders[1])],
                "evidence_cid": ob["cid"],
                "rationale": "the espresso machine answers to the owner",
            })
            .to_string(),
        )
        .expect("designate with backed evidence");
        verify_impl(&a).expect("charter valid after a backed designation");

        let st = guardian_edges(&a, &polity);
        assert_eq!(st["derived"], serde_json::json!(1));
        let edge = &st["edges"][0];
        assert_eq!(edge["member"], serde_json::json!(machine.did));
        assert_eq!(edge["guardian"], serde_json::json!(human.did));
        assert_eq!(edge["evidence"], serde_json::json!("observed"));
        assert_eq!(edge["backed"], serde_json::json!(true), "off-roll observer grades backed");
        assert_eq!(edge["observer"], serde_json::json!(monitor.did));
        // The attendance stamp is carried through unreduced, never a verdict.
        assert_eq!(edge["attested_at"], serde_json::json!(1_700_000_000i64));
    }

    #[test]
    fn an_on_roll_observer_is_valid_but_does_not_ground_the_edge() {
        // The negative that pairs with the test above, and the reason the observer
        // key is not a free choice: a polity may not vouch for its own ground.
        let (a, polity, founders) = founded_for_guardianship();
        let machine = &founders[2];
        let human = ident();

        // founders[0] IS on the roll — the observation is real and legal, and it
        // still must not grade as backed.
        let ob = observe(&a, &polity, &founders[0], &machine.did, Some(&human.did));
        assert_eq!(ob["off_roll"], serde_json::json!(false));

        designate_impl(
            &a,
            &serde_json::json!({
                "polity_did": polity,
                "member_did": machine.did,
                "guardian": signer_json(&human),
                "deciders": [signer_json(&founders[0]), signer_json(&founders[1])],
                "evidence_cid": ob["cid"],
            })
            .to_string(),
        )
        .expect("designation is accepted");
        // The AUTHORITY pass is satisfied: the evidence shows the edge it claims.
        verify_impl(&a).expect("an on-roll observation is still valid evidence");

        let edge = &guardian_edges(&a, &polity)["edges"][0];
        assert_eq!(edge["evidence"], serde_json::json!("observed"));
        assert_eq!(edge["backed"], serde_json::json!(false), "a polity cannot ground itself");
        assert!(
            edge["reason"].as_str().unwrap().contains("own ground"),
            "the UI must be told WHY it is not backed, got {}", edge["reason"]
        );
    }

    #[test]
    fn an_unbacked_edge_must_say_why_and_is_recorded_as_such() {
        let (a, polity, founders) = founded_for_guardianship();
        let machine = &founders[2];
        let human = ident();
        let deciders = serde_json::json!([signer_json(&founders[0]), signer_json(&founders[1])]);

        // The override has to state a reason; an unexplained one is refused.
        assert!(
            designate_impl(
                &a,
                &serde_json::json!({
                    "polity_did": polity, "member_did": machine.did,
                    "guardian": signer_json(&human), "deciders": deciders,
                    "unbacked_reason": "   ",
                })
                .to_string(),
            )
            .is_err(),
            "an empty override reason must be refused"
        );
        // And an edge claimed with NO evidence at all is refused by the core (D15).
        designate_impl(
            &a,
            &serde_json::json!({
                "polity_did": polity, "member_did": machine.did,
                "guardian": signer_json(&human), "deciders": deciders,
            })
            .to_string(),
        )
        .expect("append succeeds; the authority pass is what refuses it");
        assert!(
            verify_impl(&a).is_err(),
            "a claimed edge with no evidence must fail the authority pass"
        );

        // A stated reason is accepted, and surfaces verbatim in the read model.
        let (a, polity, founders) = founded_for_guardianship();
        let machine = &founders[2];
        designate_impl(
            &a,
            &serde_json::json!({
                "polity_did": polity, "member_did": machine.did,
                "guardian": signer_json(&human),
                "deciders": [signer_json(&founders[0]), signer_json(&founders[1])],
                "unbacked_reason": "no monitor was reachable at the counter",
            })
            .to_string(),
        )
        .expect("unbacked designation");
        verify_impl(&a).expect("an unbacked edge that says why is valid");
        let edge = &guardian_edges(&a, &polity)["edges"][0];
        assert_eq!(edge["evidence"], serde_json::json!("unbacked"));
        assert_eq!(edge["backed"], serde_json::json!(false));
        assert_eq!(edge["reason"], serde_json::json!("no monitor was reachable at the counter"));
    }

    #[test]
    fn the_two_closure_rules_hold() {
        let (a, polity, founders) = founded_for_guardianship();
        let machine = &founders[2];
        let deciders = serde_json::json!([signer_json(&founders[0]), signer_json(&founders[1])]);

        // Nothing guards itself.
        designate_impl(
            &a,
            &serde_json::json!({
                "polity_did": polity, "member_did": machine.did,
                "guardian": signer_json(machine), "deciders": deciders,
                "unbacked_reason": "self-guarding attempt",
            })
            .to_string(),
        )
        .expect("append");
        let why = verify_impl(&a).unwrap_err();
        assert!(why.contains("own guardian"), "expected the self-guard refusal, got: {why}");

        // A machine cannot guard a machine: designate two members, then try to
        // point the second at the first.
        let (a, polity, founders) = founded_for_guardianship();
        let human = ident();
        for m in [&founders[1], &founders[2]] {
            designate_impl(
                &a,
                &serde_json::json!({
                    "polity_did": polity, "member_did": m.did,
                    "guardian": signer_json(&human),
                    "deciders": [signer_json(&founders[0]), signer_json(&founders[1])],
                    "unbacked_reason": "bench check",
                })
                .to_string(),
            )
            .expect("designate");
        }
        verify_impl(&a).expect("two guarded machines are fine");
        rotate_impl(
            &a,
            &serde_json::json!({
                "polity_did": polity, "member_did": founders[2].did,
                "guardian": signer_json(&founders[1]),
                "deciders": [signer_json(&founders[0]), signer_json(&founders[1])],
                "unbacked_reason": "machine-guards-machine attempt",
            })
            .to_string(),
        )
        .expect("append");
        let why = verify_impl(&a).unwrap_err();
        assert!(
            why.contains("machine cannot guard a machine"),
            "expected the machine-guards-machine refusal, got: {why}"
        );
    }

    #[test]
    fn rotate_then_release_moves_the_edge_and_then_clears_it() {
        let (a, polity, founders) = founded_for_guardianship();
        let machine = &founders[2];
        let (first, second) = (ident(), ident());
        let deciders = serde_json::json!([signer_json(&founders[0]), signer_json(&founders[1])]);

        designate_impl(
            &a,
            &serde_json::json!({
                "polity_did": polity, "member_did": machine.did,
                "guardian": signer_json(&first), "deciders": deciders,
                "unbacked_reason": "first operator, bench check",
            })
            .to_string(),
        )
        .expect("designate");

        // The operator changes; the INCOMING guardian consents.
        rotate_impl(
            &a,
            &serde_json::json!({
                "polity_did": polity, "member_did": machine.did,
                "guardian": signer_json(&second), "deciders": deciders,
                "unbacked_reason": "shift handover",
            })
            .to_string(),
        )
        .expect("rotate");
        verify_impl(&a).expect("valid after rotation");
        assert_eq!(
            guardian_edges(&a, &polity)["edges"][0]["guardian"],
            serde_json::json!(second.did)
        );

        // A release carrying evidence is refused at this seam, before anything is
        // signed: it claims the edge is GONE.
        assert!(
            release_impl(
                &a,
                &serde_json::json!({
                    "polity_did": polity, "member_did": machine.did,
                    "guardian": signer_json(&second), "unbacked_reason": "gone",
                })
                .to_string(),
            )
            .is_err(),
            "a release must carry no evidence"
        );
        // And it is one route or the other, never both.
        assert!(
            release_impl(
                &a,
                &serde_json::json!({
                    "polity_did": polity, "member_did": machine.did,
                    "guardian": signer_json(&second), "deciders": deciders,
                })
                .to_string(),
            )
            .is_err(),
            "a release is the guardian's act or the roll's, not both"
        );

        // The guardian steps away on their own signature.
        release_impl(
            &a,
            &serde_json::json!({
                "polity_did": polity, "member_did": machine.did,
                "guardian": signer_json(&second),
                "rationale": "stepping back from the counter",
            })
            .to_string(),
        )
        .expect("release");
        verify_impl(&a).expect("valid after release");

        let st = guardian_edges(&a, &polity);
        let edge = &st["edges"][0];
        assert_eq!(edge["guardian"], serde_json::Value::Null);
        assert_eq!(edge["guarded"], serde_json::json!(false));
        assert_eq!(edge["backed"], serde_json::json!(false));
        assert_eq!(edge["evidence"], serde_json::json!("none"));
        // Still DERIVED — released, not un-designated. A machine answering to
        // nobody is an honest state, and the read model names it.
        assert_eq!(st["derived"], serde_json::json!(1));
        assert_eq!(st["unguarded"], serde_json::json!([machine.did]));
    }

    #[test]
    fn a_guardian_change_co_signs_with_no_key_changing_hands() {
        let (a, polity, founders) = founded_for_guardianship();
        let machine = &founders[2];
        let human = ident();
        let monitor = ident();
        let ob = observe(&a, &polity, &monitor, &machine.did, Some(&human.did));

        // Phase one: the authoring node builds the record. DIDs ONLY.
        let p: serde_json::Value = serde_json::from_str(
            &pending_impl(
                &a,
                &serde_json::json!({
                    "record": "guardian",
                    "op": "designate",
                    "polity_did": polity,
                    "member_did": machine.did,
                    "guardian_did": human.did,
                    "deciders": [founders[0].did, founders[1].did],
                    "evidence_cid": ob["cid"],
                    "rationale": "the owner takes it on",
                })
                .to_string(),
            )
            .expect("pending"),
        )
        .unwrap();
        assert_eq!(p["record"], serde_json::json!("guardian"));
        // The wire ask names the polity — without it AT refuses to send it at all.
        assert_eq!(p["polity_did"], serde_json::json!(polity));
        // The guardian's consent is required BEYOND the majority, and the caller
        // is told so before anyone is asked to sign.
        let required: Vec<&str> =
            p["signers_required"].as_array().unwrap().iter().map(|v| v.as_str().unwrap()).collect();
        assert_eq!(required, vec![founders[0].did.as_str(), founders[1].did.as_str(), human.did.as_str()]);
        // Ethne's own wording, naming the consequence rather than the fields.
        let desc = p["description"].as_str().unwrap();
        assert!(desc.contains(&machine.did) && desc.contains(&human.did), "description: {desc}");

        // Phase two: each signer signs in their OWN process, with only the bytes.
        let bytes = p["bytes"].as_str().unwrap();
        let sigs: Vec<serde_json::Value> = [&founders[0], &founders[1], &human]
            .iter()
            .map(|i| {
                let sig = sign_detached_impl(
                    &serde_json::json!({
                        "priv": serde_json::to_value(&i.priv_key).unwrap(),
                        "bytes": bytes,
                    })
                    .to_string(),
                )
                .expect("sign");
                serde_json::json!({ "did": i.did, "sig": sig })
            })
            .collect();

        // Phase three: assemble over the VERBATIM payload and append.
        assemble_impl(
            &a,
            &serde_json::json!({
                "record": "guardian",
                "payload": p["payload"],
                "signatures": sigs,
            })
            .to_string(),
        )
        .expect("assemble");
        verify_impl(&a).expect("the assembled guardian change is authorized");
        let edge = &guardian_edges(&a, &polity)["edges"][0];
        assert_eq!(edge["guardian"], serde_json::json!(human.did));
        assert_eq!(edge["backed"], serde_json::json!(true));
    }

    #[test]
    fn a_wrong_signature_fails_at_assembly_not_later() {
        let (a, polity, founders) = founded_for_guardianship();
        let machine = &founders[2];
        let human = ident();
        let p: serde_json::Value = serde_json::from_str(
            &pending_impl(
                &a,
                &serde_json::json!({
                    "record": "guardian", "op": "designate",
                    "polity_did": polity, "member_did": machine.did,
                    "guardian_did": human.did,
                    "deciders": [founders[0].did, founders[1].did],
                    "unbacked_reason": "bench check",
                })
                .to_string(),
            )
            .expect("pending"),
        )
        .unwrap();
        // An impostor signs the right bytes under the wrong key, claiming the
        // guardian's DID. did:key embeds the public key, so no registry is needed
        // to catch it — and it is caught HERE, not as an unauthorized record later.
        let impostor = ident();
        let sig = sign_detached_impl(
            &serde_json::json!({
                "priv": serde_json::to_value(&impostor.priv_key).unwrap(),
                "bytes": p["bytes"],
            })
            .to_string(),
        )
        .unwrap();
        assert!(
            assemble_impl(
                &a,
                &serde_json::json!({
                    "record": "guardian",
                    "payload": p["payload"],
                    "signatures": [{ "did": human.did, "sig": sig }],
                })
                .to_string(),
            )
            .is_err(),
            "a signature under the wrong key must fail at assembly"
        );
    }

    #[test]
    fn a_release_exchange_resolves_the_outgoing_guardian_from_the_log() {
        let (a, polity, founders) = founded_for_guardianship();
        let machine = &founders[2];
        let human = ident();
        designate_impl(
            &a,
            &serde_json::json!({
                "polity_did": polity, "member_did": machine.did,
                "guardian": signer_json(&human),
                "deciders": [signer_json(&founders[0]), signer_json(&founders[1])],
                "unbacked_reason": "bench check",
            })
            .to_string(),
        )
        .expect("designate");

        // No deciders: the guardian's own act. The caller does not have to say who
        // that is — asserting it wrongly would only be found out after signatures
        // had been collected.
        let p: serde_json::Value = serde_json::from_str(
            &pending_impl(
                &a,
                &serde_json::json!({
                    "record": "guardian", "op": "release",
                    "polity_did": polity, "member_did": machine.did,
                })
                .to_string(),
            )
            .expect("pending release"),
        )
        .unwrap();
        assert_eq!(p["signers_required"], serde_json::json!([human.did]));

        // A member who was never designated has no edge to release.
        assert!(
            pending_impl(
                &a,
                &serde_json::json!({
                    "record": "guardian", "op": "release",
                    "polity_did": polity, "member_did": founders[0].did,
                })
                .to_string(),
            )
            .is_err(),
            "a release exchange for an undesignated member must be refused"
        );
    }

    #[test]
    fn machine_majority_is_reported_so_offices_can_be_held_to_a_human() {
        let (a, polity, founders) = founded_for_guardianship();
        let human = ident();
        let deciders = serde_json::json!([signer_json(&founders[0]), signer_json(&founders[1])]);
        // One machine of three is not a majority.
        designate_impl(
            &a,
            &serde_json::json!({
                "polity_did": polity, "member_did": founders[2].did,
                "guardian": signer_json(&human), "deciders": deciders,
                "unbacked_reason": "bench check",
            })
            .to_string(),
        )
        .expect("designate");
        assert_eq!(
            guardian_edges(&a, &polity)["machine_majority"],
            serde_json::json!(false)
        );
        // Two of three is (majority(3) = 2), and the read model says so.
        designate_impl(
            &a,
            &serde_json::json!({
                "polity_did": polity, "member_did": founders[1].did,
                "guardian": signer_json(&human), "deciders": deciders,
                "unbacked_reason": "bench check",
            })
            .to_string(),
        )
        .expect("designate");
        verify_impl(&a).expect("valid");
        assert_eq!(
            guardian_edges(&a, &polity)["machine_majority"],
            serde_json::json!(true)
        );
    }

    #[test]
    fn a_membership_exchange_still_works_with_no_record_field() {
        // P3.2-era callers send no `record`; the discriminator defaults so the
        // membership path they were written against is unchanged.
        let (a, polity, founders) = founded_for_guardianship();
        let joiner = ident();
        let p: serde_json::Value = serde_json::from_str(
            &pending_impl(
                &a,
                &serde_json::json!({
                    "op": "admit", "polity_did": polity, "member_did": joiner.did,
                    "deciders": [founders[0].did, founders[1].did],
                })
                .to_string(),
            )
            .expect("pending"),
        )
        .unwrap();
        assert_eq!(p["record"], serde_json::json!("membership"));
        let bytes = p["bytes"].as_str().unwrap();
        let sigs: Vec<serde_json::Value> = [&founders[0], &founders[1], &joiner]
            .iter()
            .map(|i| {
                let sig = sign_detached_impl(
                    &serde_json::json!({
                        "priv": serde_json::to_value(&i.priv_key).unwrap(), "bytes": bytes,
                    })
                    .to_string(),
                )
                .unwrap();
                serde_json::json!({ "did": i.did, "sig": sig })
            })
            .collect();
        assemble_impl(
            &a,
            &serde_json::json!({ "payload": p["payload"], "signatures": sigs }).to_string(),
        )
        .expect("assemble with no record field");
        verify_impl(&a).expect("valid");
    }

    /// Build the worst realistic co-signing exchange: a guardian designation
    /// carrying a real observation, decided by a majority of a Dunbar-bounded
    /// staff roll, with a long rationale. Returns its exported bytes, hex.
    fn worst_realistic_exchange(deciders_n: usize, readings_n: usize) -> String {
        let a = EthneArchive(Mutex::new(Archive::new()));
        let (polity, _, _) = keypair();
        let n = deciders_n + 2;
        let members: Vec<Ident> = (0..n).map(|_| ident()).collect();
        found_impl(
            &a,
            &serde_json::json!({
                "polity_did": polity, "name": "Corner Cafe",
                "statement": "A neighborhood coffee shop.",
                "members": members.iter().map(|m| m.did.clone()).collect::<Vec<_>>(),
                "ratifiers": members.iter().map(signer_json).collect::<Vec<_>>(),
            })
            .to_string(),
        )
        .unwrap();
        let machine = &members[n - 1];
        let human = ident();
        let monitor = ident();
        let readings: Vec<serde_json::Value> = (0..readings_n)
            .map(|i| {
                let m = if i == 0 { machine.did.clone() } else { ident().did };
                serde_json::json!({
                    "member": m, "reputation": 0.83, "guardian": human.did,
                    "attested_at": 1_700_000_000i64
                })
            })
            .collect();
        let ob: serde_json::Value = serde_json::from_str(
            &observe_impl(
                &a,
                &serde_json::json!({
                    "polity_did": polity, "observer": signer_json(&monitor),
                    "readings": readings,
                })
                .to_string(),
            )
            .unwrap(),
        )
        .unwrap();
        let p: serde_json::Value = serde_json::from_str(
            &pending_impl(
                &a,
                &serde_json::json!({
                    "record": "guardian", "op": "designate",
                    "polity_did": polity, "member_did": machine.did,
                    "guardian_did": human.did,
                    "deciders": members[..deciders_n].iter().map(|m| m.did.clone())
                        .collect::<Vec<_>>(),
                    "evidence_cid": ob["cid"],
                    "rationale": "x".repeat(256),
                })
                .to_string(),
            )
            .expect("the realistic case must fit the wire"),
        )
        .unwrap();
        p["bytes"].as_str().unwrap().to_string()
    }

    #[test]
    fn the_wire_bound_holds_for_a_realistic_exchange() {
        // Thirty staff, a majority deciding, a long rationale, a real
        // observation: the shape the live cohort will actually produce.
        let bytes = worst_realistic_exchange(16, 5);
        assert!(
            bytes.len() <= COSIGN_BYTES_HEX_MAX,
            "a realistic exchange is {} hex, over the {COSIGN_BYTES_HEX_MAX} the wire carries \
             — raise the bound in app_events.h, msg_types.h and the shim TOGETHER, or the \
             C layer will truncate bytes that exist to be reproduced exactly",
            bytes.len()
        );
    }

    #[test]
    fn an_oversized_exchange_is_refused_at_authoring_not_truncated_on_the_wire() {
        // The failure this bound exists to prevent: the evidence is what grows,
        // and a payload that arrives truncated verifies against nothing at all.
        let a = EthneArchive(Mutex::new(Archive::new()));
        let (polity, _, _) = keypair();
        let members: Vec<Ident> = (0..3).map(|_| ident()).collect();
        found_impl(
            &a,
            &serde_json::json!({
                "polity_did": polity, "name": "Corner Cafe",
                "statement": "A neighborhood coffee shop.",
                "members": members.iter().map(|m| m.did.clone()).collect::<Vec<_>>(),
                "ratifiers": members.iter().map(signer_json).collect::<Vec<_>>(),
            })
            .to_string(),
        )
        .unwrap();
        let machine = &members[2];
        let human = ident();
        let monitor = ident();
        // A whole peer-table sweep, not an observation scoped to this member.
        let readings: Vec<serde_json::Value> = (0..40)
            .map(|i| {
                let m = if i == 0 { machine.did.clone() } else { ident().did };
                serde_json::json!({
                    "member": m, "reputation": 0.83, "guardian": human.did,
                    "attested_at": 1_700_000_000i64
                })
            })
            .collect();
        let ob: serde_json::Value = serde_json::from_str(
            &observe_impl(
                &a,
                &serde_json::json!({
                    "polity_did": polity, "observer": signer_json(&monitor),
                    "readings": readings,
                })
                .to_string(),
            )
            .unwrap(),
        )
        .unwrap();
        let why = pending_impl(
            &a,
            &serde_json::json!({
                "record": "guardian", "op": "designate",
                "polity_did": polity, "member_did": machine.did,
                "guardian_did": human.did,
                "deciders": [members[0].did, members[1].did],
                "evidence_cid": ob["cid"],
            })
            .to_string(),
        )
        .unwrap_err();
        assert!(why.contains("over the"), "{why}");
        assert!(why.contains("scoped to this member"), "the error must say what to do: {why}");
    }

    #[test]
    fn a_signer_reads_the_act_out_of_the_bytes_not_out_of_the_request() {
        let (a, polity, founders) = founded_for_guardianship();
        let machine = &founders[2];
        let human = ident();
        let p: serde_json::Value = serde_json::from_str(
            &pending_impl(
                &a,
                &serde_json::json!({
                    "record": "guardian", "op": "designate",
                    "polity_did": polity, "member_did": machine.did,
                    "guardian_did": human.did,
                    "deciders": [founders[0].did, founders[1].did],
                    "unbacked_reason": "no monitor was reachable at the counter",
                    "rationale": "the owner takes it on",
                })
                .to_string(),
            )
            .unwrap(),
        )
        .unwrap();

        // The signer holds ONLY the bytes, and gets the same act and the same
        // CID back out of them — nothing is taken on the asking node's word.
        let d: serde_json::Value = serde_json::from_str(
            &describe_impl(
                &serde_json::json!({ "record": "guardian", "bytes": p["bytes"] }).to_string(),
            )
            .expect("describe"),
        )
        .unwrap();
        assert_eq!(d["cid"], p["cid"], "the CID must be recomputed, not trusted");
        assert_eq!(d["description"], p["description"]);
        assert_eq!(d["op"], serde_json::json!("designate"));
        assert_eq!(d["member_did"], serde_json::json!(machine.did));
        assert_eq!(d["guardian_did"], serde_json::json!(human.did));
        // What backs the edge is part of what a signer is being asked to accept.
        assert_eq!(d["evidence"]["kind"], serde_json::json!("unbacked"));
        assert_eq!(
            d["evidence"]["reason"],
            serde_json::json!("no monitor was reachable at the counter")
        );

        // Different bytes describe a different act, and carry a different CID —
        // so a friendly wording cannot be attached to a hostile payload.
        let other: serde_json::Value = serde_json::from_str(
            &pending_impl(
                &a,
                &serde_json::json!({
                    "op": "expel", "polity_did": polity, "member_did": founders[0].did,
                    "deciders": [founders[1].did, founders[2].did],
                    "rationale": "for cause",
                })
                .to_string(),
            )
            .unwrap(),
        )
        .unwrap();
        let d2: serde_json::Value = serde_json::from_str(
            &describe_impl(
                &serde_json::json!({ "record": "membership", "bytes": other["bytes"] })
                    .to_string(),
            )
            .unwrap(),
        )
        .unwrap();
        assert_ne!(d2["cid"], d["cid"]);
        assert!(d2["description"].as_str().unwrap().contains("EXPEL"));

        // And bytes of the wrong class are refused rather than mis-read.
        assert!(
            describe_impl(
                &serde_json::json!({ "record": "guardian", "bytes": other["bytes"] }).to_string(),
            )
            .is_err(),
            "membership bytes must not describe as a guardian change"
        );
    }

    // --- P3.3 S9: the member-roll border artifact --------------------------
    //
    // The self-contained verifier is what KC can do: it establishes the
    // PUBLISHER. The full verifier is what only a node holding the log can do:
    // it audits the CLAIM. Several tests below turn on the two disagreeing,
    // which is the point of shipping both.

    fn roll_member(did: &str) -> kc_identity::RollMember {
        let d = DidKey::from_str(did).unwrap();
        let pk = d.to_pubkey().unwrap();
        kc_identity::RollMember { member_did: d, member_pubkey: pk }
    }

    /// Hand-build a roll and sign it with whoever we like — the shape a stranger
    /// can put on the wire, and the reason the verifier restates KC's rules
    /// rather than trusting the minter.
    fn roll_signed_by(
        polity: &str,
        members: Vec<kc_identity::RollMember>,
        signer_did: &str,
        signer_priv: &PrivKey,
    ) -> String {
        let now = time::now();
        let payload = MemberRoll {
            community_did: DidKey::from_str(polity).unwrap(),
            members,
            as_of: now,
            published_at: now,
        };
        let signed = Signed::build(payload, &[(signer_did, signer_priv)]).unwrap();
        serde_json::to_string(&signed).unwrap()
    }

    fn minted_roll(a: &EthneArchive, polity: &str, rp: &PrivKey, rpub: &PubKey) -> String {
        member_roll_sign_impl(
            a,
            &serde_json::json!({
                "polity_did": polity,
                "root_priv": serde_json::to_value(rp).unwrap(),
                "root_pub": serde_json::to_value(rpub).unwrap(),
            })
            .to_string(),
        )
        .expect("mint the roll")
    }

    #[test]
    fn a_published_roll_verifies_both_ways() {
        let (a, polity, rp, rpub, founders) = founded_with_envoy();
        let roll = minted_roll(&a, &polity, &rp, &rpub);

        member_roll_verify_impl(&roll).expect("self-contained roll verifies");
        member_roll_verify_full_impl(&a, &roll).expect("and it matches the log");

        let parsed: Signed<MemberRoll> = serde_json::from_str(&roll).unwrap();
        assert_eq!(parsed.payload.members.len(), founders.len());
        assert_eq!(parsed.payload.community_did.as_str(), polity);
    }

    #[test]
    fn the_polity_is_not_named_on_its_own_roll() {
        let (a, polity, rp, rpub, _f) = founded_with_envoy();
        let roll = minted_roll(&a, &polity, &rp, &rpub);
        let parsed: Signed<MemberRoll> = serde_json::from_str(&roll).unwrap();
        // Its root key is already an insider; a second entry would be a repeated
        // ring position. A true reading, not a gap.
        assert!(
            !parsed.payload.members.iter().any(|m| m.member_did.as_str() == polity),
            "the polity must not appear on its own roll"
        );
    }

    #[test]
    fn a_tampered_roll_is_rejected() {
        let (a, polity, rp, rpub, _f) = founded_with_envoy();
        let roll = minted_roll(&a, &polity, &rp, &rpub);
        let mut v: serde_json::Value = serde_json::from_str(&roll).unwrap();
        // Drop a member after signing.
        v["payload"]["members"].as_array_mut().unwrap().pop();
        let tampered = v.to_string();

        assert!(member_roll_verify_impl(&tampered).is_err(), "tampered roll must not verify");
        assert!(member_roll_verify_full_impl(&a, &tampered).is_err());
    }

    #[test]
    fn a_roll_signed_by_a_member_rather_than_the_root_is_rejected() {
        let (a, polity, _rp, _rpub, founders) = founded_with_envoy();
        // Perfectly good signature; simply not the community's.
        let roll = roll_signed_by(
            &polity,
            founders.iter().map(|f| roll_member(&f.did)).collect(),
            &founders[0].did,
            &founders[0].priv_key,
        );
        let e = member_roll_verify_impl(&roll).expect_err("a member cannot publish the roll");
        assert!(e.contains("not signed by the community"), "{e}");
    }

    #[test]
    fn a_roll_naming_a_member_twice_is_rejected() {
        let (a, polity, rp, _rpub, founders) = founded_with_envoy();
        // NOT checked at mint — en_uplift passes the read model straight through
        // — so this rule exists only here, on the receiving side.
        let roll = roll_signed_by(
            &polity,
            vec![roll_member(&founders[0].did), roll_member(&founders[0].did)],
            &polity,
            &rp,
        );
        let e = member_roll_verify_impl(&roll).expect_err("a duplicate is a repeated ring position");
        assert!(e.contains("twice"), "{e}");
        let _ = a;
    }

    #[test]
    fn a_roll_giving_a_member_a_key_its_did_does_not_resolve_to_is_rejected() {
        let (_a, polity, rp, _rpub, founders) = founded_with_envoy();
        let (_stray_did, _stray_priv, stray_pub) = keypair();
        let mut m = roll_member(&founders[0].did);
        // A real member named against a foreign key: an outsider in the ring
        // under that member's name, and the ring is what bounds a reveal.
        m.member_pubkey = stray_pub;
        let roll = roll_signed_by(&polity, vec![m], &polity, &rp);
        let e = member_roll_verify_impl(&roll).expect_err("foreign key must be refused");
        assert!(e.contains("does not resolve to"), "{e}");
    }

    #[test]
    fn a_roll_naming_the_community_itself_is_rejected() {
        let (_a, polity, rp, _rpub, founders) = founded_with_envoy();
        let roll = roll_signed_by(
            &polity,
            vec![roll_member(&founders[0].did), roll_member(&polity)],
            &polity,
            &rp,
        );
        let e = member_roll_verify_impl(&roll).expect_err("the community is not its own member");
        assert!(e.contains("may not name the community itself"), "{e}");
    }

    #[test]
    fn an_empty_roll_is_not_a_roll() {
        let (_a, polity, rp, _rpub, _f) = founded_with_envoy();
        let roll = roll_signed_by(&polity, vec![], &polity, &rp);
        assert!(member_roll_verify_impl(&roll).is_err());
    }

    #[test]
    fn the_full_verifier_rejects_a_roll_the_log_does_not_agree_with() {
        let (a, polity, rp, _rpub, founders) = founded_with_envoy();
        // Root-signed, well-formed, and a lie: it names a stranger who was never
        // admitted. THE SELF-CONTAINED CHECK PASSES — a roll is the polity
        // speaking about itself, and KC could not catch this. The node holding
        // the log can.
        let stranger = ident();
        let roll = roll_signed_by(
            &polity,
            founders
                .iter()
                .map(|f| roll_member(&f.did))
                .chain(std::iter::once(roll_member(&stranger.did)))
                .collect(),
            &polity,
            &rp,
        );

        member_roll_verify_impl(&roll).expect("the publisher is exactly who it claims to be");
        let e = member_roll_verify_full_impl(&a, &roll)
            .expect_err("the log does not agree with the claim");
        assert!(e.contains("does not match the log"), "{e}");
    }

    // --- Phase 4: content policy (D37) ----------------------------------------

    /// Five founders, ALL ratifying, so all five carry weight: a majority is 3 and
    /// more than a majority is 4.
    fn five_seasoned() -> (EthneArchive, String, PrivKey, Vec<Ident>) {
        let a = EthneArchive(Mutex::new(Archive::new()));
        let (polity_did, root_priv, _root_pub) = keypair();
        let f: Vec<Ident> = (0..5).map(|_| ident()).collect();
        let found = serde_json::json!({
            "polity_did": polity_did,
            "name": "Riverside Commons",
            "statement": "Neighbours who garden.",
            "members": f.iter().map(|m| m.did.clone()).collect::<Vec<_>>(),
            "ratifiers": f.iter().map(signer_json).collect::<Vec<_>>(),
        });
        found_impl(&a, &found.to_string()).unwrap();
        (a, polity_did, root_priv, f)
    }

    fn strict_policy() -> serde_json::Value {
        serde_json::json!({
            "operator_bound_required": true, "min_tier": 2, "daily_post_cap": 3,
            "labels": {"nsfw": "Hide", "spoiler": "Warn", "promo": "Allow"},
        })
    }

    fn amend(a: &EthneArchive, polity: &str, policy: serde_json::Value, by: &[&Ident]) {
        amend_policy_impl(a, &serde_json::json!({
            "polity_did": polity, "policy": policy,
            "deciders": by.iter().map(|i| signer_json(i)).collect::<Vec<_>>(),
        }).to_string()).expect("append");
    }

    fn confer_moderator(a: &EthneArchive, polity: &str, holder: &Ident, by: &[&Ident]) {
        office_impl(a, &serde_json::json!({
            "polity_did": polity, "office": "Moderator", "holder_did": holder.did,
            "holder_priv": serde_json::to_value(&holder.priv_key).unwrap(),
            "deciders": by.iter().map(|i| signer_json(i)).collect::<Vec<_>>(),
        }).to_string(), OfficeKind::Confer).expect("confer");
    }

    fn policy_now(a: &EthneArchive, polity: &str, root: &PrivKey) -> String {
        policy_sign_impl(a, &serde_json::json!({
            "polity_did": polity, "root_priv": serde_json::to_value(root).unwrap(),
        }).to_string()).expect("policy sign")
    }

    fn label(polity: &str, post: &str, labels: &[&str], seq: u64, m: &Ident) -> String {
        label_sign_impl(&serde_json::json!({
            "community_did": polity, "post_id": post, "labels": labels, "seq": seq,
            "moderator": signer_json(m),
        }).to_string()).expect("label sign")
    }

    const POST: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const OTHER_POST: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    fn verdict(policy: &str, author_labels: &[&str], labels: &[String], tier: u8, bound: bool, idx: u32) -> serde_json::Value {
        let out = verdict_impl(&serde_json::json!({
            "policy": policy, "post_id": POST, "author_labels": author_labels, "labels": labels,
            "author_tier": tier, "author_operator_bound": bound, "author_post_index_today": idx,
        }).to_string()).expect("verdict");
        serde_json::from_str(&out).unwrap()
    }

    fn codes(v: &serde_json::Value) -> Vec<String> {
        v["reasons"].as_array().unwrap().iter().map(|r| r["code"].as_str().unwrap().to_string()).collect()
    }

    #[test]
    fn a_majority_sets_a_policy_and_a_loosening_needs_more() {
        let (a, polity, _root, f) = five_seasoned();
        amend(&a, &polity, strict_policy(), &[&f[0], &f[1], &f[2]]);
        verify_impl(&a).expect("a first policy is a tightening");
        let st: serde_json::Value = serde_json::from_str(&policy_state_impl(&a, &polity).unwrap()).unwrap();
        assert_eq!(st["policy"], strict_policy());

        let mut looser = strict_policy();
        looser["min_tier"] = serde_json::json!(1);
        amend(&a, &polity, looser.clone(), &[&f[0], &f[1], &f[2]]);
        let e = verify_impl(&a).expect_err("a loosening at a bare majority");
        assert!(e.contains("more than a majority"), "{e}");
        let st: serde_json::Value = serde_json::from_str(&policy_state_impl(&a, &polity).unwrap()).unwrap();
        assert_eq!(st["policy"], strict_policy(), "the refused loosening is not in force");
    }

    #[test]
    fn a_policy_and_a_moderator_travel_through_detached_signing() {
        let (a, polity, _root, f) = five_seasoned();
        let deciders: Vec<String> = f[..3].iter().map(|i| i.did.clone()).collect();

        // The policy: the deciders sign in their own processes.
        let p: serde_json::Value = serde_json::from_str(&pending_impl(&a, &serde_json::json!({
            "record": "content_policy", "op": "amend", "polity_did": polity, "member_did": "",
            "deciders": deciders, "policy": strict_policy(),
        }).to_string()).expect("pending")).unwrap();
        let described: serde_json::Value = serde_json::from_str(&describe_impl(&serde_json::json!({
            "record": "content_policy", "bytes": p["bytes"],
        }).to_string()).unwrap()).unwrap();
        assert_eq!(described["policy"], strict_policy(), "a signer is shown what they sign");
        assert_eq!(described["cid"], p["cid"]);
        assert!(described["description"].as_str().unwrap().contains("'nsfw' hidden"));
        let sigs: Vec<serde_json::Value> = f[..3].iter().map(|i| serde_json::json!({
            "did": i.did,
            "sig": sign_detached_impl(&serde_json::json!({
                "priv": serde_json::to_value(&i.priv_key).unwrap(), "bytes": p["bytes"],
            }).to_string()).unwrap(),
        })).collect();
        assemble_impl(&a, &serde_json::json!({
            "record": "content_policy", "payload": p["payload"], "signatures": sigs,
        }).to_string()).expect("assemble policy");

        // The office: a conferral needs the holder's consent too.
        let o: serde_json::Value = serde_json::from_str(&pending_impl(&a, &serde_json::json!({
            "record": "office", "op": "confer", "office": "Moderator", "polity_did": polity,
            "member_did": f[4].did, "deciders": deciders,
        }).to_string()).expect("pending office")).unwrap();
        let required: Vec<String> = serde_json::from_value(o["signers_required"].clone()).unwrap();
        assert!(required.contains(&f[4].did), "the holder consents");
        let signers: Vec<&Ident> = vec![&f[0], &f[1], &f[2], &f[4]];
        let sigs: Vec<serde_json::Value> = signers.iter().map(|i| serde_json::json!({
            "did": i.did,
            "sig": sign_detached_impl(&serde_json::json!({
                "priv": serde_json::to_value(&i.priv_key).unwrap(), "bytes": o["bytes"],
            }).to_string()).unwrap(),
        })).collect();
        assemble_impl(&a, &serde_json::json!({
            "record": "office", "payload": o["payload"], "signatures": sigs,
        }).to_string()).expect("assemble office");

        verify_impl(&a).expect("both acts are authorized");
        let st: serde_json::Value = serde_json::from_str(&policy_state_impl(&a, &polity).unwrap()).unwrap();
        assert_eq!(st["policy"], strict_policy());
        assert_eq!(st["moderators"], serde_json::json!([f[4].did]));
    }

    #[test]
    fn the_policy_artifact_verifies_and_a_newer_one_has_a_larger_seq() {
        let (a, polity, root, f) = five_seasoned();
        amend(&a, &polity, strict_policy(), &[&f[0], &f[1], &f[2]]);
        let first = policy_now(&a, &polity, &root);
        let read: serde_json::Value = serde_json::from_str(&policy_verify_impl(&first).unwrap()).unwrap();
        assert_eq!(read["community_did"], serde_json::json!(polity));
        assert_eq!(read["policy"], strict_policy());
        assert_eq!(read["moderators"], serde_json::json!([]));

        confer_moderator(&a, &polity, &f[4], &[&f[0], &f[1], &f[2]]);
        let second = policy_now(&a, &polity, &root);
        let read2: serde_json::Value = serde_json::from_str(&policy_verify_impl(&second).unwrap()).unwrap();
        assert!(read2["seq"].as_u64() > read["seq"].as_u64(), "a moderator change alone mints a newer policy");
        assert_eq!(read2["moderators"], serde_json::json!([f[4].did]));
    }

    #[test]
    fn a_policy_under_any_other_key_or_tampered_is_refused() {
        let (a, polity, _root, f) = five_seasoned();
        amend(&a, &polity, strict_policy(), &[&f[0], &f[1], &f[2]]);
        let (_, wrong, _) = keypair();
        let e = policy_sign_impl(&a, &serde_json::json!({
            "polity_did": polity, "root_priv": serde_json::to_value(&wrong).unwrap(),
        }).to_string()).expect_err("not the polity's key");
        assert!(e.contains("not the polity's own key"), "{e}");

        let (a, polity, root, f) = five_seasoned();
        amend(&a, &polity, strict_policy(), &[&f[0], &f[1], &f[2]]);
        let good = policy_now(&a, &polity, &root);
        let tampered = good.replace("\"min_tier\":2", "\"min_tier\":0");
        assert_ne!(good, tampered);
        assert!(policy_verify_impl(&tampered).is_err(), "a reader cannot be handed a looser policy");
    }

    const HUB_UUID: &str = "0f1e2d3c-4b5a-4968-8776-655443322110";

    /// f[3] seated as a rendezvous operator and declared a hub for u4pr.
    fn seat_hub(a: &EthneArchive, polity: &str, f: &[Ident]) {
        office_impl(a, &serde_json::json!({
            "polity_did": polity, "office": "RendezvousOperator", "holder_did": f[3].did,
            "holder_priv": serde_json::to_value(&f[3].priv_key).unwrap(),
            "deciders": [signer_json(&f[0]), signer_json(&f[1]), signer_json(&f[2])],
        }).to_string(), OfficeKind::Confer).expect("confer");
        relay_impl(a, &serde_json::json!({
            "polity_did": polity, "member": signer_json(&f[3]), "at_uuid": HUB_UUID,
            "host": "hub.example.org", "port": 27790, "areas": ["u4pr"],
        }).to_string()).expect("declare");
        verify_impl(a).expect("an operator declares its hub");
    }

    fn policy_with_hubs(a: &EthneArchive, polity: &str, root: &PrivKey) -> String {
        policy_sign_impl(a, &serde_json::json!({
            "polity_did": polity, "root_priv": serde_json::to_value(root).unwrap(), "hubs": true,
        }).to_string()).expect("policy sign")
    }

    #[test]
    fn a_policy_carries_the_communitys_hub_roster_to_its_followers() {
        let (a, polity, root, f) = five_seasoned();
        seat_hub(&a, &polity, &f);
        let bundle = policy_with_hubs(&a, &polity, &root);
        let read: serde_json::Value = serde_json::from_str(&policy_verify_impl(&bundle).unwrap()).unwrap();
        let roster = read["hubs"].as_str().expect("the roster rides inside");
        let body: serde_json::Value =
            serde_json::from_str(serde_json::from_str::<serde_json::Value>(roster).unwrap()["body"]
                .as_str().unwrap()).unwrap();
        assert_eq!(body["seq"], read["seq"], "the roster's seq is the log's length too");
        let (hint, areas) = read["hub_areas"].as_object().unwrap().iter().next().unwrap();
        assert!(hint.contains(HUB_UUID) && hint.ends_with("@hub.example.org:27790"), "{hint}");
        assert_eq!(areas, &serde_json::json!(["u4pr"]));
        // Without asking for hubs the bundle is exactly the D37 one.
        let plain = policy_now(&a, &polity, &root);
        assert!(!plain.contains("hubs"));
        let read: serde_json::Value = serde_json::from_str(&policy_verify_impl(&plain).unwrap()).unwrap();
        assert!(read["hubs"].is_null() && read["hub_areas"] == serde_json::json!({}));
    }

    #[test]
    fn a_policy_carrying_a_roster_it_did_not_sign_is_refused() {
        let (a, polity, root, f) = five_seasoned();
        seat_hub(&a, &polity, &f);
        let bundle = policy_with_hubs(&a, &polity, &root);
        // Another polity's roster, re-signed into this policy under this root: the
        // roster's own signature is by the other root, so a reader refuses it.
        let (b, other, other_root, g) = five_seasoned();
        seat_hub(&b, &other, &g);
        let foreign: serde_json::Value = serde_json::from_str(&policy_verify_impl(
            &policy_with_hubs(&b, &other, &other_root)).unwrap()).unwrap();
        let mut signed: Signed<CommunityPolicy> = serde_json::from_str(&bundle).unwrap();
        signed.payload.hubs = Some(foreign["hubs"].as_str().unwrap().to_string());
        let forged = Signed::build(signed.payload, &[(polity.as_str(), &root)]).unwrap();
        let e = policy_verify_impl(&serde_json::to_string(&forged).unwrap()).expect_err("foreign roster");
        assert!(e.contains("not signed by its community"), "{e}");
        // And a hub whose areas no hub could serve is refused at declaration.
        let e = relay_impl(&a, &serde_json::json!({
            "polity_did": polity, "member": signer_json(&f[3]), "at_uuid": HUB_UUID,
            "host": "hub.example.org", "port": 27790, "areas": ["u4pa"],
        }).to_string()).expect_err("bad area");
        assert!(e.contains("geohash"), "{e}");
    }

    #[test]
    fn only_a_listed_moderator_labels() {
        let (a, polity, root, f) = five_seasoned();
        amend(&a, &polity, strict_policy(), &[&f[0], &f[1], &f[2]]);
        confer_moderator(&a, &polity, &f[4], &[&f[0], &f[1], &f[2]]);
        let policy = policy_now(&a, &polity, &root);

        let ok = label(&polity, POST, &["nsfw"], 1, &f[4]);
        let read: serde_json::Value = serde_json::from_str(&label_verify_impl(&serde_json::json!({
            "label": ok, "policy": policy,
        }).to_string()).unwrap()).unwrap();
        assert_eq!(read["moderator_did"], serde_json::json!(f[4].did));
        assert_eq!(read["labels"], serde_json::json!(["nsfw"]));

        let member = label(&polity, POST, &["nsfw"], 1, &f[0]);
        let e = label_verify_impl(&serde_json::json!({"label": member, "policy": policy}).to_string())
            .expect_err("a member without the office");
        assert!(e.contains("not a moderator"), "{e}");

        let (_, other_polity, _, g) = five_seasoned();
        let elsewhere = label(&other_polity, POST, &["nsfw"], 1, &g[0]);
        assert!(label_verify_impl(&serde_json::json!({"label": elsewhere, "policy": policy}).to_string()).is_err());

        assert!(label_sign_impl(&serde_json::json!({
            "community_did": polity, "post_id": "not-a-post-id", "labels": ["nsfw"], "seq": 1,
            "moderator": signer_json(&f[4]),
        }).to_string()).is_err());
    }

    #[test]
    fn the_verdict_reads_every_requirement() {
        let (a, polity, root, f) = five_seasoned();
        amend(&a, &polity, strict_policy(), &[&f[0], &f[1], &f[2]]);
        let policy = policy_now(&a, &polity, &root);

        let v = verdict(&policy, &[], &[], 2, true, 1);
        assert_eq!(v["action"], "show");
        assert!(codes(&v).is_empty());

        let v = verdict(&policy, &[], &[], 2, false, 1);
        assert_eq!((v["action"].as_str(), codes(&v)), (Some("hide"), vec!["operator_unbound".to_string()]));
        let v = verdict(&policy, &[], &[], 1, true, 1);
        assert_eq!((v["action"].as_str(), codes(&v)), (Some("hide"), vec!["below_min_tier".to_string()]));
        let v = verdict(&policy, &[], &[], 2, true, 3);
        assert_eq!(v["action"], "show", "the cap's last post is still in");
        let v = verdict(&policy, &[], &[], 2, true, 4);
        assert_eq!((v["action"].as_str(), codes(&v)), (Some("hide"), vec!["over_daily_cap".to_string()]));
        let v = verdict(&policy, &[], &[], 0, false, 9);
        assert_eq!(codes(&v).len(), 3, "every failed requirement is named");
    }

    #[test]
    fn the_verdict_applies_labels_by_the_strictest_action() {
        let (a, polity, root, f) = five_seasoned();
        amend(&a, &polity, strict_policy(), &[&f[0], &f[1], &f[2]]);
        confer_moderator(&a, &polity, &f[4], &[&f[0], &f[1], &f[2]]);
        let policy = policy_now(&a, &polity, &root);

        let v = verdict(&policy, &["spoiler"], &[], 2, true, 1);
        assert_eq!(v["action"], "warn", "an author's own label does what the policy says");
        let v = verdict(&policy, &["promo", "cats"], &[], 2, true, 1);
        assert_eq!(v["action"], "show");
        assert_eq!(v["tags"], serde_json::json!(["cats", "promo"]), "unnamed labels are tags");

        let hide = label(&polity, POST, &["nsfw"], 1, &f[4]);
        let v = verdict(&policy, &["spoiler"], std::slice::from_ref(&hide), 2, true, 1);
        assert_eq!(v["action"], "hide", "hide beats warn");
        let by: Vec<&str> = v["reasons"].as_array().unwrap().iter().map(|r| r["by"].as_str().unwrap()).collect();
        assert!(by.contains(&f[4].did.as_str()) && by.contains(&"author"));

        // A retraction at a higher seq wins, whatever order the two arrived in.
        let retract = label(&polity, POST, &[], 2, &f[4]);
        let v = verdict(&policy, &[], &[retract.clone(), hide.clone()], 2, true, 1);
        assert_eq!(v["action"], "show");

        // A label for another post, or by a non-moderator, does nothing.
        let other = label(&polity, OTHER_POST, &["nsfw"], 3, &f[4]);
        let forged = label(&polity, POST, &["nsfw"], 3, &f[0]);
        let v = verdict(&policy, &[], &[other, forged], 2, true, 1);
        assert_eq!(v["action"], "show");
        assert_eq!(v["labels_refused"], 1);
    }

    #[test]
    fn the_worst_case_policy_fits_the_wire_bound() {
        // Every bound at its maximum: 32 labels of 32 bytes, 16 moderators, the
        // largest cap. Built directly, since a log with 16 inducted moderators
        // measures nothing more than this does.
        let (polity_did, root, _) = keypair();
        let labels = (0..en_charter::CONTENT_LABELS_MAX)
            .map(|i| (format!("{i:0>32}"), LabelAction::Hide))
            .collect();
        let moderators = (0..POLICY_MODERATORS_MAX)
            .map(|_| DidKey::from_str(&ident().did).unwrap())
            .collect();
        let artifact = CommunityPolicy {
            community_did: DidKey::from_str(&polity_did).unwrap(),
            seq: u64::MAX,
            policy: ContentPolicy {
                operator_bound_required: true,
                min_tier: 4,
                daily_post_cap: Some(u32::MAX),
                labels,
                // D39: every standing rule, so the worst case stays the worst case.
                standing: [
                    en_charter::CommunityStanding::Probationary,
                    en_charter::CommunityStanding::Denied,
                    en_charter::CommunityStanding::Anathema,
                    en_charter::CommunityStanding::Outside,
                ]
                .into_iter()
                .map(|st| (st, LabelAction::Hide))
                .collect(),
            },
            moderators,
            hubs: None,
        };
        let signed = Signed::build(artifact, &[(polity_did.as_str(), &root)]).unwrap();
        let n = serde_json::to_string(&signed).unwrap().len();
        assert!(n <= COMMUNITY_POLICY_BUNDLE_MAX, "worst-case policy is {n} bytes");
    }

    #[test]
    fn the_worst_case_label_fits_the_wire_bound() {
        let (polity_did, _, _) = keypair();
        let m = ident();
        let labels: Vec<String> = (0..POST_LABELS_MAX).map(|i| format!("{i:0>32}")).collect();
        let l = label_sign_impl(&serde_json::json!({
            "community_did": polity_did, "post_id": POST, "labels": labels, "seq": u64::MAX,
            "moderator": signer_json(&m),
        }).to_string()).expect("the worst case signs");
        assert!(l.len() <= POST_LABEL_BUNDLE_MAX, "worst-case label is {} bytes", l.len());
    }
}
