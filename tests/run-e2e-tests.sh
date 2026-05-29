#!/usr/bin/env bash
#
# End-to-end (E2E) smoke suite: runs the REAL workflow with REAL tools (Comet,
# FILTER_PIN, Percolator) in their containers against the bundled test-data/.
# This is the tier the stub suite (tests/run-stub-tests.sh) cannot cover: stub
# blocks only `touch` outputs, so they prove wiring but never that a process
# script actually produces correct output. Here the tools really execute and we
# assert their output has real content (Comet made identifications, Percolator
# emitted peptides), not just that files exist.
#
# Scope (deliberately narrower than the stub matrix):
#   - input:     mzML only (MSCONVERT / the raw path is NOT exercised here)
#   - dispatch:  combined (process_separately=false) vs separate (true)
#   - files:     1 vs 3  -> 4 cases total
#   - NO Panorama, NO Limelight upload (those integrations need live services
#     and credentials; they stay covered by the stub suite's wiring checks).
#
# Usage:  tests/run-e2e-tests.sh
# Needs:  Java + Nextflow + a working Docker daemon (real containers run here).
#         No secrets (no Panorama / Limelight).
# Env:    NEXTFLOW_BIN  launcher to use (default: `nextflow` on PATH).
#         NXF_VER       pin a specific engine version (honored by the launcher).
#         NXF_HOME      Nextflow home (default: .test-tools/nxf-home, isolated
#                       from the user's ~/.nextflow).
# Exit:   0 if every check passes, non-zero = number of failed checks.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

NEXTFLOW="${NEXTFLOW_BIN:-nextflow}"

# Isolated, reproducible Nextflow state — deliberately NOT the user's
# ~/.nextflow. No secrets are needed: this suite runs neither Panorama nor
# Limelight, the only secret-consuming processes.
export NXF_HOME="${NXF_HOME:-$REPO_ROOT/.test-tools/nxf-home}"
mkdir -p "$NXF_HOME"

# Real containers run here, so a usable Docker daemon is mandatory. Fail loudly
# and early rather than letting Nextflow surface a cryptic mid-run error (this
# is the common gap on WSL2 without Docker Desktop integration).
if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker is not available/usable, but the E2E suite needs it to" >&2
    echo "       run the real tool containers. Start Docker and retry." >&2
    exit 1
fi

WORK_ROOT="$(mktemp -d)"
trap 'rm -rf "$WORK_ROOT"' EXIT

failures=0
current_case=""

# --- assertion helpers ------------------------------------------------------

assert_file() {  # assert_file <results_dir> <relative-path>
    if [[ -f "$1/$2" ]]; then
        echo "    ok: $2"
    else
        echo "    FAIL [$current_case]: expected published file missing: $2"
        failures=$((failures + 1))
    fi
}

assert_absent() {  # assert_absent <results_dir> <relative-path>
    if [[ ! -e "$1/$2" ]]; then
        echo "    ok: absent as expected: $2"
    else
        echo "    FAIL [$current_case]: should not exist for this case: $2"
        failures=$((failures + 1))
    fi
}

assert_nonempty() {  # assert_nonempty <results_dir> <relative-path>
    if [[ -s "$1/$2" ]]; then
        echo "    ok: non-empty: $2"
    else
        echo "    FAIL [$current_case]: missing or empty: $2"
        failures=$((failures + 1))
    fi
}

assert_min_lines() {  # assert_min_lines <results_dir> <relative-path> <min>
    local path="$1/$2" min="$3" n
    n=$(wc -l < "$path" 2>/dev/null || echo 0)
    if [[ "$n" -ge "$min" ]]; then
        echo "    ok: $2 has $n line(s) (>= $min)"
    else
        echo "    FAIL [$current_case]: $2 has $n line(s), expected >= $min"
        failures=$((failures + 1))
    fi
}

# Count matches of a fixed pattern and assert at least <min>. This is the check
# the stub suite can't do: it proves the real tool produced real content (Comet
# searched spectra and made hits; Percolator emitted peptides).
assert_grep_ge() {  # assert_grep_ge <results_dir> <relative-path> <pattern> <min>
    local path="$1/$2" pat="$3" min="$4" n
    n=$(grep -c -- "$pat" "$path" 2>/dev/null || echo 0)
    if [[ "$n" -ge "$min" ]]; then
        echo "    ok: $2 has $n match(es) of '$pat' (>= $min)"
    else
        echo "    FAIL [$current_case]: $2 has $n match(es) of '$pat', expected >= $min"
        failures=$((failures + 1))
    fi
}

