Added the Claude Usage 3.0 Developer ID pipeline, standalone DMG packager, future App Store export and sandbox files, App Store readiness document, rewritten English/Thai README, and fleet deployment of one locally built app. Shell and plist checks pass. The requested release invocation stops at the missing Developer ID certificate with exit 2 before project generation or building. Fleet status succeeds without writes or network access. No archive, real signing, notarization, DMG creation, deployment, app launch, browser, outbound notification, or commit was performed. Changes in Sources and Packages belong to the concurrent UI work; this task did not edit them, project.yml, or the generated Xcode project.

Files written

- `scripts/release.sh`
- `scripts/make-dmg.sh`
- `Config/ExportOptions-DeveloperID.plist`
- `Config/ExportOptions-AppStore.plist`
- `Config/ClaudeUsage-AppStore.entitlements`
- `docs/APP_STORE.md`
- `README.md`
- `../../infra/fleet/deploy-usage-widget.sh`
- `RESULT-release.md`

Decisions and reasons

- Resolve release paths from the script location, and quote paths throughout. The release works from another current directory and supports the spaces in this checkout path.
- Read DEVELOPMENT_TEAM directly from project.yml without invoking XcodeGen or Xcode. Require a matching valid Developer ID Application identity before checking other release tools or creating output directories. Check that the Developer ID export plist has the same team to catch a future team change.
- Override the archive identity to Developer ID Application while retaining manual archive signing. Keep automatic export signing in both supplied export plists as requested. Do not change the project's Apple Development settings.
- Keep Xcode output in .build/release logs. Require Accepted status from each notarytool plist response, validate both stapled tickets, and assess both products with Gatekeeper in a normal release.
- Treat --skip-notarize as local testing: still require Developer ID and sign the app/DMG, but skip submission, stapling, and Gatekeeper assessments that would reject an unnotarized product. Label the output accordingly.
- Preserve earlier archives, exports, ZIPs, DMGs, and checksums under .build/release. Retain DMG staging for inspection. The standalone packager refuses an existing destination instead of replacing it.
- Fleet deployment creates a fresh installed bundle with ditto and retains the previous app under ~/Library/Caches/claude-usage-widget/deploy/previous.*. A failed copy or launch restores that previous app. Runtime cleanup removes only the deployment's own transfer directory, as required by the brief. Nothing was deleted during this task.
- Add pipefail to detect a failed tar transfer. Parse SERVER_VERSION from the bundled Python source with ast rather than executing or importing it. Parse the remote ping JSON with /usr/bin/python3 -c and require its version and ok flag, plus an exact CFBundleVersion match.
- Make --status strictly read-only, even before state files exist. Skip the local build for an empty pending list so the original self-disabling LaunchAgent block still runs. A failed local build marks requested hosts pending and exits 1 before any remote mutation.
- Retain the hosts, pending paths, log, pending success LINE block, and LaunchAgent block. The LINE message and push command are unchanged. They were not run. Update the deployment comments for bundle transfer and retain the pkill parent-shell trap warning.
- Keep the README's account discovery, cache, probe-cost, Codex, configuration, credentials, and Thai information. Replace the old menu description, source layout, server location, build instructions, font-license path, and launch-at-login description. Do not claim the new native client falls back to the legacy single-account API; the current client uses /api/accounts.
- Describe the future sandbox build and metadata separately from the current Developer ID app. Usage Desk is a neutral suggestion subject to availability and clearance. Current service terms were not fetched, following the no-network constraint; the document requires checking them before submission.
- The prescribed multi-file bash -n command checks only the first script as shell input. An additional check parses each script separately and both embedded remote scripts. It also verifies plist values, executable bits, metadata lengths, local documentation links, and Markdown fences.

Feedback Loop

Commands ran from the task folder with /bin/bash. Output is reproduced below. Steps 3 and 4 end with echo, so their shell-command status is 0; the printed exit value is the script status. Step 5 exits 1 for no matches. Its command is displayed with equivalent UTF-8 byte escapes so this report contains no prohibited dash character. Step 4 prints historical log lines; those lines do not mean that this run launched, signed, installed, or notified anything.

