// MagicMaker sync hub, phase P2: Outbox, one per link (docs/SYNC_P2_FIRMWARE_PLAN.md §5.4;
// spec §4.11; SYNC_PROTOCOL.md §9.2).
//
// A HUB_OUTBOX_BYTES arena of whole messages, each stored as [class u8][len u16 LE][bytes], plus
// the link's P1 Fragmenter (frame counter and per-direction frame seq, reset at SUBSCRIBE).
//
//   Selection   FIFO while no timed job is on air (wire order == emission order, D-P2-8); while a
//               job is on air the lowest class first (ERR 0 > control 1 > HB 2 > EVT / relays 3 >
//               live REC 4 > page REC / PAGE_END 5), FIFO within a class. The message being
//               fragmented is never reordered or removed once its first frame was built.
//   Frames      peekFrame() builds the next frame and keeps it until popFrame() (the radio took
//               it), so a refused notify is retried with the same bytes and frame seq.
//   Overflow    ERR and control may use the whole arena; every other class leaves
//               HUB_OUTBOX_RESERVE (2 x 160 B) for them. An HB replaces a queued HB describing the
//               same device (in place). An EVT that does not fit drops the oldest queued EVTs. A
//               live REC that does not fit is dropped (it arrives by pull). Page RECs are only
//               produced when room() holds HUB_PAGE_REC_ROOM, so they never overflow.
//
// Pure C++11, no heap, no Arduino dependency.
#pragma once

#include "hub_ports.h"

namespace mmsync {

enum OutClass : uint8_t {
  OC_ERR = 0,
  OC_CONTROL = 1,  // HELLO, AUTH, JOIN, PULL
  OC_HB = 2,
  OC_EVT = 3,      // EVT and the EVT_SINCE / EVT_GAP relays
  OC_LIVE = 4,     // live REC
  OC_PAGE = 5      // page REC, PAGE_END
};

static const uint16_t HUB_OUTBOX_BYTES = 2048;
static const uint16_t HUB_OUTBOX_RESERVE = 320;   // room only ERR / control may use
static const uint16_t HUB_PAGE_REC_ROOM = 370;    // a page REC (<= 370 B) + its header fits
static const uint16_t HUB_TX_MTU_MAX = 247;       // NimBLEDevice::setMTU(247): the largest link MTU
static const uint8_t HUB_OUT_HEAD = 3;            // [class][len u16]

// The class a message type is queued with (page RECs and live RECs are told apart by the caller).
inline uint8_t outClassOf(uint8_t msgType, bool liveRec) {
  switch (msgType) {
    case MSG_ERR:
      return OC_ERR;
    case MSG_HELLO:
    case MSG_AUTH:
    case MSG_JOIN:
    case MSG_PULL:
    case MSG_SUB:
      return OC_CONTROL;
    case MSG_HB:
      return OC_HB;
    case MSG_EVT:
    case MSG_EVT_SINCE:
    case MSG_EVT_GAP:
      return OC_EVT;
    case MSG_REC:
      return liveRec ? OC_LIVE : OC_PAGE;
    default:
      return OC_PAGE;
  }
}

// The deviceId (TLV 0x01) of an encoded HB; false when it has none.
inline bool hbDescribed(const uint8_t* msg, size_t n, Id8* out) {
  if (n < 1 || msg[0] != MSG_HB || !tlvFramingOk(msg, n, 1)) return false;
  for (size_t i = 1; i < n;) {
    const uint8_t tag = msg[i];
    const uint8_t ln = msg[i + 1];
    if (tag == 0x01 && ln == 8) {
      *out = makeId8(msg + i + 2);
      return true;
    }
    i += 2 + (size_t)ln;
  }
  return false;
}

class Outbox {
 public:
  Outbox() { reset(); }

  void reset() {
    used_ = 0;
    active_ = false;
    activePos_ = 0;
    activeOff_ = 0;
    framePending_ = false;
    frameLen_ = 0;
    frag_.reset();
    dropped_ = 0;
    droppedLive_ = 0;
    droppedEvt_ = 0;
    replacedHb_ = 0;
  }

  bool empty() const { return used_ == 0 && !framePending_; }
  bool hasFrame() const { return used_ != 0 || framePending_; }
  uint16_t used() const { return used_; }
  uint16_t count() const {
    uint16_t n = 0;
    for (uint16_t p = 0; p < used_; p = next(p)) n++;
    return n;
  }
  // Bytes a message of class cls may still use (header included).
  uint16_t room(uint8_t cls) const {
    const uint16_t limit = limitFor(cls);
    return used_ >= limit ? 0 : (uint16_t)(limit - used_);
  }
  bool hasRoomFor(uint8_t cls, uint16_t msgLen) const {
    return (uint32_t)room(cls) >= (uint32_t)msgLen + HUB_OUT_HEAD;
  }

