# Workleap's reusable GitHub Actions repository

This repository contains centralized workflows that are re-used across the organization's repositories.

# Renovate daily workflow

This repository also hosts the daily [Renovate](https://docs.renovatebot.com/) workflow for the whole [workleap GitHub organization](https://github.com/workleap/).

Repositories **must opt-in** to Renovate automated dependency updates by providing their own configuration file. Repositories without a Renovate configuration file will be ignored.

# Reusable workflows

## Semgrep

This workflow runs the semgrep security scanner against the given repo.

## Jira

This workflow creates links between jira cards and pull requests based on branch names.

## LinearB

This workflow will create a deployment entry in LinearB for the provided environment.
Example usage in a workflow:
```yaml
jobs:
  deploy-<your_environment>:
    uses: workleap/wl-reusable-workflows/.github/workflows/linearb-deployment.yml@main
    with:
      environment: "<your_environment>" # development, staging or release
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
  main:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: workleap/wl-reusable-workflows/checkly@main
        with:
          account-id: "your-checkly-account-id"
          api-key: "your-checkly-api-key"
          private-location-name: "your-private-location-name"
```

## Terraform checks

This workflow runs TF-Lint to find issues in the code, Terraform-Docs to create a README and Terraform FMT to format the code.

## Git tag

This workflow creates a new Git tag.

## Create GitHub releases from commits available since the last stable release

This reusable workflow is useful because we often forget to create new GitHub releases for libraries after merging pull requests. It is intended to be used with a schedule. It requires a secret named `token` that contains a personal access token with permissions to create GitHub releases on the targeted repo (`contents: write`).

Supports semantic commits containing matching the following regexes:

- `\+semver:\s?major`: if any commit matches this regex, it will bump the major version,
- `\+semver:\s?minor`: if any commit matches this regex, it will bump the minor version,
- `\+semver:\s?patch`: if any commit matches this regex, it will bump the patch version (default behavior).

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
    uses: workleap/wl-reusable-workflows/.github/workflows/create-stable-release.yml
    secrets:
      token: ${{ secrets.SOME_PAT }}
```

## License

Copyright © 2025, Workleap. This code is licensed under the Apache License, Version 2.0. You may obtain a copy of this license at https://github.com/workleap/gsoft-license/blob/master/LICENSE.
