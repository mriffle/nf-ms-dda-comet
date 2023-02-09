#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

// modules
include { UPLOAD_TO_LIMELIGHT } from "./modules/limelight_upload"
include { PANORAMA_GET_FASTA } from "./modules/panorama"
include { PANORAMA_GET_COMET_PARAMS } from "./modules/panorama"
include { PANORAMA_GET_RAW_FILE } from "./modules/panorama"
include { PANORAMA_GET_RAW_FILE_LIST } from "./modules/panorama"

// Sub workflows
include { wf_comet_percolator } from "./workflows/comet_percolator"

//
// The main workflow
//
workflow {

    if(params.fasta.startsWith("https://")) {
        PANORAMA_GET_FASTA(params.fasta)
        fasta = PANORAMA_GET_FASTA.out.panorama_file
    } else {
        fasta = file(params.fasta, checkIfExists: true)
    }

    if(params.comet_params.startsWith("https://")) {
        PANORAMA_GET_COMET_PARAMS(params.comet_params)
        comet_params = PANORAMA_GET_COMET_PARAMS.out.panorama_file
    } else {
        comet_params = file(params.comet_params, checkIfExists: true)
    }

    if(params.spectra_dir.startsWith("https://")) {
        
        spectra_dirs_ch = Channel.fromList((params.spectra_dir).split(',').flatten())

        // get raw files from panorama
        PANORAMA_GET_RAW_FILE_LIST(spectra_dirs_ch)
        placeholder_ch = PANORAMA_GET_RAW_FILE_LIST.out.raw_file_placeholders.transpose()
        PANORAMA_GET_RAW_FILE(placeholder_ch)
        
        spectra_files_ch = PANORAMA_GET_RAW_FILE.out.panorama_file
        from_raw_files = true;

    } else {

        spectra_dir = file(params.spectra_dir, checkIfExists: true)

        // get our mzML files
        mzml_files = file("$spectra_dir/*.mzML")

        // get our raw files
        raw_files = file("$spectra_dir/*.raw")

        if(mzml_files.size() < 1 && raw_files.size() < 1) {
            error "No raw or mzML files found in: $spectra_dir"
        }

        if(mzml_files.size() > 0) {
                spectra_files_ch = Channel.fromList(mzml_files)
                from_raw_files = false;
        } else {
                spectra_files_ch = Channel.fromList(raw_files)
                from_raw_files = true;
        }
    }

    limelight_xml = wf_comet_percolator(spectra_files_ch, comet_params, fasta, from_raw_files)

    if (params.limelight_upload) {
        UPLOAD_TO_LIMELIGHT(
            limelight_xml,
            mzml_files,
            params.limelight_webapp_url,
            params.limelight_project_id,
            params.limelight_search_description,
            params.limelight_search_short_name,
            params.limelight_tags,
        )
    }
}

//
// Used for email notifications
//
def email() {
    // Create the email text:
    def (subject, msg) = EmailTemplate.email(workflow, params)
    // Send the email:
    if (params.email) {
        sendMail(
            to: "$params.email",
            subject: subject,
            body: msg
        )
    }
}

//
// This is a dummy workflow for testing
//
workflow dummy {
    println "This is a workflow that doesn't do anything."
}

// Email notifications:
workflow.onComplete { email() }
