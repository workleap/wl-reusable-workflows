const { describe, it, before, after, beforeEach, mock } = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const os = require("os");

const {
  resolveRefs,
  importPolicyFromGit,
  getChangedFiles,
  findRequiredChecks,
  waitRequiredChecks,
  getCheckRuns,
  testGlobMatch,
  getWorkflowFiles,
  findWlNotRequired,
  testWorkflowTriggers,
  findAutoDiscoveredChecks,
  _setCore,
} = require("./index.js");

// Mock core for logging
const mockCore = {
  info: () => {},
  startGroup: () => {},
  endGroup: () => {},
  debug: () => {},
};
_setCore(mockCore);

// Helper: create a test git repo with a bare origin and a clone.
function createTestGitRepo() {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "test-git-"));
  const originRepo = path.join(tempRoot, "origin");
  const cloneRepo = path.join(tempRoot, "clone");

  fs.mkdirSync(originRepo);

  const gitIn = (dir, ...args) => execFileSync("git", args, { cwd: dir, encoding: "utf-8" });

  gitIn(originRepo, "init");
  gitIn(originRepo, "config", "user.email", "test@test.com");
  gitIn(originRepo, "config", "user.name", "Test");
  gitIn(originRepo, "checkout", "-b", "main");

  fs.mkdirSync(path.join(originRepo, "service1"), { recursive: true });
  fs.mkdirSync(path.join(originRepo, "service2"), { recursive: true });
  fs.mkdirSync(path.join(originRepo, "shared"), { recursive: true });

  fs.writeFileSync(path.join(originRepo, "service1", "app.ts"), "service1 content");
  fs.writeFileSync(path.join(originRepo, "service2", "app.ts"), "service2 content");
  fs.writeFileSync(path.join(originRepo, "shared", "util.ts"), "shared content");

  const policyContent = JSON.stringify([
    { checks: ["build-service1"], paths: ["service1/"] },
    { checks: ["build-service2"], paths: ["service2/"] },
  ], null, 2);
  fs.writeFileSync(path.join(originRepo, "policy.json"), policyContent);

  gitIn(originRepo, "add", "-A");
  gitIn(originRepo, "commit", "-m", "Initial commit");

  // Create feature branch
  gitIn(originRepo, "checkout", "-b", "feature");
  fs.writeFileSync(path.join(originRepo, "service1", "new-file.txt"), "new file");
  fs.writeFileSync(path.join(originRepo, "shared", "util.ts"), "shared content modified");
  gitIn(originRepo, "add", "-A");
  gitIn(originRepo, "commit", "-m", "Feature changes");

  // Clone
  execFileSync("git", ["clone", originRepo, cloneRepo], { encoding: "utf-8" });

  return { root: tempRoot, clonePath: cloneRepo };
}

