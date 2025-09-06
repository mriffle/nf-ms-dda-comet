// Modules
include { MSCONVERT } from "../modules/msconvert"
include { COMET } from "../modules/comet"
include { PERCOLATOR } from "../modules/percolator"
include { FILTER_PIN } from "../modules/filter_pin"
include { CONVERT_TO_LIMELIGHT_XML_SEP } from "../modules/limelight_xml_convert_separate"
include { UPLOAD_TO_LIMELIGHT_SEP } from "../modules/limelight_upload_separate"

workflow wf_comet_separate_percolator {

    take:
        spectra_file_ch
        comet_params
        fasta
        from_raw_files
    
    main:

        // convert raw files to mzML files if necessary
        if(from_raw_files) {
            mzml_file_ch = MSCONVERT(spectra_file_ch)
        } else {
            // If starting with mzML files, create tuples with sample_id
            mzml_file_ch = spectra_file_ch.map { mzml_file -> 
                tuple(mzml_file.baseName, mzml_file) 
            }
        }

        COMET(mzml_file_ch, comet_params, fasta)
        FILTER_PIN(COMET.out.pin)

        PERCOLATOR(
            FILTER_PIN.out.filtered_pin,
            params.limelight_import_decoys
        )

        if (params.limelight_upload) {

            // Create paired channel by joining COMET and PERCOLATOR outputs
            // Both outputs have the same sample ID (base name of original raw file)
            paired_results = COMET.out.pepxml
                .join(PERCOLATOR.out.pout)
                .map { sample_id, comet_pepxml, percolator_pout ->
                    tuple(sample_id, comet_pepxml, percolator_pout)
                }

            CONVERT_TO_LIMELIGHT_XML_SEP(
                paired_results,
                fasta, 
                comet_params,
                params.limelight_import_decoys,
                params.limelight_entrapment_prefix ? params.limelight_entrapment_prefix : false
            )

            // Create paired channel for mzML files and limelight XML outputs
            upload_pairs = mzml_file_ch
                .join(CONVERT_TO_LIMELIGHT_XML_SEP.out.limelight_xml)
                .map { sample_id, mzml_file, limelight_xml ->
                    tuple(sample_id, mzml_file, limelight_xml)
                }

            UPLOAD_TO_LIMELIGHT_SEP(
                upload_pairs,
                fasta,
                params.limelight_webapp_url,
                params.limelight_project_id,
                params.limelight_search_description,
                params.limelight_search_short_name,
                params.limelight_tags,
            )
        }

}