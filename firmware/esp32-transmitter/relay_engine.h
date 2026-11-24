// Transmit engine of the ESP32 relay: the JOB on air now, and the PROGRAM the chip keeps running
// by itself (keep-awake, TX loop, wand loop) whether or not a phone is linked.
//
// Pure C++ like relay_proto.h, so it is tested on a desktop too. loop() is its only user: it
// applies the queued commands, calls service() with the time, and puts airBytes() on air. The
// engine never touches the radio, the LED or the screen itself.
//
// Jobs (one on air at a time):
//   NORMAL  a packet with the app's timing. Wand / ping: one burst. Band: wake ping, then the
//           command (sustained); 1:1 wake/command slices over the window (interleave); or the
//           command alone while keep-awake runs (the band is already listening).
//   RAW     the packet alone for exactly ms (raw_burst replay steps, MBLE taps).
//   STREAM  the keep-awake packet, continuously.
// A user send or an MBLE tap preempts anything (the newest wins). A raw_burst waits in a 1-deep
// slot behind a raw_burst on air, otherwise preempts. Loop bursts never preempt: they start only
// when nothing is on air.
//
// Programs (at most one; turning one on turns the others off; none at boot, nothing persisted):
//   KEEP_AWAKE  the stream runs whenever no job is on air.
//   TX_LOOP / WAND_LOOP  one burst of the loop's packet every intervalMs, measured from the end of
//           the previous burst. The first burst goes out as soon as the air is free.
#pragma once

#include "relay_proto.h"

enum RelayJobType : uint8_t { RELAY_JOB_NONE = 0, RELAY_JOB_NORMAL, RELAY_JOB_RAW, RELAY_JOB_STREAM };
enum RelayPhase : uint8_t { RELAY_PHASE_SEND = 0, RELAY_PHASE_WAKE };

static const uint32_t RELAY_NO_DEADLINE = 0xFFFFFFFFu;

// Chip settings (RAM only; the iPhone pushes its values on every link).
struct RelaySettings {
  uint16_t wakeMs;      // band wake ping before the command (interleave: each slice)
  uint16_t cmdMs;       // band command stream (interleave: the whole window)
  uint16_t starMs;      // wand burst
  uint16_t pingMs;      // standalone ping burst
  uint8_t  powerLevel;  // beacon power 0..3
  bool     interleave;
};

struct RelayLoop {
  uint8_t  len;  // 0: no packet given yet
  uint8_t  bytes[RELAY_PACKET_MAX];
  char     label[RELAY_LABEL_MAX + 1];
  uint32_t intervalMs;
};

struct RelayJob {
  uint8_t  type;        // RelayJobType
  uint8_t  kind;        // RelayKind (RELAY_KIND_RAW for raw jobs)
  uint8_t  phase;       // RelayPhase
  uint8_t  loopOf;      // RELAY_PROG_TX_LOOP / _WAND_LOOP when this is that loop's burst
  bool     replay;      // a raw_burst step
  uint8_t  len;
  uint8_t  bytes[RELAY_PACKET_MAX];
  uint32_t phaseStart;  // millis()
  uint32_t phaseMs;
  uint32_t wakeMs;      // length of each wake phase
  uint32_t sendMs;      // length of each command phase
  uint16_t cyclesLeft;  // interleave: wake+command pairs still to come after the current one
};

// The last job put on air (for the LED flash and the screen's LAST PACKET page).
struct RelayStarted {
  uint8_t  kind;
  uint8_t  len;
  uint8_t  bytes[RELAY_PACKET_MAX];
  uint32_t ms;    // command stream / burst length (interleave: the whole window)
  bool     wake;  // a wake ping ran first
};

struct RelayEngine {
  RelaySettings set;
  uint8_t   program;  // RelayProgram
  RelayJob  job;
  RelayLoop txLoop;
  RelayLoop wandLoop;
  uint8_t   keepLen;  // keep-awake packet
  uint8_t   keepBytes[RELAY_PACKET_MAX];
  uint8_t   wakeLen;  // band wake ping
  uint8_t   wakeBytes[RELAY_PACKET_MAX];
  bool      loopRearm;  // a manual job preempted the running loop's burst
  uint32_t  nextDue;    // the running loop's next burst (millis())
  bool      slotFull;   // a raw_burst waiting behind the one on air
  uint8_t   slotLen;
  uint8_t   slotBytes[RELAY_PACKET_MAX];
  uint16_t  slotMs;
  uint32_t  sent;       // NORMAL + RAW jobs started since boot
  RelayStarted started;

