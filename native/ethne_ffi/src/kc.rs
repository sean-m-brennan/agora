// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
//! The community at kith-covenant's border (SOCIAL_APP_PLAN Phase 5; Ethne D39, D40).
//!
//! A community's **governance node** (the one holding the polity root key, the envoy's
//! key and the Inductor's) keeps a replica of every compact it is in: a KC
//! `InMemoryArchive`, plus the ceremony parts (claims and verdicts) that are not
//! archive entries until a seal holds them. Records reach other members' replicas as
//! **deliveries** on Agora's co-sign carrier, each the canonical CBOR of one
//! [`Delivery`], at most 6144 hex characters. Measured in Ethne's
//! `recognition_handoff` example, every border record fits except the seals
//! themselves (18.7K hex for a founding by two, 40.3K for an admission of a third), so
//! a seal is never carried. Every node rebuilds it from a [`SealManifest`] of content
//! addresses and the parts it already holds, and signs the rebuilt bytes.
//!
//! Every producer here checks the roll's mandate first (D40 `compact_state`, through
//! en-uplift's builders), so an envoy is never handed bytes its roll did not decide.
//! Every ingest verifies and re-runs KC's authority pass on a copy before the replica
//! changes, so a record that does not authorize never lands. One whose prerequisites
//! have not arrived yet is held and retried after each later arrival.
//!
//! What readers see is not this archive: it is the **compact view** each community's
//! root signs from it, a small artifact carried like the community's policy (D39's
//! "the view is the polity's word").

use std::collections::BTreeMap;
use std::ffi::c_char;
use std::str::FromStr;
use std::sync::Mutex;

use en_archive::Archive;
use en_charter::{
    affirmation_state, charter_state, compact_state, office_state, rite_state, CharterEntry,
    CommunityStanding, CompactActKind, CompactState, ContentPolicy, LabelAction, PolityCharter,
};
use en_core::{keys, time, Cid, DidKey, PrivKey, PubKey, Signed, Timestamp};
use kc_archive::{
    check_authority, verify_all, Archive as KcStore, ArchiveEntry, InMemoryArchive,
    DEFAULT_PANEL_MIN, DEFAULT_QUORUM_THRESHOLD,
};
use kc_ceremony::inter::{
    AntiSpiralFeatureClaim, FeatureAcceptance, InterCommunityWitnessRecord,
    InterCredentialingOutcome, InterCredentialingRunner, NonAdmissionRecord, ParticipantContext,
};
use kc_ceremony::intra::{InternalWitnessAttestation, IntraCommunityRiteRecord, IntraCommunityRiteRunner};
use kc_conduct::{ConductKind, ConductRecord, DecisionClass};
use kc_core::canonical;
use kc_identity::{DelegationScope, SpeakerDelegation};
use kc_reputation::{lookup, RecognitionStanding};
use serde::{Deserialize, Serialize};

use crate::{arg_str, didkey_resolver, parse_cid, set_err, set_out, EthneArchive};

/// The quorum every member community's verifier uses. KC lets the verifier choose,
/// so all members must choose the same: KC's own defaults.
pub const KC_QUORUM: usize = DEFAULT_QUORUM_THRESHOLD;
/// The mediation-panel minimum handed to KC's authority pass (its default).
pub const KC_PANEL_MIN: usize = DEFAULT_PANEL_MIN;

/// The co-sign carrier's bound, in hex characters (MUST match COSIGN_BYTES_HEX_MAX).
const DELIVERY_HEX_MAX: usize = 6144;
/// The policy carrier's bound, in bytes (MUST match COMMUNITY_POLICY_BUNDLE_MAX).
pub const COMPACT_VIEW_BUNDLE_MAX: usize = 4096;
/// The most standings a view lists, and the most compacts.
pub const COMPACT_VIEW_STANDINGS_MAX: usize = 22;
pub const COMPACT_VIEW_COMPACTS_MAX: usize = 4;
/// The most deliveries a replica holds waiting for a prerequisite; the oldest goes.
const HELD_MAX: usize = 256;
/// Domain separation for a receipt, so it can never pass as a co-signature.
const RECEIPT_DOMAIN: &str = "agora-kc-receipt-v1|";

/// One record as it travels between replicas.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum Delivery {
    Entry(ArchiveEntry),
    Claim(Signed<AntiSpiralFeatureClaim>),
    Acceptance(Signed<FeatureAcceptance>),
}

impl Delivery {
    fn bytes(&self) -> Result<Vec<u8>, String> {
        canonical::to_canonical_cbor(self).map_err(|e| e.to_string())
    }
    fn cid(&self) -> Result<Cid, String> {
        Ok(Cid::of_bytes(&self.bytes()?))
    }
    fn kind(&self) -> &'static str {
        match self {
            Delivery::Entry(e) => entry_kind(e),
            Delivery::Claim(_) => "Claim",
            Delivery::Acceptance(_) => "Acceptance",
        }
    }
    fn from_hex(hex_str: &str) -> Result<Self, String> {
        let bytes = hex::decode(hex_str).map_err(|e| format!("bad delivery hex: {e}"))?;
        canonical::from_canonical_cbor(&bytes).map_err(|e| format!("not a KC delivery: {e}"))
    }
}

fn entry_kind(e: &ArchiveEntry) -> &'static str {
    match e {
        ArchiveEntry::CommunityIdentityPublished(_) => "CommunityIdentity",
        ArchiveEntry::SpeakerDelegated(_) => "SpeakerDelegation",
        ArchiveEntry::WitnessRegistryUpdated(_) => "WitnessRegistry",
        ArchiveEntry::IntraCommunityRite(_) => "IntraCommunityRite",
        ArchiveEntry::ExaminerRegistryUpdated(_) => "ExaminerRegistry",
        ArchiveEntry::SponsorshipVouched(_) => "Sponsorship",
        ArchiveEntry::InterCommunityWitness(_) => "InterCommunityWitness",
        ArchiveEntry::InterCommunityNonAdmission(_) => "InterCommunityNonAdmission",
        ArchiveEntry::ConductAttested(_) => "ConductAttested",
        _ => "Other",
    }
}

/// A governance node's replica of its compacts.
#[derive(Default, Clone)]
pub struct Replica {
    archive: InMemoryArchive,
    claims: Vec<Signed<AntiSpiralFeatureClaim>>,
    acceptances: Vec<Signed<FeatureAcceptance>>,
    held: Vec<Delivery>,
    seen: Vec<Cid>,
    /// The sealed note each landed seal arrived as (or was assembled into): the only
    /// form a seal travels in, so it is kept to hand on (see `deliveries_impl`).
    notes: Vec<(Cid, String)>,
}

#[derive(Serialize, Deserialize)]
struct ReplicaDump {
    archive: serde_json::Value,
    claims: Vec<Signed<AntiSpiralFeatureClaim>>,
    acceptances: Vec<Signed<FeatureAcceptance>>,
    held: Vec<Delivery>,
    #[serde(default)]
    notes: Vec<(String, String)>,
}

/// The opaque replica handle Dart holds.
pub struct EthneKc(Mutex<Replica>);

fn authorize(kc: &InMemoryArchive) -> Result<(), String> {
    verify_all(kc).map_err(|e| e.to_string())?;
    check_authority(kc, KC_QUORUM, KC_PANEL_MIN, Default::default(), Default::default(), Default::default())
        .map_err(|e| e.to_string())
}

/// The envoy KC holds for `community`: the latest `Envoy` delegation in the replica.
fn envoy_of(kc: &InMemoryArchive, community: &DidKey) -> Option<DidKey> {
    let mut found = None;
    for (_, e) in kc.iter() {
        if let ArchiveEntry::SpeakerDelegated(s) = e {
            let d: &SpeakerDelegation = &s.payload;
            if &d.community_did == community && d.scope == DelegationScope::Envoy && d.revoked_at.is_none() {
                found = Some(d.speaker_did.clone());
            }
        }
    }
    found
}

fn identity_in(kc: &InMemoryArchive, did: &DidKey) -> Option<Signed<kc_core::CommunityIdentity>> {
    kc.iter().find_map(|(_, e)| match e {
        ArchiveEntry::CommunityIdentityPublished(s) if &s.payload.did == did => Some(s.clone()),
        _ => None,
    })
}

fn latest_rite(kc: &InMemoryArchive, did: &DidKey) -> Option<(Cid, Signed<IntraCommunityRiteRecord>)> {
    let mut found = None;
    for (cid, e) in kc.iter() {
        if let ArchiveEntry::IntraCommunityRite(s) = e {
            if &s.payload.recitation.payload.community_did == did {
                found = Some((*cid, s.clone()));
            }
        }
    }
    found
}

fn rite_by_cid(kc: &InMemoryArchive, cid: &Cid) -> Option<Signed<IntraCommunityRiteRecord>> {
    kc.iter().find_map(|(c, e)| match e {
        ArchiveEntry::IntraCommunityRite(s) if c == cid => Some(s.clone()),
        _ => None,
    })
}

/// Communities sitting in `label`: participants of a seal already in the replica.
fn sitting(kc: &InMemoryArchive, label: &str) -> Vec<DidKey> {
    let mut out: Vec<DidKey> = Vec::new();
    for (_, e) in kc.iter() {
        if let ArchiveEntry::InterCommunityWitness(s) = e {
            if s.payload.compact_label == label {
                for p in &s.payload.participants {
                    if !out.contains(p) {
                        out.push(p.clone());
                    }
                }
            }
        }
    }
    out
}

/// Whether `signer` may sign for `community` at KC's border: its root, its envoy, or a
/// seated examiner of it.
fn speaks_for(kc: &InMemoryArchive, community: &DidKey, signer: &DidKey, at: Timestamp) -> bool {
    if signer == community || envoy_of(kc, community).as_ref() == Some(signer) {
        return true;
    }
    kc.iter().any(|(_, e)| match e {
        ArchiveEntry::ExaminerRegistryUpdated(s) => {
            &s.payload.nominating_community == community
                && s.payload.entries.iter().any(|x| &x.examiner_did == signer && x.active_at(at))
        }
        _ => false,
    })
}

impl Replica {
    fn keep_note(&mut self, cid: Cid, note: &str) {
        if !self.notes.iter().any(|(c, _)| c == &cid) {
            self.notes.push((cid, note.to_string()));
        }
    }

    fn holds(&self, cid: &Cid) -> bool {
        self.seen.contains(cid)
    }

    /// Take one delivery in. `Ok(true)` when it landed (or was already here),
    /// `Ok(false)` when it waits for a prerequisite and is held. An error is a record
    /// that will never land: a signature that does not verify.
    fn ingest(&mut self, d: Delivery) -> Result<bool, String> {
        let landed = self.try_land(&d)?;
        if landed {
            self.retry_held();
        } else if !self.held.contains(&d) {
            if self.held.len() >= HELD_MAX {
                self.held.remove(0);
            }
            self.held.push(d);
        }
        Ok(landed)
    }

    /// Try held deliveries again until a pass lands nothing more.
    fn retry_held(&mut self) {
        loop {
            let held = std::mem::take(&mut self.held);
            let mut progressed = false;
            for d in held {
                match self.try_land(&d) {
                    Ok(true) => progressed = true,
                    Ok(false) => self.held.push(d),
                    Err(_) => {} // can never land; drop it
                }
            }
            if !progressed {
                break;
            }
        }
    }

    /// Land `d` if it verifies and authorizes now. No retry, no holding.
    fn try_land(&mut self, d: &Delivery) -> Result<bool, String> {
        let cid = d.cid()?;
        if self.holds(&cid) {
            return Ok(true);
        }
        match d {
            Delivery::Entry(e) => {
                let mut trial = self.archive.clone();
                trial.append(e.clone()).map_err(|e| e.to_string())?;
                // KC resolves a signer through the archive (a delegation is checked
                // against the identity that delegates it), so an envelope that does
                // not verify YET may be waiting for its identity. Hold it; the cap on
                // the held queue bounds what a record that never comes good costs.
                if authorize(&trial).is_err() {
                    return Ok(false);
                }
                self.archive = trial;
            }
            Delivery::Claim(c) => {
                c.verify(didkey_resolver).map_err(|e| format!("claim signature: {e}"))?;
                let signer = signer_did(&c.signatures)?;
                if !speaks_for(&self.archive, &c.payload.community_did, &signer, c.payload.claimed_at) {
                    return Ok(false);
                }
                self.claims.push(c.clone());
            }
            Delivery::Acceptance(a) => {
                a.verify(didkey_resolver).map_err(|e| format!("verdict signature: {e}"))?;
                let signer = signer_did(&a.signatures)?;
                if !speaks_for(&self.archive, &a.payload.accepting_community_did, &signer, a.payload.decided_at) {
                    return Ok(false);
                }
                self.acceptances.push(a.clone());
            }
        }
        self.seen.push(cid);
        Ok(true)
    }

