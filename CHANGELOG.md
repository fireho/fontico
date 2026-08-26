# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Vendor icons on a grid other than 24 shipped cropped to their top-left
  corner. Iconify returns a body fragment with its dimensions out of band,
  and the wrapper the preprocessor built around it hardcoded a 24×24 viewBox,
  so the refit computed a scale of 1 and never ran. arcticons (48) rendered as
  its own top-left quarter, game-icons (512) as a near-empty corner. lucide is
  24, which is why the default provider never showed it.

## [0.1.0]

- Initial release.
