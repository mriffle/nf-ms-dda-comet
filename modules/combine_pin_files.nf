process COMBINE_PIN_FILES {
    publishDir "${params.result_dir}/percolator", failOnError: true, mode: 'copy'
    label 'process_low_constant'
    container params.images.ubuntu

    input:
        path pin_files

    output:
        path("combined.filtered.pin"), emit: combined_pin
        path("*.stderr"), emit: stderr

    script:
    command = ''

    // sort the files so subsequent runs of pipeline process files in same order
    pin_files.sort().indexed().collect { index, item ->
        if(index == 0) {
            command = command + "cat $item >combined.filtered.pin 2> >(tee combine-pin.stderr >&2)\n"
        } else {
            command = command + "sed 1d $item >>combined.filtered.pin 2>> >(tee combine-pin.stderr >&2)\n"
        }
    }


    """
    echo "Combining pin files..."
    $command
    echo "DONE!" # Needed for proper exit
    """

    stub:
    """
    touch combined.filtered.pin
    touch combine-pin.stderr
    """
}