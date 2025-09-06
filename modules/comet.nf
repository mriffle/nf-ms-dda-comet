
process COMET {
    publishDir "${params.result_dir}/comet", failOnError: true, mode: 'copy'
    label 'process_high_constant'
    container params.images.comet

    input:
        tuple val(sample_id), path(mzml_file)
        path comet_params_file
        path fasta_file

    output:
        tuple val(sample_id), path("${sample_id}.pep.xml"), emit: pepxml
        tuple val(sample_id), path("${sample_id}.pin"), emit: pin
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:
    // sample_id is already provided from the input tuple

    """
    echo "Running comet..."
    comet \
        -P${comet_params_file} \
        -D${fasta_file} \
        ${mzml_file} \
        > >(tee "${sample_id}.comet.stdout") 2> >(tee "${sample_id}.comet.stderr" >&2)

    echo "DONE!" # Needed for proper exit
    """

    stub:
    // sample_id is already provided from the input tuple
    """
    touch "${sample_id}.pep.xml"
    touch "${sample_id}.pin"
    touch "${sample_id}.comet.stdout"
    touch "${sample_id}.comet.stderr"
    """
}