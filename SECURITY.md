# Security Policy

## Reporting a vulnerability

Email **tommy@muckstack.com** with details. Please do not open a public issue for security problems. You'll get a response within a few days, and a fix ships via the app's auto-update channel as soon as it's ready.

## Scope notes

- My Man runs locally by default; the attack surface includes the app, its update channel, and capture files. Optional publishing uses a separately deployed sharing service with private Blob storage. Published links can be opened by anyone who has the link until expiry or revocation. All AI runs on-device by default. An optional setting can send meeting notes, tasks, and Brain chat to Anthropic's or OpenAI's API using your own key, stored in your Mac's Keychain. The key is stored in the macOS Keychain and is never logged or sent to analytics.
- The Brain export contains private notes and transcripts and is a Git repository. Keep any remote private; deleting a capture does not erase copies already present in Git history or a remote repository.
- Updates are Sparkle EdDSA-signed and delivered over HTTPS; the public key is embedded in the app. Reports about the update chain are especially welcome.
- Analytics/crash-reporting keys are not in the source tree; they're injected into official builds at release time. Keys extracted from a shipped binary are publishable client ingestion keys; abuse reports about them still welcome.
