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
