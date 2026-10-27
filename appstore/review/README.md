# Purchase offer review images

These images render the production SwiftUI PurchaseScreen with Apple's local
StoreKit test catalog at the configured US prices: free trial and $2.99 unlock.
They were exported from StoreKitIntegrationTests on an iOS 18.4 simulator and
visually inspected at 390-point phone and 768-point tablet widths. They are not
proof of real sandbox or production purchases. No personal data is present.

The phone image is the private App Review screenshot for both products.
Regenerate with the Landline StoreKit scheme, then export attachments from
StoreKitIntegrationTests/testPurchaseScreenAtPhoneAndTabletWidths() using
xcresulttool. The catalog is bundled only in the test target.
