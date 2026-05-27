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

There is no build, lint, unit-test harness, or CI. "Running the code" means running Nextflow.

```bash
# Wiring check — uses every process's stub: block, no real tools execute.
# Run this after any change to channel topology in main.nf or workflows/.
nextflow run main.nf -stub-run --fasta test-data/test.fasta \
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
- Resource values scale with `task.attempt` via the `check_max()` helper.

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
- Every process **must** declare a `stub:` block that `touch`es each declared output.
- The one exception in the current tree is `COMBINE_PIN_FILES`; don't follow its lead, and fix it if you're nearby.
- `nextflow run -stub-run` is the cheapest way to validate channel wiring after a refactor — make sure it passes before declaring a change done.

### 4.7 Caching vs publishing
- `storeDir` for cross-run cache (expensive, idempotent steps): `MSCONVERT`, `PANORAMA_GET_RAW_FILE`. Cache paths come from `params.mzml_cache_directory` / `params.panorama_cache_directory`.
- `publishDir` into `params.result_dir` for everything users should keep. Use `mode: 'copy'` and `failOnError: true` consistently with neighbouring modules.

### 4.8 Combined vs separate symmetry
- The `*_combined.nf` / `*_separate.nf` Limelight module pairs must stay in lockstep on flags and behavior, even though they differ in I/O shape.
- When editing one, open the other in the same change and apply the equivalent edit (or note explicitly why they should diverge).

### 4.9 Secrets
- Secrets reach processes via `env.*` re-export in `nextflow.config:53-65`, not via Nextflow's native secret directive. This is **deliberate** — AWS Batch tasks don't honor `nextflow.secret`. Don't "simplify" this back to native secrets.

### 4.10 Comments and dead code
- Default to no comments. Only add one when the *why* is non-obvious (a hidden constraint, a workaround for a specific tool quirk, etc.). Don't write comments that just describe what the next line does.
- Don't leave orphaned/dummy workflows or unused processes lying around. (`main.nf:99-101` has a `workflow dummy` that fits this description — fine to remove if you're touching `main.nf`.)

### 4.11 Updating documentation
- If you change a process name, output filename, parameter name, or the set of files written to `results/`, also update the matching place in `docs/source/`. The docs drift faster than anything else in this repo — actively prevent it.
- If you change a user-visible parameter, update `resources/pipeline.config` (the template users copy) and `docs/source/workflow_parameters.rst`.

## 5. Cross-cutting source-of-truth files

When you need to change one of these things, change it *only* here:

| Concern | File |
|---|---|
| Container image and version for any tool | `container_images.config` |
| Resource tiers (cpus / memory / time per label) | `conf/base.config` |
| Default params, execution profiles, secrets, reports | `nextflow.config` |
| Template config users copy and edit | `resources/pipeline.config` |
| User-facing docs | `docs/source/*.rst` |
| Repo orientation for developers | `README.md` |
| Onboarding + conventions for agents (this file) | `CLAUDE.md` |

## 6. Known footguns

**Stray project name in `nextflow.config:1-5`.** The repo, Read the Docs URL, manifest, and Sphinx project are all `nf-ms-dda-comet`. The one remaining inconsistency is a docstring header at the top of `nextflow.config` that opens with `# Parameters for nf-maccoss-trex` — leftover from an earlier name. It has no functional effect; fix it if you're editing nearby, but don't introduce a new third name.

**No CI, no test harness.** The only protection against regressions is `-stub-run` for wiring and a manual smoke run against `test-data/`. Run both before declaring a non-trivial change done.