    fn dump(&self) -> Result<String, String> {
        let archive: serde_json::Value = serde_json::from_str(
            &self.archive.dump_json_to_string().map_err(|e| e.to_string())?,
        )
        .map_err(|e| e.to_string())?;
        serde_json::to_string(&ReplicaDump {
            archive,
            claims: self.claims.clone(),
            acceptances: self.acceptances.clone(),
            held: self.held.clone(),
            notes: self.notes.iter().map(|(c, n)| (c.to_string(), n.clone())).collect(),
        })
        .map_err(|e| e.to_string())
    }

    fn load(json: &str) -> Result<Self, String> {
        let d: ReplicaDump = serde_json::from_str(json).map_err(|e| format!("bad replica: {e}"))?;
        let archive = InMemoryArchive::load_json_from_str(&d.archive.to_string())
            .map_err(|e| e.to_string())?;
        authorize(&archive)?;
        let mut r = Replica { archive, ..Default::default() };
        // Re-derive what has been seen from the archive's entries and the parts.
        let entries: Vec<ArchiveEntry> = r.archive.iter().map(|(_, e)| e.clone()).collect();
        for e in entries {
            r.seen.push(Delivery::Entry(e).cid()?);
        }
        for c in d.claims {
            c.verify(didkey_resolver).map_err(|e| e.to_string())?;
            r.seen.push(Delivery::Claim(c.clone()).cid()?);
            r.claims.push(c);
        }
        for a in d.acceptances {
            a.verify(didkey_resolver).map_err(|e| e.to_string())?;
            r.seen.push(Delivery::Acceptance(a.clone()).cid()?);
            r.acceptances.push(a);
        }
        r.held = d.held;
        for (c, n) in d.notes {
            let c = parse_cid(&c)?;
            if r.seen.contains(&c) {
                r.notes.push((c, n));
            }
        }
        Ok(r)
    }
}

fn signer_did(sigs: &[kc_core::SignatureEntry]) -> Result<DidKey, String> {
    let first = sigs.first().ok_or("no signature")?;
    DidKey::from_str(&first.signer_did).map_err(|e| e.to_string())
}

/// What a producer hands back: the deliveries to send, each with its CID and hex.
fn deliveries_json(ds: &[Delivery]) -> Result<serde_json::Value, String> {
    let mut out = Vec::new();
    for d in ds {
        let bytes = d.bytes()?;
        let hex_str = hex::encode(&bytes);
        if hex_str.len() > DELIVERY_HEX_MAX {
            return Err(format!(
                "a {} delivery is {} hex characters, over the {DELIVERY_HEX_MAX} the carrier holds",
                d.kind(),
                hex_str.len()
            ));
        }
        out.push(serde_json::json!({
            "kind": d.kind(),
            "cid": Cid::of_bytes(&bytes).to_string(),
            "hex": hex_str,
        }));
    }
    Ok(serde_json::Value::Array(out))
}

/// Land our own records in our own replica (through the same checks as anyone's),
/// and say what to send.
fn produce(r: &mut Replica, ds: Vec<Delivery>) -> Result<String, String> {
    for d in &ds {
        if !r.ingest(d.clone())? {
            return Err(format!("our own {} does not authorize here yet", d.kind()));
        }
    }
    serde_json::to_string(&serde_json::json!({ "deliveries": deliveries_json(&ds)? }))
        .map_err(|e| e.to_string())
}

// --- the polity's side: what the charter log decided -------------------------

fn charter_of(a: &Archive<CharterEntry>) -> Result<PolityCharter, String> {
    a.iter()
        .find_map(|(_, e)| match e {
            CharterEntry::PolityChartered(s) => Some(s.payload.clone()),
            _ => None,
        })
        .ok_or_else(|| "the polity is not chartered".to_string())
}

fn mandate_now(charter: &EthneArchive, polity: &DidKey, at: Timestamp) -> CompactState {
    compact_state(&charter.0.lock().unwrap(), polity, at)
}

fn did(s: &str) -> Result<DidKey, String> {
    DidKey::from_str(s).map_err(|e| format!("bad did {s}: {e}"))
}

fn ts(n: Option<i64>) -> Result<Timestamp, String> {
    match n {
        Some(s) => Timestamp::from_second(s).map_err(|e| e.to_string()),
        None => Ok(time::now()),
    }
}

fn pub_of(priv_key: &PrivKey) -> Result<PubKey, String> {
    keys::public_of(priv_key).map_err(|e| e.to_string())
}

// --- the border: identity and envoy -----------------------------------------

#[derive(Deserialize)]
struct BorderSpec {
    polity_did: String,
    root_priv: PrivKey,
    envoy_did: String,
    #[serde(default)]
    at: Option<i64>,
}

fn border_impl(charter: &EthneArchive, kc: &EthneKc, spec: &str) -> Result<String, String> {
    let s: BorderSpec = serde_json::from_str(spec).map_err(|e| format!("bad border spec: {e}"))?;
    let at = ts(s.at)?;
    let polity = did(&s.polity_did)?;
    let log = charter.0.lock().unwrap();
    let c = charter_of(&log)?;
    let root_pub = pub_of(&s.root_priv)?;
    let identity = en_uplift::community_identity("polity".into(), &c, &s.root_priv, root_pub.clone(), at)
        .map_err(|e| e.to_string())?;
    let envoys = en_charter::envoy_state(&log, &polity, at);
    let delegation = en_uplift::envoy_delegation(&c, &envoys, &did(&s.envoy_did)?, &s.root_priv, root_pub, at)
        .map_err(|e| e.to_string())?;
    drop(log);
    let mut r = kc.0.lock().unwrap();
    let mut ds = Vec::new();
    if identity_in(&r.archive, &polity).is_none() {
        ds.push(Delivery::Entry(ArchiveEntry::CommunityIdentityPublished(identity)));
    }
    ds.push(Delivery::Entry(ArchiveEntry::SpeakerDelegated(delegation)));
    produce(&mut r, ds)
}

// --- the rite -----------------------------------------------------------------

#[derive(Deserialize)]
struct RiteDraftSpec {
    polity_did: String,
    root_priv: PrivKey,
    inductor_did: String,
    #[serde(default)]
    at: Option<i64>,
}

fn rite_draft_impl(charter: &EthneArchive, kc: &EthneKc, spec: &str) -> Result<String, String> {
    let s: RiteDraftSpec = serde_json::from_str(spec).map_err(|e| format!("bad rite spec: {e}"))?;
    let at = ts(s.at)?;
    let polity = did(&s.polity_did)?;
    let log = charter.0.lock().unwrap();
    let c = charter_of(&log)?;
    let state = charter_state(&log, &polity, at);
    let handoff = en_uplift::intra_rite(
        &c,
        &state.commitments,
        &office_state(&log, &polity, at),
        &affirmation_state(&log, &polity, at),
        &rite_state(&log, &polity, at),
        &did(&s.inductor_did)?,
        &s.root_priv,
        pub_of(&s.root_priv)?,
        at,
    )
    .map_err(|e| e.to_string())?;
    drop(log);
    let recitation_bytes = canonical::to_canonical_cbor(&handoff.recitation).map_err(|e| e.to_string())?;
    let recitation_cid = Cid::of_bytes(&recitation_bytes);
    let mut attest = Vec::new();
    for entry in &handoff.witnesses.payload.entries {
        let a = InternalWitnessAttestation {
            witness_did: entry.witness_did.clone(),
            recitation_cid,
            attested_at: at,
        };
        let bytes = canonical::to_canonical_cbor(&a).map_err(|e| e.to_string())?;
        attest.push(serde_json::json!({
            "witness_did": entry.witness_did.as_str(),
            "payload": a,
            "bytes": hex::encode(bytes),
        }));
    }
    let mut r = kc.0.lock().unwrap();
    let out = produce(
        &mut r,
        vec![
            Delivery::Entry(ArchiveEntry::SpeakerDelegated(handoff.reciter)),
            Delivery::Entry(ArchiveEntry::WitnessRegistryUpdated(handoff.witnesses)),
        ],
    )?;
    let mut v: serde_json::Value = serde_json::from_str(&out).map_err(|e| e.to_string())?;
    v["recitation"] = serde_json::to_value(&handoff.recitation).map_err(|e| e.to_string())?;
    v["recitation_bytes"] = serde_json::Value::String(hex::encode(recitation_bytes));
    v["attest"] = serde_json::Value::Array(attest);
    v["at"] = serde_json::json!(at.as_second());
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

#[derive(Deserialize)]
struct SigSpec {
    did: String,
    sig: String,
}

#[derive(Deserialize)]
struct AttestSpec {
    payload: InternalWitnessAttestation,
    sig: String,
}

#[derive(Deserialize)]
struct RiteSealSpec {
    polity_did: String,
    root_priv: PrivKey,
    recitation: kc_ceremony::Recitation,
    recitation_sig: SigSpec,
    attestations: Vec<AttestSpec>,
    at: i64,
}

fn sigs_of(v: &[SigSpec]) -> Result<Vec<(String, Vec<u8>)>, String> {
    v.iter()
        .map(|s| hex::decode(&s.sig).map(|b| (s.did.clone(), b)).map_err(|e| format!("bad sig hex: {e}")))
        .collect()
}

fn rite_seal_impl(kc: &EthneKc, spec: &str) -> Result<String, String> {
    let s: RiteSealSpec = serde_json::from_str(spec).map_err(|e| format!("bad rite seal spec: {e}"))?;
    let polity = did(&s.polity_did)?;
    let at = ts(Some(s.at))?;
    let recitation = en_charter::assemble(s.recitation, &sigs_of(&[s.recitation_sig])?)
        .map_err(|e| e.to_string())?;
    let mut attestations = Vec::new();
    for a in s.attestations {
        let did_s = a.payload.witness_did.as_str().to_string();
        attestations.push(
            en_charter::assemble(a.payload, &sigs_of(&[SigSpec { did: did_s, sig: a.sig }])?)
                .map_err(|e| e.to_string())?,
        );
    }
    let mut r = kc.0.lock().unwrap();
    let identity = identity_in(&r.archive, &polity).ok_or("publish the polity's identity first")?;
    let delegations: Vec<Signed<SpeakerDelegation>> = r
        .archive
        .iter()
        .filter_map(|(_, e)| match e {
            ArchiveEntry::SpeakerDelegated(d) if d.payload.community_did == polity => Some(d.clone()),
            _ => None,
        })
        .collect();
    let registry = r
        .archive
        .iter()
        .filter_map(|(_, e)| match e {
            ArchiveEntry::WitnessRegistryUpdated(w) if w.payload.community_did == polity => Some(w.clone()),
            _ => None,
        })
        .last()
        .ok_or("draft the rite first: no witness registry")?;
    let runner = IntraCommunityRiteRunner::new(&identity, &delegations, &registry);
    let sealed = runner
        .seal(recitation, attestations, &s.root_priv, at)
        .map_err(|e| e.to_string())?;
    produce(&mut r, vec![Delivery::Entry(ArchiveEntry::IntraCommunityRite(sealed))])
}

// --- the ceremony parts -------------------------------------------------------

#[derive(Deserialize)]
struct ClaimsSpec {
    polity_did: String,
    compact: String,
    counterparties: Vec<String>,
    envoy_priv: PrivKey,
    #[serde(default)]
    at: Option<i64>,
}

fn claims_impl(charter: &EthneArchive, kc: &EthneKc, spec: &str) -> Result<String, String> {
    let s: ClaimsSpec = serde_json::from_str(spec).map_err(|e| format!("bad claims spec: {e}"))?;
    let at = ts(s.at)?;
    let polity = did(&s.polity_did)?;
    let others = s.counterparties.iter().map(|d| did(d)).collect::<Result<Vec<_>, _>>()?;
    let state = mandate_now(charter, &polity, at);
    let mut r = kc.0.lock().unwrap();
    let (rite_cid, _) = latest_rite(&r.archive, &polity).ok_or("seal the polity's rite first")?;
    let envoy = envoy_of(&r.archive, &polity).ok_or("publish the envoy first")?;
    let drafts = en_uplift::anti_spiral_claims(&state, &s.compact, &polity, &others, rite_cid, at)
        .map_err(|e| e.to_string())?;
    let mut ds = Vec::new();
    for d in drafts {
        // Already presented for this feature in this round? Then it is the same claim.
        let signed = Signed::build(d, &[(envoy.as_str(), &s.envoy_priv)]).map_err(|e| e.to_string())?;
        ds.push(Delivery::Claim(signed));
    }
    produce(&mut r, ds)
}

#[derive(Deserialize)]
struct VerdictSpec {
    polity_did: String,
    compact: String,
    presenter: String,
    accepted: bool,
    #[serde(default)]
    rationale: Option<String>,
    envoy_priv: PrivKey,
    #[serde(default)]
    at: Option<i64>,
}

fn verdicts_impl(charter: &EthneArchive, kc: &EthneKc, spec: &str) -> Result<String, String> {
    let s: VerdictSpec = serde_json::from_str(spec).map_err(|e| format!("bad verdict spec: {e}"))?;
    let at = ts(s.at)?;
    let polity = did(&s.polity_did)?;
    let presenter = did(&s.presenter)?;
    let state = mandate_now(charter, &polity, at);
    let mut r = kc.0.lock().unwrap();
    let envoy = envoy_of(&r.archive, &polity).ok_or("publish the envoy first")?;
    // The presenter's latest claim for each feature.
    let mut latest: BTreeMap<String, Cid> = BTreeMap::new();
    for c in &r.claims {
        if c.payload.community_did == presenter {
            latest.insert(format!("{:?}", c.payload.feature), c.payload_cid);
        }
    }
    if latest.is_empty() {
        return Err(format!("no claims from {presenter} have arrived"));
    }
    let mut ds = Vec::new();
    for claim_cid in latest.values() {
        let a = en_uplift::feature_acceptance(
            &state, &s.compact, &polity, &presenter, *claim_cid, s.accepted, s.rationale.clone(), at,
        )
        .map_err(|e| e.to_string())?;
        ds.push(Delivery::Acceptance(
            Signed::build(a, &[(envoy.as_str(), &s.envoy_priv)]).map_err(|e| e.to_string())?,
        ));
    }
    produce(&mut r, ds)
}

#[derive(Deserialize)]
struct SponsorSpec {
    polity_did: String,
    compact: String,
    entrant: String,
    envoy_priv: PrivKey,
    #[serde(default)]
    at: Option<i64>,
}

fn sponsor_impl(charter: &EthneArchive, kc: &EthneKc, spec: &str) -> Result<String, String> {
    let s: SponsorSpec = serde_json::from_str(spec).map_err(|e| format!("bad sponsor spec: {e}"))?;
    let at = ts(s.at)?;
    let polity = did(&s.polity_did)?;
    let state = mandate_now(charter, &polity, at);
    let rec = en_uplift::sponsorship(&state, &s.compact, &polity, &did(&s.entrant)?, at)
        .map_err(|e| e.to_string())?;
    let mut r = kc.0.lock().unwrap();
    let envoy = envoy_of(&r.archive, &polity).ok_or("publish the envoy first")?;
    let signed = Signed::build(rec, &[(envoy.as_str(), &s.envoy_priv)]).map_err(|e| e.to_string())?;
    produce(&mut r, vec![Delivery::Entry(ArchiveEntry::SponsorshipVouched(signed))])
}

#[derive(Deserialize)]
struct SeatSpec {
    did: String,
    /// Optional: a did:key carries its own public key.
    #[serde(rename = "pub", default)]
    pub_key: Option<PubKey>,
}

#[derive(Deserialize)]
struct ExaminersSpec {
    polity_did: String,
    root_priv: PrivKey,
    seats: Vec<SeatSpec>,
    #[serde(default)]
    from: Option<i64>,
    /// Term in days (at most 182).
    days: i64,
}

fn examiners_impl(kc: &EthneKc, spec: &str) -> Result<String, String> {
    let s: ExaminersSpec = serde_json::from_str(spec).map_err(|e| format!("bad examiners spec: {e}"))?;
    let from = ts(s.from)?;
    let until = Timestamp::from_second(from.as_second() + s.days * 86_400).map_err(|e| e.to_string())?;
    let polity = did(&s.polity_did)?;
    let seats = s
        .seats
        .iter()
        .map(|x| {
            let d = did(&x.did)?;
            let pk = match &x.pub_key {
                Some(pk) => pk.clone(),
                None => d.to_pubkey().map_err(|e| e.to_string())?,
            };
            Ok((d, pk))
        })
        .collect::<Result<Vec<_>, String>>()?;
    let reg = en_uplift::examiner_registry(&polity, &seats, from, until).map_err(|e| e.to_string())?;
    let signed = Signed::build(reg, &[(polity.as_str(), &s.root_priv)]).map_err(|e| e.to_string())?;
    let mut r = kc.0.lock().unwrap();
    produce(&mut r, vec![Delivery::Entry(ArchiveEntry::ExaminerRegistryUpdated(signed))])
}

// --- the seal -----------------------------------------------------------------

/// What a seal ask carries in place of the seal: the label, the instant, and the
/// content addresses of everything it is built from. Canonical CBOR, binary CIDs.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SealManifest {
    pub label: String,
    pub participants: Vec<DidKey>,
    pub rites: Vec<Cid>,
    pub claims: Vec<Cid>,
    pub acceptances: Vec<Cid>,
    pub witnessed_at: Timestamp,
}

