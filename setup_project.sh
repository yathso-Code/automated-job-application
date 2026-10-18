#!/usr/bin/env bash
# Bootstrap script for job-application-bot.
# Regenerates every project file from scratch, installs dependencies,
# and runs a syntax check (node -c) on every generated JS file.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

echo "[setup] Writing project files into $PROJECT_DIR ..."
mkdir -p src

# ---------------------------------------------------------------------------
cat > package.json << 'EOF'
{
  "name": "job-application-bot",
  "version": "1.0.0",
  "description": "Automated job application bot for MERN stack roles using Playwright, native Chrome, and the Gemini API.",
  "main": "src/index.js",
  "scripts": {
    "start": "./start.sh",
    "bot": "node src/index.js"
  },
  "license": "MIT",
  "dependencies": {
    "@google/genai": "^2.30.0",
    "dotenv": "^16.4.5",
    "pdf-parse": "^1.1.4",
    "playwright": "^1.64.1"
  }
}
EOF

# ---------------------------------------------------------------------------
cat > config.example.json << 'EOF'
{
  "target_role": "MERN Stack Developer",
  "target_location": "Noida, Uttar Pradesh",
  "notice_period_days": "15",
  "expected_ctc": "12 LPA",
  "linkedin_url": "https://linkedin.com/in/your-profile",
  "target_quota": 5
}
EOF

if [ ! -f config.json ]; then
  cp config.example.json config.json
  echo "[setup] No config.json found. Created one from config.example.json - edit it with your own details."
fi

# ---------------------------------------------------------------------------
if [ ! -f applied_jobs.json ]; then
  cat > applied_jobs.json << 'EOF'
[]
EOF
fi

# ---------------------------------------------------------------------------
cat > .env.example << 'EOF'
GEMINI_API_KEY=your_actual_gemini_api_key
GEMINI_MODEL=gemini-flash-latest
EOF

if [ ! -f .env ]; then
  echo "[setup] No .env found. Copy .env.example to .env and fill in your real GEMINI_API_KEY."
fi

# ---------------------------------------------------------------------------
cat > .gitignore << 'EOF'
node_modules/
.env
resume.pdf
config.json
applied_jobs.json
EOF

# ---------------------------------------------------------------------------
cat > src/aiClient.js << 'EOF'
const { GoogleGenAI } = require('@google/genai');

const MODEL = process.env.GEMINI_MODEL || 'gemini-flash-latest';

let client = null;
let clientInitFailed = false;

function getClient() {
  if (clientInitFailed) return null;
  if (!process.env.GEMINI_API_KEY) return null;

  if (!client) {
    try {
      client = new GoogleGenAI({ apiKey: process.env.GEMINI_API_KEY });
    } catch (err) {
      console.warn(`[ai] Could not initialize Gemini client (${err.message}). AI features disabled for this run.`);
      clientInitFailed = true;
      return null;
    }
  }

  return client;
}

async function generateText(prompt) {
  const ai = getClient();
  if (!ai) return null;

  try {
    const response = await ai.models.generateContent({
      model: MODEL,
      contents: prompt,
    });
    const text = response && response.text;
    return typeof text === 'string' && text.trim() ? text.trim() : null;
  } catch (err) {
    console.warn(`[ai] Gemini text request failed (${err.message}). Falling back to local logic.`);
    return null;
  }
}

async function generateFromPdf(pdfBuffer, prompt) {
  const ai = getClient();
  if (!ai) return null;

  try {
    const response = await ai.models.generateContent({
      model: MODEL,
      contents: [
        {
          role: 'user',
          parts: [
            { inlineData: { mimeType: 'application/pdf', data: pdfBuffer.toString('base64') } },
            { text: prompt },
          ],
        },
      ],
    });
    const text = response && response.text;
    return typeof text === 'string' && text.trim() ? text.trim() : null;
  } catch (err) {
    console.warn(`[ai] Gemini PDF request failed (${err.message}). Falling back to local logic.`);
    return null;
  }
}

module.exports = { generateText, generateFromPdf };
EOF

# ---------------------------------------------------------------------------
cat > src/parser.js << 'EOF'
const fs = require('fs');
const path = require('path');
const pdfParse = require('pdf-parse');
const { generateFromPdf } = require('./aiClient');

