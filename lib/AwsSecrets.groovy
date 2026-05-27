//
// Helpers for bridging Nextflow secrets to AWS Batch tasks.
//
// Nextflow's native `secret` directive only works on the local and grid
// executors, NOT on AWS Batch. To keep secrets working on Batch without ever
// putting their values in nextflow.config, modules/aws.nf runs a LOCAL process
// that reads the secret (via the directive) and writes it into AWS Secrets
// Manager under a deterministic per-user id. Each Batch task then fetches it
// back at runtime with fetchScript() below. On local/grid the directive already
// provides the value, so fetchScript() is a no-op there.
//
class AwsSecrets {

    //
    // Deterministic AWS Secrets Manager id for a given AWS user + key suffix,
    // e.g. secretId('AReallyLongUserId', 'PANORAMA_KEY') -> 'NF_AReallyLongUserId_PANORAMA_KEY'.
    //
    static String secretId(awsUserId, keySuffix) {
        return "NF_${awsUserId.toString().trim()}_${keySuffix}"
    }

    //
    // Shell snippet (placed at the top of a process script) that ensures the
    // named secret is available as an environment variable inside the task.
    //
    // - awsbatch executor: fetch the value from AWS Secrets Manager (it was
    //   stored there as a plain string by modules/aws.nf) and export it.
    // - any other executor: the `secret` directive already exported it, so emit
    //   only a comment. awsSecretId/region are unused in this case (may be 'none'/null).
    //
    static String fetchScript(secretName, awsSecretId, region, executor) {
        if (executor != 'awsbatch') {
            return "# ${secretName} provided by Nextflow secret directive (executor: ${executor})"
        }
        return ("export ${secretName}=\$(aws secretsmanager get-secret-value" +
                " --secret-id ${awsSecretId} --region ${region}" +
                " --query SecretString --output text)").toString()
    }
}