Step 1

```bash
bash -n scripts/release.sh scripts/make-dmg.sh ../../infra/fleet/deploy-usage-widget.sh
```

Exit status: 0

```text
(no output)
```

Step 2

```bash
plutil -lint Config/ExportOptions-DeveloperID.plist Config/ExportOptions-AppStore.plist Config/ClaudeUsage-AppStore.entitlements
```

Exit status: 0

```text
Config/ExportOptions-DeveloperID.plist: OK
Config/ExportOptions-AppStore.plist: OK
Config/ClaudeUsage-AppStore.entitlements: OK
```

Step 3

```bash
bash scripts/release.sh --skip-notarize; echo "exit=$?"
```

Exit status: 0

```text
==> Check Developer ID Application certificate for team FP62793T7J
Missing: a valid Developer ID Application certificate and private key for team FP62793T7J.
1. Join the Apple Developer Program (paid membership, USD 99/year). A free Personal Team cannot release this app.
2. Create a Developer ID Application certificate at developer.apple.com > Certificates or Xcode > Settings > Accounts, and install its private key on this Mac.
3. Rerun scripts/release.sh.
exit=2
```

Step 4

```bash
bash ../../infra/fleet/deploy-usage-widget.sh --status; echo "exit=$?"
```

Exit status: 0

```text
ค้าง: 
/Applications/Claude Usage.app: replacing existing signature
==> Done! Claw'd is floating on your screen 🦀
    • drag to move · right-click for Refresh / Quit
    • auto-starts at login (System Settings › Login Items)
2026-10-20 10:05:48  macbook-neo · ผ่าน · server ab769ae761ff · ping ok
exit=0
```

Step 5

```bash
grep -n $'\xe2\x80\x94' scripts/release.sh scripts/make-dmg.sh docs/APP_STORE.md README.md ../../infra/fleet/deploy-usage-widget.sh
```

Exit status: 1

```text
(no output)
```

Additional static checks

```bash
python3 - <<'PY'
from pathlib import Path
import os
import plistlib
import re
import subprocess

scripts = [Path('scripts/release.sh'), Path('scripts/make-dmg.sh'), Path('../../infra/fleet/deploy-usage-widget.sh')]
for script in scripts:
    subprocess.run(['/bin/bash', '-n', str(script)], check=True)
    print('Shell syntax OK: ' + str(script))
fleet = scripts[2].read_text()
for marker, body in re.findall(r"<<'([A-Z_]+)'\n(.*?)\n\1", fleet, re.S):
    subprocess.run(['/bin/bash', '-n'], input=body, text=True, check=True)
    print('Remote heredoc syntax OK: ' + marker)
assert len(re.findall(r"<<'([A-Z_]+)'\n(.*?)\n\1", fleet, re.S)) == 2
for script in scripts[:2]:
    assert os.access(script, os.X_OK), str(script)
print('Release scripts are executable')
expected = {
    'Config/ExportOptions-DeveloperID.plist': {'method': 'developer-id', 'teamID': 'FP62793T7J', 'signingStyle': 'automatic'},
    'Config/ExportOptions-AppStore.plist': {'method': 'app-store-connect', 'destination': 'export', 'teamID': 'FP62793T7J', 'signingStyle': 'automatic'},
    'Config/ClaudeUsage-AppStore.entitlements': {
        'com.apple.security.app-sandbox': True,
        'com.apple.security.network.client': True,
        'com.apple.security.files.user-selected.read-only': True,
        'com.apple.security.files.bookmarks.app-scope': True,
    },
}
for filename, values in expected.items():
    assert plistlib.loads(Path(filename).read_bytes()) == values, filename
print('Export options and sandbox entitlements match the required keys')
for value, limit in [('Usage limits in your menu bar', 30), ('usage,quota,limits,developer,menu bar,productivity,monitor,accounts', 100)]:
    assert len(value) <= limit
    print('Metadata length: ' + str(len(value)) + '/' + str(limit) + ' ' + value)
for filename in ['README.md', 'docs/APP_STORE.md']:
    body = Path(filename).read_text()
    assert body.count('```') % 2 == 0
    for target in re.findall(r'!?\[[^\]]*\]\(([^)]+)\)', body):
        if '://' not in target and not target.startswith('#'):
            assert (Path(filename).parent / target).exists(), (filename, target)
