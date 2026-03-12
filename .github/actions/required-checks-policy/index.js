// @actions/glob uses minimatch internally for pattern matching, so we use
// minimatch directly to match GitHub Actions' path filter behavior.
// @actions/glob itself is filesystem-based and cannot match patterns against strings.
const { minimatch } = require("minimatch");
const yaml = require("js-yaml");
const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const WL_NOT_REQUIRED_RE = /#\s*wl-not-required/;

/** @typedef {import("@actions/core")} Core */
/** @typedef {import("@octokit/core").Octokit & import("@octokit/plugin-rest-endpoint-methods/dist-types/types").Api & { paginate: Function }} GitHub */

/**
 * @typedef {Object} PolicyItem
 * @property {string[]} checks - Status check names that must succeed.
 * @property {string[]} paths - Pathspecs to match against changed files.
 */

/**
 * @typedef {Object} WlNotRequiredResult
 * @property {boolean} isWorkflowOptOut - Whether the entire workflow is opted out.
 * @property {string[]} optOutJobs - Job keys opted out.
 */

/**
 * @typedef {Object} CheckRun
 * @property {number} id - Unique identifier for the check run.
 * @property {string} name - The name of the check run.
 * @property {string} status - The current status (e.g. "queued", "in_progress", "completed").
 * @property {string|null} conclusion - The result of the check run (e.g. "success", "failure"), null if not completed.
 * @property {string} html_url - URL to the check run on GitHub.
 */

/**
 * @typedef {Object} WorkflowFile
 * @property {string} path - Relative path to the workflow file (e.g. ".github/workflows/build.yml").
 * @property {string} content - Raw YAML content of the workflow file.
 */

/** @type {Core} */
let _core;

/**
 * Executes a git command and returns trimmed stdout, or null on failure.
 * @param {...string} args - Git command arguments.
 * @returns {string | null}
 */
function git(...args) {
  try {
    return execFileSync("git", args, { encoding: "utf-8" }).trim();
  } catch {
    return null;
  }
}


/**
 * Resolves the base and head refs for the current event, applying fallbacks.
 * @param {Object} params
 * @param {string} params.commitId - The commit SHA (GITHUB_SHA).
 * @param {string} params.baseRef - The base ref (GITHUB_BASE_REF, empty on push events).
 * @param {string} params.headRef - The head ref (GITHUB_HEAD_REF, empty on push events).
 * @param {string} params.refName - The ref name (GITHUB_REF_NAME, fallback for headRef).
 * @param {string} params.defaultBranch - The repository default branch (fallback for baseRef).
 * @returns {{ baseRef: string, headRef: string }}
 */
function resolveRefs({ commitId, baseRef, headRef, refName, defaultBranch }) {
  if (!headRef) headRef = refName;
  if (!baseRef) {
    _core.info(`Base ref is not set. Falling back to default branch '${defaultBranch}'.`);
    baseRef = defaultBranch;
  }

  _core.info("Change description:");
  _core.info(`Commit ID: ${commitId}`);
  _core.info(`Base Ref: ${baseRef}`);
  _core.info(`Head Ref: ${headRef}`);
  _core.info("");

  return { baseRef, headRef };
}

/**
 * Loads and parses a JSON policy file from a git ref.
 * @param {string} policyPath - Path to the policy file, relative to the repo root.
 * @param {string} baseRef - Branch name to read the policy from.
 * @returns {PolicyItem[]} The parsed policy array.
 * @throws {Error} If the file doesn't exist or is empty.
 */
function importPolicyFromGit(policyPath, baseRef) {
  const fullBaseRef = `refs/remotes/origin/${baseRef}`;
  _core.info(`Loading policy at '${policyPath}' in ref '${baseRef}'`);

  const policyContent = git("show", `${fullBaseRef}:${policyPath}`);
  if (policyContent === null) {
    _core.startGroup("Available git references");
    _core.info(git("show-ref") ?? "No references found");
    _core.endGroup();

    _core.startGroup(`Available files in ${fullBaseRef}`);
    _core.info(git("ls-tree", "--full-tree", "-r", "--name-only", fullBaseRef) ?? "Could not list files");
    _core.endGroup();

    throw new Error(
      `Failed to load policy file from '${baseRef}' branch at '${policyPath}'. ` +
      `Make sure the file exists in the target branch and that the path is relative to the root of the repository.`
    );
  }

  const policy = JSON.parse(policyContent);
  if (!policy) {
    throw new Error("Policy is not defined or is empty.");
  }

  _core.startGroup("Policy details");
  _core.info(JSON.stringify(policy, null, 2));
  _core.endGroup();

  return policy;
}