// Helper: create a test git repo with workflow files for auto-discovery tests.
function createTestGitRepoWithWorkflows() {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "test-git-"));
  const originRepo = path.join(tempRoot, "origin");
  const cloneRepo = path.join(tempRoot, "clone");

  fs.mkdirSync(originRepo);

  const gitIn = (dir, ...args) => execFileSync("git", args, { cwd: dir, encoding: "utf-8" });

  gitIn(originRepo, "init");
  gitIn(originRepo, "config", "user.email", "test@test.com");
  gitIn(originRepo, "config", "user.name", "Test");
  gitIn(originRepo, "checkout", "-b", "main");

  fs.mkdirSync(path.join(originRepo, "service1"), { recursive: true });
  fs.mkdirSync(path.join(originRepo, "service2"), { recursive: true });
  fs.writeFileSync(path.join(originRepo, "service1", "app.ts"), "service1 content");
  fs.writeFileSync(path.join(originRepo, "service2", "app.ts"), "service2 content");

  const workflowsDir = path.join(originRepo, ".github", "workflows");
  fs.mkdirSync(workflowsDir, { recursive: true });

  // Workflow 1: service1 build with path filter
  fs.writeFileSync(path.join(workflowsDir, "build-service1.yml"), `name: Build Service 1
on:
  pull_request:
    paths:
      - service1/**
jobs:
  build-service1:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
`);

  // Workflow 2: service2 build with path filter
  fs.writeFileSync(path.join(workflowsDir, "build-service2.yml"), `name: Build Service 2
on:
  pull_request:
    paths:
      - service2/**
jobs:
  build-service2:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
`);

  // Workflow 3: entirely opted out at workflow level
  fs.writeFileSync(path.join(workflowsDir, "opted-out-workflow.yml"), `# wl-not-required
name: Opted Out Workflow
on:
  pull_request:
    paths:
      - service1/**
jobs:
  opted-out-workflow-job:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
`);


  // Workflow 5: job-level opt-out
  fs.writeFileSync(path.join(workflowsDir, "job-opt-out.yml"), `name: Job Opt Out
on:
  pull_request:
    paths:
      - service1/**
jobs:
  # wl-not-required
  optional-job:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
  required-job:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
`);

  // Workflow 6: workflow_call only (reusable workflow)
  fs.writeFileSync(path.join(workflowsDir, "reusable.yml"), `name: Reusable Workflow
on:
  workflow_call:
    inputs:
      param1:
        type: string
jobs:
  reusable-job:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
`);

  // Workflow 7: no path filters (triggers on everything)
  fs.writeFileSync(path.join(workflowsDir, "no-filter.yml"), `name: No Filter
on:
  pull_request:
jobs:
  no-filter-job:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
`);

  // Workflow 8: wrong branch filter
  fs.writeFileSync(path.join(workflowsDir, "wrong-branch.yml"), `name: Wrong Branch
on:
  pull_request:
    branches:
      - develop
    paths:
      - service1/**
jobs:
  wrong-branch-job:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
`);

  gitIn(originRepo, "add", "-A");
  gitIn(originRepo, "commit", "-m", "Initial commit with workflows");

  // Create feature branch with changes
  gitIn(originRepo, "checkout", "-b", "feature");
  fs.writeFileSync(path.join(originRepo, "service1", "new-file.txt"), "new file");
  gitIn(originRepo, "add", "-A");
  gitIn(originRepo, "commit", "-m", "Feature changes");

  execFileSync("git", ["clone", originRepo, cloneRepo], { encoding: "utf-8" });

  return { root: tempRoot, clonePath: cloneRepo };
}

// ============================================================
// resolveRefs
// ============================================================

describe("resolveRefs", () => {
  it("returns headRef and baseRef as-is when both are provided", () => {
    const result = resolveRefs({ commitId: "abc123", baseRef: "main", headRef: "feature", refName: "unused", defaultBranch: "main" });
    assert.equal(result.baseRef, "main");
    assert.equal(result.headRef, "feature");
  });

  it("falls back to refName when headRef is empty", () => {
    const result = resolveRefs({ commitId: "abc123", baseRef: "main", headRef: "", refName: "my-branch", defaultBranch: "main" });
    assert.equal(result.headRef, "my-branch");
  });

  it("falls back to defaultBranch when baseRef is empty", () => {
    const result = resolveRefs({ commitId: "abc123", baseRef: "", headRef: "feature", refName: "", defaultBranch: "develop" });
    assert.equal(result.baseRef, "develop");
  });

  it("falls back to both defaults when headRef and baseRef are empty", () => {
    const result = resolveRefs({ commitId: "abc123", baseRef: "", headRef: "", refName: "push-branch", defaultBranch: "main" });
    assert.equal(result.baseRef, "main");
    assert.equal(result.headRef, "push-branch");
  });
});

// ============================================================
// importPolicyFromGit
// ============================================================

