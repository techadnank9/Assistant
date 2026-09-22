// Runs when the <Dial> to the app ends. If the app never picked up, take a voicemail.
exports.handler = function (context, event, callback) {
  const twiml = new Twilio.twiml.VoiceResponse();
  if (event.DialCallStatus !== 'completed' && event.DialCallStatus !== 'answered') {
    twiml.say("Sorry, nobody can take your call right now. Please leave a message after the tone.");
    twiml.record({ maxLength: 120, playBeep: true });
  }
  twiml.hangup();
  callback(null, twiml);
};
