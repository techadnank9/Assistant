// Voice webhook for the Twilio number: ring the iPhone app, and fall back to
// voicemail if nobody answers.
exports.handler = function (context, event, callback) {
  const twiml = new Twilio.twiml.VoiceResponse();
  const dial = twiml.dial({ timeout: 25, answerOnBridge: true, action: '/voicemail' });
  const client = dial.client();
  client.identity(context.CLIENT_IDENTITY || 'owner');
  // The app shows this and passes it to the agent.
  client.parameter({ name: 'caller', value: event.From || 'Unknown' });
  callback(null, twiml);
};
