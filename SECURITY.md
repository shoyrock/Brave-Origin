# Security

Report suspected vulnerabilities privately through [GitHub security reporting](https://github.com/shoyrock/Brave-Origin/security/advisories/new). Include the image tag, host type, and steps to reproduce. Do not post passwords, tokens, browser profiles, or private browsing data in public issues.

## Deployment

- Keep login protection enabled and use a unique password. Prefer a mounted secret file to a password in Compose configuration.
- Keep the web session on a trusted network or behind a VPN. Use a trusted TLS certificate when accessing it remotely.
- Keep the Docker host, kernel, and container image updated. Automatic Brave updates do not update the rest of the image.
- Give each container its own appdata folder. Back up a stopped or quiesced profile, and restrict access to backups: they contain browsing data, saved passwords, and session cookies.
- Keep Chromium sandboxing and `no-new-privileges` enabled. The supplied configuration allows user namespaces using `seccomp:unconfined`; Docker's syscall filter is therefore disabled for this container. Do not grant privileged mode, `SYS_ADMIN`, or access to the Docker socket.
- Keep the capability allowlist and process limit from `compose.yaml` or the Unraid template when writing your own `docker run` command. The image contains no setuid programs or file capabilities other than Brave's sandbox helper.
- Let startup manage appdata permissions. The mount root, credentials, certificates, and lifetime locks are protected from the browser account. Do not recursively change ownership of the whole appdata folder or use symlinks for these protected paths.

## Release checks

### Known issues in 1.0.1-beta.2

This beta contains the saved-file and cross-site session protections, plus automatic display resizing. It is available for testing with known dependency vulnerabilities; it is not a security-cleared stable release. Use a separate appdata folder on a trusted network or VPN.

The September 8 scan of `1.0.1-beta.2` returned 31 critical and 249 high-severity package vulnerability matches. Stable publication remains blocked. Examples include:

- **nginx — CVE-2026-42533:** a memory-safety issue can crash the web proxy and, under additional conditions, allow code execution. Exploitability depends on nginx configuration. Debian still lists the supplied Trixie package as affected and plans a point-release fix. [Debian advisory](https://security-tracker.debian.org/tracker/CVE-2026-42533).
- **libxml2 — CVE-2026-86140:** a stack buffer overflow in an XML validation function. The supplied version remains affected. [Debian advisory](https://security-tracker.debian.org/tracker/CVE-2026-86140).
- **FFmpeg — CVE-2026-70628 and CVE-2026-70632:** crafted media can trigger memory corruption in particular subtitle and video decoders. The image includes affected distribution libraries and libraries bundled with PyAV. We have not established whether this application can reach the affected decoders. [Subtitle advisory](https://security-tracker.debian.org/tracker/CVE-2026-70628), [video advisory](https://security-tracker.debian.org/tracker/CVE-2026-70632).

These examples are not the complete finding list. The [prerelease](https://github.com/shoyrock/Brave-Origin/releases/tag/v1.0.1-beta.2) includes the dependency report. Scanner matches identify affected packages; they do not establish that every issue is exploitable in this deployment. This beta leaves all findings in the report and does not claim a clean scan.

Review changes to downloaded dependencies and pinned checksums. Run the container smoke tests, including hostile-storage and updater tests, before publishing. Scan the final image for known dependency vulnerabilities and malware, and scan Git history for secrets. Investigate scanner findings and record unresolved risks; a clean scan is not proof that software is safe.

If a machine reports malware, preserve the detection name and file path, isolate that machine from sensitive services, and investigate the affected file before running it again. A repository scan cannot determine whether a different machine is compromised.
