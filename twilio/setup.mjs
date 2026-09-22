// One-shot Twilio setup for the Assistant app. Safe to re-run: it only creates what's missing.
//
//   1. API key for access tokens
//   2. VoIP push credential (from certs/voip.pem + certs/voip.key)
//   3. Deploys the Functions in ./functions
//   4. Points your number's voice webhook at /incoming (buys one with --buy)
//
// Needs ACCOUNT_SID and AUTH_TOKEN in .env.
import { execFileSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import twilio from 'twilio';

const envPath = new URL('./.env', import.meta.url);
const env = Object.fromEntries(
  (existsSync(envPath) ? readFileSync(envPath, 'utf8') : '')
    .split('\n')
    .filter((line) => line.includes('=') && !line.trim().startsWith('#'))
    .map((line) => [line.slice(0, line.indexOf('=')).trim(), line.slice(line.indexOf('=') + 1).trim()])
);
const save = () =>
  writeFileSync(envPath, Object.entries(env).map(([k, v]) => `${k}=${v ?? ''}`).join('\n') + '\n');

if (!env.ACCOUNT_SID || !env.AUTH_TOKEN) {
  console.error('Put ACCOUNT_SID and AUTH_TOKEN in twilio/.env first.');
  process.exit(1);
}
const client = twilio(env.ACCOUNT_SID, env.AUTH_TOKEN);
env.CLIENT_IDENTITY ||= 'owner';
env.APP_SECRET ||= randomBytes(24).toString('base64url');

if (!env.API_KEY_SID || !env.API_KEY_SECRET) {
  const key = await client.newKeys.create({ friendlyName: 'assistant-app' });
  env.API_KEY_SID = key.sid;
  env.API_KEY_SECRET = key.secret;
  console.log(`✓ API key ${key.sid}`);
}

if (!env.PUSH_CREDENTIAL_SID) {
  const cert = new URL('./certs/voip.pem', import.meta.url);
  const key = new URL('./certs/voip.key', import.meta.url);
  if (existsSync(cert) && existsSync(key)) {
    const credential = await client.chat.v2.credentials.create({
      type: 'apn',
      friendlyName: 'assistant-voip',
      certificate: readFileSync(cert, 'utf8'),
      privateKey: readFileSync(key, 'utf8'),
      // Debug builds from Xcode get sandbox pushes. Use false for TestFlight/App Store.
      sandbox: env.PUSH_SANDBOX !== 'false',
    });
    env.PUSH_CREDENTIAL_SID = credential.sid;
    console.log(`✓ Push credential ${credential.sid}`);
  } else {
    console.log('… No VoIP certificate in certs/ yet; calls will not ring the phone until one is added.');
  }
}
save();

console.log('… Deploying functions');
const output = execFileSync(
  'npx',
  ['twilio-run', 'deploy', '--service-name', 'assistant', '--override-existing-project', '--load-system-env'],
  { encoding: 'utf8', env: { ...process.env, ...env } }
);
const domain = output.match(/([a-z0-9-]+\.twil\.io)/)?.[1];
if (!domain) {
  console.error(output);
  process.exit(1);
}
env.FUNCTIONS_URL = `https://${domain}`;
save();
console.log(`✓ Functions at ${env.FUNCTIONS_URL}`);

let number = env.PHONE_NUMBER
  ? (await client.incomingPhoneNumbers.list({ phoneNumber: env.PHONE_NUMBER }))[0]
  : (await client.incomingPhoneNumbers.list({ limit: 1 }))[0];
if (!number && process.argv.includes('--buy')) {
  const [available] = await client.availablePhoneNumbers('US').local.list({ voiceEnabled: true, limit: 1 });
  number = await client.incomingPhoneNumbers.create({ phoneNumber: available.phoneNumber });
  console.log(`✓ Bought ${number.phoneNumber}`);
}
if (number) {
  await client.incomingPhoneNumbers(number.sid).update({
    voiceUrl: `${env.FUNCTIONS_URL}/incoming`,
    voiceMethod: 'POST',
  });
  env.PHONE_NUMBER = number.phoneNumber;
  save();
  console.log(`✓ ${number.phoneNumber} now rings the app`);
} else {
  console.log('… No phone number on the account. Re-run with --buy to buy one.');
}

// Bake the account into the build, so there's nothing to type in the app. Gitignored: the repo is public.
const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>BaseURL</key>
\t<string>${env.FUNCTIONS_URL}</string>
\t<key>Secret</key>
\t<string>${env.APP_SECRET}</string>
</dict>
</plist>
`;
const configPath = new URL('../Assistant/Resources/TwilioConfig.plist', import.meta.url);
writeFileSync(configPath, plist);
console.log('✓ Wrote Assistant/Resources/TwilioConfig.plist — rebuild and the app registers on its own');

console.log(`
Nothing to type in the app. To point a build at another account by hand,
Settings → Phone number:
  URL     ${env.FUNCTIONS_URL}
  Secret  ${env.APP_SECRET}
`);
