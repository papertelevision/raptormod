// Room Review viewer (2026-10-08). Each room's offline export drawn unlit (as painted), every point clickable for a
// note. Coordinates stored in notes are ALWAYS the room's own (the .XAF space, Y up -- the space the rooms\<ROOM>.json
// lights use); the Z mirror is display only (the engine is left-handed, so mirrored is the right way round).
import * as THREE from 'three';
import { OBJLoader } from 'three/addons/loaders/OBJLoader.js';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';

window.__rrReady = true;
document.getElementById('boot').classList.add('hidden');

const $ = id => document.getElementById(id);
const HDR = { 'X-Review': '1' };
const url = new URL(location.href);
const store = { get(k, d) { try { const v = localStorage.getItem('rr.' + k); return v === null ? d : JSON.parse(v); } catch { return d; } },
                set(k, v) { try { localStorage.setItem('rr.' + k, JSON.stringify(v)); } catch { } } };

// ---- three -------------------------------------------------------------------------------------------------------
const canvas = $('c');
const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, preserveDrawingBuffer: true });
renderer.setPixelRatio(Math.min(2, window.devicePixelRatio || 1));
renderer.outputColorSpace = THREE.SRGBColorSpace;
const scene = new THREE.Scene(); scene.background = new THREE.Color(0x0b0b0d);
const camera = new THREE.PerspectiveCamera(50, 1, 1, 20000);       // 50 degrees vertical, as the renderer
const root = new THREE.Group(); scene.add(root);                    // the room, in its own coordinates (mirrored for display)
const room = new THREE.Group(); root.add(room);                     // its meshes
const marks = new THREE.Group(); root.add(marks);                   // notes' pins, lights, doors
const orbit = new OrbitControls(camera, canvas); orbit.enableDamping = true; orbit.dampingFactor = 0.12;
const loader = new OBJLoader(), texLoader = new THREE.TextureLoader();
const maxAniso = renderer.capabilities.getMaxAnisotropy();

let S = { rooms: [], name: null, man: null, atm: null, doc: null, rev: -1, mode: 'orbit', size: 600, triggerMat: null, mats: [] };
let mirror = url.searchParams.has('mirror') ? url.searchParams.get('mirror') === '1' : store.get('mirror', null);
// (for checking from the browser's console)
window.__rr = { S, THREE, camera, root, room, scene, get pose() { return camPose(); }, setPose: (...a) => { setPose(...a); requestRender(); } };

function resize() {
  const w = canvas.clientWidth, h = canvas.clientHeight;
  if (canvas.width !== Math.round(w * renderer.getPixelRatio()) || canvas.height !== Math.round(h * renderer.getPixelRatio())) {
    renderer.setSize(w, h, false); camera.aspect = w / Math.max(1, h); camera.updateProjectionMatrix();
  }
}

// ---- room <-> world (display) coordinates ------------------------------------------------------------------------------
const toRoom = v => root.worldToLocal(v.clone());
const toWorld = v => root.localToWorld(v.clone());
function camPose() {
  const p = toRoom(camera.position), f = new THREE.Vector3(); camera.getWorldDirection(f);
  const fl = toRoom(camera.position.clone().add(f)).sub(p).normalize();
  const ul = toRoom(camera.position.clone().add(camera.up)).sub(p).normalize();
  const yaw = Math.atan2(fl.x, fl.z) * 180 / Math.PI, pitch = Math.atan2(fl.y, Math.hypot(fl.x, fl.z)) * 180 / Math.PI;
  const r = n => Math.round(n * 100) / 100;
  return { pos: [r(p.x), r(p.y), r(p.z)], fwd: [r(fl.x), r(fl.y), r(fl.z)], up: [r(ul.x), r(ul.y), r(ul.z)], fov: 50, mirror,
           gpuLook: { X: r(p.x), Y: r(p.y), Z: r(p.z), Yaw: r(yaw), Pitch: r(pitch) } };
}
// put the camera at a room-space pose (x, y, z, yaw, pitch in degrees: forward = (sin yaw, tan pitch, cos yaw))
function setPose(x, y, z, yaw, pitch) {
  const a = yaw * Math.PI / 180, t = Math.tan(pitch * Math.PI / 180);
  const pos = toWorld(new THREE.Vector3(x, y, z)), tgt = toWorld(new THREE.Vector3(x + Math.sin(a) * 100, y + t * 100, z + Math.cos(a) * 100));
  camera.position.copy(pos); orbit.target.copy(tgt); camera.lookAt(tgt); orbit.update();
  if (S.mode === 'walk') { syncLook(); eyeY = null; }
}

// ---- api -----------------------------------------------------------------------------------------------------------
async function api(path, opt = {}) {
  const r = await fetch(path, opt); const t = await r.text(); let j = null; try { j = JSON.parse(t); } catch { }
  if (!r.ok) throw new Error((j && j.error) || (r.status + ' ' + t.slice(0, 120)));
  return j;
}
function status(msg) { $('status').textContent = msg || ''; }

