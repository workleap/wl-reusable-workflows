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

Export-ModuleMember -Function Resolve-Refs, Import-PolicyFromGit, Get-ChangedFiles, Find-RequiredChecks, Wait-RequiredChecks, Get-CheckRuns