const SKILL_KEYWORDS = [
  'React.js',
  'React',
  'Node.js',
  'Express.js',
  'Express',
  'MongoDB',
  'TypeScript',
  'JavaScript',
  'REST APIs',
  'REST API',
  'Redux',
  'HTML',
  'CSS',
  'Git',
];

const DEFAULT_SKILLS = [
  'React.js',
  'Node.js',
  'Express.js',
  'MongoDB',
  'TypeScript',
  'JavaScript',
  'REST APIs',
];

// Last-resort placeholders, only used if resume.pdf can't be parsed at all
// (neither Gemini nor the local regex fallback found anything). These are
// intentionally generic - this file is shared/public, so it must never
// default to any one person's real contact details.
const FALLBACK_NAME = 'Your Name';
const FALLBACK_EMAIL = 'you@example.com';
const FALLBACK_PHONE = '+91-XXXXXXXXXX';

const GEMINI_PROMPT =
  'Extract the candidate profile from this resume PDF as strict JSON with exactly these keys: ' +
  '"name" (string), "email" (string), "phone" (string), "skills" (array of strings), ' +
  '"summary" (a 3-4 sentence first-person professional summary written for a software developer ' +
  'with 3+ years of MERN stack experience, suitable for pasting into a job application cover-letter field). ' +
  'Respond with ONLY the raw JSON object. No markdown code fences, no commentary.';

async function parseResume(resumePath) {
  if (!fs.existsSync(resumePath)) {
    throw new Error(
      `Resume file not found at ${resumePath}. Place your resume.pdf in the project root before running the bot.`
    );
  }

  const buffer = fs.readFileSync(resumePath);

  const aiProfile = await parseResumeWithGemini(buffer, resumePath);
  if (aiProfile) {
    console.log('[parser] Resume parsed via Gemini.');
    return aiProfile;
  }

  console.warn('[parser] Using local (non-AI) resume parsing.');
  return parseResumeLocally(buffer, resumePath);
}

async function parseResumeWithGemini(buffer, resumePath) {
  const raw = await generateFromPdf(buffer, GEMINI_PROMPT);
  if (!raw) return null;

  try {
    const jsonText = extractJsonBlock(raw);
    const parsed = JSON.parse(jsonText);

    if (!parsed.name || !parsed.email) return null;

    const skills =
      Array.isArray(parsed.skills) && parsed.skills.length ? parsed.skills.map(String) : DEFAULT_SKILLS;

    const profile = {
      name: String(parsed.name).trim(),
      email: String(parsed.email).trim(),
      phone: parsed.phone ? String(parsed.phone).trim() : FALLBACK_PHONE,
      skills,
      rawText: '',
      resumePath: path.resolve(resumePath),
    };

    profile.summary = parsed.summary ? String(parsed.summary).trim() : buildSummary(profile);
    return profile;
  } catch (err) {
    console.warn(`[parser] Could not parse Gemini's JSON response (${err.message}).`);
    return null;
  }
}

function extractJsonBlock(text) {
  const match = text.match(/\{[\s\S]*\}/);
  return match ? match[0] : text;
}

async function parseResumeLocally(buffer, resumePath) {
  let text = '';

  try {
    const parsed = await pdfParse(buffer);
    text = parsed.text || '';
  } catch (err) {
    console.warn(`[parser] Could not extract text from PDF (${err.message}). Falling back to defaults.`);
    text = '';
  }

  const profile = {
    name: extractName(text) || FALLBACK_NAME,
    email: extractEmail(text) || FALLBACK_EMAIL,
    phone: extractPhone(text) || FALLBACK_PHONE,
    skills: extractSkills(text),
    rawText: text,
    resumePath: path.resolve(resumePath),
  };

  profile.summary = buildSummary(profile);

  return profile;
}

function extractEmail(text) {
  const match = text.match(/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/);
  return match ? match[0] : null;
}

function extractPhone(text) {
  const match = text.match(/(\+?\d{1,3}[-\s]?)?\d{10}\b/);
  return match ? match[0].replace(/\s+/g, '') : null;
}

function extractName(text) {
  const lines = text
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean);

  const candidateLine = lines.find((line) => {
    const words = line.split(/\s+/);
    return (
      words.length >= 2 &&
      words.length <= 4 &&
      /^[A-Za-z.\s]+$/.test(line) &&
      line === line.replace(/\s{2,}/g, ' ')
    );
  });

  if (!candidateLine) return null;

  const normalized = candidateLine.replace(/\s+/g, ' ').trim();
  const isAllCaps = normalized === normalized.toUpperCase() && normalized !== normalized.toLowerCase();
  return isAllCaps ? toTitleCase(normalized) : normalized;
}

