# Claude Usage 3.0: Mac App Store readiness

**Verdict: not ready for the Mac App Store.** Use Developer ID distribution for the current app after obtaining the required membership and certificate. The App Store export options and entitlements in this repository are preparation files. They do not make the current app sandbox compatible.

## Blockers

Effort estimates are engineering estimates for one engineer. They exclude membership processing, legal review, and App Review time. Guideline references describe the issues to resolve; check the live rules before submission.

| Guideline or requirement | What breaks | Fix | Effort |
| --- | --- | --- | --- |
| 2.4.5(i) | Mac App Store apps must use App Sandbox. The current app reads Claude Code's `Claude Code-credentials` Keychain item. A sandboxed app cannot read another app's Keychain items. | Remove shared Keychain access. Accept a user-provided token and store it in the app's own Keychain item, or read a user-selected token folder. | 2 to 4 days |
| 2.4.5(i) and 2.5.2 | The app launches bundled `server.py` with `/usr/bin/python3`, which is an Xcode Command Line Tools shim on stock macOS. It also runs `codex app-server` from the user's PATH and `claude auth login` in Terminal through AppleScript. Child processes inherit the sandbox. These flows break or require temporary-exception entitlements that App Review normally rejects. | Rewrite the server as Swift services inside the app. Remove external interpreter, CLI, Terminal, and sign-in/out dependencies from the App Store build. | 1 to 2 weeks |
| Sandbox file access | `~/.config/claude-bridge/accounts`, `~/.config/codex-bridge/env`, and `~/.codex/sessions` are outside the container. | Ask the user to choose each needed folder with `NSOpenPanel`. Persist security-scoped bookmarks. Use `com.apple.security.files.user-selected.read-only` and `com.apple.security.files.bookmarks.app-scope`. | 2 to 4 days |
| 2.4.5(iii) | Launch at login requires user consent. | **Done in 3.0:** an opt-in Settings toggle, with no automatic registration. Verify this behavior in the final sandboxed build. | Implemented; final QA remains |
| 5.2.1 and 5.2.2 | Claude and Codex are Anthropic and OpenAI trademarks. Claw'd is Anthropic's character. The current name, icon, and artwork need permission. The app also uses Claude subscription OAuth tokens with `/api/oauth/usage` and `/api/oauth/profile`, and sends a 1-token probe that counts toward the user's limits. | Obtain written name/art permissions or choose a neutral name and original artwork. Check Anthropic's and OpenAI's current terms. Confirm that the services permit the access and token use, including probes, before submitting. | External permission; time unknown |
| 5.1.1 | App Store Connect requires a privacy policy URL, including for an app that collects nothing. | Publish a policy covering local credentials, provider requests, probe cost, retention, and contact details. Add its URL in App Store Connect and the app. | 1 to 2 days plus policy review |
| Accounts and certificates | The current free Personal Team and Apple Development certificate cannot deliver an App Store build. | Complete paid membership, distribution certificates, registered bundle ID, agreements, and App Store Connect app record. | Administrative; time unknown |

## Prerequisites

1. **Join the paid Apple Developer Program (USD 99 per year).** Team `FP62793T7J` is currently a free Personal Team (`isFreeProvisioningTeam = 1`). It cannot issue Developer ID or App Store distribution certificates or use notarization. The installed identity is `Apple Development: developer@example.com (M6W8MTA32Y)`. `M6W8MTA32Y` is a member ID, not the team ID.
2. For App Store delivery, obtain **Apple Distribution** and **Mac Installer Distribution** certificates with their private keys. Register `com.heng.claude-usage-widget`, then create its macOS app record in App Store Connect. A renamed app may also need a new bundle ID and record.
3. Build with Xcode 27 and XcodeGen 2.46 or later. Resolve every blocker below before preparing an App Store archive.

## Sandbox-ready architecture

Implement a Swift `UsageService` with `URLSession` inside the app. Give the App Store build `com.apple.security.network.client` for outbound provider requests. Remove the Python HTTP server and loopback API from this build. Keep account models and formatting in `Packages/UsageKit`.

