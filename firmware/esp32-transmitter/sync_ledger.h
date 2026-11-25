// MagicMaker SYNC v1 ledger model (docs/SYNC_PROTOCOL.md §6): the per-key winning verbatim body
// with its feed seq and syncFrom, remote apply, local edits (stamp + text normalisation), learn
// checks and the tombstone cap.
//
// This is the phones' ledger, in C++ for the shared `apply` vectors and for the P2 three-node
// simulation. It uses std::vector, so it is meant for the host; the hub keeps records in its
// flash log (P2) and uses only applyCheck() (sync_codec.h) for the accept rule.
#pragma once

#include <vector>

#include "sync_codec.h"

namespace mmsync {

struct LedgerEntry {
  Key key;
  Version version;  // u, o, c
  uint8_t cls;      // RecordClass
  uint8_t flags;
  bool hasOrigin;
  Id8 origin;
  uint16_t bodyLen;
  uint8_t body[BODY_MAX];  // b: verbatim canonical body
  uint32_t s;              // local feed seq (syncSeq)
  bool hasSyncFrom;        // f: none for local edits / learns
  Id8 syncFrom;

  bool deleted() const { return (flags & FLAG_DELETED) != 0; }
};

// A local edit (§6.4). Text fields are normalised here (§5.3); `has*` false = not given.
struct EditRequest {
  uint8_t cls;  // CLS_USER, CLS_RESET, CLS_TOMBSTONE or CLS_NEWWAND
  Key key;
  int64_t nowMs;
  Id8 self;
  bool hasLabel;
  const uint8_t* label;
  size_t labelLen;
  bool hasCategory;
  uint8_t category;
  bool hasKind;
  const uint8_t* kind;
  size_t kindLen;
  bool hasPlace;
  uint8_t place;
  bool hasNote;
  const uint8_t* note;
  size_t noteLen;
  bool preset;      // USER only
  bool userEdited;  // USER only
};

inline EditRequest makeEdit(uint8_t cls, const Key& key, int64_t nowMs, const Id8& self) {
  EditRequest e;
  memset(&e, 0, sizeof(e));
  e.cls = cls;
  e.key = key;
  e.nowMs = nowMs;
  e.self = self;
  e.userEdited = true;
  return e;
}

class Ledger {
 public:
  uint32_t nextSyncSeq;
  int64_t lastLocalStamp;
  uint32_t tombstoneCap;

  explicit Ledger(uint32_t cap = TOMBSTONE_CAP_PHONE, uint32_t nextSeq = 1)
      : nextSyncSeq(nextSeq), lastLocalStamp(0), tombstoneCap(cap) {}

  const std::vector<LedgerEntry>& entries() const { return entries_; }

  const LedgerEntry* get(const Key& k) const {
    for (size_t i = 0; i < entries_.size(); i++)
      if (entries_[i].key == k) return &entries_[i];
    return NULL;
  }

  size_t tombstoneCount() const {
    size_t n = 0;
    for (size_t i = 0; i < entries_.size(); i++)
      if (entries_[i].deleted()) n++;
    return n;
  }

  // A received record (§6.2). On ACCEPT *stored is a copy of the new entry (even when the cap
  // evicted it at once) and *evicted lists the keys removed by the tombstone cap.
  ApplyStatus applyRemote(const uint8_t* body, size_t n, const Id8& sender, bool nowKnown,
                          int64_t nowMs, LedgerEntry* stored, std::vector<Key>* evicted,
                          Status* err = NULL) {
    if (evicted) evicted->clear();
    Body b;
    Version v;
    Status e;
    const LedgerEntry* cur = NULL;
    {
      Body probe;
      if (decodeBody(body, n, &probe, NULL).ok()) cur = get(probe.key);
    }
    const ApplyStatus st =
        applyCheck(body, n, nowKnown, nowMs, cur ? &cur->version : NULL, &b, &v, &e);
    if (err) *err = e;
    if (st != APPLY_ACCEPT) return st;
    store(b, body, n, true, sender, stored, evicted);
    return APPLY_ACCEPT;
  }

  // A learn path met a library packet: PRESENCE only when the key has no entry at all.
  bool localLearn(const uint8_t* packet, size_t n, LedgerEntry* stored) {
    if (!checkPacket(packet, n).ok()) return false;
    const Key k = makeKey(NS_LIB, packet, n);
    if (get(k)) return false;
    Body b;
    clearBody(&b);
    b.key = k;
    b.updatedAt = U_PRESENCE;
    uint8_t buf[BODY_MAX];
    size_t len;
    if (!encodeBody(b, buf, sizeof(buf), &len).ok()) return false;
    store(b, buf, len, false, zeroId8(), stored, NULL);
    return true;
  }

