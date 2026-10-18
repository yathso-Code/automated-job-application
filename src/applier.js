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
