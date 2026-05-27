=====================================
How to Setup and Configure AWS Batch
=====================================
See our guide at https://teirex-aws-setup.readthedocs.io/ for instructions
to set up, configure, and run the workflow using AWS Batch.

Secrets on AWS Batch
====================
Nextflow's native secrets (``nextflow secrets set ...``) work on local and HPC
executors but are **not** available to AWS Batch tasks. When you run with
``-profile aws`` and use a feature that needs an API key, the workflow bridges the
key through AWS Secrets Manager automatically:

#. A short process runs **locally** (on the machine launching Nextflow), reads the
   key from your local Nextflow secret, and stores it in AWS Secrets Manager under a
   per-user name (``NF_<aws-user>_PANORAMA_KEY`` / ``..._LIMELIGHT_KEY``).
#. Each Batch task fetches the key back from Secrets Manager at runtime.

This happens only for the keys a run actually needs (PanoramaWeb input and/or
Limelight upload). Requirements:

* Set the key locally as usual, e.g. ``nextflow secrets set PANORAMA_API_KEY "..."``.
* Set ``params.aws_region`` to your region (the ``aws`` profile in your
  ``pipeline.config`` does this) — the secret is stored and read there.
* The AWS identity used must have ``secretsmanager`` permissions
  (``CreateSecret``, ``UpdateSecret``, ``GetSecretValue``, ``ListSecrets``) and
  ``sts:GetCallerIdentity``.
* The AWS CLI must be available both on the launch host and inside the task
  containers (PanoramaWeb / Limelight images) used on Batch.