function toTitleCase(str) {
  return str
    .toLowerCase()
    .split(' ')
    .map((word) => (word ? word.charAt(0).toUpperCase() + word.slice(1) : word))
    .join(' ');
}

function extractSkills(text) {
  const lowerText = text.toLowerCase();
  const detected = SKILL_KEYWORDS.filter((skill) => lowerText.includes(skill.toLowerCase()));
  const unique = [...new Set(detected)];
  return unique.length ? unique : DEFAULT_SKILLS;
}

function buildSummary(profile) {
  const skillList = profile.skills.slice(0, 6).join(', ');
  return (
    `I am a Software Developer with 3+ years of hands-on experience building full-stack web applications ` +
    `using the MERN stack (${skillList}). I have designed and shipped REST APIs, built responsive React ` +
    `front-ends, and worked extensively with MongoDB for data modeling and Express.js for backend services. ` +
    `I am currently looking for a MERN Stack Developer role in Noida / Delhi NCR where I can contribute to ` +
    `scalable product development, and I would welcome the opportunity to discuss this role further.`
  );
}

module.exports = { parseResume };
EOF

# ---------------------------------------------------------------------------
cat > src/searcher.js << 'EOF'
const ATS_HOST_PATTERNS = [
  /lever\.co/i,
  /greenhouse\.io/i,
  /myworkdayjobs\.com/i,
  /naukri\.com/i,
  /indeed\.com/i,
  /smartrecruiters\.com/i,
  /workable\.com/i,
  /icims\.com/i,
  /bamboohr\.com/i,
  /zohorecruit/i,
  /freshteam\.com/i,
];

const CAREER_PAGE_PATTERN = /career|jobs?|vacanc|opening|hiring|apply/i;

const EXCLUDED_HOST_PATTERNS = [
  /google\.[a-z.]+/i,
  /webcache\.googleusercontent/i,
  /youtube\.com/i,
  /facebook\.com/i,
  /twitter\.com/i,
  /x\.com/i,
  /instagram\.com/i,
  /schema\.org/i,
  /gstatic\.com/i,
  /bing\.com/i,
  /microsoft\.com/i,
];

const MAX_RESULTS = 15;
const DEFAULT_ROLE = 'MERN Stack Developer';
const DEFAULT_LOCATION = 'Noida';

async function fetchJobLinks(page, { role = DEFAULT_ROLE, location = DEFAULT_LOCATION } = {}) {
  const collected = new Map();
  const city = location.split(',')[0].trim();
  const query = `${role} job in ${city}`;

  // Naukri's own search is the primary source: it's the actual target ATS for
  // this search, India-focused, and returns live listings directly - unlike
  // Google (CAPTCHAs automated queries almost instantly, even on a real
  // logged-in profile) or Bing (often ignores site: filters and returns
  // generic articles instead of live postings).
  try {
    await searchNaukri(page, role, city, collected);
  } catch (err) {
    console.warn(`[searcher] Naukri search failed: ${err.message}`);
  }

  if (collected.size < MAX_RESULTS) {
    try {
      await searchIndeed(page, role, city, collected);
    } catch (err) {
      console.warn(`[searcher] Indeed search failed: ${err.message}`);
    }
  }

  if (collected.size < MAX_RESULTS) {
    try {
      await searchGoogle(page, query, collected);
    } catch (err) {
      console.warn(`[searcher] Google search failed for "${query}": ${err.message}`);
    }
  }

  if (collected.size === 0) {
    console.warn('[searcher] Google returned no usable results (likely blocked or showing a CAPTCHA). Falling back to Bing.');
    try {
      await searchBing(page, query, collected);
    } catch (err) {
      console.warn(`[searcher] Bing search failed for "${query}": ${err.message}`);
    }
  }

  return Array.from(collected.values());
}

function slugify(text) {
  return text
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/(^-|-$)/g, '');
}

