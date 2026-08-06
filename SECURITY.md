# Security Policy

## Reporting a vulnerability

Email **tommy@muckstack.com** with details. Please do not open a public issue for security problems. You'll get a response within a few days, and a fix ships via the app's auto-update channel as soon as it's ready.

## Scope notes

- My Man has no backend; the attack surface is the local app, its update channel, and its capture files.
- Updates are Sparkle EdDSA-signed and delivered over HTTPS; the public key is embedded in the app. Reports about the update chain are especially welcome.
- Analytics/crash-reporting keys are not in the source tree; they're injected into official builds at release time. Keys extracted from a shipped binary are publishable client ingestion keys; abuse reports about them still welcome.