// ---- materials -----------------------------------------------------------------------------------------------------
function disposeRoom() {
  room.traverse(o => { if (o.geometry) o.geometry.dispose(); });
  for (const m of S.mats) { if (m.map) m.map.dispose(); if (m.alphaMap) m.alphaMap.dispose(); m.dispose(); }
  S.mats = []; room.clear(); marks.clear();
}
function makeMaterials(man) {
  const lo = $('lo').checked, byName = new Map();
  const tex = (leaf, orig) => {
    const t = texLoader.load(`/rooms/${man.room}/${orig ? 'tex-orig' : 'tex'}/${encodeURIComponent(leaf)}${!orig && lo ? '?lo=1' : ''}`, () => requestRender());
    t.colorSpace = orig ? THREE.NoColorSpace : THREE.SRGBColorSpace; t.wrapS = t.wrapT = THREE.RepeatWrapping; t.anisotropy = Math.min(8, maxAniso);
    return t;
  };
  S.triggerMat = new THREE.MeshBasicMaterial({ color: 0xff40ff, transparent: true, opacity: 0.22, side: THREE.DoubleSide, depthWrite: false, visible: $('trig').checked });
  S.triggerMat.userData.skip = true; S.mats.push(S.triggerMat);
  for (const m of man.materials) {
    let mat;
    if (m.skip) mat = S.triggerMat;
    else if (m.map) {
      mat = new THREE.MeshBasicMaterial({ map: tex(m.map, false), side: sideNow() });
      if (m.keyed) {
        // the holes come from the ORIGINAL texture's alpha (a hi-res copy may carry colour only)
        mat.alphaMap = tex(m.map, true); mat.alphaTest = 0.5;
        mat.onBeforeCompile = sh => { sh.fragmentShader = sh.fragmentShader.replace('#include <alphamap_fragment>', 'diffuseColor.a *= texture2D( alphaMap, vAlphaMapUv ).a;'); };
      }
      S.mats.push(mat);
    } else {
      mat = new THREE.MeshBasicMaterial({ side: sideNow() }); mat.color.setRGB(m.kd[0], m.kd[1], m.kd[2], THREE.SRGBColorSpace); S.mats.push(mat);
    }
    mat.userData.name = m.name; mat.userData.texture = m.map || null; mat.userData.hires = !!m.hires;
    byName.set(m.name.toUpperCase(), mat);
  }
  const grey = new THREE.MeshBasicMaterial({ color: 0x777777, side: sideNow() }); grey.userData.name = '(missing)'; S.mats.push(grey);
  return name => name ? (byName.get(name.toUpperCase()) || grey) : S.triggerMat;      // (no material at all: an authoring dummy)
}
// one-sided like the game (a wall seen from behind is not there -- the first room's start is behind one), unless "Back faces"
const sideNow = () => $('back').checked ? THREE.DoubleSide : THREE.FrontSide;
function applyWire() { const w = $('wire').checked, sd = sideNow(); for (const m of S.mats) if (m !== S.triggerMat) { m.wireframe = w; m.side = sd; m.needsUpdate = true; } requestRender(); }
function applyFog() {
  scene.fog = null;
  if ($('fogPrev').checked && S.atm) {
    const v = S.atm.volume, f = S.atm.fog;
    if (v) scene.fog = new THREE.FogExp2(new THREE.Color(v.color || '#000000'), Number(v.density || 0.004));
    else if (f) scene.fog = new THREE.Fog(new THREE.Color(f.color || '#120C08'), Number(f.near || 100), Number(f.far || 820));
  }
  requestRender();
}

// ---- loading a room -------------------------------------------------------------------------------------------------
async function loadRoom(name, pose) {
  status('loading ' + name + '…'); disposeRoom(); S.name = name; S.rev = -1; S.sel = null;
  history.replaceState(null, '', '?room=' + name);
  $('roomSel').value = name;
  const [man, atm] = await Promise.all([api(`/api/rooms/${name}`), api(`/api/rooms/${name}/atmosphere`)]);
  S.man = man; S.atm = atm;
  if (mirror === null) mirror = !!man.mirrorZ;
  $('mirror').checked = mirror; root.scale.z = mirror ? -1 : 1; root.updateMatrixWorld(true);
  const matFor = makeMaterials(man);
  const t0 = performance.now();
  const objText = await (await fetch(`/rooms/${name}/${name}.obj`)).text();
  const obj = loader.parse(objText);
  obj.traverse(o => {
    if (!o.isMesh) return;
    o.userData.part = o.name;
    o.material = Array.isArray(o.material) ? o.material.map(m => matFor(m.name)) : matFor(o.material.name);
  });
  room.add(obj); applyWire(); applyFog();
  // the room's size, for the camera and the fly speed
  const box = new THREE.Box3().setFromObject(room), c = box.getCenter(new THREE.Vector3()), sz = box.getSize(new THREE.Vector3());
  S.size = Math.max(sz.x, sz.y, sz.z); S.center = c;
  camera.near = Math.max(0.5, S.size / 4000); camera.far = S.size * 8; camera.updateProjectionMatrix();
  if (pose) setPose(...pose);
  else if (man.arrive && man.arrive.land) {
    // where the player arrives from the previous room, at eye height, facing the most OPEN way: 16 directions at eye
    // level, the one whose first wall is farthest (the doors' trigger zones do not say reliably which way is 'in')
    const L = man.arrive.land, eye = L[1] + (man.eyeHeight || 48);
    room.updateMatrixWorld(true);
    let best = 0, bestYaw = 0;
    for (let k = 0; k < 16; k++) {
      const yw = k * 22.5, a = yw * Math.PI / 180;
      const o = toWorld(new THREE.Vector3(L[0], eye, L[2])), dst = toWorld(new THREE.Vector3(L[0] + Math.sin(a), eye - 0.08, L[2] + Math.cos(a)));
      const rc = new THREE.Raycaster(o, dst.sub(o).normalize());
      const h = rc.intersectObject(room, true).find(x => { const m = Array.isArray(x.object.material) ? x.object.material[x.face.materialIndex] : x.object.material; return !m.userData.skip && m.visible !== false; });
      const d = h ? h.distance : S.size;
      if (d > best) { best = d; bestYaw = yw; }
    }
    setPose(L[0], eye, L[2], bestYaw, -8);
  } else {
    orbit.target.copy(c); camera.position.copy(c.clone().add(new THREE.Vector3(S.size * 0.55, S.size * 0.45, S.size * 0.55))); camera.lookAt(c); orbit.update();
  }
  await refreshNotes(true);
  drawLightsAndDoors(); renderAtm();
  status(`${man.refreshed ? "(re-exported: the game's " + man.refreshed + ' changed) ' : ''}${name}: ${obj.children.length} parts, ${man.materials.length} materials (${man.materials.filter(m => m.hires).length} hi-res) · ${Math.round(performance.now() - t0)} ms`);
  requestRender();
}

