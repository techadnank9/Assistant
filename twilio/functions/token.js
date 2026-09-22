// Issues a Twilio access token so the iPhone app can register for incoming calls.
// POST { "secret": APP_SECRET } → { "token": "..." }
const crypto = require('crypto');

function sameSecret(given, expected) {
  const a = Buffer.from(String(given || ''));
  const b = Buffer.from(String(expected || ''));
  return a.length === b.length && b.length > 0 && crypto.timingSafeEqual(a, b);
}

exports.handler = function (context, event, callback) {
  const response = new Twilio.Response();
  response.appendHeader('Content-Type', 'application/json');

  if (!sameSecret(event.secret, context.APP_SECRET)) {
    response.setStatusCode(401);
    response.setBody({ error: 'unauthorized' });
    return callback(null, response);
  }

  const { AccessToken } = Twilio.jwt;
  const identity = context.CLIENT_IDENTITY || 'owner';
  const token = new AccessToken(context.ACCOUNT_SID, context.API_KEY_SID, context.API_KEY_SECRET, {
    identity,
    ttl: 3600,
  });
  token.addGrant(
    new AccessToken.VoiceGrant({
      incomingAllow: true,
      pushCredentialSid: context.PUSH_CREDENTIAL_SID,
    })
  );

  response.setBody({ token: token.toJwt(), identity });
  callback(null, response);
};
