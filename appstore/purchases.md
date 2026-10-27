# Seven-day trial and one-time unlock

Requested September 17, 2026: free download, seven days of full access, then an
optional **$2.99 USD one-time unlock**, using Nonna's purchase model. No subscription,
renewal, or automatic charge. StoreKit supplies the localized price shown before
trial activation. The daemon remains free.

## App Store Connect

App: **Landline: Tailscale SSH**, ID `6808344753`, bundle `com.landlineclient.app`.
Version **1.1 (19)** and both purchase products are **Waiting for Review**,
verified via App Store Connect on September 17, 2026. The publisher submitted
review at 13:00 Europe/Madrid and confirmed successful TestFlight testing.
The submission ID is `decffa85-79d2-490a-9a59-886bd263ff0b`.

The release setting is now **After Approval**, changed from the prepared manual
release draft. The current US app download price is still **$2.99 upfront**, with
no end date or future free price in the base schedule. This must switch to **Free**
before the trial-enabled version releases, so new users are not charged for both
the download and the full unlock. This verification did not change live settings.

| Product | ID | Type | US base price |
| --- | --- | --- | --- |
| 7-day Trial | `com.landlineclient.app.trial7days` | Non-consumable | $0.00 |
| Unlock Landline | `com.landlineclient.app.fullUnlock` | Non-consumable | $2.99 |

Both products have saved English and Korean names/descriptions, availability in
all 175 existing app territories, automatic availability in future territories,
and Family Sharing off. Prices, territory availability, and localized metadata
were read back from Apple after saving. Version 1.1 descriptions and release
notes also match the exported English and Korean records.

Local source files: [version listing](localizations.json),
[English trial](en-US/trial.json), [English unlock](en-US/full-unlock.json),
[Korean trial](ko/trial.json), and [Korean unlock](ko/full-unlock.json).

## Access behavior

- A verified acquisition of the free non-consumable starts the trial. It lasts
  exactly 168 hours from the original purchase date. Installation and restoration
  never start or extend it. Dates before that verified start grant no trial access.
- The free trial button requires both the zero-price trial and the unlock's local
  price to be available. The paid unlock is optional during or after the trial.
- After expiry, terminal access requires purchase. Existing terminal views detach
  within one second; user input and new connection attempts check access directly.
  No KILL frame is sent. Saved session IDs, hosts, settings, and snippets remain.
  The daemon still applies its normal idle timeout to detached sessions.
- Host setup, saved settings/snippets, and session management remain accessible.
  Both compact navigation and split-view terminals use the same access gate.
- StoreKit's verified history supplies access after relaunch and while offline.
  A transient refresh error retains the last verified in-memory state. A failed
  initial verification grants no access. Cancellation and pending approval grant
  nothing; a verified completion unlocks, and refund updates revoke the purchase.
- Restore purchases is available in the offer and Settings > Trial & purchase.
  No developer account, billing server, or telemetry is introduced.
- Trial time uses the device clock, like Nonna. There is no server-side clock or
  cross-account abuse detection.

## Existing users

A verified production `AppTransaction` for this bundle with an original iOS
**build number below 19** grants full access, including users who acquired the
app during its initial free period. On iOS, `originalAppVersion` is the build
number, not the marketing version. Sandbox/Xcode transactions never grant this
legacy access; their placeholder version is not a production purchase.

Build 19 is the fixed migration boundary. Do not move it when incrementing a
later build. This follows [Apple's app transaction migration guidance](https://developer.apple.com/documentation/storekit/supporting-business-model-changes-by-using-the-app-transaction).
The trial product follows [Apple's non-subscription trial rule](https://developer.apple.com/app-store/review/guidelines/#in-app-purchase).

## Verification and release

Use **Landline StoreKit** for local runs and automated StoreKit tests. Its catalog
is in the test target only. The ordinary **Landline** scheme and Release build
use Apple's catalog. Unit tests cover trial boundaries, existing-user eligibility,
price disclosure, cancellation, pending state, restoration, verification failures,
and a hosted terminal expiring without KILL or losing its session ID. Integration
tests cover real local StoreKit trial/unlock transactions, restore, refund updates,
and screenshots of the offer at phone and tablet widths.

The installed iOS 26.3 runtime fails SKTestSession configuration writes with
`SKInternalErrorDomain Code=3`, a [known Apple StoreKit testing issue](https://developer.apple.com/forums/thread/826971).
Use the installed iOS 18.4 runtime for the full StoreKit suite. All 300 tests
passed there, including trial acquisition,
restoration without restarting the clock, paid unlock, refund updates, and the
rendered purchase screens. The app's other 297 tests also passed on iOS 26.3.
The iPhone Release build and signed archive passed. The archive is version
1.1 (19), with export compliance declared and no local StoreKit catalog bundled.
Both private purchase review screenshots processed successfully. The App Store
distribution IPA was exported with automatic provisioning through the existing
App Store Connect API key and uploaded successfully. Apple processed build 19 as
**VALID**, and the API confirms it is attached to the submitted version 1.1.
Submission preflight passed **10/10** checks before submission.

The publisher confirmed that the app works in TestFlight and submitted the app
and both purchase products for review on September 17, 2026. The exact device,
currency, and individual purchase edge cases tested were not specified, so this
confirmation does not establish coverage of every case listed below.

Before the pricing transition goes live:

1. Change the app download price to **Free** and verify propagation before approval
   triggers automatic release. Older-build acquisitions during this transition
   retain full access under the same legacy rule.
2. Publish the updated privacy policy from `docs/PRIVACY.md` with the code release.
3. Retain the publisher's successful TestFlight result. Separately verify any
   untested cases: restoration, offline relaunch, cancellation/refund, local
   currency, and existing-customer migration from a production installation.

Apple has not approved the update or products yet. The new pricing model is not
live. This status check made no new submission and changed no release or price
settings.
