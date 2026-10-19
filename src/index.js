require('dotenv').config();

const fs = require('fs');
const os = require('os');
const path = require('path');
const readline = require('readline');
const { chromium } = require('playwright');
const { parseResume } = require('./parser');
const { fetchJobLinks } = require('./searcher');
const { applyToJobPage } = require('./applier');

const ROOT_DIR = path.resolve(__dirname, '..');
const CONFIG_PATH = path.join(ROOT_DIR, 'config.json');
const RESUME_PATH = path.join(ROOT_DIR, 'resume.pdf');
const APPLIED_JOBS_PATH = path.join(ROOT_DIR, 'applied_jobs.json');
const CHROME_USER_DATA_DIR = path.join(os.homedir(), '.config', 'google-chrome');
const CHROME_CLONE_DIR = path.join(os.tmpdir(), 'job-application-bot-chrome-profile');
const MAX_ATTEMPTS = 50;

// Chrome refuses to open its DevTools/remote-debugging pipe when --user-data-dir
// points at its own OS-default profile directory (a deliberate anti-automation
// security check), which silently hangs Playwright's launch. So we clone the
// resolved profile's session data into a non-default directory and launch there
// instead - same cookies/logins, but a directory Chrome will actually debug.
const EXCLUDED_PROFILE_ENTRIES = new Set([
  'Extensions',
  'Service Worker',
  'Local Extension Settings',
  'Extension State',
  'Extension Rules',
  'DNR Extension Rules',
  'GPUCache',
  'DawnWebGPUCache',
  'DawnGraphiteCache',
  'Code Cache',
  'Cache',
  'ShaderCache',
  'GrShaderCache',
  'blob_storage',
]);

function loadConfig() {
  const raw = fs.readFileSync(CONFIG_PATH, 'utf-8');
  return JSON.parse(raw);
}

function loadAppliedJobs() {
  if (!fs.existsSync(APPLIED_JOBS_PATH)) return [];
  try {
    const raw = fs.readFileSync(APPLIED_JOBS_PATH, 'utf-8');
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function saveAppliedJob(appliedJobs, record) {
  appliedJobs.push(record);
  fs.writeFileSync(APPLIED_JOBS_PATH, JSON.stringify(appliedJobs, null, 2));
}

function resolveChromeProfileDirectory(candidateEmail) {
  const localStatePath = path.join(CHROME_USER_DATA_DIR, 'Local State');

  try {
    const localState = JSON.parse(fs.readFileSync(localStatePath, 'utf-8'));
    const infoCache = (localState.profile && localState.profile.info_cache) || {};

    for (const [dirName, info] of Object.entries(infoCache)) {
      if (info.user_name && candidateEmail && info.user_name.toLowerCase() === candidateEmail.toLowerCase()) {
        return dirName;
      }
    }
  } catch (err) {
    console.warn(`[index] Could not read Chrome's Local State (${err.message}). Using "Default" profile.`);
  }

  return 'Default';
}

function copyProfileData(srcDir, destDir) {
  fs.mkdirSync(destDir, { recursive: true });

  for (const entry of fs.readdirSync(srcDir, { withFileTypes: true })) {
    if (EXCLUDED_PROFILE_ENTRIES.has(entry.name)) continue;

    const srcPath = path.join(srcDir, entry.name);
    const destPath = path.join(destDir, entry.name);

    try {
      fs.cpSync(srcPath, destPath, { recursive: true, force: true });
    } catch (err) {
      console.warn(`[index] Could not copy "${entry.name}" from your Chrome profile (${err.message}). Skipping it.`);
    }
  }
}

function prepareClonedChromeProfile(profileDirectory) {
  fs.rmSync(CHROME_CLONE_DIR, { recursive: true, force: true });
  fs.mkdirSync(CHROME_CLONE_DIR, { recursive: true });

  const localStateSrc = path.join(CHROME_USER_DATA_DIR, 'Local State');
  if (fs.existsSync(localStateSrc)) {
    fs.copyFileSync(localStateSrc, path.join(CHROME_CLONE_DIR, 'Local State'));
  }

  const srcProfile = path.join(CHROME_USER_DATA_DIR, profileDirectory);
  const destProfile = path.join(CHROME_CLONE_DIR, profileDirectory);

  console.log(`[index] Cloning Chrome profile "${profileDirectory}" (cookies, saved logins) into a working copy...`);
  copyProfileData(srcProfile, destProfile);
}

async function launchBrowserContext(candidateEmail) {
  const profileDirectory = resolveChromeProfileDirectory(candidateEmail);
  prepareClonedChromeProfile(profileDirectory);

  console.log(`[index] Launching cloned Chrome profile: "${profileDirectory}"`);

  const context = await chromium.launchPersistentContext(CHROME_CLONE_DIR, {
    channel: 'chrome',
    headless: false,
    ignoreDefaultArgs: ['--enable-automation', '--no-sandbox'],
    args: [
      '--disable-blink-features=AutomationControlled',
      `--profile-directory=${profileDirectory}`,
      '--no-first-run',
      '--no-default-browser-check',
      '--start-maximized',
    ],
    viewport: null,
  });

  return context;
}

// Naukri/Indeed sessions don't survive being copied from the real profile:
// login state partly lives in sessionStorage (memory-only, never written to
// disk by any browser) and/or these sites deliberately show a logged-out
// view to anything they fingerprint as automated, even with valid cookies
// present. The only reliable fix is logging in live, inside this exact
// browser instance, before the run starts using it.
async function promptForManualLogin(page) {
  console.log('[index] A real Chrome window has opened.');
  console.log('[index] Naukri/Indeed logins do not carry over from the cloned profile - if you want');
  console.log('[index] real applications to go through, log into Naukri/Indeed/etc. in THIS window now.');

  try {
    await page.goto('https://www.naukri.com/', { waitUntil: 'load', timeout: 20000 });
  } catch (err) {
    console.warn(`[index] Could not open Naukri for manual login (${err.message}).`);
  }

  await waitForEnter('[index] Press Enter here once you are done (or just press Enter to skip and search anyway)...\n');
}

const MANUAL_LOGIN_FALLBACK_SECONDS = 45;

// readline only actually blocks when stdin is a real interactive terminal.
// If this is launched in a context without one (an IDE "run" button, a
// non-interactive shell, stdin redirected/closed), rl.question() can resolve
// immediately or never fire its callback at all - either way the pause
// silently fails to give you any real chance to log in. Detect that case and
// fall back to a fixed, clearly-announced wait instead of trusting readline.
function waitForEnter(promptText) {
  if (!process.stdin.isTTY) {
    console.log('[index] No interactive terminal detected, so Enter-to-continue will not work here.');
    console.log(`[index] Waiting ${MANUAL_LOGIN_FALLBACK_SECONDS}s instead - log in in the Chrome window now.`);
    return countdown(MANUAL_LOGIN_FALLBACK_SECONDS);
  }

  return new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    rl.question(promptText, () => {
      rl.close();
      resolve();
    });
  });
}

