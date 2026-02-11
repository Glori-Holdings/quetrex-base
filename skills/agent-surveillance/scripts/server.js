#!/usr/bin/env node

const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execSync } = require('child_process');

// ============================================================================
// CONFIGURATION
// ============================================================================

const PORT = 3847;
const HOME_DIR = os.homedir();
const TEAMS_DIR = path.join(HOME_DIR, '.claude', 'teams');
const TASKS_DIR = path.join(HOME_DIR, '.claude', 'tasks');
const DATA_DIR = path.join(HOME_DIR, '.claude', 'skills', 'agent-surveillance', 'data');
const DB_PATH = path.join(DATA_DIR, 'sessions.db');

// Ensure data directory exists
if (!fs.existsSync(DATA_DIR)) {
  fs.mkdirSync(DATA_DIR, { recursive: true });
}

// ============================================================================
// SQLITE SETUP (with graceful degradation)
// ============================================================================

let db = null;
let usingSqlite = false;

try {
  const Database = require('better-sqlite3');
  db = new Database(DB_PATH);
  usingSqlite = true;

  // Initialize schema
  db.exec(`
    CREATE TABLE IF NOT EXISTS sessions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      team_name TEXT UNIQUE NOT NULL,
      started_at TEXT NOT NULL,
      ended_at TEXT,
      created_at TEXT DEFAULT CURRENT_TIMESTAMP
    );

    CREATE TABLE IF NOT EXISTS agents (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id INTEGER NOT NULL,
      agent_name TEXT NOT NULL,
      agent_type TEXT,
      model TEXT,
      is_lead INTEGER DEFAULT 0,
      FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE,
      UNIQUE(session_id, agent_name)
    );

    CREATE TABLE IF NOT EXISTS messages (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id INTEGER NOT NULL,
      inbox_agent TEXT NOT NULL,
      from_agent TEXT NOT NULL,
      text TEXT NOT NULL,
      timestamp TEXT NOT NULL,
      is_read INTEGER DEFAULT 0,
      FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS tasks (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id INTEGER NOT NULL,
      task_id TEXT NOT NULL,
      subject TEXT,
      status TEXT,
      owner TEXT,
      description TEXT,
      blocked_by TEXT,
      blocks TEXT,
      last_updated TEXT NOT NULL,
      FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS agent_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id INTEGER NOT NULL,
      agent_name TEXT NOT NULL,
      event_type TEXT NOT NULL,
      timestamp TEXT NOT NULL,
      FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
    );

    CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_dedup
      ON messages(session_id, inbox_agent, from_agent, timestamp);

    CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_dedup
      ON tasks(session_id, task_id);
  `);

  console.log('✓ SQLite initialized:', DB_PATH);
} catch (err) {
  console.warn('⚠ SQLite unavailable (memory-only mode):', err.message);
}

// ============================================================================
// STATE MANAGEMENT
// ============================================================================

const state = {
  teams: {},      // { "team-name": { name, members: [...] } }
  inboxes: {},    // { "team/agent": [...messages] }
  tasks: {}       // { "team/taskId": { id, subject, status, owner, ... } }
};

const sseClients = [];

// ============================================================================
// UTILITY FUNCTIONS
// ============================================================================

function debounce(fn, delay = 200) {
  let timer = null;
  return function(...args) {
    clearTimeout(timer);
    timer = setTimeout(() => fn(...args), delay);
  };
}

function readJsonFile(filePath) {
  try {
    const content = fs.readFileSync(filePath, 'utf8');
    return JSON.parse(content);
  } catch (err) {
    return null;
  }
}

function broadcastSSE(event) {
  const data = JSON.stringify(event);
  sseClients.forEach(client => {
    try {
      client.write(`data: ${data}\n\n`);
    } catch (err) {
      // Client disconnected, will be cleaned up
    }
  });
}

// ============================================================================
// FILE SCANNING
// ============================================================================

function scanTeamsDirectory() {
  if (!fs.existsSync(TEAMS_DIR)) {
    return;
  }

  const currentTeams = new Set();

  try {
    const teamDirs = fs.readdirSync(TEAMS_DIR);

    for (const teamName of teamDirs) {
      const teamPath = path.join(TEAMS_DIR, teamName);
      const configPath = path.join(teamPath, 'config.json');

      if (!fs.existsSync(configPath)) continue;

      const config = readJsonFile(configPath);
      if (!config) continue;

      currentTeams.add(teamName);

      const members = (config.members || []).map(m => ({
        name: m.name,
        agentType: m.agentType || m.agent_type || 'general-purpose',
        model: m.model || 'claude-sonnet-4-5-20250929',
        isLead: m.isLead || m.is_lead || false
      }));

      const existingTeam = state.teams[teamName];
      const hasChanged = !existingTeam || JSON.stringify(existingTeam.members) !== JSON.stringify(members);

      state.teams[teamName] = { name: teamName, members };

      if (hasChanged) {
        // Persist to SQLite
        if (db) {
          const session = db.prepare('SELECT id FROM sessions WHERE team_name = ?').get(teamName);
          let sessionId;

          if (!session) {
            const result = db.prepare('INSERT INTO sessions (team_name, started_at) VALUES (?, ?)').run(
              teamName,
              new Date().toISOString()
            );
            sessionId = result.lastInsertRowid;
          } else {
            sessionId = session.id;
          }

          // Upsert agents
          const insertAgent = db.prepare(`
            INSERT OR REPLACE INTO agents (session_id, agent_name, agent_type, model, is_lead)
            VALUES (?, ?, ?, ?, ?)
          `);

          for (const member of members) {
            insertAgent.run(sessionId, member.name, member.agentType, member.model, member.isLead ? 1 : 0);
          }
        }

        broadcastSSE({ type: 'team_updated', team: teamName, data: state.teams[teamName] });
      }

      // Scan inboxes for this team
      scanInboxesForTeam(teamName, teamPath);
    }

    // Detect removed teams
    const removedTeams = Object.keys(state.teams).filter(t => !currentTeams.has(t));
    for (const teamName of removedTeams) {
      delete state.teams[teamName];

      // Mark session as ended
      if (db) {
        db.prepare('UPDATE sessions SET ended_at = ? WHERE team_name = ? AND ended_at IS NULL').run(
          new Date().toISOString(),
          teamName
        );
      }

      broadcastSSE({ type: 'team_removed', team: teamName });
    }
  } catch (err) {
    console.error('Error scanning teams:', err);
  }
}