/**
 * Returns the list of files changed between two refs using git diff.
 * @param {string} baseRef - Base branch name.
 * @param {string} headRef - Head branch name.
 * @returns {string[]} List of changed file paths.
 */
function getChangedFiles(baseRef, headRef) {
  const output = git("diff", "--name-only", `refs/remotes/origin/${baseRef}...refs/remotes/origin/${headRef}`);
  if (!output) return [];
  return output.split("\n").filter(Boolean);
}

/**
 * Evaluates a JSON policy against changed files and returns the required check names.
 * Uses git diff with pathspecs to determine which policy items match.
 * @param {PolicyItem[]} policy - The policy items to evaluate.
 * @param {string} baseRef - Base branch name.
 * @param {string} headRef - Head branch name.
 * @returns {string[]} Sorted, deduplicated list of required check names.
 */
function findRequiredChecks(policy, baseRef, headRef) {
  _core.startGroup("Finding required checks for changed files");
  const requiredChecks = new Set();

  for (const item of policy) {
    const { checks, paths } = item;
    const pathspecs = [];

    for (const path of paths) {
      if (!path) continue;
      if (path.startsWith("!")) {
        throw new Error(
          `Path exclusions starting with '!' are not supported in the policy. ` +
          `Please use ':(exclude)<path>' syntax instead. Invalid path: '${path}'`
        );
      }
      pathspecs.push(path);
    }

    if (pathspecs.length === 0) {
      _core.info("Warning: No valid paths found in policy item. Skipping.");
      continue;
    }

    const diff = git(
      "diff", "--name-only",
      `refs/remotes/origin/${baseRef}...refs/remotes/origin/${headRef}`,
      "--", ...pathspecs
    );

    if (diff) {
      _core.info(`Paths '${paths.join("', '")}' have changes. Adding required checks: ${checks.join(", ")}`);
      for (const check of checks) {
        requiredChecks.add(check);
      }
    }
  }

  _core.endGroup();
  _core.info("");
  return [...requiredChecks].sort();
}

/**
 * Polls the GitHub Checks API until all required checks complete or a timeout is reached.
 * @param {Object} params
 * @param {string[]} params.requiredChecks - Check names that must pass.
 * @param {string} params.owner - Repository owner.
 * @param {string} params.repo - Repository name.
 * @param {string} params.headRef - The commit ref to query check runs for.
 * @param {number} params.timeoutMinutesCreatedChecks - Max minutes to wait for a check to be created.
 * @param {number} params.timeoutMinutesQueuedChecks - Max minutes a check can remain queued.
 * @param {GitHub} params.github - Authenticated octokit instance from actions/github-script.
 * @returns {Promise<void>} Resolves when all checks pass.
 * @throws {Error} If a check fails, isn't created in time, or stays queued past the timeout.
 */
