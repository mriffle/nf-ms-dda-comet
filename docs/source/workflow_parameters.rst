===================================
Workflow Parameters
===================================

The workflow parameters should be included in a configuration file, an example
of which can be found at
https://raw.githubusercontent.com/mriffle/nf-teirex-dda/main/resources/pipeline.config

The parameters in this file should be changed to indicate the locations of your data, the
options you'd like to use for the software included in the workflow, and the capabilities and
configuration for the system on which you are running the workflow steps.

The configuration file is roughly organized as:

.. code-block:: groovy

    params {
    ...
    }

    profiles {
    ...
    }

    mail {
    ...
    }

- The ``params`` section includes locations of data and configuration options for a specific run of the workflow.
- The ``profiles`` sections includes parameters that describe the capabilities of the systems that run the steps of the workflow. For example, if running on your local system, this will include things like how many cores and how much RAM may be used by the steps of the workflow. This will not need to be changed for each run of the workflow.
- The ``mail`` section includes configuration options for sending email. This is optional and only necessary if you wish to send emails when the workflow completes. This will not need to be changed for each run of the workflow.

Below is a complete description of all parameters that may be included in these sections.

.. note::

    This workflow can process files stored in **PanoramaWeb**. When specifying directories or file locations, any paths that begin with ``https://`` will be interpreted as being PanoramaWeb locations.

    For example, to process raw files stored in PanoramaWeb, you would have the following in your pipeline.config file:

    .. code-block:: bash

        quant_spectra_dir= 'https://panoramaweb.org/_webdav/path/to/@files/RawFiles/'


    Where, ``https://panoramaweb.org/_webdav/path/to/@files/RawFiles/`` is the WebDav URL of the folder on the Panorama server.


The ``params`` Section
^^^^^^^^^^^^^^^^^^^^^^^