describe("importPolicyFromGit", () => {
  let testRepo;
  let originalCwd;

  before(() => {
    testRepo = createTestGitRepo();
    originalCwd = process.cwd();
    process.chdir(testRepo.clonePath);
  });

  after(() => {
    process.chdir(originalCwd);
    fs.rmSync(testRepo.root, { recursive: true, force: true });
  });

  it("loads and parses the policy from the base branch", () => {
    const policy = importPolicyFromGit("policy.json", "main");
    assert.ok(policy);
    assert.equal(policy.length, 2);
    assert.ok(policy[0].checks.includes("build-service1"));
    assert.ok(policy[1].checks.includes("build-service2"));
  });

  it("throws when the policy file does not exist", () => {
    assert.throws(() => importPolicyFromGit("nonexistent.json", "main"), /Failed to load policy file/);
  });
});

// ============================================================
// getChangedFiles
// ============================================================

describe("getChangedFiles", () => {
  let testRepo;
  let originalCwd;

  before(() => {
    testRepo = createTestGitRepo();
    originalCwd = process.cwd();
    process.chdir(testRepo.clonePath);
  });

  after(() => {
    process.chdir(originalCwd);
    fs.rmSync(testRepo.root, { recursive: true, force: true });
  });

  it("returns changed files between base and head", () => {
    const result = getChangedFiles("main", "feature");
    assert.ok(result.includes("service1/new-file.txt"));
    assert.ok(result.includes("shared/util.ts"));
    assert.ok(!result.includes("service2/app.ts"));
  });

  it("returns empty when comparing a branch to itself", () => {
    const result = getChangedFiles("main", "main");
    assert.equal(result.length, 0);
  });
});

// ============================================================
// findRequiredChecks
// ============================================================

describe("findRequiredChecks", () => {
  let testRepo;
  let originalCwd;

  before(() => {
    testRepo = createTestGitRepo();
    originalCwd = process.cwd();
    process.chdir(testRepo.clonePath);
  });

  after(() => {
    process.chdir(originalCwd);
    fs.rmSync(testRepo.root, { recursive: true, force: true });
  });

  it("returns matching checks when paths have changes", () => {
    const policy = [{ checks: ["build-service1"], paths: ["service1/"] }];
    const result = findRequiredChecks(policy, "main", "feature");
    assert.deepEqual(result, ["build-service1"]);
  });

  it("returns empty when no paths have changes", () => {
    const policy = [{ checks: ["build-service2"], paths: ["service2/"] }];
    const result = findRequiredChecks(policy, "main", "feature");
    assert.equal(result.length, 0);
  });

  it("returns deduplicated and sorted checks from multiple matching policies", () => {
    const policy = [
      { checks: ["check-b", "check-a"], paths: ["service1/"] },
      { checks: ["check-a", "check-c"], paths: ["shared/"] },
    ];
    const result = findRequiredChecks(policy, "main", "feature");
    assert.deepEqual(result, ["check-a", "check-b", "check-c"]);
  });

  it("skips policy items with no valid paths", () => {
    const policy = [{ checks: ["check1"], paths: [null, ""] }];
    const result = findRequiredChecks(policy, "main", "feature");
    assert.equal(result.length, 0);
  });

  it("throws on paths starting with !", () => {
    const policy = [{ checks: ["check1"], paths: ["!excluded/"] }];
    assert.throws(() => findRequiredChecks(policy, "main", "feature"), /not supported/);
  });

  it("only returns checks for policy items with matching changes", () => {
    const policy = [
      { checks: ["build-service1"], paths: ["service1/"] },
      { checks: ["build-service2"], paths: ["service2/"] },
    ];
    const result = findRequiredChecks(policy, "main", "feature");
    assert.deepEqual(result, ["build-service1"]);
  });

  it("supports pathspec exclusions with :(exclude) syntax", () => {
    const policy = [{ checks: ["check-all"], paths: ["service1/", ":(exclude)service1/new-file.txt"] }];
    const result = findRequiredChecks(policy, "main", "feature");
    assert.equal(result.length, 0);
  });
});

// ============================================================
// testGlobMatch
// ============================================================

