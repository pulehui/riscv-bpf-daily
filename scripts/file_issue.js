// SPDX-License-Identifier: Apache-2.0
const fs = require('fs');

module.exports = async ({ github, context, core }) => {
  const bpfBaseCommit = process.env.BPF_BASE_COMMIT || process.env.BPF_COMMIT || '';
  const repoCommit = context.sha;
  const kernelCommit = bpfBaseCommit || repoCommit;
  const commit12 = kernelCommit.slice(0, 12);

  const title = `Daily failed at commit ${commit12}`;

  // Determine failed testcase: only test_progs and test_verifier are specific, others become 'other'
  let testcase = '';
  if (process.env.TEST_PROGS_STATUS === 'failure') {
    testcase = 'test_progs';
  } else if (process.env.TEST_VERIFIER_STATUS === 'failure') {
    testcase = 'test_verifier';
  } else if (fs.existsSync('test_progs_errors.txt') && fs.readFileSync('test_progs_errors.txt', 'utf8').trim()) {
    testcase = 'test_progs';
  } else if (fs.existsSync('test_verifier_errors.txt') && fs.readFileSync('test_verifier_errors.txt', 'utf8').trim()) {
    testcase = 'test_verifier';
  } else {
    testcase = 'other';
  }

  // Extract error logs
  let errorLogs = '';
  if (testcase === 'test_progs') {
    if (fs.existsSync('test_progs_errors.txt')) {
      errorLogs = fs.readFileSync('test_progs_errors.txt', 'utf8').trim();
    }
    if (!errorLogs && fs.existsSync('test_progs.stdout')) {
      errorLogs = fs.readFileSync('test_progs.stdout', 'utf8').trim();
    }
  } else if (testcase === 'test_verifier') {
    if (fs.existsSync('test_verifier_errors.txt')) {
      errorLogs = fs.readFileSync('test_verifier_errors.txt', 'utf8').trim();
    }
    if (!errorLogs && fs.existsSync('test_verifier.stdout')) {
      errorLogs = fs.readFileSync('test_verifier.stdout', 'utf8').trim();
    }
  } else {
    // For 'other': copy log content verbatim without truncation
    for (const file of ['setup.stdout', 'bpf_vmtest.stdout']) {
      try {
        if (fs.existsSync(file)) {
          const content = fs.readFileSync(file, 'utf8').trim();
          if (content) {
            errorLogs = content;
            break;
          }
        }
      } catch (_) {}
    }
  }

  // Guard against GitHub issue character limit (65536 chars)
  if (errorLogs.length > 60000) {
    errorLogs = errorLogs.slice(0, 60000) + '\n... [Logs truncated due to size limit] ...';
  }

  const body = [
    `## riscv64 bpf vmtest failed`,
    ``,
    `- **Testcase:** ${testcase}`,
    `- **Kernel commit:** ${kernelCommit}`,
    `- **Run:** ${context.serverUrl}/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}`,
    ``,
    `### Error logs`,
    '```',
    errorLogs,
    '```',
  ].join('\n');

  // Always create a new issue for every failure run
  const { data: issue } = await github.rest.issues.create({
    ...context.repo,
    title,
    body,
    labels: [testcase],
  });
  core.info(`Created issue #${issue.number} with label [${testcase}]: ${title}`);
};
