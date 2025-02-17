# Workleap's reusable GitHub Actions repository

This repository contains centralized workflows that are re-used across the organization's repositories.

# Renovate daily workflow

This repository also hosts the daily [Renovate](https://docs.renovatebot.com/) workflow for the whole [gsoft-inc GitHub organization](https://github.com/workleap/).

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

## Terraform checks

This workflow runs TF-Lint to find issues in the code, Terraform-Docs to create a README and Terraform FMT to format the code.

## Git tag

This workflow creates a new Git tag.

## License

Copyright © 2024, Workleap. This code is licensed under the Apache License, Version 2.0. You may obtain a copy of this license at https://github.com/workleap/gsoft-license/blob/master/LICENSE.