enum Draft {
    Sealed(InterCommunityWitnessRecord),
    NonAdmission(NonAdmissionRecord),
}

impl SealManifest {
    fn rebuild(&self, r: &Replica) -> Result<Draft, String> {
        let mut identities = Vec::new();
        let mut rites = Vec::new();
        for (p, cid) in self.participants.iter().zip(self.rites.iter()) {
            identities.push(identity_in(&r.archive, p).ok_or(format!("{p} is not published here"))?);
            rites.push(rite_by_cid(&r.archive, cid).ok_or(format!("the rite {cid} has not arrived"))?);
        }
        if rites.len() != self.participants.len() {
            return Err("one rite per participant".into());
        }
        let find_claim = |cid: &Cid| r.claims.iter().find(|c| &c.payload_cid == cid).cloned();
        let find_verdict = |cid: &Cid| r.acceptances.iter().find(|a| &a.payload_cid == cid).cloned();
        let claims = self
            .claims
            .iter()
            .map(|c| find_claim(c).ok_or(format!("the claim {c} has not arrived")))
            .collect::<Result<Vec<_>, _>>()?;
        let acceptances = self
            .acceptances
            .iter()
            .map(|c| find_verdict(c).ok_or(format!("the verdict {c} has not arrived")))
            .collect::<Result<Vec<_>, _>>()?;
        let throwaway: Vec<PrivKey> = self
            .participants
            .iter()
            .map(|_| keys::generate(en_core::Alg::Ed25519).map(|(sk, _)| sk).map_err(|e| e.to_string()))
            .collect::<Result<_, _>>()?;
        let contexts: Vec<ParticipantContext> = identities
            .iter()
            .zip(rites.iter())
            .zip(throwaway.iter())
            .map(|((identity, rite), sk)| ParticipantContext {
                community: identity,
                intra_record: rite,
                cross_boundary_signer_did: identity.payload.did.clone(),
                cross_boundary_signer_priv: sk,
            })
            .collect();
        let runner = InterCredentialingRunner::new(self.label.clone(), contexts);
        Ok(match runner.seal(claims, acceptances, vec![], self.witnessed_at).map_err(|e| e.to_string())? {
            InterCredentialingOutcome::Sealed(s) => Draft::Sealed(s.payload),
            InterCredentialingOutcome::NonAdmission(s) => Draft::NonAdmission(s.payload),
        })
    }

    fn hex(&self) -> Result<String, String> {
        let h = hex::encode(canonical::to_canonical_cbor(self).map_err(|e| e.to_string())?);
        if h.len() > DELIVERY_HEX_MAX {
            return Err(format!("the seal manifest is {} hex, over the carrier's {DELIVERY_HEX_MAX}", h.len()));
        }
        Ok(h)
    }

    fn from_hex(h: &str) -> Result<Self, String> {
        let b = hex::decode(h).map_err(|e| format!("bad manifest hex: {e}"))?;
        canonical::from_canonical_cbor(&b).map_err(|e| format!("not a seal manifest: {e}"))
    }
}

impl Draft {
    fn bytes(&self) -> Result<Vec<u8>, String> {
        match self {
            Draft::Sealed(p) => canonical::to_canonical_cbor(p),
            Draft::NonAdmission(p) => canonical::to_canonical_cbor(p),
        }
        .map_err(|e| e.to_string())
    }
    fn kind(&self) -> &'static str {
        match self {
            Draft::Sealed(_) => "sealed",
            Draft::NonAdmission(_) => "non_admission",
        }
    }
}

#[derive(Deserialize)]
struct SealDraftSpec {
    compact: String,
    /// Ordered: sitting members first, then the entrant (or the two founders).
    participants: Vec<String>,
    #[serde(default)]
    at: Option<i64>,
}

fn seal_draft_impl(kc: &EthneKc, spec: &str) -> Result<String, String> {
    let s: SealDraftSpec = serde_json::from_str(spec).map_err(|e| format!("bad seal spec: {e}"))?;
    let at = ts(s.at)?;
    let participants = s.participants.iter().map(|d| did(d)).collect::<Result<Vec<_>, _>>()?;
    let r = kc.0.lock().unwrap();
    let mut rites = Vec::new();
    let mut claims = Vec::new();
    let mut acceptances = Vec::new();
    for p in &participants {
        rites.push(latest_rite(&r.archive, p).ok_or(format!("{p} has no rite here"))?.0);
        // Each participant's latest claim per feature.
        let mut per: BTreeMap<String, Cid> = BTreeMap::new();
        for c in &r.claims {
            if &c.payload.community_did == p {
                per.insert(format!("{:?}", c.payload.feature), c.payload_cid);
            }
        }
        claims.extend(per.into_values());
    }
    for claim in &claims {
        let presenter = r
            .claims
            .iter()
            .find(|c| &c.payload_cid == claim)
            .map(|c| c.payload.community_did.clone())
            .ok_or("claim vanished")?;
        for p in &participants {
            if p == &presenter {
                continue;
            }
            if let Some(a) = r
                .acceptances
                .iter()
                .rev()
                .find(|a| &a.payload.claim_cid == claim && &a.payload.accepting_community_did == p)
            {
                acceptances.push(a.payload_cid);
            }
        }
    }
    let m = SealManifest { label: s.compact.clone(), participants: participants.clone(), rites, claims, acceptances, witnessed_at: at };
    let draft = m.rebuild(&r)?;
    let bytes = draft.bytes()?;
    let sitting_now = sitting(&r.archive, &s.compact);
    serde_json::to_string(&serde_json::json!({
        "manifest": m.hex()?,
        "kind": draft.kind(),
        "cid": Cid::of_bytes(&bytes).to_string(),
        "sitting": sitting_now.iter().map(DidKey::as_str).collect::<Vec<_>>(),
    }))
    .map_err(|e| e.to_string())
}

#[derive(Deserialize)]
struct SealSignSpec {
    manifest: String,
    polity_did: String,
    signer_did: String,
    signer_priv: PrivKey,
}

