// SPDX-License-Identifier: Apache-2.0
const fs = require('fs');

module.exports = async ({ github, context, core }) => {
  const bpfCommit40 = process.env.BPF_COMMIT || '';
  const repoCommit40 = context.sha;
  const commit12 = (bpfCommit40 || repoCommit40).slice(0, 12);
  const title = `Daily failed at commit ${commit12}`;

  let errorLogs = '';
  try {
    errorLogs = fs.readFileSync('bpf_error_logs.txt', 'utf8').trim();
  } catch (_) {}

  const errorSection = errorLogs
    ? `### Error logs\n\`\`\`\n${errorLogs}\n\`\`\``
    : (() => {
        let stdoutTail = '';
        try {
          stdoutTail = fs.readFileSync('bpf_vmtest.stdout', 'utf8').split('\n').slice(-120).join('\n');
        } catch (_) {}
        return `### Error logs\n_(All error logs 段缺失，以下为 stdout 末尾兜底)_\n\`\`\`\n${stdoutTail}\n\`\`\``;
      })();

  const bpfLine = bpfCommit40
    ? `**bpf-next tested:** \`master@${bpfCommit40}\` (https://git.kernel.org/pub/scm/linux/kernel/git/bpf/bpf-next.git/commit/?id=${bpfCommit40})`
    : `**bpf-next tested:** \`master\``;

  const body = [
    `## RISC-V BPF vmtest failed`,
    ``,
    `- **Run:** ${context.serverUrl}/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}`,
    `- ${bpfLine}`,
    `- **repo commit:** \`${repoCommit40}\``,
    ``,
    errorSection,
    ``,
    `Full log: \`bpf_vmtest-log\` artifact of run ${context.runId}.`,
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
