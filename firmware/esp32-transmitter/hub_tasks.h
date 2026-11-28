// MagicMaker sync hub, phase P2: TaskTable, the production Scheduler of the hub node
// (docs/SYNC_P2_FIRMWARE_PLAN.md §5.12; the port is hub_ports.h Scheduler).
//
// A fixed table of HUB_TASKS_MAX deferred tasks: session timers, the HB round, the flush timer,
// drains, deadlines, TX retries. at() replaces a pending entry with the same (kind, link, arg)
// (a re-armed timer makes the older one a no-op anyway) and stamps an insertion counter, so
// popDue() returns due tasks in (due, insertion) order like the transcript simulation's event
// queue. Times are mono ms that wrap: every comparison is relative to `now`.
//
// Pure C++11, no heap, no Arduino dependency.
#pragma once

#include "hub_ports.h"

namespace mmsync {

static const uint8_t HUB_TASKS_MAX = 48;

class TaskTable : public Scheduler {
 public:
  TaskTable() { clear(); }

  void clear() {
    memset(items_, 0, sizeof(items_));
    counter_ = 0;
  }

  bool at(const HubTask& task) override {
    int free = -1;
    for (uint8_t i = 0; i < HUB_TASKS_MAX; i++) {
      Item& it = items_[i];
      if (!it.used) {
        if (free < 0) free = i;
        continue;
      }
      if (it.task.kind == task.kind && it.task.link == task.link && it.task.arg == task.arg) {
        it.task = task;
        it.order = ++counter_;
        return true;
      }
    }
    if (free < 0) return false;
    items_[free].used = true;
    items_[free].task = task;
    items_[free].order = ++counter_;
    return true;
  }

  bool popDue(uint32_t now, HubTask* out) override {
    int best = -1;
    int32_t bestRel = 0;
    for (uint8_t i = 0; i < HUB_TASKS_MAX; i++) {
      const Item& it = items_[i];
      if (!it.used) continue;
      const int32_t rel = (int32_t)(it.task.due - now);
      if (rel > 0) continue;
      if (best < 0 || rel < bestRel || (rel == bestRel && orderBefore(it.order, items_[best].order))) {
        best = i;
        bestRel = rel;
      }
    }
    if (best < 0) return false;
    *out = items_[best].task;
    items_[best].used = false;
    return true;
  }

  uint32_t nextDueMs(uint32_t now) override {
    bool any = false;
    int32_t best = 0;
    for (uint8_t i = 0; i < HUB_TASKS_MAX; i++) {
      if (!items_[i].used) continue;
      const int32_t rel = (int32_t)(items_[i].task.due - now);
      if (!any || rel < best) {
        best = rel;
        any = true;
      }
    }
    if (!any) return HUB_NO_DEADLINE;
    return best <= 0 ? 0 : (uint32_t)best;
  }

  // Drops every pending task of one kind (and link, unless link is 0xFF = any).
  void cancel(uint8_t kind, uint8_t link) {
    for (uint8_t i = 0; i < HUB_TASKS_MAX; i++) {
      if (items_[i].used && items_[i].task.kind == kind && (link == 0xFF || items_[i].task.link == link))
        items_[i].used = false;
    }
  }

  uint8_t size() const {
    uint8_t n = 0;
    for (uint8_t i = 0; i < HUB_TASKS_MAX; i++)
      if (items_[i].used) n++;
    return n;
  }

 private:
  struct Item {
    bool used;
    uint32_t order;
    HubTask task;
  };

  // Insertion order survives the 32-bit counter wrap (2^31 inserts apart at most).
  static bool orderBefore(uint32_t a, uint32_t b) { return (int32_t)(a - b) < 0; }

  Item items_[HUB_TASKS_MAX];
  uint32_t counter_;
};

}  // namespace mmsync
