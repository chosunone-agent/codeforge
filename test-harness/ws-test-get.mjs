#!/usr/bin/env node
/**
 * Test getting full suggestion details via WebSocket
 */
import WebSocket from "ws";

const WS_URL = "ws://127.0.0.1:4097/ws";

console.log("Connecting to", WS_URL);

const ws = new WebSocket(WS_URL);

let messageId = 0;
const pending = new Map();

function send(msg) {
  return new Promise((resolve, reject) => {
    const id = String(++messageId);
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ ...msg, id }));
    setTimeout(() => {
      if (pending.has(id)) {
        pending.delete(id);
        reject(new Error("timeout"));
      }
    }, 5000);
  });
}

ws.on("open", async () => {
  console.log("Connected!\n");
  
  // Wait for connected message
  await new Promise(r => setTimeout(r, 200));
});

ws.on("message", async (data) => {
  const msg = JSON.parse(data.toString());
  
  // Handle responses
  if (msg.type === "response" && msg.id) {
    const p = pending.get(msg.id);
    if (p) {
      pending.delete(msg.id);
      p.resolve(msg);
      return;
    }
  }
  
  console.log("Event:", msg.type);
  
  if (msg.type === "connected") {
    console.log("Got connected event with", msg.suggestions?.length || 0, "suggestions");
    
    // If we have suggestions, request full details for the first one
    if (msg.suggestions?.length > 0) {
      const brief = msg.suggestions[0];
      console.log("\nBrief:", JSON.stringify(brief, null, 2));
      
      console.log("\nRequesting full details for:", brief.id);
      const fullResult = await send({ type: "get", suggestionId: brief.id });
      
      if (fullResult.success) {
        const full = fullResult.suggestion;
        console.log("\nFull suggestion:");
        console.log("  ID:", full.id);
        console.log("  Description:", full.description);
        console.log("  Hunks:", full.hunks?.length);
        console.log("  Reviewed:", full.reviewedCount, "/", full.hunks?.length);
        
        if (full.hunks?.length > 0) {
          console.log("\n  First hunk:");
          console.log("    File:", full.hunks[0].file);
          console.log("    Diff preview:", full.hunks[0].diff?.substring(0, 200) + "...");
          console.log("    Original lines:", full.hunks[0].originalLines?.length ?? "NOT PROVIDED");
          console.log("    Original start line:", full.hunks[0].originalStartLine ?? "NOT PROVIDED");
          if (full.hunks[0].originalLines?.length > 0) {
            console.log("    First original line:", JSON.stringify(full.hunks[0].originalLines[0]));
          }
        }
      } else {
        console.log("Failed:", fullResult.error);
      }
    }
    
    ws.close();
    process.exit(0);
  }
});

ws.on("error", (err) => {
  console.error("Error:", err.message);
  process.exit(1);
});