async function waitRequiredChecks({ requiredChecks, owner, repo, headRef, timeoutMinutesCreatedChecks, timeoutMinutesQueuedChecks, github }) {
  _core.info("Required checks for changed paths:");
  for (const check of requiredChecks) _core.info(`- ${check}`);
  _core.info("");
  _core.info("Waiting for required checks to complete...");

  let attempt = 0;
  const startedAt = Date.now();
  const timeoutCreatedMs = timeoutMinutesCreatedChecks * 60 * 1000;
  const timeoutQueuedMs = timeoutMinutesQueuedChecks * 60 * 1000;
  const completedCheckIds = new Set();

  while (true) {
    const checkRuns = await getCheckRuns({ owner, repo, ref: headRef, github });

    let completed = true;
    const newlyCompleted = [];
    const statusLines = [];

    for (const requiredCheck of requiredChecks) {
      const matching = checkRuns.filter(cr => cr.name === requiredCheck);

      if (matching.length === 0) {
        completed = false;
        statusLines.push(`- \u23f3 ${requiredCheck} (waiting to be created)`);
        if (Date.now() - startedAt > timeoutCreatedMs) {
          const checkNames = [...new Set(checkRuns.map(cr => cr.name))].sort().map(n => `- ${n}`).join("\n");
          throw new Error(
            `Check '${requiredCheck}' wasn't created after ${timeoutMinutesCreatedChecks} minutes ` +
            `(timeout-minutes-created-checks: ${timeoutMinutesCreatedChecks}). Available checks:\n${checkNames}`
          );
        }
      } else {
        for (const check of matching) {
          if (check.status === "completed") {
            if (check.conclusion !== "success") {
              statusLines.push(`- \u274c ${requiredCheck} (${check.conclusion})`);
              throw new Error(`Check '${requiredCheck}' failed with conclusion: ${check.conclusion}. Details: ${check.html_url}`);
            }
            statusLines.push(`- \u2705 ${requiredCheck}`);
            if (!completedCheckIds.has(check.id)) {
              newlyCompleted.push({ name: requiredCheck, id: check.id, url: check.html_url });
              completedCheckIds.add(check.id);
            }
          } else if (check.status === "queued") {
            completed = false;
            statusLines.push(`- \u23f3 ${requiredCheck} (queued)`);
            if (Date.now() - startedAt > timeoutQueuedMs) {
              throw new Error(
                `Check '${requiredCheck}' is still queued after ${timeoutMinutesQueuedChecks} minutes ` +
                `(timeout-minutes-queued-checks: ${timeoutMinutesQueuedChecks}). Details: ${check.html_url}`
              );
            }
          } else {
            completed = false;
            statusLines.push(`- \u23f3 ${requiredCheck} (${check.status})`);
          }
        }
      }
    }

    // Print check status summary
    _core.info(`\nStatus (attempt ${attempt + 1}):`);
    for (const line of statusLines) {
      _core.info(line);
    }

    // Print API response as collapsed details
    _core.startGroup("GitHub API response");
    _core.info(JSON.stringify(checkRuns, null, 2));
    _core.endGroup();

    for (const c of newlyCompleted) {
      _core.debug(`Check '${c.name}' completed successfully. Details: ${c.url}`);
    }

    if (completed) {
      _core.info("All required checks have passed.");
      return;
    }

    attempt++;
    const waitTime = Math.min(10 * attempt, 60);
    _core.info(``);
    _core.info(`Waiting ${waitTime}s before next check...`);
    _core.info(``);
    await new Promise(resolve => setTimeout(resolve, waitTime * 1000));
  }
}

/**
 * Fetches all check runs for a commit ref using the GitHub Checks API with pagination.
 * @param {Object} params
 * @param {string} params.owner - Repository owner.
 * @param {string} params.repo - Repository name.
 * @param {string} params.ref - The commit ref to query.
 * @param {GitHub} params.github - Authenticated octokit instance.
 * @returns {Promise<CheckRun[]>} Array of check run objects.
 */
async function getCheckRuns({ owner, repo, ref, github }) {
  return await github.paginate(
    github.rest.checks.listForRef,
    { owner, repo, ref, filter: "latest", per_page: 100 },
    (response) => response.data
  );
}

/**
 * Tests whether a file path matches a glob pattern using minimatch.
 * @param {string} value - The file path to test.
 * @param {string} pattern - The glob pattern to match against.
 * @returns {boolean}
 */
function testGlobMatch(value, pattern) {
  return minimatch(value, pattern, { dot: true });
}

/**
 * Reads all workflow YAML files from the .github/workflows/ directory on disk.
 * @returns {WorkflowFile[]} Array of workflow file objects with path and content.
 */
