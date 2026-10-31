#!/usr/bin/env python3
"""Authored process fixture for visible saved-key reconnection.

Root supplies already-built local binaries. Two unique --bridge-fixture UUIDs
isolate a real native module and companion; a same-user Unix relay submits the
private native-review DeckWire commands and observes exact DTO replies. It does
not click the native window or claim its pending-request receiver acceptance.
Fake Elgato is loopback-only, and the fake core never executes an action.
No installed profile, device, external service or SDK endpoint is used.
"""
import argparse
import errno
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import socket
import stat
import struct
import subprocess
import threading
import time
import uuid
from fixture_recovery import archive_recovery

MODULE = 'cafe.nero.plugin.streamdeck'
RUN = 'cafe.nero.neronook.run'
STOP = 'cafe.nero.neronook.stop'
OLD = {'plugin': 'authored.workflows', 'name': 'old_flow'}
NEW = {'plugin': 'authored.workflows', 'name': 'published_flow'}
OLD_ACTION = {'id': OLD['name'], 'title': 'Authored legacy flow', 'input': {'fields': []},
              'output': {'fields': []}, 'effect': 'localChange', 'cancellable': True,
              'timeoutSeconds': 300, 'completionTimeoutSeconds': 86400}
NEW_ACTION = {'id': NEW['name'], 'title': 'Authored published flow', 'input': {'fields': []},
              'output': {'fields': [{'name': 'reply', 'kind': 'string', 'required': True}]},
              'effect': 'readOnly', 'cancellable': True, 'timeoutSeconds': 300,
              'completionTimeoutSeconds': 300}
UNKNOWN = {'futureObject': {'array': ['café 🌿', 7, None, False], 'nested': {'n': 2.75}},
           'futureInteger': 1234567890123, 'futureNull': None, 'futureBoolean': True}
FRAME_LIMIT = 131072


def uid():
    return str(uuid.uuid4()).upper()


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


def canonical_sha(value):
    # Foundation JSONSerialization.sortedKeys retains slash escaping. These
    # authored values avoid unsupported floating/Unicode canonical edge cases.
    return hashlib.sha256(encoded(value).replace(b'/', b'\\/')).hexdigest()


def exact_json(left, right):
    assert encoded(left) == encoded(right), 'Complete JSON settings differ, including scalar types'


class Mailbox:
    def __init__(self, owner):
        self.owner = owner
        self.condition = threading.Condition()
        self.items = []

    def put(self, item):
        with self.condition:
            if len(self.items) >= 10000:
                self.owner.fail('Bounded fixture mailbox overflow')
                return
            self.items.append(item)
            self.condition.notify_all()

    def wait(self, predicate, seconds=10):
        end = time.monotonic() + seconds
        with self.condition:
            while True:
                self.owner.check()
                for index, item in enumerate(self.items):
                    if predicate(item):
                        return self.items.pop(index)
                left = end - time.monotonic()
                if left <= 0:
                    raise AssertionError('Expected fixture event did not arrive before its bounded deadline')
                self.condition.wait(min(left, .1))


