// Read-only proof against pinned upstream plus the exact PR76 gateway patch.
// Infrastructure collaborators are spies; no network or WhatsApp sends occur.
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import ts from 'typescript';
const source = process.argv[2] + '/src/';
if (!process.argv[2]) throw new Error('Pass the pinned, patched OpenWA checkout');
function load(file, dependencies = {}) {
  const exports = {};
  const js = ts.transpileModule(fs.readFileSync(source + file, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS, experimentalDecorators: true },
  }).outputText;
  vm.runInNewContext(js, { exports, require: id => dependencies[id] ?? {}, process, console, setTimeout });
  return exports;
}
const websocket = [], webhooks = [], database = [], logs = [], callbacks = [];
const logger = { debug: (...args) => logs.push(args), error: (...args) => logs.push(args) };
const eventsGateway = {
  emitMessageAck: (...args) => websocket.push(['message.ack', ...args]),
  emitGroupUpdate: (...args) => websocket.push(['group.update', ...args]),
};
const webhookService = { dispatch: (...args) => { webhooks.push(args); return Promise.resolve(); } };
const noopDecorator = () => () => {};
const gate = load('modules/session/individual-chat-gate.ts');
const identity = load('engine/identity/wa-id.ts');
const { MessageProjector } = load('modules/session/message-projector.service.ts', {
  '@nestjs/common': { Injectable: noopDecorator, Optional: noopDecorator },
  '@nestjs/typeorm': { InjectRepository: noopDecorator },
  typeorm: { In: value => value },
  '../message/message-status.util': {
    deliveryStatusToMessageStatus: () => 'READ', deliveryStatusToAck: () => 3, ackStatusTransitionFrom: () => ['SENT'],
  },
});
const projector = Object.assign(Object.create(MessageProjector.prototype), {
  engines: { isLive: () => true }, logger, eventsGateway, webhookService,
  messageRepository: { update: (...args) => { database.push(args); return Promise.resolve({ affected: 1 }); } },
  hookManager: { execute: () => Promise.resolve() },
});
const { SessionEngineLeafEvents } = load('modules/session/session-engine-leaf-events.ts');
const leaf = new SessionEngineLeafEvents({ eventsGateway, webhookService });
const { SessionEngineEventWiring } = load('modules/session/session-engine-event-wiring.ts');
const wiring = new SessionEngineEventWiring({ logger });
const wired = wiring.buildCallbacks('synthetic-session', {}, 'synthetic', {
  isLiveEngine: () => true, messages: projector, leafEvents: leaf,
});
const host = { getCallbacks: () => ({
  onMessageAck: (...args) => { callbacks.push(['ack', ...args]); wired.onMessageAck(...args); },
  onGroupEvent: data => { callbacks.push(['group', data]); wired.onGroupEvent(data); },
}) };
const client = new EventEmitter();
load('engine/adapters/wwebjs-message-events.ts', {
  '../../modules/session/individual-chat-gate': gate,
  '../identity/wa-id': identity,
  './wwebjs-messaging': { wwebjsAckToDeliveryStatus: () => 'read' },
}).registerWwebjsMessageEvents(client, host);
load('engine/adapters/wwebjs-group-events.ts').registerWwebjsGroupEvents(client, host);
for (const chatId of ['120363123456789@g.us', 'status@broadcast', '123@newsletter', '123@broadcast', undefined]) {
  client.emit('message_ack', {
    id: { _serialized: `true_${chatId}_PRIVATE_MESSAGE` },
    fromMe: true, from: '201000000000@c.us', to: chatId,
  }, 3);
}
for (const event of ['group_join', 'group_leave', 'group_update', 'group_membership_request']) {
  client.emit(event, {
    chatId: '120363123456789@g.us', author: '201000000001@c.us',
    recipientIds: ['201000000002@c.us'], type: 'description',
    body: 'Private group description', timestamp: 1700000000,
  });
}
// An alternate adapter cannot bypass the neutral wiring either.
wired.onGroupEvent({ kind: 'update', groupId: '120363@g.us', changes: { description: 'private' } });
assert.equal(callbacks.length, 0, 'group events must be rejected before engine callbacks');
assert.equal(websocket.length, 0);
assert.equal(webhooks.length, 0);
assert.equal(database.length, 0);
assert.equal(logs.length, 0);
client.emit('message_ack', { id: { _serialized: 'true_201000000001@c.us_DIRECT' }, fromMe: true, from: 'me@c.us', to: '201000000001@c.us' }, 3);
assert.equal(callbacks.length, 1, 'individual ACK must retain real gateway delivery');
assert.equal(websocket.length, 1);
assert.equal(webhooks.length, 1);
assert.equal(database.length, 1);
console.log(JSON.stringify({ callbacks, websocket, webhooks, database, logs }, null, 2));