function getWorkflowFiles() {
  const workflowsDir = path.join(".github", "workflows");
  _core.info(`Listing workflow files from '${workflowsDir}'`);

  let files;
  try {
    files = fs.readdirSync(workflowsDir);
  } catch {
    _core.info("No workflow files found in .github/workflows/");
    return [];
  }

  const workflows = [];
  for (const file of files) {
    if (!/\.(yml|yaml)$/.test(file)) continue;
    const filePath = path.join(workflowsDir, file);
    const content = fs.readFileSync(filePath, "utf-8");
    if (content) {
      workflows.push({ path: filePath, content });
    }
  }

  _core.info(`Found ${workflows.length} workflow file(s)`);
  return workflows;
}

/**
 * Parses raw workflow YAML content to find `# wl-not-required` opt-out comments.
 * Detects opt-outs at two levels: workflow and job.
 * @param {string} rawContent - Raw YAML content of a workflow file.
 * @returns {WlNotRequiredResult}
 */
function findWlNotRequired(rawContent) {
  const result = {
    isWorkflowOptOut: false,
    optOutJobs: [],
  };

  const lines = rawContent.split("\n");

  // Check workflow-level opt-out: first non-empty line
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed === "") continue;
    if (WL_NOT_REQUIRED_RE.test(trimmed)) {
      result.isWorkflowOptOut = true;
    }
    break;
  }

  if (result.isWorkflowOptOut) return result;

  // Track jobs section to detect job-level opt-outs
  let inJobsSection = false;
  let previousLineIsOptOut = false;

  for (const line of lines) {
    const trimmed = line.trim();

    // Track top-level sections
    if (/^jobs\s*:/.test(line)) {
      inJobsSection = true;
      previousLineIsOptOut = false;
      continue;
    }
    // Any other top-level key resets
    if (/^\S/.test(line) && trimmed !== "" && !/^#/.test(trimmed)) {
      inJobsSection = false;
      previousLineIsOptOut = false;
      continue;
    }

    if (!inJobsSection) continue;

    // Check for wl-not-required comment
    if (WL_NOT_REQUIRED_RE.test(trimmed)) {
      previousLineIsOptOut = true;
      continue;
    }

    // Skip empty lines and other comments
    if (trimmed === "" || /^#/.test(trimmed)) {
      continue;
    }

    // This is a non-comment, non-empty line
    if (previousLineIsOptOut) {
      const match = trimmed.match(/^(\S+)\s*:/);
      if (match) {
        result.optOutJobs.push(match[1]);
      }
    }

    previousLineIsOptOut = false;
  }

  return result;
}

/**
 * Determines whether a workflow would trigger for the given event context.
 * Evaluates branch filters and path filters for push/pull_request triggers.
 * @param {string | string[] | Object} workflowOn - The parsed `on` value from the workflow YAML.
 * @param {string} baseRef - Base branch name (used for pull_request branch matching).
 * @param {string} headRef - Head branch name (used for push branch matching).
 * @param {string[]} changedFiles - List of changed file paths.
 * @returns {boolean} True if the workflow would trigger.
 */
function testWorkflowTriggers(workflowOn, baseRef, headRef, changedFiles) {
  // Normalize the 'on' value to a map of trigger configs
  const triggers = {};

  if (typeof workflowOn === "string") {
    triggers[workflowOn] = {};
  } else if (Array.isArray(workflowOn)) {
    for (const t of workflowOn) triggers[String(t)] = {};
  } else if (workflowOn && typeof workflowOn === "object") {
    for (const [key, val] of Object.entries(workflowOn)) {
      triggers[key] = val && typeof val === "object" && !Array.isArray(val) ? val : {};
    }
  }

  const relevantTriggers = ["push", "pull_request", "pull_request_target"];

  for (const triggerName of relevantTriggers) {
    if (!(triggerName in triggers)) {
      continue;
    }

    const config = triggers[triggerName];
    const branchToMatch = triggerName === "push" ? headRef : baseRef;

    // Check branch filters
    let branchMatch = true;
    if (config.branches && config.branches.length > 0) {
      branchMatch = config.branches.some(pattern => testGlobMatch(branchToMatch, pattern));
    }
    if (config["branches-ignore"] && config["branches-ignore"].length > 0) {
      if (config["branches-ignore"].some(pattern => testGlobMatch(branchToMatch, pattern))) {
        branchMatch = false;
      }
    }

    if (!branchMatch) continue;

    // Check path filters
    let pathMatch = true;
    if (config.paths && config.paths.length > 0) {
      pathMatch = changedFiles.some(file =>
        config.paths.some(pattern => testGlobMatch(file, pattern))
      );
    }
    if (config["paths-ignore"] && config["paths-ignore"].length > 0) {
      const allIgnored = changedFiles.every(file =>
        config["paths-ignore"].some(pattern => testGlobMatch(file, pattern))
      );
      if (allIgnored) pathMatch = false;
    }

    if (pathMatch) return true;
  }

  return false;
}