.. list-table:: Parameters for the ``params`` section
   :widths: 5 20 75
   :header-rows: 1

   * - Req?
     - Parameter Name
     - Description
   * - ✓
     - ``spectra_dir``
     - That path to the location of the raw or mzML files to be processed. This can be a directory location (e.g., ``/data/mass_spec/my_raw_files/`` or a Panorama WebDAV URL (described above).
   * - ✓
     - ``fasta``
     - That path to the location of the FASTA file to be used in the Comet search. This can be a directory location (e.g., ``/data/mass_spec/my.fasta`` or a Panorama WebDAV URL (described above).
   * - 
     - ``comet_params``
     - That path to the location of the Comet params file to be used in the Comet search. This can be a directory location (e.g., ``/data/mass_spec/comet.params`` or a Panorama WebDAV URL (described above). Default: ``'comet.params'``.
   * - 
     - ``process_separately``
     - Set to ``true`` to run Percolator (and upload to Limelight) separately for each raw file in ``spectra_dir``. This results in a separate Percolator output file and a separate search in Limelight for each raw file. Set to ``false`` to combine all Comet results into a single Percolator run and upload all results as a single search (with sub-searches) to Limelight. Setting to ``false`` may result in better Percolator statistics, but may make it harder to compare results from individual raw files to results from other searches. Default: ``false``.
   * - 
     - ``limelight_upload``
     - Set to ``true`` to upload to Limelight. If set to ``true``, the following Limelight-related parameters apply. Default: ``false``.
   * - 
     - ``limelight_project_id``
     - This is required if ``limelight_upload`` is set to ``true``. This is the Limelight project ID to which to upload data.
   * - 
     - ``limelight_webapp_url``
     - This is required if ``limelight_upload`` is set to ``true``. This is the URL of the Limelight instance to which to upload data. E.g., ``'https://limelight.yeastrc.org/limelight'``.
   * - 
     - ``limelight_search_description``
     - This is required if ``limelight_upload`` is set to ``true``. This is a one-line description of the search that will appear in Limelight. 
   * - 
     - ``limelight_search_short_name``
     - This is required if ``limelight_upload`` is set to ``true``. This is a very brief one-word nickname for this search. Used in plots to label data.
   * - 
     - ``limelight_tags``
     - Comma-delimited list of Limelight tags to use for this search (e.g., ``'yeast,control,2023'``. Any tags present that haven't been created in Limelight will be created in Limelight. Note: You can also specify
       categories for tags, and tags with the same tag categories will be grouped together in Limelight. For example, one could have a tag category called ``treatment`` and tags called ``control`` or ``irradiated`` as
       tags within this tag category. To specify a tag category use the tag category name then a tilda (~) then the tag name. E.g., ``treatment~control,organism~yeast,year~2023``. Default: no tags will be sent.
   * - 
     - ``limelight_import_decoys``
     - If set to ``true``, decoy hits will be imported into Limelight--enabling target/decoy QC visualization. Only set to ``true`` if this is required, dramatically increases file sizes. Default: ``false``
   * - 
     - ``limelight_entrapment_prefix``
     - If this set, any protein that begins with this string will be considered an entrapment decoy by Limelight--that is a target hit that is secretly really a decoy. This enables some QC/statistic tools within Limelight to estimate error. Example: ``limelight_entrapment_prefix = 'ENTRAP'``. Default: not set.
   * - 
     - ``email``
     - The email address to which a notification should be sent upon workflow completion. If no email is specified, no email will be sent. To send email, you must configure mail server settings (see below).

The ``profiles`` Section
^^^^^^^^^^^^^^^^^^^^^^^^
The example configuration file includes this ``profiles`` section:

.. code-block:: groovy

    profiles {

        // "standard" is the profile used when the steps of the workflow are run
        // locally on your computer. These parameters should be changed to match
        // your system resources (that you are willing to devote to running
        // workflow jobs).
        standard {
            params.max_memory = '8.GB'
            params.max_cpus = 4
            params.max_time = '240.h'

            params.mzml_cache_directory = '/data/mass_spec/nextflow/nf-teirex-dda/mzml_cache'
            params.panorama_cache_directory = '/data/mass_spec/nextflow/panorama/raw_cache'
        }
    }

These parameters describe the capability of your local computer for running the steps of the workflow. Below is a description of each parameter:

.. list-table:: Parameters for the ``profiles/standard`` section
   :widths: 5 20 75
   :header-rows: 1

   * - Req?
     - Parameter Name
     - Description
   * - ✓
     - ``params.max_memory``
     - The maximum amount of RAM that may be used by steps of the workflow. Default: 8 gigabytes.
   * - ✓
     - ``params.max_cpus``
     - The number of cores that may be used by the workflow. Default: 4 cores.
   * - ✓
     - ``params.max_time``
     - The maximum amount of a time a step in the workflow may run before it is stopped and error generated. Default: 240 hours.
   * - ✓
     - ``params.mzml_cache_directory``
     - When ``msconvert`` converts a RAW file to mzML, the mzML file is cached for future use. This specifies the directory in which the cached mzML files are stored.
   * - ✓
     - ``params.panorama_cache_directory``
     - If the RAW files to be processed are in PanoramaWeb, the RAW files will be downloaded to and cached in this directory for future use.

The ``mail`` Section
^^^^^^^^^^^^^^^^^^^^^^^
This is a more advanced and entirely optional set of parameters. When the workflow completes, it can optionally send an email to the address specified above in the ``params`` section.
For this to work, the following parameters must be changed to match the settings of your email server. You may need to contact your IT department to obtain the appropriate settings.

The example configuration file includes this ``mail`` section:

.. code-block:: groovy

    mail {
        from = 'address@host.com'
        smtp.host = 'smtp.host.com'
        smtp.port = 587
        smtp.user = 'smpt_user'
        smtp.password = 'smtp_password'
        smtp.auth = true
        smtp.starttls.enable = true
        smtp.starttls.required = false
        mail.smtp.ssl.protocols = 'TLSv1.2'
    }

Below is a description of each parameter:

.. list-table:: Parameters for the ``profiles/standard`` section
   :widths: 5 20 75
   :header-rows: 1

   * - Req?
     - Parameter Name
     - Description
   * - ✓
     - ``from``
     - The email address **from** which the email should be sent.
   * - ✓
     - ``smtp.host``
     - The internet address (host name or ip address) of the email SMTP server.
   * - ✓
     - ``smtp.port``
     - The port on the host to connect to. Most likely will be ``587``.
   * - 
     - ``smtp.user``
     - If authentication is required, this is the username.
   * - 
     - ``smtp.password``
     - If authentication is required, this is the password.
   * - ✓
     - ``smtp.auth``
     - Whether or not (true or false) authentication is required.
   * - ✓
     - ``smtp.starttls.enable``
     - Whether or not to enable TLS support.
   * - ✓
     - ``smtp.starttls.required``
     - Whether or not TLS is required.
   * - ✓
     - ``smtp.ssl.protocols``
     - SSL protocol to use for sending SMTP messages.
