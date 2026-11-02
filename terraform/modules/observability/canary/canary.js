// External check of the uptime board, from outside the VPC: the same path a
// visitor takes (internet -> WAF -> ALB -> app). Runs every few minutes as a
// CloudWatch Synthetics canary; any failed step fails the run.
const synthetics = require('Synthetics');
const log = require('SyntheticsLogger');

const base = new URL(process.env.BASE_URL);

// Record status and timing only: no bodies or headers in the artifacts.
const stepConfig = {
  includeRequestHeaders: false,
  includeResponseHeaders: false,
  includeRequestBody: false,
  includeResponseBody: false,
  continueOnHttpStepFailure: false,
};

function request(path) {
  return {
    hostname: base.hostname,
    method: 'GET',
    path,
    port: 443,
    protocol: 'https:',
    headers: { 'User-Agent': synthetics.getCanaryUserAgentString() },
  };
}

function expect(status, check) {
  return async (res) => {
    if (res.statusCode !== status) {
      throw new Error(`expected HTTP ${status}, got ${res.statusCode}`);
    }
    if (!check) return;
    const body = await new Promise((resolve, reject) => {
      let data = '';
      res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => resolve(data));
      res.on('error', reject);
    });
    check(body);
  };
}

exports.handler = async () => {
  await synthetics.executeHttpStep('healthz', request('/healthz'), expect(200), stepConfig);

  await synthetics.executeHttpStep('board page', request('/'), expect(200, (body) => {
    if (!body.includes('Uptime board')) throw new Error('board page did not render');
  }), stepConfig);

  await synthetics.executeHttpStep('monitors api', request('/api/monitors'), expect(200, (body) => {
    const monitors = JSON.parse(body).monitors;
    if (!Array.isArray(monitors)) throw new Error('no monitors array');
    log.info(`board lists ${monitors.length} monitors`);
  }), stepConfig);
};