  void begin(const RelaySettings& defaults, uint32_t loopIntervalMs) {
    memset((void*)this, 0, sizeof(*this));
    set = defaults;
    relayCanonicalPacket(RELAY_WAKE_PING_HEX, strlen(RELAY_WAKE_PING_HEX), wakeBytes, &wakeLen);
    keepLen = wakeLen;
    memcpy(keepBytes, wakeBytes, wakeLen);
    txLoop.intervalMs = loopIntervalMs;
    wandLoop.intervalMs = loopIntervalMs;
  }

  bool loopRunning() const { return program == RELAY_PROG_TX_LOOP || program == RELAY_PROG_WAND_LOOP; }
  RelayLoop& loopFor(uint8_t prog) { return prog == RELAY_PROG_TX_LOOP ? txLoop : wandLoop; }
  const RelayLoop& loopFor(uint8_t prog) const { return prog == RELAY_PROG_TX_LOOP ? txLoop : wandLoop; }
  bool timedJob() const { return job.type == RELAY_JOB_NORMAL || job.type == RELAY_JOB_RAW; }

  // The running loop's interval (0 when no loop runs).
  uint32_t loopIntervalMs() const { return loopRunning() ? loopFor(program).intervalMs : 0; }

  // ---- Jobs ----------------------------------------------------------------------------
  void beginPhase(uint8_t phase, uint32_t ms, uint32_t now) {
    job.phase = phase;
    job.phaseStart = now;
    job.phaseMs = ms;
  }

  // A new job takes the air; whatever was on air stops. A preempted burst of the running loop
  // re-arms that loop one interval after the job that replaced it ends.
  void takeAir(uint8_t type, const uint8_t* bytes, uint8_t len, uint32_t now) {
    if (timedJob() && job.loopOf != RELAY_PROG_NONE && job.loopOf == program) loopRearm = true;
    memset((void*)&job, 0, sizeof(job));
    job.type = type;
    job.len = len;
    memcpy(job.bytes, bytes, len);
    job.phaseStart = now;
  }

  void noteStart(uint32_t ms, bool wake) {
    sent++;
    started.kind = job.kind;
    started.len = job.len;
    memcpy(started.bytes, job.bytes, job.len);
    started.ms = ms;
    started.wake = wake;
  }

  // wireMs 0 = the kind's default from the chip settings.
  void startNormal(const uint8_t* bytes, uint8_t len, uint16_t wireMs, uint8_t loopOf, uint32_t now) {
    takeAir(RELAY_JOB_NORMAL, bytes, len, now);
    job.kind = relayPacketKind(bytes, len);
    job.loopOf = loopOf;
    uint32_t ms = wireMs;
    if (ms == 0) {
      ms = job.kind == RELAY_KIND_WAND ? set.starMs : (job.kind == RELAY_KIND_PING ? set.pingMs : set.cmdMs);
    }
    const bool wake = job.kind == RELAY_KIND_BAND && program != RELAY_PROG_KEEP_AWAKE;
    if (wake && set.interleave) {
      const uint32_t slice = set.wakeMs;
      uint32_t cycles = ms / (2u * slice);
      if (cycles < 1) cycles = 1;
      job.wakeMs = slice;
      job.sendMs = slice;
      job.cyclesLeft = (uint16_t)(cycles - 1);
      beginPhase(RELAY_PHASE_WAKE, slice, now);
    } else if (wake) {
      job.wakeMs = set.wakeMs;
      job.sendMs = ms;
      beginPhase(RELAY_PHASE_WAKE, set.wakeMs, now);
    } else {
      job.sendMs = ms;  // wand, ping, or a band command under keep-awake: the packet alone
      beginPhase(RELAY_PHASE_SEND, ms, now);
    }
    noteStart(ms, wake);
  }

