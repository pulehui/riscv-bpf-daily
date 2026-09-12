// SPDX-License-Identifier: Apache-2.0
const fs = require('fs');

module.exports = async ({ github, context, core }) => {
  const bpfCommit40 = process.env.BPF_COMMIT || '';
  const repoCommit40 = context.sha;
  const kernelCommit = bpfCommit40 || repoCommit40;
  const commit12 = kernelCommit.slice(0, 12);

  const title = `Daily failed at commit ${commit12}`;

  // Determine failed testcase
  const testcases = [];
  if (process.env.TEST_PROGS_STATUS === 'failure') {
    testcases.push('test_progs');
  }
  if (process.env.TEST_VERIFIER_STATUS === 'failure') {
    testcases.push('test_verifier');
  }
  if (testcases.length === 0) {
    if (fs.existsSync('test_progs_errors.txt') && fs.readFileSync('test_progs_errors.txt', 'utf8').trim()) {
      testcases.push('test_progs');
    } else if (fs.existsSync('test_verifier_errors.txt') && fs.readFileSync('test_verifier_errors.txt', 'utf8').trim()) {
      testcases.push('test_verifier');
    } else {
      testcases.push('setup');
    }
  }
  const testcaseStr = testcases.join(', ');

  // Extract focused error logs
  let errorLogs = '';
  if (process.env.TEST_PROGS_STATUS === 'failure' && fs.existsSync('test_progs_errors.txt')) {
    errorLogs = fs.readFileSync('test_progs_errors.txt', 'utf8').trim();
  } else if (process.env.TEST_VERIFIER_STATUS === 'failure' && fs.existsSync('test_verifier_errors.txt')) {
    errorLogs = fs.readFileSync('test_verifier_errors.txt', 'utf8').trim();
  }

  if (!errorLogs) {
    for (const file of ['test_progs_errors.txt', 'test_verifier_errors.txt']) {
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

  // Fallback: tail of stdout when focused error log file is missing
  if (!errorLogs) {
    for (const file of ['test_progs.stdout', 'test_verifier.stdout', 'setup.stdout']) {
      try {
        if (fs.existsSync(file)) {
          const tail = fs.readFileSync(file, 'utf8').split('\n').slice(-100).join('\n').trim();
          if (tail) {
            errorLogs = tail;
            break;
          }
        }
      } catch (_) {}
    }
  }

  const body = [
    `## riscv64 bpf vmtest failed`,
    ``,
    `- **Testcase:** ${testcaseStr}`,
    `- **Kernel commit:** ${kernelCommit}`,
    `- **Run:** ${context.serverUrl}/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}`,
    ``,
    `### Error logs`,
    '```',
    errorLogs,
    '```',
  ].join('\n');

  const { data: openIssues } = await github.rest.issues.listForRepo({
    ...context.repo,
    state: 'open',
    labels: 'bpf-vmtest',
  });

  const existing = openIssues.find(i => i.title.includes(commit12));
  if (existing) {
    await github.rest.issues.createComment({
      ...context.repo,
      issue_number: existing.number,
      body: `Recurring failure in run [${context.runId}](${context.serverUrl}/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}):\n\n${body}`,
    });
    core.info(`Appended failure comment to existing issue #${existing.number}`);
  } else {
    const { data: issue } = await github.rest.issues.create({
      ...context.repo,
      title,
      body,
      labels: ['bpf-vmtest', 'riscv64'],
    });
    core.info(`Created issue #${issue.number}: ${title}`);
  }
};