async function searchNaukri(page, role, city, collected) {
  const url = `https://www.naukri.com/${slugify(role)}-jobs-in-${slugify(city)}`;

  // Naukri is a client-rendered SPA: the listings aren't in the DOM yet at
  // 'domcontentloaded', only after the page finishes loading and its JS runs.
  await page.goto(url, { waitUntil: 'load', timeout: 30000 });
  await page.waitForTimeout(2500);

  const blocked = await page
    .locator('text=/access denied|you don\'t have permission/i')
    .first()
    .isVisible()
    .catch(() => false);

  if (blocked) {
    console.warn('[searcher] Naukri blocked this request.');
    return;
  }

  const hrefs = await page.$$eval('a', (anchors) => anchors.map((a) => a.href).filter(Boolean));
  extractJobLinks(hrefs, collected);
}

async function searchIndeed(page, role, city, collected) {
  const url = `https://in.indeed.com/jobs?q=${encodeURIComponent(role)}&l=${encodeURIComponent(city)}`;
  await page.goto(url, { waitUntil: 'load', timeout: 30000 });
  await page.waitForTimeout(2000);

  const hrefs = await page.$$eval('a', (anchors) => anchors.map((a) => a.href).filter(Boolean));
  extractJobLinks(hrefs, collected);
}

async function searchGoogle(page, query, collected) {
  const url = `https://www.google.com/search?q=${encodeURIComponent(query)}&num=30`;
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });

  const captchaDetected = await page
    .locator('text=/unusual traffic|recaptcha|verify you are a human/i')
    .first()
    .isVisible()
    .catch(() => false);

  if (captchaDetected) {
    console.warn('[searcher] Google CAPTCHA/unusual-traffic page detected, skipping this query.');
    return;
  }

  const hrefs = await page.$$eval('a', (anchors) => anchors.map((a) => a.href).filter(Boolean));
  extractJobLinks(hrefs, collected);
}

async function searchBing(page, query, collected) {
  const url = `https://www.bing.com/search?q=${encodeURIComponent(query)}&count=30`;
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });

  const hrefs = await page.$$eval('a', (anchors) => anchors.map((a) => a.href).filter(Boolean));
  extractJobLinks(hrefs, collected);
}

function resolveRealUrl(href) {
  try {
    const parsed = new URL(href);
    if (parsed.hostname.endsWith('bing.com') && parsed.pathname === '/ck/a') {
      const wrapped = parsed.searchParams.get('u');
      if (!wrapped) return null;
      const encoded = wrapped.startsWith('a1') ? wrapped.slice(2) : wrapped;
      const decoded = Buffer.from(encoded, 'base64').toString('utf-8');
      return decoded.startsWith('http') ? decoded : null;
    }
    return href;
  } catch {
    return null;
  }
}

const NAUKRI_JOB_LISTING_PATTERN = /naukri\.com\/job-listings-/i;
const NAUKRI_HOST_PATTERN = /naukri\.com/i;
const INDEED_JOB_LINK_PATTERN = /indeed\.com\/rc\/clk/i;
const INDEED_HOST_PATTERN = /indeed\.com/i;

function extractJobLinks(hrefs, collected) {
  for (const rawHref of hrefs) {
    if (!rawHref.startsWith('http')) continue;

    const href = resolveRealUrl(rawHref);
    if (!href || !href.startsWith('http')) continue;
    if (EXCLUDED_HOST_PATTERNS.some((pattern) => pattern.test(href))) continue;

    // Naukri's own pages are full of generic "browse by category/city" nav
    // links (/it-jobs, /jobs-in-mumbai, ...) that match the career-page
    // pattern just as well as a real posting does, and they appear earlier in
    // the DOM than actual listings - so without this they fill up the result
    // cap before a single real job is ever reached. Only accept Naukri URLs
    // that are actual job-listing detail pages.
    if (NAUKRI_HOST_PATTERN.test(href) && !NAUKRI_JOB_LISTING_PATTERN.test(href)) continue;

    // Same idea for Indeed: only its /rc/clk redirect links are real postings
    // (e.g. /career/.../salaries/... pages are not). Note: navigating straight
    // to Indeed's canonical /viewjob?jk=... URL (bypassing the /rc/clk
    // redirect) trips Indeed's Cloudflare bot check, so the original /rc/clk
    // URL - tracking params and all - has to be kept and used for navigation.
    if (INDEED_HOST_PATTERN.test(href) && !INDEED_JOB_LINK_PATTERN.test(href)) continue;

    const isAtsLink = ATS_HOST_PATTERNS.some((pattern) => pattern.test(href));
    const looksLikeCareerPage = CAREER_PAGE_PATTERN.test(href);

    if (isAtsLink || looksLikeCareerPage) {
      const cleanUrl = href.split('&sa=')[0].split('&ved=')[0];
      if (!collected.has(cleanUrl) && collected.size < MAX_RESULTS) {
        collected.set(cleanUrl, {
          url: cleanUrl,
          source: isAtsLink ? 'ats' : 'career-page',
          dedupeKey: buildDedupeKey(cleanUrl),
        });
      }
    }
  }
}

