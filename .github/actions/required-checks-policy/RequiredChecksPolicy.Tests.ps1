BeforeAll {
    Import-Module "$PSScriptRoot/RequiredChecksPolicy.psm1" -Force

    # Helper to create a test git repo with a bare origin and a clone.
    # Main branch has: service1/app.ts, service2/app.ts, shared/util.ts, policy.json
    # Feature branch adds: service1/new-file.txt, modifies shared/util.ts
    function New-TestGitRepo {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "pester-git-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $tempRoot | Out-Null

        $bareRepo = Join-Path $tempRoot "origin.git"
        $cloneRepo = Join-Path $tempRoot "clone"

        # Create bare origin
        git init --bare $bareRepo 2>&1 | Out-Null

        # Clone it
        git clone $bareRepo $cloneRepo 2>&1 | Out-Null
        Push-Location $cloneRepo

        git config user.email "test@test.com"
        git config user.name "Test"

        # Create main branch with files
        New-Item -ItemType Directory -Path "service1" -Force | Out-Null
        New-Item -ItemType Directory -Path "service2" -Force | Out-Null
        New-Item -ItemType Directory -Path "shared" -Force | Out-Null

        Set-Content -Path "service1/app.ts" -Value "service1 content"
        Set-Content -Path "service2/app.ts" -Value "service2 content"
        Set-Content -Path "shared/util.ts" -Value "shared content"

        $policyContent = @(
            [PSCustomObject]@{ checks = @("build-service1"); paths = @("service1/") }
            [PSCustomObject]@{ checks = @("build-service2"); paths = @("service2/") }
        ) | ConvertTo-Json -Depth 10

        Set-Content -Path "policy.json" -Value $policyContent

        git add -A 2>&1 | Out-Null
        git commit -m "Initial commit" 2>&1 | Out-Null
        git push origin main 2>&1 | Out-Null

        # Create feature branch with changes in service1 and shared
        git checkout -b feature 2>&1 | Out-Null
        Set-Content -Path "service1/new-file.txt" -Value "new file"
        Set-Content -Path "shared/util.ts" -Value "shared content modified"
        git add -A 2>&1 | Out-Null
        git commit -m "Feature changes" 2>&1 | Out-Null
        git push origin feature 2>&1 | Out-Null

        Pop-Location

        return @{
            Root      = $tempRoot
            ClonePath = $cloneRepo
        }
    }
}

Describe "Resolve-Refs" {
    It "Returns HeadRef and BaseRef as-is when both are provided" {
        $result = Resolve-Refs -CommitId "abc123" -BaseRef "main" -HeadRef "feature" -RefName "unused" -DefaultBranch "main"
        $result.BaseRef | Should -Be "main"
        $result.HeadRef | Should -Be "feature"
    }

    It "Falls back to RefName when HeadRef is empty" {
        $result = Resolve-Refs -CommitId "abc123" -BaseRef "main" -HeadRef "" -RefName "my-branch" -DefaultBranch "main"
        $result.HeadRef | Should -Be "my-branch"
    }

    It "Falls back to DefaultBranch when BaseRef is empty" {
        $result = Resolve-Refs -CommitId "abc123" -BaseRef "" -HeadRef "feature" -RefName "" -DefaultBranch "develop"
        $result.BaseRef | Should -Be "develop"
    }

    It "Falls back to both defaults when HeadRef and BaseRef are empty" {
        $result = Resolve-Refs -CommitId "abc123" -BaseRef "" -HeadRef "" -RefName "push-branch" -DefaultBranch "main"
        $result.BaseRef | Should -Be "main"
        $result.HeadRef | Should -Be "push-branch"
    }
}