/**
 * Auto-discovers required checks by parsing workflow files from the base ref.
 * Evaluates each workflow's triggers and path filters against the changed files,
 * then collects job keys as required check names.
 * @param {string} baseRef - Base branch name.
 * @param {string} headRef - Head branch name.
 * @param {string[]} changedFiles - List of changed file paths.
 * @param {string} [currentWorkflowPath] - Relative path to the current workflow file (e.g. ".github/workflows/foo.yml") to exclude from discovery.
 * @returns {string[]} Sorted, deduplicated list of required check names.
 */
function findAutoDiscoveredChecks(baseRef, headRef, changedFiles, currentWorkflowPath) {
  _core.startGroup("Auto-discovering required checks from workflow files");

  const workflows = getWorkflowFiles();
  if (!workflows.length) {
    _core.info("No workflow files found. Skipping auto-discovery.");
    _core.endGroup();
    return [];
  }

  const requiredChecks = new Set();

  for (const wf of workflows) {
    _core.info(`Processing workflow: ${wf.path}`);

    if (currentWorkflowPath && path.normalize(wf.path) === path.normalize(currentWorkflowPath)) {
      _core.info("  Skipping current workflow to avoid self-wait deadlock.");
      continue;
    }

    const optOuts = findWlNotRequired(wf.content);
    if (optOuts.isWorkflowOptOut) {
      _core.info("  Workflow is opted out via wl-not-required");
      continue;
    }

    let parsed;
    try {
      parsed = yaml.load(wf.content);
    } catch {
      _core.info("  Failed to parse workflow YAML. Skipping.");
      continue;
    }

    if (!parsed) {
      continue;
    }

    // Get the 'on' key. js-yaml interprets bare 'on' as boolean true,
    // so the key becomes the string "true" in the parsed object.
    const onConfig = parsed.on ?? parsed.true;
    if (!onConfig) {
      _core.info("  No 'on' triggers found. Skipping.");
      continue;
    }

    // Check if the workflow has relevant triggers
    const relevant = ["push", "pull_request", "pull_request_target"];
    let hasRelevantTrigger = false;
    if (typeof onConfig === "string") {
      hasRelevantTrigger = relevant.includes(onConfig);
    } else if (Array.isArray(onConfig)) {
      hasRelevantTrigger = onConfig.some(t => relevant.includes(String(t)));
    } else if (typeof onConfig === "object") {
      hasRelevantTrigger = Object.keys(onConfig).some(k => relevant.includes(k));
    }

    if (!hasRelevantTrigger) {
      _core.info("  No push/pull_request triggers. Skipping.");
      continue;
    }

    const shouldTrigger = testWorkflowTriggers(onConfig, baseRef, headRef, changedFiles);
    if (!shouldTrigger) {
      _core.info("  Workflow would not trigger for this change. Skipping.");
      continue;
    }

    const jobs = parsed.jobs;
    if (!jobs) {
      _core.info("  No jobs found. Skipping.");
      continue;
    }

    for (const jobKey of Object.keys(jobs)) {
      if (optOuts.optOutJobs.includes(jobKey)) {
        _core.info(`  Job '${jobKey}' is opted out via wl-not-required`);
        continue;
      }
      _core.info(`  Adding required check: ${jobKey}`);
      requiredChecks.add(jobKey);
    }
  }

  _core.endGroup();
  _core.info("");
  return [...requiredChecks].sort();
}

