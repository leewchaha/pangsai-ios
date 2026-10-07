# CloudKit schema CI token fix — 2026-10-07

## Failure reproduced from build logs

The `cloudkit-schema` Codemagic workflow stopped with `cktool validate-schema` exit 64 because no CloudKit management token was available. This is separate from signing and TestFlight integration credentials. Codemagic does not automatically provision `CLOUDKIT_MANAGEMENT_TOKEN` just because `environment.groups` includes `cloudkit`.

## Changes

- **`codemagic.yaml`**: added safe, actionable preflight checks for `CLOUDKIT_MANAGEMENT_TOKEN`, `TEAM_ID` and `CloudKit/schema.ckdb` before `cktool` calls; `set -euo pipefail` ensures validate/import failures propagate. Token remains in environment and is never echoed or passed as a command-line option. Validation still runs before import. Production deployment remains manual.
- **`docs/SETUP.md`**: explicit setup of the `cloudkit` variable group, token generation and deployment steps; distinguish it from the App Store Connect signing integration.
- **No app source, schema definition, signing workflow, Git history or notification extension changes.**

## Verification scope

Static YAML loading, shell syntax checking, mocked xcrun invocation tests and archive integrity comparison can verify the flow without credentials. A real `xcrun cktool` invocation requires a Mac runner and an authorized management token; a successful CloudKit import is **not** claimed here.

## Steps to take

1. Add a CloudKit Management Token as a Secret `CLOUDKIT_MANAGEMENT_TOKEN` in the Codemagic `cloudkit` variable group.
2. Add your Apple Developer `TEAM_ID` to the same group.
3. Push this updated configuration to the repository/branch Codemagic uses.
4. Run the **cloudkit-schema** workflow, then manually review/deploy schema changes to Production in CloudKit Console.

You can run **ios-testflight** separately. Its integrated code signing does not authenticate `cktool`.
