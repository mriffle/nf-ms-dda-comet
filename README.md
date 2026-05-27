# nf-ms-dda-comet

**User documentation:** https://nf-ms-dda-comet.readthedocs.io/

A Nextflow (DSL2) pipeline for **Data-Dependent Acquisition (DDA)** mass spectrometry
proteomics. Given vendor `.raw` (or pre-converted `.mzML`) spectra and a FASTA, it runs
peptide identification with [Comet](https://uwpr.github.io/Comet/), post-processes the
results with [Percolator](https://github.com/percolator/percolator), and optionally uploads
the search to [Limelight](https://limelight-ms.org/) for visualization and sharing. Inputs
and outputs may live on the local filesystem or in
[PanoramaWeb](https://panoramaweb.org/) — any path beginning with `https://` is treated as
a PanoramaWeb WebDAV URL and downloaded automatically.

This README is for people reading the source. End-user instructions (install, run,
parameters, AWS Batch setup) are in the
[user documentation](https://nf-ms-dda-comet.readthedocs.io/).

---

## Pipeline Overview

```
[panorama download?] -> MSCONVERT (if .raw) -> COMET -> FILTER_PIN -> ...
```

Past `FILTER_PIN` the pipeline branches on `params.process_separately`:

| Mode | Pin handling | Percolator runs | Limelight upload |
|---|---|---|---|
| **combined** (default) | `COMBINE_PIN_FILES` concatenates all filtered pins | 1 (over the combined pin) | 1 search with sub-searches |
| **separate** (`process_separately = true`) | per-sample pins kept distinct | 1 per sample | 1 search per sample |

The two paths are implemented as separate sub-workflows that share the same set of
upstream processes (msconvert, Comet, filter_pin).

## Repository Layout

```
main.nf                          Entry point. Resolves inputs (local vs. PanoramaWeb)
                                 and dispatches to one of two sub-workflows.

nextflow.config                  Pipeline params, secrets loading, execution profiles
                                 (standard, slurm), report/timeline/trace settings,
                                 and the check_max() helper from the nf-core template.

container_images.config          Centralized, version-pinned Docker image registry.
                                 Edit here to bump tool versions.

conf/base.config                 Resource labels (process_low, process_medium,
                                 process_high, process_long, process_high_memory,
                                 *_constant variants) and retry policy.

workflows/
  comet_combined_percolator.nf   Sub-workflow for the "combined" mode.
  comet_separate_percolator.nf   Sub-workflow for the "separate" mode.

modules/
  msconvert.nf                   Raw -> mzML via ProteoWizard (wine msconvert).
                                 Uses storeDir for cross-run caching.
  comet.nf                       Peptide search; emits pep.xml + pin per sample.
  filter_pin.nf                  Drops non-rank-one hits from pin files (Java JAR).
  combine_pin_files.nf           Concatenates filtered pins (combined mode only).
  percolator.nf                  FDR post-processing; emits pout.xml.
  limelight_xml_convert_combined.nf    Comet+Percolator -> Limelight XML (combined).
  limelight_xml_convert_separate.nf    Same, per-sample (separate mode).
  limelight_upload_combined.nf         Upload to Limelight (single search).
  limelight_upload_separate.nf         Upload to Limelight (one search per sample).
  panorama.nf                    Four PanoramaWeb processes: GET_FASTA,
                                 GET_COMET_PARAMS, GET_RAW_FILE_LIST, GET_RAW_FILE.
                                 GET_RAW_FILE uses storeDir for download caching.

lib/EmailTemplate.groovy         Builds the workflow.onComplete email body.
assets/email_template.html       GSP-style HTML template used by EmailTemplate.

resources/
  pipeline.config                Template user config file (copied by end users).
  comet.params                   Template Comet params file.

test-data/                       Small mzML + fasta + comet.params for smoke runs.

tests/
  run-stub-tests-all.sh          Runs the stub suite against every pinned Nextflow
                                 version (what CI runs).
  run-stub-tests.sh              Inner harness: -stub-run over an 8-case matrix
                                 (1/3 files × combined/separate × upload on/off),
                                 asserts published outputs. No Docker.
  setup-nextflow.sh              Installs the pinned Nextflow versions locally into
                                 .test-tools/ (gitignored). Run once per machine.
  nextflow-versions.txt          Pinned Nextflow versions the suite runs against.
  stub.config                    Disables Docker + caps CPU/RAM for stub runs.

.github/workflows/ci.yml         Runs the stub suite (all versions) on every push / PR.

docs/                            Sphinx documentation source (published to
                                 Read the Docs via .readthedocs.yaml).
```

## Execution Flow

1. **`main.nf`** resolves each input. For each of `fasta`, `comet_params`, and
   `spectra_dir`, it checks whether the value starts with `https://`. If so, the
   corresponding `PANORAMA_GET_*` process downloads it; otherwise it's a local `file()`.
   For spectra, the directory is then sniffed for `*.mzML` first, falling back to `*.raw`.
   A `from_raw_files` boolean is threaded to the sub-workflow so it knows whether to invoke
   `MSCONVERT`.
2. The selected sub-workflow runs `MSCONVERT` (if needed), `COMET`, and `FILTER_PIN`,
   producing `(sample_id, file)` tuples that carry the sample identity downstream.
3. In **combined** mode, all filtered pins are concatenated by `COMBINE_PIN_FILES` and a
   single `PERCOLATOR` runs. In **separate** mode, `PERCOLATOR` is invoked once per
   filtered pin.
4. If `params.limelight_upload` is true, the appropriate
   `CONVERT_TO_LIMELIGHT_XML_*` / `UPLOAD_TO_LIMELIGHT_*` pair runs. In separate mode the
   Comet pepXML, Percolator pout, and mzML are re-joined by `sample_id` to keep per-sample
   artifacts paired through to upload.
5. `workflow.onComplete` optionally sends a completion email via
   `lib/EmailTemplate.groovy` (wrapped in try/catch so SMTP failures don't fail the run).

## Conventions Used Across Modules

- **One container per process.** Every process sets `container params.images.<key>`; the
  image strings (and pinned tags) live in `container_images.config`. Bumping a tool
  version should be a one-line change there.
- **Resource labels, not hard-coded resources.** Processes apply labels like
  `process_medium` or `process_high_constant`; the actual cpus/memory/time live in
  `conf/base.config` and scale with `task.attempt` via `check_max()`.
- **Retry on transient failures.** `errorStrategy` retries on a fixed set of exit codes
  (OOM, signal, etc.) up to 3 times; other failures fail fast.
- **Caching where it matters.** `MSCONVERT` and `PANORAMA_GET_RAW_FILE` use `storeDir`
  (pointed at `params.mzml_cache_directory` / `params.panorama_cache_directory`) so
  expensive conversions and downloads are reused across runs. Everything else uses
  `publishDir` into `params.result_dir`.
- **Sample-keyed tuples.** Channels carry `tuple(sample_id, file)` so multi-output
  processes can be re-joined cleanly downstream.
- **stdout/stderr capture.** CLI invocations are wrapped in
  `> >(tee X.stdout) 2> >(tee X.stderr >&2)` so logs land in both the terminal and
  declared output files. The trailing `echo "Done!"` defeats pipefail on `tee`.
- **Java memory wrapper.** Modules that run JARs define
  `def exec_java_command(mem)` to compute `-Xmx${mem.toGiga()-1}G` and assemble the
  `java -jar` invocation.
- **Stub blocks.** Most processes declare a `stub:` so `nextflow run -stub-run` works
  for fast wiring checks. (`COMBINE_PIN_FILES` is the one current exception.)

## Secrets and External Services

`nextflow.config` loads two secrets from `nextflow.secret` and re-exports them into the
process environment (so they reach AWS Batch tasks, which don't natively honor
`nextflow.secret`):

- `PANORAMA_API_KEY` — used by all `PANORAMA_GET_*` processes.
- `LIMELIGHT_SUBMIT_UPLOAD_KEY` — used by `UPLOAD_TO_LIMELIGHT_*`.

Both must be set with `nextflow secrets set ...` before running. The user docs walk
through how to obtain them.

## Execution Profiles

`nextflow.config` defines:

- `standard` — local executor, `executor.queueSize = 1` (one task at a time).
- `slurm` — slurm executor.

There is no `aws` profile in this repo; users who run on AWS Batch supply that via their
own `-c pipeline.config` (the user docs cover this).

## Adding or Modifying a Step

- New tool image → add a key to `container_images.config` and reference it as
  `params.images.<key>`.
- New resource tier → add a `withLabel:` block in `conf/base.config`.
- New process → place in `modules/`, follow the conventions above (container,
  label, tee for logs, `(sample_id, file)` tuples, stub block).
- New sub-workflow → place in `workflows/`, include it from `main.nf`.

---

## Funding & Attribution

This work was made possible with funding from IARPA via the TEI-REX program
(Contract #: W911NF2220059). The contents of these documents are purely technical in
nature, with no opinions or perspectives of the US Government's interests in TEI-REX.