/// Rebuild the seal a manifest names from what this replica holds, check this
/// polity's mandate for it, and sign the rebuilt bytes. Returns `{cid, kind, sig}`.
fn seal_sign_impl(charter: &EthneArchive, kc: &EthneKc, spec: &str) -> Result<String, String> {
    let s: SealSignSpec = serde_json::from_str(spec).map_err(|e| format!("bad seal sign spec: {e}"))?;
    let m = SealManifest::from_hex(&s.manifest)?;
    let polity = did(&s.polity_did)?;
    let signer = did(&s.signer_did)?;
    if pub_of(&s.signer_priv)? != signer.to_pubkey().map_err(|e| e.to_string())? {
        return Err("the signer's key is not the signer's".into());
    }
    let state = mandate_now(charter, &polity, m.witnessed_at);
    let r = kc.0.lock().unwrap();
    if !speaks_for(&r.archive, &polity, &signer, m.witnessed_at) {
        return Err(format!("{signer} does not speak for {polity} at KC's border"));
    }
    let seated = sitting(&r.archive, &m.label);
    let draft = m.rebuild(&r)?;
    let others: Vec<&DidKey> = m.participants.iter().filter(|p| *p != &polity).collect();
    let covered = |kind: CompactActKind, who: &DidKey| state.covers(kind, &m.label, who);
    // A seated examiner signs on its own judgement: examining is its office, and its
    // node need not hold the polity's current charter log. The polity's consent is
    // its envoy's signature, which the mandate below governs.
    let examiner_only = signer != polity
        && envoy_of(&r.archive, &polity).as_ref() != Some(&signer)
        && matches!(draft, Draft::Sealed(_));
    match &draft {
        _ if examiner_only => {}
        Draft::Sealed(_) => {
            if seated.is_empty() || !seated.contains(&polity) {
                // A founder, or the entrant: the roll decided to join these.
                if !others.iter().any(|o| covered(CompactActKind::Join, o)) {
                    return Err(format!("no Join act in force covers this seal in '{}' (D40)", m.label));
                }
            } else {
                for o in others.iter().filter(|o| !seated.contains(o)) {
                    if !covered(CompactActKind::Admit, o) {
                        return Err(format!("no Admit act in force covers {o} in '{}' (D40)", m.label));
                    }
                }
            }
        }
        Draft::NonAdmission(rec) => {
            let refused_by_us: Vec<&DidKey> = rec
                .rejections
                .iter()
                .filter(|x| x.rejecting_community == polity)
                .map(|x| &x.presenting_community)
                .collect();
            for p in refused_by_us {
                if !covered(CompactActKind::Refuse, p) {
                    return Err(format!("no Refuse act in force covers {p} (D40)"));
                }
            }
        }
    }
    let bytes = draft.bytes()?;
    let sig = keys::sign(&s.signer_priv, &bytes).map_err(|e| e.to_string())?;
    serde_json::to_string(&serde_json::json!({
        "cid": Cid::of_bytes(&bytes).to_string(),
        "kind": draft.kind(),
        "sig": hex::encode(sig.bytes),
    }))
    .map_err(|e| e.to_string())
}

#[derive(Deserialize)]
struct SealAssembleSpec {
    manifest: String,
    signatures: Vec<SigSpec>,
}

/// Rebuild a seal from its manifest, attach the collected signatures, and land it.
/// Every member's replica does this with the same manifest and signatures, so every
/// replica holds the same seal without it ever crossing the wire.
/// What the convener sends every member once a seal stands: the manifest and the
/// signatures, as canonical CBOR (a JSON envelope would carry the manifest's hex
/// twice over and not fit the carrier).
#[derive(Serialize, Deserialize)]
struct SealedNote {
    manifest: SealManifest,
    signatures: Vec<(String, serde_bytes_compat::Bytes)>,
}

mod serde_bytes_compat {
    //! Signatures as CBOR byte strings rather than arrays of integers.
    use serde::{Deserialize, Deserializer, Serialize, Serializer};
    #[derive(Debug, Clone)]
    pub struct Bytes(pub Vec<u8>);
    impl Serialize for Bytes {
        fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
            s.serialize_bytes(&self.0)
        }
    }
    impl<'de> Deserialize<'de> for Bytes {
        fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
            struct V;
            impl<'de> serde::de::Visitor<'de> for V {
                type Value = Bytes;
                fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                    f.write_str("bytes")
                }
                fn visit_bytes<E: serde::de::Error>(self, v: &[u8]) -> Result<Bytes, E> {
                    Ok(Bytes(v.to_vec()))
                }
                fn visit_byte_buf<E: serde::de::Error>(self, v: Vec<u8>) -> Result<Bytes, E> {
                    Ok(Bytes(v))
                }
                fn visit_seq<A: serde::de::SeqAccess<'de>>(self, mut a: A) -> Result<Bytes, A::Error> {
                    let mut out = Vec::new();
                    while let Some(b) = a.next_element::<u8>()? {
                        out.push(b);
                    }
                    Ok(Bytes(out))
                }
            }
            d.deserialize_bytes(V)
        }
    }
}

/// Land a seal from its manifest and signatures, without holding a seal that does
/// not authorize yet (more signatures may still be coming). Returns its CID.
fn land_seal(r: &mut Replica, m: &SealManifest, sigs: &[(String, Vec<u8>)]) -> Result<Cid, String> {
    let draft = m.rebuild(r)?;
    let entry = match draft {
        Draft::Sealed(p) => ArchiveEntry::InterCommunityWitness(en_charter::assemble(p, sigs).map_err(|e| e.to_string())?),
        Draft::NonAdmission(p) => {
            ArchiveEntry::InterCommunityNonAdmission(en_charter::assemble(p, sigs).map_err(|e| e.to_string())?)
        }
    };
    let d = Delivery::Entry(entry);
    let cid = d.cid()?;
    if !r.try_land(&d)? {
        // Say why: the caller decides whether more signatures can mend it.
        let mut trial = r.archive.clone();
        let why = match &d {
            Delivery::Entry(e) => trial.append(e.clone()).map_err(|e| e.to_string()).and_then(|_| authorize(&trial)),
            _ => Ok(()),
        };
        return Err(format!(
            "the assembled seal does not authorize here yet: {}",
            why.err().unwrap_or_else(|| "a missing record".into())
        ));
    }
    r.retry_held();
    Ok(cid)
}

fn seal_assemble_impl(kc: &EthneKc, spec: &str) -> Result<String, String> {
    let s: SealAssembleSpec = serde_json::from_str(spec).map_err(|e| format!("bad assemble spec: {e}"))?;
    let m = SealManifest::from_hex(&s.manifest)?;
    let sigs = sigs_of(&s.signatures)?;
    let mut r = kc.0.lock().unwrap();
    let note = SealedNote {
        manifest: m.clone(),
        signatures: sigs.iter().map(|(d, b)| (d.clone(), serde_bytes_compat::Bytes(b.clone()))).collect(),
    };
    let sealed = hex::encode(canonical::to_canonical_cbor(&note).map_err(|e| e.to_string())?);
    if sealed.len() > DELIVERY_HEX_MAX {
        return Err(format!("the sealed note is {} hex, over the carrier's {DELIVERY_HEX_MAX}", sealed.len()));
    }
    let cid = land_seal(&mut r, &m, &sigs)?;
    r.keep_note(cid, &sealed);
    serde_json::to_string(&serde_json::json!({ "cid": cid.to_string(), "sealed": sealed }))
        .map_err(|e| e.to_string())
}

/// A member's node: land the seal a sealed note names, rebuilt from this replica.
fn seal_ingest_impl(kc: &EthneKc, sealed_hex: &str) -> Result<String, String> {
    let b = hex::decode(sealed_hex.trim()).map_err(|e| format!("bad sealed hex: {e}"))?;
    let note: SealedNote = canonical::from_canonical_cbor(&b).map_err(|e| format!("not a sealed note: {e}"))?;
    let sigs: Vec<(String, Vec<u8>)> = note.signatures.into_iter().map(|(d, b)| (d, b.0)).collect();
    let mut r = kc.0.lock().unwrap();
    let cid = land_seal(&mut r, &note.manifest, &sigs)?;
    r.keep_note(cid, sealed_hex.trim());
    serde_json::to_string(&serde_json::json!({ "cid": cid.to_string() })).map_err(|e| e.to_string())
}

/// Everything this replica holds, as it would travel: each record as a
/// `kc_record/deliver`, and each seal as the `kc_seal/sealed` note it came in.
/// The governance node relays these to its own seated examiners' nodes, whose
/// replicas need every member's border (not only their own community's) to
/// rebuild a seal they are asked to sign. Seals come last, in archive order, so
/// their parts arrive first; a record over the carrier's bound is left out.
fn deliveries_impl(kc: &EthneKc, _spec: &str) -> Result<String, String> {
    let r = kc.0.lock().unwrap();
    let mut out = Vec::new();
    let mut push = |record: &str, op: &str, kind: &str, cid: String, hex_str: String| {
        if hex_str.len() <= DELIVERY_HEX_MAX {
            out.push(serde_json::json!({"record": record, "op": op, "kind": kind, "cid": cid, "hex": hex_str}));
        }
    };
    let mut seals = Vec::new();
    for (_, e) in r.archive.iter() {
        let d = Delivery::Entry(e.clone());
        let cid = d.cid()?;
        if matches!(e, ArchiveEntry::InterCommunityWitness(_) | ArchiveEntry::InterCommunityNonAdmission(_)) {
            if let Some((_, n)) = r.notes.iter().find(|(c, _)| c == &cid) {
                seals.push((cid, n.clone(), entry_kind(e)));
            }
            continue;
        }
        push("kc_record", "deliver", d.kind(), cid.to_string(), hex::encode(d.bytes()?));
    }
    for d in r.claims.iter().cloned().map(Delivery::Claim).chain(r.acceptances.iter().cloned().map(Delivery::Acceptance)) {
        push("kc_record", "deliver", d.kind(), d.cid()?.to_string(), hex::encode(d.bytes()?));
    }
    for (cid, n, kind) in seals {
        push("kc_seal", "sealed", kind, cid.to_string(), n);
    }
    serde_json::to_string(&serde_json::json!({ "deliveries": out })).map_err(|e| e.to_string())
}

// --- conduct: anathema and its lifting --------------------------------------

#[derive(Deserialize)]
struct ConductDraftSpec {
    polity_did: String,
    compact: String,
    /// "anathema" or "lift".
    kind: String,
    reporters: Vec<String>,
    subject: String,
    #[serde(default)]
    designation: Option<String>,
    #[serde(default)]
    narrative: Option<String>,
    #[serde(default)]
    at: Option<i64>,
}

fn conduct_draft_impl(charter: &EthneArchive, spec: &str) -> Result<String, String> {
    let s: ConductDraftSpec = serde_json::from_str(spec).map_err(|e| format!("bad conduct spec: {e}"))?;
    let at = ts(s.at)?;
    let polity = did(&s.polity_did)?;
    let reporters = s.reporters.iter().map(|d| did(d)).collect::<Result<Vec<_>, _>>()?;
    if !reporters.contains(&polity) {
        return Err("the drafting polity is one of the reporters".into());
    }
    let subject = did(&s.subject)?;
    let state = mandate_now(charter, &polity, at);
    let rec = match s.kind.as_str() {
        "anathema" => en_uplift::anathema(
            &state, &s.compact, &reporters, &subject,
            s.narrative.unwrap_or_else(|| "the compact has found it cannot stand with them".into()), at,
        ),
        "lift" => {
            let d = s.designation.as_deref().ok_or("a lifting names the designation")?;
            en_uplift::lift(&state, &s.compact, &reporters, &subject, crate::parse_cid(d)?, at)
        }
        other => return Err(format!("unknown conduct kind '{other}'")),
    }
    .map_err(|e| e.to_string())?;
    let bytes = canonical::to_canonical_cbor(&rec).map_err(|e| e.to_string())?;
    let h = hex::encode(&bytes);
    if h.len() > DELIVERY_HEX_MAX {
        return Err("the conduct record is over the carrier".into());
    }
    serde_json::to_string(&serde_json::json!({
        "payload": rec,
        "bytes": h,
        "cid": Cid::of_bytes(&bytes).to_string(),
    }))
    .map_err(|e| e.to_string())
}

#[derive(Deserialize)]
struct ConductSignSpec {
    polity_did: String,
    compact: String,
    /// The record, or the canonical bytes a co-reporter was handed (hex).
    #[serde(default)]
    payload: Option<ConductRecord>,
    #[serde(default)]
    bytes: Option<String>,
    envoy_priv: PrivKey,
}