// Indeed's /rc/clk URLs carry per-session tracking params (bb=, xkcb=, ...)
// that change on every search, so the exact URL can't be used to detect "we
// already tried this job" across runs. Its 'jk' param is the stable job id,
// so that becomes the dedupe key instead; every other source still dedupes
// on the URL itself, unchanged.
function buildDedupeKey(url) {
  if (INDEED_JOB_LINK_PATTERN.test(url)) {
    try {
      const jk = new URL(url).searchParams.get('jk');
      if (jk) return `indeed:${jk}`;
    } catch {
      // fall through to using the URL itself
    }
  }
  return url;
}

module.exports = { fetchJobLinks };
EOF

# ---------------------------------------------------------------------------
cat > src/applier.js << 'EOF'
const { generateText } = require('./aiClient');

const NOT_FOUND_PATTERN =
  /page not found|404 error|job (has been closed|is no longer available|has expired)|this position has been filled|no longer accepting applications|posting has closed/i;

const FIELD_MATCHERS = [
  { key: 'name', labels: ['full name', 'your name', 'candidate name', 'applicant name', 'name'], value: (p) => p.name },
  { key: 'email', labels: ['email'], value: (p) => p.email },
  { key: 'phone', labels: ['phone', 'mobile', 'contact number'], value: (p) => p.phone },
  { key: 'location', labels: ['current location', 'location', 'city'], value: (p) => p.location },
  { key: 'notice', labels: ['notice period'], value: (p) => String(p.noticePeriod) },
  { key: 'linkedin', labels: ['linkedin'], value: (p) => p.linkedin },
  { key: 'ctc', labels: ['current ctc', 'expected ctc', 'expected salary', 'ctc'], value: (p) => p.expectedCtc },
];

const SUBMIT_SELECTOR =
  'button:has-text("submit application"), button:has-text("apply now"), button:has-text("submit"), ' +
  'button:has-text("apply"), button:has-text("send application"), input[type="submit"]';

const UPLOAD_TRIGGER_SELECTOR =
  'button:has-text("upload"), button:has-text("attach"), a:has-text("upload resume"), a:has-text("attach resume")';

async function applyToJobPage(page, jobUrl, profile, resumePath) {
  const result = {
    applied: false,
    company: 'Unknown',
    role: 'Unknown',
    url: jobUrl,
    timestamp: new Date().toISOString(),
  };

  try {
    const response = await page.goto(jobUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });

    if (response && [404, 410, 500, 502, 503].includes(response.status())) {
      result.reason = `HTTP ${response.status()}`;
      return result;
    }

    const bodyText = await page.locator('body').innerText().catch(() => '');
    if (NOT_FOUND_PATTERN.test(bodyText)) {
      result.reason = 'Listing expired or not found';
      return result;
    }

    result.role = await extractTitle(page);
    result.company = extractCompany(jobUrl);

    await fillTextInputs(page, profile);
    await fillTextAreas(page, profile);
    await uploadResume(page, resumePath);
    await revealStickyElements(page);

    const submitResult = await clickSubmit(page);
    if (!submitResult.success) {
      result.reason = submitResult.reason;
      return result;
    }

    result.applied = true;
    return result;
  } catch (err) {
    result.reason = err.message;
    return result;
  }
}

async function extractTitle(page) {
  const h1Text = await page.locator('h1').first().innerText().catch(() => '');
  if (h1Text && h1Text.trim()) return h1Text.trim();

  const titleText = await page.title().catch(() => '');
  return titleText ? titleText.trim() : 'Unknown Role';
}

function extractCompany(jobUrl) {
  try {
    const hostname = new URL(jobUrl).hostname.replace(/^www\./, '');
    const parts = hostname.split('.');
    return parts.length > 1 ? parts[parts.length - 2] : hostname;
  } catch {
    return 'Unknown';
  }
}

