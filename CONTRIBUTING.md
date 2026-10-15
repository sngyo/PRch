# Contributing

Build with Swift 6 on macOS 14 or newer. Run `swift test` and `bash scripts/build-app.sh` before submitting a change. Tests and CI must work without credentials or network access.

Keep GitHub transport and classification logic in `ReviewCore`, separate from SwiftUI. Cover changes to pagination, organization boundaries, review states, and scope with synthetic fixtures. Do not add tests that call a real organization by default.

Do not commit access tokens, local settings, real API responses, private repository names, private PR titles, or screenshots of live data. Use `--demo` for public screenshots. Build outputs and local verification artifacts belong in ignored directories.

Use generic fictional names for fixtures, demo data, and documentation, such as `example-org`, `sample-web`, `sample-docs`, and `sample-api`. Invent PR titles independently of real work. Internal company, product, customer, repository, and account names must not appear in source, tests, comments, or sample assets, including abbreviated forms. Keep any organization-specific audit terms outside the public repository.

README media is generated from `docs/media/preview.html`, an interactive illustration with fictional data, rather than a recording of a real account. Serve the repository locally (`python3 -m http.server --bind 127.0.0.1`) and open that page. The controls select the menu-bar, incoming, outgoing, and changes scenes; Play demo cycles through them. Capture only the scene, excluding its preview controls. The `?capture` query disables transitions for deterministic stills. Keep the preview consistent with the native UI and label it as an illustration. Refresh `preview.jpg`, `demo.gif`, and `demo.mp4` together when the depicted UI changes.

The app must continue to use read-only GitHub operations. Expanding permissions, adding telemetry, storing PR payloads, or changing authentication requires an explicit design discussion.

## Localization

UI translations live in `Sources/PRch/Resources/{language}.lproj/Localizable.strings`, with semantic keys shared across languages. Use `L10n.text` for visible text, tooltips, and accessibility labels; keep GitHub content verbatim. Format complete sentences with positional placeholders (`%1$ld`, `%2$@`) so translators can reorder arguments. Use Foundation's locale-aware formatters for relative dates and plural units.

To add a language, copy the English resource into a new `.lproj`, translate its values, then add its code and native display name to `AppLanguage` and `Resources/Info.plist`. Keep English as the fallback. Extend localization tests to check the new language's keys and placeholders. Errors and warnings remain typed in ReviewCore and are translated when displayed, so changing languages also updates previously fetched results. Avoid translated strings in application state.

Run `swift test` and `bash scripts/build-app.sh`. Verify the generated `.app` away from the checkout so missing resource bundles cannot be hidden by build-directory fallbacks. Check both menu bar and window views; language changes must not reset repository drafts, filters, or fetched data.
