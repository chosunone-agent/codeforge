import { describe, expect, test, beforeEach, afterEach } from "bun:test";
import { loadConfig } from "../src/index.ts";
import { mkdirSync, writeFileSync, rmSync, existsSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";

describe("loadConfig", () => {
  let testDir: string;
  const originalEnv: Record<string, string | undefined> = {};

  beforeEach(() => {
    // Create a unique temp directory for each test
    testDir = join(tmpdir(), `codeforge-test-${Date.now()}`);
    mkdirSync(testDir, { recursive: true });

    // Save original env vars
    originalEnv.CODEFORGE_SERVER_ENABLED = process.env.CODEFORGE_SERVER_ENABLED;
    originalEnv.CODEFORGE_SERVER_PORT = process.env.CODEFORGE_SERVER_PORT;
    originalEnv.CODEFORGE_SERVER_HOST = process.env.CODEFORGE_SERVER_HOST;

    // Clear env vars for testing
    delete process.env.CODEFORGE_SERVER_ENABLED;
    delete process.env.CODEFORGE_SERVER_PORT;
    delete process.env.CODEFORGE_SERVER_HOST;
  });

  afterEach(() => {
    // Clean up temp directory
    if (existsSync(testDir)) {
      rmSync(testDir, { recursive: true });
    }

    // Restore original env vars
    if (originalEnv.CODEFORGE_SERVER_ENABLED !== undefined) {
      process.env.CODEFORGE_SERVER_ENABLED = originalEnv.CODEFORGE_SERVER_ENABLED;
    } else {
      delete process.env.CODEFORGE_SERVER_ENABLED;
    }
    if (originalEnv.CODEFORGE_SERVER_PORT !== undefined) {
      process.env.CODEFORGE_SERVER_PORT = originalEnv.CODEFORGE_SERVER_PORT;
    } else {
      delete process.env.CODEFORGE_SERVER_PORT;
    }
    if (originalEnv.CODEFORGE_SERVER_HOST !== undefined) {
      process.env.CODEFORGE_SERVER_HOST = originalEnv.CODEFORGE_SERVER_HOST;
    } else {
      delete process.env.CODEFORGE_SERVER_HOST;
    }
  });

  test("returns defaults when no config files exist", () => {
    const config = loadConfig(testDir);

    expect(config.enabled).toBe(true);
    expect(config.port).toBe(4097);
    expect(config.host).toBe("127.0.0.1");
  });

  test("loads project config from .opencode/codeforge.json", () => {
    const configDir = join(testDir, ".opencode");
    mkdirSync(configDir, { recursive: true });
    writeFileSync(
      join(configDir, "codeforge.json"),
      JSON.stringify({
        server: {
          enabled: false,
          port: 5000,
          host: "0.0.0.0",
        },
      })
    );

    const config = loadConfig(testDir);

    expect(config.enabled).toBe(false);
    expect(config.port).toBe(5000);
    expect(config.host).toBe("0.0.0.0");
  });

  test("partial project config only overrides specified values", () => {
    const configDir = join(testDir, ".opencode");
    mkdirSync(configDir, { recursive: true });
    writeFileSync(
      join(configDir, "codeforge.json"),
      JSON.stringify({
        server: {
          port: 8080,
        },
      })
    );

    const config = loadConfig(testDir);

    expect(config.enabled).toBe(true); // default
    expect(config.port).toBe(8080); // from config
    expect(config.host).toBe("127.0.0.1"); // default
  });

  test("environment variables override config file", () => {
    const configDir = join(testDir, ".opencode");
    mkdirSync(configDir, { recursive: true });
    writeFileSync(
      join(configDir, "codeforge.json"),
      JSON.stringify({
        server: {
          enabled: true,
          port: 5000,
          host: "0.0.0.0",
        },
      })
    );

    // Set env vars
    process.env.CODEFORGE_SERVER_ENABLED = "false";
    process.env.CODEFORGE_SERVER_PORT = "9999";
    process.env.CODEFORGE_SERVER_HOST = "localhost";

    const config = loadConfig(testDir);

    expect(config.enabled).toBe(false);
    expect(config.port).toBe(9999);
    expect(config.host).toBe("localhost");
  });

  test("handles invalid JSON gracefully", () => {
    const configDir = join(testDir, ".opencode");
    mkdirSync(configDir, { recursive: true });
    writeFileSync(join(configDir, "codeforge.json"), "{ invalid json }");

    // Should not throw, should return defaults
    const config = loadConfig(testDir);

    expect(config.enabled).toBe(true);
    expect(config.port).toBe(4097);
    expect(config.host).toBe("127.0.0.1");
  });

  test("handles empty config object", () => {
    const configDir = join(testDir, ".opencode");
    mkdirSync(configDir, { recursive: true });
    writeFileSync(join(configDir, "codeforge.json"), "{}");

    const config = loadConfig(testDir);

    expect(config.enabled).toBe(true);
    expect(config.port).toBe(4097);
    expect(config.host).toBe("127.0.0.1");
  });

  test("CODEFORGE_SERVER_ENABLED=false disables server", () => {
    process.env.CODEFORGE_SERVER_ENABLED = "false";

    const config = loadConfig(testDir);

    expect(config.enabled).toBe(false);
  });

  test("CODEFORGE_SERVER_ENABLED=true enables server", () => {
    process.env.CODEFORGE_SERVER_ENABLED = "true";

    const config = loadConfig(testDir);

    expect(config.enabled).toBe(true);
  });

  test("ignores invalid port in env var", () => {
    process.env.CODEFORGE_SERVER_PORT = "not-a-number";

    const config = loadConfig(testDir);

    expect(config.port).toBe(4097); // default
  });
});
