# ******************
#  Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
# ******************
"""File sharing in a DM thread: the Python twin of social/file_xfer.c (wire
forms, bounds, names, the bitmap, the store) and social/id_file_xfer.c (the
state machine).

A file goes 1:1 from a sender to one device of a peer, after the receiver
accepts. The receiver PULLS: it keeps a window of chunk requests outstanding
and writes each chunk at its offset in a ``.part`` file, with a bitmap sidecar
so a restart resumes. The whole file's BLAKE2b-256 rides the offer and is
checked once at the end. Four directed, encrypted verbs, none plaintext:

  peer_file_offer  {id, name, size, chunk, total, hash, ts}
  peer_file_ctl    {id, op, reason?}    op: accept|decline|cancel|done|fail
  peer_file_req    {id, first, count}   receiver -> sender
  peer_file_chunk  {id, i, data}        sender -> receiver, base64

No freshness seq: each verb is idempotent and keyed by (peer, id), so a
retried request or two offers crossing on the wire are not replays. Terminal
records stay RECORD_TTL as tombstones so a replayed offer changes nothing.

The app verbs (offer / accept / decline / cancel) are the C runtime's; here
they are plain functions the conformance adapter calls, as it does for the
other app-driven sends. No app events are emitted (the C runtime's job).
"""
import base64
import hashlib
import json
import os
import tempfile
import time
import uuid as uuid_mod

ID_HEX_LEN = 32
NAME_MAX = 255
PATH_MAX = 4095
REASON_MAX = 31
HASH_HEX_LEN = 64
CHUNK_DEFAULT = 16384
CHUNK_MIN = 1024
CHUNK_MAX = 32768
REQ_MAX = 64
WINDOW_DEFAULT = 8
WINDOW_MAX = 64
REQ_TIMEOUT = 3.0
MAX_BYTES_DEFAULT = 2 * 1024 * 1024 * 1024
RECORD_TTL = 7.0 * 24 * 3600
RECORDS_MAX = 256
MAP_EVERY = 64
STORE_FILENAME = 'file_xfer.cfg.json'
STORE_VERSION = 1

OFFERED, ACCEPTED, DONE, DECLINED, CANCELLED, FAILED, TOO_LARGE = range(7)
TERMINAL = frozenset((DONE, DECLINED, CANCELLED, FAILED, TOO_LARGE))
OPS = ('accept', 'decline', 'cancel', 'done', 'fail')
OP_ACCEPT, OP_DECLINE, OP_CANCEL, OP_DONE, OP_FAIL = range(5)

_WIN_FORBIDDEN = b'<>:"|?*'
_WIN_DEVICES = {'con', 'prn', 'aux', 'nul'} | {f'com{i}' for i in range(1, 10)} \
    | {f'lpt{i}' for i in range(1, 10)}


# -- bounds and names ------------------------------------------------------ #

def _hex_ok(s, n):
    return isinstance(s, str) and len(s) == n \
        and all(c in '0123456789abcdef' for c in s)


def id_ok(s):
    return _hex_ok(s, ID_HEX_LEN)


def sanitize_name(name):
    """A safe bare file name, byte for byte what C at_file_sanitize_name
    makes: the part after the last '/' or '\\', control bytes dropped, the
    Windows-forbidden characters made '_', at most NAME_MAX bytes without a
    split UTF-8 sequence, trailing dots and spaces trimmed, and "file" for an
    empty, '.', '..' or Windows device name."""
    raw = name.encode('utf-8', 'surrogatepass') if isinstance(name, str) else b''
    for sep in (b'/', b'\\'):
        raw = raw.rsplit(sep, 1)[-1]
    out = bytearray()
    for c in raw:
        if c < 0x20 or c == 0x7f:
            continue
        if c in _WIN_FORBIDDEN:
            c = ord('_')
        if len(out) >= NAME_MAX:
            break
        out.append(c)
    if out and out[-1] & 0x80:
        lead = len(out) - 1
        while lead > 0 and (out[lead] & 0xC0) == 0x80:
            lead -= 1
        lb = out[lead]
        need = 2 if (lb & 0xE0) == 0xC0 else 3 if (lb & 0xF0) == 0xE0 \
            else 4 if (lb & 0xF8) == 0xF0 else 1
        if len(out) - lead < need:
            del out[lead:]
    while out and out[-1] in (ord('.'), ord(' ')):
        out.pop()
    text = out.decode('utf-8', 'surrogateescape')
    stem = text.split('.', 1)[0].lower()
    if not text or text in ('.', '..') or stem in _WIN_DEVICES:
        return 'file'
    return text


