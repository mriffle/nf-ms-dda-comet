// Modules
include { MSCONVERT } from "../modules/msconvert"
include { COMET } from "../modules/comet"
include { PERCOLATOR } from "../modules/percolator"
include { FILTER_PIN } from "../modules/filter_pin"
include { COMBINE_PIN_FILES } from "../modules/combine_pin_files"
include { CONVERT_TO_LIMELIGHT_XML_COM } from "../modules/limelight_xml_convert_combined"
include { UPLOAD_TO_LIMELIGHT_COM } from "../modules/limelight_upload_combined"

workflow wf_comet_combined_percolator {

    take:
        spectra_file_ch
        comet_params
        fasta
        from_raw_files
        limelight_secret_id
        limelight_config_files

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

        filtered_pin_files = FILTER_PIN.out.filtered_pin.map { it[1] }.collect()
        COMBINE_PIN_FILES(filtered_pin_files)

        combined_pin_tuple = Channel.of("combined").combine(COMBINE_PIN_FILES.out.combined_pin)
        PERCOLATOR(
            combined_pin_tuple,
            Utils.asBool(params.limelight_import_decoys)
        )

        if (Utils.asBool(params.limelight_upload)) {

            CONVERT_TO_LIMELIGHT_XML_COM(
                COMET.out.pepxml.map { it[1] }.collect(), 
                PERCOLATOR.out.pout.map { it[1] },
                fasta, 
                comet_params,
                Utils.asBool(params.limelight_import_decoys),
                params.limelight_entrapment_prefix ? params.limelight_entrapment_prefix : false
            )

            UPLOAD_TO_LIMELIGHT_COM(
                CONVERT_TO_LIMELIGHT_XML_COM.out.limelight_xml,
                mzml_file_ch.map { it[1] }.collect(),
                fasta,
                limelight_config_files,
                params.limelight_webapp_url,
                params.limelight_project_id,
                params.limelight_search_description,
                params.limelight_search_short_name,
                params.limelight_tags,
                limelight_secret_id,
            )
        }

}
