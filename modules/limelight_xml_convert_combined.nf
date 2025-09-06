def exec_java_command(mem) {
    def xmx = "-Xmx${mem.toGiga()-1}G"
    return "java -Djava.aws.headless=true ${xmx} -jar /usr/local/bin/cometPercolator2LimelightXML.jar"
}

process CONVERT_TO_LIMELIGHT_XML_COM {
    publishDir "${params.result_dir}/limelight", failOnError: true, mode: 'copy'
    label 'process_low'
    label 'process_high_memory'
    label 'process_long'
    container params.images.limelight_xml_convert

    input:
        path pepxml
        path pout
        path fasta
        path comet_params
        val import_decoys
        val entrapment_prefix

    output:
        path("results.limelight.xml"), emit: limelight_xml
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:

    decoy_import_flag = import_decoys ? '--import-decoys' : ''
    entrapment_flag = entrapment_prefix ? "--independent-decoy-prefix=${entrapment_prefix}" : ''

    """
    echo "Running Limelight XML conversion..."
        ${exec_java_command(task.memory)} \
        -c ${comet_params} \
        -f ${fasta} \
        -p ${pout} \
        -d . \
        -o results.limelight.xml \
        -v ${decoy_import_flag} ${entrapment_flag} \
        > >(tee "limelight-xml-convert.stdout") 2> >(tee "limelight-xml-convert.stderr" >&2)
        

    echo "Done!" # Needed for proper exit
    """

    stub:
    """
    touch "results.limelight.xml"
    """
}
