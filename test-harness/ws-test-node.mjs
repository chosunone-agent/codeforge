#!/usr/bin/env node
/**
 * WebSocket Test Client for Suggestion Manager (Node.js version)
 */
import WebSocket from "ws";

const PORT = process.env.SUGGESTION_MANAGER_PORT ?? "4097";
const WS_URL = `ws://127.0.0.1:${PORT}/ws`;

const c = {
  reset: "\x1b[0m",
  green: "\x1b[32m",
  red: "\x1b[31m",
  yellow: "\x1b[33m",
  cyan: "\x1b[36m",
  dim: "\x1b[2m",
};

console.log(`\n${c.cyan}=== WebSocket Test: Suggestion Manager ===${c.reset}`);
console.log(`${c.dim}Connecting to: ${WS_URL}${c.reset}\n`);

const ws = new WebSocket(WS_URL);

let messageId = 0;
const pendingRequests = new Map();

function send(message) {
  return new Promise((resolve, reject) => {
    const id = String(++messageId);
    pendingRequests.set(id, { resolve, reject });
    ws.send(JSON.stringify({ ...message, id }));
    
    setTimeout(() => {
      if (pendingRequests.has(id)) {
        pendingRequests.delete(id);
        reject(new Error("Request timeout"));
      }
    }, 5000);
  });
}

ws.on("open", async () => {
  console.log(`${c.green}✓${c.reset} Connected to WebSocket server\n`);
  
  await new Promise(resolve => setTimeout(resolve, 100));
  
  try {
    console.log(`${c.cyan}Test 1: List suggestions${c.reset}`);
    const listResult = await send({ type: "list" });
    console.log(`${c.green}✓${c.reset} Got ${listResult.suggestions?.length ?? 0} suggestions\n`);
    
    if (listResult.suggestions?.length > 0) {
      const suggestion = listResult.suggestions[0];
      console.log(`${c.dim}First suggestion: ${suggestion.id}${c.reset}`);
      console.log(`${c.dim}Description: ${suggestion.description}${c.reset}`);
      console.log(`${c.dim}Hunks: ${suggestion.hunkCount}${c.reset}\n`);
      
      console.log(`${c.cyan}Test 2: Get suggestion details${c.reset}`);
      const getResult = await send({ type: "get", suggestionId: suggestion.id });
      if (getResult.success) {
        console.log(`${c.green}✓${c.reset} Got suggestion with ${getResult.suggestion.hunks.length} hunks\n`);
        
        for (const hunk of getResult.suggestion.hunks) {
          const state = getResult.suggestion.hunkStates[hunk.id];
          const status = state?.reviewed ? `${c.green}reviewed${c.reset}` : `${c.yellow}pending${c.reset}`;
          console.log(`   ${c.dim}[${hunk.id}]${c.reset} ${hunk.file} (${status})`);
        }
        console.log();
      }
    }
    
    console.log(`${c.cyan}=== Tests Complete ===${c.reset}\n`);
    ws.close();
    process.exit(0);
    
  } catch (error) {
    console.error(`${c.red}Test error:${c.reset}`, error);
    ws.close();
    process.exit(1);
  }
});

ws.on("message", (data) => {
  const parsed = JSON.parse(data.toString());
  
  if (parsed.type === "response" && parsed.id) {
    const pending = pendingRequests.get(parsed.id);
    if (pending) {
      pendingRequests.delete(parsed.id);
      pending.resolve(parsed);
      return;
    }
  }
  
  console.log(`${c.cyan}[Event]${c.reset} ${parsed.type}`);
  if (parsed.type === "connected") {
    console.log(`   ${c.dim}Suggestions: ${parsed.suggestions?.length ?? 0}${c.reset}`);
  }
  console.log();
});

ws.on("error", (error) => {
  console.error(`${c.red}WebSocket error:${c.reset}`, error.message);
  process.exit(1);
});

ws.on("close", () => {
  console.log(`${c.yellow}WebSocket connection closed${c.reset}`);
});
