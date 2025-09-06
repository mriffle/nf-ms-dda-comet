process PERCOLATOR {
    publishDir "${params.result_dir}/percolator", failOnError: true, mode: 'copy'
    label 'process_medium'
    label 'process_high_memory'
    label 'process_long'
    container params.images.percolator

    input:
        tuple val(sample_id), path(pin_file)
        val import_decoys

    output:
        tuple val(sample_id), path("${sample_id}.pout.xml"), emit: pout
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:

    decoy_import_flag = import_decoys ? '-Z' : ''

    """
    echo "Running percolator..."
    percolator \
        ${decoy_import_flag} -X "${sample_id}.pout.xml" \
        ${pin_file} \
        > >(tee "${sample_id}.percolator.stdout") 2> >(tee "${sample_id}.percolator.stderr" >&2)
    echo "Done!" # Needed for proper exit
    """

    stub:
    """
    touch "${sample_id}.pout.xml"
    touch "${sample_id}.percolator.stdout"
    touch "${sample_id}.percolator.stderr"
    """
}