async function fillTextInputs(page, profile) {
  const inputs = await page
    .locator('input[type="text"], input[type="email"], input[type="tel"], input:not([type])')
    .all();

  for (const input of inputs) {
    const descriptor = await getFieldDescriptor(page, input);
    const match = FIELD_MATCHERS.find((matcher) => matcher.labels.some((label) => descriptor.includes(label)));
    if (!match) continue;

    const value = match.value(profile);
    if (!value) continue;

    try {
      await input.fill(String(value), { timeout: 3000 });
    } catch {
      // field was hidden, disabled, or readonly; skip it and move on
    }
  }
}

async function getFieldDescriptor(page, locator) {
  const [name, id, placeholder, ariaLabel] = await Promise.all([
    locator.getAttribute('name').catch(() => null),
    locator.getAttribute('id').catch(() => null),
    locator.getAttribute('placeholder').catch(() => null),
    locator.getAttribute('aria-label').catch(() => null),
  ]);

  let labelText = '';
  if (id) {
    labelText = await page
      .locator(`label[for="${id}"]`)
      .innerText()
      .catch(() => '');
  }

  return [name, id, placeholder, ariaLabel, labelText]
    .filter(Boolean)
    .join(' ')
    .toLowerCase();
}

async function fillTextAreas(page, profile) {
  const allTextAreas = await page.locator('textarea').all();
  if (allTextAreas.length === 0) return;

  const pageContext = await page
    .locator('body')
    .innerText()
    .then((text) => text.slice(0, 1500))
    .catch(() => '');

  for (const textarea of allTextAreas) {
    const question = await getFieldDescriptor(page, textarea);
    const answer = await buildCoverLetterAnswer(profile, question, pageContext);

    try {
      await textarea.fill(answer, { timeout: 3000 });
    } catch {
      // textarea was hidden or disabled; skip it
    }
  }
}

async function buildCoverLetterAnswer(profile, question, pageContext) {
  const prompt = buildCoverLetterPrompt(profile, question, pageContext);
  const aiAnswer = await generateText(prompt);
  return aiAnswer || profile.summary;
}

function buildCoverLetterPrompt(profile, question, pageContext) {
  const skillList = (profile.skills || []).slice(0, 8).join(', ');
  return [
    `You are ${profile.name}, a Software Developer with 3+ years of experience in the MERN stack (${skillList}).`,
    'You are filling out a job application form. Here is context scraped from the job posting page:',
    pageContext || '(no additional context available)',
    `The application form field asks: "${question || 'Tell us about yourself / why you are a good fit for this role'}"`,
    'Write a concise, professional, first-person answer (3-5 sentences) suitable to paste directly into this form field. Do not use markdown formatting and do not restate the question.',
  ].join('\n\n');
}

async function uploadResume(page, resumePath) {
  const fileInputs = await page.locator('input[type="file"]').all();

  if (fileInputs.length > 0) {
    for (const fileInput of fileInputs) {
      try {
        await fileInput.setInputFiles(resumePath, { timeout: 5000 });
      } catch {
        // this particular file input could not accept the file; skip it
      }
    }
    return;
  }

  const uploadTrigger = page.locator(UPLOAD_TRIGGER_SELECTOR).first();
  const triggerVisible = await uploadTrigger.isVisible().catch(() => false);
  if (!triggerVisible) return;

  try {
    const [chooser] = await Promise.all([
      page.waitForEvent('filechooser', { timeout: 5000 }),
      uploadTrigger.click(),
    ]);
    await chooser.setFiles(resumePath);
  } catch {
    // clicking the trigger did not open a native file chooser; skip the upload
  }
}

async function revealStickyElements(page) {
  // Some sites (e.g. Naukri) render their real "Apply" button inside a sticky
  // header that stays at 0x0 size until the page is scrolled - before that it
  // technically exists in the DOM but Playwright correctly treats it as not
  // visible, so the submit step would otherwise always report "not found".
  try {
    await page.mouse.wheel(0, 400);
    await page.waitForTimeout(800);
  } catch {
    // scrolling isn't essential; continue regardless
  }
}

const LOGIN_PROMPT_SELECTOR =
  'text=/continue with google|sign in to continue|log ?in to apply|enter your password|sign in with google/i';

// Some platforms (e.g. Indeed) hand off "Apply" to their own proprietary,
// multi-step apply wizard on a separate subdomain (resume confirmation,
// screening questions, etc.) rather than a plain single-page form. This bot
// only fills single-page forms, so landing there means nothing was actually
// submitted yet - it must not be logged as a success.
const MULTI_STEP_APPLY_HOST_PATTERN = /smartapply\.indeed\.com|indeedapply/i;

