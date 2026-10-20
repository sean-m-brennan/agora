// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// The file-sharing verbs PeerService sends to the core, behind one seam so a
// test can see which went out, to which device, under which id.
//
// Every verb returns the shim's rc: 0 queued, -2 daemon not ready, -1 no
// channel. A 0 means QUEUED: the core hashes, checks and answers afterwards,
// and says what happened in an AGORA_EVENT_FILE.

abstract class FileVerbs {
  int offer(List<int> deviceUuid, String xferId, String path);
  int accept(List<int> deviceUuid, String xferId);
  int decline(List<int> deviceUuid, String xferId);
  int cancel(List<int> deviceUuid, String xferId);
}