function countdown(totalSeconds) {
  return new Promise((resolve) => {
    let remaining = totalSeconds;
    const interval = setInterval(() => {
      remaining -= 5;
      if (remaining > 0) {
        console.log(`[index] ...${remaining}s remaining`);
      } else {
        clearInterval(interval);
        resolve();
      }
    }, 5000);
  });
}

function buildProfile(parsedProfile, config) {
  return {
    ...parsedProfile,
    location: config.target_location,
    noticePeriod: config.notice_period_days,
    expectedCtc: config.expected_ctc,
    linkedin: config.linkedin_url,
    role: config.target_role,
  };
}

async function run() {
  const config = loadConfig();

  console.log('[index] Parsing resume...');
  const parsedProfile = await parseResume(RESUME_PATH);
  const profile = buildProfile(parsedProfile, config);

  const appliedJobs = loadAppliedJobs();
  const appliedKeys = new Set(appliedJobs.map((job) => job.dedupeKey || job.url));

  const targetQuota = config.target_quota || 5;
  let successCount = appliedJobs.filter((job) => job.applied).length;

  console.log(`[index] Target quota: ${targetQuota}. Already applied so far: ${successCount}.`);
  if (successCount >= targetQuota) {
    console.log('[index] Quota already met. Exiting.');
    return;
  }

  const context = await launchBrowserContext(profile.email);
  const page = context.pages()[0] || (await context.newPage());

  await promptForManualLogin(page);

  try {
    let attempts = 0;

    while (successCount < targetQuota && attempts < MAX_ATTEMPTS) {
      console.log('[index] Fetching job links...');
      const jobLinks = await fetchJobLinks(page, { role: profile.role, location: profile.location });
      const freshLinks = jobLinks.filter((job) => !appliedKeys.has(job.dedupeKey || job.url));

      if (freshLinks.length === 0) {
        console.log('[index] No new job links found this round. Stopping.');
        break;
      }

      for (const job of freshLinks) {
        if (successCount >= targetQuota || attempts >= MAX_ATTEMPTS) break;
        attempts += 1;

        console.log(`[index] Attempt ${attempts}: ${job.url}`);
        const result = await applyToJobPage(page, job.url, profile, RESUME_PATH);
        result.dedupeKey = job.dedupeKey || job.url;

        appliedKeys.add(result.dedupeKey);
        saveAppliedJob(appliedJobs, result);

        if (result.applied) {
          successCount += 1;
          console.log(`[index] Applied (${successCount}/${targetQuota}): ${result.company} - ${result.role}`);
        } else {
          console.log(`[index] Skipped: ${job.url} (${result.reason || 'unknown reason'})`);
        }
      }
    }

    console.log(`[index] Session complete. Successful applications: ${successCount}/${targetQuota}.`);
  } finally {
    await context.close();
  }
}

run().catch((err) => {
  console.error('[index] Fatal error:', err);
  process.exit(1);
});