async function clickSubmit(page) {
  const submitButton = page.locator(SUBMIT_SELECTOR).first();
  const isVisible = await submitButton.isVisible().catch(() => false);
  if (!isVisible) return { success: false, reason: 'No submit button found' };

  try {
    await submitButton.click({ timeout: 5000 });
  } catch {
    return { success: false, reason: 'Could not click submit button' };
  }

  await page.waitForTimeout(2000);

  // Some sites (e.g. Naukri) only let you apply once logged into THEIR account
  // specifically - being signed into the underlying Chrome/Google profile isn't
  // enough. Clicking "Apply" there just surfaces a login prompt instead of
  // submitting anything, so treat that as a non-application rather than a success.
  const loginRequired = await page.locator(LOGIN_PROMPT_SELECTOR).first().isVisible().catch(() => false);
  if (loginRequired) {
    return { success: false, reason: 'Site requires logging into its own account before applying' };
  }

  if (MULTI_STEP_APPLY_HOST_PATTERN.test(page.url())) {
    return { success: false, reason: "Redirected to the site's own multi-step apply flow - needs manual completion" };
  }

  return { success: true };
}

module.exports = { applyToJobPage };
EOF

# ---------------------------------------------------------------------------
cat > src/index.js << 'EOF'
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

function waitForEnter(promptText) {
  return new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    rl.question(promptText, () => {
      rl.close();
      resolve();
    });
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
EOF

# ---------------------------------------------------------------------------
cat > start.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

CHROME_USER_DATA_DIR="$HOME/.config/google-chrome"
CHROME_BIN_PATTERN="/opt/google/chrome/chrome"

if pgrep -f "$CHROME_BIN_PATTERN" > /dev/null 2>&1; then
  echo "[start.sh] Your real Chrome browser is currently running."
  echo "[start.sh] This bot reuses your actual Chrome profile (so it has your saved logins for"
  echo "[start.sh] Naukri/LinkedIn/Indeed etc.), and Chrome will not let a second instance open"
  echo "[start.sh] on the same profile while one is already running."
  read -r -p "[start.sh] Close all open Chrome windows now and continue? Unsaved Chrome tabs/work will be lost. [y/N] " answer
  case "$answer" in
    [yY][eE][sS]|[yY])
      echo "[start.sh] Closing Chrome..."
      pkill -15 -f "$CHROME_BIN_PATTERN" 2>/dev/null || true
      sleep 2
      pkill -9 -f "$CHROME_BIN_PATTERN" 2>/dev/null || true
      sleep 1
      ;;
    *)
      echo "[start.sh] Aborting. Close Chrome yourself and re-run, or re-run and answer 'y'."
      exit 1
      ;;
  esac
fi

echo "[start.sh] Clearing stale Chrome profile lock files..."
rm -f "$CHROME_USER_DATA_DIR"/SingletonLock "$CHROME_USER_DATA_DIR"/SingletonCookie "$CHROME_USER_DATA_DIR"/SingletonSocket 2>/dev/null || true

if [ ! -f "resume.pdf" ]; then
  echo "[start.sh] ERROR: resume.pdf not found in $(pwd). Place your resume there before running." >&2
  exit 1
fi

if [ ! -f "config.json" ]; then
  echo "[start.sh] ERROR: config.json not found. Copy config.example.json to config.json and edit it first." >&2
  exit 1
fi

if [ ! -f ".env" ]; then
  echo "[start.sh] WARNING: .env not found. Gemini AI features will be disabled; the bot will fall back to local (non-AI) logic."
fi

if [ ! -d "node_modules" ]; then
  echo "[start.sh] Installing dependencies..."
  npm install
fi

echo "[start.sh] Starting Job Application Bot..."
node src/index.js
EOF
chmod +x start.sh

echo "[setup] Installing npm dependencies..."
npm install

echo "[setup] Running syntax checks (node -c) on all generated JS files..."
for f in src/*.js; do
  echo "  - checking $f"
  node -c "$f"
done

echo "[setup] Done. Files written, dependencies installed, syntax checks passed."
echo "[setup] Next steps:"
echo "  1. Copy your resume to: $PROJECT_DIR/resume.pdf"
echo "  2. Make sure .env has a valid GEMINI_API_KEY (see .env.example if you don't have one yet)"
echo "  3. Run: ./start.sh"