// ---- markers: lights, doors, notes ----------------------------------------------------------------------------------------
function labelSprite(text, color, px = 30) {
  const cv = document.createElement('canvas'), g = cv.getContext('2d'); g.font = `bold ${px}px system-ui`;
  const w = Math.ceil(g.measureText(text).width) + 20, h = px + 16; cv.width = w; cv.height = h;
  g.font = `bold ${px}px system-ui`; g.fillStyle = 'rgba(0,0,0,0.65)'; g.beginPath(); g.roundRect(0, 0, w, h, 8); g.fill();
  g.fillStyle = color; g.textBaseline = 'middle'; g.fillText(text, 10, h / 2 + 1);
  const t = new THREE.CanvasTexture(cv); t.colorSpace = THREE.SRGBColorSpace;
  const s = new THREE.Sprite(new THREE.SpriteMaterial({ map: t, depthTest: false, sizeAttenuation: false }));
  s.scale.set(0.045 * w / h, 0.045, 1); s.renderOrder = 10; return s;
}
function drawLightsAndDoors() {
  for (const o of [...marks.children]) if (o.userData.kind !== 'pin') marks.remove(o);
  (S.atm.lights || []).forEach((l, i) => {
    if (l.x === undefined || l.x === null) return;
    const col = new THREE.Color(l.color || '#FFB266'), p = new THREE.Vector3(+l.x, +l.y, +l.z);
    const ball = new THREE.Mesh(new THREE.SphereGeometry(5, 16, 10), new THREE.MeshBasicMaterial({ color: col }));
    ball.position.copy(p); ball.userData = { kind: 'light', index: i, name: l.name || ('light ' + i) }; marks.add(ball);
    if (l.dir) { const d = new THREE.Vector3(+l.dir[0], +l.dir[1], +l.dir[2]).normalize(); marks.add(new THREE.ArrowHelper(d, p, 40, col.getHex(), 10, 6)); }
    const lab = labelSprite('✹ ' + (l.name || 'light ' + i), '#ffd38a', 22); lab.position.copy(p).add(new THREE.Vector3(0, 14, 0)); lab.userData = ball.userData; marks.add(lab);
  });
  for (const d of (S.man.doors || [])) {
    if (!d.door) continue;
    const lab = labelSprite('→ ' + d.to, '#9fd0ff', 24); lab.position.set(d.door[0], d.door[1] + 40, d.door[2]);
    lab.userData = { kind: 'door', to: d.to }; marks.add(lab);
  }
}
// a note's state: NEW = Josh has written, Claude's turn; REVIEW = Claude has answered, Josh's turn; COMPLETE = done
const STATUS_COL = { new: '#e0a040', review: '#6aa8ff', complete: '#4caf7a' };
const STATUS_LABEL = { new: 'New · with Claude', review: 'Needs review · your turn', complete: 'Complete' };
// the pins: one per note in the current list; the open note's pin larger and ringed
function drawPins() {
  for (const o of [...marks.children]) if (o.userData.kind === 'pin') marks.remove(o);
  for (const n of visibleNotes()) {
    if (!n.point) continue;
    const sel = n.id === S.sel, s = labelSprite((sel ? '◉ #' : '#') + n.id, sel ? '#ffffff' : (STATUS_COL[n.status] || '#e0a040'), sel ? 34 : 26);
    s.position.set(n.point[0], n.point[1], n.point[2]); s.userData = { kind: 'pin', id: n.id }; marks.add(s);
  }
}