  // A user edit (§5.2, §5.3, §6.4). *stored is the new entry; *kept is false when the tombstone
  // cap evicted it at once. A USER edit whose label normalises to empty is refused (the caller
  // sends RESET for a blank rename).
  Status localEdit(const EditRequest& r, LedgerEntry* stored, bool* kept,
                   std::vector<Key>* evicted) {
    if (evicted) evicted->clear();
    if (kept) *kept = false;
    const LedgerEntry* cur = get(r.key);
    // No stamp can beat an entry (or a previous stamp) at I64_MAX: refuse rather than emit a
    // version that does not win (sync_ref.py fails to encode it).
    if ((cur && cur->version.updatedAt == I64_MAX) || lastLocalStamp == I64_MAX)
      return clockErr("stamp_overflow");
    const int64_t u = localStamp(r.nowMs, cur ? cur->version.updatedAt : 0, lastLocalStamp);
    lastLocalStamp = u;
    Body b;
    clearBody(&b);
    b.key = r.key;
    b.updatedAt = u;
    b.hasOrigin = true;
    b.origin = r.self;
    uint8_t label[LABEL_MAX], note[NOTE_MAX], kind[KIND_MAX];
    size_t labelLen = 0, noteLen = 0, kindLen = 0;
    if (r.hasLabel && !normalizeText(r.label, r.labelLen, LABEL_MAX, label, &labelLen))
      return badMsg("utf8");
    if (r.hasNote && !normalizeText(r.note, r.noteLen, NOTE_MAX, note, &noteLen))
      return badMsg("utf8");
    if (r.hasKind && !normalizeKind(r.kind, r.kindLen, kind, &kindLen)) return badMsg("utf8");
    switch (r.cls) {
      case CLS_USER:
        if (r.key.ns != NS_LIB || labelLen == 0) return badMsg("class");
        b.flags = (uint8_t)((r.userEdited ? FLAG_USER_EDITED : 0) | (r.preset ? FLAG_PRESET : 0));
        if (!b.flags) return badMsg("class");
        setText(b.label, &b.labelLen, label, labelLen);
        b.hasCategory = r.hasCategory;
        b.category = r.category;
        setText(b.kind, &b.kindLen, kind, kindLen);
        b.hasPlace = r.hasPlace;
        b.place = r.place;
        setText(b.note, &b.noteLen, note, noteLen);
        break;
      case CLS_RESET:
        if (r.key.ns != NS_LIB) return badMsg("class");
        setText(b.note, &b.noteLen, note, noteLen);
        break;
      case CLS_TOMBSTONE:
        b.flags = FLAG_DELETED;
        break;
      case CLS_NEWWAND:
        if (r.key.ns != NS_NEWWAND) return badMsg("class");
        if (labelLen == 0) {
          b.flags = FLAG_DELETED;
        } else {
          setText(b.label, &b.labelLen, label, labelLen);
          setText(b.note, &b.noteLen, note, noteLen);
        }
        break;
      default:
        return badMsg("class");
    }
    uint8_t buf[BODY_MAX];
    size_t len;
    Status s = encodeBody(b, buf, sizeof(buf), &len);
    if (!s.ok()) return s;
    const bool k = store(b, buf, len, false, zeroId8(), stored, evicted);
    if (kept) *kept = k;
    return statusOk();
  }

 private:
  static void setText(uint8_t* dst, uint8_t* dstLen, const uint8_t* src, size_t n) {
    if (n) memcpy(dst, src, n);
    *dstLen = (uint8_t)n;
  }

  // Stores a new version (s = nextSyncSeq++), then applies the tombstone cap when the new entry
  // is a deletion. Returns whether the new entry is still there.
  bool store(const Body& b, const uint8_t* body, size_t n, bool hasFrom, const Id8& from,
             LedgerEntry* copyOut, std::vector<Key>* evicted) {
    LedgerEntry e;
    memset(&e, 0, sizeof(e));
    e.key = b.key;
    e.version = versionOf(b, body, n);
    RecordClass cls = CLS_NONE;
    validateBodyFields(b, &cls);
    e.cls = cls;
    e.flags = b.flags;
    e.hasOrigin = b.hasOrigin;
    e.origin = b.origin;
    e.bodyLen = (uint16_t)n;
    memcpy(e.body, body, n);
    e.s = nextSyncSeq++;
    e.hasSyncFrom = hasFrom;
    e.syncFrom = hasFrom ? from : zeroId8();
    if (copyOut) *copyOut = e;
    bool replaced = false;
    for (size_t i = 0; i < entries_.size(); i++) {
      if (entries_[i].key == e.key) {
        entries_[i] = e;
        replaced = true;
        break;
      }
    }
    if (!replaced) entries_.push_back(e);
    if (!e.deleted()) return true;
    bool kept = true;
    size_t tombs = tombstoneCount();
    while (tombs > tombstoneCap) {
      size_t victim = entries_.size();
      for (size_t i = 0; i < entries_.size(); i++) {
        if (!entries_[i].deleted()) continue;
        if (victim == entries_.size()) {
          victim = i;
          continue;
        }
        const int c = compareVersions(entries_[i].version, entries_[victim].version);
        if (c < 0 || (c == 0 && compareKeyBytes(entries_[i].key, entries_[victim].key) < 0))
          victim = i;
      }
      if (victim == entries_.size()) break;
      if (entries_[victim].key == e.key) kept = false;
      if (evicted) evicted->push_back(entries_[victim].key);
      entries_.erase(entries_.begin() +
                     static_cast<std::vector<LedgerEntry>::difference_type>(victim));
      tombs--;
    }
    return kept;
  }

  std::vector<LedgerEntry> entries_;
};

}  // namespace mmsync
