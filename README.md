# Workleap's reusable GitHub Actions repository

This repository contains centralized workflows that are re-used across the organization's repositories.

# Renovate daily workflow

This repository also hosts the daily [Renovate](https://docs.renovatebot.com/) workflow for the whole [workleap GitHub organization](https://github.com/workleap/).

Repositories **must opt-in** to Renovate automated dependency updates by providing their own configuration file. Repositories without a Renovate configuration file will be ignored.

# Reusable workflows

## Semgrep

test this thing you know

This workflow runs the semgrep security scanner against the given repo.

## Jira

This workflow creates links between jira cards and pull requests based on branch names.

## LinearB and Cortex

This workflow will create a deployment entry in LinearB and Cortex for the provided environment.
Example usage in a workflow:
```yaml
jobs:
  deploy-<your_environment>:
    uses: workleap/wl-reusable-workflows/.github/workflows/linearb-deployment.yml@main
    with:
      environment: "<your_environment>" # development, staging or release
      cortexEntityIdOrTag: "service-dummy" # (optional) entity tag or id like "service-dummy" or "en307ab223af38dc0e"
    secrets: inherit
```

## Send Slack notification

```yml
jobs:
  sample:
    steps:
      - uses: workleap/wl-reusable-workflows/send-slack-notification@main
        with:
          webhook_url: ${{secrets.SLACK_WEBHOOK_URL_IDP_DEV_ALERTS}}
          # Use either text or messageTemplate
          text: Sample message
          messageTemplate: "FailedJob" # Support "", "FailedJob"
```

## Perform and deploy Checkly checks
This workflow requires two secrets to be set:
- `CHECKLY_API_KEY`: The API key to access the Checkly API
- `CHECKLY_ACCOUNT_ID`: The ID of the Checkly account

```yml
jobs:
  deploy-checkly:
    uses: workleap/wl-reusable-workflows/.github/workflows/deploy-checkly.yml@main
    permissions:
      id-token: write
      contents: read
    with:
      account-id: "your-checkly-account-id"
      api-key: "your-checkly-api-key"
      private-location-name: "your-private-location-name"
```

## Azure Artifacts Authenticate
Before using this action, make sure the managed identity associated with your repository has access to the ADO feed.
- Your managed identity will need to be a user of your Organization with the `Stakeholder` access level
- Then this user will need to have either contributor or reader access to your ADO feed

This action authenticates to Azure Artifacts feed using Azure CLI and configures the environment for package access. It sets up the necessary authentication tokens and credential providers for accessing Azure DevOps feeds.

This action requires the following repository variables to be configured:
- `AZURE_CLIENT_ID`: The Azure service principal client ID
- `AZURE_TENANT_ID`: The Azure tenant ID  
- `AZURE_SUBSCRIPTION_ID`: The Azure subscription ID

```yml
permissions:
  contents: read
  id-token: write

jobs:
  build:
    runs-on: idp
    environment: ci
    steps:
      - uses: actions/checkout@v4
      
      - uses: workleap/wl-reusable-workflows/az-artifact-authenticate@main
        with:
          feed-url: "https://pkgs.dev.azure.com/workleap/_packaging/your-feed/nuget/v3/index.json"
          variables: ${{ toJSON(vars) }}
```

## Terraform checks

This workflow runs TF-Lint to find issues in the code, Terraform-Docs to create a README and Terraform FMT to format the code.

## Git tag

This workflow creates a new Git tag.

## Create GitHub releases from commits available since the last stable release

This reusable workflow is useful because we often forget to create new GitHub releases for libraries after merging pull requests. It is intended to be used with a schedule. It requires a secret named `token` that contains a personal access token with permissions to create GitHub releases on the targeted repo (`contents: write`).

If any commit message contains the following keywords, it will create a new release with the corresponding version bump:
- `#major`: bump the major version,
- `#minor`: bump the minor version,
- `#patch`: bump the patch version (default behavior).

Additional features and behaviors:

- Supports new repos without tags (will create `0.0.1`).
- Gracefully exits if there's no commits since the last stable tag.
- Automatically generates the release notes.
- Only supports creating tags from the main branch of the targeted repo.

Here's how to use it:

```yaml
name: Create stable release

on:
  schedule:
    - cron: "0 3 * * 0" # At 03:00 on Sunday (that's an example)

jobs:
  create-release:
    permissions:
      contents: write
    uses: workleap/wl-reusable-workflows/.github/workflows/create-stable-release.yml@main
    secrets:
      token: ${{ secrets.SOME_PAT }}
```

## Update downstream repositories from template

This workflow automatically synchronizes template files (`.github` folder, `CONTRIBUTING.md`, `SECURITY.md`, `renovate.json`) from a template repository to all downstream repositories with a specified prefix. It's useful for maintaining consistent configurations and documentation across multiple repositories.

Example usage in a workflow:
```yaml
name: Sync from Template Repo

on:
  workflow_dispatch:
  push:
    branches: [ main ]
    paths:
      - '.github/**'
      - 'CONTRIBUTING.md'
      - 'SECURITY.md'
      - 'renovate.json'

jobs:
   update-downstream-repositories:
      uses: workleap/wl-reusable-workflows/.github/workflows/github-template-update-downstream.yml@main
      with:
        templateRepoName: 'terraform-template'
        repoPrefix: 'terraform-'
      secrets: inherit
```

## GitHub Status Check Policy

When working with mono-repositories, you may need different pipelines to run based on which files have changed. However, GitHub only supports static required checks in repository settings. This reusable workflow helps you implement dynamic status checks as a workaround.

1. Define your check policy

  Create a JSON file describing which checks are required for specific paths. Example:

  ````json
  [
    {
     "checks": ["build_service1"],
     "paths": ["service1/**"]
    },
    {
     "checks": ["build_service2"],
     "paths": ["service2/**"]
    }
  ]
  ````

  - `checks`: An array of status check names that must succeed if any files matching the specified `paths` are changed. To determine the correct check names, you can open a draft pull request and reference the exact names shown for checks in the pull request interface.
  - `paths`: List of [pathspecs](https://git-scm.com/docs/gitglossary#Documentation/gitglossary.txt-aiddefpathspecapathspec) to match against files changed in the pull request.

2. Add the workflow

  ````yaml
  name: Evaluate policy

  on:
    push:
    pull_request:

  jobs:
    evaluate_policy:
        uses: workleap/wl-reusable-workflows/.github/workflows/required_checks_policy.yml@main
        with:
          policyPath: ./policy.json # Relative to the root of the git repository
        secrets: inherit
        permissions:
          contents: read
          checks: read
  ````

3. Set required checks in repository settings

> [!NOTE]
> The policy file is fetched from the target branch for `pull_request` events and from the default branch for `push` events. This means you cannot update the policy without a code review.

## Trigger Maintenance Page

This workflow enables or disables a maintenance or outage page for a specified Cloudflare zone and environment. It is useful for quickly toggling maintenance or outage states across different environments and endpoints managed by Cloudflare.

**Inputs:**
- `pageType`: Type of page to enable or disable (`maintenance` or `outage`).
- `action`: Whether to `enable` or `disable` the page.
- `zone`: The endpoint (zone) to target (e.g., `login`, or another subdomain).
- `environment`: The environment to target (`dev`, `stg`, or `prod`).
- `cloudflareApiToken`: Cloudflare API token with permissions to manage rulesets.

**Example usage:**
```yaml
jobs:
  trigger-maintenance:
    uses: workleap/wl-reusable-workflows/.github/workflows/trigger-maintenance-page.yml@main
    with:
      pageType: "maintenance"
      action: "enable"
      zone: "login"
      environment: "prod"
      cloudflareApiToken: ${{ secrets.CLOUDFLARE_API_TOKEN }}
```

This workflow will call the Cloudflare API to enable or disable the specified rule for the given zone and environment.

## License

Copyright © 2025, Workleap. This code is licensed under the Apache License, Version 2.0. You may obtain a copy of this license at https://github.com/workleap/gsoft-license/blob/master/LICENSE.
