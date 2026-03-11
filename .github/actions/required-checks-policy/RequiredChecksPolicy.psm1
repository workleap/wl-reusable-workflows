$ErrorActionPreference = "Stop"

function Resolve-Refs {
    param(
        [string]$CommitId,
        [string]$BaseRef,
        [string]$HeadRef,
        [string]$RefName,
        [string]$DefaultBranch
    )

    if (!$HeadRef) {
        $HeadRef = $RefName
    }

    if (!$BaseRef) {
        Write-Host "Base ref is not set. Falling back to default branch '$DefaultBranch'."
        $BaseRef = $DefaultBranch
    }

    Write-Host "Change description:"
    Write-Host "Commit ID: $CommitId"
    Write-Host "Base Ref: $BaseRef"
    Write-Host "Head Ref: $HeadRef"
    Write-Host ""

    return @{
        BaseRef = $BaseRef
        HeadRef = $HeadRef
    }
}

function Import-PolicyFromGit {
    param(
        [Parameter(Mandatory)]
        [string]$PolicyPath,

        [Parameter(Mandatory)]
        [string]$BaseRef
    )

    $FullBaseRef = "refs/remotes/origin/$BaseRef"
    Write-Host "Loading policy at '$PolicyPath' in ref '$BaseRef'"

    try {
        $policyContent = git show "${FullBaseRef}:$PolicyPath" 2>$null
    } catch {
        Write-Host "::group::Available git references"
        git show-ref
        Write-Host "::endgroup::"

        Write-Host "::group::Available files in $FullBaseRef"
        git ls-tree --full-tree -r --name-only "$FullBaseRef"
        Write-Host "::endgroup::"

        Write-Error "Failed to load policy file from '$BaseRef' branch at '$PolicyPath'. Make sure the file exists in the target branch and that the path is relative to the root of the repository."
    }

    $policy = $policyContent | ConvertFrom-Json
    if (-not $policy) {
        Write-Error "Policy is not defined or is empty."
    }

    Write-Host "::group::Policy details"
    Write-Host ($policy | ConvertTo-Json -Depth 10)
    Write-Host "::endgroup::"

    return $policy
}

function Get-ChangedFiles {
    param(
        [Parameter(Mandatory)]
        [string]$BaseRef,

        [Parameter(Mandatory)]
        [string]$HeadRef
    )

    $diff = (git diff --name-only "refs/remotes/origin/$BaseRef...refs/remotes/origin/$HeadRef") | Where-Object { $_ }
    return $diff
}

function Find-RequiredChecks {
    param(
        [Parameter(Mandatory)]
        [object[]]$Policy,

        [Parameter(Mandatory)]
        [string]$BaseRef,

        [Parameter(Mandatory)]
        [string]$HeadRef
    )

    Write-Host "::group::Finding required checks for changed files"
    $requiredChecks = @()
    foreach ($item in $Policy) {
        $checks = $item.checks
        $paths = $item.paths

        $pathspecs = @()
        foreach ($path in $paths) {
            if (-not $path) {
                continue
            }

            if ($path.StartsWith("!")) {
                Write-Error "Path exclusions starting with '!' are not supported in the policy. Please use ':(exclude)<path>' syntax instead (https://git-scm.com/docs/gitglossary#Documentation/gitglossary.txt-pathspec). Invalid path: '$path'"
            }

            $pathspecs += $path
        }

        if ($pathspecs.Count -eq 0) {
            Write-Host "Warning: No valid paths found in policy item. Skipping."
            continue
        }

        $gitArgs = @("diff", "--name-only", "refs/remotes/origin/$BaseRef...refs/remotes/origin/$HeadRef", "--")
        $gitArgs += $pathspecs

        $diff = (& git @gitArgs) | Where-Object { $_ }
        if ($diff) {
            Write-Host "Paths '$($paths -join "', '")' have changes. Adding required checks: $($checks -join ', ')"
            foreach ($check in $checks) {
                $requiredChecks += $check
            }
        }
    }
    Write-Host "::endgroup::"
    Write-Host ""

    return ($requiredChecks | Sort-Object -Unique)
}

