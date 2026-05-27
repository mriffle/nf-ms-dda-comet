#!/usr/bin/env bash
#
# Stub-test harness: exercises channel wiring end-to-end with no real tools.
#
# Runs `nextflow -stub-run` across a matrix of:
#   - input type:           mzML (MSCONVERT skipped) vs raw (MSCONVERT runs)
#   - spectra file count:   1 file  vs  3 files
#   - dispatch mode:        combined (process_separately=false) vs separate (true)
#   - Limelight upload:     off vs on
# = 16 cases, plus AWS-profile cases below. For each, asserts exit 0 plus the
# *published* files that prove the wiring did the right thing for that
# combination. The presence/absence checks are what catch the silent
# combined-vs-separate divergence CLAUDE.md warns about, that COMET fans out per
# input file, and that the raw path runs MSCONVERT (mzML into the cache) while
# the mzML path skips it.
#
# Secret availability: the secret-consuming process stubs begin with a
# `: "${SECRET:?...}"` guard, so any upload case that exited 0 also proves the
# secret was injected into that process's environment (via the `secret`
# directive on the local executor). This does NOT cover the AWS Batch fetch
# path, which forces executor=local here and is never really executed.
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

# Secrets are now required only by the processes that declare the `secret`
# directive, and only when they actually run. Of the processes our matrix
# exercises, only the Limelight upload + AWS Limelight-bridge stubs run (upload
# cases), so only this key must exist in the store. PANORAMA_API_KEY is NOT
# seeded — no test runs a Panorama process — which proves it is not required
# for non-Panorama runs. Set the placeholder only when absent; never clobber.
ensure_secret() {
    if ! "$NEXTFLOW" secrets list 2>/dev/null | grep -qw "$1"; then
        "$NEXTFLOW" secrets set "$1" stub-placeholder >/dev/null 2>&1 || true
    fi
}
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

# make_spectra <dir> <n> <ext>  — n copies of test.mzML named sample1..sampleN.<ext>
# Stub runs never read spectra content, so copies with distinct basenames
# (= distinct sample_ids) are enough to exercise per-file fan-out. The extension
# (mzML or raw) is what makes main.nf route to MSCONVERT or not.
make_spectra() {
    local dir="$1" n="$2" ext="$3" i
    mkdir -p "$dir"
    for ((i = 1; i <= n; i++)); do
        cp test-data/test.mzML "$dir/sample${i}.${ext}"
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

# MSCONVERT writes sample.mzML to storeDir (the mzml cache), not result_dir.
assert_msconvert_ran() {  # <cache_dir> <sample_id>
    if [[ -f "$1/$2.mzML" ]]; then
        echo "    ok: MSCONVERT produced $2.mzML"
    else
        echo "    FAIL [$current_case]: MSCONVERT output missing from cache: $2.mzML"
        failures=$((failures + 1))
    fi
}

assert_msconvert_skipped() {  # <cache_dir>
    if compgen -G "$1/*.mzML" >/dev/null 2>&1; then
        echo "    FAIL [$current_case]: MSCONVERT ran for mzML input (cache holds *.mzML)"
        failures=$((failures + 1))
    else
        echo "    ok: MSCONVERT skipped (mzML input)"
    fi
}

# run_case <name> <nfiles> <separately> <upload> <input_type:mzml|raw> [profile]
run_case() {
    local name="$1" nfiles="$2" separately="$3" upload="$4" input_type="$5" profile="${6:-}"
    current_case="$name"
    local dir="$WORK_ROOT/$name"
    local spectra="$dir/spectra" results="$dir/results" cache="$dir/cache"
    mkdir -p "$dir"

    local ext="mzML"
    [[ "$input_type" == "raw" ]] && ext="raw"
    make_spectra "$spectra" "$nfiles" "$ext"

    local args=(--process_separately "$separately")
    [[ "$upload" == "true" ]] && args+=("${LIMELIGHT_ARGS[@]}")
    local profile_args=()
    [[ -n "$profile" ]] && profile_args=(-profile "$profile")

    echo "=== $name  (input=$input_type, files=$nfiles, separate=$separately, upload=$upload, profile=${profile:-default}) ==="
    if "$NEXTFLOW" -log "$dir/.nextflow.log" run main.nf -stub-run \
        -c tests/stub.config \
        "${profile_args[@]}" \
        --fasta test-data/test.fasta \
        --spectra_dir "$spectra" \
        --comet_params test-data/comet.params \
        --mzml_cache_directory "$cache" \
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

    # Raw input must run MSCONVERT (mzML into the cache, one per file); mzML
    # input must skip it. Either way COMET sees sampleN and names match below.
    local i
    if [[ "$input_type" == "raw" ]]; then
        for ((i = 1; i <= nfiles; i++)); do
            assert_msconvert_ran "$cache" "sample${i}"
        done
    else
        assert_msconvert_skipped "$cache"
    fi

    # COMET must fan out to one result per input file, regardless of mode.
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

    # AWS Secrets Manager bridge: runs ONLY under -profile aws and ONLY for a
    # secret the run actually needs. Our inputs are local files (no Panorama),
    # so only the Limelight bridge should appear, and only when uploading.
    if [[ "$profile" == "aws" && "$upload" == "true" ]]; then
        assert_file   "$results" "aws/aws-setup-LIMELIGHT_SUBMIT_UPLOAD_KEY.stdout"
        assert_absent "$results" "aws/aws-setup-PANORAMA_API_KEY.stdout"
    else
        assert_absent "$results" "aws"
    fi
}

# Full matrix: input type × file count × dispatch mode × upload = 16 cases
# (default profile, no AWS bridge).
for input_type in mzml raw; do
    for nfiles in 1 3; do
        for separately in false true; do
            for upload in false true; do
                mode=combined;  [[ "$separately" == "true" ]] && mode=separate
                up=noupload;    [[ "$upload" == "true" ]] && up=upload
                run_case "${input_type}_n${nfiles}_${mode}_${up}" \
                    "$nfiles" "$separately" "$upload" "$input_type"
            done
        done
    done
done

# AWS-path cases (-profile aws): exercise GET_AWS_USER_ID + BUILD_AWS_LIMELIGHT_SECRET
# and the limelight_secret_id threading into the upload. The no-upload case
# verifies the bridge does NOT run when no secret is needed.
#         name                          files separate upload input profile
run_case  "aws_combined_upload"           1   false    true   mzml  aws
run_case  "aws_separate_upload"           1   true     true   mzml  aws
run_case  "aws_separate_upload_n3"        3   true     true   mzml  aws
run_case  "aws_combined_noupload"         1   false    false  mzml  aws

echo
if [[ $failures -eq 0 ]]; then
    echo "All stub tests passed."
else
    echo "$failures check(s) failed."
fi
exit $failures
