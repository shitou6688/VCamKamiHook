/**
 * 卡密管理系统 v2 — Cloudflare Workers + D1
 *
 * 移植自极简云核心功能:
 *   ✅ 卡密类型 (时长卡/计次卡/永久卡)
 *   ✅ 卡密解绑 (限次数 + 冷却时间)
 *   ✅ 黑名单 (设备/IP 封禁)
 *   ✅ IP 记录与限制
 *   ✅ 应用配置 (免费/付费模式)
 *   ✅ 兼容旧接口
 *
 * API 端点：
 *   兼容旧接口:
 *     GET /api.php?api=kmlogon&app=XXX&kami=XXX&markcode=XXX
 *     GET /trollstore-device-api.php?api=ts_register&serial=&markcode=XXX&kami=XXX&model=XXX&ios=XXX
 *
 *   新接口:
 *     POST /api/activate     激活卡密
 *     POST /api/unbind       解绑卡密
 *     GET  /api/verify       验证卡密/设备状态
 *     POST /api/register     设备注册
 *
 *   管理接口 (需要 Admin Token):
 *     GET    /api/admin/keys         查看卡密列表
 *     POST   /api/admin/generate     批量生成卡密
 *     POST   /api/admin/revoke       撤销卡密
 *     DELETE /api/admin/keys/:id     删除卡密
 *     GET    /api/admin/stats        统计信息
 *     GET    /api/admin/logs         操作日志
 *     POST   /api/admin/init         初始化
 *     GET    /api/admin/blacklist    查看黑名单
 *     POST   /api/admin/blacklist    添加黑名单
 *     DELETE /api/admin/blacklist/:id 删除黑名单
 *     GET    /api/admin/apps         查看应用配置
 *     POST   /api/admin/apps         更新应用配置
 *
 *   其他:
 *     GET  /admin                  管理后台页面
 */

// ============ 工具函数 ============

function generateKey(length = 16, mode = 'alphanum') {
  const charsets = {
    alphanum: 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789',
    digit:    '0123456789',
    upper:    'ABCDEFGHJKLMNPQRSTUVWXYZ',
  };
  const chars = charsets[mode] || charsets.alphanum;
  let result = '';
  const arr = new Uint8Array(length);
  crypto.getRandomValues(arr);
  for (let i = 0; i < length; i++) {
    result += chars[arr[i] % chars.length];
  }
  if (mode === 'digit') return result;
  return result.match(/.{1,4}/g).join('-');
}

function generateToken(length = 32) {
  const arr = new Uint8Array(length);
  crypto.getRandomValues(arr);
  return Array.from(arr, b => b.toString(16).padStart(2, '0')).join('');
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    },
  });
}

function getClientIP(request) {
  return request.headers.get('CF-Connecting-IP') ||
         request.headers.get('X-Forwarded-For')?.split(',')[0]?.trim() ||
         'unknown';
}

async function logAction(DB, action, keyCode, deviceSerial, ip, detail) {
  try {
    await DB.prepare(
      'INSERT INTO audit_log (action, key_code, device_serial, ip, detail) VALUES (?, ?, ?, ?, ?)'
    ).bind(action, keyCode || null, deviceSerial || null, ip, detail || null).run();
  } catch (e) {
    console.error('audit log error:', e.message);
  }
}

function isAdmin(request, env) {
  const auth = request.headers.get('Authorization');
  const adminToken = env.ADMIN_TOKEN;
  if (!adminToken) return false;
  if (auth === `Bearer ${adminToken}`) return true;
  const url = new URL(request.url);
  if (url.searchParams.get('token') === adminToken) return true;
  return false;
}

// 时长单位转秒数
function timeUnitToSeconds(unit) {
  const map = { hour: 3600, day: 86400, week: 604800, month: 2592000, season: 7776000, year: 31104000, longuse: 4102243200 };
  return map[unit] || 0;
}

function timeUnitLabel(unit) {
  const map = { hour: '小时', day: '天', week: '周', month: '月', season: '季', year: '年', longuse: '永久' };
  return map[unit] || unit || '永久';
}

// 检查黑名单
async function checkBlacklist(DB, deviceSerial, ip) {
  if (deviceSerial) {
    const blocked = await DB.prepare(
      "SELECT id FROM blacklist WHERE type = 'device' AND value = ?"
    ).bind(deviceSerial).first();
    if (blocked) return '设备已封禁';
  }
  if (ip) {
    const blocked = await DB.prepare(
      "SELECT id FROM blacklist WHERE type = 'ip' AND value = ?"
    ).bind(ip).first();
    if (blocked) return 'IP 已封禁';
  }
  return null;
}

// 获取应用配置，无则返回默认
async function getAppConfig(DB, appId) {
  const config = await DB.prepare('SELECT * FROM app_config WHERE app_id = ?').bind(appId).first();
  return config || {
    app_id: appId,
    name: appId,
    is_free: 0,
    max_unbind: 3,
    unbind_cooldown: 24,
    unbind_deduct_hours: 0,
    single_deduct: 1,
    ip_check: 0,
    notice: '',
  };
}

// ============ 核心逻辑：卡密验证/激活 ============

/**
 * 通用卡密验证 — 被 handleLegacyActivate / handleActivate / handleRegister 共用
 * 返回 { keyRow, errorMsg } — keyRow 可用则通过，errorMsg 有值则拒绝
 */
async function verifyAndActivate(DB, kami, markcode, appId, ip, model, ios, dryRun = false) {
  // 1. 黑名单检查
  const blockMsg = await checkBlacklist(DB, markcode, ip);
  if (blockMsg) return { errorMsg: blockMsg };

  // 2. 获取应用配置
  const appConfig = await getAppConfig(DB, appId);

  // 3. 免费模式直接通过
  if (appConfig.is_free === 1) {
    return { keyRow: null, freePass: true, appConfig };
  }

  // 4. 查卡密
  const keyRow = await DB.prepare(
    'SELECT * FROM keys WHERE code = ? AND app_id = ?'
  ).bind(kami, appId).first();

  if (!keyRow) return { errorMsg: '卡密不存在' };
  if (keyRow.status === 'revoked') return { errorMsg: '卡密已撤销' };

  // 5. 已过期检查
  if (keyRow.type === 'vip' && keyRow.end_time) {
    const endTime = parseInt(keyRow.end_time);
    if (endTime < Date.now() / 1000 && endTime !== 4102243200) {
      await DB.prepare("UPDATE keys SET status = 'expired' WHERE id = ?").bind(keyRow.id).run();
      return { errorMsg: '卡密已过期', keyRow };
    }
  }

  // 6. 计次卡次数检查
  if (keyRow.type === 'single' && keyRow.status === 'used') {
    if (keyRow.amount <= 0) {
      await DB.prepare("UPDATE keys SET status = 'expired' WHERE id = ?").bind(keyRow.id).run();
      return { errorMsg: '卡密次数已用完', keyRow };
    }
  }

  // 7. 设备绑定检查
  if (keyRow.status === 'used' && keyRow.device_serial && keyRow.device_serial !== markcode) {
    return { errorMsg: '卡密已绑定其他设备', keyRow };
  }

  // 8. IP 一致性检查
  if (appConfig.ip_check === 1 && keyRow.user_ip && keyRow.user_ip !== ip) {
    return { errorMsg: 'IP 地址不一致', keyRow };
  }

  if (dryRun) return { keyRow, appConfig };

  // 9. 激活逻辑
  if (keyRow.status === 'unused') {
    if (keyRow.type === 'vip') {
      // 时长卡
      const unitSec = timeUnitToSeconds(keyRow.time_unit || 'longuse');
      let endTime;
      if (keyRow.time_unit === 'longuse' || !keyRow.time_unit) {
        endTime = 4102243200; // 永久标记
      } else {
        endTime = Math.floor(Date.now() / 1000) + unitSec * (keyRow.amount || 1);
      }
      await DB.prepare(
        "UPDATE keys SET status = 'used', device_serial = ?, device_model = ?, ios_version = ?, user_ip = ?, activated_at = datetime('now'), end_time = ? WHERE id = ?"
      ).bind(markcode, model || '', ios || '', ip, String(endTime), keyRow.id).run();
      keyRow.end_time = String(endTime);
    } else if (keyRow.type === 'single') {
      // 计次卡 — 首次激活扣一次
      const deduct = appConfig.single_deduct || 1;
      const newAmount = Math.max(0, (keyRow.amount || 1) - deduct);
      const newStatus = newAmount <= 0 ? 'expired' : 'used';
      await DB.prepare(
        "UPDATE keys SET status = ?, device_serial = ?, device_model = ?, ios_version = ?, user_ip = ?, activated_at = datetime('now'), amount = ? WHERE id = ?"
      ).bind(newStatus, markcode, model || '', ios || '', ip, newAmount, keyRow.id).run();
      keyRow.amount = newAmount;
    } else {
      // 默认 vip 行为
      await DB.prepare(
        "UPDATE keys SET status = 'used', device_serial = ?, device_model = ?, ios_version = ?, user_ip = ?, activated_at = datetime('now') WHERE id = ?"
      ).bind(markcode, model || '', ios || '', ip, keyRow.id).run();
    }
  } else if (keyRow.status === 'used' && keyRow.type === 'single') {
    // 计次卡再次验证，扣减次数
    const deduct = appConfig.single_deduct || 1;
    const newAmount = Math.max(0, (keyRow.amount || 0) - deduct);
    const newStatus = newAmount <= 0 ? 'expired' : 'used';
    await DB.prepare(
      "UPDATE keys SET amount = ?, status = ? WHERE id = ?"
    ).bind(newAmount, newStatus, keyRow.id).run();
    keyRow.amount = newAmount;
  } else {
    // 已激活的时长卡，更新设备信息
    await DB.prepare(
      "UPDATE keys SET device_model = ?, ios_version = ? WHERE id = ?"
    ).bind(model || '', ios || '', keyRow.id).run();
  }

  keyRow.status = keyRow.status || 'used';
  keyRow.device_serial = markcode;
  return { keyRow, appConfig };
}

// ============ 兼容旧接口 ============