describe("testGlobMatch", () => {
  it("matches exact string", () => {
    assert.ok(testGlobMatch("main", "main"));
  });

  it("does not match different string", () => {
    assert.ok(!testGlobMatch("develop", "main"));
  });

  it("matches * wildcard within a single segment", () => {
    assert.ok(testGlobMatch("release/1.0", "release/*"));
  });

  it("does not match * across directory separator", () => {
    assert.ok(!testGlobMatch("release/v1/hotfix", "release/*"));
  });

  it("matches ** across directories", () => {
    assert.ok(testGlobMatch("src/components/Button/index.ts", "src/**"));
  });

  it("matches ** in the middle of a pattern", () => {
    assert.ok(testGlobMatch("src/components/Button/index.ts", "src/**/index.ts"));
  });

  it("matches file extension patterns in same directory", () => {
    assert.ok(testGlobMatch("app.ts", "*.ts"));
  });

  it("does not match file extension across directories without **", () => {
    assert.ok(!testGlobMatch("src/app.ts", "*.ts"));
  });

  it("does not match wrong extension", () => {
    assert.ok(!testGlobMatch("src/app.js", "*.ts"));
  });

  it("matches ? single character wildcard", () => {
    assert.ok(testGlobMatch("file1.ts", "file?.ts"));
  });

  it("matches branch patterns like feature/**", () => {
    assert.ok(testGlobMatch("feature/my-feature", "feature/**"));
  });

  it("escapes regex special characters", () => {
    assert.ok(testGlobMatch("file.test.ts", "file.test.ts"));
  });

  it("matches paths with ** and file extension", () => {
    assert.ok(testGlobMatch("src/deep/nested/file.ts", "src/**/*.ts"));
  });
});

// ============================================================
// findWlNotRequired
// ============================================================

describe("findWlNotRequired", () => {
  it("detects workflow-level opt-out on first non-empty line", () => {
    const yaml = `# wl-not-required
name: My Workflow
on:
  push:
jobs:
  build:
    runs-on: ubuntu-latest`;
    const result = findWlNotRequired(yaml);
    assert.ok(result.isWorkflowOptOut);
  });

  it("detects workflow-level opt-out with leading blank lines", () => {
    const yaml = `
# wl-not-required
name: My Workflow`;
    const result = findWlNotRequired(yaml);
    assert.ok(result.isWorkflowOptOut);
  });

  it("does not detect workflow-level opt-out when comment is not first", () => {
    const yaml = `name: My Workflow
# wl-not-required
on:
  push:`;
    const result = findWlNotRequired(yaml);
    assert.ok(!result.isWorkflowOptOut);
  });

  it("detects job-level opt-out", () => {
    const yaml = `name: My Workflow
on:
  pull_request:
jobs:
  # wl-not-required
  optional-job:
    runs-on: ubuntu-latest
  required-job:
    runs-on: ubuntu-latest`;
    const result = findWlNotRequired(yaml);
    assert.ok(!result.isWorkflowOptOut);
    assert.ok(result.optOutJobs.includes("optional-job"));
    assert.ok(!result.optOutJobs.includes("required-job"));
  });

  it("handles multiple job opt-outs in same file", () => {
    const yaml = `name: My Workflow
on:
  pull_request:
jobs:
  # wl-not-required
  optional-job1:
    runs-on: ubuntu-latest
  # wl-not-required
  optional-job2:
    runs-on: ubuntu-latest
  required-job:
    runs-on: ubuntu-latest`;
    const result = findWlNotRequired(yaml);
    assert.ok(result.optOutJobs.includes("optional-job1"));
    assert.ok(result.optOutJobs.includes("optional-job2"));
    assert.ok(!result.optOutJobs.includes("required-job"));
  });

  it("ignores wl-not-required in unrelated comments", () => {
    const yaml = `name: My Workflow
on:
  pull_request:
    # This is not a wl-not-required comment, just a regular comment
    paths:
      - src/**
jobs:
  build:
    runs-on: ubuntu-latest`;
    const result = findWlNotRequired(yaml);
    assert.ok(!result.isWorkflowOptOut);
    assert.equal(result.optOutJobs.length, 0);
  });

  it("detects wl-not-required without space after #", () => {
    const yaml = `#wl-not-required
name: My Workflow
on:
  push:`;
    const result = findWlNotRequired(yaml);
    assert.ok(result.isWorkflowOptOut);
  });

  it("detects wl-not-required with multiple spaces after #", () => {
    const yaml = `#   wl-not-required
name: My Workflow
on:
  push:`;
    const result = findWlNotRequired(yaml);
    assert.ok(result.isWorkflowOptOut);
  });

  it("detects job-level opt-out with multiple spaces after #", () => {
    const yaml = `name: My Workflow
on:
  pull_request:
jobs:
  #    wl-not-required
  optional-job:
    runs-on: ubuntu-latest`;
    const result = findWlNotRequired(yaml);
    assert.ok(result.optOutJobs.includes("optional-job"));
  });
});

