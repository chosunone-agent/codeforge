#!/usr/bin/env bun
/**
 * Test Harness for Suggestion Manager
 * 
 * Simulates neovim talking to OpenCode. Sends messages to the session
 * and receives events via SSE - exactly like neovim would.
 * 
 * Usage:
 *   bun run index.ts [--port PORT] [--host HOST]
 */

import * as readline from "readline";

// Parse command line arguments
const args = process.argv.slice(2);
let port = 4096;
let host = "localhost";

for (let i = 0; i < args.length; i++) {
  if (args[i] === "--port" && args[i + 1]) {
    port = parseInt(args[i + 1]!, 10);
    i++;
  } else if (args[i] === "--host" && args[i + 1]) {
    host = args[i + 1]!;
    i++;
  }
}

const baseUrl = `http://${host}:${port}`;

// Colors for terminal output
const c = {
  reset: "\x1b[0m",
  dim: "\x1b[2m",
  red: "\x1b[31m",
  green: "\x1b[32m",
  yellow: "\x1b[33m",
  blue: "\x1b[34m",
  magenta: "\x1b[35m",
  cyan: "\x1b[36m",
};

console.log(`\n${c.cyan}═══════════════════════════════════════════════════${c.reset}`);
console.log(`${c.cyan}  Suggestion Manager Test Harness${c.reset}`);
console.log(`${c.cyan}  Connecting to ${baseUrl}${c.reset}`);
console.log(`${c.cyan}═══════════════════════════════════════════════════${c.reset}\n`);

// Check server health
async function checkHealth(): Promise<boolean> {
  try {
    const res = await fetch(`${baseUrl}/global/health`);
    if (!res.ok) return false;
    const data = await res.json() as { healthy: boolean; version: string };
    console.log(`${c.green}✓ Server healthy${c.reset} (version: ${data.version})\n`);
    return true;
  } catch {
    console.error(`${c.red}✗ Cannot connect to server${c.reset}\n`);
    return false;
  }
}

// Get or create a session
async function getSession(): Promise<string | null> {
  try {
    const res = await fetch(`${baseUrl}/session`);
    const sessions = await res.json() as Array<{ id: string; title?: string }>;
    
    if (sessions.length > 0) {
      const session = sessions[0]!;
      console.log(`${c.green}✓ Using session:${c.reset} ${session.id}\n`);
      return session.id;
    }
    
    // Create new session
    const createRes = await fetch(`${baseUrl}/session`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ title: "Test Harness" }),
    });
    const newSession = await createRes.json() as { id: string };
    console.log(`${c.green}✓ Created session:${c.reset} ${newSession.id}\n`);
    return newSession.id;
  } catch (error) {
    console.error(`${c.red}✗ Failed to get/create session:${c.reset}`, error);
    return null;
  }
}

// Subscribe to SSE events
async function subscribeToEvents() {
  console.log(`${c.blue}📡 Listening for events...${c.reset}\n`);
  
  try {
    const response = await fetch(`${baseUrl}/event`);
    
    if (!response.ok || !response.body) {
      throw new Error(`Failed to connect: ${response.status}`);
    }
    
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      
      buffer += decoder.decode(value, { stream: true });
      
      // Process complete SSE messages
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";
      
      let eventData: string | null = null;
      
      for (const line of lines) {
        if (line.startsWith("data: ")) {
          eventData = line.slice(6);
        } else if (line === "" && eventData) {
          try {
            const event = JSON.parse(eventData);
            
            // Filter for suggestion-manager events
            if (event.type === "log" && event.properties?.service === "suggestion-manager") {
              const extra = event.properties.extra;
              if (extra?.event) {
                const suggEvent = JSON.parse(event.properties.message);
                logSuggestionEvent(suggEvent);
              }
            }
          } catch {
            // Ignore parse errors
          }
          eventData = null;
        }
      }
    }
  } catch (error) {
    console.error(`${c.red}SSE connection error:${c.reset}`, error);
  }
}

// Log suggestion events nicely
function logSuggestionEvent(event: any) {
  const type = event.type;
  const timestamp = new Date().toLocaleTimeString();
  
  console.log(`\n${c.dim}[${timestamp}]${c.reset}`);
  
  switch (type) {
    case "suggestion.ready":
      console.log(`${c.green}📦 SUGGESTION READY${c.reset}`);
      console.log(`   ID: ${event.suggestion?.id}`);
      console.log(`   Description: ${event.suggestion?.description}`);
      console.log(`   Files: ${event.suggestion?.files?.join(", ")}`);
      console.log(`   Hunks: ${event.suggestion?.hunks?.length}`);
      if (event.suggestion?.hunks) {
        for (const hunk of event.suggestion.hunks) {
          console.log(`${c.dim}   ─────────────────────────────${c.reset}`);
          console.log(`   ${c.yellow}Hunk:${c.reset} ${hunk.id}`);
          console.log(`   ${c.yellow}File:${c.reset} ${hunk.file}`);
          console.log(`${c.dim}${hunk.diff}${c.reset}`);
        }
      }
      break;
      
    case "suggestion.status":
      console.log(`${c.cyan}📊 STATUS${c.reset} [${event.status}] ${event.message}`);
      break;
      
    case "suggestion.error":
      console.log(`${c.red}❌ ERROR${c.reset} [${event.code}] ${event.message}`);
      break;
      
    case "suggestion.hunk_applied":
      console.log(`${c.green}✅ HUNK APPLIED${c.reset} ${event.hunkId} → ${event.action}`);
      break;
      
    case "suggestion.list":
      console.log(`${c.blue}📋 SUGGESTIONS${c.reset}`);
      for (const s of event.suggestions ?? []) {
        console.log(`   - ${s.id}: ${s.description} (${s.reviewedCount}/${s.hunkCount})`);
      }
      break;
      
    default:
      console.log(`${c.yellow}📨 EVENT${c.reset} ${type}`);
      console.log(`${c.dim}${JSON.stringify(event, null, 2)}${c.reset}`);
  }
}

// Send a message to the session
async function sendMessage(sessionId: string, text: string): Promise<void> {
  console.log(`${c.dim}→ Sending: ${text}${c.reset}`);
  
  try {
    // Use prompt_async so we don't block waiting for response
    await fetch(`${baseUrl}/session/${sessionId}/prompt_async`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        parts: [{ type: "text", text }],
      }),
    });
  } catch (error) {
    console.error(`${c.red}Failed to send message:${c.reset}`, error);
  }
}

// Interactive CLI
async function startCLI(sessionId: string) {
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });
  
  console.log(`${c.yellow}Commands:${c.reset}`);
  console.log(`  Type any message to send to the AI`);
  console.log(`  ${c.dim}quit${c.reset} - Exit\n`);
  
  const prompt = () => {
    rl.question(`${c.magenta}>${c.reset} `, async (input) => {
      const trimmed = input.trim();
      
      if (trimmed === "quit" || trimmed === "exit" || trimmed === "q") {
        console.log("Goodbye!");
        process.exit(0);
      }
      
      if (trimmed) {
        await sendMessage(sessionId, trimmed);
      }
      
      prompt();
    });
  };
  
  prompt();
}

// Main
async function main() {
  if (!await checkHealth()) {
    console.error("Make sure 'opencode serve' is running.");
    process.exit(1);
  }
  
  const sessionId = await getSession();
  if (!sessionId) {
    process.exit(1);
  }
  
  // Start SSE listener in background
  subscribeToEvents();
  
  // Start interactive CLI
  await startCLI(sessionId);
}

main().catch(console.error);
