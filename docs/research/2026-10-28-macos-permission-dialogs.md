# MIMOLETTE: the "op wants to do a thing again" dialog

Investigated 2026-10-28 09:38–10:00 PDT on MIMOLETTE (macOS 27.2, build 26B123, Homebrew 7.0.11).
Tags: **[V]** = verified on this machine, **[C]** = cited source, **[I]** = inferred, not proven.

> **Status, 2026-10-28 afternoon.** These are the research notes as written. Since then:
>
> - Fix #1 below (post-upgrade approval for binary casks) shipped as dotfiles#470, using option (a): remove quarantine
>   from files that pass `codesign --verify --strict` with a Developer ID Application authority.
> - Homebrew developer mode, turned on by accident during this research (`brew cat --cask`), is off again.
> - Open question 4 (an upstream Homebrew change) is dev-env#237. A different recurring dialog, for `node`, is
>   dev-env#235; `node` is a formula with no quarantine, so §2b/§2c apply to it, not §2a.

---

## 1. Dialog class: Gatekeeper first-launch (quarantine) prompt. Confidence: high. [V]

This was **not** a TCC prompt and **not** a Keychain ACL prompt. It was Gatekeeper's "code-evaluation" prompt for a
quarantined, notarized Developer-ID binary that had not yet been user-approved. The dialog text was probably close to
*"'op' is an app downloaded from the Internet. Are you sure you want to open it?"* [I: inferred from the prompt
class. The exact text was not captured.]

### Log evidence (unified log, 2026-10-28 PDT; searched 08:45–09:45)

First `op` exec from the SSH wrapper. syspolicyd scans it, finds team 2BUA8C4S2C (AgileBits), and shows a prompt on the console user's desktop:

```
09:03:46.648 syspolicyd [com.apple.syspolicy.exec] GK evaluateScanResult: 0, PST: (path: b38d0ad315db823f), (team: 2BUA8C4S2C), ... 1, 0, 1, 0, 4, 4, 1
09:03:46.648 syspolicyd [com.apple.syspolicy] Found console users: <private>
09:03:46.649 syspolicyd [com.apple.syspolicy.exec] Prompt shown (5, 0), waiting for response: PST: (path: b38d0ad315db823f), (team: 2BUA8C4S2C)
09:03:46.654 CoreServicesUIAgent  present code-evaluation prompt
```

While the prompt waited, the kernel refused every further exec of `op`. There were 32 refusals in five bursts (09:03:48–09:04:42 x12, 09:16:03 x1, 09:19:04–09:19:59 x12, 09:21:36 x1, 09:22:06–09:22:32 x6):

```
09:03:48.628 kernel (AppleSystemPolicy) ASP: Security policy would not allow process: 92590, /opt/homebrew/Caskroom/1password-cli/2.41.1/op
... (five bursts; within a burst, spacing of about 2, 4, 8 s) ...
09:22:32.605 kernel (AppleSystemPolicy) ASP: Security policy would not allow process: 93728, /opt/homebrew/Caskroom/1password-cli/2.41.1/op
```

Andrew clicked Open. syspolicyd recorded the approval and asked TCC whether the requester was a Developer Tool:

```
09:26:14.402 syspolicyd Marked application as user approved: 1, PST: (path: b38d0ad315db823f), (team: 2BUA8C4S2C)
09:26:14.403 syspolicyd [com.apple.TCC:access] SEND: ... function=TCCAccessRequest, service=kTCCServiceDeveloperTool, target_token={pid:92590, ...}
09:26:14.404 syspolicyd Wrote provenance data on target: TA(6ddc9bd9432c3d39, 2), ... (id: com.1password.op), (bundle_id: NOT_A_BUNDLE)
```

About 100 ms after the approval, sandboxd asked TCC about new `op` processes (pids 5432, 5436). Every check resolved to Allowed, and none needed a prompt:

```
09:26:14.500 tccd AttributionChain: responsible={identifier=com.apple.sshd-keygen-wrapper, pid=88269, responsible_path=/usr/libexec/sshd-keygen-wrapper, binary_path=/usr/libexec/sshd-session},
             accessing={identifier=com.1password.op, pid=5432, binary_path=/opt/homebrew/Caskroom/1password-cli/2.41.1/op}, requesting={com.apple.sandboxd}
09:26:14.519 tccd Handling access request to kTCCServiceSystemPolicyAllFiles, from Sub:{/usr/libexec/sshd-keygen-wrapper} ... ReqResult(Auth Right: Allowed (System Set), ...)
```

