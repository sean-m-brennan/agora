// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Minimal geohash decode + great-circle distance, computed app-side. The AT C
// core treats a shared position as an opaque geohash string; Agora decodes it
// here and computes the geographic distance from this node's own opted-in
// bucket. RTT (Increment 1) is a separate, directionless proximity signal.

import 'dart:math' as math;

/// A decoded geohash bucket: its center plus the half-extents of the cell (so a
/// caller can reason about the bucket's coarseness, not just its point).
class GeoBucket {
  const GeoBucket(this.lat, this.lon, this.latErr, this.lonErr);
  final double lat;
  final double lon;
  final double latErr;
  final double lonErr;
}

const String _base32 = '0123456789bcdefghjkmnpqrstuvwxyz';

/// Decode a geohash to the center of its cell. Returns null for an empty or
/// invalid geohash (so "opted out / not shared" is a clean null, not a point).
GeoBucket? decodeGeohash(String geohash) {
  if (geohash.isEmpty) return null;
  var latLo = -90.0, latHi = 90.0;
  var lonLo = -180.0, lonHi = 180.0;
  var even = true; // even bits index longitude
  for (final ch in geohash.toLowerCase().codeUnits) {
    final cd = _base32.indexOf(String.fromCharCode(ch));
    if (cd < 0) return null; // invalid character
    for (var mask = 16; mask != 0; mask >>= 1) {
      final bit = (cd & mask) != 0;
      if (even) {
        final mid = (lonLo + lonHi) / 2;
        if (bit) {
          lonLo = mid;
        } else {
          lonHi = mid;
        }
      } else {
        final mid = (latLo + latHi) / 2;
        if (bit) {
          latLo = mid;
        } else {
          latHi = mid;
        }
      }
      even = !even;
    }
  }
  return GeoBucket(
    (latLo + latHi) / 2,
    (lonLo + lonHi) / 2,
    (latHi - latLo) / 2,
    (lonHi - lonLo) / 2,
  );
}

const double _earthRadiusKm = 6371.0088;

double _deg2rad(double d) => d * math.pi / 180.0;

/// Great-circle (haversine) distance in km between two lat/lon points.
double haversineKm(double lat1, double lon1, double lat2, double lon2) {
  final dLat = _deg2rad(lat2 - lat1);
  final dLon = _deg2rad(lon2 - lon1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_deg2rad(lat1)) *
          math.cos(_deg2rad(lat2)) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return _earthRadiusKm * c;
}

/// Distance in km between two geohash buckets' centers, or null if either is
/// empty/invalid (one-sided opt-in yields no distance — the intended privacy
/// behavior). Coarse by construction: a ~5-char bucket is ~±2.4 km.
double? geohashDistanceKm(String a, String b) {
  final ga = decodeGeohash(a);
  final gb = decodeGeohash(b);
  if (ga == null || gb == null) return null;
  return haversineKm(ga.lat, ga.lon, gb.lat, gb.lon);
}