// ============================================================
// testWorkflowTriggers
// ============================================================

describe("testWorkflowTriggers", () => {
  it("returns true for pull_request with no filters", () => {
    const on = { pull_request: {} };
    assert.ok(testWorkflowTriggers(on, "main", "feature", ["src/app.ts"]));
  });

  it("returns false when branch filter does not match base ref", () => {
    const on = { pull_request: { branches: ["develop"] } };
    assert.ok(!testWorkflowTriggers(on, "main", "feature", ["src/app.ts"]));
  });

  it("returns true when branch filter matches base ref", () => {
    const on = { pull_request: { branches: ["main", "develop"] } };
    assert.ok(testWorkflowTriggers(on, "main", "feature", ["src/app.ts"]));
  });

  it("returns true when branch filter matches with glob", () => {
    const on = { pull_request: { branches: ["release/*"] } };
    assert.ok(testWorkflowTriggers(on, "release/1.0", "feature", ["src/app.ts"]));
  });

  it("returns false when paths filter does not match any changed file", () => {
    const on = { pull_request: { paths: ["docs/**"] } };
    assert.ok(!testWorkflowTriggers(on, "main", "feature", ["src/app.ts"]));
  });

  it("returns true when paths filter matches a changed file", () => {
    const on = { pull_request: { paths: ["src/**"] } };
    assert.ok(testWorkflowTriggers(on, "main", "feature", ["src/app.ts"]));
  });

  it("handles branches-ignore correctly", () => {
    const on = { pull_request: { "branches-ignore": ["main"] } };
    assert.ok(!testWorkflowTriggers(on, "main", "feature", ["src/app.ts"]));
  });

  it("returns true when branch is not in branches-ignore", () => {
    const on = { pull_request: { "branches-ignore": ["develop"] } };
    assert.ok(testWorkflowTriggers(on, "main", "feature", ["src/app.ts"]));
  });

  it("handles paths-ignore correctly when all files are ignored", () => {
    const on = { pull_request: { "paths-ignore": ["docs/**"] } };
    assert.ok(!testWorkflowTriggers(on, "main", "feature", ["docs/readme.md"]));
  });

  it("returns true when not all files are in paths-ignore", () => {
    const on = { pull_request: { "paths-ignore": ["docs/**"] } };
    assert.ok(testWorkflowTriggers(on, "main", "feature", ["docs/readme.md", "src/app.ts"]));
  });

  it("returns false for workflow_call-only trigger", () => {
    const on = { workflow_call: {} };
    assert.ok(!testWorkflowTriggers(on, "main", "feature", ["src/app.ts"]));
  });

  it("handles push trigger matching head ref", () => {
    const on = { push: { branches: ["feature"] } };
    assert.ok(testWorkflowTriggers(on, "main", "feature", ["src/app.ts"]));
  });

  it("returns false for push when head ref does not match", () => {
    const on = { push: { branches: ["main"] } };
    assert.ok(!testWorkflowTriggers(on, "main", "feature", ["src/app.ts"]));
  });

  it("handles shorthand string syntax", () => {
    assert.ok(testWorkflowTriggers("push", "main", "feature", ["src/app.ts"]));
  });

  it("handles shorthand array syntax", () => {
    const on = ["push", "pull_request"];
    assert.ok(testWorkflowTriggers(on, "main", "feature", ["src/app.ts"]));
  });
});