function Wait-RequiredChecks {
    param(
        [Parameter(Mandatory)]
        [string[]]$RequiredChecks,

        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        [string]$HeadRef,

        [Parameter(Mandatory)]
        [int]$TimeoutMinutesCreatedChecks,

        [Parameter(Mandatory)]
        [int]$TimeoutMinutesQueuedChecks
    )

    Write-Host "Required checks for changed paths:"
    $RequiredChecks | ForEach-Object {
        Write-Host "- $_"
    }
    Write-Host ""

    Write-Host "Waiting for required checks to complete..."
    $url = "repos/$Repository/commits/$HeadRef/check-runs?filter=latest&per_page=100"
    Write-Debug "API URL: $url"

    $attempt = 0
    $TimeoutCreated = New-TimeSpan -Minutes $TimeoutMinutesCreatedChecks
    $TimeoutQueued = New-TimeSpan -Minutes $TimeoutMinutesQueuedChecks
    $startedAt = Get-Date -AsUTC
    $CompletedCheckIds = @()

    while ($true) {
        $checkRuns = Get-CheckRuns -Url $url

        Write-Host "::group::Response for $url (attempt $($attempt + 1))"
        Write-Host "$($checkRuns | ConvertTo-Json -Compress -Depth 10)"
        Write-Host "::endgroup::"

        $completed = $true
        $NewlyCompletedChecks = @()
        foreach ($requiredCheck in $RequiredChecks) {
            $checkRunsMatchingRequiredCheck = @($checkRuns.check_runs | Where-Object { $_.name -eq $requiredCheck })

            if ($checkRunsMatchingRequiredCheck.Count -eq 0) {
                $completed = $false
                if ((Get-Date -AsUTC) - $startedAt -gt $TimeoutCreated) {
                    $checkNames = $checkRuns.check_runs | ForEach-Object { "- $($_.name)" } | Sort-Object -Unique
                    Write-Error "Check '$requiredCheck' wasn't created after $($TimeoutCreated.TotalMinutes) minutes (timeout-minutes-created-checks: $TimeoutMinutesCreatedChecks). Available checks:`n$($checkNames -join "`n")"
                }
            }
            else {
                foreach ($check in $checkRunsMatchingRequiredCheck) {
                    if ($check.status -eq "completed") {
                        if ($check.conclusion -ne "success") {
                            Write-Error "Check '$requiredCheck' failed with conclusion: $($check.conclusion). Details: $($check.html_url)"
                        }
                        else {
                            if ($CompletedCheckIds -notcontains $check.id) {
                                $NewlyCompletedChecks += [PSCustomObject]@{
                                    Name = $requiredCheck
                                    Id = $check.id
                                    Url = $check.html_url
                                }
                                $CompletedCheckIds += $check.id
                            }
                        }
                    }
                    elseif ($check.status -eq "queued") {
                        $completed = $false
                        if ((Get-Date -AsUTC) - $startedAt -gt $TimeoutQueued) {
                            Write-Error "Check '$requiredCheck' is still queued after $($TimeoutQueued.TotalMinutes) minutes (timeout-minutes-queued-checks: $TimeoutMinutesQueuedChecks). Details: $($check.html_url)"
                        }
                    }
                    else {
                        $completed = $false
                        Write-Debug "Check '$requiredCheck' is in status '$($check.status)'. Waiting..."
                    }
                }
            }
        }

        if ($NewlyCompletedChecks.Count -gt 0) {
            foreach ($completedCheck in $NewlyCompletedChecks) {
                Write-Host "Check '$($completedCheck.Name)' completed successfully. Details: $($completedCheck.Url)"
            }
        }

        if ($completed) {
            Write-Host "All required checks have passed."
            return
        }

        $attempt += 1
        $WaitTime = 10 * $attempt
        if ($WaitTime -gt 60) {
            $WaitTime = 60
        }

        $InfoLog = ""
        if ($CompletedCheckIds.Count -gt 0) {
            $completedCheckDetails = $checkRuns.check_runs | Where-Object { $CompletedCheckIds -contains $_.id } | ForEach-Object { "$($_.name) (ID: $($_.id))" } | Sort-Object
            $InfoLog += "Completed checks: $($completedCheckDetails -join ', ')."
        }
        else {
            $InfoLog += "No checks completed yet."
        }

        Write-Host "$InfoLog Waiting for $WaitTime seconds before checking again..."
        Start-Sleep -Seconds $WaitTime
    }
}

function Get-CheckRuns {
    param(
        [Parameter(Mandatory)]
        [string]$Url
    )

    try {
        $rawResponse = gh api --paginate --slurp $Url
        $pages = $rawResponse | ConvertFrom-Json

        $allCheckRuns = @()
        foreach ($page in $pages) {
            if ($page.check_runs) {
                $allCheckRuns += $page.check_runs
            }
        }

        return [PSCustomObject]@{
            check_runs = $allCheckRuns
            total_count = $allCheckRuns.Count
        }
    }
    catch {
        Write-Error "Failed to call GitHub API. Raw response: $rawResponse. Error details: $_"
        throw
    }
}

function Initialize-GlobMatcher {
    $scriptDir = $PSScriptRoot
    if (-not $scriptDir) {
        $scriptDir = Split-Path -Parent $MyInvocation.ScriptName
    }

    $globMatchScript = Join-Path $scriptDir "glob-match.js"
    if (-not (Test-Path $globMatchScript)) {
        Write-Error "glob-match.js not found at '$scriptDir'. Cannot initialize glob matcher."
    }

    $nodeModules = Join-Path $scriptDir "node_modules"
    if (-not (Test-Path $nodeModules)) {
        Write-Host "Installing node dependencies for glob matching..."
        Push-Location $scriptDir
        npm ci --no-audit --no-fund 2>&1 | Out-Null
        Pop-Location
    }

    $script:GlobMatchScript = $globMatchScript
}

function Test-GlobMatch {
    param(
        [Parameter(Mandatory)]
        [string]$Value,

        [Parameter(Mandatory)]
        [string]$Pattern
    )

    if (-not $script:GlobMatchScript) {
        Initialize-GlobMatcher
    }

    $json = @{ value = $Value; pattern = $Pattern } | ConvertTo-Json -Compress
    $result = node $script:GlobMatchScript $json
    return $result -eq "true"
}

function Get-WorkflowFilesFromGit {
    param(
        [Parameter(Mandatory)]
        [string]$BaseRef
    )

    $FullBaseRef = "refs/remotes/origin/$BaseRef"
    Write-Host "Listing workflow files from '$FullBaseRef'"

    $files = git ls-tree --name-only "${FullBaseRef}:.github/workflows" 2>$null
    if (-not $files) {
        Write-Host "No workflow files found in .github/workflows/"
        return @()
    }

    $workflows = @()
    foreach ($file in $files) {
        if ($file -notmatch '\.(yml|yaml)$') {
            continue
        }

        $path = ".github/workflows/$file"
        $content = git show "${FullBaseRef}:$path" 2>$null
        if ($content) {
            $workflows += @{
                Path    = $path
                Content = ($content -join "`n")
            }
        }
    }

    Write-Host "Found $($workflows.Count) workflow file(s)"
    return $workflows
}

function Find-WlNotRequired {
    param(
        [Parameter(Mandatory)]
        [string]$RawContent
    )

    $result = @{
        IsWorkflowOptOut = $false
        OptOutTriggers   = @()
        OptOutJobs       = @()
    }

    $lines = $RawContent -split "`n"

    # Check workflow-level opt-out: first non-empty line
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '') {
            continue
        }
        if ($trimmed -match '# wl-not-required') {
            $result.IsWorkflowOptOut = $true
        }
        break
    }

    if ($result.IsWorkflowOptOut) {
        return $result
    }

    # Track sections to determine trigger-level vs job-level
    $inOnSection = $false
    $inJobsSection = $false
    $previousLineIsOptOut = $false

    foreach ($line in $lines) {
        $trimmed = $line.Trim()

        # Track top-level sections
        if ($line -match '^on\s*:' -or $line -match '^"on"\s*:' -or $line -match "^'on'\s*:") {
            $inOnSection = $true
            $inJobsSection = $false
            $previousLineIsOptOut = $false
            continue
        }
        if ($line -match '^jobs\s*:') {
            $inOnSection = $false
            $inJobsSection = $true
            $previousLineIsOptOut = $false
            continue
        }
        # Any other top-level key resets sections
        if ($line -match '^\S' -and $trimmed -ne '' -and $trimmed -notmatch '^#') {
            $inOnSection = $false
            $inJobsSection = $false
            $previousLineIsOptOut = $false
            continue
        }

        # Check for wl-not-required comment
        if ($trimmed -match '# wl-not-required') {
            $previousLineIsOptOut = $true
            continue
        }

        # Skip empty lines and other comments (they don't break the "immediately before" chain)
        if ($trimmed -eq '' -or $trimmed -match '^#') {
            continue
        }

        # This is a non-comment, non-empty line
        if ($previousLineIsOptOut) {
            if ($inOnSection) {
                # Extract trigger name (indented key under on:)
                if ($trimmed -match '^(\S+)\s*:') {
                    $result.OptOutTriggers += $Matches[1]
                }
            }
            elseif ($inJobsSection) {
                # Extract job name (indented key under jobs:)
                if ($trimmed -match '^(\S+)\s*:') {
                    $result.OptOutJobs += $Matches[1]
                }
            }
        }

        $previousLineIsOptOut = $false
    }

    return $result
}

