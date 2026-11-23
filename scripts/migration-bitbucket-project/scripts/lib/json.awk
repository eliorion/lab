# json.awk - minimal JSON flattener (replaces jq; POSIX awk: gawk, mawk, BSD awk, busybox)
#
# Input : JSON tokens, one per line, as produced by
#           grep -Eo '"([^"\\]|\\.)*"|-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?|true|false|null|[][{}:,]'
# Output: one line per scalar value:   <path> TAB <kind> TAB <value>
#           kind  = s (string) | n (number) | b (boolean) | z (null)
#           path  = .version   .values[0].slug   .errors[1].message ...
#         Strings are unescaped (\n, \t, \uXXXX -> UTF-8); tabs/newlines become spaces.
# Run it with LC_ALL=C so that strings are handled as bytes.

function hexval(h,    i, c, v) {
  v = 0
  h = tolower(h)
  for (i = 1; i <= length(h); i++) {
    c = index("0123456789abcdef", substr(h, i, 1))
    if (c == 0) return -1
    v = v * 16 + c - 1
  }
  return v
}

function utf8(cp) {
  if (cp < 128) return sprintf("%c", cp)
  if (cp < 2048) return sprintf("%c%c", 192 + int(cp / 64), 128 + cp % 64)
  if (cp < 65536) return sprintf("%c%c%c", 224 + int(cp / 4096), 128 + int(cp / 64) % 64, 128 + cp % 64)
  return sprintf("%c%c%c%c", 240 + int(cp / 262144), 128 + int(cp / 4096) % 64, 128 + int(cp / 64) % 64, 128 + cp % 64)
}

function unescape(s,    out, i, c, n, cp, lo) {
  s = substr(s, 2, length(s) - 2)
  if (index(s, "\\") == 0) return s
  out = ""
  while ((i = index(s, "\\")) > 0) {
    out = out substr(s, 1, i - 1)
    c = substr(s, i + 1, 1)
    n = 2
    if (c == "n") out = out "\n"
    else if (c == "t") out = out "\t"
    else if (c == "r") out = out "\r"
    else if (c == "b") out = out "\b"
    else if (c == "f") out = out "\f"
    else if (c == "u") {
      cp = hexval(substr(s, i + 2, 4))
      n = 6
      if (cp >= 55296 && cp < 56320 && substr(s, i + 6, 2) == "\\u") {
        lo = hexval(substr(s, i + 8, 4))
        if (lo >= 56320 && lo < 57344) { cp = 65536 + (cp - 55296) * 1024 + (lo - 56320); n = 12 }
      }
      if (cp > 0) out = out utf8(cp)
    }
    else out = out c          # \"  \\  \/
    s = substr(s, i + n)
  }
  return out s
}

function path(    p, i) {
  p = ""
  for (i = 1; i <= d; i++) p = p (t[i] == "o" ? "." k[i] : "[" ix[i] "]")
  return p
}

function emit(kind, v) {
  gsub(/[\t\n\r]/, " ", v)
  printf "%s\t%s\t%s\n", path(), kind, v
}

BEGIN { d = 0; expect_key = 0 }

{
  tok = $0
  if (tok == "{") { d++; t[d] = "o"; k[d] = ""; expect_key = 1; next }
  if (tok == "[") { d++; t[d] = "a"; ix[d] = 0; next }
  if (tok == "}" || tok == "]") { d--; expect_key = 0; next }
  if (tok == ":") { expect_key = 0; next }
  if (tok == ",") { if (t[d] == "a") ix[d]++; else expect_key = 1; next }
  if (d > 0 && t[d] == "o" && expect_key) { k[d] = unescape(tok); expect_key = 0; next }
  if (substr(tok, 1, 1) == "\"") emit("s", unescape(tok))
  else if (tok == "true" || tok == "false") emit("b", tok)
  else if (tok == "null") emit("z", "")
  else emit("n", tok)
}
