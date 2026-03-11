BeforeAll {
    # Ensure node dependencies are installed for glob matching
    Push-Location $PSScriptRoot
    npm install --no-audit --no-fund 2>&1 | Out-Null
    Pop-Location

    Import-Module "$PSScriptRoot/RequiredChecksPolicy.psm1" -Force

    # Helper to create a test git repo with a bare origin and a clone.
    # Main branch has: service1/app.ts, service2/app.ts, shared/util.ts, policy.json
    # Feature branch adds: service1/new-file.txt, modifies shared/util.ts
    function New-TestGitRepo {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "pester-git-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $tempRoot | Out-Null

        $originRepo = Join-Path $tempRoot "origin"
        $cloneRepo = Join-Path $tempRoot "clone"

        # Create origin repo with all branches and content
        git init $originRepo 2>&1 | Out-Null
        Push-Location $originRepo

        git config user.email "test@test.com"
        git config user.name "Test"

        # Create main branch with files
        # Rename default branch to main (handles systems where default is master)
        git checkout -b main 2>&1 | Out-Null

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

        # Create feature branch with changes in service1 and shared
        git checkout -b feature 2>&1 | Out-Null
        Set-Content -Path "service1/new-file.txt" -Value "new file"
        Set-Content -Path "shared/util.ts" -Value "shared content modified"
        git add -A 2>&1 | Out-Null
        git commit -m "Feature changes" 2>&1 | Out-Null

        Pop-Location

        # Clone the origin repo so refs/remotes/origin/* are properly created
        git clone $originRepo $cloneRepo 2>&1 | Out-Null

        return @{
            Root      = $tempRoot
            ClonePath = $cloneRepo
        }
    }

    # Helper to create a test git repo with workflow files for auto-discovery tests.
    function New-TestGitRepoWithWorkflows {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "pester-git-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $tempRoot | Out-Null

        $originRepo = Join-Path $tempRoot "origin"
        $cloneRepo = Join-Path $tempRoot "clone"

        git init $originRepo 2>&1 | Out-Null
        Push-Location $originRepo

        git config user.email "test@test.com"
        git config user.name "Test"
        git checkout -b main 2>&1 | Out-Null

        # Create service directories
        New-Item -ItemType Directory -Path "service1" -Force | Out-Null
        New-Item -ItemType Directory -Path "service2" -Force | Out-Null
        Set-Content -Path "service1/app.ts" -Value "service1 content"
        Set-Content -Path "service2/app.ts" -Value "service2 content"

        # Create workflow files
        New-Item -ItemType Directory -Path ".github/workflows" -Force | Out-Null

        # Workflow 1: service1 build with path filter
        Set-Content -Path ".github/workflows/build-service1.yml" -Value @"
name: Build Service 1
on:
  pull_request:
    paths:
      - service1/**
jobs:
  build-service1:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
"@

        # Workflow 2: service2 build with path filter
        Set-Content -Path ".github/workflows/build-service2.yml" -Value @"
name: Build Service 2
on:
  pull_request:
    paths:
      - service2/**
jobs:
  build-service2:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
"@

        # Workflow 3: entirely opted out at workflow level
        Set-Content -Path ".github/workflows/opted-out-workflow.yml" -Value @"
# wl-not-required
name: Opted Out Workflow
on:
  pull_request:
    paths:
      - service1/**
jobs:
  opted-out-workflow-job:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
"@

        # Workflow 4: trigger-level opt-out
        Set-Content -Path ".github/workflows/opted-out-trigger.yml" -Value @"
name: Opted Out Trigger
on:
  # wl-not-required
  pull_request:
    paths:
      - service1/**
jobs:
  opted-out-trigger-job:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
"@

        # Workflow 5: job-level opt-out
        Set-Content -Path ".github/workflows/job-opt-out.yml" -Value @"
name: Job Opt Out
on:
  pull_request:
    paths:
      - service1/**
jobs:
  # wl-not-required
  optional-job:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
  required-job:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
"@

        # Workflow 6: workflow_call only (reusable workflow)
        Set-Content -Path ".github/workflows/reusable.yml" -Value @"
name: Reusable Workflow
on:
  workflow_call:
    inputs:
      param1:
        type: string
jobs:
  reusable-job:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
"@

        # Workflow 7: no path filters (triggers on everything)
        Set-Content -Path ".github/workflows/no-filter.yml" -Value @"
name: No Filter
on:
  pull_request:
jobs:
  no-filter-job:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
"@

        # Workflow 8: wrong branch filter
        Set-Content -Path ".github/workflows/wrong-branch.yml" -Value @"
name: Wrong Branch
on:
  pull_request:
    branches:
      - develop
    paths:
      - service1/**
jobs:
  wrong-branch-job:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
"@

        git add -A 2>&1 | Out-Null
        git commit -m "Initial commit with workflows" 2>&1 | Out-Null

        # Create feature branch with changes
        git checkout -b feature 2>&1 | Out-Null
        Set-Content -Path "service1/new-file.txt" -Value "new file"
        git add -A 2>&1 | Out-Null
        git commit -m "Feature changes" 2>&1 | Out-Null

        Pop-Location

        git clone $originRepo $cloneRepo 2>&1 | Out-Null

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

Describe "Test-GlobMatch" {
    It "Matches exact string" {
        Test-GlobMatch -Value "main" -Pattern "main" | Should -BeTrue
    }

    It "Does not match different string" {
        Test-GlobMatch -Value "develop" -Pattern "main" | Should -BeFalse
    }

    It "Matches * wildcard within a single segment" {
        Test-GlobMatch -Value "release/1.0" -Pattern "release/*" | Should -BeTrue
    }

    It "Does not match * across directory separator" {
        Test-GlobMatch -Value "release/v1/hotfix" -Pattern "release/*" | Should -BeFalse
    }

    It "Matches ** across directories" {
        Test-GlobMatch -Value "src/components/Button/index.ts" -Pattern "src/**" | Should -BeTrue
    }

    It "Matches ** in the middle of a pattern" {
        Test-GlobMatch -Value "src/components/Button/index.ts" -Pattern "src/**/index.ts" | Should -BeTrue
    }

    It "Matches file extension patterns in same directory" {
        Test-GlobMatch -Value "app.ts" -Pattern "*.ts" | Should -BeTrue
    }

    It "Does not match file extension across directories without **" {
        Test-GlobMatch -Value "src/app.ts" -Pattern "*.ts" | Should -BeFalse
    }

    It "Does not match wrong extension" {
        Test-GlobMatch -Value "src/app.js" -Pattern "*.ts" | Should -BeFalse
    }

    It "Matches ? single character wildcard" {
        Test-GlobMatch -Value "file1.ts" -Pattern "file?.ts" | Should -BeTrue
    }

    It "Matches branch patterns like feature/**" {
        Test-GlobMatch -Value "feature/my-feature" -Pattern "feature/**" | Should -BeTrue
    }

    It "Escapes regex special characters" {
        Test-GlobMatch -Value "file.test.ts" -Pattern "file.test.ts" | Should -BeTrue
    }

    It "Matches paths with ** and file extension" {
        Test-GlobMatch -Value "src/deep/nested/file.ts" -Pattern "src/**/*.ts" | Should -BeTrue
    }
}

