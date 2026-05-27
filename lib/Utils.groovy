//
// Small shared helpers, available to every .nf file on the lib/ classpath
// (no import needed — used as Utils.<method>, like AwsSecrets / EmailTemplate).
//

class Utils {
    //
    // Interpret a parameter as a boolean.
    //
    // Nextflow 26's strict (v2) language no longer coerces a command-line
    // `--flag false` into a boolean — it arrives as the String "false", which
    // is truthy in Groovy, so `if (params.flag)` would take the wrong branch.
    // This normalises both real booleans (from config defaults) and the
    // "true"/"false" strings (from the CLI) to a real boolean. Use it for every
    // boolean param read in a truthy context.
    //
    public static boolean asBool(value) {
        if (value instanceof Boolean) return value
        return value?.toString()?.toBoolean() ?: false
    }
}
