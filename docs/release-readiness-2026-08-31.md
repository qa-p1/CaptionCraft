# CaptionCraft release-readiness audit

Base: `origin/master` at `32ebd5d1d7f68d93804659a7832906aa659fadf1`.

## Fixed in code

- Instagram inspection now validates canonical HTTPS post/Reel URLs, uses bounded canonical and public-embed attempts, understands Open Graph, current serialized URL names, and `video_versions` payloads, deduplicates media, and refreshes expiring links on retry.
- Instagram failures distinguish invalid links, private/login-only media, upstream anonymous-access blocking, deleted/unavailable posts, rate limiting, network errors, and timeouts. In-flight requests are cancelled and owned HTTP resources are closed on disposal.
- Instagram CDN downloads now send the required page origin/referer context, have a bounded connection setup, validate the downloaded payload independently of its extension, remove partial files, and give retry-specific messages for expired CDN URLs.
- Firebase initialization failures no longer terminate before Flutter can render. The app presents a sanitized startup failure screen while detailed diagnostics remain in development logs.
- App icon geometry now has optical safe-zone padding. Android adaptive foreground scaling, legacy/round launcher PNGs, iOS icon sizes, and Android/iOS launch images use the same centered mark. Regression coverage checks required PNG dimensions and visible margins.
- Generated golden-test failure images are no longer tracked. The validation workflow now runs for release-readiness branches and includes Android debug packaging after analysis and tests.

## Automated verification

The validation workflow pins Flutter 3.41.2, restores the lockfile, runs `flutter analyze`, runs the full `flutter test` suite, and builds a debug Android APK. Targeted regression tests cover Instagram fallback parsing and failure classification, request timeouts/disposal, startup failure rendering, icon margins, and platform asset completeness.

## Required release gates outside unit tests

- Test a public photo post, carousel, video post, and Reel on real Android and iOS devices from at least two networks. Instagram can block anonymous clients even for public content; no client-only scraper can guarantee access when Instagram returns an error shell. Confirm the UI reports that state rather than presenting it as a private/deleted post.
- Inspect adaptive, round, legacy, iOS, and splash artwork on physical devices and store-preview tooling. Platform launchers apply masks that cannot be reproduced exactly by PNG checks.
- Supply and verify Android release signing, Apple signing/provisioning, production bundle identifiers, App Store/Play metadata, and store privacy declarations.
- Verify Firebase Auth providers, Firestore rules/indexes, App Check enforcement, OAuth fingerprints/redirect schemes, quotas, and production project selection in the Firebase and Google consoles.
- Exercise background/resume during downloads, saves, and exports; interrupted exports; corrupted/missing source media; low-storage behavior; very large projects; and long multi-layer exports on representative low-, mid-, and high-end devices.
- Configure required API keys and the asset-pack manifest URL in the release environment. Run the unsigned iOS workflow and signed Android/iOS release builds with production secrets before submission.