// ============================================================
// getWorkflowFiles
// ============================================================

describe("getWorkflowFiles", () => {
  describe("without workflows", () => {
    let testRepo;
    let originalCwd;

    before(() => {
      testRepo = createTestGitRepo();
      originalCwd = process.cwd();
      process.chdir(testRepo.clonePath);
    });

    after(() => {
      process.chdir(originalCwd);
      fs.rmSync(testRepo.root, { recursive: true, force: true });
    });

    it("returns empty when no workflows directory exists", () => {
      const result = getWorkflowFiles();
      assert.equal(result.length, 0);
    });
  });

  describe("with workflows", () => {
    let testRepo;
    let originalCwd;

    before(() => {
      testRepo = createTestGitRepoWithWorkflows();
      originalCwd = process.cwd();
      process.chdir(testRepo.clonePath);
    });

    after(() => {
      process.chdir(originalCwd);
      fs.rmSync(testRepo.root, { recursive: true, force: true });
    });

    it("reads workflow files from disk", () => {
      const result = getWorkflowFiles();
      assert.ok(result.length >= 1);
      assert.ok(/\.github[\\/]workflows[\\/].*\.yml$/.test(result[0].path));
      assert.ok(result[0].content);
    });
  });
});

// ============================================================
// findAutoDiscoveredChecks
// ============================================================

describe("findAutoDiscoveredChecks", () => {
  let testRepo;
  let originalCwd;

  before(() => {
    testRepo = createTestGitRepoWithWorkflows();
    originalCwd = process.cwd();
    process.chdir(testRepo.clonePath);
  });

  after(() => {
    process.chdir(originalCwd);
    fs.rmSync(testRepo.root, { recursive: true, force: true });
  });

  it("discovers job keys from workflows matching changed paths", () => {
    const result = findAutoDiscoveredChecks("main", "feature", ["service1/new-file.txt"]);
    assert.ok(result.includes("build-service1"));
  });

  it("does not discover jobs from workflows with non-matching paths", () => {
    const result = findAutoDiscoveredChecks("main", "feature", ["unrelated/file.txt"]);
    assert.ok(!result.includes("build-service1"));
    assert.ok(!result.includes("build-service2"));
  });

  it("excludes entire workflow with wl-not-required at workflow level", () => {
    const result = findAutoDiscoveredChecks("main", "feature", ["service1/new-file.txt"]);
    assert.ok(!result.includes("opted-out-workflow-job"));
  });

  it("excludes specific job with wl-not-required at job level", () => {
    const result = findAutoDiscoveredChecks("main", "feature", ["service1/new-file.txt"]);
    assert.ok(!result.includes("optional-job"));
    assert.ok(result.includes("required-job"));
  });

  it("excludes workflow_call-only workflows", () => {
    const result = findAutoDiscoveredChecks("main", "feature", ["service1/new-file.txt"]);
    assert.ok(!result.includes("reusable-job"));
  });

  it("includes jobs from workflows with no path filters", () => {
    const result = findAutoDiscoveredChecks("main", "feature", ["anything.txt"]);
    assert.ok(result.includes("no-filter-job"));
  });

  it("excludes workflows with non-matching branch filter", () => {
    const result = findAutoDiscoveredChecks("main", "feature", ["service1/new-file.txt"]);
    assert.ok(!result.includes("wrong-branch-job"));
  });
});

// ============================================================
// waitRequiredChecks
// ============================================================