  void startRaw(const uint8_t* bytes, uint8_t len, uint16_t ms, bool replay, uint32_t now) {
    takeAir(RELAY_JOB_RAW, bytes, len, now);
    job.kind = RELAY_KIND_RAW;
    job.replay = replay;
    job.sendMs = ms;
    beginPhase(RELAY_PHASE_SEND, ms, now);
    noteStart(ms, false);
  }

  void startStream(uint32_t now) {
    takeAir(RELAY_JOB_STREAM, keepBytes, keepLen, now);
    job.kind = relayPacketKind(keepBytes, keepLen);
  }

  void startLoopBurst(uint32_t now) {
    const RelayLoop& l = loopFor(program);
    if (l.len == 0) {  // never: enabling a loop needs a packet
      program = RELAY_PROG_NONE;
      return;
    }
    startNormal(l.bytes, l.len, 0, program, now);
  }

  // The job's last phase ended: what comes next.
  void finishJob(uint32_t now) {
    const uint8_t endedLoop = job.loopOf;
    job.type = RELAY_JOB_NONE;
    job.loopOf = RELAY_PROG_NONE;
    if (slotFull) {  // the next replay step
      slotFull = false;
      startRaw(slotBytes, slotLen, slotMs, true, now);
      return;
    }
    if (program == RELAY_PROG_KEEP_AWAKE) {
      startStream(now);
      return;
    }
    if (loopRunning()) {
      // After its own burst (or a manual job that cut one short) the loop waits one interval;
      // after anything else a burst already due goes out now (service()).
      if (endedLoop == program || loopRearm) nextDue = now + loopFor(program).intervalMs;
      loopRearm = false;
    }
  }

  // ---- Commands from the phone ----------------------------------------------------------
  void apply(const ChipCmd& c, uint32_t now) {
    switch (c.type) {
      case RELAY_CMD_SEND:  // tap, transmit, vibrate, interrogate: the newest wins
        slotFull = false;
        startNormal(c.bytes, c.len, c.ms, RELAY_PROG_NONE, now);
        break;

      case RELAY_CMD_RAW:
        if ((c.flags & RELAY_CMDF_REPLAY) && job.type == RELAY_JOB_RAW && job.replay) {
          slotFull = true;  // behind the replay step on air (a newer one replaces it)
          slotLen = c.len;
          memcpy(slotBytes, c.bytes, c.len);
          slotMs = c.ms;
        } else {
          slotFull = false;
          startRaw(c.bytes, c.len, c.ms, (c.flags & RELAY_CMDF_REPLAY) != 0, now);
        }
        break;

      case RELAY_CMD_KEEP_AWAKE:
        if (c.flags & RELAY_CMDF_PACKET) {
          const bool changed = c.len != keepLen || memcmp(c.bytes, keepBytes, c.len) != 0;
          keepLen = c.len;
          memcpy(keepBytes, c.bytes, c.len);
          if (changed && job.type == RELAY_JOB_STREAM) startStream(now);  // restart with the new bytes
        }
        if (c.en) {
          program = RELAY_PROG_KEEP_AWAKE;  // a loop burst on air finishes, then the stream starts
          loopRearm = false;
          if (job.type == RELAY_JOB_NONE) startStream(now);
        } else if (program == RELAY_PROG_KEEP_AWAKE) {
          program = RELAY_PROG_NONE;
          if (job.type == RELAY_JOB_STREAM) job.type = RELAY_JOB_NONE;  // stops at once; a send in flight finishes
        }
        break;

      case RELAY_CMD_TX_LOOP:
      case RELAY_CMD_WAND_LOOP: {
        const uint8_t which = c.type == RELAY_CMD_TX_LOOP ? RELAY_PROG_TX_LOOP : RELAY_PROG_WAND_LOOP;
        RelayLoop& l = loopFor(which);
        if (c.flags & RELAY_CMDF_PACKET) {
          l.len = c.len;
          memcpy(l.bytes, c.bytes, c.len);
          l.label[0] = '\0';  // a new packet without a label has none
        }
        if (c.flags & RELAY_CMDF_LABEL) memcpy(l.label, c.label, sizeof(l.label));
        if (c.flags & RELAY_CMDF_INTERVAL) l.intervalMs = c.interval;
        if (c.en) {
          if (l.len == 0) break;
          if (job.type == RELAY_JOB_STREAM) job.type = RELAY_JOB_NONE;  // keep-awake stops at once
          program = which;
          nextDue = now;  // first burst as soon as the air is free
          loopRearm = false;
          job.loopOf = RELAY_PROG_NONE;  // a burst on air finishes without pushing that back
        } else if (program == which) {
          program = RELAY_PROG_NONE;  // the burst on air finishes and is not re-armed
        }
        break;
      }

      case RELAY_CMD_SET_WAKE:
        set.wakeMs = c.ms;
        break;
      case RELAY_CMD_SET_CMD:
        set.cmdMs = c.ms;
        break;
      case RELAY_CMD_SET_STAR:
        set.starMs = c.ms;
        break;
      case RELAY_CMD_SET_POWER:
        set.powerLevel = (uint8_t)(c.interval > 3 ? 3 : c.interval);
        break;
      case RELAY_CMD_SET_INTERLEAVE:
        set.interleave = c.en;
        break;
      default:
        break;
    }
  }

