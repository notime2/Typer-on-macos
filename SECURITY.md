# Security Policy

## Reporting a vulnerability

Do not open a public issue for a security problem.

Report it privately through GitHub's
[private vulnerability reporting](https://github.com/notime2/Typer-on-macos/security/advisories/new)
on this repository. Include what you found, how to reproduce it, and the
impact you believe it has.

This is a solo project with no paid support and no bug bounty. Expect an
acknowledgement within a couple of weeks, and understand that a fix may take
longer or, for issues judged low impact, may not ship at all.

## Supported versions

Only the latest release is supported. There are no backports.

## Scope

Typer On runs unsandboxed on the user's Mac, holds Accessibility permission,
and stores an OpenRouter API key in the system Keychain. Reports that are
particularly relevant:

- Leaking the API key out of the Keychain, into logs, or into a network
  request other than the configured OpenRouter endpoint.
- Leaking captured text or screenshot data anywhere other than the OpenRouter
  request the user triggered.
- Abusing the Accessibility permission to read or write text the user did not
  select.
- Any path where a response from the model can cause code execution, file
  writes, or shell invocation.

## Out of scope

- The absence of Developer ID signing and notarization on unofficial builds.
  This is a known limitation, documented in the README.
- OpenRouter's own infrastructure, availability, or model behavior. Report
  those to [OpenRouter](https://openrouter.ai).
- The content or quality of model output.
- Anything that requires an attacker to already have local code execution or
  administrator access on the user's Mac.