/// A reporter's own node: check this polity's mandate for the act and sign it.
fn conduct_sign_impl(charter: &EthneArchive, kc: &EthneKc, spec: &str) -> Result<String, String> {
    let s: ConductSignSpec = serde_json::from_str(spec).map_err(|e| format!("bad conduct sign spec: {e}"))?;
    let polity = did(&s.polity_did)?;
    let owned = match (&s.payload, &s.bytes) {
        (Some(p), _) => p.clone(),
        (None, Some(h)) => canonical::from_canonical_cbor(&hex::decode(h).map_err(|e| format!("bad bytes hex: {e}"))?)
            .map_err(|e| format!("these bytes are not a conduct record: {e}"))?,
        (None, None) => return Err("a conduct signature needs `payload` or `bytes`".into()),
    };
    let rec = &owned;
    if !matches!(rec.decision_class, DecisionClass::SecondClass) {
        return Err("Agora signs only second-class conduct (two or more reporters)".into());
    }
    if !rec.reporters.contains(&polity) {
        return Err("this polity is not a reporter of the record".into());
    }
    let kind = match rec.kind {
        ConductKind::DesignationAnathema => CompactActKind::Anathematize,
        ConductKind::DesignationLifted => CompactActKind::Lift,
        _ => return Err("Agora signs anathema and its lifting only".into()),
    };
    let state = mandate_now(charter, &polity, rec.recorded_at);
    en_uplift::mandate(&state, kind, &s.compact, &rec.subject_community).map_err(|e| e.to_string())?;
    let r = kc.0.lock().unwrap();
    let envoy = envoy_of(&r.archive, &polity).ok_or("publish the envoy first")?;
    if pub_of(&s.envoy_priv)? != envoy.to_pubkey().map_err(|e| e.to_string())? {
        return Err("that is not this polity's envoy key".into());
    }
    let bytes = canonical::to_canonical_cbor(rec).map_err(|e| e.to_string())?;
    let sig = keys::sign(&s.envoy_priv, &bytes).map_err(|e| e.to_string())?;
    serde_json::to_string(&serde_json::json!({ "did": envoy.as_str(), "sig": hex::encode(sig.bytes) }))
        .map_err(|e| e.to_string())
}

#[derive(Deserialize)]
struct ConductAssembleSpec {
    payload: ConductRecord,
    signatures: Vec<SigSpec>,
}

fn conduct_assemble_impl(kc: &EthneKc, spec: &str) -> Result<String, String> {
    let s: ConductAssembleSpec = serde_json::from_str(spec).map_err(|e| format!("bad conduct assemble spec: {e}"))?;
    let signed = en_charter::assemble(s.payload, &sigs_of(&s.signatures)?).map_err(|e| e.to_string())?;
    let mut r = kc.0.lock().unwrap();
    produce(&mut r, vec![Delivery::Entry(ArchiveEntry::ConductAttested(signed))])
}

// --- ingest, receipts, standing ----------------------------------------------

fn ingest_impl(kc: &EthneKc, hex_str: &str) -> Result<String, String> {
    let d = Delivery::from_hex(hex_str)?;
    let cid = d.cid()?;
    let kind = d.kind();
    let mut r = kc.0.lock().unwrap();
    let landed = r.ingest(d)?;
    serde_json::to_string(&serde_json::json!({
        "cid": cid.to_string(),
        "kind": kind,
        "status": if landed { "landed" } else { "held" },
        "held": r.held.len(),
    }))
    .map_err(|e| e.to_string())
}

fn receipt_message(cid: &str) -> Vec<u8> {
    format!("{RECEIPT_DOMAIN}{cid}").into_bytes()
}

#[derive(Deserialize)]
struct ReceiptSignSpec {
    cid: String,
    #[serde(rename = "priv")]
    priv_key: PrivKey,
}

fn receipt_sign_impl(spec: &str) -> Result<String, String> {
    let s: ReceiptSignSpec = serde_json::from_str(spec).map_err(|e| format!("bad receipt spec: {e}"))?;
    let sig = keys::sign(&s.priv_key, &receipt_message(&s.cid)).map_err(|e| e.to_string())?;
    Ok(hex::encode(sig.bytes))
}

#[derive(Deserialize)]
struct ReceiptVerifySpec {
    cid: String,
    did: String,
    sig: String,
}

fn receipt_verify_impl(spec: &str) -> Result<(), String> {
    let s: ReceiptVerifySpec = serde_json::from_str(spec).map_err(|e| format!("bad receipt spec: {e}"))?;
    let pk = did(&s.did)?.to_pubkey().map_err(|e| e.to_string())?;
    let sig = en_core::Signature {
        alg: en_core::Alg::Ed25519,
        bytes: hex::decode(&s.sig).map_err(|e| format!("bad sig hex: {e}"))?,
    };
    keys::verify(&pk, &receipt_message(&s.cid), &sig).map_err(|e| format!("receipt does not verify: {e}"))
}

fn standing_word(s: RecognitionStanding) -> &'static str {
    match s {
        RecognitionStanding::Unknown => "unknown",
        RecognitionStanding::Identified => "identified",
        RecognitionStanding::InCompact => "in_compact",
        RecognitionStanding::Probationary => "probationary",
        RecognitionStanding::Denied => "denied",
        RecognitionStanding::Anathema => "anathema",
    }
}

// --- the compact view ---------------------------------------------------------

/// One compact the publishing community sits in.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ViewCompact {
    pub label: String,
    /// The CID of the compact's founding seal: its identity in Agora.
    pub id: Cid,
    /// Indexes into [`CompactView::standings`] of the compact's other members.
    pub members: Vec<u16>,
}

/// Another community, and how it stands with the publisher.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ViewStanding {
    pub did: DidKey,
    /// `in_compact` (shares one of the publisher's compacts), `probationary`,
    /// `denied`, `anathema`, or `outside`.
    pub standing: String,
}

/// What a community says about its compacts, root-signed (D39's "the polity's word").
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CompactView {
    pub community_did: DidKey,
    /// The AT uuid (32 hex) of the community's governance node: where another
    /// community sends compact asks. Root-signed with the rest, so it is the
    /// community's own word about which node speaks for it.
    pub node: String,
    /// The replica's length when it was minted: a reader keeps the highest.
    pub seq: u64,
    pub as_of: Timestamp,
    pub compacts: Vec<ViewCompact>,
    pub standings: Vec<ViewStanding>,
}

fn view_of(r: &Replica, polity: &DidKey, node: &str, at: Timestamp) -> CompactView {
    // Labels the publisher sits in, each with its founding seal.
    let mut compacts: Vec<(String, Cid, Vec<DidKey>)> = Vec::new();
    for (cid, e) in r.archive.iter() {
        if let ArchiveEntry::InterCommunityWitness(s) = e {
            let label = &s.payload.compact_label;
            match compacts.iter_mut().find(|(l, _, _)| l == label) {
                Some((_, _, members)) => {
                    for p in &s.payload.participants {
                        if !members.contains(p) {
                            members.push(p.clone());
                        }
                    }
                }
                None => compacts.push((label.clone(), *cid, s.payload.participants.clone())),
            }
        }
    }
    compacts.retain(|(_, _, m)| m.contains(polity));
    compacts.truncate(COMPACT_VIEW_COMPACTS_MAX);
    // Every other community the replica knows, as it stands.
    let mut standings: Vec<ViewStanding> = Vec::new();
    for (_, e) in r.archive.iter() {
        if let ArchiveEntry::CommunityIdentityPublished(s) = e {
            let d = &s.payload.did;
            if d == polity || standings.iter().any(|x| &x.did == d) {
                continue;
            }
            let shares = compacts.iter().any(|(_, _, m)| m.contains(d));
            let word = match lookup(&r.archive, d, Some(at)).standing {
                RecognitionStanding::Anathema => "anathema",
                RecognitionStanding::Denied => "denied",
                RecognitionStanding::Probationary if shares => "probationary",
                RecognitionStanding::InCompact if shares => "in_compact",
                _ => "outside",
            };
            standings.push(ViewStanding { did: d.clone(), standing: word.into() });
        }
    }
    // The ones that matter most first, so the cap drops the least telling.
    let rank = |w: &str| match w {
        "anathema" => 0,
        "denied" => 1,
        "probationary" => 2,
        "in_compact" => 3,
        _ => 4,
    };
    standings.sort_by(|a, b| rank(&a.standing).cmp(&rank(&b.standing)).then(a.did.as_str().cmp(b.did.as_str())));
    standings.truncate(COMPACT_VIEW_STANDINGS_MAX);
    let view_compacts = compacts
        .into_iter()
        .map(|(label, id, members)| ViewCompact {
            label,
            id,
            members: members
                .iter()
                .filter_map(|m| standings.iter().position(|x| &x.did == m).map(|i| i as u16))
                .collect(),
        })
        .collect();
    CompactView {
        community_did: polity.clone(),
        node: node.to_string(),
        seq: r.archive.iter().count() as u64,
        as_of: at,
        compacts: view_compacts,
        standings,
    }
}

#[derive(Deserialize)]
struct ViewSignSpec {
    polity_did: String,
    root_priv: PrivKey,
    /// This governance node's AT uuid, 32 lowercase hex.
    node: String,
    #[serde(default)]
    at: Option<i64>,
}

fn view_sign_impl(kc: &EthneKc, spec: &str) -> Result<String, String> {
    let s: ViewSignSpec = serde_json::from_str(spec).map_err(|e| format!("bad view spec: {e}"))?;
    let polity = did(&s.polity_did)?;
    let at = ts(s.at)?;
    if s.node.len() != 32 || !s.node.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()) {
        return Err("`node` is the governance node's AT uuid, 32 lowercase hex".into());
    }
    let view = view_of(&kc.0.lock().unwrap(), &polity, &s.node, at);
    let signed = Signed::build(view, &[(polity.as_str(), &s.root_priv)]).map_err(|e| e.to_string())?;
    signed.verify(didkey_resolver).map_err(|e| format!("signed with the wrong key: {e}"))?;
    let json = serde_json::to_string(&signed).map_err(|e| e.to_string())?;
    if json.len() > COMPACT_VIEW_BUNDLE_MAX {
        return Err(format!("the compact view is {} bytes, over the {COMPACT_VIEW_BUNDLE_MAX} its carrier holds", json.len()));
    }
    Ok(json)
}

fn read_view(json: &str) -> Result<CompactView, String> {
    if json.len() > COMPACT_VIEW_BUNDLE_MAX {
        return Err("the view is over the wire bound".into());
    }
    let signed: Signed<CompactView> = serde_json::from_str(json).map_err(|e| format!("bad view: {e}"))?;
    signed.verify(didkey_resolver).map_err(|e| format!("view signature invalid: {e}"))?;
    if signed.signatures.len() != 1 || signed.signatures[0].signer_did != signed.payload.community_did.as_str() {
        return Err("a compact view must be signed by its community alone".into());
    }
    let v = signed.payload;
    if v.node.len() != 32 || !v.node.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err("the view's node is not an AT uuid".into());
    }
    if v.standings.len() > COMPACT_VIEW_STANDINGS_MAX || v.compacts.len() > COMPACT_VIEW_COMPACTS_MAX {
        return Err("the view lists more than it may".into());
    }
    for x in &v.standings {
        if !matches!(x.standing.as_str(), "in_compact" | "probationary" | "denied" | "anathema" | "outside") {
            return Err(format!("unknown standing '{}'", x.standing));
        }
    }
    for c in &v.compacts {
        if c.members.iter().any(|i| *i as usize >= v.standings.len()) {
            return Err("a compact names a member the view does not list".into());
        }
    }
    Ok(v)
}

fn view_verify_impl(json: &str) -> Result<String, String> {
    let v = read_view(json)?;
    serde_json::to_string(&serde_json::json!({
        "community_did": v.community_did.as_str(),
        "node": v.node,
        "seq": v.seq,
        "as_of": v.as_of.as_second(),
        "compacts": v.compacts.iter().map(|c| serde_json::json!({
            "label": c.label,
            "id": c.id.to_string(),
            "members": c.members.iter().map(|i| v.standings[*i as usize].did.as_str()).collect::<Vec<_>>(),
        })).collect::<Vec<_>>(),
        "standings": v.standings.iter().map(|x| (x.did.as_str().to_string(), x.standing.clone()))
            .collect::<BTreeMap<_, _>>(),
    }))
    .map_err(|e| e.to_string())
}

#[derive(Deserialize)]
struct VerdictInSpec {
    /// The publishing community's policy (the `policy` of a verified policy bundle).
    policy: ContentPolicy,
    /// The publishing community's verified view (`ethne_compact_view_verify` output).
    view: serde_json::Value,
    /// The community a post was made in.
    post_community: String,
}