Describe "Import-PolicyFromGit" {
    BeforeAll {
        $script:testRepo = New-TestGitRepo
        Push-Location $script:testRepo.ClonePath
    }

    AfterAll {
        Pop-Location
        Remove-Item -Recurse -Force $script:testRepo.Root
    }

    It "Loads and parses the policy from the base branch" {
        $policy = Import-PolicyFromGit -PolicyPath "policy.json" -BaseRef "main"
        $policy | Should -Not -BeNullOrEmpty
        $policy.Count | Should -Be 2
        $policy[0].checks | Should -Contain "build-service1"
        $policy[1].checks | Should -Contain "build-service2"
    }

    It "Throws when the policy file does not exist" {
        { Import-PolicyFromGit -PolicyPath "nonexistent.json" -BaseRef "main" } | Should -Throw "*Policy is not defined or is empty*"
    }
}

Describe "Get-ChangedFiles" {
    BeforeAll {
        $script:testRepo = New-TestGitRepo
        Push-Location $script:testRepo.ClonePath
    }

    AfterAll {
        Pop-Location
        Remove-Item -Recurse -Force $script:testRepo.Root
    }

    It "Returns changed files between base and head" {
        $result = Get-ChangedFiles -BaseRef "main" -HeadRef "feature"
        $result | Should -Contain "service1/new-file.txt"
        $result | Should -Contain "shared/util.ts"
        $result | Should -Not -Contain "service2/app.ts"
    }

    It "Returns nothing when comparing a branch to itself" {
        $result = Get-ChangedFiles -BaseRef "main" -HeadRef "main"
        $result | Should -BeNullOrEmpty
    }
}

Describe "Find-RequiredChecks" {
    BeforeAll {
        $script:testRepo = New-TestGitRepo
        Push-Location $script:testRepo.ClonePath
    }

    AfterAll {
        Pop-Location
        Remove-Item -Recurse -Force $script:testRepo.Root
    }

    It "Returns matching checks when paths have changes" {
        $policy = @(
            [PSCustomObject]@{ checks = @("build-service1"); paths = @("service1/") }
        )

        $result = Find-RequiredChecks -Policy $policy -BaseRef "main" -HeadRef "feature"
        $result | Should -Be @("build-service1")
    }

    It "Returns empty when no paths have changes" {
        $policy = @(
            [PSCustomObject]@{ checks = @("build-service2"); paths = @("service2/") }
        )

        $result = Find-RequiredChecks -Policy $policy -BaseRef "main" -HeadRef "feature"
        $result | Should -BeNullOrEmpty
    }

    It "Returns deduplicated and sorted checks from multiple matching policies" {
        $policy = @(
            [PSCustomObject]@{ checks = @("check-b", "check-a"); paths = @("service1/") }
            [PSCustomObject]@{ checks = @("check-a", "check-c"); paths = @("shared/") }
        )

        $result = Find-RequiredChecks -Policy $policy -BaseRef "main" -HeadRef "feature"
        $result | Should -Be @("check-a", "check-b", "check-c")
    }

    It "Skips policy items with no valid paths" {
        $policy = @(
            [PSCustomObject]@{ checks = @("check1"); paths = @($null, "") }
        )

        $result = Find-RequiredChecks -Policy $policy -BaseRef "main" -HeadRef "feature"
        $result | Should -BeNullOrEmpty
    }

    It "Throws on paths starting with !" {
        $policy = @(
            [PSCustomObject]@{ checks = @("check1"); paths = @("!excluded/") }
        )

        { Find-RequiredChecks -Policy $policy -BaseRef "main" -HeadRef "feature" } | Should -Throw "*not supported*"
    }

    It "Only returns checks for policy items with matching changes" {
        $policy = @(
            [PSCustomObject]@{ checks = @("build-service1"); paths = @("service1/") }
            [PSCustomObject]@{ checks = @("build-service2"); paths = @("service2/") }
        )

        $result = Find-RequiredChecks -Policy $policy -BaseRef "main" -HeadRef "feature"
        $result | Should -Be @("build-service1")
    }

    It "Supports pathspec exclusions with :(exclude) syntax" {
        $policy = @(
            [PSCustomObject]@{ checks = @("check-all"); paths = @("service1/", ":(exclude)service1/new-file.txt") }
        )

        $result = Find-RequiredChecks -Policy $policy -BaseRef "main" -HeadRef "feature"
        $result | Should -BeNullOrEmpty
    }
}

