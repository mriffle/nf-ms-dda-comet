#!/usr/bin/env bash
#
# Runs the full stub suite (tests/run-stub-tests.sh) against every Nextflow
# version listed in tests/nextflow-versions.txt, using the project-local
# installs created by tests/setup-nextflow.sh. Reports a per-version summary
# and exits non-zero if any version fails.
#
# Usage:  tests/run-stub-tests-all.sh   (run tests/setup-nextflow.sh first)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$REPO_ROOT/.test-tools"
LAUNCHER="$TOOLS_DIR/bin/nextflow"
export NXF_HOME="$TOOLS_DIR/nxf-home"

if [[ ! -x "$LAUNCHER" ]]; then
    echo "Nextflow not installed locally. Run tests/setup-nextflow.sh first." >&2
    exit 1
fi

mapfile -t VERSIONS < <(grep -vE '^[[:space:]]*(#|$)' "$REPO_ROOT/tests/nextflow-versions.txt")

declare -a results
overall=0
for v in "${VERSIONS[@]}"; do
    echo
    echo "########## Nextflow $v ##########"
    if NEXTFLOW_BIN="$LAUNCHER" NXF_VER="$v" "$REPO_ROOT/tests/run-stub-tests.sh"; then
        results+=("  $v: PASS")
    else
        results+=("  $v: FAIL")
        overall=1
    fi
done

echo
echo "===== Summary ====="
printf '%s\n' "${results[@]}"
exit $overall