### What rules out the other classes [V]

- **Keychain ACL or partition list:** `SecurityAgent` logged nothing from 08:45 to 09:45. No securityd ACL or partition events appear. The keychain dialog is drawn by SecurityAgent, so this class is ruled out.
- **TCC:** no TCC request in the window needed a prompt. The only TCC services that `op` touched resolved to "Allowed (System Set)" through sshd-keygen-wrapper. That is the "Allow full disk access for remote users" grant under Remote Login [I: that this toggle is the source of the System Set grant].
- **Background Items / Login Items:** no related events were logged.
- **File state agrees with the log.** `op` now carries `com.apple.quarantine: 01c1;...;Homebrew Cask;...`. Not-yet-approved cask apps on this machine carry `0181` (Stats.app, Hidden Bar.app, Android Studio.app). The only difference is bit `0x0040`. Homebrew's source calls that bit `USER_APPROVED_FLAG` and cites Apple's QuarantineSPI.h for it.
- `spctl --assess -vvv --type execute op` returns `rejected (the code is valid but does not seem to be an app)` with `origin=Developer ID Application: AgileBits Inc. (2BUA8C4S2C)`. This output is normal for a bare CLI under `--type execute`. It does not explain the prompt.

### Correction to "op read hung"

`op` did not hang inside its own code. The first exec raised the prompt. Every later exec was refused within about 2 s while the prompt stayed open, and the refusals came in five bursts over 19 minutes. That pattern fits several wrapper invocations, each retrying with backoff until it timed out. [V: 32 ASP denials in five bursts. I: that each burst is one wrapper run with backoff. I did not read the wrapper.]

### What op does with a service-account token