async function handleLegacyActivate(request, env) {
  const url = new URL(request.url);
  const appId = url.searchParams.get('app') || 'default';
  const kami = url.searchParams.get('kami');
  const markcode = url.searchParams.get('markcode');
  const ip = getClientIP(request);

  if (!kami || !markcode) return json({ code: 400, msg: '缺少参数' });

  const result = await verifyAndActivate(env.DB, kami, markcode, appId, ip, '', '');

  if (result.errorMsg) {
    await logAction(env.DB, 'activate', kami, markcode, ip, result.errorMsg);
    return json({ code: 403, msg: result.errorMsg });
  }

  if (result.freePass) {
    return json({ code: 200, msg: 'success', data: { kami, markcode, vip: '4102243200' } });
  }

  const action = result.keyRow.status === 'unused' ? '激活成功' : '验证通过';
  await logAction(env.DB, 'activate', kami, markcode, ip, action);

  const vip = result.keyRow.end_time || '';
  return json({ code: 200, msg: 'success', data: { kami, markcode, vip, expires_at: result.keyRow.expires_at } });
}

async function handleLegacyRegister(request, env) {
  const url = new URL(request.url);
  const api = url.searchParams.get('api') || 'ts_register';

  // === VCam 接口（独立卡密，不绑 app_id）===
  if (api === 'vcam_verify') return handleVcamVerify(request, env);
  if (api === 'vcam_admin_list') return handleVcamAdminList(request, env);
  if (api === 'vcam_admin_add') return handleVcamAdminAdd(request, env);
  if (api === 'vcam_admin_stats') return handleVcamAdminStats(request, env);
  if (api === 'vcam_admin_toggle') return handleVcamAdminToggle(request, env);
  if (api === 'vcam_admin_unbind') return handleVcamAdminUnbind(request, env);
  if (api === 'vcam_admin_delete') return handleVcamAdminDelete(request, env);

  // === 旧 ts_register ===
  const markcode = url.searchParams.get('markcode');
  const kami = url.searchParams.get('kami');
  const model = url.searchParams.get('model') || '';
  const ios = url.searchParams.get('ios') || '';
  const ip = getClientIP(request);

  if (!kami || !markcode) return json({ code: 400, msg: '缺少参数' });

  const result = await verifyAndActivate(env.DB, kami, markcode, 'trollstore', ip, model, ios);

  if (result.errorMsg) {
    await logAction(env.DB, 'register', kami, markcode, ip, result.errorMsg);
    return json({ code: 403, msg: result.errorMsg });
  }

  if (result.freePass) {
    return json({ code: 200, msg: 'success', data: { kami, markcode, model, ios, vip: '4102243200' } });
  }

  await logAction(env.DB, 'register', kami, markcode, ip, `注册成功 model=${model} ios=${ios}`);
  const vip = result.keyRow.end_time || '';
  return json({ code: 200, msg: 'success', data: { kami, markcode, model, ios, vip, expires_at: result.keyRow.expires_at } });
}

// ============ VCam 独立卡密验证 ============

async function initVcamTable(DB) {
  await DB.prepare(`
    CREATE TABLE IF NOT EXISTS vcam_keys (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      code TEXT NOT NULL UNIQUE,
      device_serial TEXT DEFAULT '',
      device_udid TEXT DEFAULT '',
      device_markcode TEXT DEFAULT '',
      device_model TEXT DEFAULT '',
      ios_version TEXT DEFAULT '',
      activated_at TEXT DEFAULT NULL,
      last_active TEXT DEFAULT NULL,
      status TEXT DEFAULT 'active',
      created_at TEXT DEFAULT (datetime('now'))
    )
  `).run();
}

async function handleVcamVerify(request, env) {
  const url = new URL(request.url);
  const kami = url.searchParams.get('kami');
  const serial = url.searchParams.get('serial') || '';
  const udid = url.searchParams.get('udid') || '';
  const markcode = url.searchParams.get('markcode') || '';
  const model = url.searchParams.get('model') || '';
  const ios = url.searchParams.get('ios') || '';

  if (!kami) return json({ code: 400, msg: '缺少卡密' });

  await initVcamTable(env.DB);

  const keyRow = await env.DB.prepare('SELECT * FROM vcam_keys WHERE code = ?').bind(kami).first();
  if (!keyRow) return json({ code: 401, msg: '卡密不存在' });
  if (keyRow.status === 'disabled') return json({ code: 401, msg: '卡密已禁用' });

  // 已绑定设备 → 校验是否为同一设备
  if (keyRow.device_serial || keyRow.device_udid) {
    let sameDevice = false;
    if (serial && keyRow.device_serial === serial) sameDevice = true;
    if (!sameDevice && udid && keyRow.device_udid === udid) sameDevice = true;

    if (sameDevice) {
      await env.DB.prepare(
        'UPDATE vcam_keys SET last_active = datetime(now), device_markcode = ? WHERE id = ?'
      ).bind(markcode, keyRow.id).run();
      return json({ code: 200, msg: '授权成功' });
    }
    return json({ code: 401, msg: '卡密已被其他设备使用' });
  }

  // 首次激活 → 绑定设备
  await env.DB.prepare(`
    UPDATE vcam_keys SET
      device_serial = ?, device_udid = ?, device_markcode = ?,
      device_model = ?, ios_version = ?,
      activated_at = datetime('now'), last_active = datetime('now')
    WHERE id = ?
  `).bind(serial, udid, markcode, model, ios, keyRow.id).run();

  return json({ code: 200, msg: '激活成功' });
}

async function handleVcamAdminList(request, env) {
  if (!isAdmin(request, env)) return json({ code: 403, msg: '未授权' }, 401);
  await initVcamTable(env.DB);
  const rows = await env.DB.prepare('SELECT * FROM vcam_keys ORDER BY created_at DESC LIMIT 200').all();
  return json({ code: 200, data: rows.results });
}

async function handleVcamAdminAdd(request, env) {
  if (!isAdmin(request, env)) return json({ code: 403, msg: '未授权' }, 401);
  await initVcamTable(env.DB);
  const url = new URL(request.url);
  const kami = url.searchParams.get('kami') || '';
  const count = parseInt(url.searchParams.get('count') || '0') || 0;

  if (kami) {
    await env.DB.prepare('INSERT OR IGNORE INTO vcam_keys (code) VALUES (?)').bind(kami).run();
    return json({ code: 200, msg: '添加成功', kami });
  }

  if (count > 0 && count <= 100) {
    const added = [];
    for (let i = 0; i < count; i++) {
      const arr = new Uint8Array(8);
      crypto.getRandomValues(arr);
      const k = Array.from(arr, b => b.toString(16).padStart(2, '0')).join('').toUpperCase();
      await env.DB.prepare('INSERT OR IGNORE INTO vcam_keys (code) VALUES (?)').bind(k).run();
      added.push(k);
    }
    return json({ code: 200, msg: `已生成 ${count} 张`, kamis: added });
  }

  return json({ code: 400, msg: '请提供 kami 或 count(1-100)' });
}

async function handleVcamAdminStats(request, env) {
  if (!isAdmin(request, env)) return json({ code: 403, msg: '未授权' }, 401);
  await initVcamTable(env.DB);
  const r1 = await env.DB.prepare('SELECT COUNT(*) as c FROM vcam_keys').first();
  const r2 = await env.DB.prepare("SELECT COUNT(*) as c FROM vcam_keys WHERE status='active'").first();
  const r3 = await env.DB.prepare('SELECT COUNT(*) as c FROM vcam_keys WHERE activated_at IS NOT NULL').first();
  const r4 = await env.DB.prepare("SELECT COUNT(*) as c FROM vcam_keys WHERE status='disabled'").first();
  return json({ code: 200, total: r1.c, active: r2.c, bound: r3.c, disabled: r4.c });
}

async function handleVcamAdminToggle(request, env) {
  if (!isAdmin(request, env)) return json({ code: 403, msg: '未授权' }, 401);
  const id = parseInt(new URL(request.url).searchParams.get('id') || '0');
  if (!id) return json({ code: 400 });
  const row = await env.DB.prepare('SELECT status FROM vcam_keys WHERE id = ?').bind(id).first();
  if (!row) return json({ code: 404, msg: '卡密不存在' });
  const next = row.status === 'active' ? 'disabled' : 'active';
  await env.DB.prepare('UPDATE vcam_keys SET status = ? WHERE id = ?').bind(next, id).run();
  return json({ code: 200, msg: `已切换为 ${next}` });
}

async function handleVcamAdminUnbind(request, env) {
  if (!isAdmin(request, env)) return json({ code: 403, msg: '未授权' }, 401);
  const id = parseInt(new URL(request.url).searchParams.get('id') || '0');
  if (!id) return json({ code: 400 });
  await env.DB.prepare(`UPDATE vcam_keys SET device_serial='', device_udid='', device_markcode='', device_model='', ios_version='', activated_at=NULL, last_active=NULL WHERE id = ?`).bind(id).run();
  return json({ code: 200, msg: '已解绑' });
}

async function handleVcamAdminDelete(request, env) {
  if (!isAdmin(request, env)) return json({ code: 403, msg: '未授权' }, 401);
  const id = parseInt(new URL(request.url).searchParams.get('id') || '0');
  if (!id) return json({ code: 400 });
  await env.DB.prepare('DELETE FROM vcam_keys WHERE id = ?').bind(id).run();
  return json({ code: 200, msg: '已删除' });
}

// ============ 新接口 ============

async function handleActivate(request, env) {
  let body;
  try { body = await request.json(); } catch { return json({ code: 0, msg: '请求格式错误' }, 400); }

  const { kami, markcode, app_id = 'default' } = body;
  const ip = getClientIP(request);

  if (!kami || !markcode) return json({ code: 0, msg: '缺少卡密或设备标识' }, 400);

  const result = await verifyAndActivate(env.DB, kami, markcode, app_id, ip, '', '');

  if (result.errorMsg) {
    await logAction(env.DB, 'activate', kami, markcode, ip, result.errorMsg);
    return json({ code: 0, msg: result.errorMsg });
  }

  if (result.freePass) {
    return json({ code: 1, msg: '验证通过(免费模式)', data: { vip: '4102243200' } });
  }

  const isNew = result.keyRow.activated_at === null;
  await logAction(env.DB, isNew ? 'activate' : 'verify', kami, markcode, ip, isNew ? '激活成功' : '验证通过');

  const resp = {
    code: 1,
    msg: isNew ? '激活成功' : '验证通过',
    data: {
      type: result.keyRow.type,
      end_time: result.keyRow.end_time,
      expires_at: result.keyRow.expires_at,
    },
  };
  if (result.keyRow.type === 'single') {
    resp.data.remaining = result.keyRow.amount;
  }
  return json(resp);
}

/**
 * POST /api/unbind — 卡密解绑
 * Body: { kami, markcode, app_id }
 */
