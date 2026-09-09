@{
    ExcludeRules = @(
        # Write-Host is intentional here: these are top-level, interactive
        # installer scripts meant to always print status to the console
        # regardless of how output is redirected, not library code whose
        # output should stay in the pipeline.
        'PSAvoidUsingWriteHost',

        # False positive: $Branch is read inside the Invoke-Patch function
        # via PowerShell's normal scope capture (a nested/later function in
        # the same script sees the script-scope parameter), which the
        # analyzer's per-function usage check doesn't trace across function
        # boundaries.
        'PSReviewUnusedParameter',

        # False positive: Write-Log here is this script's own local helper
        # function, not a real PowerShell cmdlet in any installed module.
        'PSAvoidOverwritingBuiltInCmdlets'
    )
}