// ---- notes panel: a LIST (one row a note: filter + sort) and the open note's DETAIL (its whole conversation) ----------
// A note opens from its row, or from its pin in the room. Completed notes can be browsed (filter: Completed).
const allNotes = () => S.doc ? (($('noteFilter').value === 'complete') ? (S.doc.completed || []) : S.doc.notes) : [];
function visibleNotes() {
  const f = $('noteFilter').value, sort = $('noteSort').value;
  const list = allNotes().filter(n => f === 'all' || f === 'complete' || n.status === f);
  const by = {
    activity: (a, b) => (b.updated || b.completedAt || '').localeCompare(a.updated || a.completedAt || ''),
    number: (a, b) => a.id - b.id,
    kind: (a, b) => (a.kind || '').localeCompare(b.kind || '') || a.id - b.id,
    turn: (a, b) => (a.status === b.status ? (b.updated || '').localeCompare(a.updated || '') : a.status === 'review' ? -1 : 1)
  };
  return list.slice().sort(by[sort] || by.turn);
}
async function refreshNotes(force) {
  if (!S.name) return;
  const doc = await api(`/api/rooms/${S.name}/notes`);
  if (!force && doc.rev === S.rev) return;
  S.doc = doc; S.rev = doc.rev;
  if (S.sel && !allNotes().some(n => n.id === S.sel)) S.sel = null;     // (completed or deleted elsewhere)
  renderNotes(); drawPins(); requestRender(); refreshSubmit();
}
function esc(s) { return String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])); }
function when(iso) { if (!iso) return ''; const d = new Date(iso); return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' }) + ' ' + d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' }); }
const shotUrl = leaf => `/shots/${S.name}/${encodeURIComponent(String(leaf).replace(S.name + '-', ''))}`;
const firstText = n => ((n.log && n.log[0] && n.log[0].text) || '').replace(/\s+/g, ' ');
function selectNote(id) { S.sel = id; renderNotes(); drawPins(); requestRender(); const side = $('side'); if (side) side.scrollTop = 0; }
function renderNotes() {
  const box = $('notes'), open = S.doc ? S.doc.notes : [];
  const nNew = open.filter(n => n.status === 'new').length, nRev = open.filter(n => n.status === 'review').length;
  $('noteCounts').textContent = `${nRev} to review · ${nNew} with Claude` + (S.doc && S.doc.completed && S.doc.completed.length ? ` · ${S.doc.completed.length} complete` : '');
  const n = S.sel ? allNotes().find(x => x.id === S.sel) : null;
  if (n) { box.innerHTML = noteDetail(n); return; }
  const list = visibleNotes();
  if (!list.length) { box.innerHTML = `<div class="small">${open.length || (S.doc && S.doc.completed && S.doc.completed.length) ? 'Nothing in this view.' : 'No notes yet. Click anywhere on the room to leave one.'}</div>`; return; }
  box.innerHTML = list.map(n => `
    <div class="nrow ${esc(n.status)}" data-id="${n.id}" title="Open note #${n.id}">
      <span class="dot"></span><b>#${n.id}</b><span class="chip">${esc(n.kind)}</span>
      <span class="ntext">${esc(firstText(n))}</span>
      <span class="nstate">${n.status === 'review' ? 'your turn' : n.status === 'new' ? 'with Claude' : 'done'}</span>
    </div>`).join('');
}
function noteDetail(n) {
  const done = n.status === 'complete';
  return `
    <div class="ndetail ${esc(n.status)}" data-id="${n.id}">
      <div class="nback"><button data-a="back">← All notes</button></div>
      <div class="head"><b>#${n.id}</b><span class="chip">${esc(n.kind)}</span><span class="chip st">${esc(STATUS_LABEL[n.status] || n.status)}</span>
        <span class="where">${esc(n.part || (n.target ? n.target.name : 'whole room'))}</span></div>
      <div class="log">${(n.log || []).map(m => `
        <div class="msg ${m.who === 'claude' ? 'claude' : 'josh'}">
          <div class="who">${m.who === 'claude' ? 'Claude' + (m.round ? ` · round ${m.round}` : '') : 'You'} <span>${esc(when(m.at))}</span></div>
          <div class="text">${esc(m.text)}</div>
          ${m.changes && m.changes.length ? `<ul class="changes">${m.changes.map(c => `<li>${esc(c)}</li>`).join('')}</ul>` : ''}
          ${m.render ? `<img class="render" src="${shotUrl(m.render)}" alt="render" title="The renderer's view from this note's camera (click to enlarge)">` : ''}
          ${m.shot ? `<img src="${shotUrl(m.shot)}" alt="" title="Your view (click to enlarge)">` : ''}
        </div>`).join('')}</div>
      <div class="acts">
        ${n.camera ? '<button data-a="go" title="Go to this note\'s view">View</button>' : ''}
        ${done ? '' : n.status === 'review'
            ? '<button data-a="complete" class="ok" title="Happy with it: the note is done and leaves the list">Complete ✓</button><button data-a="follow" title="Not quite: tell Claude what to change next">Follow up</button>'
            : '<button data-a="edit" title="Change your last message (before Claude answers)">Edit</button><button data-a="follow" title="Add more to this note">Add</button>'}
        ${done ? '' : '<button data-a="del" class="quiet" title="Delete (kept in the file\'s deleted list)">Delete</button>'}
      </div>
    </div>`;
}
$('notes').addEventListener('click', async e => {
  const row = e.target.closest('.nrow'); if (row) { selectNote(+row.dataset.id); return; }
  const b = e.target.closest('button'), card = e.target.closest('.ndetail'); if (!card) return;
  const n = allNotes().find(x => x.id === +card.dataset.id); if (!n) return;
  if (e.target.tagName === 'IMG') { window.open(e.target.src, '_blank'); return; }
  if (!b) return;
  const a = b.dataset.a, J = { ...HDR, 'Content-Type': 'application/json' };
  try {
    if (a === 'back') { S.sel = null; renderNotes(); drawPins(); requestRender(); }
    if (a === 'go' && n.camera) { const g = n.camera.gpuLook; setMode('orbit'); setPose(g.X, g.Y, g.Z, g.Yaw, g.Pitch); requestRender(); }
    if (a === 'edit') openDialog({ edit: n });
    if (a === 'follow') openDialog({ follow: n });
    if (a === 'complete') { await api(`/api/rooms/${S.name}/notes/${n.id}`, { method: 'PATCH', headers: J, body: JSON.stringify({ status: 'complete' }) }); status(`note #${n.id} complete`); S.sel = null; refreshNotes(true); }
    if (a === 'del' && confirm(`Delete note #${n.id}? (It is kept in the file's "deleted" list.)`)) { await api(`/api/rooms/${S.name}/notes/${n.id}`, { method: 'DELETE', headers: HDR }); S.sel = null; refreshNotes(true); }
  } catch (err) { alert(err.message); }
});
for (const id of ['noteFilter', 'noteSort']) $(id).addEventListener('change', () => { S.sel = null; renderNotes(); drawPins(); requestRender(); });

// ---- the room's settings ---------------------------------------------------------------------------------------------------------
function renderAtm() {
  const a = S.atm, rows = [], fmt = o => esc(Object.entries(o).filter(([k]) => !k.startsWith('_')).map(([k, v]) => `${k} ${Array.isArray(v) ? v.join(',') : v}`).join(' · '));
  $('atmSrc').textContent = (a.source || []).join(' + ');
  (a.lights || []).forEach((l, i) => rows.push(['light ' + i, `${esc(l.name || '')}<br><span class="small">${fmt(l)}</span>`]));
  for (const k of ['volume', 'fog', 'mist', 'dust', 'drips', 'steam', 'embers', 'kickup']) rows.push([k, a[k] ? `<span class="small">${fmt(a[k])}</span>` : '<span class="small">none</span>']);
  $('atm').innerHTML = rows.map(([k, v]) => `<div class="atm-row"><span>${k}</span><span>${v}</span></div>`).join('');
}

