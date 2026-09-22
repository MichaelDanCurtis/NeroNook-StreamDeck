#!/usr/bin/env python3
"""Exercise both native processes with a local fake Elgato WebSocket and core peer.
No device, real profile, external network or action settings are touched.
"""
import base64, hashlib, json, os, queue, socket, struct, subprocess, threading, time, uuid
from pathlib import Path
root = Path(__file__).resolve().parents[1]
binary = root / 'build/Stream Deck Module.app/Contents/MacOS/StreamDeckPlugin'
module_id = 'cafe.nero.plugin.streamdeck'
session = str(uuid.uuid4())
fixture = str(uuid.uuid4()).upper()
messages = queue.Queue()
workers = []
listener = socket.socket(); listener.bind(('127.0.0.1', 0)); listener.listen(1); listener.settimeout(10)

def begin_core():
    p = subprocess.Popen([str(binary), '--neronook-plugin', '--bridge-fixture', fixture], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    workers.append(p)
    threading.Thread(target=lambda: [messages.put(json.loads(line)) for line in p.stdout], daemon=True).start()
    send_core(p, {'type':'hello','features':['actions-v1','dashboard-v1','panels-v1']})
    return p

def send_core(p, body):
    p.stdin.write((json.dumps(dict(apiVersion=1,pluginID=module_id,session=session,sequence=0,**body))+'\n').encode());p.stdin.flush()

def wait_core(predicate, seconds=10):
    until = time.monotonic()+seconds
    while time.monotonic()<until:
        item=messages.get(timeout=max(.01, until-time.monotonic()))
        if predicate(item):return item
    raise AssertionError('Core message missing')

def read_exact(sock,n):
    b=b''
    while len(b)<n:
        d=sock.recv(n-len(b))
        if not d:raise EOFError()
        b+=d
    return b

def ws_send(sock, obj):
    data=json.dumps(obj).encode();n=len(data)
    sock.sendall(b'\x81'+(bytes([n]) if n<126 else b'\x7e'+struct.pack('!H',n))+data)

def ws_read(sock):
    while True:
        a,b=read_exact(sock,2);n=b&127
        if n==126:n=struct.unpack('!H',read_exact(sock,2))[0]
        elif n==127:n=struct.unpack('!Q',read_exact(sock,8))[0]
        assert n<=131072
        mask=read_exact(sock,4) if b&128 else b''
        data=read_exact(sock,n)
        if mask:data=bytes(v^mask[i%4] for i,v in enumerate(data))
        if a&15==1:return json.loads(data)
        if a&15==8:raise EOFError()
        if a&15==9:sock.sendall(b'\x8a'+bytes([len(data)])+data)

def wait_ws(sock,predicate, seconds=10):
    until=time.monotonic()+seconds
    while time.monotonic()<until:
        sock.settimeout(max(.01,until-time.monotonic()))
        item=ws_read(sock)
        if os.environ.get("BRIDGE_TRACE"): print("WS", item, flush=True)
        if predicate(item):return item
    raise AssertionError('Elgato message missing')

try:
    core=begin_core()
    ready=wait_core(lambda x:x['type']=='ready');assert ready['sequence']==0
    registration=wait_core(lambda x:x.get('bus',{}).get('operation')=='register')['bus']['registration']
    client=subprocess.Popen([str(binary),'-port',str(listener.getsockname()[1]),'-pluginUUID','fixture','-registerEvent','registerPlugin','-info','{}','--bridge-fixture',fixture],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);workers.append(client)
    ws,_=listener.accept();ws.settimeout(10)
    headers=b''
    while b'\r\n\r\n' not in headers:headers+=ws.recv(4096)
    key=next(line.split(b':',1)[1].strip() for line in headers.split(b'\r\n') if line.lower().startswith(b'sec-websocket-key:'))
    accept=base64.b64encode(hashlib.sha1(key+b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
    ws.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+b'\r\n\r\n')
    assert ws_read(ws)=={'event':'registerPlugin','uuid':'fixture'}
    wait_core(lambda x:x.get('bus',{}).get('operation')=='discover')
    gen=str(uuid.uuid4());address={'plugin':module_id,'name':'check_connection'}
    def bus(value):send_core(core,{'type':'bus','bus':dict(requestID=str(uuid.uuid4()),**value)})
    entries=[{'address':address,'action':registration['actions'][0]}, {'address':{'plugin':module_id,'name':'connection'},'channel':registration['channels'][0]}]
    entries += [{'address':{'plugin':'fixture.provider'+str(i),'name':'check_connection'},'action':registration['actions'][0]} for i in range(200)]
    for payload in [{'catalog':[]}] + [{'catalog':[entry]} for entry in entries] + [{'complete':True}]:
        send_core(core,{'type':'bus','bus':{'operation':'catalog','requestID':gen,**payload}})
    action='cafe.nero.neronook.run';context='test-key'
    ws_send(ws,{'event':'willAppear','action':action,'context':context,'payload':{'settings':{}}})
    wait_ws(ws,lambda x:x.get('event')=='setTitle' and 'Check Stream Deck' in x.get('payload',{}).get('title',''))
    wait_ws(ws,lambda x:x.get('event')=='sendToPropertyInspector' and x.get('payload',{}).get('complete') is True)
    # The inspector's Test mapping follows the same path as an actual key press.
    ws_send(ws,{'event':'sendToPlugin','action':action,'context':context,'payload':{'test':True}})
    invocation=wait_core(lambda x:x.get('bus',{}).get('operation')=='invoke')['bus']
    assert invocation['address']==address and invocation['values']=={}
    run=invocation['requestID']
    send_core(core,{'type':'bus','bus':{'operation':'update','requestID':run,'update':{'phase':'running','message':'','values':{}}}})
    send_core(core,{'type':'bus','bus':{'operation':'execute','requestID':run,'address':address,'values':{}}})
    result=wait_core(lambda x:x.get('bus',{}).get('operation')=='update' and x['bus']['requestID']==run)['bus']
    assert result['update']['phase']=='succeeded' and result['update']['values']['connected'] is True
    send_core(core,{'type':'bus','bus':result})
    wait_ws(ws,lambda x:x.get('event')=='showOk' and x.get('context')==context)
    state_address={'plugin':module_id,'name':'connection'}
    ws_send(ws,{'event':'willAppear','action':'cafe.nero.neronook.status','context':'status-key','payload':{'settings':{}}})
    subscription=wait_core(lambda x:x.get('bus',{}).get('operation')=='subscribe')['bus']
    assert subscription['address']==state_address
    bus({'operation':'event','address':state_address,'values':{'connected':True,'message':'Connected'},'lifetime':1})
    wait_ws(ws,lambda x:x.get('context')=='status-key' and x.get('payload',{}).get('title')=='Connected')
    wait_ws(ws,lambda x:x.get('context')=='status-key' and 'stale' in x.get('payload',{}).get('title',''))
    # Second same-user client cannot replace the active Elgato connection.
    extra=socket.socket(socket.AF_UNIX);extra.settimeout(3);extra.connect('/tmp/nn-deck-test-'+str(os.getuid())+'-'+fixture+'/bridge.sock');assert extra.recv(1)==b'';extra.close()
    core.terminate();core.wait(timeout=5)
    wait_ws(ws,lambda x:x.get('event')=='setTitle' and 'Offline' in x.get('payload',{}).get('title',''))
    # A stale socket left by SIGTERM is recovered by the owner lock on restart.
    while not messages.empty():messages.get_nowait()
    session=str(uuid.uuid4());core=begin_core()
    wait_core(lambda x:x.get('bus',{}).get('operation')=='discover')
    deadline=time.monotonic()+3
    while time.monotonic()<deadline:
        try: item=messages.get(timeout=.2)
        except queue.Empty:continue
        assert item.get('bus',{}).get('operation')!='invoke','Action replayed on reconnect'
    print('PASS: native Elgato WebSocket registration, large framed SDK/inspector catalog, inspector invocation, result feedback, subscribed status/expiry, single-client ownership, offline state, stale-socket recovery and no reconnect replay')
finally:
    for p in workers:
        if p.poll() is None:p.terminate()
    for p in workers:
        try:p.wait(timeout=5)
        except subprocess.TimeoutExpired:p.kill();p.wait()
    listener.close()
    folder=Path('/tmp/nn-deck-test-'+str(os.getuid())+'-'+fixture)
    for name in ['bridge.sock','owner.lock']:
        (folder/name).unlink(missing_ok=True)
    if folder.exists():folder.rmdir()
