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
