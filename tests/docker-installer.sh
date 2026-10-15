#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT
export TEST_LOG="$test_dir/commands.log"
# No real package installs or system mutations: fail apt and record every attempted command.
cat > "$test_dir/sudo" <<'MOCK'
#!/bin/bash
echo "$*" >> "$TEST_LOG"
exit 42
MOCK
chmod +x "$test_dir/sudo"
if PATH="$test_dir:$PATH" bash "$repo_root/docker-ce/install-docker-ce.sh"; then
    echo 'Installer ignored apt failure' >&2
    exit 1
fi
test "$(wc -l < "$TEST_LOG")" -eq 1
echo 'Installer stopped after first failed command.'

# A successful gpg command must not hide a failed curl in the signing-key pipeline.
cat > "$test_dir/sudo" <<'MOCK'
#!/bin/bash
echo "$*" >> "$TEST_LOG"
if [ "$1" = gpg ]; then cat >/dev/null; fi
exit 0
MOCK
cat > "$test_dir/curl" <<'MOCK'
#!/bin/bash
exit 22
MOCK
chmod +x "$test_dir/curl"
: > "$TEST_LOG"
if PATH="$test_dir:$PATH" bash "$repo_root/docker-ce/install-docker-ce.sh"; then
    echo 'Installer ignored signing-key download failure' >&2
    exit 1
fi
test "$(wc -l < "$TEST_LOG")" -eq 3
echo 'Installer rejected a failed signing-key pipeline.'