  // ---- Time -------------------------------------------------------------------------------
  // Ends phases that are over and starts what follows (the next phase, the replay slot, the
  // keep-awake stream, a loop burst that is due).
  void service(uint32_t now) {
    if (timedJob() && (int32_t)(now - job.phaseStart) >= (int32_t)job.phaseMs) {
      if (job.type == RELAY_JOB_NORMAL && job.phase == RELAY_PHASE_WAKE) {
        beginPhase(RELAY_PHASE_SEND, job.sendMs, now);
      } else if (job.type == RELAY_JOB_NORMAL && job.cyclesLeft > 0) {
        job.cyclesLeft--;
        beginPhase(RELAY_PHASE_WAKE, job.wakeMs, now);
      } else {
        finishJob(now);
      }
    }
    if (job.type == RELAY_JOB_NONE && loopRunning() && (int32_t)(now - nextDue) >= 0) startLoopBurst(now);
  }

  // How long until service() has something to do (RELAY_NO_DEADLINE: nothing timed).
  uint32_t msUntilDue(uint32_t now) const {
    int32_t d;
    if (timedJob()) {
      d = (int32_t)(job.phaseStart + job.phaseMs - now);
    } else if (job.type == RELAY_JOB_NONE && loopRunning()) {
      d = (int32_t)(nextDue - now);
    } else {
      return RELAY_NO_DEADLINE;
    }
    return d < 0 ? 0 : (uint32_t)d;
  }

  // What to advertise right now (nullptr: nothing).
  const uint8_t* airBytes(uint8_t* len) const {
    if (job.type == RELAY_JOB_NONE) {
      *len = 0;
      return nullptr;
    }
    if (job.type == RELAY_JOB_NORMAL && job.phase == RELAY_PHASE_WAKE) {
      *len = wakeLen;
      return wakeBytes;
    }
    *len = job.len;
    return job.bytes;
  }

  // Progress through the current phase of a timed job, 0..1000.
  uint16_t phasePermille(uint32_t now) const {
    if (!timedJob() || job.phaseMs == 0) return 1000;
    uint32_t done = now - job.phaseStart;
    if ((int32_t)done < 0) done = 0;
    if (done > job.phaseMs) done = job.phaseMs;
    return (uint16_t)((uint64_t)done * 1000u / job.phaseMs);
  }

  // STATUS fields owned by the engine (battery fields: none).
  void snapshot(RelaySnapshot& s) const {
    memset((void*)&s, 0, sizeof(s));
    s.program = program;
    s.intervalMs = loopIntervalMs();
    s.wakeMs = set.wakeMs;
    s.cmdMs = set.cmdMs;
    s.starMs = set.starMs;
    s.powerLevel = set.powerLevel;
    s.interleave = set.interleave;
    s.sent = sent;
    s.batMv = -1;
    s.batPct = -1;
    s.runMin = -1;
    if (program == RELAY_PROG_KEEP_AWAKE) {
      s.len = keepLen;
      memcpy(s.bytes, keepBytes, keepLen);
    } else if (loopRunning()) {
      const RelayLoop& l = loopFor(program);
      s.len = l.len;
      memcpy(s.bytes, l.bytes, l.len);
      memcpy(s.label, l.label, sizeof(s.label));
    }
  }
};