function Test-WorkflowTriggers {
    param(
        [Parameter(Mandatory)]
        [object]$WorkflowOn,

        [Parameter(Mandatory)]
        [string]$BaseRef,

        [Parameter(Mandatory)]
        [string]$HeadRef,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ChangedFiles,

        [Parameter(Mandatory)]
        [hashtable]$OptOuts
    )

    # Normalize the 'on' value to a hashtable of trigger configs
    $triggers = @{}

    if ($WorkflowOn -is [string]) {
        # on: push
        $triggers[$WorkflowOn] = @{}
    }
    elseif ($WorkflowOn -is [System.Collections.IList]) {
        # on: [push, pull_request]
        foreach ($t in $WorkflowOn) {
            $triggers["$t"] = @{}
        }
    }
    elseif ($WorkflowOn -is [System.Collections.IDictionary] -or $WorkflowOn -is [System.Collections.Specialized.OrderedDictionary]) {
        foreach ($key in $WorkflowOn.Keys) {
            $val = $WorkflowOn[$key]
            if ($null -eq $val) {
                $triggers["$key"] = @{}
            }
            elseif ($val -is [System.Collections.IDictionary] -or $val -is [System.Collections.Specialized.OrderedDictionary]) {
                $triggers["$key"] = $val
            }
            else {
                $triggers["$key"] = @{}
            }
        }
    }

    $relevantTriggers = @('push', 'pull_request', 'pull_request_target')

    foreach ($triggerName in $relevantTriggers) {
        if (-not $triggers.ContainsKey($triggerName)) {
            continue
        }

        if ($OptOuts.OptOutTriggers -contains $triggerName) {
            Write-Host "  Trigger '$triggerName' is opted out via wl-not-required"
            continue
        }

        $config = $triggers[$triggerName]

        # Determine which branch to match
        $branchToMatch = if ($triggerName -eq 'push') { $HeadRef } else { $BaseRef }

        # Check branch filters
        $branchMatch = $true
        if ($config.ContainsKey('branches') -and $config['branches']) {
            $branchMatch = $false
            foreach ($pattern in $config['branches']) {
                if (Test-GlobMatch -Value $branchToMatch -Pattern $pattern) {
                    $branchMatch = $true
                    break
                }
            }
        }
        if ($config.ContainsKey('branches-ignore') -and $config['branches-ignore']) {
            foreach ($pattern in $config['branches-ignore']) {
                if (Test-GlobMatch -Value $branchToMatch -Pattern $pattern) {
                    $branchMatch = $false
                    break
                }
            }
        }

        if (-not $branchMatch) {
            continue
        }

        # Check path filters
        $pathMatch = $true
        if ($config.ContainsKey('paths') -and $config['paths']) {
            $pathMatch = $false
            foreach ($changedFile in $ChangedFiles) {
                foreach ($pattern in $config['paths']) {
                    if (Test-GlobMatch -Value $changedFile -Pattern $pattern) {
                        $pathMatch = $true
                        break
                    }
                }
                if ($pathMatch) { break }
            }
        }
        if ($config.ContainsKey('paths-ignore') -and $config['paths-ignore']) {
            # All changed files must be in the ignore list for the trigger to NOT fire
            $allIgnored = $true
            foreach ($changedFile in $ChangedFiles) {
                $fileIgnored = $false
                foreach ($pattern in $config['paths-ignore']) {
                    if (Test-GlobMatch -Value $changedFile -Pattern $pattern) {
                        $fileIgnored = $true
                        break
                    }
                }
                if (-not $fileIgnored) {
                    $allIgnored = $false
                    break
                }
            }
            if ($allIgnored) {
                $pathMatch = $false
            }
        }

        if ($pathMatch) {
            return $true
        }
    }

    return $false
}

