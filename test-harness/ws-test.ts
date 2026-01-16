#!/usr/bin/env bun
/**
 * WebSocket Test Client for Suggestion Manager
 * 
 * Tests the WebSocket connection and bidirectional communication.
 * 
 * Usage:
 *   bun run ws-test.ts
 */

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
const pendingRequests = new Map<string, { resolve: (data: any) => void; reject: (error: any) => void }>();

function send(message: object): Promise<any> {
  return new Promise((resolve, reject) => {
    const id = String(++messageId);
    pendingRequests.set(id, { resolve, reject });
    ws.send(JSON.stringify({ ...message, id }));
    
    // Timeout after 5 seconds
    setTimeout(() => {
      if (pendingRequests.has(id)) {
        pendingRequests.delete(id);
        reject(new Error("Request timeout"));
      }
    }, 5000);
  });
}

ws.onopen = async () => {
  console.log(`${c.green}✓${c.reset} Connected to WebSocket server\n`);
  
  // Wait for initial "connected" message
  await new Promise(resolve => setTimeout(resolve, 100));
  
  try {
    // Test 1: List suggestions
    console.log(`${c.cyan}Test 1: List suggestions${c.reset}`);
    const listResult = await send({ type: "list" });
    console.log(`${c.green}✓${c.reset} Got ${listResult.suggestions?.length ?? 0} suggestions\n`);
    
    if (listResult.suggestions?.length > 0) {
      const suggestion = listResult.suggestions[0];
      console.log(`${c.dim}First suggestion: ${suggestion.id}${c.reset}`);
      console.log(`${c.dim}Description: ${suggestion.description}${c.reset}`);
      console.log(`${c.dim}Hunks: ${suggestion.hunkCount}${c.reset}\n`);
      
      // Test 2: Get suggestion details
      console.log(`${c.cyan}Test 2: Get suggestion details${c.reset}`);
      const getResult = await send({ type: "get", suggestionId: suggestion.id });
      if (getResult.success) {
        console.log(`${c.green}✓${c.reset} Got suggestion with ${getResult.suggestion.hunks.length} hunks\n`);
        
        // Show hunks
        for (const hunk of getResult.suggestion.hunks) {
          const state = getResult.suggestion.hunkStates[hunk.id];
          const status = state?.reviewed ? `${c.green}reviewed${c.reset}` : `${c.yellow}pending${c.reset}`;
          console.log(`   ${c.dim}[${hunk.id}]${c.reset} ${hunk.file} (${status})`);
        }
        console.log();
      } else {
        console.log(`${c.red}✗${c.reset} Failed to get suggestion: ${getResult.error}\n`);
      }
    }
    
    // Test 3: Invalid request
    console.log(`${c.cyan}Test 3: Invalid request (missing fields)${c.reset}`);
    const invalidResult = await send({ type: "feedback", suggestionId: "test" });
    if (!invalidResult.success && invalidResult.error) {
      console.log(`${c.green}✓${c.reset} Got expected error: ${invalidResult.error}\n`);
    } else {
      console.log(`${c.red}✗${c.reset} Expected error but got success\n`);
    }
    
    console.log(`${c.cyan}=== Tests Complete ===${c.reset}`);
    console.log(`\n${c.yellow}Listening for events... Press Ctrl+C to exit${c.reset}\n`);
    
  } catch (error) {
    console.error(`${c.red}Test error:${c.reset}`, error);
    ws.close();
    process.exit(1);
  }
};

ws.onmessage = (event) => {
  const data = JSON.parse(event.data);
  
  // Handle responses to our requests
  if (data.type === "response" && data.id) {
    const pending = pendingRequests.get(data.id);
    if (pending) {
      pendingRequests.delete(data.id);
      pending.resolve(data);
      return;
    }
  }
  
  // Handle server-initiated events
  console.log(`${c.cyan}[Event]${c.reset} ${data.type}`);
  
  switch (data.type) {
    case "connected":
      console.log(`   ${c.dim}Suggestions: ${data.suggestions?.length ?? 0}${c.reset}`);
      break;
    case "suggestion.ready":
      console.log(`   ${c.green}New suggestion:${c.reset} ${data.suggestion?.id}`);
      console.log(`   ${c.dim}Description: ${data.suggestion?.description}${c.reset}`);
      console.log(`   ${c.dim}Hunks: ${data.suggestion?.hunks?.length}${c.reset}`);
      break;
    case "suggestion.hunk_applied":
      console.log(`   ${c.dim}Suggestion: ${data.suggestionId}${c.reset}`);
      console.log(`   ${c.dim}Hunk: ${data.hunkId}${c.reset}`);
      console.log(`   ${c.dim}Action: ${data.action}${c.reset}`);
      break;
    case "suggestion.status":
      console.log(`   ${c.dim}Status: ${data.status}${c.reset}`);
      console.log(`   ${c.dim}Message: ${data.message}${c.reset}`);
      break;
    case "suggestion.error":
      console.log(`   ${c.red}Error [${data.code}]: ${data.message}${c.reset}`);
      break;
    default:
      console.log(`   ${c.dim}${JSON.stringify(data)}${c.reset}`);
  }
  console.log();
};

ws.onerror = (error) => {
  console.error(`${c.red}WebSocket error:${c.reset}`, error);
};

ws.onclose = () => {
  console.log(`${c.yellow}WebSocket connection closed${c.reset}`);
  process.exit(0);
};

// Keep process alive
process.on("SIGINT", () => {
  ws.close();
  process.exit(0);
});
