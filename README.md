# buildwithaihub — founding-member waitlist

Static single-file waitlist page for the Build With AI Hub community (Claude-native agentic automation). Deployed via GitHub Pages.

## Live URL
- GitHub Pages: https://lgcreativestudios.github.io/buildwithaihub/
- Custom domain (pending DNS recovery): buildwithaihub.com

## Form backend
Web3Forms (free tier, 250 submissions/mo). The access key lives in `index.html` as `W3F_KEY`.
Setup: get a key at https://web3forms.com (enter the destination email, key arrives instantly), replace `REPLACE_WITH_WEB3FORMS_KEY`, commit, push. Submissions arrive at the destination email.

## Custom domain (when buildwithaihub.com DNS control is recovered)
1. Add a `CNAME` file to this repo containing exactly: `buildwithaihub.com`
2. At the registrar: CNAME record `www -> lgcreativestudios.github.io`, and apex A records to GitHub Pages IPs (185.199.108.153 / .109 / .110 / .111).
3. Enable "Enforce HTTPS" in repo Settings → Pages once the cert issues.

## Waitlist pass threshold (demand micro-validation)
Set BEFORE promotion begins; see OHD project instructions. Proposed: ≥30 signups within 21 days of active $0 promotion.

## Notes
- No trackers, no cookies. Honeypot field for bots.
- `prefers-reduced-motion` respected (terminal animation renders static).
- Part of the OHD project's PURSUE-CONDITIONAL validation for the Skool community lead (scored 2026-07-16).
## Book: It Ran While I Slept

The free material from the book *It Ran While I Slept: How to Run AI Agents Unattended, Safely*:

- The wrapper script the book is built around: `scripts/v1/phaseC_overnight_orchestrator.ps1` (annotated in Appendix B).
- The Windows setup files from Appendix C: `book/windows-setup/`.
