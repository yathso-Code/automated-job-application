# Job Application Bot

A Node.js + Playwright bot that searches Naukri, Indeed, and Google/Bing for job postings matching your profile, then auto-fills and submits applications using your resume — optionally using the Gemini API to write context-aware answers to open-ended application questions.

Built for Ubuntu Linux with native Google Chrome. Runs against your **real Chrome profile** (cloned into a disposable working copy on each run) so it can reuse your existing logins.

> **Status: working but rough.** This was built iteratively against real job sites, and several of their quirks are documented below under [Known Limitations](#known-limitations). Contributions that address any of these are very welcome — see [Contributing](#contributing).

## How it works

```
 config.json + resume.pdf
          │
          ▼
   ┌─────────────┐     Gemini (if available) extracts a structured profile
   │  parser.js  │ ──► from resume.pdf; falls back to local regex parsing
   └─────────────┘     if the AI call fails or quota is exhausted
          │
          ▼
   ┌─────────────┐     Clones your Chrome profile into a disposable temp
   │  index.js   │ ──► directory (Chrome refuses DevTools access on its own
   │(orchestrator)│     default profile dir), launches it, and pauses so you
   └─────────────┘     can log into Naukri/Indeed live in that window
          │
          ▼
   ┌─────────────┐     Searches Naukri + Indeed directly (most reliable),
   │ searcher.js │ ──► falls back to Google (often CAPTCHA'd) then Bing
   └─────────────┘     (often ignores site: filters) if those found nothing
          │
          ▼
   ┌─────────────┐     For each new link: fills name/email/phone/location/
   │ applier.js  │ ──► notice period/CTC, writes a cover-letter answer (via
   └─────────────┘     Gemini or a static summary), uploads resume.pdf, clicks
          │             submit - skipping anything that looks closed, login-
          ▼             gated, or redirected to a multi-step apply wizard
  applied_jobs.json  ◄── every attempt (success or skip, with a reason) is
                          recorded immediately, so re-runs never duplicate
```

The loop in `index.js` keeps searching and applying until `target_quota` (from `config.json`) successful applications are reached, or it runs out of new links.

## Setup

**Requirements:** Ubuntu Linux, Node.js v24+, native Google Chrome (`/opt/google/chrome/chrome` via the `google-chrome` apt package).

```bash
git clone <this-repo-url>
cd job-appling
bash setup_project.sh   # installs deps, creates config.json/.env from the example templates, runs syntax checks
```

Then:

1. **`resume.pdf`** — put your actual resume in the project root (gitignored, never committed).
2. **`config.json`** — created from `config.example.json` on first setup; edit it with your real target role, location, notice period, expected CTC, LinkedIn URL, and how many successful applications to aim for (`target_quota`).
3. **`.env`** (optional) — created from `.env.example`; add a real `GEMINI_API_KEY` from [Google AI Studio](https://aistudio.google.com/apikey) to enable AI-based resume parsing and cover-letter answers. Without it, the bot falls back to local regex parsing and a static summary — it still works, just less tailored.

## Usage

```bash
./start.sh
```

What happens, in order:

1. If your real Chrome is open, it asks to close it (needed for a clean, consistent copy of your cookies) — nothing is closed without this confirmation.
2. Clones your Chrome profile's session data (cookies, local storage, etc. — not caches or extensions) into a disposable working copy, and launches that instead of your real profile.
3. Opens Naukri and **pauses**, waiting for you to press Enter in the terminal. Log into Naukri/Indeed in that window now if you want real applications to go through — see [Known Limitations](#known-limitations) for why this manual step exists.
4. Searches for jobs, applies to each new one it finds, and logs every attempt to `applied_jobs.json` immediately.
5. Stops once `target_quota` applications succeed, or it runs out of new links.

## Project structure

| File | Purpose |
|---|---|
| `src/index.js` | Orchestrator: loads config/resume, launches Chrome, runs the search→apply loop, tracks dedup/quota |
| `src/parser.js` | Extracts a structured candidate profile from `resume.pdf` (Gemini first, local regex fallback) |
| `src/searcher.js` | Finds job links on Naukri/Indeed/Google/Bing, filtering out nav junk and normalizing dedup keys |
| `src/applier.js` | Fills and submits a single application page; detects expired/login-gated/multi-step-flow pages |
| `src/aiClient.js` | Thin wrapper around the Gemini API with graceful fallback on any failure |
| `config.json` | Your target role, location, CTC, etc. (gitignored — see `config.example.json`) |
| `.env` | Your `GEMINI_API_KEY` (gitignored — see `.env.example`) |
| `applied_jobs.json` | Running log of every attempt, used to avoid duplicate applications |
| `setup_project.sh` | Regenerates every file above from scratch and runs syntax checks — the canonical source of truth alongside `src/` |
| `start.sh` | Pre-flight checks (Chrome lock cleanup, required files) then runs the bot |

## Known limitations

These were found by actually running the bot against live sites, not guessed:

- **Google CAPTCHAs automated search almost instantly**, even from a real logged-in profile. Bing works but often ignores `site:` filters and returns generic articles instead of live postings. Naukri and Indeed's own search is used as the primary source for this reason.
- **Naukri's real "Apply" button renders at 0×0 pixels until the page is scrolled** (it lives in a sticky header that only activates on scroll). The bot scrolls before checking for it, but this kind of quirk is easy for other sites to have in different forms.
- **Session/login state does not survive profile cloning.** Naukri (and likely other sites) keep part of their login state in `sessionStorage`, which no browser ever writes to disk — so copying profile files can never carry it over, and/or these sites may deliberately show a logged-out view to anything they fingerprint as automated. The bot works around this with a manual login pause at startup rather than trying to transplant a session.
- **Indeed's "Apply" usually hands off to its own multi-step wizard** (`smartapply.indeed.com`) — resume confirmation, screening questions, etc. This bot only fills single-page forms, so these are correctly logged as skipped rather than falsely marked as applied, but it means most Indeed listings won't actually go through end-to-end.
- **Gemini's free tier caps at 20 requests/day** on the current model. Once exhausted, the bot silently falls back to local parsing and a static cover-letter summary — this is by design, not a bug, but expect AI-personalized answers to run out fast.
- **Linux/Chrome-specific.** The Chrome launch flags, profile paths (`~/.config/google-chrome`), and lock-file handling assume Ubuntu with native Chrome. No Windows/macOS support.

## Disclaimer

This submits real job applications, under your real identity, to real companies — there is no review step before clicking submit. Automated access likely falls outside the Terms of Service of the sites it targets (Naukri, Indeed, Google, Bing), and some platforms may flag or restrict accounts used this way. This project is intended for personal, educational use against your own accounts. Use it at your own risk; review `applied_jobs.json` regularly rather than letting it run fully unattended.

## Contributing

This was built fast against real sites and has plenty of rough edges. Issues and PRs welcome, especially around:

- **Reliability of the search step** — better handling of Google's CAPTCHA, or additional direct-search sources beyond Naukri/Indeed.
- **Smarter apply-page detection** — distinguishing "genuinely not applicable" from "this bot just doesn't understand this site's UI yet" (the sticky-button and multi-step-wizard cases are examples of bugs found this way; there are certainly more).
- **More ATS/platform support** — LinkedIn Easy Apply, Workday, Greenhouse, Lever all have their own apply-flow quirks not yet handled.
- **Cross-platform support** — Windows/macOS Chrome paths and launch flags.
- **Tests** — there currently aren't any automated tests; everything so far was verified by hand against live sites.

Fork it, open an issue, or send a PR.

## License

MIT — see [LICENSE](LICENSE).