// ---- picking and the note dialog -------------------------------------------------------------------------------------------
const ray = new THREE.Raycaster(), ndc = new THREE.Vector2();
function pick(ev) {
  const r = canvas.getBoundingClientRect(); ndc.set(((ev.clientX - r.left) / r.width) * 2 - 1, -((ev.clientY - r.top) / r.height) * 2 + 1);
  ray.setFromCamera(ndc, camera);
  const mk = ray.intersectObjects(marks.children, true).find(h => h.object.userData && h.object.userData.kind);
  const hits = ray.intersectObject(room, true);
  for (const h of hits) {
    const m = Array.isArray(h.object.material) ? h.object.material[h.face.materialIndex] : h.object.material;
    if (m.userData.skip) continue;                                  // invisible triggers would swallow every click
    if (mk && mk.distance < h.distance) return { marker: mk.object.userData };
    return { hit: h, mat: m };
  }
  return mk ? { marker: mk.object.userData } : null;
}
function hitInfo(p) {
  const h = p.hit, pt = h.object.worldToLocal(h.point.clone());       // the room's own coordinates (meshes sit at identity)
  const n = h.face.normal.clone(); const camL = toRoom(camera.position);
  if (n.dot(camL.clone().sub(pt)) < 0) n.negate();                    // the face's side facing the eye
  const r = v => Math.round(v * 100) / 100, r3 = v => Math.round(v * 1000) / 1000;
  const flat = new THREE.Vector3(n.x, 0, n.z); const sug = pt.clone().add(n.clone().multiplyScalar(30));
  return { point: [r(pt.x), r(pt.y), r(pt.z)], normal: [r3(n.x), r3(n.y), r3(n.z)], part: h.object.userData.part || h.object.name,
           material: p.mat.userData.name || null, texture: p.mat.userData.texture || null, uv: h.uv ? [r3(h.uv.x), r3(h.uv.y)] : null,
           suggest: { light: { x: r(sug.x), y: r(sug.y), z: r(sug.z), dir: flat.lengthSq() > 1e-6 ? flat.normalize().toArray().map(r3) : [0, -1, 0] } } };
}
let pending = null;
function openDialog(ctx) {
  pending = ctx;
  const ed = ctx.edit, fu = ctx.follow, last = ed ? ed.log[ed.log.length - 1] : null;
  $('dlgTitle').textContent = ed ? `Edit your note #${ed.id}` : fu ? `Follow up on #${fu.id}` : 'New note';
  $('dlgKindRow').style.display = fu ? 'none' : '';
  $('dlgKind').value = ed ? ed.kind : (ctx.target ? 'light' : 'other');
  $('dlgText').value = ed ? (last && last.who === 'josh' ? last.text : '') : '';
  $('dlgText').placeholder = fu ? 'What should change next? (or what is still not right)' : 'What should change here?';
  $('dlgShot').checked = !ed; $('dlgShot').disabled = !!ed;
  const nn = ed || fu;
  $('dlgWhere').textContent = nn ? (nn.part ? `${nn.part} at ${nn.point}` : nn.target ? nn.target.name : 'whole room')
              : ctx.target ? `${ctx.target.name} (light ${ctx.target.index})`
              : ctx.info ? `${ctx.info.part} · ${ctx.info.material || ''} · at ${ctx.info.point.join(', ')}` : 'The whole room';
  $('dlg').showModal(); $('dlgText').focus();
}
// saved on the form's SUBMIT (immediate), not the dialog's 'close' event (a browser may hold that back in a background tab)
$('dlgForm').addEventListener('submit', async e => {
  e.preventDefault();
  const ok = e.submitter ? e.submitter.value === 'ok' : true, ctx = pending; pending = null;
  $('dlg').close(ok ? 'ok' : 'cancel');
  if (!ctx || !ok) return;
  const text = $('dlgText').value.trim(), kind = $('dlgKind').value; if (!text) return;
  const J = { ...HDR, 'Content-Type': 'application/json' };
  try {
    if (ctx.edit) {
      await api(`/api/rooms/${S.name}/notes/${ctx.edit.id}`, { method: 'PATCH', headers: J, body: JSON.stringify({ text, kind }) });
    } else if (ctx.follow) {
      const r = await api(`/api/rooms/${S.name}/notes/${ctx.follow.id}/messages`, { method: 'POST', headers: J, body: JSON.stringify({ text }) });
      if ($('dlgShot').checked) await sendShot(ctx.follow.id, r.index);
    } else {
      const body = { kind, text, camera: camPose(), target: ctx.target || null, seen: { objMtime: S.man.objMtime, roomFileMtime: S.man.roomFileMtime } };
      if (ctx.info) Object.assign(body, ctx.info);
      const note = await api(`/api/rooms/${S.name}/notes`, { method: 'POST', headers: J, body: JSON.stringify(body) });
      if ($('dlgShot').checked) await sendShot(note.id, 0);
      S.sel = note.id;
    }
    await refreshNotes(true); status('note saved');
  } catch (e) { alert('Could not save the note: ' + e.message); }
});
async function sendShot(id, msg) {
  renderNow();
  const src = renderer.domElement, k = Math.min(1, 1280 / src.width), cv = document.createElement('canvas');
  cv.width = Math.round(src.width * k); cv.height = Math.round(src.height * k); cv.getContext('2d').drawImage(src, 0, 0, cv.width, cv.height);
  const blob = await new Promise(res => cv.toBlob(res, 'image/png'));
  if (blob) await api(`/api/rooms/${S.name}/notes/${id}/shot?msg=${msg}`, { method: 'PUT', headers: { ...HDR, 'Content-Type': 'image/png' }, body: blob });
}
// a click is a short left press that hardly moved (a drag turns the view)
let down = null;
canvas.addEventListener('pointerdown', e => { if (e.button === 0) down = { x: e.clientX, y: e.clientY, t: performance.now() }; });
canvas.addEventListener('pointerup', e => {
  if (e.button !== 0 || !down) return;
  const moved = Math.hypot(e.clientX - down.x, e.clientY - down.y), dt = performance.now() - down.t; down = null;
  if (moved > 4 || dt > 400) return;
  const p = pick(e); if (!p) return;
  if (p.marker) {
    if (p.marker.kind === 'door') { loadRoom(p.marker.to); return; }
    if (p.marker.kind === 'pin') { selectNote(p.marker.id); return; }
    if (p.marker.kind === 'light') { openDialog({ target: { type: 'light', index: p.marker.index, name: p.marker.name } }); return; }
  }
  if (p.hit) openDialog({ info: hitInfo(p) });
});
let hoverT = 0;
canvas.addEventListener('pointermove', e => {
  if (performance.now() - hoverT < 60 || !S.man) return; hoverT = performance.now();
  const p = pick(e);
  if (p && p.hit) { const i = hitInfo(p); $('hover').textContent = `${i.part}  ·  ${i.material || ''}${i.texture ? ' (' + i.texture + ')' : ''}  ·  ${i.point.join(', ')}`; }
  else if (p && p.marker) $('hover').textContent = p.marker.kind === 'door' ? `door to ${p.marker.to} (click to go)` : p.marker.kind === 'light' ? `${p.marker.name} (click to note on this light)` : `note #${p.marker.id}`;
  else $('hover').textContent = '';
});
$('roomNote').addEventListener('click', () => openDialog({}));

