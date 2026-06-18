/**
 * vlc_media_logger.gs
 * Google Apps Script — receives GET requests from the VLC Lua extension
 * and appends a row to the active Google Sheet.
 *
 * ── SETUP ────────────────────────────────────────────────────────────────────
 * 1. Open Google Sheets → Extensions → Apps Script
 * 2. Paste this entire file, replacing any existing content.
 * 3. Click ▶ Run → "setupSheet" once to create the header row.
 * 4. Deploy:
 *      Deploy → New deployment
 *      Type: Web app
 *      Execute as: Me
 *      Who has access: Anyone   ← required for VLC to call it without OAuth
 *    Copy the deployment URL and paste it into vlc_media_logger.lua
 *    as APPS_SCRIPT_URL.
 * 5. On re-deploy after edits, always choose "New deployment" (not "Manage"),
 *    otherwise the URL won't reflect your changes.
 * ─────────────────────────────────────────────────────────────────────────────
 */

// ─── CONFIGURATION ────────────────────────────────────────────────────────────

// Name of the sheet tab to write to. Created automatically if missing.
const SHEET_NAME = "Watch Log";

// Column order written to the sheet.
// Allowed keys: timestamp, title, type, uri
// Remove or reorder freely — the header row will match.
const COLUMNS = ["timestamp", "title", "type", "uri"];

// Optional: duplicate guard window in minutes.
// If the same title was logged within this many minutes, skip it.
// Set to 0 to disable.
const DEDUP_WINDOW_MINUTES = 5;

// ─── END CONFIGURATION ────────────────────────────────────────────────────────


/**
 * Entry point — called by VLC's curl request.
 * All parameters arrive as URL query parameters.
 */
function doGet(e) {
  try {
    const params = e.parameter || {};

    const title     = params.title     || "(no title)";
    const mediaType = params.type      || "Unknown";
    const uri       = params.uri       || "";
    const timestamp = params.timestamp || new Date().toISOString();

    if (title === "(no title)" && uri === "") {
      return respond("error", "No title or URI provided");
    }

    const sheet = getOrCreateSheet();

    // Duplicate guard
    if (DEDUP_WINDOW_MINUTES > 0 && isDuplicate(sheet, title, DEDUP_WINDOW_MINUTES)) {
      return respond("skipped", "Duplicate within window: " + title);
    }

    // Build row in configured column order
    const rowData = COLUMNS.map(col => {
      switch (col) {
        case "timestamp": return timestamp;
        case "title":     return title;
        case "type":      return mediaType;
        case "uri":       return uri;
        default:          return "";
      }
    });

    sheet.appendRow(rowData);

    // Auto-resize columns once after the header row is written.
    if (sheet.getLastRow() === 2) {
      sheet.autoResizeColumns(1, COLUMNS.length);
    }

    return respond("ok", "Logged: " + title);

  } catch (err) {
    return respond("error", err.toString());
  }
}


// ─── HELPERS ─────────────────────────────────────────────────────────────────

/**
 * Returns the target sheet, creating it (with header row) if it doesn't exist.
 */
function getOrCreateSheet() {
  const ss    = SpreadsheetApp.getActiveSpreadsheet();
  let   sheet = ss.getSheetByName(SHEET_NAME);

  if (!sheet) {
    sheet = ss.insertSheet(SHEET_NAME);
    writeHeader(sheet);
  }
  return sheet;
}

/**
 * Writes the header row with formatting.
 */
function writeHeader(sheet) {
  const headers = COLUMNS.map(c => c.charAt(0).toUpperCase() + c.slice(1));
  sheet.appendRow(headers);

  const headerRange = sheet.getRange(1, 1, 1, headers.length);
  headerRange.setFontWeight("bold");
  headerRange.setBackground("#4A90D9");
  headerRange.setFontColor("#FFFFFF");
  sheet.setFrozenRows(1);
}

/**
 * Run this manually once via Apps Script editor to create the sheet + header.
 */
function setupSheet() {
  const sheet = getOrCreateSheet();
  SpreadsheetApp.getUi().alert("Sheet '" + SHEET_NAME + "' is ready.");
}

/**
 * Returns true if the same title appears in the last N rows within the time window.
 */
function isDuplicate(sheet, title, windowMinutes) {
  const lastRow = sheet.getLastRow();
  if (lastRow <= 1) return false; // only header

  // Check the last 20 rows at most (performance guard)
  const checkRows = Math.min(lastRow - 1, 20);
  const startRow  = lastRow - checkRows + 1;

  const titleCol = COLUMNS.indexOf("title") + 1;
  const tsCol    = COLUMNS.indexOf("timestamp") + 1;

  if (titleCol === 0 || tsCol === 0) return false;

  const data = sheet.getRange(startRow, 1, checkRows, COLUMNS.length).getValues();
  const now  = new Date();

  for (let i = data.length - 1; i >= 0; i--) {
    const rowTitle = data[i][titleCol - 1];
    const rowTs    = data[i][tsCol - 1];

    if (String(rowTitle).toLowerCase() !== String(title).toLowerCase()) continue;

    const rowDate = new Date(rowTs);
    if (isNaN(rowDate)) continue;

    const diffMinutes = (now - rowDate) / 1000 / 60;
    if (diffMinutes <= windowMinutes) return true;
  }

  return false;
}

/**
 * Returns a plain-text ContentService response.
 */
function respond(status, message) {
  return ContentService
    .createTextOutput(JSON.stringify({ status: status, message: message }))
    .setMimeType(ContentService.MimeType.JSON);
}
