#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

// modules
include { PANORAMA_GET_FASTA } from "./modules/panorama"
include { PANORAMA_GET_COMET_PARAMS } from "./modules/panorama"
include { PANORAMA_GET_RAW_FILE } from "./modules/panorama"
include { PANORAMA_GET_RAW_FILE_LIST } from "./modules/panorama"
include { GET_AWS_USER_ID } from "./modules/aws"
include { BUILD_AWS_PANORAMA_SECRET } from "./modules/aws"
include { BUILD_AWS_LIMELIGHT_SECRET } from "./modules/aws"

// Sub workflows
include { wf_comet_combined_percolator } from "./workflows/comet_combined_percolator"
include { wf_comet_separate_percolator } from "./workflows/comet_separate_percolator"

//
// The main workflow
//
workflow {

    // Which API keys does this run actually need?
    needs_panorama = params.fasta.startsWith("https://") ||
                     params.comet_params.startsWith("https://") ||
                     params.spectra_dir.contains("https://")
    needs_limelight = params.limelight_upload
    on_aws = workflow.profile.tokenize(',').contains('aws')

    // On AWS Batch the native `secret` directive isn't honored, so bridge the
    // needed keys into AWS Secrets Manager (a local process reads the secret and
    // stores it; Batch tasks fetch it back — see modules/aws.nf). Off AWS, this
    // is skipped and 'none' flows through; the `secret` directive supplies the
    // key directly. The secret-id channels gate the dependent processes too.
    if( on_aws && (needs_panorama || needs_limelight) ) {
        GET_AWS_USER_ID()
        aws_user_id = GET_AWS_USER_ID.out.aws_user_id.first()
    }

    if( on_aws && needs_panorama ) {
        BUILD_AWS_PANORAMA_SECRET(aws_user_id)
        panorama_secret_id = BUILD_AWS_PANORAMA_SECRET.out.aws_secret_id.first()
    } else {
        panorama_secret_id = Channel.value('none')
    }

    if( on_aws && needs_limelight ) {
        BUILD_AWS_LIMELIGHT_SECRET(aws_user_id)
        limelight_secret_id = BUILD_AWS_LIMELIGHT_SECRET.out.aws_secret_id.first()
    } else {
        limelight_secret_id = Channel.value('none')
    }

    if(params.fasta.startsWith("https://")) {
        PANORAMA_GET_FASTA(params.fasta, panorama_secret_id)
        fasta = PANORAMA_GET_FASTA.out.panorama_file
    } else {
        fasta = file(params.fasta, checkIfExists: true)
    }

    if(params.comet_params.startsWith("https://")) {
        PANORAMA_GET_COMET_PARAMS(params.comet_params, panorama_secret_id)
        comet_params = PANORAMA_GET_COMET_PARAMS.out.panorama_file
    } else {
        comet_params = file(params.comet_params, checkIfExists: true)
    }

    if(params.spectra_dir.contains("https://")) {

        spectra_dirs_ch = Channel.from(params.spectra_dir)
                                .splitText()               // split multiline input
                                .map{ it.trim() }          // removing surrounding whitespace
                                .filter{ it.length() > 0 } // skip empty lines

        // get raw files from panorama
        PANORAMA_GET_RAW_FILE_LIST(spectra_dirs_ch, panorama_secret_id)
        placeholder_ch = PANORAMA_GET_RAW_FILE_LIST.out.raw_file_placeholders.transpose()
        PANORAMA_GET_RAW_FILE(placeholder_ch, panorama_secret_id)

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

    if(params.process_separately) {
        wf_comet_separate_percolator(spectra_files_ch, comet_params, fasta, from_raw_files, limelight_secret_id)
    } else {
        wf_comet_combined_percolator(spectra_files_ch, comet_params, fasta, from_raw_files, limelight_secret_id)
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
workflow.onComplete {
    try {
        email()
    } catch (Exception e) {
        println "Warning: Error sending completion email."
    }
}