class Fixture:
    def __init__(self, module_binary, companion_binary, include_old=True):
        self.module_binary, self.companion_binary = module_binary, companion_binary
        self.module_uuid, self.companion_uuid, self.session = uid(), uid(), uid()
        self.folders = [Path('/tmp') / ('nn-deck-test-' + str(os.getuid()) + '-' + value)
                        for value in [self.module_uuid, self.companion_uuid]]
        self.workers, self.threads, self.sockets = [], [], []
        self.errors, self.writes, self.actions, self.child_results = [], [], [], []
        self.cleanup_errors, self.folder_pins = [], {}
        self.ws_index = 0
        self.core_index = 0
        self.closing = False
        self.lock = threading.Lock()
        self.to_companion_lock = threading.Lock()
        self.to_module_lock = threading.Lock()
        self.ws_send_lock = threading.Lock()
        self.relay_condition = threading.Condition()
        self.core_messages, self.wires, self.ws_messages = [Mailbox(self) for _ in range(3)]
        self.forwarded_catalogs = Mailbox(self)
        self.current_relay = None
        self.relay_count = 0
        self.settings, self.kinds = {}, {}
        self.include_old = include_old

    def fail(self, message):
        with self.lock:
            self.errors.append(message)

    def check(self):
        with self.lock:
            assert not self.errors, self.errors[0] if self.errors else ''
            assert not self.actions, 'Fixture emitted an invoke/cancel; no provider action is allowed'

    def thread(self, function, *args):
        t = threading.Thread(target=function, args=args, daemon=True)
        self.threads.append(t)
        t.start()

    def process(self, label, args, stdin=None, stdout=None):
        p = subprocess.Popen(args, stdin=stdin, stdout=stdout, stderr=subprocess.PIPE, start_new_session=True)
        self.workers.append((label, p))
        self.thread(self.read_stderr, label, p.stderr)
        return p

    def read_stderr(self, label, pipe):
        count = 0
        try:
            while True:
                data = pipe.read(8192)
                if not data:
                    return
                count += len(data)
                if count > 262144:
                    self.fail(label + ' exceeded the bounded diagnostic stream')
                    return
        finally:
            pipe.close()

    def read_core(self):
        try:
            while True:
                line = self.core.stdout.readline(FRAME_LIMIT + 1)
                if not line:
                    return
                if len(line) > FRAME_LIMIT:
                    raise AssertionError('Oversize core frame')
                item = json.loads(line)
                with self.lock:
                    self.core_index += 1
                    item['_fixtureCoreIndex'] = self.core_index
                operation = item.get('bus', {}).get('operation')
                if operation in ('invoke', 'cancel'):
                    with self.lock:
                        self.actions.append(operation)
                self.core_messages.put(item)
        except Exception as error:
            if not self.closing:
                self.fail('Core reader: ' + type(error).__name__ + ': ' + str(error))
        finally:
            self.core.stdout.close()

    def core_send(self, body):
        frame = dict(apiVersion=1, pluginID=MODULE, session=self.session, sequence=0, **body)
        self.core.stdin.write(encoded(frame) + b'\n')
        self.core.stdin.flush()

    def catalog(self):
        generation = uid()
        entries = [{'address': NEW, 'action': NEW_ACTION}]
        if self.include_old:
            entries.insert(0, {'address': OLD, 'action': OLD_ACTION})
        for frame in [{'catalog': []}] + [{'catalog': [x]} for x in entries] + [{'complete': True}]:
            self.core_send({'type': 'bus', 'bus': dict(operation='catalog', requestID=generation, **frame)})
        return generation

    def wait_relay_after(self, previous, seconds=10):
        end = time.monotonic() + seconds
        with self.relay_condition:
            while self.relay_count <= previous:
                self.check()
                left = end - time.monotonic()
                if left <= 0:
                    raise AssertionError('A genuinely new relay epoch did not connect')
                self.relay_condition.wait(min(left, .1))
            return self.relay_count

    def catalog_forwarded(self, generation, epoch):
        self.forwarded_catalogs.wait(lambda x: x['epoch'] == epoch
            and x['message'].get('operation') == 'catalog'
            and x['message'].get('requestID') == generation
            and x['message'].get('complete') is True)
        with self.relay_condition:
            assert self.relay_count == epoch, 'Catalog witness belongs to a retired relay epoch'
        # The forwarded complete and this fresh status request enter the same
        # companion socket under one write lock. Its exact UUID reply therefore
        # proves the companion processed that catalog before later mutations.
        self.status()
        with self.relay_condition:
            assert self.relay_count == epoch, 'Relay changed during catalog/status handshake'

    def start(self):
        for folder in self.folders:
            assert not folder.exists(), 'Fresh fixture namespace unexpectedly exists'
        self.core = self.process('module', [str(self.module_binary), '--neronook-plugin', '--bridge-fixture', self.module_uuid],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.thread(self.read_core)
        self.core_send({'type': 'hello', 'features': ['actions-v1', 'dashboard-v1', 'panels-v1',
                        'custom-views-v1', 'presentation-v1', 'run-display-v1']})
        self.core_messages.wait(lambda x: x.get('type') == 'ready')
        self.core_messages.wait(lambda x: x.get('bus', {}).get('operation') == 'register')
        self.folders[1].mkdir(mode=0o700)
        self.remember_folder(self.folders[1])
        self.unix_listener = socket.socket(socket.AF_UNIX)
        self.unix_listener.bind(str(self.folders[1] / 'bridge.sock'))
        os.chmod(self.folders[1] / 'bridge.sock', 0o600)
        self.unix_listener.listen(2)
        self.unix_listener.settimeout(.2)
        self.sockets.append(self.unix_listener)
        self.thread(self.accept_relays)
        listener = socket.socket()
        listener.bind(('127.0.0.1', 0)); listener.listen(1); listener.settimeout(10)
        self.sockets.append(listener)
        self.client = self.process('companion', [str(self.companion_binary), '-port', str(listener.getsockname()[1]),
            '-pluginUUID', 'authored-fixture', '-registerEvent', 'registerPlugin', '-info',
            json.dumps({'devices': [{'id': 'authored-deck', 'name': 'Authored Deck', 'type': 7,
                                    'size': {'columns': 4, 'rows': 2}}]}), '--bridge-fixture', self.companion_uuid],
            stdout=subprocess.DEVNULL)
        self.ws, _ = listener.accept(); self.sockets.append(self.ws)
        self.ws.settimeout(10)
        headers = b''
        while b'\r\n\r\n' not in headers:
            headers += self.ws.recv(4096)
            assert len(headers) <= 16384
        key = next(line.split(b':', 1)[1].strip() for line in headers.split(b'\r\n')
                   if line.lower().startswith(b'sec-websocket-key:'))
        accept = base64.b64encode(hashlib.sha1(key + b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
        self.ws.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + b'\r\n\r\n')
        self.ws.settimeout(None)
        self.thread(self.read_ws)
        self.ws_messages.wait(lambda x: x.get('event') == 'registerPlugin')
        self.core_messages.wait(lambda x: x.get('bus', {}).get('operation') == 'discover')
        epoch = self.wait_relay_after(0)
        self.catalog_forwarded(self.catalog(), epoch)
        self.wires.wait(lambda x: x.get('deckEvent') == 'device' and x.get('device', {}).get('id') == 'authored-deck')
        self.remember_folder(self.folders[0])
        return self

    def remember_folder(self, folder):
        value = os.lstat(folder)
        assert stat.S_ISDIR(value.st_mode) and value.st_uid == os.getuid() and stat.S_IMODE(value.st_mode) == 0o700
        self.folder_pins[str(folder)] = (value.st_dev, value.st_ino)

    def accept_relays(self):
        while not self.closing:
            try:
                downstream, _ = self.unix_listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            if self.closing:
                downstream.close()
                return
            upstream = socket.socket(socket.AF_UNIX)
            try:
                upstream.connect(str(self.folders[0] / 'bridge.sock'))
            except OSError:
                downstream.close(); upstream.close()
                continue
            self.sockets.extend([upstream, downstream])
            with self.relay_condition:
                self.current_relay = (upstream, downstream)
                self.relay_count += 1
                epoch = self.relay_count
                self.relay_condition.notify_all()
            self.thread(self.relay, upstream, downstream, False, epoch)
            self.thread(self.relay, downstream, upstream, True, epoch)

    def relay(self, source, destination, from_companion, epoch):
        stream = source.makefile('rb')
        try:
            while not self.closing:
                line = stream.readline(FRAME_LIMIT + 1)
                if not line:
                    break
                assert len(line) <= FRAME_LIMIT
                if from_companion:
                    item = json.loads(line)
                    if item.get('operation') in ('invoke', 'cancel'):
                        with self.lock:
                            self.actions.append(item['operation'])
                    self.wires.put(item)
                lock = self.to_module_lock if from_companion else self.to_companion_lock
                with lock:
                    destination.sendall(line)
                    if not from_companion:
                        message = json.loads(line)
                        if message.get('operation') == 'catalog' and message.get('complete') is True:
                            self.forwarded_catalogs.put({'epoch': epoch, 'message': message})
        except (OSError, ValueError):
            pass  # A deliberate relay disconnect is part of one case.
        except Exception as error:
            if not self.closing:
                self.fail('Relay: ' + type(error).__name__ + ': ' + str(error))
        finally:
            stream.close()
            for peer in (source, destination):
                try:
                    peer.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

    def command(self, command, payload=None):
        request = uid()
        frame = {'deckEvent': 'command', 'command': command, 'request': request,
                 'rebindingCommand': payload or {}}
        assert self.current_relay is not None
        with self.to_companion_lock:
            self.current_relay[1].sendall(encoded(frame) + b'\n')
        return request

    def result(self, request, phases=None, seconds=10):
        item = self.wires.wait(lambda x: x.get('deckEvent') == 'rebinding'
            and x.get('request', '').lower() == request.lower()
            and (phases is None or x.get('rebinding', {}).get('phase') in phases), seconds)
        assert item['request'] == request, 'Response did not echo its exact canonical request'
        return item['rebinding']

    def status(self):
        return self.result(self.command('rebind_status'))

    @staticmethod
    def read_exact(sock, count):
        value = b''
        while len(value) < count:
            part = sock.recv(count - len(value))
            if not part:
                raise EOFError()
            value += part
        return value

    def read_ws(self):
        try:
            while not self.closing:
                a, b = self.read_exact(self.ws, 2)
                length = b & 127
                if length == 126:
                    length = struct.unpack('!H', self.read_exact(self.ws, 2))[0]
                elif length == 127:
                    length = struct.unpack('!Q', self.read_exact(self.ws, 8))[0]
                assert length <= FRAME_LIMIT
                mask = self.read_exact(self.ws, 4) if b & 128 else b''
                data = self.read_exact(self.ws, length)
                if mask:
                    data = bytes(value ^ mask[index % 4] for index, value in enumerate(data))
                if a & 15 == 8:
                    return
                if a & 15 == 9:
                    with self.ws_send_lock:
                        self.ws.sendall(b'\x8a' + bytes([len(data)]) + data)
                    continue
                if a & 15 != 1:
                    continue
                item = json.loads(data)
                self.ws_index += 1
                item['_fixtureWSIndex'] = self.ws_index
                if item.get('event') == 'setSettings':
                    with self.lock:
                        self.writes.append(item)
                if item.get('event') not in ('setImage', 'setFeedback', 'setFeedbackLayout'):
                    self.ws_messages.put(item)
        except (EOFError, OSError):
            if not self.closing:
                self.fail('Fake Elgato socket closed before fixture cleanup')
        except Exception as error:
            if not self.closing:
                self.fail('Fake Elgato reader: ' + type(error).__name__ + ': ' + str(error))

    def ws_send(self, value):
        data = encoded(value); length = len(data)
        assert length <= FRAME_LIMIT
        header = b'\x81' + (bytes([length]) if length < 126 else
                             b'\x7e' + struct.pack('!H', length) if length < 65536 else
                             b'\x7f' + struct.pack('!Q', length))
        with self.ws_send_lock:
            self.ws.sendall(header + data)

    def announce(self, context, kind=RUN, address=OLD, column=0, settings=None):
        value = copy.deepcopy(settings if settings is not None else dict(UNKNOWN,
            provider=address['plugin'], name=address['name'], arguments='{}', label='Authored ' + context))
        self.settings[context], self.kinds[context] = value, kind
        self.ws_send({'event': 'willAppear', 'action': kind, 'context': context, 'device': 'authored-deck',
                      'payload': {'controller': 'Keypad', 'coordinates': {'column': column, 'row': 0}, 'settings': value}})
        self.wires.wait(lambda x: x.get('deckEvent') == 'slot' and x.get('slot', {}).get('context') == context)
        # A complete inspector catalog proves the companion consumed the granted
        # catalog before this case prepares its private native review.
        self.ws_messages.wait(lambda x: x.get('event') == 'sendToPropertyInspector'
            and x.get('context') == context and x.get('payload', {}).get('complete') is True)

    def readback(self, context, settings=None):
        value = copy.deepcopy(self.settings[context] if settings is None else settings)
        self.settings[context] = value
        self.ws_send({'event': 'didReceiveSettings', 'action': self.kinds[context], 'context': context,
                      'payload': {'settings': value}})

    def get_settings(self, context):
        return self.ws_messages.wait(lambda x: x.get('event') == 'getSettings' and x.get('context') == context)

    def set_settings(self, context):
        item = self.ws_messages.wait(lambda x: x.get('event') == 'setSettings' and x.get('context') == context)
        return item['payload']

    def write_count(self):
        with self.lock:
            return len(self.writes)

    def barrier(self, context):
        # A new read-only refresh produces getSettings then a complete catalog
        # on the same FIFO WebSocket as writes. Sequence-tagged complete avoids
        # accepting an older queued inspector snapshot as this barrier.
        self.ws_send({'event': 'sendToPlugin', 'action': self.kinds[context], 'context': context,
                      'payload': {'refresh': True, 'readSettings': True}})
        marker = self.get_settings(context)['_fixtureWSIndex']
        self.ws_messages.wait(lambda x: x.get('event') == 'sendToPropertyInspector'
            and x.get('context') == context and x.get('payload', {}).get('complete') is True
            and x['_fixtureWSIndex'] > marker)
        self.status()  # UDS FIFO acknowledgment also drains earlier bus effects.
        self.check()

    def prepare(self, contexts):
        count = self.write_count()
        view = self.result(self.command('rebind_prepare', {'contexts': contexts, 'source': OLD, 'target': NEW}), ['review'])
        assert view['visibleOnly'] is True and len(view['rows']) == len(contexts)
        assert view['source'] == OLD and view['target'] == NEW
        assert view['newAction'] == NEW_ACTION
        if self.include_old:
            assert view['oldAction'] == OLD_ACTION
        else:
            assert 'oldAction' not in view
        for row in view['rows']:
            original = self.settings[row['context']]
            after = dict(original, provider=NEW['plugin'], name=NEW['name'])
            assert row['beforeSHA256'] == canonical_sha(original)
            assert row['afterSHA256'] == canonical_sha(after)
            assert row['unknownFieldCount'] == len(UNKNOWN)
        assert self.write_count() == count, 'Prepare wrote settings'
        return view

    def apply(self, review):
        request = self.command('rebind_apply', {'reviewID': review['reviewID']})
        self.result(request, ['applying'])
        return request

    def confirm_row(self, context, expected, write_count_before):
        self.get_settings(context)
        assert self.write_count() == write_count_before, 'Write preceded fresh before-settings'
        self.readback(context)
        # Durable intent is followed by another real before-read. Its callback
        # must still precede any write, including after a delayed disk commit.
        self.get_settings(context)
        assert self.write_count() == write_count_before, 'Write preceded post-intent fresh settings'
        self.readback(context)
        actual = self.set_settings(context)
        exact_json(actual, expected)
        self.get_settings(context)
        return actual

    def assert_writes(self, count):
        self.check()
        assert self.write_count() == count, 'Unexpected later/repeated settings write'

    def close(self):
        self.closing = True
        # Closing fake WS and stdin asks both actual native processes to exit
        # through their ordinary EOF paths. Any fallback signal is explicit.
        if hasattr(self, 'ws'):
            try:
                with self.ws_send_lock:
                    self.ws.sendall(b'\x88\x00')
            except OSError:
                pass
        if hasattr(self, 'core') and self.core.stdin:
            try:
                self.core.stdin.close()
            except OSError:
                pass
        for sock in self.sockets:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            sock.close()
        for label, child in self.workers:
            cleanup_signal = None
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                cleanup_signal = 'SIGTERM'
                child.terminate()
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    cleanup_signal = 'SIGTERM then SIGKILL'
                    child.kill(); child.wait()
            try:
                os.killpg(child.pid, 0); absent = False
            except ProcessLookupError:
                absent = True
            self.child_results.append({'role': label, 'exitCode': child.returncode,
                'cleanupSignal': cleanup_signal, 'groupAbsent': absent})
        for thread in self.threads:
            thread.join(timeout=3)
        if any(t.is_alive() for t in self.threads):
            self.cleanup_errors.append('Fixture reader/relay did not join')
        for folder in self.folders:
            try:
                if os.path.lexists(folder):
                    assert folder.parent == Path('/tmp') and str(os.getuid()) in folder.name
                    value = os.lstat(folder)
                    assert stat.S_ISDIR(value.st_mode) and value.st_uid == os.getuid() and stat.S_IMODE(value.st_mode) == 0o700
                    expected = self.folder_pins.get(str(folder))
                    if expected is None:
                        # Startup may fail before its first native event. The
                        # random namespace was proved absent before this child;
                        # only its exact fixed entries are considered below.
                        expected = (value.st_dev, value.st_ino)
                    assert (value.st_dev, value.st_ino) == expected
                    for name in ['bridge.sock', 'owner.lock']:
                        path = folder / name
                        if os.path.lexists(path):
                            entry = os.lstat(path)
                            assert entry.st_uid == os.getuid() and stat.S_IMODE(entry.st_mode) == 0o600
                            assert (stat.S_ISSOCK(entry.st_mode) if name == 'bridge.sock' else stat.S_ISREG(entry.st_mode))
                            path.unlink()
                    archive_recovery(folder)
                    folder.rmdir()
            except Exception as error:
                self.cleanup_errors.append('Owned namespace cleanup: ' + type(error).__name__ + ': ' + str(error))
        return self.child_results


def success_and_conditional_undo(f):
    f.announce('run', RUN, column=0); f.announce('stop', STOP, column=1)
    before = copy.deepcopy(f.settings)
    view = f.prepare(['run', 'stop'])
    assert f.status()['reviewID'] == view['reviewID']
    request = f.apply(view)
    after_run = dict(before['run'], provider=NEW['plugin'], name=NEW['name'])
    f.confirm_row('run', after_run, 0)
    assert f.status()['phase'] == 'applying'
    f.assert_writes(1)  # Stop cannot begin until Run's complete after-ack.
    f.readback('run', after_run)
    after_stop = dict(before['stop'], provider=NEW['plugin'], name=NEW['name'])
    f.confirm_row('stop', after_stop, 1)
    f.readback('stop', after_stop)
    done = f.result(request, ['complete'])
    assert [r['outcome'] for r in done['rows']] == ['confirmed', 'confirmed']
    receipts = {r['context']: r['receiptID'] for r in done['rows']}
    changed = copy.deepcopy(after_stop); changed['futureObject']['nested']['n'] = 9.25
    changed['label'] = 'Authored external edit'
    f.readback('stop', changed)
    f.ws_messages.wait(lambda x: x.get('event') == 'sendToPropertyInspector' and x.get('context') == 'stop'
        and x.get('payload', {}).get('complete') is True and x.get('payload', {}).get('settings', {}).get('label') == changed['label'])
    rejected = f.command('rebind_undo', {'receiptID': receipts['stop']})
    f.result(rejected, ['rejected']); f.barrier('stop'); f.assert_writes(2)
    f.readback('stop', after_stop)
    f.barrier('stop')
    for index, context in enumerate(['stop', 'run']):
        undo = f.command('rebind_undo', {'receiptID': receipts[context]})
        f.result(undo, ['applying'])
        f.confirm_row(context, before[context], 2 + index)
        f.readback(context, before[context])
        f.result(undo, ['undone'])
    f.barrier('run'); f.assert_writes(4)


def conflict_stops_later_rows(f):
    for index, (context, kind) in enumerate([('first', RUN), ('second', STOP), ('third', RUN)]):
        f.announce(context, kind, column=index)
    view = f.prepare(['first', 'second', 'third']); request = f.apply(view)
    first = dict(f.settings['first'], provider=NEW['plugin'], name=NEW['name'])
    f.confirm_row('first', first, 0); f.readback('first', first)
    second = dict(f.settings['second'], provider=NEW['plugin'], name=NEW['name'])
    f.confirm_row('second', second, 1)
    different = copy.deepcopy(second); different['futureNull'] = 'external change'
    f.readback('second', different)
    result = f.result(request, ['partial'])
    assert [row['outcome'] for row in result['rows']] == ['confirmed', 'conflict', 'notAttempted']
    f.status(); f.barrier('second'); f.assert_writes(2)


def cancel_stops_future_writes(f):
    f.announce('first', RUN); f.announce('second', STOP, column=1)
    view = f.prepare(['first', 'second']); request = f.apply(view)
    after = dict(f.settings['first'], provider=NEW['plugin'], name=NEW['name'])
    f.confirm_row('first', after, 0)
    close = f.command('rebind_close', {'reviewID': view['reviewID']})
    f.result(close, ['applying'])
    f.readback('first', after)
    result = f.result(request, ['partial'])
    assert [row['outcome'] for row in result['rows']] == ['confirmed', 'notAttempted']
    f.status(); f.barrier('first'); f.assert_writes(1)


def timeout_barriers_and_reconnect(f):
    f.announce('first', RUN); f.announce('paired-stop', STOP, column=1)
    f.announce('new-target', RUN, address=NEW, column=2)
    view = f.prepare(['first', 'paired-stop']); request = f.apply(view)
    after = dict(f.settings['first'], provider=NEW['plugin'], name=NEW['name'])
    f.confirm_row('first', after, 0)
    for context in ['first', 'new-target']:
        f.ws_send({'event': 'keyDown', 'action': RUN, 'context': context, 'payload': {}})
        f.ws_messages.wait(lambda x: x.get('event') == 'setTitle' and x.get('context') == context
                           and x.get('payload', {}).get('title') == 'Updating\nkeys')
    f.ws_send({'event': 'keyDown', 'action': STOP, 'context': 'paired-stop', 'payload': {}})
    f.wires.wait(lambda x: x.get('deckEvent') == 'result' and 'No active run' in x.get('message', ''))
    result = f.result(request, ['unconfirmed'], seconds=16)  # One actual bounded timeout, not an injected clock.
    assert [r['outcome'] for r in result['rows']] == ['unconfirmed', 'notAttempted']
    f.barrier('first'); f.assert_writes(1)
    for context in ['first', 'new-target']:
        f.ws_send({'event': 'keyDown', 'action': RUN, 'context': context, 'payload': {}})
        f.ws_messages.wait(lambda x: x.get('event') == 'setTitle' and x.get('context') == context
                           and x.get('payload', {}).get('title') == 'Reload\nmapping')
    with f.relay_condition:
        count = f.relay_count
        previous_relay = f.current_relay
    with f.lock:
        core_marker = f.core_index
    for sock in previous_relay:
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError as error:
            # Shutting down one endpoint can let its reader close the other
            # before this loop reaches it. Only already-disconnected is benign;
            # a fresh relay/forwarded catalog is still required below.
            if error.errno != errno.ENOTCONN:
                raise
    epoch = f.wait_relay_after(count)
    # Supplement the actual new connection with a new module accept/forward
    # observation. Old startup discovers may remain queued, but their causal
    # read index is strictly below this pre-disconnect marker.
    f.core_messages.wait(lambda x: x.get('bus', {}).get('operation') == 'discover'
        and x['_fixtureCoreIndex'] > core_marker, seconds=10)
    f.catalog_forwarded(f.catalog(), epoch)
    assert f.relay_count > count
    status = f.status()
    assert status['phase'] in ['closed', 'unconfirmed']
    stale = f.command('rebind_apply', {'reviewID': view['reviewID']})
    f.result(stale, ['rejected'])
    f.barrier('first'); f.assert_writes(1)


def absent_original_restores_inert(f):
    f.announce('only', RUN)
    before = copy.deepcopy(f.settings['only'])
    view = f.prepare(['only']); request = f.apply(view)
    after = dict(before, provider=NEW['plugin'], name=NEW['name'])
    f.confirm_row('only', after, 0); f.readback('only', after)
    result = f.result(request, ['complete'])
    undo = f.command('rebind_undo', {'receiptID': result['rows'][0]['receiptID']})
    f.result(undo, ['applying']); f.confirm_row('only', before, 1); f.readback('only', before)
    f.result(undo, ['undone']); f.assert_writes(2)
    f.ws_send({'event': 'keyDown', 'action': RUN, 'context': 'only', 'payload': {}})
    f.ws_messages.wait(lambda x: x.get('event') == 'setTitle' and x.get('context') == 'only'
                       and x.get('payload', {}).get('title') == 'Allow in\nNeroNook')
    f.status(); f.barrier('only'); f.check()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--module-binary', required=True, type=Path)
    parser.add_argument('--companion-binary', required=True, type=Path)
    args = parser.parse_args()
    module, companion = args.module_binary.resolve(strict=True), args.companion_binary.resolve(strict=True)
    assert module.is_file() and companion.is_file()
    assert not str(module).startswith('/Applications/') and '/Library/Application Support/NeroNook/Plugins/' not in str(module)
    assert not str(companion).startswith('/Applications/') and '/Library/Application Support/NeroNook/Plugins/' not in str(companion)
    signature_checks = []
    for binary in dict.fromkeys([module, companion]):
        checked = subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(binary)], capture_output=True)
        assert checked.returncode == 0, 'Fixture requires the prebuilt signed local candidate'
        signature_checks.append({'binary': str(binary), 'exitCode': checked.returncode})
    results = []
    for name, case, include_old in [
        ('paired_apply_conditional_undo', success_and_conditional_undo, True),
        ('partial_conflict_no_later_write', conflict_stops_later_rows, True),
        ('cancel_after_inflight_write', cancel_stops_future_writes, True),
        ('actual_timeout_barriers_reconnect_no_replay', timeout_barriers_and_reconnect, True),
        ('absent_original_inert_undo', absent_original_restores_inert, False)]:
        fixture = Fixture(module, companion, include_old)
        passed = False
        try:
            fixture.start(); case(fixture); fixture.check(); passed = True
        finally:
            children = fixture.close()
            print(json.dumps({'case': name, 'passed': passed, 'children': children,
                              'cleanupErrors': fixture.cleanup_errors}, sort_keys=True), flush=True)
        assert not fixture.cleanup_errors, 'Fixture cleanup was incomplete'
        assert all(x['exitCode'] == 0 and x['cleanupSignal'] is None and x['groupAbsent'] for x in children), 'Native fixture cleanup did not qualify naturally'
        results.append(name)
    print(json.dumps({'status': 'PASS', 'cases': results, 'signatureChecks': signature_checks,
        'scope': 'Actual isolated module/companion and fake Elgato/core; private relay command submission, not native UI clicks; no invokes/cancels, profiles or hardware.'}, sort_keys=True))


if __name__ == '__main__':
    main()
