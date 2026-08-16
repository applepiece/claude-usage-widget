# Claude Usage Widget 🦀

A tiny **Codex-pets-style floating desktop widget** for macOS that shows your real
Claude subscription usage — the 5-hour session limit and the weekly limit — with
**Claw'd**, Claude Code's crab mascot, as an animated pixel-art companion
(blocky look faithful to the official figure, 90's Pokemon UI).

![Claw'd idle](docs/pose-idle.png)

## What it does

- **Always-on-top native widget** (Swift/Cocoa `NSPanel`) — floats over every app
  and Space, no Dock icon, never steals focus. Drag to move; position is remembered.
- **Real account data** — the same endpoint Claude Code's `/usage` uses, refreshed
  every 60 s. Each bar shows the reset day/time and the percent used:
  orange = 5-hour session, purple = weekly.
- **Claw'd reacts to your usage**
  - cycles hobbies while things are calm:
  - **reading** <br/> ![read](docs/pose-read.png)
  - **coding** <br/> ![computer](docs/pose-computer.png)
  - **listen to music** <br/> ![music](docs/pose-music.png)
  - **photography** <br/> ![camera](docs/pose-camera.png)
  - **cooking** <br/> ![cook](docs/pose-cook.png)
  - **sleeps at night** (22:00–07:00) <br/> ![sleep](docs/pose-sleep.png)
  - **dances when a limit resets** <br/> ![dance](docs/pose-dance.png)
  - gets worried at ≥70 % and panics (>< eyes, sweat, trembling) at ≥90 % <br/> ![panic](docs/pose-panic.png)
- **Collapse into the menu bar** — click Claw'd's **legs** to tuck the whole
  widget away into a tiny white Claw'd glyph in the macOS menu bar. Left-click the
  glyph to bring the widget back; right-click (or ⌃-click) for options. Choose what
  the glyph shows next to it under **Menu Bar %**: `Off`, `5-Hour only`,
  `Weekly only`, or `Both`. The collapsed/expanded state is remembered across
  launches.
- Auto-starts at login (registered via `SMAppService`; visible in
  System Settings › Login Items).

## Account and usage menu

Right-click the floating Claw'd, or right-click its menu-bar glyph when tucked
away, to see the same account-aware menu. The header shows the signed-in name,
email, and plan. Each available plan limit has its own percentage, reset time,
and colour-coded usage bar. The menu also links to usage settings and can start
a visible Claude Code sign-in, switch accounts, or sign out after confirmation.
When no account is signed in, Claw'd shows `SIGN IN` and the menu offers the
sign-in action first.

## Install

Requirements: **macOS 13+**, **Xcode Command Line Tools** (`xcode-select --install`),
and a machine where you are **logged in to [Claude Code](https://claude.com/claude-code)**
with a Claude subscription.

```bash
git clone https://github.com/applepiece/claude-usage-widget.git
cd claude-usage-widget
./install.sh
```

Uninstall with `./uninstall.sh`.

## How it works / security

```
widget app (Swift)  ──HTTP──▶  server.py (127.0.0.1:8737)
                                 │  reads OAuth token from the macOS Keychain
                                 │  (the same "Claude Code-credentials" entry
                                 │   Claude Code itself uses)
                                 ▼
                     api.anthropic.com/api/oauth/usage
```

- The local server binds to **127.0.0.1 only**. Tokens never leave your machine,
  are never written to disk in plain text, and are never sent to the widget UI.
- When the access token expires the server refreshes it against
  `platform.claude.com/v1/oauth/token` and **writes the rotated token back to the
  Keychain**, exactly like Claude Code does, so your CLI login keeps working.
- If a fetch fails transiently the widget keeps showing the last known values
  (it only says OFFLINE after ~3 minutes of consecutive failures).
- `READY` in a bar means that window just reset and has no active session yet.

## Development

```bash
# rebuild after editing the Swift sources
swiftc -O -o "/Applications/Claude Usage.app/Contents/MacOS/ClaudeUsage" \
    app/WidgetView.swift app/main.swift
codesign --force -s - "/Applications/Claude Usage.app"

# the legacy HTML versions (Apple-Watch rings / Ghibli meadow) still live at
# http://127.0.0.1:8737 while server.py is running
```

## สำหรับผู้ใช้ภาษาไทย

Widget ลอยบนจอแสดง limit การใช้งาน Claude ของบัญชีคุณแบบเรียลไทม์ — แถบส้ม =
รอบ 5 ชั่วโมง, แถบม่วง = รายสัปดาห์ พร้อมน้อง Claw'd ที่เปลี่ยนท่าทางตามสถานการณ์:
ทำกิจกรรมเพลินๆ ตอนโควต้าเหลือเยอะ, หน้ากังวลเมื่อใช้เกิน 70%, ตกใจเหงื่อแตกเมื่อเกิน
90%, นอนหลับตอนกลางคืน และเต้นฉลองตอนโควต้ารีเซ็ต ติดตั้งด้วย `./install.sh`
(ต้องมี Xcode Command Line Tools และ login Claude Code ไว้แล้ว)

**ย่อเก็บขึ้น menu bar:** คลิกที่ **ขา** ของน้อง Claw'd เพื่อย่อ widget ทั้งตัวไปเป็น
ไอคอน Claw'd สีขาวเล็กๆ บน menu bar ด้านบน — คลิกซ้ายที่ไอคอนเพื่อเรียก widget กลับมา,
คลิกขวา (หรือ ⌃-คลิก) เพื่อเปิดเมนูตัวเลือก เลือกได้ว่าจะให้โชว์เปอร์เซ็นต์ข้างไอคอนแบบไหน
ที่ **Menu Bar %**: ปิด (Off) / เฉพาะรอบ 5 ชั่วโมง (5-Hour only) / เฉพาะรายสัปดาห์
(Weekly only) / ทั้งคู่ (Both) โดยจะจำสถานะย่อ/ขยายไว้ข้ามการเปิดโปรแกรมครั้งถัดไป

## Credits & license

- Code: [MIT](LICENSE)
- Font: [Press Start 2P](https://fonts.google.com/specimen/Press+Start+2P)
  by CodeMan38, [SIL OFL 1.1](app/fonts/OFL.txt)
- **Claw'd** is Anthropic's Claude Code mascot. This is an unofficial fan-made
  tool, not affiliated with or endorsed by Anthropic.