Describe "Find-WlNotRequired" {
    It "Detects workflow-level opt-out on first non-empty line" {
        $yaml = @"
# wl-not-required
name: My Workflow
on:
  push:
jobs:
  build:
    runs-on: ubuntu-latest
"@
        $result = Find-WlNotRequired -RawContent $yaml
        $result.IsWorkflowOptOut | Should -BeTrue
    }

    It "Detects workflow-level opt-out with leading blank lines" {
        $yaml = @"

# wl-not-required
name: My Workflow
"@
        $result = Find-WlNotRequired -RawContent $yaml
        $result.IsWorkflowOptOut | Should -BeTrue
    }

    It "Does not detect workflow-level opt-out when comment is not first" {
        $yaml = @"
name: My Workflow
# wl-not-required
on:
  push:
"@
        $result = Find-WlNotRequired -RawContent $yaml
        $result.IsWorkflowOptOut | Should -BeFalse
    }

    It "Detects trigger-level opt-out for pull_request" {
        $yaml = @"
name: My Workflow
on:
  push:
    branches: [main]
  # wl-not-required
  pull_request:
    paths:
      - src/**
jobs:
  build:
    runs-on: ubuntu-latest
"@
        $result = Find-WlNotRequired -RawContent $yaml
        $result.IsWorkflowOptOut | Should -BeFalse
        $result.OptOutTriggers | Should -Contain "pull_request"
        $result.OptOutTriggers | Should -Not -Contain "push"
    }

    It "Detects trigger-level opt-out for push" {
        $yaml = @"
name: My Workflow
on:
  # wl-not-required
  push:
    branches: [main]
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
"@
        $result = Find-WlNotRequired -RawContent $yaml
        $result.OptOutTriggers | Should -Contain "push"
        $result.OptOutTriggers | Should -Not -Contain "pull_request"
    }

    It "Detects job-level opt-out" {
        $yaml = @"
name: My Workflow
on:
  pull_request:
jobs:
  # wl-not-required
  optional-job:
    runs-on: ubuntu-latest
  required-job:
    runs-on: ubuntu-latest
"@
        $result = Find-WlNotRequired -RawContent $yaml
        $result.IsWorkflowOptOut | Should -BeFalse
        $result.OptOutJobs | Should -Contain "optional-job"
        $result.OptOutJobs | Should -Not -Contain "required-job"
    }

    It "Handles multiple opt-outs in same file" {
        $yaml = @"
name: My Workflow
on:
  # wl-not-required
  push:
    branches: [main]
  pull_request:
jobs:
  # wl-not-required
  optional-job:
    runs-on: ubuntu-latest
  required-job:
    runs-on: ubuntu-latest
"@
        $result = Find-WlNotRequired -RawContent $yaml
        $result.OptOutTriggers | Should -Contain "push"
        $result.OptOutJobs | Should -Contain "optional-job"
    }

    It "Ignores wl-not-required in unrelated comments" {
        $yaml = @"
name: My Workflow
on:
  pull_request:
    # This is not a wl-not-required comment, just a regular comment
    paths:
      - src/**
jobs:
  build:
    runs-on: ubuntu-latest
"@
        $result = Find-WlNotRequired -RawContent $yaml
        $result.IsWorkflowOptOut | Should -BeFalse
        $result.OptOutTriggers.Count | Should -Be 0
        $result.OptOutJobs.Count | Should -Be 0
    }
}

Describe "Test-WorkflowTriggers" {
    BeforeAll {
        $defaultOptOuts = @{
            IsWorkflowOptOut = $false
            OptOutTriggers   = @()
            OptOutJobs       = @()
        }
    }

    It "Returns true for pull_request with no filters" {
        $on = @{ "pull_request" = @{} }
        $result = Test-WorkflowTriggers -WorkflowOn $on -BaseRef "main" -HeadRef "feature" -ChangedFiles @("src/app.ts") -OptOuts $defaultOptOuts
        $result | Should -BeTrue
    }

    It "Returns false when branch filter does not match base ref" {
        $on = @{ "pull_request" = @{ "branches" = @("develop") } }
        $result = Test-WorkflowTriggers -WorkflowOn $on -BaseRef "main" -HeadRef "feature" -ChangedFiles @("src/app.ts") -OptOuts $defaultOptOuts
        $result | Should -BeFalse
    }

    It "Returns true when branch filter matches base ref" {
        $on = @{ "pull_request" = @{ "branches" = @("main", "develop") } }
        $result = Test-WorkflowTriggers -WorkflowOn $on -BaseRef "main" -HeadRef "feature" -ChangedFiles @("src/app.ts") -OptOuts $defaultOptOuts
        $result | Should -BeTrue
    }

    It "Returns true when branch filter matches with glob" {
        $on = @{ "pull_request" = @{ "branches" = @("release/*") } }
        $result = Test-WorkflowTriggers -WorkflowOn $on -BaseRef "release/1.0" -HeadRef "feature" -ChangedFiles @("src/app.ts") -OptOuts $defaultOptOuts
        $result | Should -BeTrue
    }

    It "Returns false when paths filter does not match any changed file" {
        $on = @{ "pull_request" = @{ "paths" = @("docs/**") } }
        $result = Test-WorkflowTriggers -WorkflowOn $on -BaseRef "main" -HeadRef "feature" -ChangedFiles @("src/app.ts") -OptOuts $defaultOptOuts
        $result | Should -BeFalse
    }

    It "Returns true when paths filter matches a changed file" {
        $on = @{ "pull_request" = @{ "paths" = @("src/**") } }
        $result = Test-WorkflowTriggers -WorkflowOn $on -BaseRef "main" -HeadRef "feature" -ChangedFiles @("src/app.ts") -OptOuts $defaultOptOuts
        $result | Should -BeTrue
    }

    It "Handles branches-ignore correctly" {
        $on = @{ "pull_request" = @{ "branches-ignore" = @("main") } }
        $result = Test-WorkflowTriggers -WorkflowOn $on -BaseRef "main" -HeadRef "feature" -ChangedFiles @("src/app.ts") -OptOuts $defaultOptOuts
        $result | Should -BeFalse
    }

    It "Returns true when branch is not in branches-ignore" {
        $on = @{ "pull_request" = @{ "branches-ignore" = @("develop") } }
        $result = Test-WorkflowTriggers -WorkflowOn $on -BaseRef "main" -HeadRef "feature" -ChangedFiles @("src/app.ts") -OptOuts $defaultOptOuts
        $result | Should -BeTrue
    }

    It "Handles paths-ignore correctly when all files are ignored" {
        $on = @{ "pull_request" = @{ "paths-ignore" = @("docs/**") } }
        $result = Test-WorkflowTriggers -WorkflowOn $on -BaseRef "main" -HeadRef "feature" -ChangedFiles @("docs/readme.md") -OptOuts $defaultOptOuts
        $result | Should -BeFalse
    }

    It "Returns true when not all files are in paths-ignore" {
        $on = @{ "pull_request" = @{ "paths-ignore" = @("docs/**") } }
        $result = Test-WorkflowTriggers -WorkflowOn $on -BaseRef "main" -HeadRef "feature" -ChangedFiles @("docs/readme.md", "src/app.ts") -OptOuts $defaultOptOuts
        $result | Should -BeTrue
    }

    It "Skips opted-out triggers" {
        $on = @{ "pull_request" = @{} }
        $optOuts = @{
            IsWorkflowOptOut = $false
            OptOutTriggers   = @("pull_request")
            OptOutJobs       = @()
        }
        $result = Test-WorkflowTriggers -WorkflowOn $on -BaseRef "main" -HeadRef "feature" -ChangedFiles @("src/app.ts") -OptOuts $optOuts
        $result | Should -BeFalse
    }

    It "Returns false for workflow_call-only trigger" {
        $on = @{ "workflow_call" = @{} }
        $result = Test-WorkflowTriggers -WorkflowOn $on -BaseRef "main" -HeadRef "feature" -ChangedFiles @("src/app.ts") -OptOuts $defaultOptOuts
        $result | Should -BeFalse
    }

    It "Handles push trigger matching head ref" {
        $on = @{ "push" = @{ "branches" = @("feature") } }
        $result = Test-WorkflowTriggers -WorkflowOn $on -BaseRef "main" -HeadRef "feature" -ChangedFiles @("src/app.ts") -OptOuts $defaultOptOuts
        $result | Should -BeTrue
    }

    It "Returns false for push when head ref does not match" {
        $on = @{ "push" = @{ "branches" = @("main") } }
        $result = Test-WorkflowTriggers -WorkflowOn $on -BaseRef "main" -HeadRef "feature" -ChangedFiles @("src/app.ts") -OptOuts $defaultOptOuts
        $result | Should -BeFalse
    }

    It "Handles shorthand string syntax" {
        $result = Test-WorkflowTriggers -WorkflowOn "push" -BaseRef "main" -HeadRef "feature" -ChangedFiles @("src/app.ts") -OptOuts $defaultOptOuts
        $result | Should -BeTrue
    }

    It "Handles shorthand array syntax" {
        $on = @("push", "pull_request")
        $result = Test-WorkflowTriggers -WorkflowOn $on -BaseRef "main" -HeadRef "feature" -ChangedFiles @("src/app.ts") -OptOuts $defaultOptOuts
        $result | Should -BeTrue
    }
}

Describe "Get-WorkflowFilesFromGit" {
    BeforeAll {
        $script:testRepo = New-TestGitRepo
        Push-Location $script:testRepo.ClonePath
    }

    AfterAll {
        Pop-Location
        Remove-Item -Recurse -Force $script:testRepo.Root
    }

    It "Returns empty when no workflows directory exists" {
        $result = Get-WorkflowFilesFromGit -BaseRef "main"
        $result | Should -BeNullOrEmpty
    }
}

Describe "Get-WorkflowFilesFromGit with workflows" {
    BeforeAll {
        $script:testRepo = New-TestGitRepoWithWorkflows
        Push-Location $script:testRepo.ClonePath
    }

    AfterAll {
        Pop-Location
        Remove-Item -Recurse -Force $script:testRepo.Root
    }

    It "Reads workflow files from base ref" {
        $result = Get-WorkflowFilesFromGit -BaseRef "main"
        $result.Count | Should -BeGreaterOrEqual 1
        $result[0].Path | Should -Match "\.github/workflows/.*\.yml$"
        $result[0].Content | Should -Not -BeNullOrEmpty
    }
}

Describe "Find-AutoDiscoveredChecks" {
    BeforeAll {
        $script:testRepo = New-TestGitRepoWithWorkflows
        Push-Location $script:testRepo.ClonePath
    }

    AfterAll {
        Pop-Location
        Remove-Item -Recurse -Force $script:testRepo.Root
    }

    It "Discovers job keys from workflows matching changed paths" {
        $result = Find-AutoDiscoveredChecks -BaseRef "main" -HeadRef "feature" -ChangedFiles @("service1/new-file.txt")
        $result | Should -Contain "build-service1"
    }

    It "Does not discover jobs from workflows with non-matching paths" {
        $result = Find-AutoDiscoveredChecks -BaseRef "main" -HeadRef "feature" -ChangedFiles @("unrelated/file.txt")
        $result | Should -Not -Contain "build-service1"
        $result | Should -Not -Contain "build-service2"
    }

    It "Excludes entire workflow with wl-not-required at workflow level" {
        $result = Find-AutoDiscoveredChecks -BaseRef "main" -HeadRef "feature" -ChangedFiles @("service1/new-file.txt")
        $result | Should -Not -Contain "opted-out-workflow-job"
    }

    It "Excludes trigger with wl-not-required at trigger level" {
        $result = Find-AutoDiscoveredChecks -BaseRef "main" -HeadRef "feature" -ChangedFiles @("service1/new-file.txt")
        $result | Should -Not -Contain "opted-out-trigger-job"
    }

    It "Excludes specific job with wl-not-required at job level" {
        $result = Find-AutoDiscoveredChecks -BaseRef "main" -HeadRef "feature" -ChangedFiles @("service1/new-file.txt")
        $result | Should -Not -Contain "optional-job"
        $result | Should -Contain "required-job"
    }

    It "Excludes workflow_call-only workflows" {
        $result = Find-AutoDiscoveredChecks -BaseRef "main" -HeadRef "feature" -ChangedFiles @("service1/new-file.txt")
        $result | Should -Not -Contain "reusable-job"
    }

    It "Includes jobs from workflows with no path filters" {
        $result = Find-AutoDiscoveredChecks -BaseRef "main" -HeadRef "feature" -ChangedFiles @("anything.txt")
        $result | Should -Contain "no-filter-job"
    }

    It "Excludes workflows with non-matching branch filter" {
        $result = Find-AutoDiscoveredChecks -BaseRef "main" -HeadRef "feature" -ChangedFiles @("service1/new-file.txt")
        $result | Should -Not -Contain "wrong-branch-job"
    }
}