async function handleUnbind(request, env) {
  let body;
  try { body = await request.json(); } catch { return json({ code: 0, msg: '请求格式错误' }, 400); }

  const { kami, markcode, app_id = 'default' } = body;
  const ip = getClientIP(request);

  if (!kami || !markcode) return json({ code: 0, msg: '缺少参数' }, 400);

  const keyRow = await env.DB.prepare(
    'SELECT * FROM keys WHERE code = ? AND app_id = ?'
  ).bind(kami, app_id).first();

  if (!keyRow) return json({ code: 0, msg: '卡密不存在' });
  if (keyRow.status === 'revoked') return json({ code: 0, msg: '卡密已撤销' });
  if (keyRow.status === 'unused') return json({ code: 0, msg: '未激活的卡密无需解绑' });
  if (!keyRow.device_serial) return json({ code: 0, msg: '卡密未绑定设备' });

  // 验证当前设备
  if (keyRow.device_serial !== markcode) {
    return json({ code: 0, msg: '仅绑定的设备可申请解绑' });
  }

  const appConfig = await getAppConfig(env.DB, app_id);

  // 检查解绑次数
  const maxUnbind = keyRow.max_unbind || appConfig.max_unbind || 3;
  if (maxUnbind > 0 && keyRow.unbind_count >= maxUnbind) {
    return json({ code: 0, msg: `解绑次数已用完(${keyRow.unbind_count}/${maxUnbind})` });
  }

  // 检查冷却时间
  if (keyRow.last_unbind_at) {
    const cooldown = (keyRow.unbind_cooldown || appConfig.unbind_cooldown || 24) * 3600 * 1000;
    const elapsed = Date.now() - new Date(keyRow.last_unbind_at).getTime();
    if (elapsed < cooldown) {
      const remaining = Math.ceil((cooldown - elapsed) / 3600000);
      return json({ code: 0, msg: `解绑冷却中，还需等待 ${remaining} 小时` });
    }
  }

  // 时长卡解绑扣时长
  let newEndTime = keyRow.end_time;
  if (keyRow.type === 'vip' && keyRow.end_time && keyRow.end_time !== '4102243200') {
    const deductSec = (keyRow.unbind_cooldown || appConfig.unbind_deduct_hours || 0) * 3600;
    if (deductSec > 0) {
      newEndTime = String(Math.max(0, parseInt(keyRow.end_time) - deductSec));
    }
  }

  // 计次卡解绑扣次数
  let newAmount = keyRow.amount;
  if (keyRow.type === 'single') {
    const deduct = appConfig.single_deduct || 0;
    if (deduct > 0) {
      newAmount = Math.max(0, keyRow.amount - deduct);
    }
  }

  // 执行解绑
  await env.DB.prepare(
    "UPDATE keys SET device_serial = '', device_model = '', ios_version = '', user_ip = '', unbind_count = unbind_count + 1, last_unbind_at = datetime('now'), end_time = ?, amount = ?, status = 'unused' WHERE id = ?"
  ).bind(newEndTime, newAmount, keyRow.id).run();

  await logAction(env.DB, 'unbind', kami, markcode, ip, `解绑成功(第${keyRow.unbind_count + 1}次)`);

  const remainUnbind = maxUnbind > 0 ? maxUnbind - keyRow.unbind_count - 1 : -1;
  return json({
    code: 1,
    msg: '解绑成功',
    data: {
      unbind_count: keyRow.unbind_count + 1,
      max_unbind: maxUnbind,
      remaining_unbind: remainUnbind >= 0 ? remainUnbind : '无限',
    },
  });
}

/**
 * GET /api/verify
 */
async function handleVerify(request, env) {
  const url = new URL(request.url);
  const kami = url.searchParams.get('kami');
  const markcode = url.searchParams.get('markcode');
  const appId = url.searchParams.get('app_id') || 'default';
  const ip = getClientIP(request);

  if (!kami) return json({ code: 0, msg: '缺少卡密' }, 400);

  const result = await verifyAndActivate(env.DB, kami, markcode, appId, ip, '', '', true);

  if (result.errorMsg) return json({ code: 0, msg: result.errorMsg });
  if (result.freePass) return json({ code: 1, msg: '验证通过(免费模式)' });

  await logAction(env.DB, 'verify', kami, markcode, ip, '验证通过');

  const resp = {
    code: 1,
    msg: '验证通过',
    data: {
      status: result.keyRow.status,
      type: result.keyRow.type,
      device_serial: result.keyRow.device_serial,
      activated_at: result.keyRow.activated_at,
      end_time: result.keyRow.end_time,
      expires_at: result.keyRow.expires_at,
    },
  };
  if (result.keyRow.type === 'single') resp.data.remaining = result.keyRow.amount;
  return json(resp);
}

/**
 * POST /api/register
 */
async function handleRegister(request, env) {
  let body;
  try { body = await request.json(); } catch { return json({ code: 0, msg: '请求格式错误' }, 400); }

  const { kami, markcode, model = '', ios = '', app_id = 'default' } = body;
  const ip = getClientIP(request);

  if (!kami || !markcode) return json({ code: 0, msg: '缺少参数' }, 400);

  const result = await verifyAndActivate(env.DB, kami, markcode, app_id, ip, model, ios);

  if (result.errorMsg) {
    await logAction(env.DB, 'register', kami, markcode, ip, result.errorMsg);
    return json({ code: 0, msg: result.errorMsg });
  }

  if (result.freePass) {
    return json({ code: 1, msg: '注册成功(免费模式)' });
  }

  await logAction(env.DB, 'register', kami, markcode, ip, `注册成功 model=${model} ios=${ios}`);
  const resp = { code: 1, msg: '注册成功', data: { type: result.keyRow.type, end_time: result.keyRow.end_time } };
  if (result.keyRow.type === 'single') resp.data.remaining = result.keyRow.amount;
  return json(resp);
}

// ============ 管理接口 ============

async function handleAdminInit(request, env) {
  const existing = await env.DB.prepare('SELECT COUNT(*) as cnt FROM admin_tokens').first();
  if (existing && existing.cnt > 0) {
    return json({ code: 0, msg: '已初始化' }, 403);
  }
  let body; try { body = await request.json(); } catch { body = {}; }
  const name = body.name || 'admin';
  const token = generateToken();
  await env.DB.prepare('INSERT INTO admin_tokens (token, name) VALUES (?, ?)').bind(token, name).run();
  return json({ code: 1, msg: '初始化成功（请妥善保存 token，不会再次显示）', data: { token, name } });
}

async function handleAdminListKeys(request, env) {
  const url = new URL(request.url);
  const status = url.searchParams.get('status');
  const appId = url.searchParams.get('app_id');
  const type = url.searchParams.get('type');
  const page = Math.max(1, parseInt(url.searchParams.get('page')) || 1);
  const limit = Math.min(100, Math.max(1, parseInt(url.searchParams.get('limit')) || 20));
  const search = url.searchParams.get('search');
  const offset = (page - 1) * limit;

  let where = [];
  let params = [];
  if (status) { where.push('status = ?'); params.push(status); }
  if (appId) { where.push('app_id = ?'); params.push(appId); }
  if (type) { where.push('type = ?'); params.push(type); }
  if (search) {
    where.push('(code LIKE ? OR device_serial LIKE ? OR note LIKE ?)');
    const like = `%${search}%`;
    params.push(like, like, like);
  }
  const whereClause = where.length ? 'WHERE ' + where.join(' AND ') : '';

  const total = await env.DB.prepare(`SELECT COUNT(*) as cnt FROM keys ${whereClause}`).bind(...params).first();
  const rows = await env.DB.prepare(`SELECT * FROM keys ${whereClause} ORDER BY id DESC LIMIT ? OFFSET ?`).bind(...params, limit, offset).all();

  return json({ code: 1, data: { keys: rows.results, total: total.cnt, page, limit, pages: Math.ceil(total.cnt / limit) } });
}

async function handleAdminGenerate(request, env) {
  let body; try { body = await request.json(); } catch { return json({ code: 0, msg: '请求格式错误' }, 400); }

  const count = Math.min(500, Math.max(1, body.count || 1));
  const appId = body.app_id || 'default';
  const expiresDays = body.expires_days || null;
  const prefix = body.prefix || '';
  const note = body.note || '';
  const mode = body.mode || 'alphanum';
  const keyLength = Math.min(64, Math.max(4, body.length || 16));
  const type = body.type || 'vip';                // vip / single
  const timeUnit = body.time_unit || 'longuse';   // hour/day/week/month/season/year/longuse
  const amount = body.amount || 1;                 // 时长倍数 或 计次卡次数
  const maxUnbind = body.max_unbind !== undefined ? body.max_unbind : 3;
  const unbindCooldown = body.unbind_cooldown || 24;
  const ip = getClientIP(request);

  const keys = [];
  for (let i = 0; i < count; i++) {
    const code = prefix + generateKey(keyLength, mode);
    const expiresAt = expiresDays
      ? new Date(Date.now() + expiresDays * 86400000).toISOString().slice(0, 19).replace('T', ' ')
      : null;

    try {
      await env.DB.prepare(
        `INSERT INTO keys (code, app_id, expires_at, note, type, amount, time_unit, max_unbind, unbind_cooldown)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
      ).bind(code, appId, expiresAt, note, type, amount, type === 'vip' ? timeUnit : null, maxUnbind, unbindCooldown).run();
      keys.push(code);
    } catch {
      const code2 = prefix + generateKey(keyLength, mode);
      try {
        await env.DB.prepare(
          `INSERT INTO keys (code, app_id, expires_at, note, type, amount, time_unit, max_unbind, unbind_cooldown)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
        ).bind(code2, appId, expiresAt, note, type, amount, type === 'vip' ? timeUnit : null, maxUnbind, unbindCooldown).run();
        keys.push(code2);
      } catch {}
    }
  }

  await logAction(env.DB, 'generate', null, null, ip, `生成 ${keys.length} 个卡密 app=${appId} type=${type}`);
  return json({ code: 1, msg: `成功生成 ${keys.length} 个卡密`, data: { keys, count: keys.length } });
}

async function handleAdminRevoke(request, env) {
  let body; try { body = await request.json(); } catch { return json({ code: 0, msg: '请求格式错误' }, 400); }
  const codes = body.codes || (body.code ? [body.code] : []);
  if (!codes.length) return json({ code: 0, msg: '未指定卡密' }, 400);

  let revoked = 0;
  for (const code of codes) {
    const result = await env.DB.prepare(
      "UPDATE keys SET status = 'revoked' WHERE code = ? AND status != 'revoked'"
    ).bind(code).run();
    revoked += result.meta.changes;
  }

  await logAction(env.DB, 'revoke', codes.join(','), null, getClientIP(request), `撤销 ${revoked} 个`);
  return json({ code: 1, msg: `已撤销 ${revoked} 个卡密`, data: { revoked } });
}

