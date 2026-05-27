# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This is the **onboarding document for every agent** working in this repo. Read it before doing anything else. It covers what the project is, how it's architected, how it's coded, and the rules you must follow when making changes.

## Keep this document current

**CLAUDE.md is the source of truth for coding conventions in this repo.** Whenever a convention is added, removed, or changed — whether by the user telling you a new rule, or by you and the user agreeing on one during a session — update this file in the same change. If you find an existing rule here that turns out to be wrong or out of date, fix it here, not just in code. An undocumented convention is one that will be broken by the next agent.

When the user says "from now on, always X" or "stop doing Y", that's a rule change: edit this file before (or alongside) the code change.

---

## 1. What this project is

A **Nextflow (DSL2) pipeline for Data-Dependent Acquisition (DDA) mass-spectrometry proteomics**. Given vendor `.raw` (or pre-converted `.mzML`) spectra and a FASTA, it runs peptide identification with [Comet](https://uwpr.github.io/Comet/), post-processes with [Percolator](https://github.com/percolator/percolator), and optionally uploads to [Limelight](https://limelight-ms.org/). Inputs and outputs may live on the local filesystem or in [PanoramaWeb](https://panoramaweb.org/) — any path beginning with `https://` is treated as a PanoramaWeb WebDAV URL and downloaded automatically.

- End-user documentation (install, run, parameters, AWS Batch): https://nf-ms-dda-comet.readthedocs.io/
- Source-tree map and per-file purpose: `README.md`
- Funded by IARPA via the TEI-REX program.

Don't duplicate user-facing instructions in this file — point users at the docs site instead.

## 2. Architecture in 60 seconds

```
main.nf  --(dispatch on params.process_separately)-->  workflows/comet_{combined,separate}_percolator.nf
                                                            |
                       MSCONVERT (if .raw)  ->  COMET  ->  FILTER_PIN  ->  ...
                                                            |
                       combined:  COMBINE_PIN_FILES -> PERCOLATOR (once)  -> upload (1 search)
                       separate:                       PERCOLATOR (per sample) -> upload (1 search/sample)
```

Three things to internalize:

1. **`main.nf` is a dispatcher, not a worker.** It resolves inputs (local path vs. PanoramaWeb URL by `startsWith("https://")`), sniffs the spectra directory for `*.mzML` then falls back to `*.raw`, sets a `from_raw_files` flag, and dispatches to one of two sub-workflows. Input-handling changes go here; processing changes go in `workflows/` or `modules/`.

2. **The combined-vs-separate fork is the central architectural choice.** Both sub-workflows share msconvert → Comet → filter_pin, then diverge at Percolator. Each path has its own `limelight_xml_convert_*` and `limelight_upload_*` module (~95% duplicated). If you edit one, check whether the other needs the same edit — silent divergence between the pair is a real risk.

3. **`(sample_id, file)` tuples carry sample identity through the DAG.** `sample_id = mzml_file.baseName`. The separate sub-workflow uses `.join()` on this key to re-pair pepXML + pout + mzML for upload. Break the tuple shape and downstream joins fail silently — commit `4e45147` is a real bug caused by exactly that.

## 3. Commands

There is no build or lint step. Tests are stub-only for now (see below). "Running the code for real" means running Nextflow against test data.

```bash
# One-time per machine (and after bumping tests/nextflow-versions.txt):
# install every pinned Nextflow version into a local, gitignored .test-tools/
# tree. Needs Java + curl + internet.
./tests/setup-nextflow.sh

# Stub-test harness across ALL pinned Nextflow versions — what CI runs on push.
# For each version runs the inner harness below; exits non-zero if any fails.
./tests/run-stub-tests-all.sh

# Inner stub harness (one Nextflow version — whatever NEXTFLOW_BIN/NXF_VER point
# at, else `nextflow` on PATH). The canonical wiring check: -stub-run across a
# 16-case matrix (mzML vs raw input × 1 vs 3 spectra files × combined vs separate
# × Limelight upload on/off) against test-data/, asserting the published outputs
# that distinguish each combination (raw runs MSCONVERT into the mzml cache while
# mzML skips it, per-file COMET fan-out, combined vs per-sample Percolator, single
# vs per-sample Limelight XML). Fixtures (mzML/raw, 1 or 3 files) are generated at
# runtime by copying test.mzML — nothing large is committed. No Docker. Uses an
# isolated NXF_HOME under .test-tools/ and seeds placeholder secrets there, so
# it neither needs nor touches your real ~/.nextflow. Run after any change to
# channel topology in main.nf or workflows/.
./tests/run-stub-tests.sh

# Manual single-mode stub run (what the harness wraps), if you want the raw
# Nextflow invocation. Uses every process's stub: block; no real tools execute.
nextflow run main.nf -stub-run -c tests/stub.config --fasta test-data/test.fasta \
    --spectra_dir test-data --comet_params test-data/comet.params

# Real smoke run against bundled test data (no Limelight upload).
nextflow run main.nf --fasta test-data/test.fasta \
    --spectra_dir test-data --comet_params test-data/comet.params

# Useful flags: -resume (reuse cached work), -profile slurm,
#               --process_separately true (exercise the separate path).

# Build user docs locally (Sphinx, sphinx_rtd_theme).
cd docs && pip install -r requirements.txt && make html
# Output: docs/build/html/index.html
```

**`-stub-run` still launches Docker containers.** Nextflow doesn't skip containers in stub mode — it just swaps the script body. `tests/stub.config` disables Docker (`docker.enabled = false`, `process.container = null`) so stub runs work on any host with just Java + Nextflow — that's why CI needs no Docker. It also sets `process.resourceLimits` (the `cpus`/`memory`/`time` cap that clamps every label — COMET's `process_high_constant` would otherwise demand far more cores than a GitHub runner has). **Keep `cpus <= 4` there** — CI runners are small. Pass it with `-c tests/stub.config` whenever Docker isn't available (e.g., WSL2 without Docker Desktop integration); the harness already does.

To also exercise the PanoramaWeb stubs without real network, add `params.mzml_cache_directory` and `params.panorama_cache_directory` overrides pointing at writable local paths, and pass any `https://`-prefixed string for `--fasta` / `--spectra_dir` / `--comet_params` — the URL is parsed by `file().name` but never fetched in stub mode.

Two secrets are read from `nextflow.secret` and re-exported into the process env (see `nextflow.config:56-65`):

```bash
nextflow secrets set PANORAMA_API_KEY "..."              # required even as a placeholder
nextflow secrets set LIMELIGHT_SUBMIT_UPLOAD_KEY "..."   # required if uploading
```

## 4. Coding conventions — required when adding or editing processes

Every existing module follows the rules below. New or modified processes must too.

### 4.1 Containers
- `container params.images.<key>` — **never** hard-code an image string in a module.
- Add or bump versions only in `container_images.config`. This is the single source of truth for what tools we run and at which version.

### 4.2 Resources
- Apply a resource `label` (`process_low`, `process_medium`, `process_high`, `process_long`, `process_high_memory`, and the `*_constant` variants). **Never** set `cpus`, `memory`, or `time` inline in a module.
- All resource tiers live in `conf/base.config` as `withLabel:` blocks. If you need a new tier, add it there, don't define it ad hoc.
- Resource values scale with `task.attempt`. Each tier states its raw desired amount (e.g. `{ 32 * task.attempt }`); the `process.resourceLimits` map automatically caps every request. The cap is set as a **literal map** — a default in `conf/base.config`, overridden per execution profile in `nextflow.config` (`standard`/`slurm`/`aws`) and in `tests/stub.config`. **Never** drive `resourceLimits` from `params` (e.g. `[cpus: params.max_cpus]`): it is evaluated eagerly at config-parse time, so a `-c`-supplied override (the user's copied `pipeline.config`, or `stub.config`) merges too late and is silently ignored — this was a real bug during the migration, see §6. A direct `process.resourceLimits = [...]` assignment merges last-wins and overrides cleanly. **Don't** reintroduce the old `check_max()` helper — it was a config-level function def that the Nextflow-26 strict parser rejects (§6). `resourceLimits` requires Nextflow ≥24.04; the manifest floor is higher (`!>=25.10.0`), set by the nf-schema plugin (§4.12, §6).

### 4.3 Logging and exit handling
- Wrap every CLI invocation in `> >(tee X.stdout) 2> >(tee X.stderr >&2)`.
- Declare both `*.stdout` and `*.stderr` as outputs (`emit: stdout`, `emit: stderr`).
- End the script with `echo "Done!"` — this defeats pipefail on the `tee` redirections. Don't skip it.

### 4.4 Java / JAR processes
- Define `def exec_java_command(mem)` at the top of the module file (canonical shape in `modules/filter_pin.nf:1-4`).
- Use `${exec_java_command(task.memory)}` to invoke the JAR. This pattern reserves 1 GiB for JVM overhead via `-Xmx${mem.toGiga()-1}G`.

### 4.5 Channel shape
- Per-sample channels carry `tuple(sample_id, file)` where `sample_id = file.baseName`.
- Preserve this shape end-to-end. If a process needs to fan out or join, do it on `sample_id`.
- When you collapse to a single combined artifact (e.g. `COMBINE_PIN_FILES`), use the literal string `"combined"` as the synthetic sample_id so downstream code stays uniform.

### 4.6 Stub blocks
- Every process **must** declare a `stub:` block.
- The stub must `touch` a file matching **every** path declared in `output:` — primary outputs, `*.stdout`, and `*.stderr` alike. Glob outputs (e.g. `path("*.stderr")`) need at least one matching file; use the same names the real script writes (check the `tee` redirections).
- For outputs whose path uses a Groovy expression (e.g. `path("${file_name}")`, `path("${sample_id}.pep.xml")`), the variables must be defined in the `stub:` block too — mirror what `script:` does. Pure shell-interpolated `${var}` works only inside the triple-quoted string; if a Groovy local from `script:` is needed, redefine it before the heredoc in `stub:` as well.
- **Secret-availability guard (the one allowed exception to "touch only").** A process that declares a `secret` directive begins its `stub:` with `: "\${SECRET_NAME:?SECRET_NAME not available to process}"` (note the `\$` so Groovy leaves it for the shell). This makes the stub fail if the secret isn't injected into the task env, so the stub suite verifies the secret actually reaches the process — on the local/directive path (`-stub-run` forces `executor=local`, so it does **not** exercise the AWS Batch fetch). **Never** print the value: `:?` emits only the variable name and message. Don't add this guard to the `BUILD_AWS_*` bridge stubs.
- `nextflow run -stub-run` is the cheapest way to validate channel wiring after a refactor — run it in both modes (default and `--process_separately true`) before declaring a change done.

### 4.7 Caching vs publishing
- `storeDir` for cross-run cache (expensive, idempotent steps): `MSCONVERT`, `PANORAMA_GET_RAW_FILE`. Cache paths come from `params.mzml_cache_directory` / `params.panorama_cache_directory`.
- `publishDir` into `params.result_dir` for everything users should keep. Use `mode: 'copy'` and `failOnError: true` consistently with neighbouring modules.

### 4.8 Combined vs separate symmetry
- The `*_combined.nf` / `*_separate.nf` Limelight module pairs must stay in lockstep on flags and behavior, even though they differ in I/O shape.
- When editing one, open the other in the same change and apply the equivalent edit (or note explicitly why they should diverge).

### 4.9 Secrets (the secret + AWS Secrets Manager bridge pattern)
This replaced an earlier `nextflow.config` env-injection hack (which forced every user to set dummy placeholder secrets and broke the Nextflow-26 config parser). **Do not load secrets in `nextflow.config`.** The pattern:

- **Local / grid executors:** each consuming process declares Nextflow's native `secret 'NAME'` directive — the 4 `PANORAMA_GET_*` (`PANORAMA_API_KEY`) and the 2 `UPLOAD_TO_LIMELIGHT_*` (`LIMELIGHT_SUBMIT_UPLOAD_KEY`). A key is required **only when its process actually runs**, so non-Panorama / non-upload runs need no secrets at all.
- **AWS Batch** does not honor the `secret` directive. So on the `aws` profile, `modules/aws.nf` runs a **local** bridge — `GET_AWS_USER_ID` → `BUILD_AWS_{PANORAMA,LIMELIGHT}_SECRET` (each `executor 'local'`, each declaring its own `secret`) — that reads the key locally and upserts it into AWS Secrets Manager under a per-user id (`AwsSecrets.secretId`). Each consuming process then calls `${AwsSecrets.fetchScript('NAME', aws_secret_id, params.aws_region, task.executor)}` at the top of its script: on `awsbatch` it pulls the value back from Secrets Manager and exports it; on any other executor it's a no-op (the directive already set it).
- **Gating + threading:** `main.nf` computes `needs_panorama` (any `https://` input), `needs_limelight` (`limelight_upload`), and `on_aws` (`workflow.profile` contains `aws`). It runs the bridge only when `on_aws && needed`, else uses `Channel.value('none')`. The resulting `aws_secret_id` is threaded into the consuming processes (panorama ids in `main.nf`; the limelight id via the sub-workflows' `take:`) — this both passes the id and gates ordering so Batch tasks can't start before the secret exists.
- **Adding a new secret-using process:** add `secret 'NAME'`, a trailing `val aws_secret_id` input, and the `AwsSecrets.fetchScript(...)` line; thread an `aws_secret_id` channel to it from `main.nf`. If it can run on Batch, add a `BUILD_AWS_*_SECRET` twin in `modules/aws.nf` and a `withName` entry in the `aws` profile's local-executor selector.
- **Constraints to preserve:** the bridge processes run **uncontainerized on the launch host** and need the host's AWS CLI + credentials; the consuming process containers need the AWS CLI available to fetch on Batch (see §6 footgun). The bridge must stay `executor 'local'` — the `aws` profile pins it with a `withName` selector so the blanket `awsbatch` executor can't pull it onto Batch.

### 4.10 Comments and dead code
- Default to no comments. Only add one when the *why* is non-obvious (a hidden constraint, a workaround for a specific tool quirk, etc.). Don't write comments that just describe what the next line does.
- Don't leave orphaned/dummy workflows or unused processes lying around. (`main.nf:99-101` has a `workflow dummy` that fits this description — fine to remove if you're touching `main.nf`.)

### 4.11 Updating documentation
- If you change a process name, output filename, parameter name, or the set of files written to `results/`, also update the matching place in `docs/source/`. The docs drift faster than anything else in this repo — actively prevent it.
- If you change a user-visible parameter, update `resources/pipeline.config` (the template users copy), `docs/source/workflow_parameters.rst`, **and** `nextflow_schema.json` (§4.12).

### 4.12 Parameter schema and validation (`nextflow_schema.json`)
Params are validated at launch against `nextflow_schema.json` by the **nf-schema** plugin (`id 'nf-schema@2.7.2'` in `nextflow.config`; `validateParameters(cast_cli_params: true)` + `paramsSummaryLog(workflow)` at the top of the `workflow {}` body in `main.nf`). The schema is the canonical nf-core format: JSON Schema **draft 2020-12**, parameter groups under top-level **`$defs`** wired together by **`allOf`** (note: `$defs`, not `defs` or `definitions`).

- **Every user-settable param must be in the schema.** Validation runs in **strict** mode (`validation.logging.unrecognisedParams = 'error'` in `nextflow.config`) — any param not described in the schema is a hard error, so a typo'd `--flag` fails the run instead of being silently ignored. When you add or rename a param, add/rename it here in the same change, or the next run breaks. This includes the `images` container map (modelled as a nested object in the `container_image_options` group) — we describe it in the schema rather than ignore-listing it.
- **`cast_cli_params: true` is mandatory in the `validateParameters(...)` call.** On the v1 parser (Nextflow 25.10's default) CLI values arrive as strings (`--limelight_upload true` → `"true"`), and without this flag the v1 default would reject `"true"` against a `boolean` and `"1"` against an `integer`. With it, CLI strings are cast to the schema type before validation on both the v1 (25.10) and v2 (26) parsers. (This is separate from `Utils.asBool` in §6, which guards the *runtime* truthiness check; the schema cast only affects a temporary copy used for validation.)
- **Do NOT use the existence-checking path formats** (`file-path`, `directory-path`, `path`) on these params. They make nf-schema assert the path exists, which is wrong here: output dirs (`result_dir`, `report_dir`) and caches don't exist yet (and caches can be `s3://`), and `fasta`/`spectra_dir`/`comet_params` may be `https://` PanoramaWeb URLs no local check can resolve. The pipeline does its own `checkIfExists` / `https://` branching in `main.nf`. Keep these as plain `string`. The non-asserting `email`/`uri` formats are fine.
- The plugin floor pins the whole pipeline's Nextflow floor — see §6.

## 5. Cross-cutting source-of-truth files

When you need to change one of these things, change it *only* here:

| Concern | File |
|---|---|
| Container image and version for any tool | `container_images.config` |
| Resource tiers (cpus / memory / time per label) | `conf/base.config` |
| Default params, execution profiles, reports | `nextflow.config` |
| Parameter schema (types, groups, validation) | `nextflow_schema.json` (§4.12) |
| Secret handling (directive + AWS Secrets Manager bridge) | `modules/aws.nf`, `lib/AwsSecrets.groovy`, the `secret` directive on consuming processes (§4.9) |
| Template config users copy and edit | `resources/pipeline.config` |
| User-facing docs | `docs/source/*.rst` |
| Repo orientation for developers | `README.md` |
| Onboarding + conventions for agents (this file) | `CLAUDE.md` |

## 6. Known footguns

**The Nextflow floor (`!>=25.10.0`) is dictated by nf-schema, not by our code.** We require param validation on Nextflow 26, and nf-schema 2.7.2 is the only line that works correctly there — and it requires Nextflow ≥25.10. Older nf-schema (2.5.x, floor 25.04) *loads* on NF 26 but its `validation` config scope is silently unrecognised, so `lenientMode`/casting is ignored and validation then wrongly rejects every boolean/integer CLI param. So there is **no** single nf-schema version spanning NF 25.04 → 26.04; 25.10 is the real minimum. Don't lower the manifest floor or downgrade the plugin expecting to "support older Nextflow 25" — it breaks NF 26 (which CI tests). If you bump the plugin, re-verify on **both** pinned engines (`tests/nextflow-versions.txt`), and confirm `validation.logging.unrecognisedParams` and `cast_cli_params` still exist (the config-key names have changed across nf-schema versions — `failUnrecognisedParams` was replaced by `logging.unrecognisedParams`).

**Stray project name in `nextflow.config:1-5`.** The repo, Read the Docs URL, manifest, and Sphinx project are all `nf-ms-dda-comet`. The one remaining inconsistency is a docstring header at the top of `nextflow.config` that opens with `# Parameters for nf-maccoss-trex` — leftover from an earlier name. It has no functional effect; fix it if you're editing nearby, but don't introduce a new third name.

**Tests are stub-only; no real-data CI.** Regression protection has two tiers: the stub harness (`tests/run-stub-tests.sh` → a 16-case matrix of mzML vs raw input × 1 vs 3 files × combined vs separate × upload on/off; `tests/run-stub-tests-all.sh` wraps it to run against every version in `tests/nextflow-versions.txt`) and a *manual* smoke run against `test-data/` with real tools (Comet/Percolator actually execute — not in CI, requires Docker). The stub harness catches wiring breakage; it does **not** catch logic errors inside a process script, since stub blocks only `touch` outputs. (One targeted exception: secret-consuming stubs carry a `: "${SECRET:?}"` guard — §4.6 — so any passing upload case also proves the secret was injected into that process's env on the local/directive path; the AWS Batch fetch path stays unverified.) Run the harness before declaring any topology change done, and a manual smoke run before declaring a process-script change done.

CI (`.github/workflows/ci.yml`) runs the matrix on every push, **one parallel job per Nextflow version** (a `versions` job reads `tests/nextflow-versions.txt` into a job-matrix; `fail-fast: false` so each version reports independently). CI provisions each engine with `nf-core/setup-nextflow` and runs the inner `tests/run-stub-tests.sh`; local dev instead installs all versions via `tests/setup-nextflow.sh` and runs `tests/run-stub-tests-all.sh`. The inner harness and the version list are shared — only the provisioning differs.

**The pipeline now parses under the Nextflow-26 strict (v2) parser — keep it that way.** Nextflow 26 makes its strict config *and* script parsers the default, and the harness runs against 26 with no `NXF_SYNTAX_PARSER` override, so any v2 regression fails CI. The migration that got us here removed every v1-only idiom:
- **Config (`nextflow.config`, `conf/base.config`):** the `def check_max(...)` helper is gone — resources are capped by `process.resourceLimits` (§4.2) instead. The top-level `def trace_timestamp` is gone — the launch timestamp is computed inline in each `timeline`/`report`/`trace`/`dag` `file` string (so they may differ by up to a second). The v2 parser rejects **any** top-level `def`/function definition or loose statement in config.
- **Script (`main.nf`):** the `workflow.onComplete { … }` handler lives **inside** the entry `workflow {}` body (the v2 script parser rejects it as a top-level statement); the dead `workflow dummy` was removed; spectra globbing uses `files(...)` not `file(...)` (the latter warns on glob matches). Top-level `def` functions like `email()` are still allowed.
- **Boolean params from the CLI (`Utils.asBool`).** Under v2, Nextflow 26 no longer coerces a command-line `--flag false` into a boolean — it stays the **string** `"false"`, which is **truthy** in Groovy, so `if (params.flag)` silently takes the wrong branch. (This is exactly how the combined-vs-separate dispatch broke: `--process_separately false` ran the *separate* path.) **Every** boolean param read in a truthy context must go through `Utils.asBool(params.x)` (`lib/Utils.groovy`) — currently `process_separately`, `limelight_upload`, and `limelight_import_decoys` in `main.nf` and both sub-workflows. When you add a new boolean param used in an `if`/ternary/`&&`, wrap it the same way. (Params set as real booleans in a config file are unaffected, but the CLI path makes raw `if (params.flag)` unsafe.)

Don't reintroduce any of these idioms (top-level `def` in config, chained assignments, loose top-level script statements, `file()` with a glob, raw `if (params.<boolean>)`). If you add a config function, find a non-function expression instead. Validate with a plain `-stub-run` on a 26 engine (no `NXF_SYNTAX_PARSER` set) — that's what the harness does.

**The AWS secret bridge needs the AWS CLI in two places (cannot be stub-tested).** On the `aws` profile, `modules/aws.nf`'s `GET_AWS_USER_ID` / `BUILD_AWS_*_SECRET` run uncontainerized on the launch host and require the host's `aws` CLI + credentials; the *consuming* process containers (`panorama_client`, `limelight_upload`) must also have `aws` on PATH so `AwsSecrets.fetchScript` can pull the key from Secrets Manager on Batch. The stub suite forces `executor=local` and only `touch`es outputs, so it exercises the **wiring** of this path but never the real `aws secretsmanager` / `aws sts` calls — validate those on an actual Batch run. Also: `docker.enabled = true` is global, so a real `aws`-profile run relies on the bridge processes having no `container` directive (they run on the host); don't add one.

**Evaluate nf-test as a future upgrade.** The current harness (`tests/run-stub-tests.sh`) is a deliberately minimal bash wrapper: it asserts exit code + presence/absence of published files, nothing finer-grained. [nf-test](https://www.nf-test.com/) is the idiomatic Nextflow framework (per-process/per-workflow stub tests, snapshot assertions) and is the intended next step when richer assertions are wanted — it was considered and deferred, not rejected. If you migrate, keep the both-dispatch-modes coverage the bash harness provides.

**`limelight_upload = true` silently requires every Limelight `val` param to be set.** Nextflow rejects any `val` input that evaluates to `null`, but there is no upfront validation — Comet, Percolator, and the Limelight XML conversion will all run first, then the upload fails with a misleading message like `A process input channel evaluates to null -- Invalid declaration 'val tags'`. The full required set when `limelight_upload = true` is: `limelight_webapp_url`, `limelight_project_id`, `limelight_search_description`, `limelight_search_short_name`, **and** `limelight_tags` (despite the latter being documented as optional). If you touch the upload modules, preserve this requirement set in any test config — and consider whether the upload modules should accept null tags explicitly.

**`MSCONVERT` file-extension detection is brittle.** `main.nf:54,57` only globs `*.mzML` and `*.raw` — case-sensitive on Linux. A spectra directory containing `.mzml` (lowercase), `.RAW` (uppercase), `.d` (Bruker / Agilent), `.wiff` (SCIEX), or any other vendor format silently produces `"No raw or mzML files found in: <dir>"` even though files clearly exist. The check is in `main.nf` between the PanoramaWeb branch and the sub-workflow dispatch. If a user reports this error and they have spectra files in the directory, this is almost always why. A fix would require a case-insensitive glob (or `findAll` with a regex) plus an expanded extension list, and a decision about how to route non-Thermo vendor formats through msconvert.