// ---- "Render view": the room's REAL look from here -- its lights, volumetric fog, mist and shadows, from its current
// settings -- through the true-colour renderer, offline (the server runs it: ~10 s). Flashlight off and on, side by side.
let renderPoll = null;
async function renderView() {
  if (!S.name || renderPoll) return;
  const box = $('renderBox'), g = camPose().gpuLook;
  box.hidden = false; $('renderImg').hidden = true; $('renderMsg').textContent = 'Rendering the real look from here…';
  try {
    const r = await api(`/api/rooms/${S.name}/render`, { method: 'POST', headers: { ...HDR, 'Content-Type': 'application/json' }, body: JSON.stringify(g) });
    const room = S.name, t0 = performance.now();
    renderPoll = setInterval(async () => {
      try {
        const st = await api(`/api/rooms/${room}/render/${r.id}`);
        if (st.state === 'running') { $('renderMsg').textContent = `Rendering the real look from here… ${Math.round((performance.now() - t0) / 1000)} s`; return; }
        clearInterval(renderPoll); renderPoll = null;
        if (st.state === 'done') {
          const img = $('renderImg'); img.src = st.image; img.hidden = false;
          $('renderMsg').textContent = `${room} · the renderer's view from here, with the room's current settings (${st.seconds} s) · click to enlarge`;
        } else $('renderMsg').textContent = 'The render did not come out. (Is the graphics card busy with the game?)';
      } catch (e) { clearInterval(renderPoll); renderPoll = null; $('renderMsg').textContent = 'Render failed: ' + e.message; }
    }, 1000);
  } catch (e) { $('renderMsg').textContent = e.message.includes('already') ? 'A render is already running: one at a time.' : 'Render failed: ' + e.message; }
}
$('renderBtn').addEventListener('click', renderView);
$('renderClose').addEventListener('click', () => { $('renderBox').hidden = true; });
$('renderImg').addEventListener('click', () => window.open($('renderImg').src, '_blank'));

// ---- "Submit update" (lower right): tells Claude the notes are ready -- no need to switch to the chat. Shows where it
// stands: notes waiting to be sent; sent and waiting for Claude; Claude working on round N; Claude replied (your turn).
let submitState = null;
async function refreshSubmit() {
  try {
    const s = await api('/api/submit'); submitState = s;
    const btn = $('submitBtn'), msg = $('submitMsg'), badge = $('submitCount');
    badge.textContent = s.pending ? String(s.pending) : ''; badge.hidden = !s.pending;
    const t = s.at ? new Date(s.at).toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' }) : '';
    if (s.state === 'waiting') { msg.textContent = `Sent ${t} · waiting for Claude`; btn.classList.add('sent'); }
    else if (s.state === 'working') { msg.textContent = `Claude is working on it (round ${s.round})`; btn.classList.add('sent'); }
    else if (s.state === 'done') { msg.textContent = s.pending ? `${s.pending} note(s) ready to send` : `Claude replied (round ${s.round}) · your turn`; btn.classList.remove('sent'); }
    else { msg.textContent = s.pending ? `${s.pending} note(s) ready to send` : 'Add notes, then submit'; btn.classList.remove('sent'); }
  } catch { }
}
$('submitBtn').addEventListener('click', async () => {
  try {
    const s = await api('/api/submit', { method: 'POST', headers: HDR });
    if (s.state === 'empty') { $('submitMsg').textContent = 'Nothing new to send yet'; return; }
    status(`sent to Claude: ${s.total} note(s)`); await refreshSubmit();
  } catch (e) { $('submitMsg').textContent = 'Could not send: ' + e.message; }
});
setInterval(() => { if (document.visibilityState === 'visible') refreshSubmit(); }, 5000);

