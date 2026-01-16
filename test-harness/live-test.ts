#!/usr/bin/env bun
/**
 * Live Test for Suggestion Manager
 * 
 * Tests against the REAL plugin running in OpenCode.
 * 
 * Usage:
 *   bun run live-test.ts
 */

const PORT = process.env.SUGGESTION_MANAGER_PORT ?? "4097";
const BASE_URL = `http://127.0.0.1:${PORT}`;

const c = {
  reset: "\x1b[0m",
  green: "\x1b[32m",
  red: "\x1b[31m",
  yellow: "\x1b[33m",
  cyan: "\x1b[36m",
  dim: "\x1b[2m",
};

async function main() {
  console.log(`\n${c.cyan}=== Live Test: Suggestion Manager ===${c.reset}`);
  console.log(`${c.dim}Server: ${BASE_URL}${c.reset}\n`);

  // 1. Health check
  console.log("1. Health check...");
  try {
    const health = await fetch(`${BASE_URL}/health`);
    const healthData = await health.json();
    console.log(`   ${c.green}✓${c.reset} Server healthy:`, healthData);
  } catch (e) {
    console.log(`   ${c.red}✗${c.reset} Server not reachable. Is OpenCode running with the plugin?`);
    process.exit(1);
  }

  // 2. List suggestions
  console.log("\n2. Listing suggestions...");
  const listRes = await fetch(`${BASE_URL}/suggestions`);
  const listData = await listRes.json() as { suggestions: Array<{ id: string; description: string; hunkCount: number; reviewedCount: number }> };
  
  if (listData.suggestions.length === 0) {
    console.log(`   ${c.yellow}No suggestions found.${c.reset}`);
    console.log(`\n   ${c.cyan}To create a suggestion, ask the AI to:${c.reset}`);
    console.log(`   "Make a small change to a file and use publish_suggestion to let me review it"`);
    console.log(`\n   Or I can try to publish one now if this is a jj repo with changes.`);
    return;
  }

  console.log(`   Found ${listData.suggestions.length} suggestion(s):\n`);
  
  for (const s of listData.suggestions) {
    console.log(`   ${c.cyan}ID:${c.reset} ${s.id}`);
    console.log(`   ${c.cyan}Description:${c.reset} ${s.description}`);
    console.log(`   ${c.cyan}Progress:${c.reset} ${s.reviewedCount}/${s.hunkCount} hunks reviewed`);
    console.log();
  }

  // 3. Get details of first suggestion
  const firstSuggestion = listData.suggestions[0]!;
  console.log(`3. Getting details for: ${firstSuggestion.id}`);
  
  const detailRes = await fetch(`${BASE_URL}/suggestions/${firstSuggestion.id}`);
  const detail = await detailRes.json() as { 
    id: string; 
    hunks: Array<{ id: string; file: string; diff: string }>; 
    hunkStates: Record<string, { reviewed: boolean }>;
  };

  console.log(`\n   ${c.cyan}Hunks:${c.reset}`);
  for (const hunk of detail.hunks) {
    const state = detail.hunkStates[hunk.id];
    const status = state?.reviewed ? `${c.green}reviewed${c.reset}` : `${c.yellow}pending${c.reset}`;
    console.log(`\n   ${c.yellow}[${hunk.id}]${c.reset} ${hunk.file} (${status})`);
    console.log(`${c.dim}${hunk.diff}${c.reset}`);
  }

  // 4. Interactive: ask if user wants to send feedback
  const pendingHunks = detail.hunks.filter(h => !detail.hunkStates[h.id]?.reviewed);
  
  if (pendingHunks.length > 0) {
    console.log(`\n${c.cyan}=== Send Feedback ===${c.reset}`);
    console.log(`\nTo accept/reject a hunk, run:\n`);
    
    const firstPending = pendingHunks[0]!;
    console.log(`${c.green}# Accept:${c.reset}`);
    console.log(`curl -X POST ${BASE_URL}/feedback \\`);
    console.log(`  -H "Content-Type: application/json" \\`);
    console.log(`  -d '{"suggestionId":"${firstSuggestion.id}","hunkId":"${firstPending.id}","action":"accept"}'`);
    
    console.log(`\n${c.red}# Reject:${c.reset}`);
    console.log(`curl -X POST ${BASE_URL}/feedback \\`);
    console.log(`  -H "Content-Type: application/json" \\`);
    console.log(`  -d '{"suggestionId":"${firstSuggestion.id}","hunkId":"${firstPending.id}","action":"reject"}'`);
  } else {
    console.log(`\n${c.green}All hunks have been reviewed!${c.reset}`);
    console.log(`\nTo finalize or discard:\n`);
    console.log(`curl -X POST ${BASE_URL}/complete \\`);
    console.log(`  -H "Content-Type: application/json" \\`);
    console.log(`  -d '{"suggestionId":"${firstSuggestion.id}","action":"finalize"}'`);
  }

  console.log();
}

main().catch(console.error);
