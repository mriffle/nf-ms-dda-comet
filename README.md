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

nextflow.config                  Pipeline params, execution profiles (standard, slurm,
                                 aws), report/timeline/trace settings, and each profile's
                                 process.resourceLimits map (the cpus/memory/time cap that
                                 conf/base.config clamps every step to).

container_images.config          Centralized, version-pinned Docker image registry.
                                 Edit here to bump tool versions.

nextflow_schema.json             Parameter schema (nf-core/nf-schema format).
                                 Validated at launch by the nf-schema plugin
                                 (strict: unknown params error out). Keep in sync
                                 with params when you add/rename one.

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
  aws.nf                         AWS Secrets Manager bridge (GET_AWS_USER_ID,
                                 BUILD_AWS_{PANORAMA,LIMELIGHT}_SECRET) for secrets
                                 on AWS Batch. See CLAUDE.md §4.9.

lib/EmailTemplate.groovy         Builds the workflow.onComplete email body.
lib/AwsSecrets.groovy            Secret-id + Batch-fetch helpers for the AWS bridge.
assets/email_template.html       GSP-style HTML template used by EmailTemplate.

resources/
  pipeline.config                Template user config file (copied by end users).
  comet.params                   Template Comet params file.

test-data/                       Small mzML files + fasta + comet.params for smoke runs.

tests/
  run-stub-tests-all.sh          Runs the inner harness against every pinned
                                 Nextflow version (local multi-version driver).
  run-stub-tests.sh              Inner harness: -stub-run over a 16-case matrix
                                 (mzML/raw × 1/3 files × combined/separate ×
                                 upload on/off), asserts published outputs. No Docker.
  run-e2e-tests.sh               E2E smoke harness: runs the REAL workflow with real
                                 tools (Comet/FILTER_PIN/Percolator in containers) over
                                 a 4-case matrix (combined/separate × 1/3 mzML files);
                                 asserts real output content. Needs Docker; no secrets.
  setup-nextflow.sh              Installs the pinned Nextflow versions locally into
                                 .test-tools/ (gitignored). Run once per machine.
  nextflow-versions.txt          Pinned Nextflow versions the stub suite runs against.
  stub.config                    Disables Docker + caps CPU/RAM for stub runs.
  e2e.config                     Keeps Docker on + caps CPU/RAM for real E2E runs.

.github/workflows/ci.yml         Runs the stub matrix (one parallel job per Nextflow
                                 version) plus a single-engine e2e-smoke job on push / PR.

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
  `conf/base.config`, scale with `task.attempt`, and are capped at the per-profile
  maxima by `process.resourceLimits`.
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

Two secrets are consumed via Nextflow's native `secret` directive, declared on the
processes that use them — so each is required **only when that process actually runs**
(set with `nextflow secrets set ...`):

- `PANORAMA_API_KEY` — declared on the `PANORAMA_GET_*` processes; needed only when an
  input is a PanoramaWeb (`https://`) URL.
- `LIMELIGHT_SUBMIT_UPLOAD_KEY` — declared on `UPLOAD_TO_LIMELIGHT_*`; needed only when
  `limelight_upload = true`.

The native directive isn't honored on **AWS Batch**. So on the `aws` profile, a local
bridge (`modules/aws.nf` + `lib/AwsSecrets.groovy`) reads each needed key and stores it
in AWS Secrets Manager (per-user id); Batch tasks fetch it back at runtime. This is
gated in `main.nf` and runs only when the feature is used. See CLAUDE.md §4.9 and the
docs (`set_up_aws`) for details. Nothing is loaded in `nextflow.config`.

## Execution Profiles

`nextflow.config` defines:

- `standard` — local executor, `executor.queueSize = 1` (one task at a time).
- `slurm` — slurm executor.
- `aws` — AWS Batch executor (`awsbatch`); also the trigger for the AWS Secrets
  Manager bridge (`workflow.profile` must contain `aws` — see §4.9 of CLAUDE.md). It
  pins the bridge processes to the local executor, sets `params.aws_region`, and sets
  its own `process.resourceLimits`. Batch-specific bits the profile does **not**
  hard-code — the job queue and the S3 cache directories — are supplied by the user's
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