def unique_path(directory, name):
    """name, then 'name (1).ext' ... up to 999; None if none is free."""
    dot = name.rfind('.')
    stem, ext = (name[:dot], name[dot:]) if dot > 0 else (name, '')
    for i in range(1000):
        p = os.path.join(directory, name if i == 0 else f'{stem} ({i}){ext}')
        if not os.path.exists(p):
            return p
    return None


def total_chunks(size, chunk):
    return 0 if size <= 0 or chunk <= 0 else (size + chunk - 1) // chunk


def chunk_len(size, chunk, index):
    off = index * chunk
    return 0 if off >= size else min(chunk, size - off)


def hash_file(path, size):
    h = hashlib.blake2b(digest_size=32)
    left = size
    try:
        with open(path, 'rb') as f:
            while left > 0:
                b = f.read(min(left, 1 << 16))
                if not b:
                    return None
                h.update(b)
                left -= len(b)
    except OSError:
        return None
    return h.hexdigest()


# -- wire forms ------------------------------------------------------------ #

def _int(v):
    return v if isinstance(v, int) and not isinstance(v, bool) else None


def offer_from_json(d):
    """The offer, bound-checked and its name sanitized, or None."""
    if not isinstance(d, dict) or not id_ok(d.get('id')):
        return None
    size, chunk, total = _int(d.get('size')), _int(d.get('chunk')), _int(d.get('total'))
    ts = d.get('ts')
    if size is None or chunk is None or total is None \
            or not isinstance(d.get('name'), str) \
            or not isinstance(ts, (int, float)) or isinstance(ts, bool) \
            or not _hex_ok(d.get('hash'), HASH_HEX_LEN):
        return None
    if size < 0 or not CHUNK_MIN <= chunk <= CHUNK_MAX \
            or total != total_chunks(size, chunk) or size > chunk * 0xFFFFFFFF:
        return None
    return {'id': d['id'], 'name': sanitize_name(d['name']), 'size': size,
            'chunk': chunk, 'total': total, 'hash': d['hash'], 'ts': float(ts)}


def ctl_from_json(d):
    """(id, op, reason) or None. A reason is a token: [a-z0-9_] only."""
    if not isinstance(d, dict) or not id_ok(d.get('id')) or d.get('op') not in OPS:
        return None
    r = d.get('reason')
    reason = ''.join(c for c in r if c in 'abcdefghijklmnopqrstuvwxyz0123456789_') \
        if isinstance(r, str) else ''
    return d['id'], OPS.index(d['op']), reason[:REASON_MAX]


def req_from_json(d):
    if not isinstance(d, dict) or not id_ok(d.get('id')):
        return None
    first, count = _int(d.get('first')), _int(d.get('count'))
    if first is None or count is None or not 0 <= first <= 0xFFFFFFFF \
            or not 1 <= count <= REQ_MAX:
        return None
    return d['id'], first, count


def chunk_from_json(d, buf_max=CHUNK_MAX):
    if not isinstance(d, dict) or not id_ok(d.get('id')):
        return None
    i, data = _int(d.get('i')), d.get('data')
    if i is None or not 0 <= i <= 0xFFFFFFFF or not isinstance(data, str) \
            or len(data) % 4:
        return None
    try:
        raw = base64.b64decode(data, validate=True)
    except ValueError:
        return None
    if len(raw) > buf_max:
        return None
    return d['id'], i, raw


