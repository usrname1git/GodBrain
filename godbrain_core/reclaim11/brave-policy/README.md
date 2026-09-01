# Reclaim11 Brave policy (not a modded browser)

Stock Brave from [brave.com](https://brave.com). Then **their** policy
templates, not a fork:

https://support.brave.app/hc/en-us/articles/360039248271-Group-Policy  
https://brave-browser-downloads.s3.brave.com/latest/policy_templates.zip

Pinned fetch: `SOURCE.txt` (`152.1.96.35`). Their `examples/brave.reg` is
every policy with **sample** values — do not import the whole file.
`lockdown.reg` is the curated subset. Verify in the browser:
`brave://policy`.

## Default (friend-safe)

Rewards, Wallet, VPN, Talk, News, Leo, P3A, metrics, Tor, stats ping:
**off**. Safe Browsing stays on. Download warnings stay on.

Shields (GPO, from the desk profile — not a 40-click Settings tour):

| Setting | Value |
|---|---|
| Trackers & ads | Block (ADMX has no Aggressive vs Standard) |
| HTTPS upgrade | Standard |
| Block scripts | off (JS allowed) |
| Fingerprinting | on (standard V2) |
| Cookies | first-party on, third-party blocked |
| Forget me when I close this site | off |

Icon badge, “store contact for reports”, and element-blocking in private
windows are not in `brave.admx` — leave Brave’s UI default.

```text
pwsh -STA -NoProfile -ExecutionPolicy Bypass -File Apply-BravePolicy.ps1
```

Home has **no gpedit**. Brave still reads
`SOFTWARE\Policies\BraveSoftware\Brave`. This `.reg` *is* the GPO
(parsed from `brave.admx`, not a Settings click-tour). HKCU always;
HKLM if you elevate.

Tick **nothing** extra. Apply. Or double-click `lockdown.reg` (UAC =
machine + user; no UAC = user hive only).

## Power-user download block

The Chromium “this file is dangerous” prompt is often noise. It is also
the only warning before an `.exe`. Default pack does **not** touch it.

In the GUI: tick **Disable download danger blocking** only if you mean
it. The label is:

**WARNING DO NOT DISABLE IF YOU'RE NOT A POWER USER**

That sets GPO `DownloadRestrictions=0` and, if a Brave profile exists,
the labs flag `brave-override-download-danger-level@1` (Brave must be
closed). It does **not** disable Safe Browsing.

CLI:

```text
pwsh -STA -NoProfile -ExecutionPolicy Bypass -File Apply-BravePolicy.ps1 -AllowDangerousDownloads
```

## Not in this pack

Galaxy Brave extension (`6a`). `ShowHomeButton`. Wallet/rewards labs
flags. `Stop-Process` unless the power-user labs write needs a closed
browser.