Describe "Wait-RequiredChecks" {
    BeforeEach {
        Mock Start-Sleep {} -ModuleName RequiredChecksPolicy
    }

    It "Succeeds immediately when all checks are completed successfully" {
        Mock Get-CheckRuns {
            return [PSCustomObject]@{
                check_runs = @(
                    [PSCustomObject]@{ id = 1; name = "build"; status = "completed"; conclusion = "success"; html_url = "https://example.com/1" }
                    [PSCustomObject]@{ id = 2; name = "test"; status = "completed"; conclusion = "success"; html_url = "https://example.com/2" }
                )
                total_count = 2
            }
        } -ModuleName RequiredChecksPolicy

        {
            Wait-RequiredChecks -RequiredChecks @("build", "test") -Repository "owner/repo" -HeadRef "feature" -TimeoutMinutesCreatedChecks 15 -TimeoutMinutesQueuedChecks 30
        } | Should -Not -Throw

        Should -Invoke Start-Sleep -ModuleName RequiredChecksPolicy -Times 0
    }

    It "Throws when a required check fails" {
        Mock Get-CheckRuns {
            return [PSCustomObject]@{
                check_runs = @(
                    [PSCustomObject]@{ id = 1; name = "build"; status = "completed"; conclusion = "failure"; html_url = "https://example.com/1" }
                )
                total_count = 1
            }
        } -ModuleName RequiredChecksPolicy

        {
            Wait-RequiredChecks -RequiredChecks @("build") -Repository "owner/repo" -HeadRef "feature" -TimeoutMinutesCreatedChecks 15 -TimeoutMinutesQueuedChecks 30
        } | Should -Throw "*failed with conclusion: failure*"
    }

    It "Waits and retries when checks are in progress then succeed" {
        $script:callCount = 0
        Mock Get-CheckRuns {
            $script:callCount++
            if ($script:callCount -eq 1) {
                return [PSCustomObject]@{
                    check_runs = @(
                        [PSCustomObject]@{ id = 1; name = "build"; status = "in_progress"; conclusion = $null; html_url = "https://example.com/1" }
                    )
                    total_count = 1
                }
            }
            return [PSCustomObject]@{
                check_runs = @(
                    [PSCustomObject]@{ id = 1; name = "build"; status = "completed"; conclusion = "success"; html_url = "https://example.com/1" }
                )
                total_count = 1
            }
        } -ModuleName RequiredChecksPolicy

        {
            Wait-RequiredChecks -RequiredChecks @("build") -Repository "owner/repo" -HeadRef "feature" -TimeoutMinutesCreatedChecks 15 -TimeoutMinutesQueuedChecks 30
        } | Should -Not -Throw

        Should -Invoke Start-Sleep -ModuleName RequiredChecksPolicy -Times 1
        Should -Invoke Get-CheckRuns -ModuleName RequiredChecksPolicy -Times 2
    }

    It "Throws when a check is not created within the timeout" {
        Mock Get-CheckRuns {
            return [PSCustomObject]@{
                check_runs = @()
                total_count = 0
            }
        } -ModuleName RequiredChecksPolicy

        # First call sets $startedAt, subsequent calls simulate time having passed
        $script:getDateCallCount = 0
        $baseTime = [DateTime]::UtcNow
        Mock Get-Date {
            $script:getDateCallCount++
            if ($script:getDateCallCount -eq 1) { return $baseTime }
            return $baseTime.AddMinutes(20)
        } -ModuleName RequiredChecksPolicy -ParameterFilter { $AsUTC }

        {
            Wait-RequiredChecks -RequiredChecks @("missing-check") -Repository "owner/repo" -HeadRef "feature" -TimeoutMinutesCreatedChecks 15 -TimeoutMinutesQueuedChecks 30
        } | Should -Throw "*wasn't created after*"
    }

    It "Throws when a check stays queued past the timeout" {
        Mock Get-CheckRuns {
            return [PSCustomObject]@{
                check_runs = @(
                    [PSCustomObject]@{ id = 1; name = "build"; status = "queued"; conclusion = $null; html_url = "https://example.com/1" }
                )
                total_count = 1
            }
        } -ModuleName RequiredChecksPolicy

        $script:getDateCallCount = 0
        $baseTime = [DateTime]::UtcNow
        Mock Get-Date {
            $script:getDateCallCount++
            if ($script:getDateCallCount -eq 1) { return $baseTime }
            return $baseTime.AddMinutes(35)
        } -ModuleName RequiredChecksPolicy -ParameterFilter { $AsUTC }

        {
            Wait-RequiredChecks -RequiredChecks @("build") -Repository "owner/repo" -HeadRef "feature" -TimeoutMinutesCreatedChecks 15 -TimeoutMinutesQueuedChecks 30
        } | Should -Throw "*is still queued after*"
    }

    It "Handles multiple checks completing across different polls" {
        $script:pollCount = 0
        Mock Get-CheckRuns {
            $script:pollCount++
            if ($script:pollCount -eq 1) {
                return [PSCustomObject]@{
                    check_runs = @(
                        [PSCustomObject]@{ id = 1; name = "build"; status = "completed"; conclusion = "success"; html_url = "https://example.com/1" }
                        [PSCustomObject]@{ id = 2; name = "test"; status = "in_progress"; conclusion = $null; html_url = "https://example.com/2" }
                    )
                    total_count = 2
                }
            }
            return [PSCustomObject]@{
                check_runs = @(
                    [PSCustomObject]@{ id = 1; name = "build"; status = "completed"; conclusion = "success"; html_url = "https://example.com/1" }
                    [PSCustomObject]@{ id = 2; name = "test"; status = "completed"; conclusion = "success"; html_url = "https://example.com/2" }
                )
                total_count = 2
            }
        } -ModuleName RequiredChecksPolicy

        {
            Wait-RequiredChecks -RequiredChecks @("build", "test") -Repository "owner/repo" -HeadRef "feature" -TimeoutMinutesCreatedChecks 15 -TimeoutMinutesQueuedChecks 30
        } | Should -Not -Throw

        Should -Invoke Get-CheckRuns -ModuleName RequiredChecksPolicy -Times 2
    }
}

Describe "Get-CheckRuns" {
    It "Flattens paginated responses into a single result" {
        Mock gh {
            return '[{"check_runs":[{"id":1,"name":"build"}]},{"check_runs":[{"id":2,"name":"test"}]}]'
        } -ModuleName RequiredChecksPolicy

        $result = Get-CheckRuns -Url "repos/owner/repo/commits/abc/check-runs"
        $result.total_count | Should -Be 2
        $result.check_runs[0].name | Should -Be "build"
        $result.check_runs[1].name | Should -Be "test"
    }

    It "Handles a single page response" {
        Mock gh {
            return '[{"check_runs":[{"id":1,"name":"build"}]}]'
        } -ModuleName RequiredChecksPolicy

        $result = Get-CheckRuns -Url "repos/owner/repo/commits/abc/check-runs"
        $result.total_count | Should -Be 1
        $result.check_runs[0].name | Should -Be "build"
    }

    It "Handles empty check_runs" {
        Mock gh {
            return '[{"check_runs":[]}]'
        } -ModuleName RequiredChecksPolicy

        $result = Get-CheckRuns -Url "repos/owner/repo/commits/abc/check-runs"
        $result.total_count | Should -Be 0
    }
}
