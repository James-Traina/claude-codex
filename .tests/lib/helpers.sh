#!/usr/bin/env bash
set -euo pipefail

# assert_file_exists <path> [description]
assert_file_exists() {
  local path="$1"
  local desc="${2:-$path}"
  if [[ -f "$path" ]]; then
    pass "$desc exists"
  else
    fail "$desc missing: $path"
  fi
}

# assert_executable <path> [description]
assert_executable() {
  local path="$1"
  local desc="${2:-$path}"
  if [[ -x "$path" ]]; then
    pass "$desc is executable"
  else
    fail "$desc not executable: $path"
  fi
}

# assert_json_valid <path>
assert_json_valid() {
  local path="$1"
  if python3 -c "import json, sys; json.load(open('$path'))" 2>/dev/null; then
    pass "Valid JSON: $path"
  else
    fail "Invalid JSON: $path"
  fi
}

# assert_contains <file> <pattern> [description]
assert_contains() {
  local file="$1"
  local pattern="$2"
  local desc="${3:-$file contains '$pattern'}"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    pass "$desc"
  else
    fail "$desc"
  fi
}

# assert_shebang <file>
assert_shebang() {
  local file="$1"
  local first
  first=$(head -1 "$file")
  if [[ "$first" == "#!/usr/bin/env bash" ]]; then
    pass "Shebang OK: $(basename "$file")"
  else
    fail "Wrong shebang in $(basename "$file"): $first"
  fi
}
