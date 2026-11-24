// A tiny JSON reader for the host tests (C++17, std only): enough for tools/sync/vectors.json and
// transcripts/*.json. Numbers are kept as int64 when they are integers (every JSON integer in
// the vectors is within ±(2^53 − 1)); strings are decoded to UTF-8 (\uXXXX and surrogate pairs
// included). Objects keep their key order; equality ignores it.
//
// Host only: PlatformIO builds every source under the sketch folder, so this file is empty when
// ARDUINO is defined. (.hpp, not .h: the firmware workflow triggers on **.h.)
#pragma once
#ifndef ARDUINO

#include <cstdint>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace jmini {

struct Value {
  enum Type { NUL, BOOL, NUM, STR, ARR, OBJ };
  Type t = NUL;
  bool b = false;
  bool isInt = true;
  int64_t i = 0;
  double d = 0;
  std::string s;
  std::vector<Value> a;
  std::vector<std::pair<std::string, Value>> o;

  static Value null() { return Value(); }
  static Value boolean(bool v) {
    Value x;
    x.t = BOOL;
    x.b = v;
    return x;
  }
  static Value num(int64_t v) {
    Value x;
    x.t = NUM;
    x.i = v;
    x.d = (double)v;
    return x;
  }
  static Value str(const std::string& v) {
    Value x;
    x.t = STR;
    x.s = v;
    return x;
  }
  static Value arr() {
    Value x;
    x.t = ARR;
    return x;
  }
  static Value obj() {
    Value x;
    x.t = OBJ;
    return x;
  }

  bool isNull() const { return t == NUL; }

  const Value* find(const std::string& k) const {
    if (t != OBJ) return nullptr;
    for (const auto& kv : o)
      if (kv.first == k) return &kv.second;
    return nullptr;
  }
  bool has(const std::string& k) const { return find(k) != nullptr; }
  const Value& operator[](const std::string& k) const {
    const Value* v = find(k);
    if (!v) throw std::runtime_error("missing key: " + k);
    return *v;
  }
  const Value& operator[](size_t idx) const {
    if (t != ARR || idx >= a.size()) throw std::runtime_error("bad index");
    return a[idx];
  }
  size_t size() const { return t == ARR ? a.size() : (t == OBJ ? o.size() : 0); }

  int64_t asInt() const {
    if (t != NUM) throw std::runtime_error("not a number");
    return isInt ? i : (int64_t)d;
  }
  const std::string& asStr() const {
    if (t != STR) throw std::runtime_error("not a string");
    return s;
  }
  bool asBool() const {
    if (t != BOOL) throw std::runtime_error("not a bool");
    return b;
  }

  Value& set(const std::string& k, Value v) {
    for (auto& kv : o)
      if (kv.first == k) {
        kv.second = std::move(v);
        return kv.second;
      }
    o.emplace_back(k, std::move(v));
    return o.back().second;
  }
  Value& push(Value v) {
    a.push_back(std::move(v));
    return a.back();
  }
};

inline bool equal(const Value& x, const Value& y) {
  if (x.t != y.t) return false;
  switch (x.t) {
    case Value::NUL:
      return true;
    case Value::BOOL:
      return x.b == y.b;
    case Value::NUM:
      if (x.isInt && y.isInt) return x.i == y.i;
      return x.d == y.d;
    case Value::STR:
      return x.s == y.s;
    case Value::ARR:
      if (x.a.size() != y.a.size()) return false;
      for (size_t k = 0; k < x.a.size(); k++)
        if (!equal(x.a[k], y.a[k])) return false;
      return true;
    case Value::OBJ:
      if (x.o.size() != y.o.size()) return false;
      for (const auto& kv : x.o) {
        const Value* other = y.find(kv.first);
        if (!other || !equal(kv.second, *other)) return false;
      }
      return true;
  }
  return false;
}

inline void appendUtf8(std::string& out, uint32_t cp) {
  if (cp < 0x80) {
    out += (char)cp;
  } else if (cp < 0x800) {
    out += (char)(0xC0 | (cp >> 6));
    out += (char)(0x80 | (cp & 0x3F));
  } else if (cp < 0x10000) {
    out += (char)(0xE0 | (cp >> 12));
    out += (char)(0x80 | ((cp >> 6) & 0x3F));
    out += (char)(0x80 | (cp & 0x3F));
  } else {
    out += (char)(0xF0 | (cp >> 18));
    out += (char)(0x80 | ((cp >> 12) & 0x3F));
    out += (char)(0x80 | ((cp >> 6) & 0x3F));
    out += (char)(0x80 | (cp & 0x3F));
  }
}

class Parser {
 public:
  explicit Parser(const std::string& text) : s_(text), i_(0) {}

  Value parseDocument() {
    Value v = parseValue();
    ws();
    if (i_ != s_.size()) fail("trailing data");
    return v;
  }