function Find-AutoDiscoveredChecks {
    param(
        [Parameter(Mandatory)]
        [string]$BaseRef,

        [Parameter(Mandatory)]
        [string]$HeadRef,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ChangedFiles
    )

    Write-Host "::group::Auto-discovering required checks from workflow files"

    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        Write-Host "Installing powershell-yaml module..."
        Install-Module powershell-yaml -Force -Scope CurrentUser
    }
    Import-Module powershell-yaml

    $workflows = Get-WorkflowFilesFromGit -BaseRef $BaseRef
    if (-not $workflows -or $workflows.Count -eq 0) {
        Write-Host "No workflow files found. Skipping auto-discovery."
        Write-Host "::endgroup::"
        return @()
    }

    $requiredChecks = @()

    foreach ($wf in $workflows) {
        Write-Host "Processing workflow: $($wf.Path)"

        $optOuts = Find-WlNotRequired -RawContent $wf.Content
        if ($optOuts.IsWorkflowOptOut) {
            Write-Host "  Workflow is opted out via wl-not-required"
            continue
        }

        $parsed = ConvertFrom-Yaml $wf.Content
        if (-not $parsed) {
            Write-Host "  Failed to parse workflow YAML. Skipping."
            continue
        }

        # Get the 'on' key (may be 'on' or 'true' due to YAML parsing of bare 'on')
        $onConfig = $null
        if ($parsed.ContainsKey('on')) {
            $onConfig = $parsed['on']
        }
        elseif ($parsed.ContainsKey('true')) {
            # YAML parsers may interpret bare 'on' as boolean true
            $onConfig = $parsed['true']
        }

        if (-not $onConfig) {
            Write-Host "  No 'on' triggers found. Skipping."
            continue
        }

        # Check if the workflow only has workflow_call (reusable workflow)
        $hasRelevantTrigger = $false
        if ($onConfig -is [string]) {
            $hasRelevantTrigger = $onConfig -in @('push', 'pull_request', 'pull_request_target')
        }
        elseif ($onConfig -is [System.Collections.IList]) {
            foreach ($t in $onConfig) {
                if ("$t" -in @('push', 'pull_request', 'pull_request_target')) {
                    $hasRelevantTrigger = $true
                    break
                }
            }
        }
        elseif ($onConfig -is [System.Collections.IDictionary] -or $onConfig -is [System.Collections.Specialized.OrderedDictionary]) {
            foreach ($key in $onConfig.Keys) {
                if ("$key" -in @('push', 'pull_request', 'pull_request_target')) {
                    $hasRelevantTrigger = $true
                    break
                }
            }
        }

        if (-not $hasRelevantTrigger) {
            Write-Host "  No push/pull_request triggers. Skipping."
            continue
        }

        $shouldTrigger = Test-WorkflowTriggers -WorkflowOn $onConfig -BaseRef $BaseRef -HeadRef $HeadRef -ChangedFiles $ChangedFiles -OptOuts $optOuts
        if (-not $shouldTrigger) {
            Write-Host "  Workflow would not trigger for this change. Skipping."
            continue
        }

        # Collect job keys
        $jobs = $parsed['jobs']
        if (-not $jobs) {
            Write-Host "  No jobs found. Skipping."
            continue
        }

        foreach ($jobKey in $jobs.Keys) {
            if ($optOuts.OptOutJobs -contains $jobKey) {
                Write-Host "  Job '$jobKey' is opted out via wl-not-required"
                continue
            }
            Write-Host "  Adding required check: $jobKey"
            $requiredChecks += $jobKey
        }
    }

    Write-Host "::endgroup::"
    Write-Host ""

    return ($requiredChecks | Sort-Object -Unique)
}

Export-ModuleMember -Function Resolve-Refs, Import-PolicyFromGit, Get-ChangedFiles, Find-RequiredChecks, Wait-RequiredChecks, Get-CheckRuns, Initialize-GlobMatcher, Test-GlobMatch, Get-WorkflowFilesFromGit, Find-WlNotRequired, Test-WorkflowTriggers, Find-AutoDiscoveredChecks