async function handleAdminDeleteKey(request, env, id) {
  if (!id) return json({ code: 0, msg: '缺少 ID' }, 400);
  const result = await env.DB.prepare('DELETE FROM keys WHERE id = ?').bind(id).run();
  if (result.meta.changes === 0) return json({ code: 0, msg: '卡密不存在' }, 404);
  await logAction(env.DB, 'delete', `id=${id}`, null, getClientIP(request), '删除卡密');
  return json({ code: 1, msg: '已删除' });
}

async function handleAdminStats(request, env) {
  const total = await env.DB.prepare('SELECT COUNT(*) as cnt FROM keys').first();
  const unused = await env.DB.prepare("SELECT COUNT(*) as cnt FROM keys WHERE status = 'unused'").first();
  const used = await env.DB.prepare("SELECT COUNT(*) as cnt FROM keys WHERE status = 'used'").first();
  const expired = await env.DB.prepare("SELECT COUNT(*) as cnt FROM keys WHERE status = 'expired'").first();
  const revoked = await env.DB.prepare("SELECT COUNT(*) as cnt FROM keys WHERE status = 'revoked'").first();
  const byApp = await env.DB.prepare("SELECT app_id, status, COUNT(*) as cnt FROM keys GROUP BY app_id, status ORDER BY app_id").all();
  const byType = await env.DB.prepare("SELECT type, COUNT(*) as cnt FROM keys GROUP BY type").all();
  const recentActivations = await env.DB.prepare(
    "SELECT date(activated_at) as day, COUNT(*) as cnt FROM keys WHERE activated_at >= date('now', '-7 days') GROUP BY date(activated_at) ORDER BY day"
  ).all();

  return json({ code: 1, data: {
    total: total.cnt, unused: unused.cnt, used: used.cnt, expired: expired.cnt, revoked: revoked.cnt,
    by_app: byApp.results, by_type: byType.results, recent_activations: recentActivations.results,
  } });
}

async function handleAdminLogs(request, env) {
  const url = new URL(request.url);
  const action = url.searchParams.get('action');
  const page = Math.max(1, parseInt(url.searchParams.get('page')) || 1);
  const limit = Math.min(100, Math.max(1, parseInt(url.searchParams.get('limit')) || 20));
  const offset = (page - 1) * limit;

  let where = '';
  let params = [];
  if (action) { where = 'WHERE action = ?'; params.push(action); }

  const total = await env.DB.prepare(`SELECT COUNT(*) as cnt FROM audit_log ${where}`).bind(...params).first();
  const rows = await env.DB.prepare(`SELECT * FROM audit_log ${where} ORDER BY id DESC LIMIT ? OFFSET ?`).bind(...params, limit, offset).all();

  return json({ code: 1, data: { logs: rows.results, total: total.cnt, page, limit } });
}

async function handleAdminCreateToken(request, env) {
  let body; try { body = await request.json(); } catch { body = {}; }
  const name = body.name || 'token';
  const token = generateToken();
  await env.DB.prepare('INSERT INTO admin_tokens (token, name) VALUES (?, ?)').bind(token, name).run();
  return json({ code: 1, msg: 'Token 创建成功', data: { token, name } });
}

// ============ 黑名单管理 ============

async function handleAdminListBlacklist(request, env) {
  const url = new URL(request.url);
  const type = url.searchParams.get('type');
  let where = '';
  let params = [];
  if (type) { where = 'WHERE type = ?'; params.push(type); }
  const rows = await env.DB.prepare(`SELECT * FROM blacklist ${where} ORDER BY id DESC`).bind(...params).all();
  return json({ code: 1, data: rows.results });
}

async function handleAdminAddBlacklist(request, env) {
  let body; try { body = await request.json(); } catch { return json({ code: 0, msg: '请求格式错误' }, 400); }
  const { type = 'device', value, reason = '' } = body;
  if (!value) return json({ code: 0, msg: '缺少值' }, 400);
  try {
    await env.DB.prepare('INSERT INTO blacklist (type, value, reason) VALUES (?, ?, ?)').bind(type, value, reason).run();
  } catch {
    return json({ code: 0, msg: '已存在' });
  }
  await logAction(env.DB, 'blacklist', null, type === 'device' ? value : null, getClientIP(request), `添加黑名单 ${type}=${value}`);
  return json({ code: 1, msg: '已添加' });
}

async function handleAdminDeleteBlacklist(request, env, id) {
  const result = await env.DB.prepare('DELETE FROM blacklist WHERE id = ?').bind(id).run();
  return json({ code: result.meta.changes > 0 ? 1 : 0, msg: result.meta.changes > 0 ? '已删除' : '不存在' });
}

// ============ 应用配置管理 ============

async function handleAdminListApps(request, env) {
  const rows = await env.DB.prepare('SELECT * FROM app_config ORDER BY app_id').all();
  return json({ code: 1, data: rows.results });
}

async function handleAdminUpdateApp(request, env) {
  let body; try { body = await request.json(); } catch { return json({ code: 0, msg: '请求格式错误' }, 400); }
  const { app_id, name, is_free, max_unbind, unbind_cooldown, unbind_deduct_hours, single_deduct, ip_check, notice } = body;
  if (!app_id) return json({ code: 0, msg: '缺少 app_id' }, 400);

  await env.DB.prepare(`
    INSERT INTO app_config (app_id, name, is_free, max_unbind, unbind_cooldown, unbind_deduct_hours, single_deduct, ip_check, notice, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
    ON CONFLICT(app_id) DO UPDATE SET
      name = excluded.name, is_free = excluded.is_free, max_unbind = excluded.max_unbind,
      unbind_cooldown = excluded.unbind_cooldown, unbind_deduct_hours = excluded.unbind_deduct_hours,
      single_deduct = excluded.single_deduct, ip_check = excluded.ip_check, notice = excluded.notice,
      updated_at = datetime('now')
  `).bind(app_id, name || app_id, is_free || 0, max_unbind ?? 3, unbind_cooldown ?? 24,
    unbind_deduct_hours ?? 0, single_deduct ?? 1, ip_check ?? 0, notice || ''
  ).run();

  return json({ code: 1, msg: '已保存' });
}

// ============ 内核分发 API ============

/**
 * GET /kernel/{filename} — 兼容旧下载方式，同时记录统计
 * 如: /kernel/iPhone15.2_16.5.kernelcache
 */
async function handleKernelDownload(request, env, filename) {
  const ip = getClientIP(request);
  const country = request.headers.get('CF-IPCountry') || '';
  const ua = request.headers.get('User-Agent') || '';

  // 尝试从 R2 取文件
  const r2Key = filename;
  const obj = await env.KERNEL_BUCKET.get(r2Key);

  if (!obj) {
    // 记录未找到
    await logKernelDownload(env.DB, null, filename, '', '', ip, ua, country, 'not_found');
    return json({ code: 0, msg: '内核文件不存在' }, 404);
  }

  // 更新下载计数 + 记录日志
  const kernelRow = await env.DB.prepare(
    'SELECT id FROM kernels WHERE filename = ? OR r2_key = ?'
  ).bind(filename, r2Key).first();

  if (kernelRow) {
    await env.DB.prepare('UPDATE kernels SET download_count = download_count + 1 WHERE id = ?').bind(kernelRow.id).run();
    await logKernelDownload(env.DB, kernelRow.id, filename, '', '', ip, ua, country, 'success');
  } else {
    await logKernelDownload(env.DB, null, filename, '', '', ip, ua, country, 'success');
  }

  return new Response(obj.body, {
    headers: {
      'Content-Type': 'application/octet-stream',
      'Content-Disposition': 'attachment; filename="' + filename + '"',
      'Content-Length': obj.size,
      'Cache-Control': 'public, max-age=86400',
      'Access-Control-Allow-Origin': '*',
    },
  });
}

async function logKernelDownload(DB, kernelId, filename, model, iosVer, ip, ua, country, status) {
  try {
    await DB.prepare(
      'INSERT INTO download_log (kernel_id, model, ios_version, ip, user_agent, cf_country, status) VALUES (?, ?, ?, ?, ?, ?, ?)'
    ).bind(kernelId, model || null, iosVer || null, ip, ua.substring(0, 500), country, status).run();
  } catch (e) {
    console.error('kernel download log error:', e.message);
  }
}

/**
 * GET /api/kernel/query?model=iPhone15,2&ios=16.5.1
 * 查询内核是否存在 + 返回下载链接
 */
async function handleKernelQuery(request, env) {
  const url = new URL(request.url);
  const model = url.searchParams.get('model');
  const ios = url.searchParams.get('ios');

  if (!model || !ios) return json({ code: 0, msg: '缺少 model 或 ios 参数' }, 400);

  const fixedModel = model.replace(/,/g, '.');
  const parts = ios.split('.');
  const shortIos = parts.length >= 2 ? parts[0] + '.' + parts[1] : ios;

  // 先精确匹配
  let row = await env.DB.prepare(
    'SELECT * FROM kernels WHERE model = ? AND ios_version = ?'
  ).bind(model, ios).first();

  // 再短版本匹配
  if (!row) {
    row = await env.DB.prepare(
      'SELECT * FROM kernels WHERE model = ? AND ios_short = ?'
    ).bind(model, shortIos).first();
  }

  // 最后从 R2 直接探测文件是否存在
  if (!row) {
    const testKeys = [
      fixedModel + '_' + ios + '.kernelcache',
      fixedModel + '_' + shortIos + '.kernelcache',
    ];
    for (const key of testKeys) {
      const obj = await env.KERNEL_BUCKET.head(key);
      if (obj) {
        // R2 有文件但 D1 没索引，自动补录
        const deviceType = model.startsWith('iPad') ? 'ipad' : 'iphone';
        try {
          await env.DB.prepare(
            'INSERT INTO kernels (filename, model, device_type, ios_version, ios_short, file_size, r2_key) VALUES (?, ?, ?, ?, ?, ?, ?)'
          ).bind(key, model, deviceType, ios, shortIos, obj.size, key).run();
        } catch {}
        row = { filename: key, model, ios_version: ios, ios_short: shortIos, file_size: obj.size, download_count: 0 };
        break;
      }
    }
  }

  if (!row) {
    return json({ code: 0, msg: '未找到匹配内核', data: { model, ios, available: false } });
  }

  const baseUrl = 'https://' + request.headers.get('Host') || 'kami.jumo8.top';
  return json({
    code: 1,
    msg: '找到内核',
    data: {
      available: true,
      filename: row.filename,
      download_url: 'https://kernel0.jumo8.top/' + (row.r2_key || row.filename),
      file_size: row.file_size,
      download_count: row.download_count,
      model: row.model,
      ios_version: row.ios_version,
    },
  });
}

