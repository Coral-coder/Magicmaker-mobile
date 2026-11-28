// MagicMaker sync hub, phase P2 part 'db': Storage over the POSIX fd API (docs/SYNC_P2_FIRMWARE_PLAN.md
// §4.1, §4.11).
//
// One handle per file for its whole life (O_RDWR | O_APPEND), lseek + read for reads, write for
// appends, fsync for sync(), rename for promoteNew() (unlink + rename when the file system refuses
// to replace). It runs in the host tests on a temp directory and on the target over the LittleFS
// VFS (storage_littlefs.h mounts it and adds usage()). No Arduino header: newlib on the ESP32 has
// the same calls.
#pragma once

#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "hub_ports.h"

namespace mmsync {

class PosixStorage : public Storage {
 public:
  // baseDir: the directory that holds lib.log and lib.new (target: HUB_DIR_PATH). Created by
  // makeDir() (at mount) when it is missing.
  explicit PosixStorage(const char* baseDir) : totalForUsage_(0) {
    fd_[0] = fd_[1] = -1;
    size_[0] = size_[1] = 0;
    setBase(baseDir);
  }

  void setBase(const char* baseDir) {
    for (uint8_t f = 0; f < HUB_FILE_COUNT; f++) close(f);
    snprintf(base_, sizeof(base_), "%s", baseDir ? baseDir : "");
    snprintf(path_[HUB_FILE_LOG], sizeof(path_[0]), "%s/lib.log", base_);
    snprintf(path_[HUB_FILE_NEW], sizeof(path_[0]), "%s/lib.new", base_);
  }

  // mkdir of the base directory (fine when it exists).
  bool makeDir() {
    if (isDir(base_)) return true;
    return ::mkdir(base_, 0777) == 0 || errno == EEXIST;
  }

  // Host: the size usage() reports as total (0: usage() fails). The target overrides usage().
  void setUsageTotal(uint32_t totalBytes) { totalForUsage_ = totalBytes; }

  const char* path(uint8_t file) const { return file < HUB_FILE_COUNT ? path_[file] : ""; }

  // ---- Storage ---------------------------------------------------------------------------------
  bool mounted() override { return isDir(base_); }

  bool exists(uint8_t file) override {
    if (file >= HUB_FILE_COUNT) return false;
    if (fd_[file] >= 0) return true;
    struct stat stt;
    return ::stat(path_[file], &stt) == 0;
  }

  bool open(uint8_t file, bool create) override {
    if (file >= HUB_FILE_COUNT) return false;
    if (fd_[file] >= 0) return true;
    const int fd = ::open(path_[file], O_RDWR | O_APPEND | (create ? O_CREAT : 0), 0666);
    if (fd < 0) return false;
    const off_t end = ::lseek(fd, 0, SEEK_END);
    if (end < 0) {
      ::close(fd);
      return false;
    }
    fd_[file] = fd;
    size_[file] = (uint32_t)end;
    return true;
  }

  void close(uint8_t file) override {
    if (file >= HUB_FILE_COUNT || fd_[file] < 0) return;
    ::close(fd_[file]);
    fd_[file] = -1;
  }

  int32_t size(uint8_t file) override {
    if (file >= HUB_FILE_COUNT || fd_[file] < 0) return -1;
    return (int32_t)size_[file];
  }

  int32_t read(uint8_t file, uint32_t off, uint8_t* buf, uint32_t n) override {
    if (file >= HUB_FILE_COUNT || fd_[file] < 0) return -1;
    if (off >= size_[file] || n == 0) return 0;
    if (n > size_[file] - off) n = size_[file] - off;
    if (::lseek(fd_[file], (off_t)off, SEEK_SET) < 0) return -1;
    uint32_t got = 0;
    while (got < n) {
      const ssize_t r = ::read(fd_[file], buf + got, n - got);
      if (r < 0) {
        if (errno == EINTR) continue;
        return got ? (int32_t)got : -1;
      }
      if (r == 0) break;
      got += (uint32_t)r;
    }
    return (int32_t)got;
  }

  bool append(uint8_t file, const uint8_t* data, uint32_t n) override {
    if (file >= HUB_FILE_COUNT || fd_[file] < 0) return false;
    uint32_t done = 0;
    while (done < n) {
      const ssize_t w = ::write(fd_[file], data + done, n - done);
      if (w < 0 && errno == EINTR) continue;
      if (w <= 0) {
        refreshSize(file);  // a partial write: the caller re-reads size()
        return false;
      }
      done += (uint32_t)w;
    }
    size_[file] += n;
    return true;
  }

  bool sync(uint8_t file) override {
    if (file >= HUB_FILE_COUNT || fd_[file] < 0) return false;
    return ::fsync(fd_[file]) == 0;
  }

  bool remove(uint8_t file) override {
    if (file >= HUB_FILE_COUNT) return false;
    close(file);
    return ::unlink(path_[file]) == 0 || errno == ENOENT;
  }

  bool promoteNew() override {
    close(HUB_FILE_LOG);
    close(HUB_FILE_NEW);
    if (::rename(path_[HUB_FILE_NEW], path_[HUB_FILE_LOG]) == 0) return true;
    if (errno != EEXIST && errno != EACCES && errno != EPERM && errno != ENOTEMPTY) return false;
    // A VFS that does not replace: remove, then rename (boot recovery covers "lib.new only").
    if (::unlink(path_[HUB_FILE_LOG]) != 0 && errno != ENOENT) return false;
    return ::rename(path_[HUB_FILE_NEW], path_[HUB_FILE_LOG]) == 0;
  }

  // Host: totalForUsage_ and the two files rounded up to 4 KB blocks (+ 2 metadata blocks).
  bool usage(uint32_t* totalBytes, uint32_t* usedBytes) override {
    if (!totalForUsage_) return false;
    uint32_t used = 2u * 4096u;
    for (uint8_t f = 0; f < HUB_FILE_COUNT; f++) {
      struct stat stt;
      if (::stat(path_[f], &stt) == 0) used += ((uint32_t)stt.st_size + 4095u) / 4096u * 4096u;
    }
    *totalBytes = totalForUsage_;
    *usedBytes = used;
    return true;
  }

  bool wipe() override {
    const bool a = remove(HUB_FILE_LOG);
    const bool b = remove(HUB_FILE_NEW);
    return a && b;
  }

  // Not virtual (the ports are never deleted through a base pointer); public so the sketch and the
  // tests can own an instance.
  ~PosixStorage() {
    for (uint8_t f = 0; f < HUB_FILE_COUNT; f++) close(f);
  }

 private:
  char base_[96];
  char path_[HUB_FILE_COUNT][112];
  int fd_[HUB_FILE_COUNT];
  uint32_t size_[HUB_FILE_COUNT];
  uint32_t totalForUsage_;

  static bool isDir(const char* p) {
    struct stat stt;
    return p[0] && ::stat(p, &stt) == 0 && S_ISDIR(stt.st_mode);
  }

  void refreshSize(uint8_t file) {
    const off_t end = ::lseek(fd_[file], 0, SEEK_END);
    if (end >= 0) size_[file] = (uint32_t)end;
  }
};

}  // namespace mmsync