/**
 * Main entry point called by actions/github-script.
 * Reads environment variables, determines changed files, evaluates policies
 * and auto-discovery, then waits for all required checks to complete.
 * @param {Object} params
 * @param {GitHub} params.github - Authenticated octokit instance.
 * @param {Object} params.context - GitHub Actions context object.
 * @param {Core} params.core - @actions/core for logging and setting outputs.
 * @returns {Promise<void>}
 */
async function run({ github, context, core }) {
  _core = core;

  const refs = resolveRefs({
    commitId: process.env.GITHUB_SHA,
    baseRef: process.env.GITHUB_BASE_REF,
    headRef: process.env.GITHUB_HEAD_REF,
    refName: process.env.GITHUB_REF_NAME,
    defaultBranch: process.env.REPOSITORY_DEFAULT_BRANCH,
  });

  const diff = getChangedFiles(refs.baseRef, refs.headRef);
  if (!diff.length) {
    core.info(`No changes detected between '${refs.baseRef}' and '${refs.headRef}'.`);
    return;
  }

  core.startGroup(`Changed files between '${refs.baseRef}' and '${refs.headRef}'`);
  for (const file of diff) core.info(`- ${file}`);
  core.endGroup();
  core.info("");

  let requiredChecks = [];

  if (process.env.CI_POLICY_PATH) {
    const policy = importPolicyFromGit(process.env.CI_POLICY_PATH, refs.baseRef);
    const policyChecks = findRequiredChecks(policy, refs.baseRef, refs.headRef);
    requiredChecks.push(...policyChecks);
  } else {
    core.info("'policyPath' input not set, skipping policy checks");
  }

  if (process.env.CI_AUTO_DISCOVER === "true") {
    // GITHUB_WORKFLOW_REF format: "{owner}/{repo}/.github/workflows/{file}@{ref}"
    const workflowRef = process.env.GITHUB_WORKFLOW_REF || "";
    const repoSlug = process.env.GITHUB_REPOSITORY || "";
    let currentWorkflowPath;
    if (workflowRef && repoSlug) {
      const prefix = repoSlug + "/";
      if (workflowRef.startsWith(prefix)) {
        currentWorkflowPath = workflowRef.slice(prefix.length).replace(/@.*$/, "");
      }
    }

    const autoChecks = findAutoDiscoveredChecks(refs.baseRef, refs.headRef, diff, currentWorkflowPath);
    requiredChecks.push(...autoChecks);
  }

  requiredChecks = [...new Set(requiredChecks)].sort();

  if (requiredChecks.length === 0) {
    if (process.env.CI_FAIL_IF_NO_POLICY === "true") {
      throw new Error("No required checks found for the changed paths, but 'failIfNoPolicy' is set to true.");
    }
    core.info("No required checks found for the changed paths.");
    return;
  }

  const [owner, repo] = process.env.GITHUB_REPOSITORY.split("/");
  await waitRequiredChecks({
    requiredChecks,
    owner,
    repo,
    headRef: refs.headRef,
    timeoutMinutesCreatedChecks: parseInt(process.env.CI_TIMEOUT_MINUTES_CREATED_CHECKS, 10),
    timeoutMinutesQueuedChecks: parseInt(process.env.CI_TIMEOUT_MINUTES_QUEUED_CHECKS, 10),
    github,
  });
}

module.exports = run;

// Export individual functions for testing
module.exports.resolveRefs = resolveRefs;
module.exports.importPolicyFromGit = importPolicyFromGit;
module.exports.getChangedFiles = getChangedFiles;
module.exports.findRequiredChecks = findRequiredChecks;
module.exports.waitRequiredChecks = waitRequiredChecks;
module.exports.getCheckRuns = getCheckRuns;
module.exports.testGlobMatch = testGlobMatch;
module.exports.getWorkflowFiles = getWorkflowFiles;
module.exports.findWlNotRequired = findWlNotRequired;
module.exports.testWorkflowTriggers = testWorkflowTriggers;
module.exports.findAutoDiscoveredChecks = findAutoDiscoveredChecks;
module.exports._setCore = (core) => { _core = core; };
