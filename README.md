# Dev Container

## Description

Source of the image for development container where most of the tools I use preinstalled.

## CI/CD Workflow

This project uses a multi-branch CI/CD pipeline with security scanning and controlled releases.

### Branching Strategy

1. **Feature Development**: Developers create feature branches from the latest `release/*` branch to work on new
   features or bug fixes.

2. **Integration & Security Scanning**: All feature branches are merged into a `release/*` branch. Upon merge, GitHub
   Actions automatically trigger and run **Trivy** security scans to detect vulnerabilities in the container image and
   dependencies before the code progresses further.

3. **Release to Main**: Once validated, the `release/*` branch is merged into the `main` branch. The `main` branch
   always contains production-ready code.

4. **Tagging & Releases**: New tags (and corresponding releases) are created **only** from the `main` branch. A special
   check enforces this policy to ensure that no tags can be created from feature or release branches, maintaining
   release integrity.
