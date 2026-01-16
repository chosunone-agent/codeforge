/**
 * Loader file for OpenCode plugin directory
 * 
 * This re-exports the plugin so OpenCode can load it from a symlinked directory.
 * 
 * Installation:
 *   ln -s /path/to/isolated-ai-coder/plugin/src ~/.config/opencode/plugin/suggestion-manager-src
 *   ln -s ~/.config/opencode/plugin/suggestion-manager-src/loader.ts ~/.config/opencode/plugin/suggestion-manager.ts
 */

export { SuggestionManagerPlugin, default } from "./index.ts";