/// What `policy` does to a post made in `post_community`'s name, by its standing in
/// the publisher's view (D39). A post in the publisher's own name is not judged here.
fn standing_verdict_impl(spec: &str) -> Result<String, String> {
    let s: VerdictInSpec = serde_json::from_str(spec).map_err(|e| format!("bad verdict spec: {e}"))?;
    let publisher = s.view.get("community_did").and_then(|v| v.as_str()).unwrap_or("");
    if publisher == s.post_community || s.post_community.is_empty() {
        return serde_json::to_string(&serde_json::json!({"standing": "own", "action": "Allow"}))
            .map_err(|e| e.to_string());
    }
    let word = s
        .view
        .get("standings")
        .and_then(|m| m.get(&s.post_community))
        .and_then(|w| w.as_str())
        .unwrap_or("outside")
        .to_string();
    let standing = match word.as_str() {
        "probationary" => Some(CommunityStanding::Probationary),
        "denied" => Some(CommunityStanding::Denied),
        "anathema" => Some(CommunityStanding::Anathema),
        "outside" => Some(CommunityStanding::Outside),
        _ => None, // in_compact: no rule applies
    };
    let action = standing
        .and_then(|st| s.policy.standing.get(&st).copied())
        .unwrap_or(LabelAction::Allow);
    serde_json::to_string(&serde_json::json!({ "standing": word, "action": action }))
        .map_err(|e| e.to_string())
}

// --- the C ABI ----------------------------------------------------------------

macro_rules! ffi_out {
    ($body:expr) => {{
        match (|| -> Result<String, String> { $body })() {
            Ok(s) => (0, s),
            Err(e) => {
                set_err(e);
                (-1, String::new())
            }
        }
    }};
}

