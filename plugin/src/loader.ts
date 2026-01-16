/**
 * Loader file for OpenCode plugin directory
 * 
 * This re-exports the plugin so OpenCode can load it from a symlinked directory.
 * 
 * Installation:
 *   ln -s /path/to/isolated-ai-coder/plugin/src ~/.config/opencode/plugin/codeforge-src
 *   ln -s ~/.config/opencode/plugin/codeforge-src/loader.ts ~/.config/opencode/plugin/codeforge.ts
 */

export { CodeForgePlugin, default } from "./index.ts";
