# .github

Account-wide defaults and the starting point for new `cyberflamingo` repositories. This repository
is a **template**: on GitHub, **Use this template** copies the workflow, pre-commit config,
Dependabot config, `CODEOWNERS`, security policy, issue and PR templates, and the hardening script
into a new repository. A template copies files, not settings, so the script applies the settings.

## Starting a new repository

1. **Use this template** (or `gh repo create cyberflamingo/<name> --private --template cyberflamingo/.github`).
2. Adjust the copied files: `CODEOWNERS`, the README, and the workflows for the project's language.
   Add a `ci.yaml` that runs the project's tests; its job name is a required check.
3. Run `scripts/harden-repo.sh cyberflamingo/<name> --no-rulesets` so the first PR is not blocked.
4. Open the first PR, read the check names from its run, merge, then re-run the script with
   `--checks "Test,Pre-commit"` to add the rulesets.

## What GitHub applies automatically

GitHub uses these files for every repository under the account that does not have its own copy:

- `SECURITY.md`: how to report a vulnerability, and how repositories are protected.
- `pull_request_template.md`
- `ISSUE_TEMPLATE/`

A personal account has no organisation-wide policy for Actions, rulesets or merge settings, so
those are applied per repository by the script below.

## `scripts/harden-repo.sh`

Applies the hardening baseline to one repository and reads every setting back, because GitHub can
accept a change and still leave it off.

```bash
scripts/harden-repo.sh cyberflamingo/<repo>
scripts/harden-repo.sh cyberflamingo/<repo> --checks "Test,Pre-commit" --allow 'astral-sh/setup-uv@*'
```

| Option                | Use when                                                                                                                                                             |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--checks "A,B"`      | The repo has CI. Use the job names a real run reports. A name no workflow reports blocks merge. Repeat it on every re-run, or the ruleset loses its required checks. |
| `--code-scanning`     | Turn on CodeQL. Public repos with a supported language only; a repo that already has it is left alone.                                                               |
| `--allow PATTERN`     | A workflow uses an action from outside GitHub-owned and verified creators.                                                                                           |
| `--no-actions-policy` | A workflow has unpinned `uses:`. Pin them first, then re-run without this flag.                                                                                      |
| `--no-token-policy`   | A workflow relies on a write token. Give the job explicit `permissions`, then re-run.                                                                                |
| `--no-rulesets`       | You do not want pull-request-only `main`.                                                                                                                            |

Each line ends in `OK`, `VERIFIED`, `UNAVAILABLE` (the plan or visibility does not allow it) or
`NO-EFFECT` (accepted but not applied). Needs `gh` (authenticated, admin on the repo) and `jq`.

What it sets: squash-only merges with the PR title and body as the commit message, delete branch
on merge, suggest updating branches, web commit sign-off, auto-merge, immutable releases,
Dependabot alerts and security updates, secret scanning and push protection, private vulnerability
reporting (public repos), allowed actions limited to GitHub-owned and verified creators with SHA
pinning required, a read-only default token that cannot approve pull requests, and three rulesets:
`main: PR and checks`, `main: history integrity`, `tags: immutable releases`.

On a private repository on GitHub Free, rulesets, secret scanning, code scanning and auto-merge are
refused. The script reports them as `UNAVAILABLE` or `NO-EFFECT` and the repository should record
the gap. For private Python code, ruff's `S` rules and `zizmor` in pre-commit are the stand-in for
CodeQL.

`--code-scanning` uses CodeQL's default setup, so there is no workflow file to maintain. CodeQL
covers Python, JavaScript/TypeScript, Ruby, Go, Java/Kotlin, C/C++, C#, Swift and Rust, not Shell,
Nix, HTML or Markdown. Add the flag when creating a public repo with application code.

## Account settings the API cannot change

Set these once at github.com/settings:

- Code security: enable Dependabot alerts, security updates, secret scanning and push protection
  for new repositories.
- Password and authentication: passkeys or an authenticator app, and recovery codes stored safely.
- SSH and GPG keys: add the signing key as a **signing** key, and turn on vigilant mode so
  unsigned commits are flagged.
- Emails: keep the email private and block command-line pushes that expose it.
- Developer settings: prefer fine-grained personal access tokens with an expiry, and review
  authorised OAuth apps.