Read token files from a folder chosen by the user. Save a security-scoped bookmark in the app container. Resolve it on launch, handle stale bookmarks by asking again, and balance `startAccessingSecurityScopedResource()` with `stopAccessingSecurityScopedResource()`. Read-only access means this build cannot rotate or update the user's token files. Renewals happen outside the app. Offer an optional **Paste a token** flow that stores the token in the app's own Keychain item.

Read Codex usage from user-selected rollout files only. Do not run `codex app-server`, read another app's Keychain, or provide sign in, switch account, or sign out actions. The user chooses a sessions folder rather than granting access to an entire home directory. Missing or expired quota data stays visibly unavailable or stale.

Use a neutral name and original art unless written permissions cover the current branding. Retain the 3.0 launch-at-login consent flow. Any retained usage endpoint or probe must pass the service-terms review first. Explain probe cost before the user enables it.

## Prepared configuration files

| File | Purpose |
| --- | --- |
| `Config/ExportOptions-DeveloperID.plist` | Current external distribution: `developer-id`, team `FP62793T7J`, automatic export signing. |
| `Config/ExportOptions-AppStore.plist` | Future App Store package: `app-store-connect`, destination `export`, team `FP62793T7J`, automatic export signing. |
| `Config/ClaudeUsage-AppStore.entitlements` | Future sandbox build only: App Sandbox, outbound network, user-selected read-only files, and app-scoped bookmarks. |

The App Store entitlements have no header comment. Their intent is documented here. They deliberately omit Apple Events and temporary exceptions. Keep the current Developer ID build on `Config/ClaudeUsage.entitlements` until the architecture changes are complete. Adding these four entitlements alone will break current credential, file, and subprocess flows.

## How to switch the build to App Store when the blockers are gone

1. Finish the Swift service, folder-selection UI, credentials flow, branding, terms review, privacy policy, and certificate setup. Test on a clean Mac without developer tools. Confirm that the sandbox build neither starts external tools nor reads outside its granted folders.
2. Merge a `Release-AppStore` configuration into `project.yml`. Keep the existing Debug and Release configurations. Extend `configFiles` to use `Config/Shared.xcconfig`, and add these configuration-specific settings. This is a future edit, not a change applied by this document:

   ```yaml
   configs:
     Debug: debug
     Release: release
     Release-AppStore: release
   configFiles:
     Debug: Config/Shared.xcconfig
     Release: Config/Shared.xcconfig
     Release-AppStore: Config/Shared.xcconfig
   settings:
     configs:
       Release-AppStore:
         CODE_SIGN_STYLE: Automatic
         CODE_SIGN_IDENTITY: Apple Distribution
         CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO
   targets:
     ClaudeUsage:
       settings:
         configs:
           Release-AppStore:
             CODE_SIGN_ENTITLEMENTS: Config/ClaudeUsage-AppStore.entitlements
   ```

   Merge these keys into the existing mappings. Do not replace the target, resources, base settings, or other configurations. Update the bundle ID and export team if the final app registration differs.
3. Outside the sandbox, with no other build using `.build/xcode`, generate and archive. Use a fresh archive/export path for each delivery:

   ```bash
   xcodegen generate
   xcodebuild archive -project ClaudeUsage.xcodeproj -scheme ClaudeUsage \
     -configuration Release-AppStore -destination 'generic/platform=macOS' \
     -archivePath .build/app-store/ClaudeUsage.xcarchive \
     -derivedDataPath .build/xcode -allowProvisioningUpdates
   xcodebuild -exportArchive \
     -archivePath .build/app-store/ClaudeUsage.xcarchive \
     -exportOptionsPlist Config/ExportOptions-AppStore.plist \
     -exportPath .build/app-store/export -allowProvisioningUpdates
   ```