// Helper to create a mock github object that simulates octokit's paginate behavior.
// The dataFn returns the check_runs array for each call.
function createMockGithub(dataFn) {
  const listForRef = "listForRef_sentinel";
  return {
    rest: { checks: { listForRef } },
    paginate: async (_method, _params, mapFn) => {
      const checkRuns = await dataFn();
      // Simulate octokit paginate calling mapFn with each page response
      return mapFn({ data: { check_runs: checkRuns } });
    },
  };
}

describe("waitRequiredChecks", () => {
  it("succeeds immediately when all checks are completed successfully", async () => {
    const mockGithub = createMockGithub(async () => [
      { id: 1, name: "build", status: "completed", conclusion: "success", html_url: "https://example.com/1" },
      { id: 2, name: "test", status: "completed", conclusion: "success", html_url: "https://example.com/2" },
    ]);

    await waitRequiredChecks({
      requiredChecks: ["build", "test"],
      owner: "owner",
      repo: "repo",
      headRef: "feature",
      timeoutMinutesCreatedChecks: 15,
      timeoutMinutesQueuedChecks: 30,
      github: mockGithub,
    });
  });

  it("throws when a required check fails", async () => {
    const mockGithub = createMockGithub(async () => [
      { id: 1, name: "build", status: "completed", conclusion: "failure", html_url: "https://example.com/1" },
    ]);

    await assert.rejects(
      () => waitRequiredChecks({
        requiredChecks: ["build"],
        owner: "owner",
        repo: "repo",
        headRef: "feature",
        timeoutMinutesCreatedChecks: 15,
        timeoutMinutesQueuedChecks: 30,
        github: mockGithub,
      }),
      /failed with conclusion: failure/
    );
  });

  it("waits and retries when checks are in progress then succeed", async () => {
    let callCount = 0;
    const mockGithub = createMockGithub(async () => {
      callCount++;
      if (callCount === 1) {
        return [{ id: 1, name: "build", status: "in_progress", conclusion: null, html_url: "https://example.com/1" }];
      }
      return [{ id: 1, name: "build", status: "completed", conclusion: "success", html_url: "https://example.com/1" }];
    });

    // Override setTimeout to avoid actual waiting
    const origSetTimeout = global.setTimeout;
    global.setTimeout = (fn) => origSetTimeout(fn, 0);

    try {
      await waitRequiredChecks({
        requiredChecks: ["build"],
        owner: "owner",
        repo: "repo",
        headRef: "feature",
        timeoutMinutesCreatedChecks: 15,
        timeoutMinutesQueuedChecks: 30,
        github: mockGithub,
      });
      assert.equal(callCount, 2);
    } finally {
      global.setTimeout = origSetTimeout;
    }
  });

  it("throws when a check is not created within the timeout", async () => {
    const mockGithub = createMockGithub(async () => []);
    const origSetTimeout = global.setTimeout;
    global.setTimeout = (fn) => origSetTimeout(fn, 0);

    try {
      await assert.rejects(
        () => waitRequiredChecks({
          requiredChecks: ["missing-check"],
          owner: "owner",
          repo: "repo",
          headRef: "feature",
          timeoutMinutesCreatedChecks: 0, // immediate timeout
          timeoutMinutesQueuedChecks: 30,
          github: mockGithub,
        }),
        /wasn't created after/
      );
    } finally {
      global.setTimeout = origSetTimeout;
    }
  });

  it("throws when a check stays queued past the timeout", async () => {
    const mockGithub = createMockGithub(async () => [
      { id: 1, name: "build", status: "queued", conclusion: null, html_url: "https://example.com/1" },
    ]);
    const origSetTimeout = global.setTimeout;
    global.setTimeout = (fn) => origSetTimeout(fn, 0);

    try {
      await assert.rejects(
        () => waitRequiredChecks({
          requiredChecks: ["build"],
          owner: "owner",
          repo: "repo",
          headRef: "feature",
          timeoutMinutesCreatedChecks: 15,
          timeoutMinutesQueuedChecks: 0, // immediate timeout
          github: mockGithub,
        }),
        /is still queued after/
      );
    } finally {
      global.setTimeout = origSetTimeout;
    }
  });
});
