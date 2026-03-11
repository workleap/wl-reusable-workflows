// @actions/glob uses minimatch internally for pattern matching, so we use
// minimatch directly to match GitHub Actions' path filter behavior.
// @actions/glob itself is filesystem-based and cannot match patterns against strings.
const { minimatch } = require("minimatch");

// Usage: node glob-match.js '{"value":"src/app.ts","pattern":"src/**"}'
const input = JSON.parse(process.argv[2]);
const result = minimatch(input.value, input.pattern, { dot: true });
process.stdout.write(result ? "true" : "false");
