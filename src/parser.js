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