# make_spectra <dir> <n>  — copies the first n REAL mzML files (test1..testN)
# into <dir>, preserving their basenames as sample_ids. Unlike the stub suite
# (which clones one placeholder), E2E needs genuine spectra so the tools have
# something real to identify. Only test1..test3 exist; n must be 1..3.
make_spectra() {
    local dir="$1" n="$2" i
    mkdir -p "$dir"
    for ((i = 1; i <= n; i++)); do
        cp "test-data/test${i}.mzML" "$dir/"
    done
}

# run_case <name> <nfiles> <separately>
run_case() {
    local name="$1" nfiles="$2" separately="$3"
    current_case="$name"
    local dir="$WORK_ROOT/$name"
    local spectra="$dir/spectra" results="$dir/results" cache="$dir/cache"
    mkdir -p "$dir"
    make_spectra "$spectra" "$nfiles"

    echo "=== $name  (files=$nfiles, separate=$separately) ==="
    if "$NEXTFLOW" -log "$dir/.nextflow.log" run main.nf \
        -c tests/e2e.config \
        --fasta test-data/test.fasta \
        --spectra_dir "$spectra" \
        --comet_params test-data/comet.params \
        --mzml_cache_directory "$cache" \
        -work-dir "$dir/work" \
        --result_dir "$results" \
        --report_dir "$dir/reports" \
        --process_separately "$separately" > "$dir/run.out" 2>&1; then
        echo "    pipeline exited 0"
    else
        echo "    FAIL [$name]: pipeline exited non-zero (see below)"
        sed 's/^/      | /' "$dir/run.out" | tail -30
        failures=$((failures + 1))
        return
    fi

    # Per-sample Comet + FILTER_PIN outputs, with real-content floors. Floors
    # are deliberately >=1 (not exact counts): they prove the tools did real
    # identification work without flaking on Percolator's run-to-run q-value
    # wobble or future test-data tweaks. For headroom context, the committed
    # test-data currently yields ~190 spectrum_query and ~85 search_hit per
    # Comet file, and 14-19 Percolator peptides per sample (43 combined); the
    # actual counts print below every run, so a collapse is still visible.
    local i s
    for ((i = 1; i <= nfiles; i++)); do
        s="test${i}"
        assert_nonempty "$results" "comet/${s}.pep.xml"
        # Comet searched spectra (spectrum_query) and made identifications (search_hit).
        assert_grep_ge  "$results" "comet/${s}.pep.xml" "spectrum_query" 1
        assert_grep_ge  "$results" "comet/${s}.pep.xml" "search_hit" 1
        # pin / filtered.pin are TSV: header + >=1 PSM row.
        assert_min_lines "$results" "comet/${s}.pin" 2
        assert_min_lines "$results" "percolator/${s}.filtered.pin" 2
    done

    if [[ "$separately" == "true" ]]; then
        # Per-sample Percolator output, each with real peptide results; no combined artifact.
        for ((i = 1; i <= nfiles; i++)); do
            s="test${i}"
            assert_nonempty "$results" "percolator/${s}.pout.xml"
            assert_grep_ge  "$results" "percolator/${s}.pout.xml" "<peptide " 1
        done
        assert_absent "$results" "percolator/combined.pout.xml"
        assert_absent "$results" "percolator/combined.filtered.pin"
    else
        # All samples collapse into one combined Percolator run.
        assert_nonempty "$results" "percolator/combined.filtered.pin"
        assert_nonempty "$results" "percolator/combined.pout.xml"
        assert_grep_ge  "$results" "percolator/combined.pout.xml" "<peptide " 1
        assert_absent   "$results" "percolator/test1.pout.xml"
    fi

    # No upload requested -> nothing published under limelight/.
    assert_absent "$results" "limelight"
}

# Matrix: dispatch mode x file count = 4 cases (mzML input, no upload).
run_case "combined_n1"  1  false
run_case "combined_n3"  3  false
run_case "separate_n1"  1  true
run_case "separate_n3"  3  true

echo
if [[ $failures -eq 0 ]]; then
    echo "All E2E smoke tests passed."
else
    echo "$failures check(s) failed."
fi
exit $failures