With `OP_SERVICE_ACCOUNT_TOKEN`, `op` talks to 1Password.com directly and does not use the desktop-app integration [I. The 1Password page https://www.1password.dev/service-accounts/use-with-1password-cli/ does not mention the desktop app, the Keychain, or biometrics. Its only precedence rule is that OP_CONNECT_HOST/OP_CONNECT_TOKEN override OP_SERVICE_ACCOUNT_TOKEN [C]]. In the incident window, `op` caused no Keychain or SecurityAgent activity [V]. Its only TCC lookups were sandbox/FDA checks, attributed to the SSH responsible process [V].

---

## 2. Mechanism: why macOS "forgets" after an update

### 2a. Gatekeeper / quarantine (the class that fired today)

- Running a quarantined executable always invokes Gatekeeper. If the check passes, Gatekeeper asks the user to confirm. [C: Apple DTS, https://developer.apple.com/forums/thread/706442. Apple Platform Security, https://support.apple.com/guide/security/gatekeeper-and-runtime-protection-sec5599b66df/web]
- The approval is recorded **on the file**: the `0x0040` flag in its `com.apple.quarantine` xattr, plus a `com.apple.provenance` xattr. It is not recorded by Team ID or by designated requirement (DR). [V: xattrs and the syspolicyd log above. I: that nothing else is keyed on the DR.]
- A new version is a new file in a new directory (`/opt/homebrew/Caskroom/1password-cli/<new-version>/op`). Homebrew quarantines the download, so the new file is quarantined but not approved, and the next exec prompts again. The `op` DR stays the same across versions (`identifier "com.1password.op" and anchor apple generic and ... leaf[subject.OU] = "2BUA8C4S2C"`) [V], but Gatekeeper's first-launch approval does not use it.
- **This is the gap behind "every update".** Homebrew 7.0.11 `cask/upgrade.rb` carries the approval forward on upgrade. It takes a snapshot of `user_approved?` and the signing identity, then calls `Quarantine.inherit_user_approval!`, which ORs in `0x40` when the signer is unchanged. It does this **only** for `old_cask.artifacts.grep(Artifact::App)`. The `1password-cli` cask installs a `binary` artifact (`INSTALL_RECEIPT.json`: `"binary": ["op"]`), and `class Binary < Symlinked`, not `App`. So `.app` casks keep their approval across `brew upgrade`, and binary-only casks such as `op` prompt again after every upgrade. [V: source files under `/opt/homebrew/Library/Homebrew/cask/`.] Homebrew could fix this upstream.
- `--no-quarantine` no longer exists. Homebrew 7.0.11 has no `no-quarantine` or `no_quarantine` string anywhere [V, by grep]. It was deprecated around Homebrew 5.0 [C: https://workbrew.com/blog/what-homebrew-5-0-0-means-for-your-mac-fleet, secondary source]. Homebrew's policy is to quarantine casks deliberately so that Gatekeeper runs [C: `/opt/homebrew/docs/Homebrew-Security-and-Supply-Chain.md`].
- **Developer Tools exemption.** When an exec is quarantined, syspolicyd asks TCC for `kTCCServiceDeveloperTool` on the target [V: log above]. Similar checks from the Claude session returned `Auth Right: Unknown (None)`, meaning no grant [V]. A process whose responsible process holds Developer Tools skips this check [I: from community reports, https://notes.billmill.org/computer_usage/mac_os/Avoiding_gatekeeper_in_your_terminal.html and https://lists.tetaneutral.net/pipermail/cfarm-users/2021-March/000718.html. Apple does not document this in a source I found].

### 2b. TCC (did not fire today; matters for other binaries)

- TCC stores a grant with a code requirement (csreq) for the client. When the requirement is a Developer-ID DR (Team ID + identifier), the grant survives vendor updates. When the client is ad-hoc signed, the DR is `cdhash H"..."` [V: every Homebrew formula binary checked], so any rebuild or version bump breaks the match and macOS prompts again. [I: the csreq-matching behaviour. I could not read TCC.db: `sqlite3 -readonly` returned "unable to open database file", because TCC protects it from this sandboxed shell.]
- **The responsible process decides who gets prompted and whose grant counts.** For the SSH wrapper launch, the responsible process was `com.apple.sshd-keygen-wrapper` at `/usr/libexec/sshd-keygen-wrapper` [V, log lines above]. It is Apple-signed and stable across Homebrew updates. A TCC grant attributed to it does not depend on `op`'s signature [I].
- Inside the Claude Code session, attribution is different. The responsible process was Homebrew bash (identifier bash-55554944c765..., DR = cdhash) or /usr/bin/env [V: tccd 09:28:29 and 09:38:37]. A grant attributed there would break on every `brew upgrade bash` [I]. The Claude sandbox is the likely reason for the difference [I].
- Andrew's login shell over SSH is Homebrew bash `/opt/homebrew/Cellar/bash/5.3.20/bin/bash` (ad-hoc, cdhash DR) [V]. For SSH children, attribution still went to sshd-keygen-wrapper [V].

### 2c. Keychain ACL / partition list (did not fire today)

- A keychain item ACL lists trusted apps by code requirement. The partition list names `teamid:XXXX`, `apple:`, or `apple-tool:`. An ad-hoc binary has no Team ID, so its entry is cdhash-bound and the prompt returns after each rebuild [I, from knowledge of `security(1)` `set-generic-password-partition-list`. I did not re-read the man page in this session].
- Likely local example: Homebrew git's `git-credential-osxkeychain` is ad-hoc (identifier git-credential-osxkeychain-5555494421fd...) and is the configured helper (`/opt/homebrew/etc/gitconfig: credential.helper=osxkeychain`) [V]. If it ever prompts, the cause is this mechanism [I].

---

## 3. Fixes, ranked (no MDM)

### For the Gatekeeper class (today's dialog)

| # | Fix | Survives updates? | Risk / cost | Status |
|---|-----|-------------------|-------------|--------|
| 1 | **Post-upgrade approval hook for binary casks.** After `brew upgrade`, for each `binary` artifact in a quarantined cask: confirm `codesign -dv` TeamIdentifier equals a pinned value (2BUA8C4S2C for op), run `codesign --verify`, then either (a) delete the quarantine xattr (`xattr -d com.apple.quarantine`). This is the certain path, because a file with no quarantine never invokes Gatekeeper [C: forum 706442]. Or (b) set bit 0x40, as Homebrew does for apps. Option (b) is [I]: today the approval also wrote `com.apple.provenance`, and it is untested whether 0x40 alone suppresses the prompt for a bare Mach-O. This does for binaries what Homebrew already does for `.app` artifacts. | Yes, if it runs after every upgrade (brew wrapper or `brew upgrade` alias). | Low. It keeps the signer check and skips only the notarization/XProtect first-launch scan of an already-verified signer. Approval is still per file. | (a) [C]. (b) [V] for apps in Homebrew, [I] for bare binaries. **Test once:** set the bit on a fresh quarantined copy, exec it over SSH, and look for `Prompt shown`. |
| 2 | **Upstream: extend Homebrew's `inherit_user_approval!` to `Artifact::Binary`.** | Yes, for every user. | None locally. Needs a Homebrew PR or issue. | [V] the gap in `upgrade.rb`. |
| 3 | **Grant Developer Tools to the stable responsible process.** For SSH, that is `/usr/libexec/sshd-keygen-wrapper`. For local Terminal or iTerm, that app. Path: `sudo spctl developer-mode enable-terminal` (subcommand exists here [V]), then System Settings → Privacy & Security → Developer Tools. | Yes. Apple-signed, so the DR is stable. | Medium-high. **Every** process launched over SSH (or from that terminal) skips Gatekeeper's first-launch checks, quarantined downloads included. | [I] that the pane accepts a non-bundle binary such as sshd-keygen-wrapper. [I] the SSH behaviour (one 2021 report). **Test:** log check for `kTCCServiceDeveloperTool` → Allowed. |
| 4 | **Install `op` outside Homebrew Cask**, so no quarantine-setting agent touches it (1Password's own pkg or a direct download with `curl`, which does not quarantine [C: forum 706442]). | Per mechanism: `curl` files carry no quarantine, so no prompt. Whether 1Password's pkg installer quarantines its payload is unknown. | Low-medium. Andrew loses `brew upgrade` for `op`, and vendor auto-update behaviour is unknown. | [C]/[I] |
| 5 | **Reveal "Allow applications from Anywhere"**: `sudo spctl --global-disable`, then choose it in Settings. | Yes. | High. This turns off Gatekeeper assessment system-wide. `spctl --disable-status` says the option is currently hidden [V]. The man page says rule-database edits (`--add`) are unsupported since macOS 15 and need MDM SystemPolicyRule profiles [V: `man spctl`]. | [V] commands exist. Not recommended. |
| — | **PPPC profile** | Not applicable | PPPC governs TCC, not Gatekeeper. It also needs MDM (below). | — |
| — | **Self-signing `op`** | No | It would break the AgileBits notarization, and it does not clear quarantine. | — |

### For the TCC class (other binaries)

1. **Grant to the stable parent, not the changing binary.** Over SSH that is already true (sshd-keygen-wrapper) [V]. For GUI sessions, grant FDA etc. to Terminal or iTerm (Developer-ID or Apple-signed, so the DR is stable). Durable [I].
2. **Do not run Homebrew bash as the attribution root for anything that needs TCC.** Inside the Claude session, Homebrew bash or /usr/bin/env became responsible [V]. If a TCC grant has to attach there, launch through an Apple-signed /bin/bash or /bin/zsh, or through an app [I, untested].
3. **Self-sign Homebrew binaries with a stable local identity** (a self-signed code-signing cert in the login keychain, then `codesign -f -s <id>` after each `brew upgrade`). The DR becomes `identifier X and certificate leaf = H"..."`, which stays the same across rebuilds. Durable only if re-run after every upgrade, and it modifies Homebrew-managed files [I]. Medium effort.
4. **PPPC configuration profile:** Apple's PPPC payload page lists "Requires a device management service to install" and "Requires user approval", and supports only Device Enrollment / Automated Device Enrollment [C: https://support.apple.com/guide/deployment/privacy-preferences-policy-control-payload-dep38df53c2a/web]. **There is no non-MDM path.** A user-installed profile cannot grant TCC [C, from that page's requirement. I: I know of no exception].
5. **Disabling SIP to edit TCC.db:** possible, but it removes protection for all of /System, TCC, and kernel-extension policy. It is not a durable workflow either, because updates can reset state [I]. Not recommended.

### For the Keychain class

1. **Per item:** set the partition list to include `apple-tool:,apple:` (and `teamid:` where it applies), or in Keychain Access → item → Access Control choose "Allow all applications to access this item." That survives binary updates because it no longer checks code identity [I, `security(1)`]. Cost: any process running as Andrew can read that item without a prompt.
2. **Use an Apple-signed or Developer-ID helper** instead of an ad-hoc one. Example: /usr/bin/git's bundled osxkeychain helper, which is Apple-signed, in place of Homebrew git's helper [I].

---

## 4. Other binaries likely to hit the same problem

**Gatekeeper class: casks that ship quarantined executables** [V: `find -xattrname com.apple.quarantine`, xattr flags]

| Cask / app | State |
|---|---|
| 1password-cli `op` | binary artifact. Approved today (`01c1`). **Prompts again on the next upgrade** (Homebrew does not inherit approval for binaries). |
| backblaze | 35 quarantined executables in the Caskroom (installer payload). |
| google-drive | 1 quarantined file (GoogleDrive.pkg). |
| Stats.app, Hidden Bar.app, Android Studio.app | `0181`: quarantined and not yet approved. Each prompts on its next GUI launch. As `.app` artifacts, they inherit approval on later upgrades once approved. |
| BBEdit.app | `01c1`, approved. |
| 1Password.app, iTerm.app, AppCleaner, Backblaze.app, Google Drive.app | No quarantine xattr. [I] Vendor self-updaters or earlier approval may explain this. |

**TCC / Keychain class: Homebrew formulae.** All are ad-hoc signed, with DR = cdhash and no quarantine. They never see a Gatekeeper prompt, but any TCC or Keychain grant tied to them breaks on each upgrade. [V: `codesign -dv` / `-d -r-`]

| Binary | Signing |
|---|---|
| bash 5.3.20 (login shell) | `flags=0x2(adhoc)`, identifier bash-55554944c765..., DR `cdhash H"bed57cec..."` |
| git 2.56.0_1, git-credential-osxkeychain | adhoc, cdhash DR |
| gh 2.103.3 | `flags=0x20002(adhoc,linker-signed)`, `Identifier=a.out` |
| node 26.12.1_1, python3.15, jq, openssh ssh 10.6p1, rsync 3.5.1, tmux 3.8 | adhoc, cdhash DR |

**Developer-ID, stable DR:** `op` (AgileBits 2BUA8C4S2C) and `claude` (Anthropic Q6L2SF6YDW). Their TCC and Keychain grants survive updates. `op` still gets the Gatekeeper prompt per new file.

---

## 5. Open questions for Andrew

1. Do the other recurring dialogs look like this one ("downloaded from the Internet… Open")? If they say "would like to access…" (TCC) or "wants to use your confidential information stored in…" (Keychain), they are a different class with different fixes. For the next one, note the exact text, or run `log stream --info --predicate 'process == "syspolicyd" OR process == "tccd" OR process == "SecurityAgent"'` while it is open.
2. Log retention here is only about 31 hours (the oldest syspolicyd entry is 2026-10-27 01:44). Past incidents cannot be classified from the log. I cannot say whether `op` ran between its 2026-10-22 08:13 install and today, or whether earlier prompts were missed.
3. Which fix does he want: the narrow, signer-pinned post-upgrade approval hook (#1), or the broad Developer Tools grant for SSH (#3)? #3 is "once and for all" but exempts everything run over SSH.
4. Does he want a Homebrew issue or PR filed for `inherit_user_approval!` covering `binary` artifacts?
5. Revert the Homebrew developer-mode change I caused: `brew developer off`.

## Sources

- Apple Platform Security, Gatekeeper and runtime protection: <https://support.apple.com/guide/security/gatekeeper-and-runtime-protection-sec5599b66df/web>
- Apple DTS (Quinn), quarantine and Gatekeeper: <https://developer.apple.com/forums/thread/706442>
- Apple PPPC payload: <https://support.apple.com/guide/deployment/privacy-preferences-policy-control-payload-dep38df53c2a/web>
- man spctl on this machine (macOS 27.2), and spctl usage output (developer-mode enable-terminal)
- Homebrew 7.0.11 source: /opt/homebrew/Library/Homebrew/cask/quarantine.rb, cask/upgrade.rb, cask/artifact/binary.rb, extend/os/mac/cask/quarantine.rb. Docs: /opt/homebrew/docs/Homebrew-Security-and-Supply-Chain.md
- Community reports on Developer Tools and SSH: <https://notes.billmill.org/computer_usage/mac_os/Avoiding_gatekeeper_in_your_terminal.html> and <https://lists.tetaneutral.net/pipermail/cfarm-users/2021-March/000718.html>
- Homebrew 5.0 --no-quarantine deprecation (secondary): <https://workbrew.com/blog/what-homebrew-5-0-0-means-for-your-mac-fleet>
