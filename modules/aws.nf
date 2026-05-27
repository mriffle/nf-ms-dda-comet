// Bridge Nextflow secrets to AWS Batch tasks via AWS Secrets Manager.
//
// Native Nextflow secrets don't work on the awsbatch executor. These processes
// run LOCALLY on the launch host (executor 'local'), read the secret via the
// native `secret` directive, and upsert its value into AWS Secrets Manager
// under a deterministic per-user id. Batch tasks then fetch it back at runtime
// (see lib/AwsSecrets.fetchScript). Only invoked on the `aws` profile when the
// corresponding feature is actually used (see main.nf). See CLAUDE.md §4.9.
//
// These processes intentionally declare no container: they run on the host and
// need the host's AWS CLI + credentials (the `aws` profile / set_up_aws docs).

// Shell body shared by the BUILD_AWS_*_SECRET processes. secret_name is the env
// var injected by the `secret` directive; its value is stored as a plain string
// so Batch tasks can read it back with `--query SecretString --output text`.
def awsSecretUpsertScript(secret_name, secret_id, region) {
    """
    SECRET_VALUE="\$${secret_name}"

    {
        echo "Ensuring AWS Secrets Manager secret '${secret_id}' is current..."
        EXISTING_NAME=\$(aws secretsmanager list-secrets --region ${region} \
            --query "SecretList[?Name=='${secret_id}'].Name" --output text)

        if [ "\$EXISTING_NAME" == "${secret_id}" ]; then
            CURRENT=\$(aws secretsmanager get-secret-value --secret-id ${secret_id} \
                --region ${region} --query SecretString --output text)
            if [ "\$CURRENT" == "\$SECRET_VALUE" ]; then
                echo "Secret '${secret_id}' already current; no update needed."
            else
                aws secretsmanager update-secret --secret-id ${secret_id} \
                    --secret-string "\$SECRET_VALUE" --region ${region}
                echo "Secret '${secret_id}' updated."
            fi
        else
            aws secretsmanager create-secret --name ${secret_id} \
                --secret-string "\$SECRET_VALUE" --region ${region}
            echo "Secret '${secret_id}' created."
        fi
    } > >(tee "aws-setup-${secret_name}.stdout") 2> >(tee "aws-setup-${secret_name}.stderr" >&2)

    echo "Done!" # Needed for proper exit
    """
}

process GET_AWS_USER_ID {
    label 'process_low_constant'
    executor 'local'    // always run on the launch host
    cache false         // identity must be re-read each run

    output:
        stdout emit: aws_user_id

    script:
    """
    aws sts get-caller-identity --output text --query Arn | sed 's/.*user\\///' | tr -d '\\n'
    """

    stub:
    """
    printf 'STUB_USER_ID'
    """
}

process BUILD_AWS_PANORAMA_SECRET {
    label 'process_low_constant'
    secret 'PANORAMA_API_KEY'
    executor 'local'
    cache false
    publishDir "${params.result_dir}/aws", failOnError: true, mode: 'copy'

    input:
        val aws_user_id

    output:
        val secret_id, emit: aws_secret_id
        path("aws-setup-PANORAMA_API_KEY.stdout"), emit: stdout
        path("aws-setup-PANORAMA_API_KEY.stderr"), emit: stderr

    script:
        secret_id = AwsSecrets.secretId(aws_user_id, 'PANORAMA_KEY')
        awsSecretUpsertScript('PANORAMA_API_KEY', secret_id, params.aws_region)

    stub:
        secret_id = AwsSecrets.secretId(aws_user_id, 'PANORAMA_KEY')
        """
        touch "aws-setup-PANORAMA_API_KEY.stdout"
        touch "aws-setup-PANORAMA_API_KEY.stderr"
        """
}

process BUILD_AWS_LIMELIGHT_SECRET {
    label 'process_low_constant'
    secret 'LIMELIGHT_SUBMIT_UPLOAD_KEY'
    executor 'local'
    cache false
    publishDir "${params.result_dir}/aws", failOnError: true, mode: 'copy'

    input:
        val aws_user_id

    output:
        val secret_id, emit: aws_secret_id
        path("aws-setup-LIMELIGHT_SUBMIT_UPLOAD_KEY.stdout"), emit: stdout
        path("aws-setup-LIMELIGHT_SUBMIT_UPLOAD_KEY.stderr"), emit: stderr

    script:
        secret_id = AwsSecrets.secretId(aws_user_id, 'LIMELIGHT_KEY')
        awsSecretUpsertScript('LIMELIGHT_SUBMIT_UPLOAD_KEY', secret_id, params.aws_region)

    stub:
        secret_id = AwsSecrets.secretId(aws_user_id, 'LIMELIGHT_KEY')
        """
        touch "aws-setup-LIMELIGHT_SUBMIT_UPLOAD_KEY.stdout"
        touch "aws-setup-LIMELIGHT_SUBMIT_UPLOAD_KEY.stderr"
        """
}
