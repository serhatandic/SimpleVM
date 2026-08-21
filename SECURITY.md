# Security Policy

## Supported versions

Security fixes currently target the latest commit on `main`. There are no
stable binary releases yet.

## Report a vulnerability

Do not open a public issue with exploit details, private VM data, credentials,
or host information.

Use GitHub's private vulnerability reporting flow:

<https://github.com/serhatandic/SimpleVM/security/advisories/new>

If private reporting is unavailable, contact the maintainer through the GitHub
profile before sharing technical details.

Include:

- A concise impact statement
- Affected SimpleVM revision
- Reproduction steps or a proof of concept
- Relevant macOS and guest versions
- Any known mitigations

No response-time or disclosure-time guarantee is currently offered.

## Windows guest boundary

SimpleVM verifies the pinned UTM support ISO before deriving Windows media.
Only allowlisted signed ARM64 drivers, licenses, and the user-invoked UTM tools
installer are copied. The original UTM unattended policy is never mounted.
SimpleVM's answer file is limited to driver staging and contains no product key,
credentials, hardware-check bypass, OOBE policy, activation command, or
first-logon execution.

The virtual TPM protects guest state from ordinary guest access, not from the
macOS account that owns the VM files. Save the Windows BitLocker recovery key
outside the VM before snapshots, clones, or disk-only exports.
