def exec_java_command(mem) {
    def xmx = "-Xmx${mem.toGiga()-1}G"
    return "java -Djava.awt.headless=true ${xmx} -jar /usr/local/bin/limelightSubmitImport.jar"
}

process UPLOAD_TO_LIMELIGHT_SEP {
    publishDir "${params.result_dir}/limelight", failOnError: true, mode: 'copy'
    label 'process_low'
    container params.images.limelight_upload
    secret 'LIMELIGHT_SUBMIT_UPLOAD_KEY'

    input:
        tuple val(sample_id), path(mzml_file), path(limelight_xml)
        path fasta
        path config_files
        val webapp_url
        val project_id
        val search_long_name
        val search_short_name
        val tags
        val aws_secret_id

    output:
        path("*.stdout"), emit: stdout
        path("*.stderr"), emit: stderr

    script:

    tags_param = ''
    if(tags) {
        tags_param = "--search-tag=\"${tags.split(',').join('\" --search-tag=\"')}\""
    }

    // Attach the user-supplied config file(s), with smtp credentials redacted
    // (sed replaces the staged symlink with a sanitized copy; the original on
    // disk is untouched).
    config_names = config_files ? (config_files as List).collect { it.name } : []
    add_file_params = config_names.collect { "--add-file=\"${it}\"" }.join(' ')
    sanitize_configs = config_names.collect {
        "sed -i -E -e \"s/smtp\\.password\\s*=\\s*'[^']*'/smtp.password = 'PASSWORD HIDDEN'/g\" -e \"s/smtp\\.user\\s*=\\s*'[^']*'/smtp.user = 'USER HIDDEN'/g\" \"${it}\""
    }.join('\n    ')

    """
    ${AwsSecrets.fetchScript('LIMELIGHT_SUBMIT_UPLOAD_KEY', aws_secret_id, params.aws_region, task.executor)}

    ${sanitize_configs}

    echo "Submitting search results for Limelight import (${sample_id})..."
        ${exec_java_command(task.memory)} \
        --retry-count-limit=5 \
        --limelight-web-app-url=${webapp_url} \
        --user-submit-import-key=\$LIMELIGHT_SUBMIT_UPLOAD_KEY \
        --project-id=${project_id} \
        --limelight-xml-file=${limelight_xml} \
        --fasta-file=${fasta} \
        --search-description="${search_long_name} (${sample_id})" \
        --path="${workflow.launchDir}" \
        --scan-file=${mzml_file} \
        ${add_file_params} \
        ${tags_param} \
        > >(tee "${sample_id}.limelight-submit-upload.stdout") 2> >(tee "${sample_id}.limelight-submit-upload.stderr" >&2)
    echo "Done!" # Needed for proper exit
    """

    stub:
    """
    : "\${LIMELIGHT_SUBMIT_UPLOAD_KEY:?LIMELIGHT_SUBMIT_UPLOAD_KEY not available to process}"
    touch "${sample_id}.limelight-submit-upload.stdout"
    touch "${sample_id}.limelight-submit-upload.stderr"
    """
}