function scanInboxesForTeam(teamName, teamPath) {
  const inboxPath = path.join(teamPath, 'inbox');
  if (!fs.existsSync(inboxPath)) return;

  try {
    const agentDirs = fs.readdirSync(inboxPath);

    for (const agentName of agentDirs) {
      const agentInboxPath = path.join(inboxPath, agentName);
      const stat = fs.statSync(agentInboxPath);
      if (!stat.isDirectory()) continue;

      const key = `${teamName}/${agentName}`;
      const messages = [];

      const messageFiles = fs.readdirSync(agentInboxPath);
      for (const file of messageFiles) {
        if (!file.endsWith('.json')) continue;

        const msgPath = path.join(agentInboxPath, file);
        const msg = readJsonFile(msgPath);
        if (msg) {
          messages.push({
            from: msg.from || 'unknown',
            text: msg.text || msg.message || '',
            timestamp: msg.timestamp || new Date().toISOString()
          });
        }
      }

      // Sort by timestamp
      messages.sort((a, b) => new Date(a.timestamp) - new Date(b.timestamp));

      const hasChanged = !state.inboxes[key] || JSON.stringify(state.inboxes[key]) !== JSON.stringify(messages);
      state.inboxes[key] = messages;

      if (hasChanged && db) {
        // Persist messages
        const session = db.prepare('SELECT id FROM sessions WHERE team_name = ?').get(teamName);
        if (session) {
          const insertMsg = db.prepare(`
            INSERT OR REPLACE INTO messages (session_id, inbox_agent, from_agent, text, timestamp)
            VALUES (?, ?, ?, ?, ?)
          `);

          for (const msg of messages) {
            try {
              insertMsg.run(session.id, agentName, msg.from, msg.text, msg.timestamp);
            } catch (err) {
              // Duplicate, skip
            }
          }
        }
      }

      if (hasChanged) {
        broadcastSSE({ type: 'inbox_updated', team: teamName, key, data: messages });
      }
    }
  } catch (err) {
    console.error('Error scanning inboxes for', teamName, err);
  }
}

function scanTasksDirectory() {
  if (!fs.existsSync(TASKS_DIR)) {
    return;
  }

  try {
    const teamDirs = fs.readdirSync(TASKS_DIR);
    const currentTasks = new Set();

    for (const teamName of teamDirs) {
      const teamTaskPath = path.join(TASKS_DIR, teamName);
      const stat = fs.statSync(teamTaskPath);
      if (!stat.isDirectory()) continue;

      const taskFiles = fs.readdirSync(teamTaskPath);

      for (const file of taskFiles) {
        if (!file.endsWith('.json')) continue;

        const taskPath = path.join(teamTaskPath, file);
        const task = readJsonFile(taskPath);
        if (!task || !task.id) continue;

        const key = `${teamName}/${task.id}`;
        currentTasks.add(key);

        const taskData = {
          id: task.id,
          subject: task.subject || '',
          status: task.status || 'pending',
          owner: task.owner || task.assignedTo || '',
          description: task.description || '',
          blockedBy: task.blockedBy || task.blocked_by || '',
          blocks: task.blocks || ''
        };

        const hasChanged = !state.tasks[key] || JSON.stringify(state.tasks[key]) !== JSON.stringify(taskData);
        state.tasks[key] = taskData;

        if (hasChanged && db) {
          const session = db.prepare('SELECT id FROM sessions WHERE team_name = ?').get(teamName);
          if (session) {
            db.prepare(`
              INSERT OR REPLACE INTO tasks
              (session_id, task_id, subject, status, owner, description, blocked_by, blocks, last_updated)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            `).run(
              session.id, task.id, taskData.subject, taskData.status,
              taskData.owner, taskData.description, taskData.blockedBy,
              taskData.blocks, new Date().toISOString()
            );
          }
        }

        if (hasChanged) {
          broadcastSSE({ type: 'task_updated', team: teamName, key, data: taskData });
        }
      }
    }

    // Detect deleted tasks
    const removedTasks = Object.keys(state.tasks).filter(k => !currentTasks.has(k));
    for (const key of removedTasks) {
      delete state.tasks[key];
      broadcastSSE({ type: 'task_deleted', key });
    }
  } catch (err) {
    console.error('Error scanning tasks:', err);
  }
}

// ============================================================================
// WATCHERS
// ============================================================================

function startWatching() {
  // Poll every 2 seconds (reliable fallback)
  setInterval(() => {
    scanTeamsDirectory();
    scanTasksDirectory();
  }, 2000);

  // Also use fs.watch for instant updates (when it works)
  if (fs.existsSync(TEAMS_DIR)) {
    try {
      fs.watch(TEAMS_DIR, { recursive: true }, debounce(() => {
        scanTeamsDirectory();
      }));
    } catch (err) {
      console.warn('fs.watch failed for teams, using polling only');
    }
  }

  if (fs.existsSync(TASKS_DIR)) {
    try {
      fs.watch(TASKS_DIR, { recursive: true }, debounce(() => {
        scanTasksDirectory();
      }));
    } catch (err) {
      console.warn('fs.watch failed for tasks, using polling only');
    }
  }

  // Initial scan
  scanTeamsDirectory();
  scanTasksDirectory();
}

// ============================================================================
// HTTP SERVER
// ============================================================================

function parseBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', chunk => { body += chunk.toString(); });
    req.on('end', () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch (err) {
        resolve({});
      }
    });
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const pathname = url.pathname;
  const method = req.method;

  // CORS headers
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (method === 'OPTIONS') {
    res.writeHead(200);
    res.end();
    return;
  }

  // Route: GET /
  if (pathname === '/' && method === 'GET') {
    res.writeHead(200, {
      'Content-Type': 'text/html',
      'Cache-Control': 'no-store, no-cache, must-revalidate'
    });
    res.end(getHTML());
    return;
  }

  // Route: GET /api/state
  if (pathname === '/api/state' && method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(state));
    return;
  }

  // Route: GET /api/events (SSE)
  if (pathname === '/api/events' && method === 'GET') {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive'
    });

    sseClients.push(res);

    // Send initial full state
    res.write(`data: ${JSON.stringify({ type: 'full_state', data: state })}\n\n`);

    req.on('close', () => {
      const idx = sseClients.indexOf(res);
      if (idx !== -1) sseClients.splice(idx, 1);
    });
    return;
  }

  // Route: GET /api/sessions
  if (pathname === '/api/sessions' && method === 'GET') {
    if (!db) {
      res.writeHead(503, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'SQLite not available' }));
      return;
    }

    const sessions = db.prepare(`
      SELECT
        s.id, s.team_name, s.started_at, s.ended_at,
        COUNT(DISTINCT a.id) as agent_count,
        COUNT(DISTINCT m.id) as message_count,
        COUNT(DISTINCT t.id) as task_count
      FROM sessions s
      LEFT JOIN agents a ON a.session_id = s.id
      LEFT JOIN messages m ON m.session_id = s.id
      LEFT JOIN tasks t ON t.session_id = s.id
      GROUP BY s.id
      ORDER BY s.started_at DESC
    `).all();

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(sessions));
    return;
  }

  // Route: GET /api/sessions/:id
  if (pathname.startsWith('/api/sessions/') && method === 'GET' && !pathname.includes('/messages') && !pathname.includes('/tasks')) {
    if (!db) {
      res.writeHead(503, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'SQLite not available' }));
      return;
    }

    const id = pathname.split('/')[3];
    const session = db.prepare('SELECT * FROM sessions WHERE id = ?').get(id);

    if (!session) {
      res.writeHead(404, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Session not found' }));
      return;
    }

    const agents = db.prepare('SELECT * FROM agents WHERE session_id = ?').all(id);

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ...session, agents }));
    return;
  }

  // Route: GET /api/sessions/:id/messages
  if (pathname.match(/^\/api\/sessions\/[0-9]+\/messages$/) && method === 'GET') {
    if (!db) {
      res.writeHead(503, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'SQLite not available' }));
      return;
    }

    const id = pathname.split('/')[3];
    const limit = parseInt(url.searchParams.get('limit') || '100', 10);
    const offset = parseInt(url.searchParams.get('offset') || '0', 10);

    const messages = db.prepare(`
      SELECT * FROM messages
      WHERE session_id = ?
      ORDER BY timestamp ASC
      LIMIT ? OFFSET ?
    `).all(id, limit, offset);

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(messages));
    return;
  }

  // Route: GET /api/sessions/:id/tasks
  if (pathname.match(/^\/api\/sessions\/[0-9]+\/tasks$/) && method === 'GET') {
    if (!db) {
      res.writeHead(503, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'SQLite not available' }));
      return;
    }

    const id = pathname.split('/')[3];
    const tasks = db.prepare('SELECT * FROM tasks WHERE session_id = ? ORDER BY last_updated DESC').all(id);

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(tasks));
    return;
  }

  // Route: DELETE /api/sessions/:id
  if (pathname.match(/^\/api\/sessions\/[0-9]+$/) && method === 'DELETE') {
    if (!db) {
      res.writeHead(503, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'SQLite not available' }));
      return;
    }

    const id = pathname.split('/')[3];
    db.prepare('DELETE FROM sessions WHERE id = ?').run(id);

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ success: true }));
    return;
  }

  // Route: POST /api/messages/:id/read
  if (pathname.match(/^\/api\/messages\/[0-9]+\/read$/) && method === 'POST') {
    if (!db) {
      res.writeHead(503, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'SQLite not available' }));
      return;
    }

    const id = pathname.split('/')[3];
    db.prepare('UPDATE messages SET is_read = 1 WHERE id = ?').run(id);

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ success: true }));
    return;
  }

  // Route: POST /api/threads/read
  if (pathname === '/api/threads/read' && method === 'POST') {
    if (!db) {
      res.writeHead(503, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'SQLite not available' }));
      return;
    }

    const body = await parseBody(req);
    // Mark thread as read (implementation depends on thread_id format)

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ success: true }));
    return;
  }

  // 404
  res.writeHead(404, { 'Content-Type': 'text/plain' });
  res.end('Not Found');
});

// ============================================================================
// HTML TEMPLATE
// ============================================================================