// ---- moving round: FLY (the default: the orbit view, and WASD floats you through the room -- no collision) and WALK
// (as the player: eye height over the floor, walls stop you, drag to look). A short click always leaves a note.
// Speeds are the game's own: walk 145 units a second, Shift = its run (291); flying is half as fast again.
const keys = new Set(); let look = null, yaw = 0, pitch = 0, speedK = 1, eyeY = null;
const MODE_NAME = { orbit: 'Fly', walk: 'Walk' };
const HELP = {
  orbit: 'Fly: WASD / arrows move &middot; Q/E or Space/C down/up &middot; Shift faster &middot; drag turn, right-drag pan, wheel zoom &middot; F: walk &middot; click to leave a note',
  walk: 'Walk: WASD / arrows &middot; drag to look &middot; Shift run &middot; wheel speed &middot; F or Esc: fly &middot; click to leave a note'
};
function syncLook() { const f = new THREE.Vector3(); camera.getWorldDirection(f); yaw = Math.atan2(f.x, f.z); pitch = Math.asin(Math.max(-1, Math.min(1, f.y))); }
function setMode(m) {
  const was = S.mode; S.mode = m; $('modeBtn').textContent = MODE_NAME[m]; orbit.enabled = m === 'orbit'; eyeY = null;
  if (m === 'walk') syncLook();
  else if (was === 'walk') { const f = new THREE.Vector3(); camera.getWorldDirection(f); orbit.target.copy(camera.position).add(f.multiplyScalar(Math.max(20, S.size * 0.08))); orbit.update(); }
  $('help').innerHTML = HELP[m]; requestRender();
}
$('modeBtn').addEventListener('click', () => setMode(S.mode === 'orbit' ? 'walk' : 'orbit'));
canvas.addEventListener('contextmenu', e => e.preventDefault());
// walk: looking is a drag with either button (past a few pixels, so a click stays a click)
canvas.addEventListener('pointerdown', e => { if (S.mode === 'walk') { look = { x: e.clientX, y: e.clientY, sx: e.clientX, sy: e.clientY, on: false }; canvas.setPointerCapture(e.pointerId); } });
canvas.addEventListener('pointermove', e => {
  if (!look) return;
  if (!look.on && Math.hypot(e.clientX - look.sx, e.clientY - look.sy) > 4) look.on = true;
  if (look.on) { yaw -= (e.clientX - look.x) * 0.004; pitch -= (e.clientY - look.y) * 0.004; pitch = Math.max(-1.5, Math.min(1.5, pitch)); requestRender(); }
  look.x = e.clientX; look.y = e.clientY;
});
canvas.addEventListener('pointerup', () => { look = null; });
// (in fly the wheel zooms, as before; in walk it sets the pace)
canvas.addEventListener('wheel', e => { if (S.mode !== 'walk') return; e.preventDefault(); speedK = Math.max(0.2, Math.min(5, speedK * (e.deltaY > 0 ? 0.85 : 1.18))); status(`speed x${speedK.toFixed(2)}`); }, { passive: false });
window.addEventListener('keydown', e => {
  if ($('dlg').open || e.target.tagName === 'TEXTAREA' || e.target.tagName === 'INPUT' || e.target.tagName === 'SELECT') return;
  const k = e.key.toLowerCase();
  if (k === 'f') { setMode(S.mode === 'walk' ? 'orbit' : 'walk'); return; }
  if (k === 'escape') { setMode('orbit'); return; }
  if (k === 'r' && !e.ctrlKey && !e.metaKey) { renderView(); return; }
  if (k.startsWith('arrow') || k === ' ') e.preventDefault();
  keys.add(k === ' ' ? 'space' : k); if (e.key === 'Shift') keys.add('shift'); requestRender();
});
window.addEventListener('keyup', e => { const k = e.key.toLowerCase(); keys.delete(k === ' ' ? 'space' : k); if (e.key === 'Shift') keys.delete('shift'); });
window.addEventListener('blur', () => keys.clear());
// the first visible surface along a world ray (triggers and seen-from-behind faces do not count, as in the game)
const probe = new THREE.Raycaster();
function surfaceAlong(o, d, far) {
  probe.set(o, d); probe.far = far;
  const h = probe.intersectObject(room, true).find(x => { const m = Array.isArray(x.object.material) ? x.object.material[x.face.materialIndex] : x.object.material; return !m.userData.skip; });
  return h ? h.distance : Infinity;
}
const WALK = 145, RUN = 291, EYE = () => (S.man && S.man.eyeHeight) || 48, BODY = 14;
window.__rr.keys = keys; window.__rr.tick = now => frame(now);      // (checks drive the loop by hand: a hidden tab gets no frames)
// ---- the loop: draws only when something changed ------------------------------------------------------------------------------
let dirty = true, last = performance.now();
function requestRender() { dirty = true; }
function renderNow() { resize(); renderer.render(scene, camera); }
orbit.addEventListener('change', requestRender);
function frame(now) {
  const dt = Math.min(0.05, (now - last) / 1000); last = now;
  const turn = 1.8 * dt;
  if (S.mode === 'walk') {
    if (keys.has('arrowleft')) { yaw += turn; dirty = true; } if (keys.has('arrowright')) { yaw -= turn; dirty = true; }
    const f = new THREE.Vector3(Math.sin(yaw) * Math.cos(pitch), Math.sin(pitch), Math.cos(yaw) * Math.cos(pitch));
    const flat = new THREE.Vector3(Math.sin(yaw), 0, Math.cos(yaw)), rgt = new THREE.Vector3().crossVectors(flat, new THREE.Vector3(0, 1, 0)).normalize();
    const v = new THREE.Vector3();
    if (keys.has('w') || keys.has('arrowup')) v.add(flat); if (keys.has('s') || keys.has('arrowdown')) v.sub(flat);
    if (keys.has('d')) v.add(rgt); if (keys.has('a')) v.sub(rgt);
    const sp = (keys.has('shift') ? RUN : WALK) * speedK * dt;
    if (v.lengthSq() > 0) {
      v.normalize();
      // walls stop you: probes at chest and eye height along the move, a body's width ahead; else slide along the wall
      const chest = camera.position.clone().add(new THREE.Vector3(0, -EYE() * 0.45, 0));
      const free = Math.min(surfaceAlong(chest, v, sp + BODY + 1), surfaceAlong(camera.position, v, sp + BODY + 1));
      if (free > sp + BODY) camera.position.addScaledVector(v, sp);
      else {
        for (const ax of [new THREE.Vector3(v.x, 0, 0), new THREE.Vector3(0, 0, v.z)]) {
          if (ax.lengthSq() < 1e-6) continue; const n = ax.clone().normalize(), s2 = sp * ax.length();
          if (Math.min(surfaceAlong(chest, n, s2 + BODY + 1), surfaceAlong(camera.position, n, s2 + BODY + 1)) > s2 + BODY) { camera.position.addScaledVector(n, s2); break; }
        }
      }
      dirty = true;
    }
    // stand on the floor below: the eye at the player's height over it, eased (stairs, slopes); probed from just above
    // the knee so a step up is found; over a drop or the void, stay where you are
    const from = camera.position.clone().add(new THREE.Vector3(0, -EYE() * 0.55, 0));
    const down = surfaceAlong(from, new THREE.Vector3(0, -1, 0), 2000);
    if (down < 2000) {
      const want = from.y - down + EYE();
      if (eyeY === null) eyeY = want; else eyeY += (want - eyeY) * Math.min(1, dt * 12);
      if (Math.abs(camera.position.y - eyeY) > 0.01) { camera.position.y = eyeY; dirty = true; }
    }
    camera.lookAt(camera.position.clone().add(f));
  } else {
    // FLY: the orbit view, and WASD floats it -- the camera and the point it turns round move together, through
    // anything: W/S along the view, A/D sideways, Q/E or Space/C straight down/up, the left/right arrows turn on the spot
    const f = new THREE.Vector3(); camera.getWorldDirection(f);
    const rgt = new THREE.Vector3().crossVectors(f, camera.up).normalize();
    const v = new THREE.Vector3();
    if (keys.has('w') || keys.has('arrowup')) v.add(f); if (keys.has('s') || keys.has('arrowdown')) v.sub(f);
    if (keys.has('d')) v.add(rgt); if (keys.has('a')) v.sub(rgt);
    if (keys.has('e') || keys.has('space')) v.y += 1; if (keys.has('q') || keys.has('c')) v.y -= 1;
    if (v.lengthSq() > 0) {
      const d = v.normalize().multiplyScalar((keys.has('shift') ? RUN * 2 : WALK * 1.5) * dt);
      camera.position.add(d); orbit.target.add(d); dirty = true;
    }
    const tl = keys.has('arrowleft') ? 1 : keys.has('arrowright') ? -1 : 0;
    if (tl) { const off = orbit.target.clone().sub(camera.position).applyAxisAngle(new THREE.Vector3(0, 1, 0), tl * turn); orbit.target.copy(camera.position).add(off); dirty = true; }
    if (orbit.update()) dirty = true;
  }
  if (dirty) { dirty = false; renderNow(); }
  requestAnimationFrame(frame);
}new ResizeObserver(requestRender).observe(canvas);

