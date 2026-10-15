# Security and privacy

PRch executes the installed GitHub CLI directly, without a shell, and sends GraphQL request bodies over stdin. Authentication remains with the CLI; the app does not read or persist its token. Standard GitHub CLI environment overrides are respected.

Only GitHub.com HTTPS links are opened. Organization names are validated before interpolation into search qualifiers. Results are checked against the organization and selected repository scope independently of the search query.

PR data remains in memory. Local macOS preferences contain organization/repository selections and display settings. Raw API errors are replaced with fixed messages to avoid accidental disclosure in logs or screenshots. There is no analytics or application server.

Do not report a security issue with credentials or private PR data in a public issue. Use private vulnerability reporting when enabled, or first ask the maintainer for a private contact channel without disclosing sensitive details.