 private:
  [[noreturn]] void fail(const char* what) {
    throw std::runtime_error(std::string("json: ") + what + " at offset " + std::to_string(i_));
  }
  void ws() {
    while (i_ < s_.size() && (s_[i_] == ' ' || s_[i_] == '\n' || s_[i_] == '\r' || s_[i_] == '\t'))
      i_++;
  }
  bool lit(const char* w) {
    size_t n = 0;
    while (w[n]) n++;
    if (s_.compare(i_, n, w) == 0) {
      i_ += n;
      return true;
    }
    return false;
  }
  uint32_t hex4() {
    if (i_ + 4 > s_.size()) fail("short \\u escape");
    uint32_t v = 0;
    for (int k = 0; k < 4; k++) {
      const char c = s_[i_++];
      v <<= 4;
      if (c >= '0' && c <= '9')
        v |= (uint32_t)(c - '0');
      else if (c >= 'a' && c <= 'f')
        v |= (uint32_t)(c - 'a' + 10);
      else if (c >= 'A' && c <= 'F')
        v |= (uint32_t)(c - 'A' + 10);
      else
        fail("bad \\u escape");
    }
    return v;
  }
  std::string parseString() {
    if (s_[i_] != '"') fail("expected string");
    i_++;
    std::string out;
    while (true) {
      if (i_ >= s_.size()) fail("unterminated string");
      const char c = s_[i_++];
      if (c == '"') break;
      if (c != '\\') {
        out += c;
        continue;
      }
      if (i_ >= s_.size()) fail("bad escape");
      const char e = s_[i_++];
      switch (e) {
        case '"':
          out += '"';
          break;
        case '\\':
          out += '\\';
          break;
        case '/':
          out += '/';
          break;
        case 'b':
          out += '\b';
          break;
        case 'f':
          out += '\f';
          break;
        case 'n':
          out += '\n';
          break;
        case 'r':
          out += '\r';
          break;
        case 't':
          out += '\t';
          break;
        case 'u': {
          uint32_t cp = hex4();
          if (cp >= 0xD800 && cp <= 0xDBFF) {
            if (i_ + 6 <= s_.size() && s_[i_] == '\\' && s_[i_ + 1] == 'u') {
              i_ += 2;
              const uint32_t lo = hex4();
              if (lo < 0xDC00 || lo > 0xDFFF) fail("bad surrogate pair");
              cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
            } else {
              fail("lone surrogate");
            }
          }
          appendUtf8(out, cp);
          break;
        }
        default:
          fail("bad escape");
      }
    }
    return out;
  }
  Value parseNumber() {
    const size_t start = i_;
    if (s_[i_] == '-') i_++;
    bool isInt = true;
    while (i_ < s_.size()) {
      const char c = s_[i_];
      if (c >= '0' && c <= '9') {
        i_++;
      } else if (c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-') {
        isInt = false;
        i_++;
      } else {
        break;
      }
    }
    const std::string tok = s_.substr(start, i_ - start);
    Value v;
    v.t = Value::NUM;
    if (isInt) {
      v.i = std::stoll(tok);
      v.d = (double)v.i;
    } else {
      v.isInt = false;
      v.d = std::stod(tok);
    }
    return v;
  }
  Value parseValue() {
    ws();
    if (i_ >= s_.size()) fail("unexpected end");
    const char c = s_[i_];
    if (c == '{') {
      i_++;
      Value v = Value::obj();
      ws();
      if (i_ < s_.size() && s_[i_] == '}') {
        i_++;
        return v;
      }
      while (true) {
        ws();
        std::string k = parseString();
        ws();
        if (i_ >= s_.size() || s_[i_] != ':') fail("expected ':'");
        i_++;
        v.o.emplace_back(std::move(k), parseValue());
        ws();
        if (i_ < s_.size() && s_[i_] == ',') {
          i_++;
          continue;
        }
        if (i_ < s_.size() && s_[i_] == '}') {
          i_++;
          return v;
        }
        fail("expected ',' or '}'");
      }
    }
    if (c == '[') {
      i_++;
      Value v = Value::arr();
      ws();
      if (i_ < s_.size() && s_[i_] == ']') {
        i_++;
        return v;
      }
      while (true) {
        v.a.push_back(parseValue());
        ws();
        if (i_ < s_.size() && s_[i_] == ',') {
          i_++;
          continue;
        }
        if (i_ < s_.size() && s_[i_] == ']') {
          i_++;
          return v;
        }
        fail("expected ',' or ']'");
      }
    }
    if (c == '"') return Value::str(parseString());
    if (lit("true")) return Value::boolean(true);
    if (lit("false")) return Value::boolean(false);
    if (lit("null")) return Value::null();
    if (c == '-' || (c >= '0' && c <= '9')) return parseNumber();
    fail("unexpected character");
  }

  const std::string& s_;
  size_t i_;
};

inline Value parse(const std::string& text) { return Parser(text).parseDocument(); }

inline Value parseFile(const std::string& path) {
  FILE* f = std::fopen(path.c_str(), "rb");
  if (!f) throw std::runtime_error("cannot open " + path);
  std::string text;
  char buf[65536];
  size_t n;
  while ((n = std::fread(buf, 1, sizeof(buf), f)) > 0) text.append(buf, n);
  std::fclose(f);
  return parse(text);
}

inline void escapeTo(std::string& out, const std::string& s) {
  out += '"';
  for (unsigned char c : s) {
    if (c == '"' || c == '\\') {
      out += '\\';
      out += (char)c;
    } else if (c < 0x20) {
      char b[8];
      std::snprintf(b, sizeof(b), "\\u%04x", c);
      out += b;
    } else {
      out += (char)c;
    }
  }
  out += '"';
}

// Compact serialisation, for failure messages.
inline std::string dump(const Value& v) {
  std::string out;
  switch (v.t) {
    case Value::NUL:
      return "null";
    case Value::BOOL:
      return v.b ? "true" : "false";
    case Value::NUM:
      if (v.isInt) return std::to_string(v.i);
      return std::to_string(v.d);
    case Value::STR:
      escapeTo(out, v.s);
      return out;
    case Value::ARR:
      out = "[";
      for (size_t k = 0; k < v.a.size(); k++) {
        if (k) out += ", ";
        out += dump(v.a[k]);
      }
      return out + "]";
    case Value::OBJ:
      out = "{";
      for (size_t k = 0; k < v.o.size(); k++) {
        if (k) out += ", ";
        escapeTo(out, v.o[k].first);
        out += ": ";
        out += dump(v.o[k].second);
      }
      return out + "}";
  }
  return out;
}

}  // namespace jmini

#endif  // ARDUINO
