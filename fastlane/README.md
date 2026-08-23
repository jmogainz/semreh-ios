# Fastlane

Maintainer-only release automation for Semreh.

```bash
bundle install
bundle exec fastlane ios internal_testflight
```

This lane is what `.github/workflows/internal-testflight.yml` runs on merge to `master`. It:

1. Selects the next App Store Connect build number
2. Archives a Release IPA with `ci/TestFlightExportIPA.plist`
3. Uploads that IPA to internal-only TestFlight

Required environment:

- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_KEY_PATH`
- `MARKETING_VERSION`