4. Inspect the exported package and effective entitlements. Confirm App Sandbox is enabled, the registered bundle ID and version are correct, and the package has a Mac Installer Distribution signature. The App Store workflow delivers a package, not the Developer ID DMG. Do not use `scripts/release.sh` for this path.
5. Upload the exported `.pkg` with Transporter: sign in to the correct App Store Connect team, add the package, and choose **Deliver**. Alternatively, use Xcode Organizer's **Distribute App > App Store Connect** flow. Command-line delivery uses `xcrun altool --upload-package`; consult `xcrun altool --help` in the selected Xcode for its package, app ID, bundle/version, and API-key options. Keep private keys and credentials outside the repository.
6. Wait for processing in App Store Connect. Select the build, complete the metadata and privacy answers, add screenshots and review notes, test through TestFlight, and submit for review.

## App Store Connect metadata draft

This draft describes the future sandbox-ready build. Replace placeholders and recheck the final behavior before submission.

| Field | Draft |
| --- | --- |
| Name | **Usage Desk**: neutral suggestion, subject to name availability and clearance. **Claude Usage**: current name, **needs trademark permission**. |
| Subtitle | `Usage limits in your menu bar` (29 characters; limit 30). |
| Category | Developer Tools |
| Keywords | `usage,quota,limits,developer,menu bar,productivity,monitor,accounts` (67 characters; limit 100). |
| Privacy label | **Data Not Collected**: draft for a build with no developer analytics, telemetry, or data sent to the developer. Confirm the final implementation and provider data flows against Apple's privacy questionnaire. |
| Privacy policy URL | Required. Publish the reviewed policy and enter its HTTPS URL here. |
| Support URL | Required release metadata: publish a support page with contact and token-renewal help. |

**Description**

See account usage limits in your Mac's menu bar and an optional desktop widget. Choose a primary and secondary account, compare usage windows, and see when limits reset.

Choose Percent, Battery, HP Bar, Dual Bars, or Ring. Settings include a live preview, account display options, and an opt-in launch-at-login toggle.

Connect accounts using a token you provide or files in a folder you select. Codex usage is read from selected local rollout files. Credentials stay in your files or this app's Keychain item. The app has no developer analytics. Usage requests go directly to the relevant provider. Limits and available data depend on the account and provider. Any enabled probe counts toward that account's usage.

**Review notes draft**

The app runs in the menu bar and has no Dock window. Open Settings with Command-comma. Launch at login is off until the user enables it. The App Store build uses App Sandbox and an in-process Swift service. It does not launch Python, CLIs, or Terminal, and it does not access Claude Code's Keychain item. The user grants read-only folder access with a system picker or pastes a token into this app's own Keychain item. Codex data comes from selected rollout files.

Before upload, provide a working review account or permitted sample files, steps to load them, expected limits/reset values, and a way to exercise unavailable and stale states. Describe any network-dependent feature and probe cost. Attach trademark/art permission if the current branding remains. Replace this paragraph with the actual review access instructions. Do not include production credentials in public metadata.

**Mac screenshots**

Use accepted Mac sizes: **1280x800**, **1440x900**, **2560x1600**, or **2880x1800** pixels. Capture the final sandboxed UI: menu account card and provider list, Settings live preview, consent-based account setup, and desktop widget. Use sample identities and redact tokens. Existing widget pose images in `docs/` document the character; they are not App Store screenshots. Do not submit menu images from an older release.

## References to check before submission

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/): 2.4.5(i), 2.4.5(iii), 2.5.2, 5.1.1, 5.2.1, and 5.2.2.
- [Apple Developer Program enrollment](https://developer.apple.com/programs/enroll/).
- [App Store Connect Help](https://developer.apple.com/help/app-store-connect/).
- [Anthropic terms](https://www.anthropic.com/legal/consumer-terms) and [commercial terms](https://www.anthropic.com/legal/commercial-terms).
- [OpenAI terms](https://openai.com/policies/terms-of-use/) and [services agreement](https://openai.com/policies/services-agreement/).

These links are review starting points. No current terms verification or permission grant is claimed by this document.