print('Markdown fences and local documentation links OK')
PY
```

Exit status: 0

```text
Shell syntax OK: scripts/release.sh
Shell syntax OK: scripts/make-dmg.sh
Shell syntax OK: ../../infra/fleet/deploy-usage-widget.sh
Remote heredoc syntax OK: REMOTE_INSTALL
Remote heredoc syntax OK: REMOTE_PING
Release scripts are executable
Export options and sandbox entitlements match the required keys
Metadata length: 29/30 Usage limits in your menu bar
Metadata length: 67/100 usage,quota,limits,developer,menu bar,productivity,monitor,accounts
Markdown fences and local documentation links OK
```

Step 6a

```bash
git status --short
```

Exit status: 0

```text
 M README.md
 M Sources/ClaudeUsage/App/AppDelegate.swift
 M Sources/ClaudeUsage/App/main.swift
 M Sources/ClaudeUsage/Menu/MenuBuilder.swift
 M Sources/ClaudeUsage/Menu/MenuViews.swift
 M Sources/ClaudeUsage/Services/UsageClient.swift
 M Sources/ClaudeUsage/Widget/WidgetView.swift
?? Config/ClaudeUsage-AppStore.entitlements
?? Config/ExportOptions-AppStore.plist
?? Config/ExportOptions-DeveloperID.plist
?? Packages/UsageKit/Sources/UsageKit/MenuFormatting.swift
?? Packages/UsageKit/Tests/UsageKitTests/MenuFormattingTests.swift
?? RESULT-release.md
?? Sources/ClaudeUsage/App/AppModel.swift
?? Sources/ClaudeUsage/Debug/QAOptions.swift
?? Sources/ClaudeUsage/Settings/
?? docs/APP_STORE.md
?? scripts/make-dmg.sh
?? scripts/release.sh
```

Step 6b

```bash
git -C ../../.. status --short agents/infra/fleet 2>/dev/null || true
```

Exit status: 0

```text
(no output)
```

Additional whitespace check

```bash
git diff --check -- README.md
```

Exit status: 0

```text
(no output)
```

The prescribed git command for the fleet path (Step 6b) produced no output. Its trailing || true and suppressed stderr mean this is not evidence that the fleet file has a clean tracked diff. The fleet directory is outside this app repository. Source and package changes listed above are the concurrent UI engineer's work. A final text audit confirmed that all nine deliverables contain no U+2014 characters and that the implementation and documentation files have no trailing whitespace.


Open questions for the reviewer

- When will team FP62793T7J enroll in the paid Apple Developer Program and install Developer ID Application plus the notarytool profile? Until then, a real release cannot proceed. After setup, run scripts/release.sh outside the sandbox with no concurrent build in this checkout. Archive/export, timestamping, notarization, stapling, Gatekeeper, and the actual DMG remain untested here by instruction.
- Which neutral name, original art or written trademark permissions, privacy policy URL, and provider-access permissions will the future App Store build use? The draft is not submission-ready.
- The existing install.sh completion text still says the app auto-starts at login and points account setup at the old menu. That file is outside this task's allowed writes. Align those messages with the requested opt-in Settings flow during integration.
- Exercise fleet deployment on a test host outside the sandbox. Confirm /Applications write access, the existing signing trust, working /usr/bin/python3, server shutdown, and launch/health checks. No SSH or deployment was run in this task.