  // Queues a whole message. False when it was dropped (counted).
  bool push(uint8_t cls, const uint8_t* msg, uint16_t len) {
    if (len == 0) return false;
    const uint16_t need = (uint16_t)(len + HUB_OUT_HEAD);
    if (need > HUB_OUTBOX_BYTES) return drop(cls);
    const uint16_t limit = limitFor(cls);
    if (cls == OC_HB) {
      Id8 who;
      if (hbDescribed(msg, len, &who)) {
        for (uint16_t p = 0; p < used_; p = next(p)) {
          if (active_ && p == activePos_) continue;
          if (buf_[p] != OC_HB) continue;
          Id8 other;
          if (!hbDescribed(buf_ + p + HUB_OUT_HEAD, lenAt(p), &other) || other != who) continue;
          const uint16_t oldNeed = (uint16_t)(lenAt(p) + HUB_OUT_HEAD);
          if ((uint32_t)used_ - oldNeed + need > limit) return drop(cls);
          removeAt(p);
          insertAt(p, cls, msg, len);
          replacedHb_++;
          return true;
        }
      }
    }
    if ((uint32_t)used_ + need <= limit) {
      insertAt(used_, cls, msg, len);
      return true;
    }
    if (cls == OC_EVT && msg[0] == MSG_EVT) {
      // drop the oldest queued EVTs (not the one being fragmented) until the new one fits
      uint16_t p = 0;
      while (p < used_ && (uint32_t)used_ + need > limit) {
        if (buf_[p] == OC_EVT && buf_[p + HUB_OUT_HEAD] == MSG_EVT && !(active_ && p == activePos_)) {
          removeAt(p);
          droppedEvt_++;
          dropped_++;
          continue;  // p now addresses the next message
        }
        p = next(p);
      }
      if ((uint32_t)used_ + need <= limit) {
        insertAt(used_, cls, msg, len);
        return true;
      }
    }
    return drop(cls);
  }

  // The next frame at this MTU (built once, kept until popFrame()); NULL when nothing is queued.
  // priority: a timed job is on air (class order instead of FIFO).
  const uint8_t* peekFrame(uint16_t mtu, bool priority, size_t* len) {
    if (!framePending_) {
      if (!active_) {
        if (used_ == 0) return NULL;
        activePos_ = priority ? bestByClass() : 0;
        active_ = true;
        activeOff_ = 0;
      }
      if (mtu > HUB_TX_MTU_MAX) mtu = HUB_TX_MTU_MAX;
      const uint8_t* msg = buf_ + activePos_ + HUB_OUT_HEAD;
      const uint16_t mlen = lenAt(activePos_);
      frameLen_ = frag_.next(msg, mlen, &activeOff_, mtu, frame_);
      framePending_ = frameLen_ != 0;
      if (activeOff_ >= mlen) {  // the last frame of this message is built: the arena copy goes
        removeAt(activePos_);
        active_ = false;
        activeOff_ = 0;
      }
      if (!framePending_) return NULL;
    }
    *len = frameLen_;
    return frame_;
  }

  void popFrame() { framePending_ = false; }

  // A message is being fragmented (some of its frames left).
  bool midMessage() const { return active_ && activeOff_ > 0; }

  uint32_t dropped() const { return dropped_; }
  uint32_t droppedLive() const { return droppedLive_; }
  uint32_t droppedEvt() const { return droppedEvt_; }
  uint32_t replacedHb() const { return replacedHb_; }

  // Iteration for tests and status: the i-th queued message (not counting a pending frame).
  bool at(uint16_t i, uint8_t* cls, const uint8_t** msg, uint16_t* len) const {
    uint16_t k = 0;
    for (uint16_t p = 0; p < used_; p = next(p), k++) {
      if (k != i) continue;
      *cls = buf_[p];
      *msg = buf_ + p + HUB_OUT_HEAD;
      *len = lenAt(p);
      return true;
    }
    return false;
  }

 private:
  static uint16_t limitFor(uint8_t cls) {
    return cls <= OC_CONTROL ? HUB_OUTBOX_BYTES : (uint16_t)(HUB_OUTBOX_BYTES - HUB_OUTBOX_RESERVE);
  }

  uint16_t lenAt(uint16_t p) const { return (uint16_t)(buf_[p + 1] | (buf_[p + 2] << 8)); }
  uint16_t next(uint16_t p) const { return (uint16_t)(p + HUB_OUT_HEAD + lenAt(p)); }

  uint16_t bestByClass() const {
    uint16_t best = 0;
    uint8_t bestCls = 0xFF;
    for (uint16_t p = 0; p < used_; p = next(p)) {
      if (buf_[p] < bestCls) {
        bestCls = buf_[p];
        best = p;
      }
    }
    return best;
  }

  void removeAt(uint16_t p) {
    const uint16_t n = (uint16_t)(HUB_OUT_HEAD + lenAt(p));
    memmove(buf_ + p, buf_ + p + n, used_ - p - n);
    used_ = (uint16_t)(used_ - n);
    if (active_ && p < activePos_) activePos_ = (uint16_t)(activePos_ - n);
  }

  void insertAt(uint16_t p, uint8_t cls, const uint8_t* msg, uint16_t len) {
    const uint16_t n = (uint16_t)(HUB_OUT_HEAD + len);
    memmove(buf_ + p + n, buf_ + p, used_ - p);
    buf_[p] = cls;
    buf_[p + 1] = (uint8_t)(len & 0xFF);
    buf_[p + 2] = (uint8_t)(len >> 8);
    memcpy(buf_ + p + HUB_OUT_HEAD, msg, len);
    used_ = (uint16_t)(used_ + n);
    if (active_ && p <= activePos_) activePos_ = (uint16_t)(activePos_ + n);
  }

  bool drop(uint8_t cls) {
    dropped_++;
    if (cls == OC_LIVE) droppedLive_++;
    if (cls == OC_EVT) droppedEvt_++;
    return false;
  }

  uint8_t buf_[HUB_OUTBOX_BYTES];
  uint16_t used_;
  bool active_;
  uint16_t activePos_;
  size_t activeOff_;
  Fragmenter frag_;
  uint8_t frame_[HUB_TX_MTU_MAX + 2];
  size_t frameLen_;
  bool framePending_;
  uint32_t dropped_;
  uint32_t droppedLive_;
  uint32_t droppedEvt_;
  uint32_t replacedHb_;
};

}  // namespace mmsync
