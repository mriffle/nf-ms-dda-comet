#!/usr/bin/env bash
#
# Installs the Nextflow versions listed in tests/nextflow-versions.txt into a
# project-local, gitignored .test-tools/ tree so the stub suite can run against
# each. Idempotent: re-run after editing the version list to fetch new engines.
#
# Layout (all under .test-tools/, never committed):
#   bin/nextflow   the launcher (version-agnostic; NXF_VER picks the engine)
#   nxf-home/      NXF_HOME — engine jars cached here, one per version
#
# Usage:  tests/setup-nextflow.sh
# Needs:  Java + curl + internet. Run once per machine (and after version bumps).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$REPO_ROOT/.test-tools"
BIN_DIR="$TOOLS_DIR/bin"
export NXF_HOME="$TOOLS_DIR/nxf-home"

mkdir -p "$BIN_DIR" "$NXF_HOME"

mapfile -t VERSIONS < <(grep -vE '^[[:space:]]*(#|$)' "$REPO_ROOT/tests/nextflow-versions.txt")
if [[ ${#VERSIONS[@]} -eq 0 ]]; then
    echo "No versions listed in tests/nextflow-versions.txt" >&2
    exit 1
fi

if [[ ! -x "$BIN_DIR/nextflow" ]]; then
    echo "Installing Nextflow launcher into $BIN_DIR ..."
    ( cd "$BIN_DIR" && curl -fsSL https://get.nextflow.io | bash )
fi

for v in "${VERSIONS[@]}"; do
    echo "Fetching Nextflow engine $v ..."
    NXF_VER="$v" "$BIN_DIR/nextflow" -version > /dev/null
done

echo "Done. Installed versions: ${VERSIONS[*]}"
echo "Run the suite against all of them with: tests/run-stub-tests-all.sh"