// ---- top bar ------------------------------------------------------------------------------------------------------------------------
$('roomSel').addEventListener('change', () => loadRoom($('roomSel').value));
$('prev').addEventListener('click', () => { if (S.man && S.man.prev) loadRoom(S.man.prev); });
$('next').addEventListener('click', () => { if (S.man && S.man.next) loadRoom(S.man.next); });
$('wire').addEventListener('change', applyWire);
$('back').addEventListener('change', applyWire);
$('fogPrev').addEventListener('change', applyFog);
$('trig').addEventListener('change', () => { if (S.triggerMat) S.triggerMat.visible = $('trig').checked; requestRender(); });
$('lo').addEventListener('change', () => { const pose = camPose().gpuLook; loadRoom(S.name, [pose.X, pose.Y, pose.Z, pose.Yaw, pose.Pitch]); });
$('mirror').addEventListener('change', () => {
  const pose = camPose().gpuLook; mirror = $('mirror').checked; store.set('mirror', mirror);
  root.scale.z = mirror ? -1 : 1; root.updateMatrixWorld(true); setPose(pose.X, pose.Y, pose.Z, pose.Yaw, pose.Pitch); requestRender();
});
setInterval(() => { if (document.visibilityState === 'visible' && !$('dlg').open) refreshNotes(false).catch(() => { }); }, 5000);

// ---- start ----------------------------------------------------------------------------------------------------------------------------
(async () => {
  try {
    S.rooms = await api('/api/rooms');
    const sel = $('roomSel'), mk = (r, label) => { const o = document.createElement('option'); o.value = r.name; o.textContent = label; return o; };
    const g1 = document.createElement('optgroup'); g1.label = 'In play order';
    const g2 = document.createElement('optgroup'); g2.label = 'All rooms';
    const g3 = document.createElement('optgroup'); g3.label = 'Dev copies';
    for (const r of S.rooms) {
      const notes = (r.review ? `  · ${r.review} to review` : '') + (r.new ? `  · ${r.new} with Claude` : '');
      if (r.batch >= 0) g1.appendChild(mk(r, `${r.batch + 1}. ${r.name}${notes}`));
      else (r.hidden ? g3 : g2).appendChild(mk(r, r.name + notes));
    }
    sel.append(g1, g2, g3);
    const want = (url.searchParams.get('room') || '').toUpperCase(), start = S.rooms.find(r => r.name === want) ? want : (S.rooms.find(r => r.batch === 0) || S.rooms[0]).name;
    const cam = (url.searchParams.get('cam') || '').split(',').map(Number);
    if (url.searchParams.get('lo') === '1') $('lo').checked = true;
    setMode('orbit');
    await loadRoom(start, cam.length === 5 && cam.every(Number.isFinite) ? cam : null);
    requestAnimationFrame(frame);
  } catch (e) { status('error: ' + e.message); console.error(e); }
})();