def ctl(xid, op, reason=''):
    body = {'id': xid, 'op': OPS[op]}
    if reason:
        body['reason'] = reason[:REASON_MAX]
    return body


# -- the bitmap ------------------------------------------------------------ #

def bitmap_new(n):
    return bytearray(n // 8 + 1)


def bit_get(bm, i):
    return (bm[i // 8] >> (i % 8)) & 1 == 1


def bit_set(bm, i):
    bm[i // 8] |= 1 << (i % 8)


def bit_count(bm, n):
    return sum(1 for i in range(n) if bit_get(bm, i))


def bitmap_load(path, n):
    try:
        with open(path, 'rb') as f:
            raw = f.read()
    except OSError:
        return bitmap_new(n)
    if len(raw) != n // 8 + 1:
        return bitmap_new(n)
    bm = bytearray(raw)
    for i in range(n, len(bm) * 8):
        bm[i // 8] &= ~(1 << (i % 8)) & 0xff
    return bm


def bitmap_save(path, bm):
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=d, prefix='.map-')
    with os.fdopen(fd, 'wb') as f:
        f.write(bytes(bm))
    os.replace(tmp, path)


# -- records and the store ------------------------------------------------- #

_PERSISTED = ('id', 'peer', 'dir', 'state', 'name', 'path', 'reason', 'size',
              'mtime', 'chunk', 'total', 'hash', 'created', 'updated')


def _root():
    return os.environ.get('AUTONOMOUS_TRUST_ROOT', os.path.abspath(os.sep))


def cfg_dir():
    return os.path.join(_root(), 'etc', 'at')


def files_dir():
    return os.path.join(_root(), 'var', 'agora', 'files')


def part_path(rec):
    return os.path.join(files_dir(), '.partial', f"{rec['peer']}-{rec['id']}.part")


def map_path(rec):
    return part_path(rec) + '.map'


def record_from_json(d):
    if not isinstance(d, dict) or not id_ok(d.get('id')) \
            or d.get('dir') not in ('in', 'out'):
        return None
    try:
        uuid_mod.UUID(str(d.get('peer')))
    except ValueError:
        return None
    state, size, chunk, total = (_int(d.get(k)) for k in ('state', 'size', 'chunk', 'total'))
    if state is None or not OFFERED <= state <= TOO_LARGE or size is None or size < 0 \
            or chunk is None or not CHUNK_MIN <= chunk <= CHUNK_MAX \
            or total != total_chunks(size, chunk) or not _hex_ok(d.get('hash'), HASH_HEX_LEN):
        return None
    rec = {k: d.get(k) for k in _PERSISTED}
    rec['name'] = sanitize_name(str(rec['name'] or ''))
    for k in ('path', 'reason'):
        rec[k] = str(rec[k] or '')
    rec['mtime'] = _int(rec['mtime']) or 0
    for k in ('created', 'updated'):
        rec[k] = float(rec[k] or 0.0)
    return rec


def store_save(records, directory=None):
    directory = directory or cfg_dir()
    doc = {'version': STORE_VERSION,
           'xfers': [{k: r[k] for k in _PERSISTED} for r in records]}
    fd, tmp = tempfile.mkstemp(dir=directory, prefix='.file_xfer-')
    with os.fdopen(fd, 'w') as f:
        json.dump(doc, f, indent=2, sort_keys=True)
    os.replace(tmp, os.path.join(directory, STORE_FILENAME))


def store_load(directory=None):
    """Records, [] for no file, None for a malformed document."""
    path = os.path.join(directory or cfg_dir(), STORE_FILENAME)
    if not os.path.exists(path):
        return []
    try:
        with open(path) as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return None
    xs = doc.get('xfers') if isinstance(doc, dict) else None
    if not isinstance(xs, list):
        return None
    return [r for r in (record_from_json(x) for x in xs[:RECORDS_MAX]) if r is not None]


def _env_int(name, dflt, lo, hi):
    try:
        v = int(os.environ.get(name, ''))
    except ValueError:
        return dflt
    return v if lo <= v <= hi else dflt


def _window():
    return _env_int('AT_FILE_WINDOW', WINDOW_DEFAULT, 1, WINDOW_MAX)


def _max_bytes():
    return _env_int('AT_FILE_MAX_BYTES', MAX_BYTES_DEFAULT, 0, MAX_BYTES_DEFAULT * 64)


def _chunk_size():
    return _env_int('AT_FILE_CHUNK', CHUNK_DEFAULT, CHUNK_MIN, CHUNK_MAX)


# -- the state machine ------------------------------------------------------ #
# proc.social.file_xfers: {(peer_str, id, outgoing): rec}. A rec is the
# persisted dict plus runtime keys: bm (bytearray), out {idx: t}, cursor,
# unsaved, last_rx. Handlers hold proc.lock while they change it and send
# after releasing it, as the C side collects into a batch.

def _xfers(proc):
    xs = getattr(proc.social, 'file_xfers', None)
    if xs is None:
        xs = proc.social.file_xfers = {}
    return xs


def _key(peer, xid, outgoing):
    return (str(peer), xid, bool(outgoing))


def _persist(proc):
    try:
        store_save(list(_xfers(proc).values()))
    except OSError as err:
        proc.logger.warning('could not save %s: %s', STORE_FILENAME, err)


def _make_room(proc):
    xs = _xfers(proc)
    if len(xs) < RECORDS_MAX:
        return True
    dead = [k for k, r in xs.items() if r['state'] in TERMINAL]
    if not dead:
        return False
    del xs[min(dead, key=lambda k: xs[k]['updated'])]
    return True


def _new(peer, xid, outgoing):
    now = time.time()
    return {'id': xid, 'peer': str(peer), 'dir': 'out' if outgoing else 'in',
            'state': OFFERED, 'name': '', 'path': '', 'reason': '', 'size': 0,
            'mtime': 0, 'chunk': CHUNK_DEFAULT, 'total': 0, 'hash': '0' * 64,
            'created': now, 'updated': now, 'bm': None, 'out': {}, 'cursor': 0,
            'unsaved': 0, 'last_rx': 0.0}


def _unlink_partial(rec):
    for p in (part_path(rec), map_path(rec)):
        try:
            os.unlink(p)
        except OSError:
            pass


def _end(rec, state, reason=''):
    rec['out'] = {}
    if rec['dir'] == 'in' and state != DONE:
        _unlink_partial(rec)
    rec['state'] = state
    rec['reason'] = (reason or '')[:REASON_MAX]
    rec['updated'] = time.time()


def bytes_done(rec):
    if rec['state'] == DONE:
        return rec['size']
    bm = rec.get('bm')
    if not bm:
        return 0
    n = bit_count(bm, rec['total'])
    done = n * rec['chunk']
    if rec['total'] and bit_get(bm, rec['total'] - 1):
        done -= rec['chunk'] - chunk_len(rec['size'], rec['chunk'], rec['total'] - 1)
    return done


def _top_up(rec, now, force=False):
    """Requests to send: re-ask what timed out, refill the window once it has
    drained to half (or always, if forced). Twin of C _rx_top_up."""
    want = [i for i, t in rec['out'].items() if now - t >= REQ_TIMEOUT]
    for i in want:
        rec['out'][i] = now
    w = _window()
    if force or want or len(rec['out']) <= w // 2:
        wrapped = False
        while len(rec['out']) < w:
            idx = next((i for i in range(rec['cursor'], rec['total'])
                        if not bit_get(rec['bm'], i)), rec['total'])
            if idx >= rec['total']:
                if wrapped or rec['cursor'] == 0:
                    break
                wrapped = True
                rec['cursor'] = 0
                continue
            rec['cursor'] = idx + 1
            if idx in rec['out']:
                continue
            rec['out'][idx] = now
            want.append(idx)
    want.sort()
    reqs, i = [], 0
    while i < len(want):
        j = i + 1
        while j < len(want) and want[j] == want[j - 1] + 1 and j - i < REQ_MAX:
            j += 1
        reqs.append({'id': rec['id'], 'first': want[i], 'count': j - i})
        i = j
    return reqs


def _finish(proc, rec):
    """All chunks held: verify, place, report. Returns frames to send."""
    rec['out'] = {}
    part = part_path(rec)
    if rec['total'] == 0:
        os.makedirs(os.path.dirname(part), exist_ok=True)
        open(part, 'wb').close()
    if hash_file(part, rec['size']) != rec['hash']:
        _end(rec, FAILED, 'hash_mismatch')
        return [(SocialProtocol_file.ctl, ctl(rec['id'], OP_FAIL, rec['reason']))]
    os.makedirs(files_dir(), exist_ok=True)
    final = unique_path(files_dir(), rec['name'])
    try:
        os.replace(part, final)
    except (OSError, TypeError):
        _end(rec, FAILED, 'cannot_place')
        return [(SocialProtocol_file.ctl, ctl(rec['id'], OP_FAIL, rec['reason']))]
    try:
        os.unlink(map_path(rec))
    except OSError:
        pass
    rec['path'] = final
    _end(rec, DONE)
    proc.logger.info('file transfer %s done: %s', rec['id'], final)
    return [(SocialProtocol_file.ctl, ctl(rec['id'], OP_DONE))]


def _begin(proc, rec):
    if rec.get('bm') is None:
        rec['bm'] = bitmap_load(map_path(rec), rec['total'])
    os.makedirs(os.path.dirname(part_path(rec)), exist_ok=True)
    if not os.path.exists(part_path(rec)):
        open(part_path(rec), 'wb').close()
    if bit_count(rec['bm'], rec['total']) >= rec['total']:
        return _finish(proc, rec)
    rec['cursor'] = 0
    rec['out'] = {}
    rec['last_rx'] = time.monotonic()
    return [(SocialProtocol_file.req, r) for r in _top_up(rec, rec['last_rx'], True)]


class SocialProtocol_file:
    """The four wire verbs (also on SocialProtocol)."""
    offer = 'peer_file_offer'
    ctl = 'peer_file_ctl'
    req = 'peer_file_req'
    chunk = 'peer_file_chunk'


def _send(proc, queues, peer_str, frames):
    if not frames:
        return
    from .handlers import _send_directed
    peer = proc.peers.find_by_uuid(peer_str) if proc.peers else None
    if peer is None:
        proc.logger.info('file transfer: %s is not an admitted peer; %d frame(s) '
                         'not sent', peer_str[:8], len(frames))
        return
    for verb, body in frames:
        _send_directed(proc, queues, peer, verb, body, 'a file transfer frame')


def _wire_sender(proc, message):
    from .handlers import _is_blocked
    sender = getattr(message, 'from_whom', None)
    if sender is None:
        return None
    s = str(sender.uuid)
    if _is_blocked(proc, s):
        proc.logger.debug('%s from %s dropped (locally blocked)', message.function, s[:8])
        return None
    return s


def _body(message):
    from autonomous_trust.core._python.config import from_json_string
    try:
        return from_json_string(message.obj)
    except Exception:
        return None


# -- app-side entry points (the C runtime's app verbs) ---------------------- #

def offer_file(proc, queues, peer_str, xid, path):
    """Twin of handle_app_file_offer."""
    from .handlers import _is_blocked
    if not id_ok(xid) or _is_blocked(proc, peer_str):
        return None
    rec = _new(peer_str, xid, True)
    rec['path'] = str(path)
    rec['name'] = sanitize_name(str(path))
    rec['chunk'] = _chunk_size()
    try:
        st = os.stat(path)
        ok = os.path.isfile(path)
    except OSError:
        ok = False
    if ok:
        rec['size'] = st.st_size
        rec['mtime'] = int(st.st_mtime)
        rec['total'] = total_chunks(rec['size'], rec['chunk'])
        h = hash_file(path, rec['size'])
        ok = h is not None
        rec['hash'] = h or rec['hash']
    with proc.lock:
        k = _key(peer_str, xid, True)
        if k in _xfers(proc):
            return _xfers(proc)[k]
        if not ok:
            rec['state'] = FAILED
            rec['reason'] = 'unreadable'
            return rec
        if not _make_room(proc):
            return None
        rec['bm'] = bitmap_new(rec['total'])
        _xfers(proc)[k] = rec
        _persist(proc)
        frame = {'id': xid, 'name': rec['name'], 'size': rec['size'],
                 'chunk': rec['chunk'], 'total': rec['total'], 'hash': rec['hash'],
                 'ts': rec['created']}
    _send(proc, queues, peer_str, [(SocialProtocol_file.offer, frame)])
    return rec


def accept_file(proc, queues, peer_str, xid):
    frames = []
    with proc.lock:
        rec = _xfers(proc).get(_key(peer_str, xid, False))
        if rec is None:
            return
        if rec['state'] == OFFERED:
            rec['state'] = ACCEPTED
            rec['updated'] = time.time()
            frames.append((SocialProtocol_file.ctl, ctl(xid, OP_ACCEPT)))
            frames += _begin(proc, rec)
            _persist(proc)
        elif rec['state'] == ACCEPTED:
            frames += [(SocialProtocol_file.req, r)
                       for r in _top_up(rec, time.monotonic(), True)]
    _send(proc, queues, peer_str, frames)


def decline_file(proc, queues, peer_str, xid):
    frames = []
    with proc.lock:
        rec = _xfers(proc).get(_key(peer_str, xid, False))
        if rec is not None and rec['state'] == OFFERED:
            _end(rec, DECLINED)
            frames.append((SocialProtocol_file.ctl, ctl(xid, OP_DECLINE)))
            _persist(proc)
    _send(proc, queues, peer_str, frames)


def cancel_file(proc, queues, peer_str, xid):
    frames = []
    with proc.lock:
        for outgoing in (True, False):
            rec = _xfers(proc).get(_key(peer_str, xid, outgoing))
            if rec is None or rec['state'] in TERMINAL:
                continue
            _end(rec, CANCELLED)
            frames.append((SocialProtocol_file.ctl, ctl(xid, OP_CANCEL)))
        if frames:
            _persist(proc)
    _send(proc, queues, peer_str, frames)


# -- wire handlers ------------------------------------------------------------ #

def handle_file_offer(proc, queues, message):
    if message.function != SocialProtocol_file.offer:
        return False
    sender = _wire_sender(proc, message)
    offer = offer_from_json(_body(message)) if sender else None
    if offer is None:
        return True
    if offer['ts'] < time.time() - RECORD_TTL:
        return True
    frames = []
    with proc.lock:
        k = _key(sender, offer['id'], False)
        if k in _xfers(proc):
            return True
        if not _make_room(proc):
            frames.append((SocialProtocol_file.ctl, ctl(offer['id'], OP_DECLINE, 'busy')))
        else:
            rec = _new(sender, offer['id'], False)
            for f in ('name', 'size', 'chunk', 'total', 'hash'):
                rec[f] = offer[f]
            if offer['size'] > _max_bytes():
                _end(rec, TOO_LARGE, 'too_large')
                frames.append((SocialProtocol_file.ctl,
                               ctl(offer['id'], OP_DECLINE, 'too_large')))
            _xfers(proc)[k] = rec
            _persist(proc)
    _send(proc, queues, sender, frames)
    return True


def handle_file_ctl(proc, queues, message):
    if message.function != SocialProtocol_file.ctl:
        return False
    sender = _wire_sender(proc, message)
    parsed = ctl_from_json(_body(message)) if sender else None
    if parsed is None:
        return True
    xid, op, reason = parsed
    frames, changed = [], False
    with proc.lock:
        xs = _xfers(proc)
        if op in (OP_ACCEPT, OP_DECLINE, OP_DONE):
            rec = xs.get(_key(sender, xid, True))
            if rec is None:
                pass
            elif op == OP_ACCEPT:
                if rec['state'] == OFFERED:
                    rec['state'] = ACCEPTED
                    rec['updated'] = time.time()
                    rec['last_rx'] = time.monotonic()
                    changed = True
                elif rec['state'] in (CANCELLED, FAILED):
                    frames.append((SocialProtocol_file.ctl,
                                   ctl(xid, OP_CANCEL if rec['state'] == CANCELLED
                                       else OP_FAIL, rec['reason'])))
            elif op == OP_DECLINE:
                if rec['state'] in (OFFERED, ACCEPTED):
                    _end(rec, DECLINED, reason)
                    changed = True
            elif rec['state'] not in TERMINAL:
                _end(rec, DONE)
                changed = True
        else:
            state = CANCELLED if op == OP_CANCEL else FAILED
            for outgoing in (False, True):
                rec = xs.get(_key(sender, xid, outgoing))
                if rec is None or rec['state'] in TERMINAL:
                    continue
                _end(rec, state, reason or ('' if state == CANCELLED else 'peer'))
                changed = True
        if changed:
            _persist(proc)
    _send(proc, queues, sender, frames)
    return True


def handle_file_req(proc, queues, message):
    if message.function != SocialProtocol_file.req:
        return False
    sender = _wire_sender(proc, message)
    parsed = req_from_json(_body(message)) if sender else None
    if parsed is None:
        return True
    xid, first, count = parsed
    frames, changed = [], False
    with proc.lock:
        rec = _xfers(proc).get(_key(sender, xid, True))
        if rec is None:
            frames.append((SocialProtocol_file.ctl, ctl(xid, OP_FAIL, 'unknown')))
        elif rec['state'] in TERMINAL:
            if rec['state'] != DONE:
                frames.append((SocialProtocol_file.ctl,
                               ctl(xid, OP_CANCEL if rec['state'] == CANCELLED
                                   else OP_FAIL, rec['reason'])))
        elif first + count <= rec['total']:
            if rec['state'] == OFFERED:
                rec['state'] = ACCEPTED
                rec['updated'] = time.time()
                changed = True
            try:
                st = os.stat(rec['path'])
                same = os.path.isfile(rec['path']) and st.st_size == rec['size'] \
                    and int(st.st_mtime) == rec['mtime']
            except OSError:
                same = False
            if not same:
                _end(rec, FAILED, 'source_changed')
                frames.append((SocialProtocol_file.ctl, ctl(xid, OP_FAIL, rec['reason'])))
                changed = True
            else:
                if rec.get('bm') is None:
                    rec['bm'] = bitmap_new(rec['total'])
                try:
                    with open(rec['path'], 'rb') as f:
                        for i in range(first, first + count):
                            n = chunk_len(rec['size'], rec['chunk'], i)
                            f.seek(i * rec['chunk'])
                            data = f.read(n)
                            if len(data) != n:
                                raise OSError('short read')
                            frames.append((SocialProtocol_file.chunk,
                                           {'id': xid, 'i': i,
                                            'data': base64.b64encode(data).decode()}))
                            bit_set(rec['bm'], i)
                except OSError:
                    frames = [(SocialProtocol_file.ctl, ctl(xid, OP_FAIL, 'unreadable'))]
                    _end(rec, FAILED, 'unreadable')
                    changed = True
                rec['last_rx'] = time.monotonic()
        if changed:
            _persist(proc)
    _send(proc, queues, sender, frames)
    return True


def handle_file_chunk(proc, queues, message):
    if message.function != SocialProtocol_file.chunk:
        return False
    sender = _wire_sender(proc, message)
    parsed = chunk_from_json(_body(message)) if sender else None
    if parsed is None:
        return True
    xid, idx, data = parsed
    frames = []
    with proc.lock:
        rec = _xfers(proc).get(_key(sender, xid, False))
        if rec is None or rec['state'] != ACCEPTED or idx >= rec['total'] \
                or len(data) != chunk_len(rec['size'], rec['chunk'], idx):
            return True
        now = time.monotonic()
        rec['out'].pop(idx, None)
        rec['last_rx'] = now
        if not bit_get(rec['bm'], idx):
            try:
                with open(part_path(rec), 'r+b') as f:
                    f.seek(idx * rec['chunk'])
                    f.write(data)
            except OSError:
                _end(rec, FAILED, 'cannot_write')
                _persist(proc)
                frames.append((SocialProtocol_file.ctl, ctl(xid, OP_FAIL, rec['reason'])))
                rec = None
            if rec is not None:
                bit_set(rec['bm'], idx)
                rec['unsaved'] += 1
                if rec['unsaved'] >= MAP_EVERY:
                    bitmap_save(map_path(rec), rec['bm'])
                    rec['unsaved'] = 0
        if rec is not None:
            if bit_count(rec['bm'], rec['total']) >= rec['total']:
                frames += _finish(proc, rec)
                _persist(proc)
            else:
                frames += [(SocialProtocol_file.req, r) for r in _top_up(rec, now)]
    _send(proc, queues, sender, frames)
    return True


# -- lifecycle --------------------------------------------------------------- #

def restore(proc):
    """Load the persisted transfers (C file_xfer_run_start)."""
    recs = store_load()
    if recs is None:
        proc.logger.warning('%s is malformed; no transfers restored', STORE_FILENAME)
        return
    with proc.lock:
        xs = _xfers(proc)
        for r in recs:
            r.update({'bm': None, 'out': {}, 'cursor': 0, 'unsaved': 0, 'last_rx': 0.0})
            if r['dir'] == 'in' and r['state'] == ACCEPTED:
                r['bm'] = bitmap_load(map_path(r), r['total'])
            elif r['state'] not in TERMINAL:
                r['bm'] = bitmap_new(r['total'])
            xs.setdefault(_key(r['peer'], r['id'], r['dir'] == 'out'), r)


def periodic(proc, queues):
    """Save progress, resume stalled pulls, expire offers, prune tombstones
    (C file_xfer_periodic)."""
    from .handlers import _is_blocked
    now, wall = time.monotonic(), time.time()
    with proc.lock:
        live = {r['peer'] for r in _xfers(proc).values() if r['state'] not in TERMINAL}
    blocked = {p for p in live if _is_blocked(proc, p)}
    sends, changed = [], False
    with proc.lock:
        xs = _xfers(proc)
        for k, r in list(xs.items()):
            if r['state'] in TERMINAL:
                if wall - r['updated'] > RECORD_TTL:
                    del xs[k]
                    changed = True
                continue
            if r['dir'] == 'in' and r['unsaved'] and r.get('bm') is not None:
                bitmap_save(map_path(r), r['bm'])
                r['unsaved'] = 0
            if r['peer'] in blocked:
                _end(r, CANCELLED, 'blocked')
                changed = True
            elif r['state'] == OFFERED and wall - r['created'] > RECORD_TTL:
                _end(r, CANCELLED, 'expired')
                sends.append((r['peer'], [(SocialProtocol_file.ctl,
                                           ctl(r['id'], OP_CANCEL, 'expired'))]))
                changed = True
            elif r['dir'] == 'in' and r['state'] == ACCEPTED \
                    and now - r['last_rx'] >= REQ_TIMEOUT and r.get('bm') is not None:
                r['out'], r['cursor'], r['last_rx'] = {}, 0, now
                sends.append((r['peer'], [(SocialProtocol_file.req, q)
                                          for q in _top_up(r, now, True)]))
        if changed:
            _persist(proc)
    for peer, frames in sends:
        _send(proc, queues, peer, frames)


def dump(proc):
    """Every record, persisted form plus 'done' (C file_xfer_dump)."""
    with proc.lock:
        return [dict({k: r[k] for k in _PERSISTED}, done=bytes_done(r))
                for r in _xfers(proc).values()]