unsafe fn finish(out: *mut *mut c_char, r: (i32, String)) -> i32 {
    if r.0 != 0 {
        return r.0;
    }
    match set_out(out, r.1) {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

unsafe fn kc_ref<'a>(h: *mut EthneKc) -> Result<&'a EthneKc, String> {
    h.as_ref().ok_or_else(|| "null replica handle".to_string())
}

unsafe fn charter_ref<'a>(h: *mut EthneArchive) -> Result<&'a EthneArchive, String> {
    h.as_ref().ok_or_else(|| "null archive handle".to_string())
}

/// A fresh, empty replica.
#[no_mangle]
pub extern "C" fn ethne_kc_new() -> *mut EthneKc {
    Box::into_raw(Box::new(EthneKc(Mutex::new(Replica::default()))))
}

/// # Safety
/// `h` must come from `ethne_kc_new` / `ethne_kc_load_json`, freed once.
#[no_mangle]
pub unsafe extern "C" fn ethne_kc_free(h: *mut EthneKc) {
    if !h.is_null() {
        drop(Box::from_raw(h));
    }
}

/// Load a replica dumped by `ethne_kc_dump_json`; every entry re-verifies and
/// re-authorizes, or the load fails. NULL on failure (see `ethne_last_error`).
///
/// # Safety
/// `json` must be a valid C string.
#[no_mangle]
pub unsafe extern "C" fn ethne_kc_load_json(json: *const c_char) -> *mut EthneKc {
    match arg_str(json).and_then(Replica::load) {
        Ok(r) => Box::into_raw(Box::new(EthneKc(Mutex::new(r)))),
        Err(e) => {
            set_err(e);
            std::ptr::null_mut()
        }
    }
}

/// # Safety
/// `h`/`out` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_kc_dump_json(h: *mut EthneKc, out: *mut *mut c_char) -> i32 {
    let r = ffi_out!(kc_ref(h)?.0.lock().unwrap().dump());
    finish(out, r)
}

/// 0 when the replica verifies and authorizes under Agora's fixed KC parameters.
///
/// # Safety
/// `h` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_kc_verify(h: *mut EthneKc) -> i32 {
    match kc_ref(h).and_then(|k| authorize(&k.0.lock().unwrap().archive)) {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

macro_rules! export_charter_kc {
    ($name:ident, $impl:ident) => {
        /// See the module docs. `spec` is JSON; writes JSON to `*out`.
        ///
        /// # Safety
        /// The handles, `spec` and `out` must be valid.
        #[no_mangle]
        pub unsafe extern "C" fn $name(
            charter: *mut EthneArchive,
            h: *mut EthneKc,
            spec: *const c_char,
            out: *mut *mut c_char,
        ) -> i32 {
            let r = ffi_out!($impl(charter_ref(charter)?, kc_ref(h)?, arg_str(spec)?));
            finish(out, r)
        }
    };
}

macro_rules! export_kc {
    ($name:ident, $impl:ident) => {
        /// See the module docs. `spec` is JSON; writes JSON to `*out`.
        ///
        /// # Safety
        /// The handle, `spec` and `out` must be valid.
        #[no_mangle]
        pub unsafe extern "C" fn $name(h: *mut EthneKc, spec: *const c_char, out: *mut *mut c_char) -> i32 {
            let r = ffi_out!($impl(kc_ref(h)?, arg_str(spec)?));
            finish(out, r)
        }
    };
}

macro_rules! export_pure {
    ($name:ident, $impl:ident) => {
        /// See the module docs. `spec` is JSON; writes the result to `*out`.
        ///
        /// # Safety
        /// `spec` and `out` must be valid.
        #[no_mangle]
        pub unsafe extern "C" fn $name(spec: *const c_char, out: *mut *mut c_char) -> i32 {
            let r = ffi_out!($impl(arg_str(spec)?));
            finish(out, r)
        }
    };
}

export_charter_kc!(ethne_kc_border, border_impl);
export_charter_kc!(ethne_kc_rite_draft, rite_draft_impl);
export_charter_kc!(ethne_kc_claims, claims_impl);
export_charter_kc!(ethne_kc_verdicts, verdicts_impl);
export_charter_kc!(ethne_kc_sponsor, sponsor_impl);
export_charter_kc!(ethne_kc_seal_sign, seal_sign_impl);
export_charter_kc!(ethne_kc_conduct_sign, conduct_sign_impl);
export_kc!(ethne_kc_rite_seal, rite_seal_impl);
export_kc!(ethne_kc_examiners, examiners_impl);
export_kc!(ethne_kc_seal_draft, seal_draft_impl);
export_kc!(ethne_kc_seal_assemble, seal_assemble_impl);
export_kc!(ethne_kc_seal_ingest, seal_ingest_impl);
export_kc!(ethne_kc_conduct_assemble, conduct_assemble_impl);
export_kc!(ethne_kc_ingest, ingest_impl);
export_kc!(ethne_kc_deliveries, deliveries_impl);
export_kc!(ethne_kc_view_sign, view_sign_impl);
export_pure!(ethne_kc_receipt_sign, receipt_sign_impl);
export_pure!(ethne_compact_view_verify, view_verify_impl);
export_pure!(ethne_compact_standing_verdict, standing_verdict_impl);

/// Draft a conduct record (anathema or lift) for the reporters to co-sign. Takes the
/// drafting polity's charter log, for its mandate.
///
/// # Safety
/// `charter`, `spec` and `out` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_kc_conduct_draft(
    charter: *mut EthneArchive,
    spec: *const c_char,
    out: *mut *mut c_char,
) -> i32 {
    let r = ffi_out!(conduct_draft_impl(charter_ref(charter)?, arg_str(spec)?));
    finish(out, r)
}

/// 0 when a receipt verifies. `spec` is `{"cid","did","sig"}`.
///
/// # Safety
/// `spec` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_kc_receipt_verify(spec: *const c_char) -> i32 {
    match arg_str(spec).and_then(receipt_verify_impl) {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

/// A community's standing as the replica reads it now: `{"standing"}`.
///
/// # Safety
/// `h`, `community` and `out` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ethne_kc_standing(
    h: *mut EthneKc,
    community: *const c_char,
    out: *mut *mut c_char,
) -> i32 {
    let r = ffi_out!({
        let k = kc_ref(h)?;
        let d = did(arg_str(community)?)?;
        let v = lookup(&k.0.lock().unwrap().archive, &d, None);
        serde_json::to_string(&serde_json::json!({ "standing": standing_word(v.standing) }))
            .map_err(|e| e.to_string())
    });
    finish(out, r)
}

#[cfg(test)]
mod tests {
    //! Three communities, each with its own charter log and its own replica, that
    //! talk only in the strings Agora's nodes exchange: delivery hex, manifests,
    //! signatures. Everything one community's node produces is ingested by the
    //! others', exactly as the co-sign carrier would hand it over.

    use super::*;
    use en_charter::{
        Affirmation, AffirmationKind, Commitment, CompactAct, EnvoyAuthorization, EnvoyKind,
        FoundingProposal, Movement, Office, OfficeChange, OfficeKind, RiteMovement, Substrate,
    };
    use en_core::Alg;

    const T0: i64 = 1_700_000_000;

    fn t(n: i64) -> Timestamp {
        Timestamp::from_second(T0 + n).unwrap()
    }

    fn keypair() -> (DidKey, PrivKey, PubKey) {
        let (sk, pk) = keys::generate(Alg::Ed25519).unwrap();
        (DidKey::from_pubkey(&pk).unwrap(), sk, pk)
    }

    /// A community's governance node: its charter log, its replica, and the keys
    /// it holds (root, envoy = m0, Inductor = m1). m2 is a second member, on its own
    /// device, who witnesses the rite and sits as a second examiner.
    struct Node {
        did: DidKey,
        root: PrivKey,
        members: Vec<(DidKey, PrivKey, PubKey)>,
        charter: EthneArchive,
        kc: EthneKc,
    }

    impl Node {
        fn envoy(&self) -> &(DidKey, PrivKey, PubKey) {
            &self.members[0]
        }
        fn found(name: &str) -> Node {
            let (did, root, _pk) = keypair();
            let members: Vec<_> = (0..3).map(|_| keypair()).collect();
            let roll: Vec<DidKey> = members.iter().map(|m| m.0.clone()).collect();
            let signers: Vec<(&str, &PrivKey)> = members.iter().map(|m| (m.0.as_str(), &m.1)).collect();
            let mut log = Archive::<CharterEntry>::new();
            let proposal = FoundingProposal::convener_asserted(
                did.clone(),
                Substrate { name: format!("{name}-substrate"), statement: "the ground".into(), anchor: None },
                vec![Commitment { key: "mutual-aid".into(), description: "we answer for one another".into() }],
                roll.clone(),
                vec![],
                t(0),
            );
            let charter = proposal.ratify(roll.clone(), t(0)).unwrap();
            log.append(CharterEntry::PolityChartered(Signed::build(charter, &signers).unwrap())).unwrap();
            log.append(CharterEntry::EnvoyAuthorized(Signed::build(EnvoyAuthorization {
                polity: did.clone(), kind: EnvoyKind::Authorize, envoy: members[0].0.clone(),
                envoy_pubkey: members[0].2.clone(), rationale: "r".into(), authorizers: roll.clone(),
                expires_at: None, decided_at: t(0),
            }, &signers).unwrap())).unwrap();
            log.append(CharterEntry::OfficeChanged(Signed::build(OfficeChange {
                polity: did.clone(), kind: OfficeKind::Confer, office: Office::Inductor,
                holder: members[1].0.clone(), rationale: "r".into(), deciders: roll.clone(), decided_at: t(0),
            }, &signers).unwrap())).unwrap();
            for (m, sk, _) in &members {
                let attending: Vec<DidKey> = roll.iter().filter(|d| *d != m).cloned().collect();
                let mut cited = Vec::new();
                let movements = [
                    Movement::Substrate { names: format!("{name}-substrate") },
                    Movement::Fallenness,
                    Movement::Recognition,
                    Movement::CommonVirtue { commits_to: vec!["mutual-aid".into()] },
                    Movement::NonUltimacy { names_anchor: None },
                ];
                for (i, movement) in movements.into_iter().enumerate() {
                    let rec = RiteMovement {
                        polity: did.clone(), member: m.clone(), kind: AffirmationKind::ReAffirmation,
                        movement, statement: "as received".into(), attending: attending.clone(),
                        recited_at: t(1 + i as i64),
                    };
                    let mut s: Vec<(&str, &PrivKey)> = vec![(m.as_str(), sk)];
                    s.extend(members.iter().filter(|x| &x.0 != m).map(|x| (x.0.as_str(), &x.1)));
                    cited.push(log.append(CharterEntry::RiteMovementRecorded(Signed::build(rec, &s).unwrap())).unwrap());
                }
                log.append(CharterEntry::MemberAffirmed(Signed::build(Affirmation {
                    polity: did.clone(), member: m.clone(), kind: AffirmationKind::ReAffirmation,
                    witnesses: attending, movements: cited, affirmed_at: t(10),
                }, &[(m.as_str(), sk)]).unwrap())).unwrap();
            }
            Node { did, root, members, charter: EthneArchive(Mutex::new(log)), kc: EthneKc(Mutex::new(Replica::default())) }
        }

        /// The roll decides a compact act (all three sign: enough for severe acts).
        fn decide(&self, kind: CompactActKind, others: &[&Node], at: i64) {
            self.decide_until(kind, others, at, None)
        }

        fn decide_until(&self, kind: CompactActKind, others: &[&Node], at: i64, until: Option<i64>) {
            let roll: Vec<DidKey> = self.members.iter().map(|m| m.0.clone()).collect();
            let signers: Vec<(&str, &PrivKey)> = self.members.iter().map(|m| (m.0.as_str(), &m.1)).collect();
            let act = CompactAct {
                polity: self.did.clone(), kind, compact: "river".into(),
                counterparties: others.iter().map(|n| n.did.clone()).collect(),
                probation_days: (kind == CompactActKind::Sponsor).then_some(90),
                rationale: "r".into(), deciders: roll, decided_at: t(at), expires_at: until.map(t),
            };
            self.charter.0.lock().unwrap()
                .append(CharterEntry::CompactActDecided(Signed::build(act, &signers).unwrap())).unwrap();
        }

        fn spec(&self, extra: serde_json::Value) -> String {
            let mut v = serde_json::json!({ "polity_did": self.did.as_str() });
            for (k, x) in extra.as_object().unwrap() {
                v[k] = x.clone();
            }
            v.to_string()
        }
    }

    /// Hand every delivery in `out` to every node in `to`.
    fn deliver(out: &str, to: &[&Node]) {
        let v: serde_json::Value = serde_json::from_str(out).unwrap();
        for d in v["deliveries"].as_array().unwrap() {
            for n in to {
                ingest_impl(&n.kc, d["hex"].as_str().unwrap()).unwrap();
            }
        }
    }

    fn border_and_rite(n: &Node, others: &[&Node], at: i64) {
        let out = border_impl(&n.charter, &n.kc, &n.spec(serde_json::json!({
            "root_priv": n.root, "envoy_did": n.envoy().0.as_str(), "at": T0 + at,
        }))).unwrap();
        deliver(&out, others);
        let draft = rite_draft_impl(&n.charter, &n.kc, &n.spec(serde_json::json!({
            "root_priv": n.root, "inductor_did": n.members[1].0.as_str(), "at": T0 + at,
        }))).unwrap();
        deliver(&draft, others);
        let d: serde_json::Value = serde_json::from_str(&draft).unwrap();
        // The Inductor signs the recitation; each witness, on its own device, signs
        // the attestation bytes it was handed.
        let rec_bytes = hex::decode(d["recitation_bytes"].as_str().unwrap()).unwrap();
        let rec_sig = keys::sign(&n.members[1].1, &rec_bytes).unwrap();
        let mut attestations = Vec::new();
        for a in d["attest"].as_array().unwrap() {
            let w = a["witness_did"].as_str().unwrap();
            let key = &n.members.iter().find(|m| m.0.as_str() == w).unwrap().1;
            let sig = keys::sign(key, &hex::decode(a["bytes"].as_str().unwrap()).unwrap()).unwrap();
            attestations.push(serde_json::json!({ "payload": a["payload"], "sig": hex::encode(sig.bytes) }));
        }
        let sealed = rite_seal_impl(&n.kc, &n.spec(serde_json::json!({
            "root_priv": n.root, "recitation": d["recitation"],
            "recitation_sig": { "did": n.members[1].0.as_str(), "sig": hex::encode(rec_sig.bytes) },
            "attestations": attestations, "at": d["at"],
        }))).unwrap();
        deliver(&sealed, others);
    }

    fn claims(n: &Node, counterparties: &[&Node], to: &[&Node], at: i64) {
        let out = claims_impl(&n.charter, &n.kc, &n.spec(serde_json::json!({
            "compact": "river",
            "counterparties": counterparties.iter().map(|c| c.did.as_str()).collect::<Vec<_>>(),
            "envoy_priv": n.envoy().1, "at": T0 + at,
        }))).unwrap();
        deliver(&out, to);
    }

    fn verdicts(n: &Node, presenter: &Node, to: &[&Node], at: i64) {
        let out = verdicts_impl(&n.charter, &n.kc, &n.spec(serde_json::json!({
            "compact": "river", "presenter": presenter.did.as_str(), "accepted": true,
            "envoy_priv": n.envoy().1, "at": T0 + at,
        }))).unwrap();
        deliver(&out, to);
    }

    fn sign_seal(n: &Node, manifest: &str, signer: &(DidKey, PrivKey, PubKey)) -> serde_json::Value {
        let out = seal_sign_impl(&n.charter, &n.kc, &n.spec(serde_json::json!({
            "manifest": manifest, "signer_did": signer.0.as_str(), "signer_priv": signer.1,
        }))).unwrap();
        let v: serde_json::Value = serde_json::from_str(&out).unwrap();
        serde_json::json!({ "did": signer.0.as_str(), "sig": v["sig"] })
    }

    /// Standing as the fixture's own clock reads it (its probation is ninety days
    /// from T0+120, long over by the wall clock).
    fn standing(n: &Node, of: &Node) -> String {
        lookup(&n.kc.0.lock().unwrap().archive, &of.did, Some(t(300))).standing.pipe(standing_word).to_string()
    }

    trait Pipe: Sized {
        fn pipe<R>(self, f: impl FnOnce(Self) -> R) -> R {
            f(self)
        }
    }
    impl<T> Pipe for T {}

    /// A and B found 'river'; C is sponsored by A, examined by A's envoy, A's second
    /// member and B's envoy, and admitted. Returns the three nodes.
    fn a_compact_of_three() -> (Node, Node, Node) {
        let (a, b, c) = (Node::found("Alpha"), Node::found("Beta"), Node::found("Gamma"));
        a.decide(CompactActKind::Join, &[&b], 20);
        b.decide(CompactActKind::Join, &[&a], 20);
        border_and_rite(&a, &[&b, &c], 30);
        border_and_rite(&b, &[&a, &c], 30);
        claims(&a, &[&b], &[&b, &c], 40);
        claims(&b, &[&a], &[&a, &c], 40);
        verdicts(&a, &b, &[&b, &c], 50);
        verdicts(&b, &a, &[&a, &c], 50);
        let draft: serde_json::Value = serde_json::from_str(&seal_draft_impl(&a.kc, &serde_json::json!({
            "compact": "river", "participants": [a.did.as_str(), b.did.as_str()], "at": T0 + 60,
        }).to_string()).unwrap()).unwrap();
        assert_eq!(draft["kind"], "sealed");
        let m = draft["manifest"].as_str().unwrap().to_string();
        let sigs = vec![sign_seal(&a, &m, a.envoy()), sign_seal(&b, &m, b.envoy())];
        let done: serde_json::Value = serde_json::from_str(&seal_assemble_impl(&a.kc,
            &serde_json::json!({ "manifest": m, "signatures": sigs }).to_string()).unwrap()).unwrap();
        let sealed = done["sealed"].as_str().unwrap();
        assert!(sealed.len() <= DELIVERY_HEX_MAX);
        for n in [&b, &c] {
            seal_ingest_impl(&n.kc, sealed).expect("every replica rebuilds and lands the same founding seal");
        }
        assert_eq!(standing(&c, &a), "in_compact");

        // Gamma: decides to join, crosses the border, seals its rite.
        c.decide(CompactActKind::Join, &[&a, &b], 100);
        a.decide(CompactActKind::Sponsor, &[&c], 100);
        a.decide(CompactActKind::Admit, &[&c], 100);
        b.decide(CompactActKind::Admit, &[&c], 100);
        border_and_rite(&c, &[&a, &b], 110);
        let s = sponsor_impl(&a.charter, &a.kc, &a.spec(serde_json::json!({
            "compact": "river", "entrant": c.did.as_str(), "envoy_priv": a.envoy().1, "at": T0 + 120,
        }))).unwrap();
        deliver(&s, &[&b, &c]);
        let seat = |n: &Node, which: &[usize]| {
            let seats: Vec<_> = which.iter().map(|i| serde_json::json!({
                "did": n.members[*i].0.as_str(), "pub": n.members[*i].2,
            })).collect();
            examiners_impl(&n.kc, &n.spec(serde_json::json!({
                "root_priv": n.root, "seats": seats, "from": T0 + 120, "days": 180,
            }))).unwrap()
        };
        deliver(&seat(&a, &[0, 2]), &[&b, &c]);
        deliver(&seat(&b, &[0]), &[&a, &c]);
        claims(&a, &[&c], &[&b, &c], 130);
        claims(&b, &[&c], &[&a, &c], 130);
        claims(&c, &[&a, &b], &[&a, &b], 130);
        for (n, others) in [(&a, [&b, &c]), (&b, [&a, &c]), (&c, [&a, &b])] {
            for p in others {
                verdicts(n, p, &[others[0], others[1]], 140);
            }
        }
        let draft: serde_json::Value = serde_json::from_str(&seal_draft_impl(&a.kc, &serde_json::json!({
            "compact": "river", "participants": [a.did.as_str(), b.did.as_str(), c.did.as_str()],
            "at": T0 + 150,
        }).to_string()).unwrap()).unwrap();
        let m = draft["manifest"].as_str().unwrap().to_string();
        assert!(m.len() <= DELIVERY_HEX_MAX, "a three-participant manifest fits one ask: {}", m.len());
        let sigs = vec![
            sign_seal(&a, &m, a.envoy()),
            sign_seal(&b, &m, b.envoy()),
            sign_seal(&c, &m, c.envoy()),
            sign_seal(&a, &m, &a.members[2]),
        ];
        // Short of the panel it does not land, and nothing is held for it.
        let short = seal_assemble_impl(&a.kc, &serde_json::json!({ "manifest": m, "signatures": sigs[..3] }).to_string());
        assert!(short.is_err(), "three envoys are not a panel of three examiners");
        assert_eq!(a.kc.0.lock().unwrap().held.len(), 0, "a half-signed seal is not held");
        let done: serde_json::Value = serde_json::from_str(&seal_assemble_impl(&a.kc,
            &serde_json::json!({ "manifest": m, "signatures": sigs }).to_string())
            .expect("sponsor, quorum of two sitting, panel of three from two")).unwrap();
        let sealed = done["sealed"].as_str().unwrap();
        println!("sealed note, three participants and four signatures: {} hex", sealed.len());
        assert!(sealed.len() <= DELIVERY_HEX_MAX);
        for n in [&b, &c] {
            seal_ingest_impl(&n.kc, sealed).expect("the members land the same seal");
        }
        (a, b, c)
    }

    #[test]
    fn three_communities_form_a_compact_over_the_wire() {
        let (a, b, c) = a_compact_of_three();
        for n in [&a, &b, &c] {
            authorize(&n.kc.0.lock().unwrap().archive).expect("every replica authorizes");
        }
        assert_eq!(standing(&b, &c), "probationary");
        assert_eq!(standing(&c, &b), "in_compact");
        // The three replicas hold the same archive.
        let len = |n: &Node| n.kc.0.lock().unwrap().archive.iter().count();
        assert_eq!(len(&a), len(&b));
        assert_eq!(len(&b), len(&c));
    }

    #[test]
    fn a_replica_survives_a_dump_and_load() {
        let (a, _b, _c) = a_compact_of_three();
        let dump = a.kc.0.lock().unwrap().dump().unwrap();
        let back = Replica::load(&dump).expect("re-verifies on load");
        assert_eq!(back.archive.iter().count(), a.kc.0.lock().unwrap().archive.iter().count());
        assert_eq!(back.claims.len(), a.kc.0.lock().unwrap().claims.len());
        assert_eq!(back.notes.len(), 2, "both seals keep the note they travel as");
    }

    #[test]
    fn an_examiner_s_node_catches_up_from_its_governance_node_s_relay() {
        let (_a, b, _c) = a_compact_of_three();
        let all: serde_json::Value = serde_json::from_str(&deliveries_impl(&b.kc, "{}").unwrap()).unwrap();
        let fresh = EthneKc(Mutex::new(Replica::default()));
        for d in all["deliveries"].as_array().unwrap() {
            let hex_str = d["hex"].as_str().unwrap();
            assert!(hex_str.len() <= DELIVERY_HEX_MAX);
            match d["op"].as_str().unwrap() {
                "deliver" => {
                    ingest_impl(&fresh, hex_str).unwrap();
                }
                "sealed" => {
                    seal_ingest_impl(&fresh, hex_str).expect("a relayed seal rebuilds from the relayed parts");
                }
                op => panic!("unexpected op {op}"),
            }
        }
        let (got, want) = (fresh.0.lock().unwrap(), b.kc.0.lock().unwrap());
        assert!(got.held.is_empty(), "nothing waits");
        assert_eq!(got.archive.iter().count(), want.archive.iter().count());
        assert_eq!(got.claims.len(), want.claims.len());
        assert_eq!(got.acceptances.len(), want.acceptances.len());
    }

    #[test]
    fn the_view_names_standings_and_fits_its_carrier() {
        let (a, b, c) = a_compact_of_three();
        let bundle = view_sign_impl(&a.kc, &a.spec(serde_json::json!({ "root_priv": a.root, "node": "0123456789abcdef0123456789abcdef", "at": T0 + 300 }))).unwrap();
        assert!(bundle.len() <= COMPACT_VIEW_BUNDLE_MAX);
        let v: serde_json::Value = serde_json::from_str(&view_verify_impl(&bundle).unwrap()).unwrap();
        assert_eq!(v["standings"][b.did.as_str()], "in_compact");
        assert_eq!(v["standings"][c.did.as_str()], "probationary");
        assert_eq!(v["compacts"][0]["label"], "river");
        // Tampering breaks it; another key cannot sign it.
        let forged = bundle.replace("probationary", "in_compact");
        assert!(view_verify_impl(&forged).is_err());
        let other = view_sign_impl(&a.kc, &a.spec(serde_json::json!({ "root_priv": b.root, "node": "0123456789abcdef0123456789abcdef" })));
        assert!(other.is_err(), "a key that is not the community's cannot sign its view");
    }

    #[test]
    fn two_communities_anathematize_a_third_and_a_policy_hides_it() {
        let (a, b, c) = a_compact_of_three();
        a.decide(CompactActKind::Anathematize, &[&c], 200);
        b.decide(CompactActKind::Anathematize, &[&c], 200);
        let draft: serde_json::Value = serde_json::from_str(&conduct_draft_impl(&a.charter, &a.spec(serde_json::json!({
            "compact": "river", "kind": "anathema", "reporters": [a.did.as_str(), b.did.as_str()],
            "subject": c.did.as_str(), "at": T0 + 210,
        }))).unwrap()).unwrap();
        // A signs its own draft; B, a co-reporter, is handed only the bytes.
        let sign = |n: &Node, by_bytes: bool| -> serde_json::Value {
            let what = if by_bytes {
                serde_json::json!({ "compact": "river", "bytes": draft["bytes"], "envoy_priv": n.envoy().1 })
            } else {
                serde_json::json!({ "compact": "river", "payload": draft["payload"], "envoy_priv": n.envoy().1 })
            };
            serde_json::from_str(&conduct_sign_impl(&n.charter, &n.kc, &n.spec(what)).unwrap()).unwrap()
        };
        let sigs = vec![sign(&a, false), sign(&b, true)];
        let out = conduct_assemble_impl(&a.kc, &serde_json::json!({
            "payload": draft["payload"], "signatures": sigs,
        }).to_string()).unwrap();
        deliver(&out, &[&b, &c]);
        assert_eq!(standing(&b, &c), "anathema");
        let bundle = view_sign_impl(&a.kc, &a.spec(serde_json::json!({ "root_priv": a.root, "node": "0123456789abcdef0123456789abcdef", "at": T0 + 220 }))).unwrap();
        let view: serde_json::Value = serde_json::from_str(&view_verify_impl(&bundle).unwrap()).unwrap();
        assert_eq!(view["standings"][c.did.as_str()], "anathema");
        let mut policy = ContentPolicy::default();
        policy.standing.insert(CommunityStanding::Anathema, LabelAction::Hide);
        let verdict = |post: &str| -> serde_json::Value {
            serde_json::from_str(&standing_verdict_impl(&serde_json::json!({
                "policy": policy, "view": view, "post_community": post,
            }).to_string()).unwrap()).unwrap()
        };
        assert_eq!(verdict(c.did.as_str())["action"], "Hide");
        assert_eq!(verdict(b.did.as_str())["action"], "Allow");
        assert_eq!(verdict(a.did.as_str())["standing"], "own");
    }

    #[test]
    fn nothing_is_drafted_or_signed_without_the_roll_s_act() {
        let (a, b) = (Node::found("Alpha"), Node::found("Beta"));
        border_and_rite(&a, &[&b], 30);
        let err = claims_impl(&a.charter, &a.kc, &a.spec(serde_json::json!({
            "compact": "river", "counterparties": [b.did.as_str()], "envoy_priv": a.envoy().1,
        }))).expect_err("no Join act");
        assert!(err.contains("D40"), "{err}");
        let (a, b, c) = a_compact_of_three();
        let draft = conduct_draft_impl(&a.charter, &a.spec(serde_json::json!({
            "compact": "river", "kind": "anathema", "reporters": [a.did.as_str(), b.did.as_str()],
            "subject": c.did.as_str(),
        })));
        assert!(draft.is_err(), "no Anathematize act at A");
    }

    #[test]
    fn a_node_whose_mandate_lapsed_does_not_sign_the_seal() {
        // Beta's Join act lapses after the claims and verdicts but before the seal's
        // instant. Beta's node rebuilds the seal and refuses to sign it.
        let (a, b) = (Node::found("Alpha"), Node::found("Beta"));
        a.decide(CompactActKind::Join, &[&b], 20);
        b.decide_until(CompactActKind::Join, &[&a], 20, Some(55));
        border_and_rite(&a, &[&b], 30);
        border_and_rite(&b, &[&a], 30);
        claims(&a, &[&b], &[&b], 40);
        claims(&b, &[&a], &[&a], 40);
        verdicts(&a, &b, &[&b], 50);
        verdicts(&b, &a, &[&a], 50);
        let draft: serde_json::Value = serde_json::from_str(&seal_draft_impl(&a.kc, &serde_json::json!({
            "compact": "river", "participants": [a.did.as_str(), b.did.as_str()], "at": T0 + 60,
        }).to_string()).unwrap()).unwrap();
        let m = draft["manifest"].as_str().unwrap();
        sign_seal(&a, m, a.envoy());
        let err = seal_sign_impl(&b.charter, &b.kc, &b.spec(serde_json::json!({
            "manifest": m, "signer_did": b.envoy().0.as_str(), "signer_priv": b.envoy().1,
        }))).expect_err("Beta's mandate lapsed");
        assert!(err.contains("Join"), "{err}");
    }

    #[test]
    fn a_delivery_waits_for_what_it_needs_and_lands_after() {
        let (a, b) = (Node::found("Alpha"), Node::found("Beta"));
        a.decide(CompactActKind::Join, &[&b], 20);
        // B hears A's claims before A's identity and envoy: they are held, not lost.
        let border = border_impl(&a.charter, &a.kc, &a.spec(serde_json::json!({
            "root_priv": a.root, "envoy_did": a.envoy().0.as_str(),
        }))).unwrap();
        let draft = rite_draft_impl(&a.charter, &a.kc, &a.spec(serde_json::json!({
            "root_priv": a.root, "inductor_did": a.members[1].0.as_str(),
        }))).unwrap();
        let _ = draft;
        let claims_out = claims_impl(&a.charter, &a.kc, &a.spec(serde_json::json!({
            "compact": "river", "counterparties": [b.did.as_str()], "envoy_priv": a.envoy().1,
        })));
        // The rite is not sealed yet, so no claims can be drafted: the border comes first.
        assert!(claims_out.is_err());
        let v: serde_json::Value = serde_json::from_str(&border).unwrap();
        let ds = v["deliveries"].as_array().unwrap();
        // Deliver the envoy delegation before the identity it needs.
        let first = ingest_impl(&b.kc, ds[1]["hex"].as_str().unwrap()).unwrap();
        assert!(first.contains("\"held\""), "{first}");
        let second = ingest_impl(&b.kc, ds[0]["hex"].as_str().unwrap()).unwrap();
        assert!(second.contains("landed"), "{second}");
        assert_eq!(b.kc.0.lock().unwrap().held.len(), 0, "the held delegation landed after it");
    }

    #[test]
    fn a_compact_act_is_co_signed_across_devices_and_lands_in_force() {
        // The roll's mandate as Agora authors it: pending bytes out, each decider
        // signs on their own device after reading what the bytes say, assembled.
        let (a, b) = (Node::found("Alpha"), Node::found("Beta"));
        let deciders: Vec<&str> = a.members.iter().map(|m| m.0.as_str()).collect();
        let pending: serde_json::Value = serde_json::from_str(&crate::pending_impl(&a.charter, &serde_json::json!({
            "record": "compact", "op": "sponsor", "polity_did": a.did.as_str(), "member_did": "",
            "body": {
                "polity": a.did.as_str(), "kind": "Sponsor", "compact": "river",
                "counterparties": [b.did.as_str()], "probation_days": 90,
                "rationale": "they keep faith", "deciders": deciders,
            },
        }).to_string()).unwrap()).unwrap();
        let bytes = pending["bytes"].as_str().unwrap();
        let described: serde_json::Value = serde_json::from_str(&crate::describe_impl(&serde_json::json!({
            "record": "compact", "bytes": bytes,
        }).to_string()).unwrap()).unwrap();
        assert!(described["description"].as_str().unwrap().contains("vouch for"), "{described}");
        let sigs: Vec<serde_json::Value> = a.members.iter().map(|m| serde_json::json!({
            "did": m.0.as_str(),
            "sig": hex::encode(keys::sign(&m.1, &hex::decode(bytes).unwrap()).unwrap().bytes),
        })).collect();
        crate::assemble_impl(&a.charter, &serde_json::json!({
            "record": "compact", "payload": pending["payload"], "signatures": sigs,
        }).to_string()).unwrap();
        let st = compact_state(&a.charter.0.lock().unwrap(), &a.did, time::now());
        assert!(st.covers(CompactActKind::Sponsor, "river", &b.did));
        // An op that does not match the act's kind is refused at authoring.
        assert!(crate::pending_impl(&a.charter, &serde_json::json!({
            "record": "compact", "op": "join", "polity_did": a.did.as_str(), "member_did": "",
            "body": { "polity": a.did.as_str(), "kind": "Sponsor", "compact": "river",
                      "counterparties": [b.did.as_str()], "probation_days": 90,
                      "rationale": "", "deciders": deciders },
        }).to_string()).is_err());
    }

    #[test]
    fn a_receipt_is_not_a_signature_over_the_record() {
        let (did, sk, _) = keypair();
        let sig = receipt_sign_impl(&serde_json::json!({ "cid": "b3:00", "priv": sk }).to_string()).unwrap();
        receipt_verify_impl(&serde_json::json!({ "cid": "b3:00", "did": did.as_str(), "sig": sig }).to_string())
            .expect("verifies");
        assert!(receipt_verify_impl(&serde_json::json!({ "cid": "b3:01", "did": did.as_str(), "sig": sig })
            .to_string()).is_err());
    }

    #[test]
    fn the_worst_case_view_fits_its_carrier() {
        let (did, sk, _) = keypair();
        let standings: Vec<ViewStanding> = (0..COMPACT_VIEW_STANDINGS_MAX)
            .map(|_| ViewStanding { did: keypair().0, standing: "probationary".into() })
            .collect();
        let compacts = (0..COMPACT_VIEW_COMPACTS_MAX)
            .map(|i| ViewCompact {
                label: format!("{}{}", "c".repeat(en_charter::COMPACT_LABEL_MAX - 1), i),
                id: Cid::of_bytes(&[i as u8]),
                members: (0..COMPACT_VIEW_STANDINGS_MAX as u16).collect(),
            })
            .collect();
        let view = CompactView {
            community_did: did.clone(), node: "f".repeat(32), seq: u64::MAX, as_of: t(0), compacts, standings,
        };
        let n = serde_json::to_string(&Signed::build(view, &[(did.as_str(), &sk)]).unwrap()).unwrap().len();
        println!("worst-case compact view: {n} bytes of {COMPACT_VIEW_BUNDLE_MAX}");
        assert!(n <= COMPACT_VIEW_BUNDLE_MAX, "{n}");
    }
}