/**
 * GET /api/kernel/list?type=iphone&ios=16 — 列出可用内核
 */
async function handleKernelList(request, env) {
  const url = new URL(request.url);
  const type = url.searchParams.get('type') || '';
  const ios = url.searchParams.get('ios') || '';
  const page = Math.max(1, parseInt(url.searchParams.get('page')) || 1);
  const limit = Math.min(200, Math.max(1, parseInt(url.searchParams.get('limit')) || 50));
  const offset = (page - 1) * limit;

  let where = [];
  let params = [];
  if (type) { where.push('device_type = ?'); params.push(type); }
  if (ios) { where.push('ios_short LIKE ?'); params.push(ios + '%'); }
  const whereClause = where.length ? 'WHERE ' + where.join(' AND ') : '';

  const total = await env.DB.prepare(`SELECT COUNT(*) as cnt FROM kernels ${whereClause}`).bind(...params).first();
  const rows = await env.DB.prepare(
    `SELECT id, filename, model, model_name, device_type, ios_version, ios_short, file_size, download_count FROM kernels ${whereClause} ORDER BY model, ios_version DESC LIMIT ? OFFSET ?`
  ).bind(...params, limit, offset).all();

  return json({ code: 1, data: { kernels: rows.results, total: total.cnt, page, limit } });
}

/**
 * POST /api/admin/kernel/scan — 扫描 R2 导入内核索引
 */
async function handleAdminScanKernel(request, env) {
  let imported = 0;
  let skipped = 0;
  let cursor = undefined;

  do {
    const listed = await env.KERNEL_BUCKET.list({ cursor, limit: 500 });
    for (const obj of listed.objects) {
      const key = obj.key;
      if (!key.endsWith('.kernelcache')) { skipped++; continue; }

      // 解析文件名: iPhone15.2_16.5.kernelcache
      const match = key.match(/^(.+)_(\d+\.\d+(?:\.\d+)?)\.kernelcache$/);
      if (!match) { skipped++; continue; }

      const model = match[1].replace(/\./g, ','); // iPhone15,2
      const iosVersion = match[2];
      const parts = iosVersion.split('.');
      const iosShort = parts[0] + '.' + parts[1];
      const deviceType = model.startsWith('iPad') ? 'ipad' : 'iphone';

      try {
        await env.DB.prepare(`
          INSERT INTO kernels (filename, model, device_type, ios_version, ios_short, file_size, r2_key)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(model, ios_version) DO UPDATE SET file_size = excluded.file_size, r2_key = excluded.r2_key, updated_at = datetime('now')
        `).bind(key, model, deviceType, iosVersion, iosShort, obj.size, key).run();
        imported++;
      } catch (e) {
        skipped++;
      }
    }
    cursor = listed.truncated ? listed.cursor : undefined;
  } while (cursor);

  return json({ code: 1, msg: `扫描完成：导入 ${imported} 个，跳过 ${skipped} 个`, data: { imported, skipped } });
}

/**
 * GET /api/admin/kernel/stats — 内核下载统计
 */
async function handleAdminKernelStats(request, env) {
  const totalKernels = await env.DB.prepare('SELECT COUNT(*) as cnt FROM kernels').first();
  const totalDownloads = await env.DB.prepare('SELECT SUM(download_count) as cnt FROM kernels').first();
  const topKernels = await env.DB.prepare(
    'SELECT model, ios_version, download_count FROM kernels ORDER BY download_count DESC LIMIT 20'
  ).all();
  const byCountry = await env.DB.prepare(
    "SELECT cf_country as country, COUNT(*) as cnt FROM download_log WHERE cf_country != '' GROUP BY cf_country ORDER BY cnt DESC LIMIT 20"
  ).all();
  const recentDl = await env.DB.prepare(
    "SELECT date(created_at) as day, COUNT(*) as cnt FROM download_log WHERE status = 'success' GROUP BY date(created_at) ORDER BY day DESC LIMIT 14"
  ).all();

  return json({ code: 1, data: {
    total_kernels: totalKernels.cnt,
    total_downloads: totalDownloads.cnt || 0,
    top_kernels: topKernels.results,
    downloads_by_country: byCountry.results,
    recent_downloads: recentDl.results,
  } });
}

/**
 * GET /api/kernel/announcement?model=iPhone15,2&ios=16.5
 */
async function handleKernelAnnouncement(request, env) {
  const url = new URL(request.url);
  const model = url.searchParams.get('model') || '';
  const ios = url.searchParams.get('ios') || '';
  const deviceType = model.startsWith('iPad') ? 'ipad' : 'iphone';

  const rows = await env.DB.prepare(
    "SELECT title, content, target_type FROM announcements WHERE active = 1 AND (target_type = 'all' OR target_type = ?) AND (expires_at IS NULL OR expires_at > datetime('now')) ORDER BY id DESC LIMIT 5"
  ).bind(deviceType).all();

  return json({ code: 1, data: rows.results });
}

// ============ 路由 ============

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;
    const method = request.method;

    if (method === 'OPTIONS') {
      return new Response(null, {
        headers: { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS', 'Access-Control-Allow-Headers': 'Content-Type, Authorization' },
      });
    }

    // ===== 兼容旧接口 =====
    if (path === '/api.php') return handleLegacyActivate(request, env);
    if (path === '/trollstore-device-api.php') return handleLegacyRegister(request, env);

    // ===== 内核分发 =====
    // 兼容旧下载: /kernel/iPhone15.2_16.5.kernelcache (重定向到 R2 直链)
    const kernelFileMatch = path.match(/^\/kernel\/(.+\.kernelcache)$/);
    if (kernelFileMatch) return handleKernelDownload(request, env, kernelFileMatch[1]);

    if (path === '/api/kernel/query' && method === 'GET') return handleKernelQuery(request, env);
    if (path === '/api/kernel/list' && method === 'GET') return handleKernelList(request, env);
    if (path === '/api/kernel/announcement' && method === 'GET') return handleKernelAnnouncement(request, env);

    // ===== 新接口 =====
    if (path === '/api/activate' && method === 'POST') return handleActivate(request, env);
    if (path === '/api/unbind' && method === 'POST') return handleUnbind(request, env);
    if (path === '/api/verify' && method === 'GET') return handleVerify(request, env);
    if (path === '/api/register' && method === 'POST') return handleRegister(request, env);

    // ===== 管理接口 =====
    if (path.startsWith('/api/admin/')) {
      if (path === '/api/admin/init' && method === 'POST') return handleAdminInit(request, env);
      if (!isAdmin(request, env)) return json({ code: 0, msg: '未授权' }, 401);

      if (path === '/api/admin/keys' && method === 'GET') return handleAdminListKeys(request, env);
      if (path === '/api/admin/generate' && method === 'POST') return handleAdminGenerate(request, env);
      if (path === '/api/admin/revoke' && method === 'POST') return handleAdminRevoke(request, env);
      if (path === '/api/admin/stats' && method === 'GET') return handleAdminStats(request, env);
      if (path === '/api/admin/logs' && method === 'GET') return handleAdminLogs(request, env);
      if (path === '/api/admin/tokens' && method === 'POST') return handleAdminCreateToken(request, env);

      // 黑名单
      if (path === '/api/admin/blacklist' && method === 'GET') return handleAdminListBlacklist(request, env);
      if (path === '/api/admin/blacklist' && method === 'POST') return handleAdminAddBlacklist(request, env);
      const blDeleteMatch = path.match(/^\/api\/admin\/blacklist\/(\d+)$/);
      if (blDeleteMatch && method === 'DELETE') return handleAdminDeleteBlacklist(request, env, parseInt(blDeleteMatch[1]));

      // 应用配置
      if (path === '/api/admin/apps' && method === 'GET') return handleAdminListApps(request, env);
      if (path === '/api/admin/apps' && method === 'POST') return handleAdminUpdateApp(request, env);

      // 内核管理
      if (path === '/api/admin/kernel/scan' && method === 'POST') return handleAdminScanKernel(request, env);
      if (path === '/api/admin/kernel/stats' && method === 'GET') return handleAdminKernelStats(request, env);

      // 删除卡密
      const deleteMatch = path.match(/^\/api\/admin\/keys\/(\d+)$/);
      if (deleteMatch && method === 'DELETE') return handleAdminDeleteKey(request, env, parseInt(deleteMatch[1]));
    }

    // ===== 管理后台 =====
    if (path === '/admin' || path === '/admin/') {
      return new Response(ADMIN_HTML, { headers: { 'Content-Type': 'text/html; charset=utf-8' } });
    }

    if (path === '/' || path === '/health') return json({ status: 'ok', version: '2.1.0' });
    return json({ code: 0, msg: 'Not Found' }, 404);
  },
};