function getHTML() {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Agent Surveillance Dashboard</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }

    :root {
      --bg1: #0f0f0f;
      --bg2: #1a1a1a;
      --bg3: #252525;
      --t1: #ffffff;
      --t2: #b0b0b0;
      --accent: #3b82f6;
      --border: #333;
      --success: #10b981;
      --warning: #f59e0b;
      --error: #ef4444;
    }

    :root[data-theme="light"] {
      --bg1: #ffffff;
      --bg2: #f5f5f5;
      --bg3: #e5e5e5;
      --t1: #0f0f0f;
      --t2: #525252;
      --border: #d4d4d4;
    }

    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: var(--bg1);
      color: var(--t1);
      overflow: hidden;
    }

    .container { display: flex; flex-direction: column; height: 100vh; }

    /* Header */
    header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 1rem 1.5rem;
      background: var(--bg2);
      border-bottom: 1px solid var(--border);
    }

    header h1 { font-size: 1.25rem; font-weight: 600; }

    .header-controls {
      display: flex;
      align-items: center;
      gap: 1rem;
    }

    .mode-toggle {
      display: flex;
      gap: 0.5rem;
    }

    .mode-btn {
      padding: 0.5rem 1rem;
      border: 1px solid var(--border);
      background: var(--bg3);
      color: var(--t1);
      border-radius: 0.375rem;
      cursor: pointer;
      font-size: 0.875rem;
      transition: all 0.2s;
    }

    .mode-btn.active {
      background: var(--accent);
      color: white;
      border-color: var(--accent);
    }

    .theme-toggle {
      padding: 0.5rem;
      border: 1px solid var(--border);
      background: var(--bg3);
      color: var(--t1);
      border-radius: 0.375rem;
      cursor: pointer;
      font-size: 1.25rem;
      line-height: 1;
    }

    .status-dot {
      width: 8px;
      height: 8px;
      border-radius: 50%;
      background: var(--success);
      animation: pulse 2s infinite;
    }

    @keyframes pulse {
      0%, 100% { opacity: 1; }
      50% { opacity: 0.5; }
    }

    /* Main Layout */
    .main-layout {
      display: flex;
      flex: 1;
      overflow: hidden;
    }

    .left-panel {
      width: 280px;
      background: var(--bg2);
      border-right: 1px solid var(--border);
      overflow-y: auto;
      padding: 1rem;
    }

    .right-panel {
      flex: 1;
      display: flex;
      flex-direction: column;
      overflow: hidden;
    }

    .messages-section {
      flex: 1;
      overflow-y: auto;
      padding: 1rem;
      border-bottom: 1px solid var(--border);
    }

    .tasks-section {
      height: 300px;
      overflow-y: auto;
      padding: 1rem;
      background: var(--bg2);
    }

    /* Agent Cards */
    .agent-card {
      padding: 1rem;
      background: var(--bg3);
      border: 1px solid var(--border);
      border-radius: 0.5rem;
      margin-bottom: 0.75rem;
      display: flex;
      align-items: center;
      gap: 0.75rem;
    }

    .agent-avatar {
      width: 48px;
      height: 48px;
      border-radius: 50%;
      display: flex;
      align-items: center;
      justify-content: center;
      font-weight: 600;
      font-size: 1.25rem;
      color: white;
      flex-shrink: 0;
    }

    .agent-info { flex: 1; }
    .agent-name { font-weight: 600; font-size: 0.875rem; }
    .agent-type { font-size: 0.75rem; color: var(--t2); margin-top: 0.25rem; }

    .leader-badge {
      background: var(--accent);
      color: white;
      font-size: 0.625rem;
      padding: 0.125rem 0.375rem;
      border-radius: 0.25rem;
      text-transform: uppercase;
      font-weight: 600;
    }

    /* Messages */
    .message-card {
      padding: 1rem;
      background: var(--bg3);
      border: 1px solid var(--border);
      border-radius: 0.5rem;
      margin-bottom: 0.75rem;
      cursor: pointer;
      transition: all 0.2s;
    }

    .message-card:hover {
      border-color: var(--accent);
      transform: translateY(-2px);
    }

    .message-header {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      margin-bottom: 0.5rem;
    }

    .message-avatar {
      width: 32px;
      height: 32px;
      border-radius: 50%;
      display: flex;
      align-items: center;
      justify-content: center;
      font-weight: 600;
      font-size: 0.875rem;
      color: white;
      flex-shrink: 0;
    }

    .message-meta {
      flex: 1;
      font-size: 0.875rem;
    }

    .message-route { font-weight: 600; }
    .message-time { color: var(--t2); font-size: 0.75rem; margin-top: 0.125rem; }

    .message-text {
      font-size: 0.875rem;
      line-height: 1.5;
      color: var(--t2);
    }

    .message-text.truncated {
      display: -webkit-box;
      -webkit-line-clamp: 3;
      -webkit-box-orient: vertical;
      overflow: hidden;
    }

    .show-more {
      color: var(--accent);
      font-size: 0.75rem;
      cursor: pointer;
      margin-top: 0.25rem;
      display: inline-block;
    }

    /* Protocol Cards */
    .protocol-card {
      background: linear-gradient(135deg, var(--bg3), var(--bg2));
      border-left: 3px solid var(--accent);
      padding: 0.75rem;
    }

    .protocol-header {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      margin-bottom: 0.5rem;
    }

    .protocol-icon { font-size: 1.25rem; }

    /* Task Board */
    .task-board {
      display: grid;
      grid-template-columns: repeat(3, 1fr);
      gap: 1rem;
      height: 100%;
    }

    .task-column {
      background: var(--bg3);
      border-radius: 0.5rem;
      padding: 1rem;
      overflow-y: auto;
    }

    .column-header {
      font-weight: 600;
      font-size: 0.875rem;
      margin-bottom: 0.75rem;
      display: flex;
      align-items: center;
      justify-content: space-between;
    }

    .column-count {
      background: var(--bg1);
      padding: 0.125rem 0.5rem;
      border-radius: 1rem;
      font-size: 0.75rem;
    }

    .task-card {
      padding: 0.75rem;
      background: var(--bg2);
      border: 1px solid var(--border);
      border-radius: 0.375rem;
      margin-bottom: 0.5rem;
      cursor: pointer;
      transition: all 0.2s;
    }

    .task-card:hover {
      border-color: var(--accent);
      transform: translateY(-2px);
    }

    .task-id {
      display: inline-block;
      background: var(--accent);
      color: white;
      font-size: 0.625rem;
      padding: 0.125rem 0.375rem;
      border-radius: 0.25rem;
      font-weight: 600;
      margin-bottom: 0.5rem;
    }

    .task-subject {
      font-size: 0.875rem;
      font-weight: 600;
      margin-bottom: 0.5rem;
    }

    .task-owner {
      font-size: 0.75rem;
      color: var(--t2);
    }

    /* History Mode */
    .history-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
      gap: 1rem;
      padding: 1rem;
    }

    .session-card {
      padding: 1.5rem;
      background: var(--bg3);
      border: 1px solid var(--border);
      border-radius: 0.5rem;
      cursor: pointer;
      transition: all 0.2s;
      position: relative;
    }

    .session-card:hover {
      border-color: var(--accent);
      transform: translateY(-4px);
    }

    .session-card:hover .delete-btn {
      opacity: 1;
    }

    .delete-btn {
      position: absolute;
      top: 0.5rem;
      right: 0.5rem;
      background: var(--error);
      color: white;
      border: none;
      border-radius: 0.25rem;
      padding: 0.25rem 0.5rem;
      font-size: 0.75rem;
      cursor: pointer;
      opacity: 0;
      transition: opacity 0.2s;
    }

    .session-team {
      font-size: 1.25rem;
      font-weight: 600;
      margin-bottom: 0.75rem;
    }

    .session-stats {
      display: flex;
      gap: 1rem;
      margin-bottom: 0.75rem;
      font-size: 0.875rem;
      color: var(--t2);
    }

    .session-dates {
      font-size: 0.75rem;
      color: var(--t2);
    }

    .ended-badge {
      display: inline-block;
      background: var(--error);
      color: white;
      font-size: 0.625rem;
      padding: 0.25rem 0.5rem;
      border-radius: 0.25rem;
      text-transform: uppercase;
      font-weight: 600;
      margin-left: 0.5rem;
    }

    /* History Banner */
    .history-banner {
      background: var(--accent);
      color: white;
      padding: 0.75rem 1.5rem;
      display: flex;
      align-items: center;
      justify-content: space-between;
    }

    .back-btn {
      background: rgba(255, 255, 255, 0.2);
      border: 1px solid rgba(255, 255, 255, 0.3);
      color: white;
      padding: 0.375rem 0.75rem;
      border-radius: 0.25rem;
      cursor: pointer;
      font-size: 0.875rem;
    }

    /* Modal */
    .modal-overlay {
      position: fixed;
      top: 0;
      left: 0;
      right: 0;
      bottom: 0;
      background: rgba(0, 0, 0, 0.7);
      backdrop-filter: blur(4px);
      display: flex;
      align-items: center;
      justify-content: center;
      z-index: 1000;
    }

    .modal {
      background: var(--bg2);
      border: 1px solid var(--border);
      border-radius: 0.5rem;
      width: 90%;
      max-width: 600px;
      max-height: 80vh;
      overflow-y: auto;
      padding: 1.5rem;
    }

    .modal-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 1rem;
      padding-bottom: 1rem;
      border-bottom: 1px solid var(--border);
    }

    .modal-title { font-size: 1.25rem; font-weight: 600; }

    .close-btn {
      background: none;
      border: none;
      color: var(--t1);
      font-size: 1.5rem;
      cursor: pointer;
      padding: 0;
      line-height: 1;
    }

    .section-title {
      font-size: 1rem;
      font-weight: 600;
      margin-bottom: 1rem;
      color: var(--t2);
      text-transform: uppercase;
      font-size: 0.75rem;
      letter-spacing: 0.05em;
    }

    /* Utility */
    .hidden { display: none !important; }
    .empty-state {
      text-align: center;
      padding: 3rem 1rem;
      color: var(--t2);
    }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <h1>Agent Surveillance Dashboard</h1>
      <div class="header-controls">
        <div class="mode-toggle">
          <button class="mode-btn active" data-mode="live">Live</button>
          <button class="mode-btn" data-mode="history">History</button>
        </div>
        <button class="theme-toggle" title="Toggle theme">☀</button>
        <div class="status-dot" title="Connected"></div>
      </div>
    </header>

    <div id="history-banner" class="history-banner hidden">
      <div id="history-banner-text"></div>
      <button class="back-btn" onclick="backToHistory()">← Back to History</button>
    </div>

    <div id="live-view" class="main-layout">
      <div class="left-panel">
        <div class="section-title">Agent Roster</div>
        <div id="agent-roster"></div>
      </div>
      <div class="right-panel">
        <div class="messages-section">
          <div class="section-title">Messages <span id="message-count"></span></div>
          <div id="messages-feed"></div>
        </div>
        <div class="tasks-section">
          <div class="section-title">Task Board</div>
          <div id="task-board" class="task-board">
            <div class="task-column">
              <div class="column-header">
                Pending <span class="column-count" id="pending-count">0</span>
              </div>
              <div id="pending-tasks"></div>
            </div>
            <div class="task-column">
              <div class="column-header">
                In Progress <span class="column-count" id="progress-count">0</span>
              </div>
              <div id="progress-tasks"></div>
            </div>
            <div class="task-column">
              <div class="column-header">
                Completed <span class="column-count" id="completed-count">0</span>
              </div>
              <div id="completed-tasks"></div>
            </div>
          </div>
        </div>
      </div>
    </div>

    <div id="history-view" class="hidden">
      <div id="history-list" class="history-grid"></div>
    </div>
  </div>

  <div id="thread-modal" class="modal-overlay hidden" onclick="closeModal(event)">
    <div class="modal" onclick="event.stopPropagation()">
      <div class="modal-header">
        <div class="modal-title" id="modal-title">Thread</div>
        <button class="close-btn" onclick="closeModal()">×</button>
      </div>
      <div id="modal-content"></div>
    </div>
  </div>

  <script>
    // =========================================================================
    // STATE
    // =========================================================================

    const AGENT_COLORS = [
      '#3b82f6', '#ef4444', '#10b981', '#f59e0b',
      '#8b5cf6', '#ec4899', '#14b8a6', '#f97316'
    ];

    let currentMode = 'live';
    let currentTheme = localStorage.getItem('theme') || 'dark';
    let liveState = { teams: {}, inboxes: {}, tasks: {} };
    let currentSessionId = null;
    let eventSource = null;

    // =========================================================================
    // INITIALIZATION
    // =========================================================================

    document.documentElement.setAttribute('data-theme', currentTheme);
    updateThemeIcon();

    fetch('/api/state')
      .then(r => r.json())
      .then(data => {
        liveState = data;
        renderLiveView();
      });

    startSSE();

    // =========================================================================
    // SSE
    // =========================================================================

    function startSSE() {
      if (eventSource) {
        eventSource.close();
      }

      eventSource = new EventSource('/api/events');

      eventSource.onmessage = function(ev) {
        const msg = JSON.parse(ev.data);

        // Only update if in live mode
        if (currentMode !== 'live') return;

        switch (msg.type) {
          case 'full_state':
            liveState = msg.data;
            renderLiveView();
            break;
          case 'team_updated':
            liveState.teams[msg.team] = msg.data;
            renderAgentRoster();
            break;
          case 'team_removed':
            delete liveState.teams[msg.team];
            renderLiveView();
            break;
          case 'inbox_updated':
            liveState.inboxes[msg.key] = msg.data;
            renderMessages();
            break;
          case 'task_updated':
            liveState.tasks[msg.key] = msg.data;
            renderTaskBoard();
            break;
          case 'task_deleted':
            delete liveState.tasks[msg.key];
            renderTaskBoard();
            break;
        }
      };

      eventSource.onerror = function() {
        console.warn('SSE connection lost, retrying in 3s...');
        setTimeout(startSSE, 3000);
      };
    }

    // =========================================================================
    // MODE SWITCHING
    // =========================================================================

    document.querySelectorAll('.mode-btn').forEach(btn => {
      btn.addEventListener('click', function() {
        const mode = this.getAttribute('data-mode');
        switchMode(mode);
      });
    });

    function switchMode(mode) {
      currentMode = mode;

      document.querySelectorAll('.mode-btn').forEach(btn => {
        btn.classList.toggle('active', btn.getAttribute('data-mode') === mode);
      });

      if (mode === 'live') {
        document.getElementById('live-view').classList.remove('hidden');
        document.getElementById('history-view').classList.add('hidden');
        document.getElementById('history-banner').classList.add('hidden');
        currentSessionId = null;
        renderLiveView();
      } else {
        document.getElementById('live-view').classList.add('hidden');
        document.getElementById('history-view').classList.remove('hidden');
        loadHistorySessions();
      }
    }

    // =========================================================================
    // THEME TOGGLE
    // =========================================================================

    document.querySelector('.theme-toggle').addEventListener('click', function() {
      currentTheme = currentTheme === 'dark' ? 'light' : 'dark';
      localStorage.setItem('theme', currentTheme);
      document.documentElement.setAttribute('data-theme', currentTheme);
      updateThemeIcon();
    });

    function updateThemeIcon() {
      document.querySelector('.theme-toggle').textContent = currentTheme === 'dark' ? '☀' : '🌙';
    }

    // =========================================================================
    // RENDERING - LIVE VIEW
    // =========================================================================

    function renderLiveView() {
      renderAgentRoster();
      renderMessages();
      renderTaskBoard();
    }

    function renderAgentRoster() {
      const container = document.getElementById('agent-roster');
      const teams = Object.values(liveState.teams);

      if (teams.length === 0) {
        container.innerHTML = '<div class="empty-state">No active teams</div>';
        return;
      }

      let html = '';
      let agentIndex = 0;

      teams.forEach(team => {
        team.members.forEach(agent => {
          const color = AGENT_COLORS[agentIndex % AGENT_COLORS.length];
          const initial = agent.name[0].toUpperCase();

          html += ${"`"}
            <div class="agent-card">
              <div class="agent-avatar" style="background: ${'$'}{color}">${'$'}{initial}</div>
              <div class="agent-info">
                <div class="agent-name">${'$'}{agent.name}</div>
                <div class="agent-type">${'$'}{agent.agentType}</div>
              </div>
              ${'$'}{agent.isLead ? '<div class="leader-badge">Lead</div>' : ''}
            </div>
          ${"`"};

          agentIndex++;
        });
      });

      container.innerHTML = html;
    }

    function renderMessages() {
      const container = document.getElementById('messages-feed');
      const allMessages = [];

      Object.entries(liveState.inboxes).forEach(([key, messages]) => {
        const [team, agent] = key.split('/');
        messages.forEach(msg => {
          allMessages.push({ ...msg, toAgent: agent, team });
        });
      });

      allMessages.sort((a, b) => new Date(a.timestamp) - new Date(b.timestamp));

      document.getElementById('message-count').textContent = ${"`"}(${'$'}{allMessages.length})${"`"};

      if (allMessages.length === 0) {
        container.innerHTML = '<div class="empty-state">No messages yet</div>';
        return;
      }

      let html = '';
      allMessages.forEach((msg, idx) => {
        html += renderMessageCard(msg, idx);
      });

      container.innerHTML = html;
      container.scrollTop = container.scrollHeight;
    }

    function renderMessageCard(msg, idx) {
      const color = getAgentColor(msg.from);
      const initial = msg.from[0].toUpperCase();
      const timeAgo = formatTimeAgo(msg.timestamp);

      let text = msg.text;
      let isProtocol = false;

      try {
        const parsed = JSON.parse(msg.text);
        if (parsed.type) {
          isProtocol = true;
          text = renderProtocolMessage(parsed);
        }
      } catch (e) {
        text = renderMarkdown(text);
      }

      const cardClass = isProtocol ? 'message-card protocol-card' : 'message-card';

      return ${"`"}
        <div class="${'$'}{cardClass}" onclick="openThread('${'$'}{msg.from}', '${'$'}{msg.toAgent}')">
          <div class="message-header">
            <div class="message-avatar" style="background: ${'$'}{color}">${'$'}{initial}</div>
            <div class="message-meta">
              <div class="message-route">${'$'}{msg.from} → ${'$'}{msg.toAgent}</div>
              <div class="message-time">${'$'}{timeAgo}</div>
            </div>
          </div>
          <div class="message-text" id="msg-${'$'}{idx}">${'$'}{text}</div>
          ${'$'}{msg.text.length > 300 ? ${"`<div class=\"show-more\" onclick=\"event.stopPropagation(); toggleMessage(${'$'}{idx})\">Show more</div>`"} : ''}
        </div>
      ${"`"};
    }

    function renderProtocolMessage(parsed) {
      const icons = {
        task_assignment: '📋',
        idle_notification: '🌙',
        shutdown_request: '⏱️',
        shutdown_response: '⏱️',
        plan_approval_request: '📄'
      };

      const icon = icons[parsed.type] || '📨';

      return ${"`"}
        <div class="protocol-header">
          <span class="protocol-icon">${'$'}{icon}</span>
          <strong>${'$'}{parsed.type.replace(/_/g, ' ').toUpperCase()}</strong>
        </div>
        <div>${'$'}{JSON.stringify(parsed, null, 2)}</div>
      ${"`"};
    }

    function renderMarkdown(text) {
      // CRITICAL: Use character classes, never backslash escapes in template literals
      // Bold: **text**
      text = text.replace(/[*][*](.+?)[*][*]/g, '<strong>${'$'}1</strong>');
      // Italic: *text*
      text = text.replace(/[*](.+?)[*]/g, '<em>${'$'}1</em>');
      // Inline code: ${"`"}text${"`"}
      text = text.replace(/\x60(.+?)\x60/g, '<code>${'$'}1</code>');
      // Headings: # Heading
      text = text.replace(/^### (.+)$/gm, '<h3>${'$'}1</h3>');
      text = text.replace(/^## (.+)$/gm, '<h2>${'$'}1</h2>');
      text = text.replace(/^# (.+)$/gm, '<h1>${'$'}1</h1>');
      // Links: [text](url)
      text = text.replace(/[([]([^)\\]]+?)[)]([(]([^)]+?)[)])/g, '<a href="${'$'}2" target="_blank">${'$'}1</a>');
      // Line breaks
      text = text.replace(/\\n/g, '<br>');

      return text;
    }

    function toggleMessage(idx) {
      const el = document.getElementById(${"`msg-${'$'}{idx}`"});
      el.classList.toggle('truncated');
      event.target.textContent = el.classList.contains('truncated') ? 'Show more' : 'Show less';
    }

    function renderTaskBoard() {
      const pending = [];
      const progress = [];
      const completed = [];

      Object.values(liveState.tasks).forEach(task => {
        // Filter out system tasks (agent tracking)
        if (isSystemTask(task)) return;

        if (task.status === 'pending') pending.push(task);
        else if (task.status === 'in_progress') progress.push(task);
        else if (task.status === 'completed') completed.push(task);
      });

      document.getElementById('pending-count').textContent = pending.length;
      document.getElementById('progress-count').textContent = progress.length;
      document.getElementById('completed-count').textContent = completed.length;

      document.getElementById('pending-tasks').innerHTML = pending.map(renderTaskCard).join('');
      document.getElementById('progress-tasks').innerHTML = progress.map(renderTaskCard).join('');
      document.getElementById('completed-tasks').innerHTML = completed.map(renderTaskCard).join('');
    }

    function renderTaskCard(task) {
      return ${"`"}
        <div class="task-card">
          <div class="task-id">#${'$'}{task.id}</div>
          <div class="task-subject">${'$'}{task.subject}</div>
          ${'$'}{task.owner ? ${"`<div class=\"task-owner\">Owner: ${'$'}{task.owner}</div>`"} : ''}
        </div>
      ${"`"};
    }

    function isSystemTask(task) {
      const subjectLower = (task.subject || '').toLowerCase();
      const hasDescription = (task.description || '').trim().length > 0;

      // System tasks typically have subject matching agent name with no description
      return !hasDescription && subjectLower.length > 0 && /^[a-z-]+$/.test(subjectLower);
    }

    // =========================================================================
    // RENDERING - HISTORY VIEW
    // =========================================================================

    function loadHistorySessions() {
      fetch('/api/sessions')
        .then(r => r.json())
        .then(sessions => {
          const container = document.getElementById('history-list');

          if (sessions.length === 0) {
            container.innerHTML = '<div class="empty-state">No historical sessions</div>';
            return;
          }

          let html = '';
          sessions.forEach(session => {
            const startDate = new Date(session.started_at).toLocaleString();
            const endDate = session.ended_at ? new Date(session.ended_at).toLocaleString() : 'Active';

            html += ${"`"}
              <div class="session-card" onclick="loadSessionDetail(${'$'}{session.id})">
                <button class="delete-btn" onclick="event.stopPropagation(); deleteSession(${'$'}{session.id})">Delete</button>
                <div class="session-team">
                  ${'$'}{session.team_name}
                  ${'$'}{session.ended_at ? '<span class="ended-badge">Ended</span>' : ''}
                </div>
                <div class="session-stats">
                  <span>${'$'}{session.agent_count} agents</span>
                  <span>${'$'}{session.message_count} messages</span>
                  <span>${'$'}{session.task_count} tasks</span>
                </div>
                <div class="session-dates">
                  ${'$'}{startDate} → ${'$'}{endDate}
                </div>
              </div>
            ${"`"};
          });

          container.innerHTML = html;
        });
    }

    function loadSessionDetail(sessionId) {
      currentSessionId = sessionId;

      Promise.all([
        fetch(${"`/api/sessions/${'$'}{sessionId}`"}).then(r => r.json()),
        fetch(${"`/api/sessions/${'$'}{sessionId}/messages`"}).then(r => r.json()),
        fetch(${"`/api/sessions/${'$'}{sessionId}/tasks`"}).then(r => r.json())
      ]).then(([session, messages, tasks]) => {
        // Transform to state format
        liveState = {
          teams: {
            [session.team_name]: {
              name: session.team_name,
              members: session.agents.map(a => ({
                name: a.agent_name,
                agentType: a.agent_type,
                model: a.model,
                isLead: a.is_lead === 1
              }))
            }
          },
          inboxes: {},
          tasks: {}
        };

        // Group messages by inbox
        messages.forEach(msg => {
          const key = ${"`${'$'}{session.team_name}/${'$'}{msg.inbox_agent}`"};
          if (!liveState.inboxes[key]) liveState.inboxes[key] = [];
          liveState.inboxes[key].push({
            from: msg.from_agent,
            text: msg.text,
            timestamp: msg.timestamp
          });
        });

        // Transform tasks
        tasks.forEach(task => {
          const key = ${"`${'$'}{session.team_name}/${'$'}{task.task_id}`"};
          liveState.tasks[key] = {
            id: task.task_id,
            subject: task.subject,
            status: task.status,
            owner: task.owner,
            description: task.description,
            blockedBy: task.blocked_by,
            blocks: task.blocks
          };
        });

        // Show history banner
        const startDate = new Date(session.started_at).toLocaleDateString();
        const endDate = session.ended_at ? new Date(session.ended_at).toLocaleDateString() : 'Active';
        document.getElementById('history-banner-text').textContent =
          ${"`Viewing historical session — ${'$'}{session.team_name} — ${'$'}{startDate} to ${'$'}{endDate}`"};
        document.getElementById('history-banner').classList.remove('hidden');

        // Show live view with historical data
        document.getElementById('history-view').classList.add('hidden');
        document.getElementById('live-view').classList.remove('hidden');

        renderLiveView();
      });
    }

    function backToHistory() {
      currentSessionId = null;
      document.getElementById('history-banner').classList.add('hidden');
      document.getElementById('live-view').classList.add('hidden');
      document.getElementById('history-view').classList.remove('hidden');
      loadHistorySessions();
    }

    function deleteSession(sessionId) {
      if (!confirm('Delete this session? This will remove all messages, tasks, and agents.')) {
        return;
      }

      fetch(${"`/api/sessions/${'$'}{sessionId}`"}, { method: 'DELETE' })
        .then(() => {
          loadHistorySessions();
        });
    }

    // =========================================================================
    // THREAD MODAL
    // =========================================================================

    function openThread(from, to) {
      const modal = document.getElementById('thread-modal');
      const title = document.getElementById('modal-title');
      const content = document.getElementById('modal-content');

      title.textContent = ${"`Thread: ${'$'}{from} ↔ ${'$'}{to}`"};

      // Find all messages between these two agents
      const threadMessages = [];

      Object.entries(liveState.inboxes).forEach(([key, messages]) => {
        const [team, agent] = key.split('/');
        messages.forEach(msg => {
          if ((msg.from === from && agent === to) || (msg.from === to && agent === from)) {
            threadMessages.push({ ...msg, toAgent: agent, team });
          }
        });
      });

      threadMessages.sort((a, b) => new Date(a.timestamp) - new Date(b.timestamp));

      let html = '';
      threadMessages.forEach((msg, idx) => {
        html += renderMessageCard(msg, ${"`thread-${'$'}{idx}`"});
      });

      content.innerHTML = html || '<div class="empty-state">No messages in this thread</div>';
      modal.classList.remove('hidden');
    }

    function closeModal(event) {
      if (!event || event.target.classList.contains('modal-overlay') || event.target.classList.contains('close-btn')) {
        document.getElementById('thread-modal').classList.add('hidden');
      }
    }

    // =========================================================================
    // UTILITIES
    // =========================================================================

    function getAgentColor(agentName) {
      // Deterministic color based on agent name
      let hash = 0;
      for (let i = 0; i < agentName.length; i++) {
        hash = agentName.charCodeAt(i) + ((hash << 5) - hash);
      }
      return AGENT_COLORS[Math.abs(hash) % AGENT_COLORS.length];
    }

    function formatTimeAgo(timestamp) {
      const seconds = Math.floor((new Date() - new Date(timestamp)) / 1000);

      if (seconds < 60) return ${"`${'$'}{seconds}s ago`"};
      if (seconds < 3600) return ${"`${'$'}{Math.floor(seconds / 60)}m ago`"};
      if (seconds < 86400) return ${"`${'$'}{Math.floor(seconds / 3600)}h ago`"};
      return ${"`${'$'}{Math.floor(seconds / 86400)}d ago`"};
    }
  </script>
</body>
</html>`;
}

// ============================================================================
// SERVER STARTUP
// ============================================================================

server.listen(PORT, () => {
  console.log('');
  console.log('='.repeat(60));
  console.log('🔭 Agent Surveillance Dashboard');
  console.log('='.repeat(60));
  console.log('');
  console.log(`  Server running at: http://localhost:${PORT}`);
  console.log(`  Storage mode: ${usingSqlite ? 'SQLite' : 'Memory-only'}`);
  console.log(`  Teams directory: ${TEAMS_DIR}`);
  console.log(`  Tasks directory: ${TASKS_DIR}`);
  console.log('');
  console.log('='.repeat(60));
  console.log('');

  startWatching();

  // Auto-open browser
  const url = `http://localhost:${PORT}`;
  try {
    if (process.platform === 'darwin') {
      execSync(`open "${url}"`);
    } else if (process.platform === 'linux') {
      execSync(`xdg-open "${url}"`);
    } else if (process.platform === 'win32') {
      execSync(`start "${url}"`);
    }
  } catch (err) {
    console.log('Unable to auto-open browser. Please navigate to:', url);
  }
});

// Handle graceful shutdown
process.on('SIGINT', () => {
  console.log('\nShutting down gracefully...');
  if (db) db.close();
  server.close(() => {
    console.log('Server closed');
    process.exit(0);
  });
});
