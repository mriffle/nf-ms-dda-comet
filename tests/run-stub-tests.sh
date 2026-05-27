#!/usr/bin/env bash
#
# Stub-test harness: exercises channel wiring end-to-end with no real tools.
#
# Runs `nextflow -stub-run` across a matrix of:
#   - spectra file count:   1 file  vs  3 files
#   - dispatch mode:        combined (process_separately=false) vs separate (true)
#   - Limelight upload:     off vs on
# = 8 cases. For each, asserts exit 0 plus the *published* files that prove the
# wiring did the right thing for that combination. The presence/absence checks
# are what catch the silent combined-vs-separate divergence CLAUDE.md warns
# about, and that COMET fans out per input file.
#
# Usage:  tests/run-stub-tests.sh
# Needs:  Java + Nextflow. No Docker, no secrets.
# Env:    NEXTFLOW_BIN  launcher to use (default: `nextflow` on PATH).
#         NXF_VER       pin a specific engine version (honored by the launcher).
#         NXF_HOME      Nextflow home (default: .test-tools/nxf-home, isolated
#                       from the user's ~/.nextflow). Placeholder secrets are
#                       seeded here automatically.
#         tests/run-stub-tests-all.sh sets these to run the suite across versions.
# Exit:   0 if every check passes, non-zero = number of failed checks.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

NEXTFLOW="${NEXTFLOW_BIN:-nextflow}"

# Isolated, reproducible Nextflow state — deliberately NOT the user's
# ~/.nextflow, so real secrets/plugins are untouched and runs are repeatable.
export NXF_HOME="${NXF_HOME:-$REPO_ROOT/.test-tools/nxf-home}"
mkdir -p "$NXF_HOME"

# nextflow.config is written in legacy (v1) config syntax — a chained
# assignment (line 57) and a check_max() function def — that Nextflow 26's
# strict default parser rejects. Force the legacy parser so the suite runs the
# pipeline on both 25 and 26 engines. (v1 is already the default on 25.)
# Migrating the config to v2 syntax is a tracked follow-up — see CLAUDE.md §6.
export NXF_SYNTAX_PARSER=v1

# nextflow.config resolves SecretsLoader at parse time, so these secrets must
# exist even for stub runs (CLAUDE.md §6 footgun) — otherwise the config fails
# with a misleading "Unknown config attribute `secret_value`". Set placeholders
# only when absent; never clobber a real value.
ensure_secret() {
    if ! "$NEXTFLOW" secrets list 2>/dev/null | grep -qw "$1"; then
        "$NEXTFLOW" secrets set "$1" stub-placeholder >/dev/null 2>&1 || true
    fi
}
ensure_secret PANORAMA_API_KEY
ensure_secret LIMELIGHT_SUBMIT_UPLOAD_KEY

WORK_ROOT="$(mktemp -d)"
trap 'rm -rf "$WORK_ROOT"' EXIT

failures=0
current_case=""

# Limelight val params Nextflow requires (non-null) once upload is enabled.
# Real values don't matter in stub mode — the upload process just touches outputs.
LIMELIGHT_ARGS=(
    --limelight_upload true
    --limelight_webapp_url https://limelight.example.org
    --limelight_project_id 1
    --limelight_search_description "stub test"
    --limelight_search_short_name stubtest
    --limelight_tags ci
)

# make_spectra <dir> <n>  — n copies of test.mzML named sample1..sampleN.mzML
# Stub runs never read spectra content, so copies with distinct basenames
# (= distinct sample_ids) are enough to exercise per-file fan-out.
make_spectra() {
    local dir="$1" n="$2" i
    mkdir -p "$dir"
    for ((i = 1; i <= n; i++)); do
        cp test-data/test.mzML "$dir/sample${i}.mzML"
    done
}

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

# run_case <name> <nfiles> <separately:true|false> <upload:true|false>
run_case() {
    local name="$1" nfiles="$2" separately="$3" upload="$4"
    current_case="$name"
    local dir="$WORK_ROOT/$name"
    local spectra="$dir/spectra" results="$dir/results"
    mkdir -p "$dir"
    make_spectra "$spectra" "$nfiles"

    local args=(--process_separately "$separately")
    [[ "$upload" == "true" ]] && args+=("${LIMELIGHT_ARGS[@]}")

    echo "=== $name  (files=$nfiles, separate=$separately, upload=$upload) ==="
    if "$NEXTFLOW" -log "$dir/.nextflow.log" run main.nf -stub-run \
        -c tests/stub.config \
        --fasta test-data/test.fasta \
        --spectra_dir "$spectra" \
        --comet_params test-data/comet.params \
        -work-dir "$dir/work" \
        --result_dir "$results" \
        --report_dir "$dir/reports" \
        "${args[@]}" > "$dir/run.out" 2>&1; then
        echo "    pipeline exited 0"
    else
        echo "    FAIL [$name]: pipeline exited non-zero (see below)"
        sed 's/^/      | /' "$dir/run.out" | tail -25
        failures=$((failures + 1))
        return
    fi

    # COMET must fan out to one result per input file, regardless of mode.
    local i
    for ((i = 1; i <= nfiles; i++)); do
        assert_file "$results" "comet/sample${i}.pep.xml"
        assert_file "$results" "comet/sample${i}.pin"
    done

    if [[ "$separately" == "true" ]]; then
        # Per-sample Percolator; no combined artifact.
        for ((i = 1; i <= nfiles; i++)); do
            assert_file "$results" "percolator/sample${i}.pout.xml"
        done
        assert_absent "$results" "percolator/combined.pout.xml"
    else
        # All samples collapse into one combined Percolator run.
        assert_file "$results" "percolator/combined.pout.xml"
        assert_file "$results" "percolator/combined.filtered.pin"
        assert_absent "$results" "percolator/sample1.pout.xml"
    fi

    if [[ "$upload" == "true" && "$separately" == "true" ]]; then
        # One Limelight XML + one upload per sample.
        for ((i = 1; i <= nfiles; i++)); do
            assert_file "$results" "limelight/sample${i}.limelight.xml"
            assert_file "$results" "limelight/sample${i}.limelight-submit-upload.stdout"
        done
    elif [[ "$upload" == "true" ]]; then
        # Combined: a single merged Limelight XML + single upload.
        assert_file "$results" "limelight/results.limelight.xml"
        assert_file "$results" "limelight/limelight-submit-upload.stdout"
    else
        # No upload requested → nothing published under limelight/.
        assert_absent "$results" "limelight"
    fi
}

#         name                       files  separate  upload
run_case  "n1_combined_noupload"        1   false     false
run_case  "n1_combined_upload"          1   false     true
run_case  "n1_separate_noupload"        1   true      false
run_case  "n1_separate_upload"          1   true      true
run_case  "n3_combined_noupload"        3   false     false
run_case  "n3_combined_upload"          3   false     true
run_case  "n3_separate_noupload"        3   true      false
run_case  "n3_separate_upload"          3   true      true

echo
if [[ $failures -eq 0 ]]; then
    echo "All stub tests passed."
else
    echo "$failures check(s) failed."
fi
exit $failures
