process CONVERT_TO_LIMELIGHT_XML_SEP {
    publishDir "${params.result_dir}/limelight", failOnError: true, mode: 'copy'
    label 'process_low'
    label 'process_high_memory'
    label 'process_long'
    container params.images.limelight_xml_convert

    input:
        tuple val(sample_id), path(pepxml), path(pout)
        path fasta
        path comet_params
        val import_decoys
        val entrapment_prefix

    output:
        tuple val(sample_id), path("${sample_id}.limelight.xml"), emit: limelight_xml
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:

    decoy_import_flag = import_decoys ? '--import-decoys' : ''
    entrapment_flag = entrapment_prefix ? "--independent-decoy-prefix=${entrapment_prefix}" : ''

    """
    echo "Running Limelight XML conversion for ${sample_id}..."
        ${exec_java_command(task.memory)} \
        -c ${comet_params} \
        -f ${fasta} \
        -p ${pout} \
        -d . \
        -o ${sample_id}.limelight.xml \
        -v ${decoy_import_flag} ${entrapment_flag} \
        > >(tee "${sample_id}.limelight-xml-convert.stdout") 2> >(tee "${sample_id}.limelight-xml-convert.stderr" >&2)
        

    echo "Done!" # Needed for proper exit
    """

    stub:
    """
    touch "${sample_id}.limelight.xml"
    touch "${sample_id}.limelight-xml-convert.stdout"
    touch "${sample_id}.limelight-xml-convert.stderr"
    """
}