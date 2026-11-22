# Claude Usage 3.1 🦀

A native macOS menu bar app and floating desktop widget for Claude and Codex
subscription usage. Orange shows 5-hour usage; purple shows weekly usage.
Each bar shows percent **used** and its reset time. Version 3.1.1 is build 311.

Changelog — **3.1.1:** supports multiple API credit organizations with account-specific Claude promo spend and three QA credit rows.
Changelog — **3.1.0:** adds API credit balances, expiry dates and low-credit warnings for Claude API and OpenAI API.

![Claw'd idle widget pose](docs/pose-idle.png)

Claw'd cycles through reading, coding, music, photography and cooking, sleeps
22:00–07:00, worries at 70%, panics at 90%, and dances when a limit resets.
Drag the widget to move it; click Claw'd's legs to minimize it. Position,
minimized state, account selections and display preferences survive relaunches.
Launch at login is opt-in in Settings.

## Prerequisites

1. **For Developer ID releases or App Store delivery, join the paid Apple
   Developer Program (USD 99 per year) first.** The current team `FP62793T7J`
   is a free Personal Team (`isFreeProvisioningTeam = 1`). Its installed
   `Apple Development: developer@example.com (M6W8MTA32Y)` identity cannot sign a
   Developer ID release or deliver to the App Store. `M6W8MTA32Y` is the member
   ID, not the team ID. Paid membership is not required for local source builds.
2. **macOS 14 or later.** The current app starts bundled `server.py` with
   `/usr/bin/python3`, so that interpreter must work. It is a Command Line Tools
   shim on stock macOS; install the tools if needed. The server uses Python 3.9+
   and the standard library, with no pip packages.
3. **To build:** Xcode 27, its selected developer directory and accepted license,
   plus XcodeGen 2.46 or later. Command Line Tools alone cannot build this project.
   For example, install XcodeGen with `brew install xcodegen`.
4. Sign in to [Claude Code](https://claude.com/claude-code), configure bridge
   accounts, or configure Codex accounts as described below. A signed-out app
   still opens and exposes account setup. Live Codex quotas need the Codex CLI.

## Install and build

Install from source:

```bash
git clone https://github.com/applepiece/claude-usage-widget.git
cd claude-usage-widget
./install.sh
```

The installer builds once, installs `/Applications/Claude Usage.app`, and opens
it. It does not need to copy the Python server into Application Support.
Enable launch at login yourself in **Settings > General**.
Uninstall with `./uninstall.sh`; account files and old Application Support data
are retained.

Build without installing or launching:

```bash
scripts/build-app.sh
scripts/build-app.sh --debug
scripts/build-app.sh --sign adhoc
scripts/build-app.sh --sign none
```

Output: `dist/Claude Usage.app`. The default is Release with `--sign auto`,
which uses the project's signing settings. The current project uses manual
Apple Development signing for team `FP62793T7J`. Use `adhoc` for a local build
without a signing identity, or `none` to disable signing for development checks.
Neither makes a public Developer ID release. Previous app outputs are kept
under `.build/previous-app.*` instead of merging old resources.

Run builds outside the agent sandbox. Do not run concurrent builds or release
commands in this checkout: they share the generated project and `.build/xcode`.

## Menu and Settings

Open the menu from the menu bar status item. The top card shows the primary
account's avatar, label, plan tag and email in a compact header. Each limit has
one line with its name, a reset symbol and short time such as **2h 59m** or
**Sat 16:20**, and its percent, above a thin bar. Orange means Session,
purple means Weekly, and red marks usage at 90% or higher. Stale and failed
states still appear on the card.

With multiple accounts, each gets one native menu row: provider glyph, account
label, and aligned mini meters with numbers in the selected bar order. A caption
labels the columns; the default is Session then Weekly. Claude accounts
come first, then Codex. Missing windows show **–**; failed accounts show
**⚠︎ expired** or **⚠︎ error**. Hover for the full plan, usage and reset details.
The primary has a checkmark and the secondary has a circled 2. Click to make an
account primary; hold **Option** while clicking to set or clear the secondary.
The list is omitted with a single account. The remaining actions are
**Show Widget** (checked when visible), **Refresh (⌘R)**, **Settings… (⌘,)**
and **Quit (⌘Q)**. Refresh has no subtitle and is disabled as **Refreshing…**
while a refresh is running.

Settings has five tabs:

| Tab | Controls |
| --- | --- |
| General | Launch at login, off until enabled by the user; desktop widget options. |
| Menu Bar | Live preview; accounts shown; value; Show percentage; Keep icon in the menu bar. |
| Layout | Add, remove, and reorder usage bars; API credits display and expiry warnings. |
| Accounts | Primary and secondary accounts; editable short names; status and renewal commands; this Mac's Claude Code sign in, switch account and sign out; provider usage page links. |
| About | Version and credits. |

### Usage bars and Layout

In **Settings > Layout**, choose one to three bars, remove them with minus, and
use the arrows to change their order. The account menu columns and desktop
widget update together. Session (orange) and Weekly (purple) are the defaults;
per-model Weekly bars such as Fable use teal, and Extra usage uses green.
Per-model data comes from the account signed in to Claude Code on this Mac.
Other accounts show **–** when the selected metric is unavailable. Widget height
adjusts for the bar count, including when primary and secondary are stacked.
Status-item text options stay in **Menu Bar**; API credits controls are in **Layout**.

The primary account initially uses this Mac's login, otherwise the first
available account. Secondary starts at None and cannot equal primary. Choosing
the current secondary as primary swaps them. The widget can show Primary only
or Primary + Secondary. A second account adds tagged bars. Claw'd's mood follows
primary usage; reset celebrations and offline state are tracked per account.

The menu bar shows a monochrome Claw'd followed by each account's short name
and percent used, including when only one account is shown: **P 85%**.
**Show** can be **Primary account** (default), **Primary and secondary**, or
**All accounts**. **Value** can be **Most used** (default: the higher available
percentage), **Session**, **Weekly**, or **Session and weekly** (such as **P 15·85**).
Missing data shows **–** and failed accounts show **!**.

Titles longer than 28 characters first drop percentage signs, then use each
account's highest window. If still too long, only the first account and **+N**
remain, where N is the number of hidden accounts. **Show percentage** is on by
default; turning it off shows Claw'd alone. Text follows the native menu bar's
light/dark appearance. **Keep icon in the menu bar** is on by default; turn it off to show the status item
only while the widget is minimized.

In **Settings > Accounts**, type a **Short name** or pick one from the arrow
menu: Automatic, the account label, its uppercase form, its first two letters
uppercased, or a Codex label prefixed with **›**. Edits update the menu bar live.
Names allow any characters, with a six-character limit that preserves Thai and
emoji. Empty or whitespace-only names use the automatic tag; matching names
show an orange **Same as kkpk** caption. Automatic tags expand when initials
collide. Short names also appear in account pickers and on the stacked widget's
account tags. They do not rename the accounts.

**Refresh** requests all accounts with guarded `POST /api/refresh?account=<id>`.
Snapshots younger than 60 seconds and failure backoffs prevent repeated probes.
Settings account actions affect only this Mac's Claude Code login. Sign out
asks for confirmation. Sign in starts a visible `claude auth login` in Terminal.
Bridge token files remain unchanged. Old `barMode` preferences migrate once:
Off becomes Claw'd alone; 5-Hour/Weekly/Both becomes the
corresponding value selection.

The **API credits** section below the account rows shows prepaid balances with
aligned remaining-credit meters and amounts. Open a provider submenu for grant,
spend and expiry details and its billing console. **Settings > Layout > API credits**
offers **Each provider**, **Total only**, or **Off**, plus a 3/7/14-day expiry
warning window. The app refreshes credits with usage and checks again when opening a
menu whose credit snapshot is more than ten minutes old; failures keep the last
snapshot, marked overdue after thirty minutes without a successful fetch.
Anchors at least seven days old show their date. No live grants means no meter
or low-credit warning. QA and menu previews include two Claude organizations and
an OpenAI balance, with healthy and warning states.

The server reads `CREDITS_CONFIG` or
`~/Dropbox/Macbook Pro/Happlen/agents/infra/fleet/api-credits/credits.json`.
It subtracts post-anchor spend from `*.jsonl` files in that directory's `ledger/`
and `~/.local/state/api-credits/ledger/`, deduplicating by provider, account and
record ID (or identical lines without IDs). Override the ledger directories with colon-separated
`API_CREDITS_LEDGER_DIRS`. Empty files, malformed records and unpriced usage mark
the balance as an upper bound (`≤`) in its row, tooltip and accessibility label.
Spend consumes grants in expiry order; expired grants contribute neither balance
nor granted totals. OpenAI uses each grant's remaining-at-anchor balance. Claude
has one promo bucket tied to the latest grant expiry, and only `claude_api`
ledger records consume that bucket; other tools bill purchased credit.
Providers appear in config order and may use any ID. Set `type` to `anthropic`
or `openai`; when omitted, the ID is the type for compatibility with older configs.
Claude providers match ledger records by `ledger_account` (default `anthropic`).
Records without `account` belong to `anthropic`; a second org can use ID
`anthropic_pho`, type `anthropic`, and ledger account `anthropic-pho`. Each row
uses the configured label, such as `Claude API · kkpk` or `Claude API · pho`.
The Claude row uses the promotional balance; `GET /api/credits` also returns the
purchased balance as `extra`.

For OpenAI, an optional `OPENAI_ADMIN_KEY_FILE` (default
`~/.secrets/api-credits/openai-admin.key`) enables the organization Costs API,
cached for thirty minutes, with ledger fallback and a five-minute retry delay on
failure. Requests refuse redirects and count USD costs only. The key stays in the
server and is never returned or logged. No config means no credit section.
An unreadable config returns a recoverable error; one invalid provider produces
an unavailable row while the others continue to render.
Error rows omit unknown or invalid types and use a neutral credit glyph when
no type is available.

## Multiple accounts

The local Python server combines two sources:

- **This Mac's Claude Code login**, from the Keychain item
  `Claude Code-credentials`. Its identity comes from the OAuth profile endpoint,
  with `~/.claude.json` as a local fallback. Usage comes from the `/api/oauth/usage`
  endpoint. The server refreshes expired OAuth credentials and
  saves rotated credentials back to the Keychain.
- **Bridge accounts**, from `~/.config/claude-bridge/accounts/<label>.token`
  (one long-lived `claude setup-token` token per file, mode 600), with a matching
  `<label>.json` containing `email`, `org_uuid` and optional `expires_at`/`plan`.
  Labels listed in `CLAUDE_BRIDGE_ACCOUNTS=pho:/path/pho.token,kkpk:/path/kkpk.token,…`
  in `~/.config/claude-bridge/env` appear first, in that order. Remaining labels
  sort alphabetically. Discovery uses the accounts directory; env paths specify
  the preferred order, not additional token sources.

Matching organization UUIDs merge the Keychain login with its bridge account.
The merged account keeps its label and uses the OAuth usage endpoint, falling back
to a bridge probe if it fails. An unmatched login appears as **This Mac**;
a signed-out Keychain adds no account. Token files and sidecars are never edited.

Inference-only bridge tokens cannot use the usage/profile endpoints. Instead,
the server sends a minimal Messages request (`max_tokens: 1`) and reads its
unified rate-limit response headers. **A probe consumes about 22 input tokens
and 1 output token, counts toward subscription usage, and can start a 5-hour
window on an idle account.** The default probe model is
`claude-haiku-4-5-20251001`. Header fractions are converted to percent used.
Team accounts with no weekly headers show **–**, never 0%.

The app polls `/api/accounts` every 60 seconds; probes are cached per account
for 600 seconds. Failures retain the last good snapshot labelled **stale**, with
a five-minute backoff. Rejected tokens show **token rejected** and a renewal
hint (`scripts/add-account.sh <label>`, in the bridge tooling). A 429 containing
usage headers still supplies valid data, labelled `rejected` on its windows.
Missing data stays missing; it never becomes a zero.

Server configuration (stdlib Python 3.9+, no packages):

| Variable | Default |
| --- | --- |
| `CLAUDE_USAGE_ACCOUNTS_DIR` | `~/.config/claude-bridge/accounts` |
| `CLAUDE_USAGE_BRIDGE_ENV` | `~/.config/claude-bridge/env` |
| `CLAUDE_USAGE_PROBE_MODEL` | `claude-haiku-4-5-20251001` |
| `CLAUDE_USAGE_PROBE_SECONDS` | `600` (minimum `120` for automatic polling) |

### Codex accounts

Codex logins appear after Claude accounts, in the order of
`CODEX_BRIDGE_ACCOUNTS=pro:~/.codex,edu:~/.codex-edu` in
`~/.config/codex-bridge/env`. Exported or quoted values are supported; duplicate
labels keep the first entry. If the file or variable is missing, an existing
`~/.codex` directory appears as **codex**. The server never reads `auth.json`.

Live quotas come from `codex app-server`, using `account/read` for identity and
`account/rateLimits/read` for usage. This costs no credits, takes about 2 seconds,
and runs at most every 5 minutes per login by default. Refresh can request a
new read after 60 seconds. The CLI runs with that login's `CODEX_HOME`, an
extended PATH for Node, and without API key environment overrides. Weekly-only
plans leave the 5-hour window unavailable.

On each poll the server checks the newest `sessions/**/rollout-*.jsonl` by mtime
and caches its last 256 KB of quota data. A newer rollout snapshot overlays live
numbers; if the live read fails, rollout data supplies a **stale** fallback.
Freshness uses the rollout event's timestamp. Expired rollout windows show 0%
with no reset time. A signed-out login clears usage and shows **token rejected**.

Codex tags start with **›**, such as **›P** and **›E**. Claude tags are computed
separately, so **pho** stays **P** beside Codex **pro**. Settings shows provider-specific usage links
and the renewal hint `bridge-accounts/login-all.sh codex`.

| Variable | Default |
| --- | --- |
| `CLAUDE_USAGE_CODEX_ENV` | `~/.config/codex-bridge/env` (override is a literal path) |
| `CLAUDE_USAGE_CODEX_BIN` | First executable in `~/.local/bin/codex`, `/opt/homebrew/bin/codex`, `/usr/local/bin/codex`, then extended PATH |
| `CLAUDE_USAGE_CODEX_SECONDS` | `300` (minimum `60`; invalid values use `300`) |

## Local API, privacy and credentials

The app starts `/usr/bin/python3` with
`Claude Usage.app/Contents/Resources/server.py`. The bundle also contains
`widget.html`. `~/Library/Application Support/claude-usage-widget` is no longer
the server source; old files there are kept for manual review.

The server binds only to **127.0.0.1:8737**, checks Host on GETs, and requires
**X-Widget: 1** and an absent Origin for POSTs. The app checks `/api/ping` for
the server version. A mismatched older server can be asked to quit through the
guarded `/api/quit`; the app waits for shutdown before starting its bundled
server. An unresponsive or rejecting listener is left in place.

Claude credentials are read inside the server and sent only to Anthropic for
provider authentication and requests. They are never logged or returned to the
UI. Keychain OAuth refresh can rotate and save this Mac's credentials. Bridge
tokens stay in their protected files and are never edited. Codex login handling
is delegated to its CLI; the server does not read `auth.json`. The registry API
returns selected identity fields and parsed usage, without credentials,
fingerprints, organization headers or arbitrary upstream headers.

The app has no developer analytics or telemetry. Provider requests still leave
the Mac, and probes consume subscription usage. Local identity data includes
account labels and email addresses. Protect token files and keep credentials
out of screenshots, logs, bug reports and source control.

`/api/accounts` returns all accounts and states. Legacy `/api/usage`,
`/api/account`, `/api/login`, `/api/logout`, `/api/ping` and HTML routes remain
available. The 3.0 native app uses the account registry API.

## Developer ID release

After completing the membership prerequisite, create and install a **Developer
ID Application** certificate with its private key for team `FP62793T7J`.
Use [developer.apple.com > Certificates](https://developer.apple.com/account/resources/certificates/list)
or **Xcode > Settings > Accounts**. An Apple Development identity is insufficient.
Confirm that `security find-identity -v -p codesigning` lists the Developer ID
identity with `(FP62793T7J)`.

Set up a notarytool keychain profile once. Replace `<email>` with your Apple ID:

```bash
xcrun notarytool store-credentials claude-usage-notary --apple-id <email> --team-id FP62793T7J
```

Enter an app-specific password at the interactive prompt. Never put a password
on the command line or in the repository. The default profile is
`claude-usage-notary`. Override it with `NOTARY_PROFILE` or `--notary-profile`.
The command-line option takes precedence.

Release with one command:

```bash
scripts/release.sh
```

The script first checks the Developer ID identity, then the notary profile.
A missing identity exits **2** with the three setup steps. An unusable notary
profile exits **3** with the one-time credentials command. These checks run
before project generation, archive, export, or output-directory creation.

The pipeline generates the Xcode project, archives Release with Developer ID,
exports and verifies the app's signature and hardened runtime, notarizes a ZIP
of the app, and staples the app. It creates a compressed DMG containing the
app and an Applications link, signs and notarizes the DMG, staples it, checks
Gatekeeper for both products, and writes a SHA-256 checksum. Version numbers
come from the exported app's Info.plist.

Outputs for version 3.0:

- `dist/Claude-Usage-3.0.dmg`
- `dist/Claude-Usage-3.0.dmg.sha256`
- `.build/release/export/Claude Usage.app`
- Archive, logs, notarization responses, retained staging and previous artifacts
  under `.build/release/`.

Verify a downloaded checksum from the directory containing both files:

```bash
shasum -a 256 -c Claude-Usage-3.0.dmg.sha256
```

For local packaging tests:

```bash
scripts/make-dmg.sh 'dist/Claude Usage.app' 'dist/Claude-Usage-local.dmg'
scripts/release.sh --skip-notarize
```

`make-dmg.sh` only packages an existing app and refuses an existing output
filename. It does not sign or notarize anything. `--skip-notarize` still requires
Developer ID, archives and signs both products, and skips notarization,
stapling and Gatekeeper assessment. Its DMG is for local testing only.
A normal release requires network access to Apple. Logs are in `.build/release`;
if notarization is rejected, inspect the response ID and retrieve its log with
`xcrun notarytool log <id> --keychain-profile claude-usage-notary`.

## App Store status

The current app cannot ship in the Mac App Store. Its shared Keychain access,
external Python and CLI processes, and direct home-directory reads need a
sandbox-ready replacement. Branding and service permissions, a privacy policy,
and paid distribution accounts also need work. The launch-at-login consent
change is done in 3.0. See [App Store readiness](docs/APP_STORE.md) for blockers,
the Swift architecture, prepared export/entitlement files, metadata draft, and
future archive/upload steps.

## Project layout

```text
project.yml                         XcodeGen source for ClaudeUsage and its scheme
ClaudeUsage.xcodeproj/               Generated Xcode project
Config/Shared.xcconfig               Version 3.1.1, build 311, macOS 14 target
Config/Info.plist                    Bundle metadata
Config/ClaudeUsage.entitlements      Developer ID app entitlements
Config/ClaudeUsage-AppStore.entitlements  Future sandbox entitlements
Config/ExportOptions-*.plist         Developer ID and App Store export settings
Sources/ClaudeUsage/                 AppKit app, menu, Settings, services and widget
Packages/UsageKit/                   Local Swift 6 package, models and renderers
Resources/                          Assets, Fonts and PrivacyInfo.xcprivacy
server.py                           Bundled Python account/usage service
scripts/build-app.sh                Build to dist without installing
scripts/release.sh                  Archive, export, notarize, staple and package
scripts/make-dmg.sh                 Package an existing app only
tests/                              Python tests and preview checks
docs/                               Widget poses and App Store readiness
install.sh / uninstall.sh           Local source install and uninstall
```

The bundle ID is `com.heng.claude-usage-widget`; the executable is `ClaudeUsage`.
Fleet deployment lives in `agents/infra/fleet/deploy-usage-widget.sh`. It builds
once on the sending Mac with `scripts/build-app.sh --sign auto`, transfers the
app, and checks the installed build plus the running server version. Target
Macs need no Xcode compilation or license acceptance for deployment. They still
need a working `/usr/bin/python3` for the current app. `--status` only reads the
pending file and recent log. The existing `--pending` success-notification path
is retained.

## Development and offscreen previews

```bash
scripts/build-app.sh --debug --sign none
swift test --package-path Packages/UsageKit
export PYTHONPYCACHEPREFIX="$PWD/.build/pycache"
/usr/bin/python3 -m unittest discover -s tests -v
python3 -m unittest discover -s tests -v
/usr/bin/python3 -m py_compile server.py
```

Run preview commands **outside the sandbox** on a Mac with WindowServer access.
They render offscreen without showing windows, registering login items or
contacting the server. Build the app first. Output stays under ignored `.build`:

```bash
'dist/Claude Usage.app/Contents/MacOS/ClaudeUsage' --preview-menu .build/menu.png
'dist/Claude Usage.app/Contents/MacOS/ClaudeUsage' --preview-menu .build/menu-dark.png --dark
'dist/Claude Usage.app/Contents/MacOS/ClaudeUsage' --preview-menu .build/menu-signed-out.png --signed-out
'dist/Claude Usage.app/Contents/MacOS/ClaudeUsage' --preview-statusbar .build/statusbar.png
'dist/Claude Usage.app/Contents/MacOS/ClaudeUsage' --preview-statusbar .build/statusbar-dark.png --dark
'dist/Claude Usage.app/Contents/MacOS/ClaudeUsage' --preview-widget .build/widget.png
'dist/Claude Usage.app/Contents/MacOS/ClaudeUsage' --preview-widget .build/widget-two-dark.png --dark --two
```

Menu samples: pho 15%/82% (machine login), kkpk 0%/37%, mahidol 4%/no weekly,
Codex pro no 5-hour/12% weekly, and Codex edu 1%/0%. Menu and two-account widget
previews select pho and codex-pro. The status grid covers every Show × Value
combination, rejected Claude and Codex accounts, a six-character Thai short
name, and Claw'd alone.
All three preview modes support `--dark`; the widget supports `--two` and the
menu supports `--signed-out`. Visual QA is separate from compilation. Run
`bash tests/preview_checks.sh` outside the sandbox and inspect `.build/previews/`
for clipping, contrast and missing-window states. The widget pose image above
is retained because those poses are unchanged; no old menu screenshot is used.

## สำหรับผู้ใช้ภาษาไทย

เวอร์ชัน 3.0 แสดงการใช้ Claude และ Codex หลายบัญชี ทั้ง login ของ Claude Code ใน Keychain
และ token จาก `~/.config/claude-bridge/accounts/<label>.token` พร้อมไฟล์ `.json`
ที่ระบุ email และ `org_uuid` เรียงตาม `CLAUDE_BRIDGE_ACCOUNTS` ในไฟล์ bridge `env`
ก่อน แล้วตามตัวอักษร หาก org ตรงกันจะรวมเป็นบัญชีเดียว; login ที่ไม่ตรงแสดงเป็น
This Mac และเมื่อ sign out จะไม่เพิ่มบัญชีจาก Keychain

บัญชี bridge อ่านโควต้าจาก response headers ของ Messages probe เพราะ token
แบบ inference ใช้ usage endpoint ไม่ได้ **แต่ละ probe ใช้ประมาณ 22 input tokens
และ 1 output token นับเป็นการใช้งานจริง และอาจเริ่มรอบ 5 ชั่วโมงของบัญชีที่ว่างอยู่**
เก็บ cache 10 นาทีต่อบัญชี (ตั้ง `CLAUDE_USAGE_PROBE_SECONDS` ได้ ขั้นต่ำ 120 วินาที
สำหรับการตรวจอัตโนมัติ) แอปอ่านข้อมูลทุก 60 วินาที บัญชีที่รวมกับ Keychain ใช้
usage endpoint ก่อนและ probe เมื่อจำเป็น ไม่มีรายสัปดาห์แสดง **–** ไม่ใช่ 0%
เมื่อดึงข้อมูลล้มเหลวแสดง stale และพัก 5 นาที; token ถูกปฏิเสธแสดง token rejected
พร้อมคำแนะนำ `scripts/add-account.sh <label>` ใน Settings > Accounts

เมนู 3.0 แสดงการ์ดบัญชีหลักพร้อม avatar ชื่อ แผน email และแต่ละ limit
มีชื่อ เวลารีเซ็ตแบบสั้น เช่น 2h 59m หรือ Sat 16:20 และเปอร์เซ็นต์ในบรรทัดเดียว
พร้อมแถบบางด้านล่าง สีส้มคือ Session สีม่วงคือ Weekly และสีแดงเมื่อใช้ตั้งแต่ 90%
รายชื่อบัญชีใช้บัญชีละหนึ่งบรรทัด มีสัญลักษณ์ provider ชื่อ และแถบเล็กพร้อมตัวเลขสองคอลัมน์
เรียง Claude ก่อน Codex ไม่มีหัวข้อหรือบรรทัดรอง ชี้เมาส์เพื่อดูรายละเอียดและเวลารีเซ็ต
บัญชีหลักมีเครื่องหมายเลือก บัญชีรองมีเลข 2 ในวงกลม คลิกเพื่อตั้งบัญชีหลัก
กด Option ค้างแล้วคลิกเพื่อตั้งหรือยกเลิกบัญชีรอง หากมีบัญชีเดียวจะไม่แสดงรายชื่อ
ตามด้วย **Show Widget**, **Refresh (⌘R)** แบบไม่มีข้อความรอง,
**Settings… (⌘,)** และ **Quit (⌘Q)** สถานะ stale และข้อผิดพลาดยังแสดงบนการ์ด

Settings แบ่งเป็น 5 แท็บ:

- **General**: เปิดตอน login macOS เมื่อผู้ใช้เลือกเองเท่านั้น ค่าเริ่มต้นปิด
  พร้อมตัวเลือก desktop widget และแสดงบัญชีหลักหรือบัญชีหลักพร้อมบัญชีรอง
- **Menu Bar**: preview สด แสดง Claw'd สีเดียวพร้อมชื่อย่อและเปอร์เซ็นต์
  เลือก Show เป็น Primary account / Primary and secondary / All accounts
  และ Value เป็น Most used (ค่าเริ่มต้น เลือกค่าสูงสุด) / Session / Weekly /
  Session and weekly มี Show percentage และ Keep icon in the menu bar
- **Layout**: เลือกและเรียงแถบ usage 1–3 แถบสำหรับเมนูและ widget พร้อมตั้งค่า API credits
- **Accounts**: เลือกบัญชีหลักและรอง ดูสถานะ คำสั่งต่ออายุ และลิงก์ usage
  ตั้ง Short name ได้โดยพิมพ์หรือเลือกจากเมนูลูกศร จำกัด 6 ตัวอักษร รองรับไทยและ emoji
  เว้นว่างเพื่อใช้ชื่อย่ออัตโนมัติ ชื่อซ้ำมีข้อความสีส้ม Same as ตามด้วยชื่อบัญชี
  ชื่อย่อเปลี่ยนบน menu bar ทันที รวมถึงรายการเลือกบัญชีและป้าย widget แบบสองบัญชี
  พร้อม sign in / switch / sign out ของ Claude Code บน Mac นี้
  sign out ยืนยันก่อนและไม่แก้ token ของบัญชี bridge
- **About**: ข้อมูลเวอร์ชันและเครดิต

ชื่อย่อแสดงเสมอแม้มีบัญชีเดียว เช่น **P 85%** ตัวเลขคือเปอร์เซ็นต์ที่ใช้ไป
Session and weekly แสดงเช่น **P 15·85** ข้อมูลหายเป็น **–** ข้อผิดพลาดเป็น **!**
Show percentage เปิดเป็นค่าเริ่มต้น ปิดแล้วเหลือ Claw'd อย่างเดียว
เมื่อข้อความยาวเกิน 28 ตัวอักษร จะตัดเครื่องหมาย % ก่อน แล้วใช้รอบที่ใช้มากสุด
หากยังยาวเกิน จะแสดงเฉพาะบัญชีแรกพร้อม **+N** บอกจำนวนบัญชีที่ซ่อน
สีของไอคอนและข้อความปรับตาม menu bar สว่างหรือมืดของระบบ

Keep Icon in Menu Bar เปิดเป็นค่าเริ่มต้น ปิดเพื่อแสดงเฉพาะเมื่อย่อ widget
บัญชีรองทำให้ widget ขยายพร้อมป้ายชื่อย่อ แถบส้มคือ 5 ชั่วโมง แถบม่วงคือรายสัปดาห์
น้อง Claw'd เปลี่ยนท่าตามบัญชีหลัก และติดตาม offline/การรีเซ็ตแยกตามบัญชี
ลากเพื่อย้ายตำแหน่ง คลิกขาน้องเพื่อย่อ จำการตั้งค่าข้ามการเปิดแอป
กด Refresh เพื่อขอข้อมูลทุกบัญชี โดยไม่ probe ซ้ำภายใน 60 วินาที
หรือระหว่างพักหลังข้อผิดพลาด

ต้องมี macOS 14 ขึ้นไป การ build ใช้ Xcode 27 และ XcodeGen
ติดตั้งจาก source ด้วย `./install.sh` หรือ build อย่างเดียวด้วย `scripts/build-app.sh`
แอปมี server.py อยู่ใน bundle และต้องใช้ `/usr/bin/python3` ที่ทำงานได้
การออก DMG ด้วย `scripts/release.sh` ต้องสมัคร Apple Developer Program แบบเสียเงิน
(USD 99 ต่อปี) มี Developer ID Application certificate และตั้ง notarytool ก่อน
Personal Team ฟรียังออก release ไม่ได้ ดูขั้นตอนด้านบนและ [สถานะ App Store](docs/APP_STORE.md)

ตรวจภาพด้วย `--preview-menu <png> [--dark] [--signed-out]`,
`--preview-statusbar <png> [--dark]`, `--preview-widget <png> [--dark] [--two]`
ตามตัวอย่างด้านบน ต้องรันนอก sandbox บน Mac ที่เข้าถึง WindowServer ได้
โหมด preview ไม่แสดงหน้าต่าง ไม่ลงทะเบียน login item และไม่ติดต่อ server

### บัญชี Codex

อ่านรายการจาก `CODEX_BRIDGE_ACCOUNTS=pro:~/.codex,edu:~/.codex-edu` ใน
`~/.config/codex-bridge/env` แล้วแสดงหลังบัญชี Claude ตามลำดับในไฟล์ รองรับ
`export` และเครื่องหมายคำพูด หากไม่มีไฟล์หรือตัวแปร จะใช้ `~/.codex` เมื่อมี
โฟลเดอร์นี้เท่านั้น เซิร์ฟเวอร์ไม่อ่าน `auth.json` และไม่แก้ไฟล์ login

ข้อมูลสดมาจาก `codex app-server` โดยอ่านตัวตนด้วย `account/read` และโควต้าด้วย
`account/rateLimits/read` ไม่เสียเครดิต ใช้เวลาประมาณ 2 วินาที และอ่านอัตโนมัติ
ไม่ถี่กว่า 5 นาทีต่อ login ตามค่าเริ่มต้น กด Refresh ได้หลังอ่านครั้งก่อน
อย่างน้อย 60 วินาที หากแผนมีเฉพาะรายสัปดาห์ ช่อง 5 ชั่วโมงจะแสดงว่าไม่มีข้อมูล

ทุกครั้งที่ poll จะตรวจ rollout ล่าสุดใน `sessions/**/rollout-*.jsonl` ตาม mtime
และ cache ผลที่อ่านจากท้ายไฟล์ 256 KB หาก timestamp ใหม่กว่าข้อมูลสดจะใช้แทน
หากอ่านสดล้มเหลวจะใช้ rollout พร้อมสถานะ stale ความสดอ้างอิงเวลาของ event
รอบที่หมดอายุแล้วจะแสดง 0% และไม่มีเวลารีเซ็ต เมื่อ sign out จะล้างโควต้า

ป้าย Codex มี **›** นำหน้า เช่น **›P**, **›E** และคำนวณแยกจาก Claude
จึงยังใช้ **P** สำหรับ pho แม้มี pro Settings แยกลิงก์ usage ตาม provider
คำแนะนำต่ออายุคือ `bridge-accounts/login-all.sh codex`

ตั้งไฟล์รายการด้วย `CLAUDE_USAGE_CODEX_ENV` (ใช้ path ตามที่กำหนด ไม่ขยาย `~`
ในตัวแปรนี้), ตั้ง CLI ด้วย `CLAUDE_USAGE_CODEX_BIN` และตั้งช่วงอ่านสดด้วย
`CLAUDE_USAGE_CODEX_SECONDS` ค่าเริ่มต้น 300 วินาที ขั้นต่ำ 60 วินาที
ค่าที่ไม่ถูกต้องใช้ 300 วินาที โดยไม่ต้องเปิดหรืออ่าน `auth.json`

## Credits and license

- Code: [MIT](LICENSE).
- Font: [Press Start 2P](https://fonts.google.com/specimen/Press+Start+2P) by
  CodeMan38, [SIL OFL 1.1](Resources/Fonts/OFL.txt).
- Claw'd is Anthropic's Claude Code mascot. This is an unofficial fan-made tool,
  not affiliated with or endorsed by Anthropic or OpenAI. Claude and Codex are
  their respective owners' trademarks. The current name and artwork need
  permission for App Store submission; see [readiness](docs/APP_STORE.md).