// ============ 管理后台 HTML ============
const ADMIN_HTML = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>卡密管理系统</title>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #0f172a; color: #e2e8f0; min-height: 100vh; }
.login-wrap { display: flex; align-items: center; justify-content: center; min-height: 100vh; }
.login-box { background: #1e293b; border-radius: 16px; padding: 40px; width: 400px; max-width: 90vw; }
.login-box h1 { font-size: 24px; margin-bottom: 8px; }
.login-box p { color: #94a3b8; margin-bottom: 24px; font-size: 14px; }
.login-box input { width: 100%; padding: 12px 16px; background: #0f172a; border: 1px solid #334155; border-radius: 8px; color: #e2e8f0; font-size: 14px; margin-bottom: 16px; outline: none; }
.login-box input:focus { border-color: #3b82f6; }
.login-box button { width: 100%; padding: 12px; background: #3b82f6; color: white; border: none; border-radius: 8px; font-size: 16px; cursor: pointer; font-weight: 600; }
.login-box button:hover { background: #2563eb; }
.app { display: none; }
.nav { background: #1e293b; padding: 16px 24px; display: flex; align-items: center; gap: 16px; border-bottom: 1px solid #334155; flex-wrap: wrap; }
.nav h1 { font-size: 18px; font-weight: 700; }
.nav a { color: #94a3b8; text-decoration: none; font-size: 13px; padding: 6px 10px; border-radius: 6px; white-space: nowrap; }
.nav a:hover, .nav a.active { color: #e2e8f0; background: #334155; }
.nav .spacer { flex: 1; }
.nav .logout { color: #f87171; cursor: pointer; }
.container { max-width: 1200px; margin: 0 auto; padding: 24px; }
.stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 12px; margin-bottom: 24px; }
.stat-card { background: #1e293b; border-radius: 12px; padding: 16px; }
.stat-card .label { font-size: 11px; color: #94a3b8; text-transform: uppercase; letter-spacing: 0.05em; }
.stat-card .value { font-size: 28px; font-weight: 700; margin-top: 2px; }
.stat-card.unused .value { color: #22c55e; }
.stat-card.used .value { color: #3b82f6; }
.stat-card.expired .value { color: #f59e0b; }
.stat-card.revoked .value { color: #f87171; }
.panel { background: #1e293b; border-radius: 12px; padding: 20px; margin-bottom: 20px; }
.panel h2 { font-size: 15px; margin-bottom: 14px; display: flex; align-items: center; gap: 8px; }
.form-row { display: flex; gap: 10px; flex-wrap: wrap; align-items: end; }
.form-group { display: flex; flex-direction: column; gap: 3px; }
.form-group label { font-size: 11px; color: #94a3b8; }
.form-group input, .form-group select, .form-group textarea { padding: 7px 10px; background: #0f172a; border: 1px solid #334155; border-radius: 6px; color: #e2e8f0; font-size: 13px; outline: none; min-width: 100px; }
.form-group input:focus, .form-group select:focus { border-color: #3b82f6; }
.btn { padding: 7px 14px; border: none; border-radius: 6px; font-size: 13px; cursor: pointer; font-weight: 500; }
.btn-primary { background: #3b82f6; color: white; }
.btn-primary:hover { background: #2563eb; }
.btn-danger { background: #ef4444; color: white; }
.btn-danger:hover { background: #dc2626; }
.btn-sm { padding: 3px 8px; font-size: 11px; }
table { width: 100%; border-collapse: collapse; font-size: 12px; }
th { text-align: left; padding: 8px 10px; color: #94a3b8; font-weight: 500; border-bottom: 1px solid #334155; font-size: 11px; text-transform: uppercase; white-space: nowrap; }
td { padding: 8px 10px; border-bottom: 1px solid #1e293b; white-space: nowrap; }
tr:hover td { background: #1e293b; }
.badge { display: inline-block; padding: 2px 6px; border-radius: 99px; font-size: 10px; font-weight: 600; }
.badge-unused { background: #16a34a20; color: #22c55e; }
.badge-used { background: #2563eb20; color: #3b82f6; }
.badge-expired { background: #d9770620; color: #f59e0b; }
.badge-revoked { background: #dc262620; color: #f87171; }
.badge-vip { background: #8b5cf620; color: #a78bfa; }
.badge-single { background: #06b6d420; color: #22d3ee; }
.pagination { display: flex; gap: 6px; justify-content: center; margin-top: 14px; }
.pagination button { padding: 5px 10px; background: #334155; color: #e2e8f0; border: none; border-radius: 6px; cursor: pointer; font-size: 12px; }
.pagination button:disabled { opacity: 0.4; cursor: default; }
.pagination button.current { background: #3b82f6; }
.key-code { font-family: 'SF Mono', Menlo, monospace; font-size: 11px; color: #a78bfa; }
.filters { display: flex; gap: 10px; margin-bottom: 14px; flex-wrap: wrap; }
.toast { position: fixed; bottom: 24px; right: 24px; background: #22c55e; color: white; padding: 10px 18px; border-radius: 8px; font-size: 13px; z-index: 999; opacity: 0; transition: opacity 0.3s; }
.toast.show { opacity: 1; }
.toast.error { background: #ef4444; }
.tab-content { display: none; }
.tab-content.active { display: block; }
.copy-area { background: #0f172a; border: 1px solid #334155; border-radius: 8px; padding: 14px; margin-top: 14px; max-height: 280px; overflow-y: auto; font-family: monospace; font-size: 11px; white-space: pre-wrap; word-break: break-all; color: #a78bfa; }
</style>
</head>
<body>

<div id="loginPage" class="login-wrap">
  <div class="login-box">
    <h1>🔐 卡密管理 v2</h1>
    <p>输入管理员 Token 登录</p>
    <input type="password" id="tokenInput" placeholder="Admin Token" autofocus>
    <button onclick="doLogin()">登录</button>
  </div>
</div>

<div id="appPage" class="app">
  <div class="nav">
    <h1>🔐 卡密管理</h1>
    <a href="#" class="active" onclick="showTab('dashboard')">概览</a>
    <a href="#" onclick="showTab('keys')">卡密</a>
    <a href="#" onclick="showTab('generate')">生成</a>
    <a href="#" onclick="showTab('blacklist')">黑名单</a>
    <a href="#" onclick="showTab('apps')">应用</a>
    <a href="#" onclick="showTab('logs')">日志</a>
    <a href="#" onclick="showTab('vcam')">🎥 VCam</a>
    <div class="spacer"></div>
    <span class="logout" onclick="doLogout()">退出</span>
  </div>

  <div class="container">
    <!-- 概览 -->
    <div id="tab-dashboard" class="tab-content active">
      <div class="stats" id="statsGrid"></div>
      <div class="panel">
        <h2>📊 最近激活趋势</h2>
        <div id="activationChart" style="height:180px;display:flex;align-items:flex-end;gap:4px;padding-top:16px;"></div>
      </div>
    </div>

    <!-- 卡密列表 -->
    <div id="tab-keys" class="tab-content">
      <div class="filters">
        <div class="form-group"><label>状态</label><select id="filterStatus" onchange="loadKeys()"><option value="">全部</option><option value="unused">未使用</option><option value="used">已使用</option><option value="expired">已过期</option><option value="revoked">已撤销</option></select></div>
        <div class="form-group"><label>类型</label><select id="filterType" onchange="loadKeys()"><option value="">全部</option><option value="vip">时长卡</option><option value="single">计次卡</option></select></div>
        <div class="form-group"><label>应用</label><select id="filterApp" onchange="loadKeys()"><option value="">全部</option><option value="trollstore">TrollStore</option><option value="default">Default</option></select></div>
        <div class="form-group"><label>搜索</label><input id="filterSearch" placeholder="卡密/设备/备注" oninput="debounceLoadKeys()"></div>
      </div>
      <div class="panel" style="padding:0;overflow-x:auto;">
        <table>
          <thead><tr><th>ID</th><th>卡密</th><th>类型</th><th>应用</th><th>状态</th><th>设备</th><th>型号</th><th>iOS</th><th>时长/次数</th><th>解绑</th><th>激活时间</th><th>操作</th></tr></thead>
          <tbody id="keysBody"></tbody>
        </table>
      </div>
      <div class="pagination" id="keysPagination"></div>
    </div>

    <!-- 生成卡密 -->
    <div id="tab-generate" class="tab-content">
      <div class="panel">
        <h2>✨ 批量生成卡密</h2>
        <div class="form-row">
          <div class="form-group"><label>数量</label><input id="genCount" type="number" value="10" min="1" max="500"></div>
          <div class="form-group"><label>类型</label><select id="genType" onchange="updateGenUI()"><option value="vip">时长卡</option><option value="single">计次卡</option></select></div>
          <div class="form-group" id="genTimeUnitGroup"><label>时长</label><select id="genTimeUnit"><option value="longuse">永久</option><option value="hour">小时</option><option value="day">天</option><option value="week">周</option><option value="month">月</option><option value="season">季</option><option value="year">年</option></select></div>
          <div class="form-group"><label id="genAmountLabel">倍数</label><input id="genAmount" type="number" value="1" min="1"></div>
          <div class="form-group"><label>格式</label><select id="genMode" onchange="updateLengthHint()"><option value="alphanum">字母+数字</option><option value="digit">纯数字</option><option value="upper">纯字母</option></select></div>
          <div class="form-group"><label>长度</label><input id="genLength" type="number" value="16" min="4" max="64"></div>
          <div class="form-group"><label>应用</label><select id="genApp"><option value="trollstore">TrollStore</option><option value="default">Default</option></select></div>
          <div class="form-group"><label>前缀</label><input id="genPrefix" placeholder="TS" maxlength="8"></div>
          <div class="form-group"><label>有效天数</label><input id="genDays" type="number" placeholder="永久" min="1"></div>
          <div class="form-group"><label>可解绑</label><input id="genMaxUnbind" type="number" value="3" min="0" max="99"></div>
          <div class="form-group"><label>备注</label><input id="genNote" placeholder="批次备注"></div>
          <button class="btn btn-primary" onclick="generateKeys()">生成</button>
        </div>
        <div id="genResult"></div>
      </div>
    </div>

    <!-- 黑名单 -->
    <div id="tab-blacklist" class="tab-content">
      <div class="panel">
        <h2>🚫 黑名单</h2>
        <div class="form-row" style="margin-bottom:14px;">
          <div class="form-group"><label>类型</label><select id="blType"><option value="device">设备</option><option value="ip">IP</option></select></div>
          <div class="form-group"><label>值</label><input id="blValue" placeholder="设备序列号或 IP"></div>
          <div class="form-group"><label>原因</label><input id="blReason" placeholder="封禁原因"></div>
          <button class="btn btn-danger" onclick="addBlacklist()">添加</button>
        </div>
        <table>
          <thead><tr><th>ID</th><th>类型</th><th>值</th><th>原因</th><th>添加时间</th><th>操作</th></tr></thead>
          <tbody id="blBody"></tbody>
        </table>
      </div>
    </div>

    <!-- 应用配置 -->
    <div id="tab-apps" class="tab-content">
      <div class="panel">
        <h2>⚙️ 应用配置</h2>
        <div class="form-row" style="margin-bottom:14px;">
          <div class="form-group"><label>应用ID</label><input id="appAppId" placeholder="trollstore"></div>
          <div class="form-group"><label>名称</label><input id="appName" placeholder="TrollStore"></div>
          <div class="form-group"><label>模式</label><select id="appFree"><option value="0">付费</option><option value="1">免费</option></select></div>
          <div class="form-group"><label>最大解绑</label><input id="appMaxUnbind" type="number" value="3" min="0"></div>
          <div class="form-group"><label>解绑冷却(h)</label><input id="appUnbindCooldown" type="number" value="24"></div>
          <div class="form-group"><label>解绑扣时长(h)</label><input id="appDeductHours" type="number" value="0"></div>
          <div class="form-group"><label>计次扣减</label><input id="appSingleDeduct" type="number" value="1" min="1"></div>
          <div class="form-group"><label>IP校验</label><select id="appIpCheck"><option value="0">关</option><option value="1">开</option></select></div>
          <button class="btn btn-primary" onclick="saveApp()">保存</button>
        </div>
        <table>
          <thead><tr><th>应用ID</th><th>名称</th><th>模式</th><th>解绑</th><th>冷却</th><th>扣时</th><th>IP</th><th>操作</th></tr></thead>
          <tbody id="appsBody"></tbody>
        </table>
      </div>
    </div>

    <!-- 操作日志 -->
    <div id="tab-logs" class="tab-content">
      <div class="filters">
        <div class="form-group"><label>操作</label><select id="logAction" onchange="loadLogs()"><option value="">全部</option><option value="activate">激活</option><option value="verify">验证</option><option value="register">注册</option><option value="unbind">解绑</option><option value="generate">生成</option><option value="revoke">撤销</option><option value="blacklist">黑名单</option></select></div>
      </div>
      <div class="panel" style="padding:0;overflow-x:auto;">
        <table>
          <thead><tr><th>时间</th><th>操作</th><th>卡密</th><th>设备</th><th>IP</th><th>详情</th></tr></thead>
          <tbody id="logsBody"></tbody>
        </table>
      </div>
      <div class="pagination" id="logsPagination"></div>
    </div>

    <!-- VCam 独立卡密 -->
    <div id="tab-vcam" class="tab-content">
      <div class="stats" id="vcamStats"></div>
      <div class="panel">
        <h2>🎥 VCam 卡密管理</h2>
        <div class="form-row" style="margin-bottom:14px;">
          <div class="form-group"><label>数量</label><input id="vcamCount" type="number" value="1" min="1" max="100" style="width:80px;"></div>
          <button class="btn btn-primary" onclick="vcamGenerate()">⚡ 批量生成</button>
          <button class="btn" style="background:#22c55e;color:white" onclick="vcamAddOne()">+ 添加单张</button>
        </div>
        <div class="copy-area" id="vcamResult" style="display:none"></div>
        <table style="margin-top:14px;">
          <thead><tr><th>ID</th><th>卡密</th><th>状态</th><th>绑定</th><th>序列号</th><th>型号</th><th>激活时间</th><th>操作</th></tr></thead>
          <tbody id="vcamBody"></tbody>
        </table>
      </div>
    </div>
  </div>
</div>

<div class="toast" id="toast"></div>

<script>
let TOKEN = localStorage.getItem('kami_admin_token') || '';
let keysPage = 1, logsPage = 1;
let debounceTimer;

function toast(msg, error) {
  const el = document.getElementById('toast');
  el.textContent = msg;
  el.className = 'toast show' + (error ? ' error' : '');
  setTimeout(() => el.className = 'toast', 3000);
}

async function api(path, opts = {}) {
  const url = path.includes('?') ? path + '&token=' + TOKEN : path + '?token=' + TOKEN;
  const headers = { 'Authorization': 'Bearer ' + TOKEN };
  if (opts.method && opts.method !== 'GET') headers['Content-Type'] = 'application/json';
  try {
    const res = await fetch(url, { headers, ...opts });
    const data = await res.json();
    if (res.status === 401) { doLogout(); throw new Error('unauthorized'); }
    return data;
  } catch(e) { console.error('api error:', e); throw e; }
}

function doLogin() {
  console.log('doLogin called');
  TOKEN = document.getElementById('tokenInput').value.trim();
  if (!TOKEN) { toast('请输入Token', true); return; }
  console.log('TOKEN:', TOKEN);
  localStorage.setItem('kami_admin_token', TOKEN);
  checkAuth();
}

function doLogout() {
  TOKEN = '';
  localStorage.removeItem('kami_admin_token');
  document.getElementById('loginPage').style.display = 'flex';
  document.getElementById('appPage').style.display = 'none';
}

async function checkAuth() {
  try {
    const data = await api('/api/admin/stats');
    if (data.code === 1) {
      document.getElementById('loginPage').style.display = 'none';
      document.getElementById('appPage').style.display = 'block';
      loadDashboard(data.data);
    } else { doLogout(); }
  } catch { doLogout(); }
}

const tabNames = ['dashboard','keys','generate','blacklist','apps','logs','vcam'];
function showTab(name) {
  document.querySelectorAll('.tab-content').forEach(el => el.classList.remove('active'));
  document.getElementById('tab-' + name).classList.add('active');
  document.querySelectorAll('.nav a').forEach((el, i) => el.classList.toggle('active', tabNames[i] === name));
  if (name === 'keys') loadKeys();
  if (name === 'logs') loadLogs();
  if (name === 'dashboard') loadStats();
  if (name === 'blacklist') loadBlacklist();
  if (name === 'apps') loadApps();
  if (name === 'vcam') loadVcam();
  return false;
}

function loadDashboard(stats) {
  const grid = document.getElementById('statsGrid');
  const items = [
    { label: '总计', value: stats.total, cls: '' },
    { label: '未使用', value: stats.unused, cls: 'unused' },
    { label: '已使用', value: stats.used, cls: 'used' },
    { label: '已过期', value: stats.expired, cls: 'expired' },
    { label: '已撤销', value: stats.revoked, cls: 'revoked' },
  ];
  grid.innerHTML = items.map(i => '<div class="stat-card ' + i.cls + '"><div class="label">' + i.label + '</div><div class="value">' + i.value + '</div></div>').join('');
  const chart = document.getElementById('activationChart');
  const days = stats.recent_activations || [];
  const maxCnt = Math.max(1, ...days.map(d => d.cnt));
  chart.innerHTML = days.map(d => {
    const h = Math.max(4, (d.cnt / maxCnt) * 140);
    return '<div style="flex:1;display:flex;flex-direction:column;align-items:center;gap:3px;"><div style="width:100%;height:' + h + 'px;background:linear-gradient(to top,#3b82f6,#60a5fa);border-radius:3px 3px 0 0;" title="' + d.cnt + '"></div><span style="font-size:9px;color:#94a3b8;">' + d.day.slice(5) + '</span></div>';
  }).join('');
}

async function loadStats() {
  const data = await api('/api/admin/stats');
  if (data.code === 1) loadDashboard(data.data);
}

function statusLabel(s) { return { unused: '未使用', used: '已使用', expired: '已过期', revoked: '已撤销' }[s] || s; }
function typeLabel(t) { return { vip: '时长卡', single: '计次卡' }[t] || t || '时长卡'; }
function timeLabel(u) { return { hour:'小时',day:'天',week:'周',month:'月',season:'季',year:'年',longuse:'永久' }[u] || u || '永久'; }

async function loadKeys() {
  const status = document.getElementById('filterStatus').value;
  const type = document.getElementById('filterType').value;
  const app = document.getElementById('filterApp').value;
  const search = document.getElementById('filterSearch').value;
  let path = '/api/admin/keys?page=' + keysPage;
  if (status) path += '&status=' + status;
  if (type) path += '&type=' + type;
  if (app) path += '&app_id=' + app;
  if (search) path += '&search=' + encodeURIComponent(search);
  const data = await api(path);
  if (data.code !== 1) return;
  const tbody = document.getElementById('keysBody');
  tbody.innerHTML = data.data.keys.map(k => {
    let timeInfo = '';
    if (k.type === 'single') timeInfo = k.amount + '次';
    else timeInfo = (k.amount || 1) + timeLabel(k.time_unit);
    const unbindInfo = k.unbind_count + '/' + (k.max_unbind || 0);
    return '<tr>' +
      '<td>' + k.id + '</td>' +
      '<td class="key-code">' + k.code + '</td>' +
      '<td><span class="badge badge-' + (k.type || 'vip') + '">' + typeLabel(k.type) + '</span></td>' +
      '<td>' + k.app_id + '</td>' +
      '<td><span class="badge badge-' + k.status + '">' + statusLabel(k.status) + '</span></td>' +
      '<td style="font-size:10px;">' + (k.device_serial || '-') + '</td>' +
      '<td>' + (k.device_model || '-') + '</td>' +
      '<td>' + (k.ios_version || '-') + '</td>' +
      '<td>' + timeInfo + '</td>' +
      '<td>' + unbindInfo + '</td>' +
      '<td style="font-size:10px;">' + (k.activated_at || '-') + '</td>' +
      '<td>' +
        (k.status === 'unused' ? '<button class="btn btn-danger btn-sm" onclick="revokeKey(\\'' + k.code + '\\')">撤销</button>' : '') +
        ' <button class="btn btn-sm" style="background:#334155;color:#e2e8f0;" onclick="deleteKey(' + k.id + ')">删除</button>' +
      '</td></tr>';
  }).join('');
  renderPagination('keysPagination', data.data.page, data.data.pages, (p) => { keysPage = p; loadKeys(); });
}

function debounceLoadKeys() { clearTimeout(debounceTimer); debounceTimer = setTimeout(() => { keysPage = 1; loadKeys(); }, 400); }

function updateGenUI() {
  const t = document.getElementById('genType').value;
  document.getElementById('genTimeUnitGroup').style.display = t === 'vip' ? '' : 'none';
  document.getElementById('genAmountLabel').textContent = t === 'vip' ? '倍数' : '次数';
  document.getElementById('genAmount').value = t === 'single' ? '10' : '1';
}

function updateLengthHint() {
  const mode = document.getElementById('genMode').value;
  const el = document.getElementById('genLength');
  if (mode === 'digit' && el.value === '16') el.value = '8';
  if (mode !== 'digit' && el.value === '8') el.value = '16';
}

async function generateKeys() {
  const count = parseInt(document.getElementById('genCount').value) || 10;
  const type = document.getElementById('genType').value;
  const time_unit = document.getElementById('genTimeUnit').value;
  const amount = parseInt(document.getElementById('genAmount').value) || 1;
  const mode = document.getElementById('genMode').value;
  const length = parseInt(document.getElementById('genLength').value) || 16;
  const app_id = document.getElementById('genApp').value;
  const prefix = document.getElementById('genPrefix').value.trim();
  const expires_days = parseInt(document.getElementById('genDays').value) || undefined;
  const max_unbind = parseInt(document.getElementById('genMaxUnbind').value);
  const note = document.getElementById('genNote').value.trim();

  const data = await api('/api/admin/generate', {
    method: 'POST',
    body: JSON.stringify({ count, app_id, mode, length, type, time_unit, amount, prefix, expires_days, max_unbind, note }),
  });
  if (data.code === 1) {
    toast(data.msg);
    document.getElementById('genResult').innerHTML =
      '<p style="margin-top:10px;color:#94a3b8;">生成 ' + data.data.count + ' 个卡密：</p>' +
      '<div class="copy-area" id="genKeysList">' + data.data.keys.join('\\n') + '</div>' +
      '<button class="btn btn-primary" style="margin-top:8px;" onclick="copyGen()">复制全部</button>';
  } else { toast(data.msg, true); }
}

function copyGen() {
  navigator.clipboard.writeText(document.getElementById('genKeysList').textContent).then(() => toast('已复制'));
}

async function revokeKey(code) {
  if (!confirm('确定撤销 ' + code + '？')) return;
  const data = await api('/api/admin/revoke', { method: 'POST', body: JSON.stringify({ code }) });
  toast(data.msg, data.code !== 1); loadKeys();
}

async function deleteKey(id) {
  if (!confirm('确定删除？不可恢复。')) return;
  const data = await api('/api/admin/keys/' + id, { method: 'DELETE' });
  toast(data.msg, data.code !== 1); loadKeys();
}

async function loadBlacklist() {
  const data = await api('/api/admin/blacklist');
  if (data.code !== 1) return;
  document.getElementById('blBody').innerHTML = data.data.map(b =>
    '<tr><td>' + b.id + '</td><td>' + (b.type === 'device' ? '设备' : 'IP') + '</td><td class="key-code">' + b.value + '</td><td>' + (b.reason || '-') + '</td><td>' + b.created_at + '</td><td><button class="btn btn-danger btn-sm" onclick="delBlacklist(' + b.id + ')">删除</button></td></tr>'
  ).join('');
}

async function addBlacklist() {
  const type = document.getElementById('blType').value;
  const value = document.getElementById('blValue').value.trim();
  const reason = document.getElementById('blReason').value.trim();
  if (!value) { toast('请输入值', true); return; }
  const data = await api('/api/admin/blacklist', { method: 'POST', body: JSON.stringify({ type, value, reason }) });
  toast(data.msg, data.code !== 1);
  if (data.code === 1) { document.getElementById('blValue').value = ''; document.getElementById('blReason').value = ''; loadBlacklist(); }
}

async function delBlacklist(id) {
  if (!confirm('确定移除？')) return;
  const data = await api('/api/admin/blacklist/' + id, { method: 'DELETE' });
  toast(data.msg, data.code !== 1); loadBlacklist();
}

async function loadApps() {
  const data = await api('/api/admin/apps');
  if (data.code !== 1) return;
  document.getElementById('appsBody').innerHTML = data.data.map(a =>
    '<tr><td>' + a.app_id + '</td><td>' + (a.name || '-') + '</td><td>' + (a.is_free ? '免费' : '付费') + '</td><td>' + a.max_unbind + '次</td><td>' + a.unbind_cooldown + 'h</td><td>' + a.unbind_deduct_hours + 'h</td><td>' + (a.ip_check ? '开' : '关') + '</td><td><button class="btn btn-sm" style="background:#334155;color:#e2e8f0;" onclick=\\'editApp(' + JSON.stringify(a).replace(/'/g, "&#39;") + ')\\'>编辑</button></td></tr>'
  ).join('');
}

function editApp(a) {
  document.getElementById('appAppId').value = a.app_id;
  document.getElementById('appName').value = a.name || '';
  document.getElementById('appFree').value = a.is_free;
  document.getElementById('appMaxUnbind').value = a.max_unbind;
  document.getElementById('appUnbindCooldown').value = a.unbind_cooldown;
  document.getElementById('appDeductHours').value = a.unbind_deduct_hours;
  document.getElementById('appSingleDeduct').value = a.single_deduct;
  document.getElementById('appIpCheck').value = a.ip_check;
}

async function saveApp() {
  const body = {
    app_id: document.getElementById('appAppId').value.trim(),
    name: document.getElementById('appName').value.trim(),
    is_free: parseInt(document.getElementById('appFree').value),
    max_unbind: parseInt(document.getElementById('appMaxUnbind').value),
    unbind_cooldown: parseInt(document.getElementById('appUnbindCooldown').value),
    unbind_deduct_hours: parseInt(document.getElementById('appDeductHours').value),
    single_deduct: parseInt(document.getElementById('appSingleDeduct').value),
    ip_check: parseInt(document.getElementById('appIpCheck').value),
  };
  if (!body.app_id) { toast('请输入应用ID', true); return; }
  const data = await api('/api/admin/apps', { method: 'POST', body: JSON.stringify(body) });
  toast(data.msg, data.code !== 1);
  if (data.code === 1) loadApps();
}

async function loadLogs() {
  const action = document.getElementById('logAction').value;
  let path = '/api/admin/logs?page=' + logsPage;
  if (action) path += '&action=' + action;
  const data = await api(path);
  if (data.code !== 1) return;
  document.getElementById('logsBody').innerHTML = data.data.logs.map(l =>
    '<tr><td style="font-size:10px;">' + l.created_at + '</td><td><span class="badge badge-unused">' + l.action + '</span></td><td class="key-code">' + (l.key_code || '-') + '</td><td style="font-size:10px;">' + (l.device_serial || '-') + '</td><td style="font-size:10px;">' + (l.ip || '-') + '</td><td style="font-size:11px;">' + (l.detail || '-') + '</td></tr>'
  ).join('');
  renderPagination('logsPagination', data.data.page, Math.ceil(data.data.total / data.data.limit), (p) => { logsPage = p; loadLogs(); });
}

function renderPagination(containerId, current, total, onClick) {
  const el = document.getElementById(containerId);
  if (total <= 1) { el.innerHTML = ''; return; }
  let html = '<button ' + (current <= 1 ? 'disabled' : '') + ' onclick="(' + onClick + ')(' + (current - 1) + ')">上一页</button>';
  for (let i = 1; i <= total; i++) {
    if (i === current) html += '<button class="current">' + i + '</button>';
    else if (Math.abs(i - current) <= 2 || i === 1 || i === total) html += '<button onclick="(' + onClick + ')(' + i + ')">' + i + '</button>';
    else if (i === current - 3 || i === current + 3) html += '<button disabled>...</button>';
  }
  html += '<button ' + (current >= total ? 'disabled' : '') + ' onclick="(' + onClick + ')(' + (current + 1) + ')">下一页</button>';
  el.innerHTML = html;
}

if (TOKEN) checkAuth();

// ===== VCam =====
async function loadVcam() {
  const data = await api('/trollstore-device-api.php?api=vcam_admin_stats');
  if (data.code === 200) {
    document.getElementById('vcamStats').innerHTML = [
      { label: '总卡密', value: data.total, cls: '' },
      { label: '可用', value: data.active, cls: 'unused' },
      { label: '已激活', value: data.bound, cls: 'used' },
      { label: '已禁用', value: data.disabled, cls: 'revoked' },
    ].map(i => '<div class="stat-card ' + i.cls + '"><div class="label">' + i.label + '</div><div class="value">' + i.value + '</div></div>').join('');
  }
  const list = await api('/trollstore-device-api.php?api=vcam_admin_list');
  if (list.code === 200) {
    const rows = list.data || [];
    document.getElementById('vcamBody').innerHTML = rows.length === 0
      ? '<tr><td colspan="8" style="text-align:center;color:#94a3b8;padding:20px;">暂无卡密</td></tr>'
      : rows.map(r => {
        const bound = r.activated_at ? 'used' : 'unused';
        const statusClass = r.status === 'active' ? 'badge-unused' : 'badge-revoked';
        return '<tr><td>' + r.id + '</td><td class="key-code">' + (r.code||'') + '</td><td><span class="badge ' + statusClass + '">' + (r.status==='active'?'可用':'禁用') + '</span></td><td><span class="badge badge-' + (bound==='used'?'used':'expired') + '">' + (bound==='used'?'已激活':'未激活') + '</span></td><td style="font-size:10px;">' + (r.device_serial||'-') + '</td><td>' + (r.device_model||'-') + '</td><td style="font-size:10px;">' + (r.activated_at||'-') + '</td><td><button class="btn btn-sm btn-danger" onclick="vcamToggle(' + r.id + ')">' + (r.status==='active'?'禁用':'启用') + '</button> ' + (r.activated_at ? '<button class="btn btn-sm" style="background:#f59e0b;color:white" onclick="vcamUnbind(' + r.id + ')">解绑</button> ' : '') + '<button class="btn btn-sm" style="background:#64748b;color:white" onclick="vcamDelete(' + r.id + ')">删</button></td></tr>';
      }).join('');
  }
}

async function vcamGenerate() {
  const cnt = parseInt(document.getElementById('vcamCount').value) || 1;
  const data = await api('/trollstore-device-api.php?api=vcam_admin_add&count=' + cnt);
  if (data.code === 200 && data.kamis) {
    document.getElementById('vcamResult').style.display = 'block';
    document.getElementById('vcamResult').textContent = data.kamis.join('\n');
    toast('已生成 ' + data.kamis.length + ' 张卡密');
    loadVcam();
  } else { toast(data.msg || '生成失败', true); }
}

async function vcamAddOne() {
  const data = await api('/trollstore-device-api.php?api=vcam_admin_add&count=1');
  if (data.code === 200 && data.kamis) {
    document.getElementById('vcamResult').style.display = 'block';
    document.getElementById('vcamResult').textContent = data.kamis[0];
    toast('卡密已生成');
    loadVcam();
  }
}

async function vcamToggle(id) {
  const data = await api('/trollstore-device-api.php?api=vcam_admin_toggle&id=' + id);
  toast(data.msg);
  loadVcam();
}

async function vcamUnbind(id) {
  if (!confirm('确定解绑该卡密？')) return;
  const data = await api('/trollstore-device-api.php?api=vcam_admin_unbind&id=' + id);
  toast(data.msg);
  loadVcam();
}

async function vcamDelete(id) {
  if (!confirm('确定删除？不可恢复！')) return;
  const data = await api('/trollstore-device-api.php?api=vcam_admin_delete&id=' + id);
  toast(data.msg);
  loadVcam();
}
document.getElementById('tokenInput').addEventListener('keydown', e => { if (e.key === 'Enter') doLogin(); });
</script>
</body>
</html>`;
