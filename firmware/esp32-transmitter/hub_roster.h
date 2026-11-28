// MagicMaker sync hub, phase P2: Roster, the latest heartbeat per device as the hub heard it
// (docs/SYNC_P2_FIRMWARE_PLAN.md §5.9; SYNC_PROTOCOL.md §16.4; spec §9.3) for sync_status and the
// Heltec DEVICES page.
//
// Up to HUB_ROSTER_MAX devices (least recently heard is replaced), never the hub itself. The HB
// fields follow the keep-latest rule (hbReplaces: bootId differs or hbSeq greater); the path times
// are updated by every HB, so a device whose HB arrives both direct and forwarded shows both
// paths. Path: DIRECT when a direct HB is <= 90 s old, VIA when a forwarded one is, BOTH when both.
//
// Pure C++11, no heap, no Arduino dependency.
#pragma once

#include "hub_ports.h"

namespace mmsync {

struct RosterEntry {
  bool used;
  Id8 id;
  uint8_t kind;
  uint16_t bootId;
  uint32_t hbSeq;
  int8_t battPct;
  int8_t charging;
  int16_t runtimeMin;
  uint8_t nameLen;
  uint8_t name[20];
  uint32_t lastAnyMs;
  bool hasDirect;
  uint32_t lastDirectMs;
  bool hasVia;
  uint32_t lastViaMs;
  uint8_t viaKind;  // the forwarder's kind of the latest forwarded HB
};

class Roster {
 public:
  Roster() { clear(); }

  void clear() { memset(items_, 0, sizeof(items_)); }

  // hb from the session whose peer has kind fromKind; direct = hops 0 and described == that peer.
  // self: the hub's own deviceId (never kept). Returns true when the HB fields were replaced.
  bool update(const Hb& hb, bool direct, uint8_t fromKind, const Id8& self, uint32_t now) {
    if (hb.deviceId == self) return false;
    RosterEntry* e = find(hb.deviceId);
    const bool fresh = e == NULL;
    if (!e) e = alloc(hb.deviceId);
    const bool repl = fresh || hbReplaces(true, e->bootId, e->hbSeq, hb.bootId, hb.hbSeq);
    if (repl) {
      e->kind = hb.kind;
      e->bootId = hb.bootId;
      e->hbSeq = hb.hbSeq;
      e->battPct = hb.battPctValue();
      e->charging = hb.chargingValue();
      e->runtimeMin = hb.runtimeMinValue();
      e->nameLen = hb.name.len > sizeof(e->name) ? (uint8_t)sizeof(e->name) : hb.name.len;
      if (e->nameLen) memcpy(e->name, hb.name.b, e->nameLen);
    }
    e->lastAnyMs = now;
    if (direct) {
      e->hasDirect = true;
      e->lastDirectMs = now;
    } else {
      e->hasVia = true;
      e->lastViaMs = now;
      e->viaKind = fromKind;
    }
    return repl;
  }

  const RosterEntry* find(const Id8& id) const {
    for (uint8_t i = 0; i < HUB_ROSTER_MAX; i++)
      if (items_[i].used && items_[i].id == id) return &items_[i];
    return NULL;
  }

  uint8_t path(const RosterEntry& e, uint32_t now) const {
    uint8_t p = HUB_PATH_NONE;
    if (e.hasDirect && now - e.lastDirectMs <= T_PATH_FRESH_MS) p |= HUB_PATH_DIRECT;
    if (e.hasVia && now - e.lastViaMs <= T_PATH_FRESH_MS) p |= HUB_PATH_VIA;
    return p;
  }

  uint32_t ageS(const RosterEntry& e, uint32_t now) const { return (now - e.lastAnyMs) / 1000; }

  // The i-th used entry, most recently heard first; NULL past the end.
  const RosterEntry* byRecency(uint8_t i) const {
    const RosterEntry* order[HUB_ROSTER_MAX];
    uint8_t n = 0;
    for (uint8_t k = 0; k < HUB_ROSTER_MAX; k++)
      if (items_[k].used) order[n++] = &items_[k];
    for (uint8_t a = 1; a < n; a++) {
      const RosterEntry* x = order[a];
      int b = a - 1;
      while (b >= 0 && (int32_t)(order[b]->lastAnyMs - x->lastAnyMs) < 0) {
        order[b + 1] = order[b];
        b--;
      }
      order[b + 1] = x;
    }
    return i < n ? order[i] : NULL;
  }

  uint8_t size() const {
    uint8_t n = 0;
    for (uint8_t i = 0; i < HUB_ROSTER_MAX; i++)
      if (items_[i].used) n++;
    return n;
  }

 private:
  RosterEntry* find(const Id8& id) {
    for (uint8_t i = 0; i < HUB_ROSTER_MAX; i++)
      if (items_[i].used && items_[i].id == id) return &items_[i];
    return NULL;
  }

  RosterEntry* alloc(const Id8& id) {
    RosterEntry* pick = &items_[0];
    for (uint8_t i = 0; i < HUB_ROSTER_MAX; i++) {
      if (!items_[i].used) {
        pick = &items_[i];
        break;
      }
      if ((int32_t)(items_[i].lastAnyMs - pick->lastAnyMs) < 0) pick = &items_[i];
    }
    memset(pick, 0, sizeof(*pick));
    pick->used = true;
    pick->id = id;
    return pick;
  }

  RosterEntry items_[HUB_ROSTER_MAX];
};

}  // namespace mmsync
