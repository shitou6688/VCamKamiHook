<?php
header('Content-Type: application/json; charset=utf-8');
$DB_HOST = 'localhost';
$DB_USER = '124_221_171_80';
$DB_PASS = '124_221_171_80';
$DB_NAME = '124_221_171_80';
$ADMIN_KEY = 'jumo000666';

$mysqli = new mysqli($DB_HOST, $DB_USER, $DB_PASS, $DB_NAME);
$mysqli->set_charset('utf8mb4');

// Auto-create pending table
$mysqli->query("CREATE TABLE IF NOT EXISTS trollstore_pending_kami (
    id INT AUTO_INCREMENT PRIMARY KEY,
    kami VARCHAR(255) NOT NULL,
    device_model VARCHAR(100) DEFAULT '',
    markcode VARCHAR(255) DEFAULT '',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_model_time (device_model, created_at),
    INDEX idx_markcode (markcode)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4");

if (isset($_GET['api'])) {
    $api = $mysqli->real_escape_string($_GET['api']);
    switch ($api) {
        case 'ts_verify': ts_verify($mysqli); break;
        case 'ts_register': ts_register($mysqli); break;
        case 'ts_check': ts_check($mysqli); break;
        case 'ts_admin_list': ts_admin_list($mysqli); break;
        case 'ts_admin_ban': ts_admin_ban($mysqli); break;
        case 'ts_admin_unban': ts_admin_unban($mysqli); break;
        case 'ts_admin_delete': ts_admin_delete($mysqli); break;
        case 'ts_admin_edit': ts_admin_edit($mysqli); break;
        case 'ts_config': ts_config($mysqli); break;
        case 'ts_admin_config': ts_admin_config($mysqli); break;
        default: echo json_encode(['code' => 400]); break;
    }
}

// ========== Remote Config ==========

function ts_config($mysqli) {
    // auto create config table
    $mysqli->query("CREATE TABLE IF NOT EXISTS trollstore_config (
        config_key VARCHAR(100) PRIMARY KEY,
        config_value VARCHAR(255) NOT NULL DEFAULT '',
        updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4");

    $res = $mysqli->query("SELECT config_key, config_value FROM trollstore_config");
    $config = [];
    if ($res) {
        while ($row = $res->fetch_assoc()) {
            $config[$row['config_key']] = $row['config_value'];
        }
    }

    echo json_encode([
        'allow_1587' => ($config['allow_1587'] ?? '0') === '1',
        'code' => 200
    ]);
}

// ========== 独立验证（绕过yixi的markcode绑定检查）==========

function ts_verify($mysqli) {
    $serial = isset($_GET['serial']) ? $mysqli->real_escape_string($_GET['serial']) : '';
    $udid = isset($_GET['udid']) ? $mysqli->real_escape_string($_GET['udid']) : '';
    $markcode = isset($_GET['markcode']) ? $mysqli->real_escape_string($_GET['markcode']) : '';
    $kami = isset($_GET['kami']) ? $mysqli->real_escape_string($_GET['kami']) : '';

    if (empty($kami)) {
        echo json_encode(['code' => 400, 'msg' => 'Missing kami']);
        return;
    }

    // 1. 按序列号查：这台设备有没有被这个卡密授权过
    $found = false;
    $device_id = 0;

    if (!empty($serial) && $serial !== 'unknown') {
        $s = $mysqli->real_escape_string($serial);
        $res = $mysqli->query("SELECT id FROM trollstore_devices WHERE serial = '$s' AND kami = '$kami' AND status = 'active' LIMIT 1");
        if ($res && $res->num_rows > 0) {
            $found = true;
            $device_id = $res->fetch_assoc()['id'];
        }
    }

    // 2. 按 UDID 查
    if (!$found && !empty($udid) && $udid !== 'unknown') {
        $u = $mysqli->real_escape_string($udid);
        $res = $mysqli->query("SELECT id FROM trollstore_devices WHERE udid = '$u' AND kami = '$kami' AND status = 'active' LIMIT 1");
        if ($res && $res->num_rows > 0) {
            $found = true;
            $device_id = $res->fetch_assoc()['id'];
        }
    }

    // 3. 按 markcode 兜底（兼容旧数据里没有 serial/udid 的情况）
    if (!$found && !empty($markcode)) {
        $mc = $mysqli->real_escape_string($markcode);
        $res = $mysqli->query("SELECT id FROM trollstore_devices WHERE kami = '$kami' AND markcode = '$mc' AND status = 'active' LIMIT 1");
        if ($res && $res->num_rows > 0) {
            $found = true;
            $device_id = $res->fetch_assoc()['id'];
        }
    }

    if ($found) {
        // 设备已授权，更新活跃时间和 markcode
        $mc = $mysqli->real_escape_string($markcode);
        $mysqli->query("UPDATE trollstore_devices SET last_active = NOW(), markcode = '$mc' WHERE id = $device_id");
        echo json_encode(['code' => 200, 'msg' => ['vip' => '4102243200']]);
        return;
    }

    // 未找到 → 需要首次激活（客户端会走 kmlogon + ts_register）
    echo json_encode(['code' => 301, 'msg' => '需要首次激活']);
}

function ts_admin_config($mysqli) {
    global $ADMIN_KEY;
    if (!isset($_GET['key']) || $_GET['key'] !== $ADMIN_KEY) {
        echo json_encode(['code' => 403]);
        return;
    }

    $mysqli->query("CREATE TABLE IF NOT EXISTS trollstore_config (
        config_key VARCHAR(100) PRIMARY KEY,
        config_value VARCHAR(255) NOT NULL DEFAULT '',
        updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4");

    $key = isset($_GET['config_key']) ? $mysqli->real_escape_string($_GET['config_key']) : '';
    $value = isset($_GET['config_value']) ? $mysqli->real_escape_string($_GET['config_value']) : '';

    if (empty($key)) {
        echo json_encode(['code' => 400, 'msg' => 'Missing config_key']);
        return;
    }

    $mysqli->query("INSERT INTO trollstore_config (config_key, config_value) VALUES ('$key', '$value') ON DUPLICATE KEY UPDATE config_value = '$value', updated_at = NOW()");

    echo json_encode(['code' => 200, 'msg' => 'Config updated', 'config_key' => $key, 'config_value' => $value]);
}

$mysqli->close();

// ========== Helper ==========

function lookup_kami_by_markcode($mysqli, $markcode) {
    if (empty($markcode)) return '';
    $md5 = md5($markcode);
    $res = $mysqli->query("SELECT kami FROM yixi_appkm WHERE user = '$md5' AND km_use = 'y' ORDER BY id DESC LIMIT 1");
    if ($res && $res->num_rows > 0) return $res->fetch_assoc()['kami'];
    $res2 = $mysqli->query("SELECT kami FROM yixi_appkm WHERE user = '" . $mysqli->real_escape_string($markcode) . "' AND km_use = 'y' ORDER BY id DESC LIMIT 1");
    if ($res2 && $res2->num_rows > 0) return $res2->fetch_assoc()['kami'];
    return '';
}

function get_ban_status($mysqli, $serial, $markcode = '') {
    if (!empty($serial) && $serial !== '-') {
        $s = $mysqli->real_escape_string($serial);
        $res = $mysqli->query("SELECT status, ban_action, ban_reason FROM trollstore_devices WHERE serial = '$s' AND status = 'banned' LIMIT 1");
        if ($res && $res->num_rows > 0) return $res->fetch_assoc();
    }
    if (!empty($markcode)) {
        $mc = $mysqli->real_escape_string($markcode);
        $res = $mysqli->query("SELECT status, ban_action, ban_reason FROM trollstore_devices WHERE markcode = '$mc' AND status = 'banned' LIMIT 1");
        if ($res && $res->num_rows > 0) return $res->fetch_assoc();
    }
    return null;
}

function respond($mysqli, $serial, $markcode = '') {
    $ban = get_ban_status($mysqli, $serial, $markcode);
    if ($ban) {
        echo json_encode(['status' => $ban['status'], 'ban_action' => $ban['ban_action'] ?: 'none', 'ban_reason' => $ban['ban_reason'] ?: '']);
    } else {
        echo json_encode(['status' => 'active', 'ban_action' => 'none']);
    }
}

// Check if serial/markcode is banned, and if so, ban ALL records for this device
// Returns ban info array or null
function check_and_propagate_ban($mysqli, $serial, $markcode = '') {
    $ban = get_ban_status($mysqli, $serial, $markcode);
    if ($ban) {
        $action = $mysqli->real_escape_string($ban['ban_action'] ?: 'disable');
        $reason = $mysqli->real_escape_string($ban['ban_reason'] ?: '');
        if (!empty($serial) && $serial !== '-') {
            $s = $mysqli->real_escape_string($serial);
            $mysqli->query("UPDATE trollstore_devices SET status = 'banned', ban_action = '$action', ban_reason = '$reason' WHERE serial = '$s'");
        }
        if (!empty($markcode)) {
            $mc = $mysqli->real_escape_string($markcode);
            $mysqli->query("UPDATE trollstore_devices SET status = 'banned', ban_action = '$action', ban_reason = '$reason' WHERE markcode = '$mc'");
        }
    }
    return $ban;
}


function log_kami_usage($mysqli, $device_id, $kami, $markcode) {
    if (empty($kami) || empty($device_id)) return;
    $safe_kami = $mysqli->real_escape_string($kami);
    $safe_mark = $mysqli->real_escape_string($markcode);
    $check = $mysqli->query("SELECT id FROM trollstore_kami_log WHERE device_id = $device_id AND kami = '$safe_kami'");
    if ($check && $check->num_rows == 0) {
        $mysqli->query("INSERT INTO trollstore_kami_log (device_id, kami, markcode, activated_at) VALUES ($device_id, '$safe_kami', '$safe_mark', NOW())");
    }
}


// Check if kami belongs to a banned agent - return true if banned
function is_kami_agent_banned($mysqli, $kami) {
    if (empty($kami)) return false;
    $k = $mysqli->real_escape_string($kami);
    $res = $mysqli->query("SELECT upid FROM yixi_appkm WHERE kami = '$k' LIMIT 1");
    if (!$res || $res->num_rows == 0) return false;
    $upid = intval($res->fetch_assoc()['upid']);
    if ($upid < 9999000) return false;
    $agent_uid = $upid - 9999000;
    $agent_res = $mysqli->query("SELECT status FROM yixi_agent WHERE uid = $agent_uid LIMIT 1");
    if (!$agent_res || $agent_res->num_rows == 0) return false;
    return intval($agent_res->fetch_assoc()['status']) === 0;
}

// When a device registers with a kami, update yixi_appkm to mark it as activated
function mark_kami_activated($mysqli, $kami, $markcode) {
    if (empty($kami)) return;
    $k = $mysqli->real_escape_string($kami);
    $mc = !empty($markcode) ? $mysqli->real_escape_string($markcode) : '';
    $now = time();
    $userVal = !empty($mc) ? $mc : '';
    $mysqli->query("UPDATE yixi_appkm SET km_use = 'y', use_time = $now, user = IF(user IS NULL OR user = '', '$userVal', user) WHERE kami = '$k' AND (km_use = 'n' OR km_use = '' OR km_use IS NULL) LIMIT 1");
}

// When TrollStore opens, pick up any pending kamis from TrollInstallerX
function claim_pending_kamis($mysqli, $serial, $model, $udid, $ios, $ts_version, $markcode) {
    // 优先按 markcode 匹配，没有 markcode 才按 model 匹配
    if (empty($markcode) && (empty($serial) || empty($model))) return;
    $s = $mysqli->real_escape_string($serial);
    $m = $mysqli->real_escape_string($model);
    $mc = $mysqli->real_escape_string($markcode);

    // 优先按 markcode 精准匹配，没有 markcode 才按 device_model 匹配
    if (!empty($markcode)) {
        $res = $mysqli->query("SELECT * FROM trollstore_pending_kami WHERE markcode = '$mc' AND created_at > DATE_SUB(NOW(), INTERVAL 30 MINUTE) ORDER BY created_at ASC");
    } else {
        $res = $mysqli->query("SELECT * FROM trollstore_pending_kami WHERE device_model = '$m' AND created_at > DATE_SUB(NOW(), INTERVAL 30 MINUTE) ORDER BY created_at ASC");
    }
    if (!$res) return;

    while ($pending = $res->fetch_assoc()) {
        $pk = $mysqli->real_escape_string($pending['kami']);

        // Check if agent is banned
        if (is_kami_agent_banned($mysqli, $pk)) {
            $mysqli->query("DELETE FROM trollstore_pending_kami WHERE id = " . $pending['id']);
            continue;
        }

        // Check if this serial already has a record with this kami (dedup)
        $check = $mysqli->query("SELECT id FROM trollstore_devices WHERE serial = '$s' AND kami = '$pk'");
        if ($check && $check->num_rows > 0) {
            // Already exists, just delete pending
            $mysqli->query("DELETE FROM trollstore_pending_kami WHERE id = " . $pending['id']);
            continue;
        }

        // One-kami-one-device: skip if this kami is already used by a different device
        $used_check = $mysqli->query("SELECT id, markcode FROM trollstore_devices WHERE kami = '$pk' AND kami != '' AND kami IS NOT NULL LIMIT 1");
        if ($used_check && $used_check->num_rows > 0) {
            $used_row = $used_check->fetch_assoc();
            // Allow if same markcode (same device re-registering)
            if (!empty($markcode) && !empty($used_row['markcode']) && $used_row['markcode'] === $markcode) {
                // Same device, allow - delete pending
                $mysqli->query("DELETE FROM trollstore_pending_kami WHERE id = " . $pending['id']);
                continue;
            }
            // Different device already using this kami, skip and delete pending
            $mysqli->query("DELETE FROM trollstore_pending_kami WHERE id = " . $pending['id']);
            continue;
        }

        // NEW kami for this serial - INSERT (keep history!)
        // Inherit ts_version/ios/udid from existing records for this serial if current request has empty values
        $inherit_ts = $ts_version;
        $inherit_ios = $ios;
        $inherit_udid = $udid;
        if (empty($inherit_ts) || $inherit_ts === '') {
            $t = $mysqli->query("SELECT ts_version, ios_version, udid FROM trollstore_devices WHERE serial = '$s' AND ts_version != '' AND ts_version IS NOT NULL ORDER BY last_active DESC LIMIT 1");
            if ($t && $t->num_rows > 0) {
                $r = $t->fetch_assoc();
                if (!empty($r['ts_version'])) $inherit_ts = $r['ts_version'];
                if (empty($inherit_ios) && !empty($r['ios_version'])) $inherit_ios = $r['ios_version'];
                if (empty($inherit_udid) && !empty($r['udid'])) $inherit_udid = $r['udid'];
            }
        }
        // Check if this device is already banned
        $ban_status = check_and_propagate_ban($mysqli, $serial, $markcode);
        $new_status = $ban_status ? 'banned' : 'active';
        $ban_action_val = $ban_status ? ("'" . $mysqli->real_escape_string($ban_status['ban_action'] ?: 'disable') . "'") : "''";
        $ban_reason_val = $ban_status ? ("'" . $mysqli->real_escape_string($ban_status['ban_reason'] ?: '') . "'") : "''";
        $mysqli->query("INSERT INTO trollstore_devices (serial, udid, device_model, ios_version, ts_version, kami, markcode, status, ban_action, ban_reason, created_at, last_active) VALUES ('$s', '" . $mysqli->real_escape_string($inherit_udid) . "', '$m', '" . $mysqli->real_escape_string($inherit_ios) . "', '" . $mysqli->real_escape_string($inherit_ts) . "', '$pk', '" . $mysqli->real_escape_string($markcode) . "', '$new_status', $ban_action_val, $ban_reason_val, NOW(), NOW())");
        $new_id = $mysqli->insert_id;
        log_kami_usage($mysqli, $new_id, $pk, $markcode);
        mark_kami_activated($mysqli, $pk, $markcode);

        // Delete pending (consumed)
        $mysqli->query("DELETE FROM trollstore_pending_kami WHERE id = " . $pending['id']);
    }
}

// ========== Registration ==========

function ts_register($mysqli) {
    $serial = isset($_GET['serial']) ? $mysqli->real_escape_string($_GET['serial']) : '';
    $udid = isset($_GET['udid']) ? $mysqli->real_escape_string($_GET['udid']) : '';
    $model = isset($_GET['model']) ? $mysqli->real_escape_string($_GET['model']) : '';
    $ios = isset($_GET['ios']) ? $mysqli->real_escape_string($_GET['ios']) : '';
    $ts_version = isset($_GET['ts_version']) ? $mysqli->real_escape_string($_GET['ts_version']) : '';
    $kami = isset($_GET['kami']) ? $_GET['kami'] : '';
    // 截取 | 前面的部分，防止旧版客户端传入 "kami|markcode" 整体
    if (strpos($kami, '|') !== false) $kami = explode('|', $kami)[0];
    $kami = $mysqli->real_escape_string($kami);
    $markcode = isset($_GET['markcode']) ? $mysqli->real_escape_string($_GET['markcode']) : '';

    // No info at all
    if (empty($serial) && empty($udid) && empty($model)) {
        respond($mysqli, '');
        return;
    }
    if (empty($kami)) $kami = lookup_kami_by_markcode($mysqli, $markcode);
    // Treat "unknown" as empty
    if ($ts_version === 'unknown') $ts_version = '';
    if ($serial === 'unknown') $serial = '';
    if ($udid === 'unknown') $udid = '';

    // ===== CASE A: TrollInstallerX (no serial, has kami) =====
    // Store as pending AND write to trollstore_devices for admin panel
    if (empty($serial) && !empty($kami)) {
        // Check if agent is banned
        if (is_kami_agent_banned($mysqli, $kami)) {
            echo json_encode(['status' => 'error', 'msg' => 'agent_banned']);
            return;
        }
        $k = $mysqli->real_escape_string($kami);
        $m = $mysqli->real_escape_string($model);
        $mc = $mysqli->real_escape_string($markcode);
        // Store pending for TrollStore to claim
        $check = $mysqli->query("SELECT id FROM trollstore_pending_kami WHERE kami = '$k' AND markcode = '$mc' AND created_at > DATE_SUB(NOW(), INTERVAL 30 MINUTE)");
        if (!$check || $check->num_rows == 0) {
            $mysqli->query("INSERT INTO trollstore_pending_kami (kami, device_model, markcode) VALUES ('$k', '$m', '$mc')");
        }
        // Also write to trollstore_devices so admin panel shows it
        if (!empty($markcode)) {
            $dev_check = $mysqli->query("SELECT id, status FROM trollstore_devices WHERE markcode = '$mc' AND kami = '$k' LIMIT 1");
            if ($dev_check && $dev_check->num_rows > 0) {
                $row = $dev_check->fetch_assoc();
                $set = ["last_active = NOW()"];
                if (!empty($model)) $set[] = "device_model = '$m'";
                if (!empty($ios)) $set[] = "ios_version = '" . $mysqli->real_escape_string($ios) . "'";
                $mysqli->query("UPDATE trollstore_devices SET " . implode(', ', $set) . " WHERE id = " . $row['id']);
            } else {
                // One-kami-one-device: check if this kami is already used by another device
                $kami_used = $mysqli->query("SELECT id, markcode FROM trollstore_devices WHERE kami = '$k' AND kami != '' AND kami IS NOT NULL LIMIT 1");
                if ($kami_used && $kami_used->num_rows > 0) {
                    $used_row = $kami_used->fetch_assoc();
                    // Allow only if same markcode
                    if (empty($markcode) || empty($used_row['markcode']) || $used_row['markcode'] !== $markcode) {
                        // Different device already using this kami, skip
                        respond($mysqli, '', $markcode);
                        return;
                    }
                }
                // Check if this markcode is already banned
                $ban_status = check_and_propagate_ban($mysqli, '', $markcode);
                $new_status = $ban_status ? 'banned' : 'active';
                $ban_action_val = $ban_status ? ("'" . $mysqli->real_escape_string($ban_status['ban_action'] ?: 'disable') . "'") : "''";
                $ban_reason_val = $ban_status ? ("'" . $mysqli->real_escape_string($ban_status['ban_reason'] ?: '') . "'") : "''";
                $mysqli->query("INSERT INTO trollstore_devices (serial, udid, device_model, ios_version, ts_version, kami, markcode, status, ban_action, ban_reason, created_at, last_active) VALUES ('', '', '$m', '" . $mysqli->real_escape_string($ios) . "', '" . $mysqli->real_escape_string($ts_version) . "', '$k', '$mc', '$new_status', $ban_action_val, $ban_reason_val, NOW(), NOW())");
                $new_id = $mysqli->insert_id;
                log_kami_usage($mysqli, $new_id, $kami, $markcode);
                mark_kami_activated($mysqli, $kami, $markcode);
            }
        }
        respond($mysqli, '', $markcode);
        return;
    }

    // ===== CASE B: TrollStore with serial + kami (from file) =====
    if (!empty($serial) && !empty($kami)) {
        // Check if agent is banned
        if (is_kami_agent_banned($mysqli, $kami)) {
            echo json_encode(['status' => 'error', 'msg' => 'agent_banned']);
            return;
        }
        $s = $mysqli->real_escape_string($serial);
        $k = $mysqli->real_escape_string($kami);
        $mc = $mysqli->real_escape_string($markcode);
        $found = false;

        // 1) 优先按 markcode+kami 匹配（TrollInstallerX 写的记录 serial 为空，但 markcode 有值）
        if (!empty($markcode)) {
            $res = $mysqli->query("SELECT * FROM trollstore_devices WHERE markcode = '$mc' AND kami = '$k' LIMIT 1");
            if ($res && $res->num_rows > 0) {
                $row = $res->fetch_assoc();
                $set = ["last_active = NOW()"];
                // 补上 serial 和 udid（TrollInstallerX 写的记录 serial/udid 为空）
                if (!empty($serial)) $set[] = "serial = '$s'";
                if (!empty($udid)) $set[] = "udid = '" . $mysqli->real_escape_string($udid) . "'";
                if (!empty($model)) $set[] = "device_model = '$model'";
                if (!empty($ios)) $set[] = "ios_version = '$ios'";
                if (!empty($ts_version)) $set[] = "ts_version = '$ts_version'";
                $mysqli->query("UPDATE trollstore_devices SET " . implode(', ', $set) . " WHERE id = " . $row['id']);
                log_kami_usage($mysqli, $row['id'], $kami, $markcode);
                $found = true;
            }
        }

        // 2) 按 serial+kami 匹配（已有完整记录）
        if (!$found) {
            $res = $mysqli->query("SELECT * FROM trollstore_devices WHERE serial = '$s' AND kami = '$k' LIMIT 1");
            if ($res && $res->num_rows > 0) {
                $row = $res->fetch_assoc();
                $set = ["last_active = NOW()"];
                if (!empty($udid) && empty($row['udid'])) $set[] = "udid = '" . $mysqli->real_escape_string($udid) . "'";
                if (!empty($model) && empty($row['device_model'])) $set[] = "device_model = '$model'";
                if (!empty($ios) && empty($row['ios_version'])) $set[] = "ios_version = '$ios'";
                if (!empty($ts_version) && empty($row['ts_version'])) $set[] = "ts_version = '$ts_version'";
                if (!empty($markcode) && empty($row['markcode'])) $set[] = "markcode = '$mc'";
                $mysqli->query("UPDATE trollstore_devices SET " . implode(', ', $set) . " WHERE id = " . $row['id']);
                log_kami_usage($mysqli, $row['id'], $kami, $markcode);
                $found = true;
            }
        }

        // 3) 按 kami 匹配 TrollInstallerX 的无 serial 记录（kami 文件被读到但 markcode 不匹配）
        if (!$found && !empty($kami)) {
            $res = $mysqli->query("SELECT * FROM trollstore_devices WHERE kami = '$k' AND (serial = '' OR serial IS NULL) LIMIT 1");
            if ($res && $res->num_rows > 0) {
                $row = $res->fetch_assoc();
                $set = ["last_active = NOW()"];
                if (!empty($serial)) $set[] = "serial = '$s'";
                if (!empty($udid)) $set[] = "udid = '" . $mysqli->real_escape_string($udid) . "'";
                if (!empty($model)) $set[] = "device_model = '$model'";
                if (!empty($ios)) $set[] = "ios_version = '$ios'";
                if (!empty($ts_version)) $set[] = "ts_version = '$ts_version'";
                $mysqli->query("UPDATE trollstore_devices SET " . implode(', ', $set) . " WHERE id = " . $row['id']);
                log_kami_usage($mysqli, $row['id'], $kami, $row['markcode']);
                $found = true;
            }
        }

        // 4) 都没找到 → 插入新记录
        if (!$found) {
            // Check if this device is already banned (new kami on banned device)
            // One-kami-one-device: check if this kami is already used by another device
            $kami_used = $mysqli->query("SELECT id, markcode, serial AS dev_serial FROM trollstore_devices WHERE kami = '$k' AND kami != '' AND kami IS NOT NULL LIMIT 1");
            if ($kami_used && $kami_used->num_rows > 0) {
                $used_row = $kami_used->fetch_assoc();
                $same_device = false;
                if (!empty($markcode) && !empty($used_row['markcode']) && $used_row['markcode'] === $markcode) $same_device = true;
                if (!empty($serial) && !empty($used_row['dev_serial']) && $used_row['dev_serial'] === $serial) $same_device = true;
                if (!$same_device) {
                    respond($mysqli, $serial, $markcode);
                    return;
                }
            }
            $ban_status = check_and_propagate_ban($mysqli, $serial, $markcode);
            $new_status = $ban_status ? 'banned' : 'active';
            $ban_action_val = $ban_status ? ("'" . $mysqli->real_escape_string($ban_status['ban_action'] ?: 'disable') . "'") : "''";
            $ban_reason_val = $ban_status ? ("'" . $mysqli->real_escape_string($ban_status['ban_reason'] ?: '') . "'") : "''";
            $mysqli->query("INSERT INTO trollstore_devices (serial, udid, device_model, ios_version, ts_version, kami, markcode, status, ban_action, ban_reason, created_at, last_active) VALUES ('$serial', '$udid', '$model', '$ios', '$ts_version', '$kami', '$markcode', '$new_status', $ban_action_val, $ban_reason_val, NOW(), NOW())");
            $new_id = $mysqli->insert_id;
            log_kami_usage($mysqli, $new_id, $kami, $markcode);
            mark_kami_activated($mysqli, $kami, $markcode);
        }

        // Mark kami as activated in yixi_appkm
        mark_kami_activated($mysqli, $kami, $markcode);
        // Also check for pending kamis (in case file was stale)
        claim_pending_kamis($mysqli, $serial, $model, $udid, $ios, $ts_version, $markcode);
        // Update last_active for ALL records with same serial (one device may have multiple kami records)
        if (!empty($serial)) { $s_all = $mysqli->real_escape_string($serial); $mysqli->query("UPDATE trollstore_devices SET last_active = NOW() WHERE serial = '$s_all'"); }
        // Also update last_active for records with same markcode that have empty serial
        if (!empty($markcode)) { $mc_all = $mysqli->real_escape_string($markcode); $mysqli->query("UPDATE trollstore_devices SET last_active = NOW() WHERE markcode = '$mc_all' AND (serial = '' OR serial IS NULL)"); }
        respond($mysqli, $serial, $markcode);
        return;
    }

    // ===== CASE C: TrollStore with serial but no kami =====
    if (!empty($serial)) {
        $s = $mysqli->real_escape_string($serial);
        // 先按 serial 匹配更新 last_active
        $mysqli->query("UPDATE trollstore_devices SET last_active = NOW() WHERE serial = '$s'");
        // Also update last_active for records with same markcode that have empty serial
        if (!empty($markcode)) { $mc_all = $mysqli->real_escape_string($markcode); $mysqli->query("UPDATE trollstore_devices SET last_active = NOW() WHERE markcode = '$mc_all' AND (serial = '' OR serial IS NULL)"); }

        // 尝试按 markcode 匹配空 serial 的记录，补上 serial/udid
        if (!empty($markcode)) {
            $mc = $mysqli->real_escape_string($markcode);
            $res = $mysqli->query("SELECT id, serial, udid, kami FROM trollstore_devices WHERE markcode = '$mc' AND (serial = '' OR serial IS NULL) LIMIT 1");
            if ($res && $res->num_rows > 0) {
                $row = $res->fetch_assoc();
                $set = ["serial = '$s'", "last_active = NOW()"];
                if (!empty($udid)) $set[] = "udid = '" . $mysqli->real_escape_string($udid) . "'";
                if (!empty($model)) $set[] = "device_model = '$model'";
                if (!empty($ios)) $set[] = "ios_version = '$ios'";
                if (!empty($ts_version)) $set[] = "ts_version = '$ts_version'";
                $mysqli->query("UPDATE trollstore_devices SET " . implode(', ', $set) . " WHERE id = " . $row['id']);
                log_kami_usage($mysqli, $row['id'], $row['kami'], $markcode);
                claim_pending_kamis($mysqli, $serial, $model, $udid, $ios, $ts_version, $markcode);
                respond($mysqli, $serial, $markcode);
                return;
            }
        }

        // 新增：按 model+时间窗口 匹配 TrollInstallerX 创建的无 serial 记录
        // 场景：TrollInstallerX 激活卡密创建了无 serial 记录，kami 文件写入失败，
        // TrollStore 打开后读不到 kami 文件，只能用 serial+model 来匹配
        if (!empty($model)) {
            $m = $mysqli->real_escape_string($model);
            // 找最近 2 小时内创建的无 serial 同 model 记录（TrollInstallerX 创建的）
            $res = $mysqli->query("SELECT id, serial, udid, kami, markcode FROM trollstore_devices WHERE device_model = '$m' AND (serial = '' OR serial IS NULL) AND kami != '' AND kami IS NOT NULL AND created_at > DATE_SUB(NOW(), INTERVAL 2 HOUR) ORDER BY created_at DESC LIMIT 1");
            if ($res && $res->num_rows > 0) {
                $row = $res->fetch_assoc();
                $set = ["serial = '$s'", "last_active = NOW()"];
                if (!empty($udid)) $set[] = "udid = '" . $mysqli->real_escape_string($udid) . "'";
                if (!empty($model)) $set[] = "device_model = '$model'";
                if (!empty($ios)) $set[] = "ios_version = '$ios'";
                if (!empty($ts_version)) $set[] = "ts_version = '$ts_version'";
                $mysqli->query("UPDATE trollstore_devices SET " . implode(', ', $set) . " WHERE id = " . $row['id']);
                log_kami_usage($mysqli, $row['id'], $row['kami'], $row['markcode']);
                claim_pending_kamis($mysqli, $serial, $model, $udid, $ios, $ts_version, $row['markcode']);
                respond($mysqli, $serial, $row['markcode']);
                return;
            }
        }

        // Check for pending kamis (file might not exist)
        claim_pending_kamis($mysqli, $serial, $model, $udid, $ios, $ts_version, $markcode);
        respond($mysqli, $serial, $markcode);
        return;
    }

    // Fallback
    respond($mysqli, '');
}

function ts_check($mysqli) {
    $serial = isset($_GET['serial']) ? $mysqli->real_escape_string($_GET['serial']) : '';
    $udid = isset($_GET['udid']) ? $mysqli->real_escape_string($_GET['udid']) : '';
    $model = isset($_GET['model']) ? $mysqli->real_escape_string($_GET['model']) : '';
    $ios = isset($_GET['ios']) ? $mysqli->real_escape_string($_GET['ios']) : '';
    $ts_version = isset($_GET['ts_version']) ? $mysqli->real_escape_string($_GET['ts_version']) : '';
    $kami = isset($_GET['kami']) ? $_GET['kami'] : '';
    // 截取 | 前面的部分，防止旧版客户端传入 "kami|markcode" 整体
    if (strpos($kami, '|') !== false) $kami = explode('|', $kami)[0];
    $kami = $mysqli->real_escape_string($kami);
    $markcode = isset($_GET['markcode']) ? $mysqli->real_escape_string($_GET['markcode']) : '';

    if (empty($serial) && empty($udid) && empty($model)) {
        respond($mysqli, '');
        return;
    }
    if (empty($kami)) $kami = lookup_kami_by_markcode($mysqli, $markcode);
    // Treat "unknown" as empty
    if ($ts_version === 'unknown') $ts_version = '';
    if ($serial === 'unknown') $serial = '';
    if ($udid === 'unknown') $udid = '';

    // Handle same 3 cases as ts_register
    if (!empty($serial) && !empty($kami)) {
        // Check if agent is banned
        if (is_kami_agent_banned($mysqli, $kami)) {
            echo json_encode(['status' => 'error', 'msg' => 'agent_banned']);
            return;
        }
        $s = $mysqli->real_escape_string($serial);
        $k = $mysqli->real_escape_string($kami);
        $mc = $mysqli->real_escape_string($markcode);
        $found = false;
        // 1) 按 markcode+kami 匹配
        if (!empty($markcode)) {
            $res = $mysqli->query("SELECT * FROM trollstore_devices WHERE markcode = '$mc' AND kami = '$k' LIMIT 1");
            if ($res && $res->num_rows > 0) {
                $row = $res->fetch_assoc();
                $set = ["last_active = NOW()"];
                if (!empty($serial)) $set[] = "serial = '$s'";
                if (!empty($udid)) $set[] = "udid = '" . $mysqli->real_escape_string($udid) . "'";
                if (!empty($model)) $set[] = "device_model = '$model'";
                if (!empty($ios)) $set[] = "ios_version = '$ios'";
                if (!empty($ts_version)) $set[] = "ts_version = '$ts_version'";
                $mysqli->query("UPDATE trollstore_devices SET " . implode(', ', $set) . " WHERE id = " . $row['id']);
                log_kami_usage($mysqli, $row['id'], $kami, $markcode);
                $found = true;
            }
        }
        // 2) 按 serial+kami 匹配
        if (!$found) {
            $res = $mysqli->query("SELECT * FROM trollstore_devices WHERE serial = '$s' AND kami = '$k' LIMIT 1");
            if ($res && $res->num_rows > 0) {
                $row = $res->fetch_assoc();
                $set = ["last_active = NOW()"];
                if (!empty($udid) && empty($row['udid'])) $set[] = "udid = '" . $mysqli->real_escape_string($udid) . "'";
                if (!empty($model) && empty($row['device_model'])) $set[] = "device_model = '$model'";
                if (!empty($ios) && empty($row['ios_version'])) $set[] = "ios_version = '$ios'";
                if (!empty($ts_version) && empty($row['ts_version'])) $set[] = "ts_version = '$ts_version'";
                $mysqli->query("UPDATE trollstore_devices SET " . implode(', ', $set) . " WHERE id = " . $row['id']);
                log_kami_usage($mysqli, $row['id'], $kami, $markcode);
                $found = true;
            }
        }
        // 3) 按 kami 匹配 TrollInstallerX 的无 serial 记录
        if (!$found && !empty($kami)) {
            $res = $mysqli->query("SELECT * FROM trollstore_devices WHERE kami = '$k' AND (serial = '' OR serial IS NULL) LIMIT 1");
            if ($res && $res->num_rows > 0) {
                $row = $res->fetch_assoc();
                $set = ["last_active = NOW()"];
                if (!empty($serial)) $set[] = "serial = '$s'";
                if (!empty($udid)) $set[] = "udid = '" . $mysqli->real_escape_string($udid) . "'";
                if (!empty($model)) $set[] = "device_model = '$model'";
                if (!empty($ios)) $set[] = "ios_version = '$ios'";
                if (!empty($ts_version)) $set[] = "ts_version = '$ts_version'";
                $mysqli->query("UPDATE trollstore_devices SET " . implode(', ', $set) . " WHERE id = " . $row['id']);
                log_kami_usage($mysqli, $row['id'], $kami, $row['markcode']);
                $found = true;
            }
        }
        if (!$found) {
            // One-kami-one-device: check if this kami is already used by another device
            $kami_used = $mysqli->query("SELECT id, markcode, serial AS dev_serial FROM trollstore_devices WHERE kami = '$k' AND kami != '' AND kami IS NOT NULL LIMIT 1");
            if ($kami_used && $kami_used->num_rows > 0) {
                $used_row = $kami_used->fetch_assoc();
                $same_device = false;
                if (!empty($markcode) && !empty($used_row['markcode']) && $used_row['markcode'] === $markcode) $same_device = true;
                if (!empty($serial) && !empty($used_row['dev_serial']) && $used_row['dev_serial'] === $serial) $same_device = true;
                if (!$same_device) {
                    respond($mysqli, $serial, $markcode);
                    return;
                }
            }
            // Check if this device is already banned (new kami on banned device)
            $ban_status = check_and_propagate_ban($mysqli, $serial, $markcode);
            $new_status = $ban_status ? 'banned' : 'active';
            $ban_action_val = $ban_status ? ("'" . $mysqli->real_escape_string($ban_status['ban_action'] ?: 'disable') . "'") : "''";
            $ban_reason_val = $ban_status ? ("'" . $mysqli->real_escape_string($ban_status['ban_reason'] ?: '') . "'") : "''";
            $mysqli->query("INSERT INTO trollstore_devices (serial, udid, device_model, ios_version, ts_version, kami, markcode, status, ban_action, ban_reason, created_at, last_active) VALUES ('$serial', '$udid', '$model', '$ios', '$ts_version', '$kami', '$markcode', '$new_status', $ban_action_val, $ban_reason_val, NOW(), NOW())");
            $new_id = $mysqli->insert_id;
            log_kami_usage($mysqli, $new_id, $kami, $markcode);
        }
        // Update last_active for ALL records with same serial (one device may have multiple kami records)
        if (!empty($serial)) { $s_all = $mysqli->real_escape_string($serial); $mysqli->query("UPDATE trollstore_devices SET last_active = NOW() WHERE serial = '$s_all'"); }
        // Also update last_active for records with same markcode that have empty serial
        if (!empty($markcode)) { $mc_all = $mysqli->real_escape_string($markcode); $mysqli->query("UPDATE trollstore_devices SET last_active = NOW() WHERE markcode = '$mc_all' AND (serial = '' OR serial IS NULL)"); }
        claim_pending_kamis($mysqli, $serial, $model, $udid, $ios, $ts_version, $markcode);
    } elseif (!empty($serial)) {
        $s = $mysqli->real_escape_string($serial);
        $mysqli->query("UPDATE trollstore_devices SET last_active = NOW() WHERE serial = '$s'");
        // Also update last_active for records with same markcode that have empty serial
        if (!empty($markcode)) { $mc_all = $mysqli->real_escape_string($markcode); $mysqli->query("UPDATE trollstore_devices SET last_active = NOW() WHERE markcode = '$mc_all' AND (serial = '' OR serial IS NULL)"); }
        // 尝试按 markcode 匹配空 serial 的记录，补上 serial/udid
        $matched = false;
        if (!empty($markcode)) {
            $mc = $mysqli->real_escape_string($markcode);
            $res = $mysqli->query("SELECT id, serial, udid, kami FROM trollstore_devices WHERE markcode = '$mc' AND (serial = '' OR serial IS NULL) LIMIT 1");
            if ($res && $res->num_rows > 0) {
                $row = $res->fetch_assoc();
                $set2 = ["serial = '$s'", "last_active = NOW()"];
                if (!empty($udid)) $set2[] = "udid = '" . $mysqli->real_escape_string($udid) . "'";
                if (!empty($model)) $set2[] = "device_model = '$model'";
                if (!empty($ios)) $set2[] = "ios_version = '$ios'";
                if (!empty($ts_version)) $set2[] = "ts_version = '$ts_version'";
                $mysqli->query("UPDATE trollstore_devices SET " . implode(', ', $set2) . " WHERE id = " . $row['id']);
                log_kami_usage($mysqli, $row['id'], $row['kami'], $markcode);
                $matched = true;
            }
        }
        // 按 model+时间窗口匹配 TrollInstallerX 无 serial 记录
        if (!$matched && !empty($model)) {
            $m = $mysqli->real_escape_string($model);
            $res = $mysqli->query("SELECT id, serial, udid, kami, markcode FROM trollstore_devices WHERE device_model = '$m' AND (serial = '' OR serial IS NULL) AND kami != '' AND kami IS NOT NULL AND created_at > DATE_SUB(NOW(), INTERVAL 2 HOUR) ORDER BY created_at DESC LIMIT 1");
            if ($res && $res->num_rows > 0) {
                $row = $res->fetch_assoc();
                $set2 = ["serial = '$s'", "last_active = NOW()"];
                if (!empty($udid)) $set2[] = "udid = '" . $mysqli->real_escape_string($udid) . "'";
                if (!empty($model)) $set2[] = "device_model = '$model'";
                if (!empty($ios)) $set2[] = "ios_version = '$ios'";
                if (!empty($ts_version)) $set2[] = "ts_version = '$ts_version'";
                $mysqli->query("UPDATE trollstore_devices SET " . implode(', ', $set2) . " WHERE id = " . $row['id']);
                log_kami_usage($mysqli, $row['id'], $row['kami'], $row['markcode']);
                $matched = true;
            }
        }
        claim_pending_kamis($mysqli, $serial, $model, $udid, $ios, $ts_version, $markcode);
    }

    respond($mysqli, $serial, $markcode);
}

// ========== Admin ==========

function ts_admin_list($mysqli) {
    global $ADMIN_KEY;
    if (!isset($_GET['key']) || $_GET['key'] !== $ADMIN_KEY) { echo json_encode(['code' => 403]); return; }
    $search = isset($_GET['search']) ? $mysqli->real_escape_string($_GET['search']) : '';
    $statusFilter = isset($_GET['status']) ? $_GET['status'] : '';
    $page = max(1, intval($_GET['page'] ?? 1));
    $limit = max(1, min(200, intval($_GET['limit'] ?? 50)));
    $offset = ($page - 1) * $limit;

    $where = '';
    $conditions = [];
    // Only show records that have serial (TrollStore has opened and uploaded serial/udid)
    $conditions[] = "(serial != '' AND serial IS NOT NULL)";
    if (!empty($search)) {
        $conditions[] = "(serial LIKE '%$search%' OR udid LIKE '%$search%' OR kami LIKE '%$search%' OR device_model LIKE '%$search%' OR remark LIKE '%$search%' OR markcode LIKE '%$search%' OR ios_version LIKE '%$search%')";
    }
    if ($statusFilter === 'active' || $statusFilter === 'banned') {
        $sf = $mysqli->real_escape_string($statusFilter);
        $conditions[] = "status = '$sf'";
    }
    if (!empty($conditions)) {
        $where = " WHERE " . implode(' AND ', $conditions);
    }

    // Get total count + active/banned stats
    $stats = $mysqli->query("SELECT COUNT(*) as total, SUM(status='active') as active_count, SUM(status='banned') as banned_count FROM trollstore_devices$where")->fetch_assoc();
    $total = intval($stats['total']);

    // Get paginated data
    $sql = "SELECT * FROM trollstore_devices$where ORDER BY created_at DESC LIMIT $limit OFFSET $offset";
    $res = $mysqli->query($sql);
    $data = [];
    if ($res) { while ($row = $res->fetch_assoc()) $data[] = $row; }

    echo json_encode([
        'code' => 200,
        'data' => $data,
        'total' => $total,
        'active' => intval($stats['active_count']),
        'banned' => intval($stats['banned_count']),
        'page' => $page,
        'limit' => $limit
    ]);
}

function ts_admin_ban($mysqli) {
    global $ADMIN_KEY;
    if (!isset($_GET['key']) || $_GET['key'] !== $ADMIN_KEY) { echo json_encode(['code' => 403]); return; }
    $id = intval($_GET['id'] ?? 0);
    $action = $mysqli->real_escape_string($_GET['action'] ?? 'disable');
    $reason = $mysqli->real_escape_string($_GET['reason'] ?? '');
    if ($id <= 0) { echo json_encode(['code' => 400]); return; }
    $dev = $mysqli->query("SELECT serial, markcode, device_model FROM trollstore_devices WHERE id = $id")->fetch_assoc();
    if ($dev) {
        if (!empty($dev['serial']) && $dev['serial'] !== '-') {
            $s = $mysqli->real_escape_string($dev['serial']);
            $mysqli->query("UPDATE trollstore_devices SET status = 'banned', ban_action = '$action', ban_reason = '$reason' WHERE serial = '$s'");
            // Also ban records with same markcode that have empty serial (TrollInstallerX created)
            if (!empty($dev['markcode'])) {
                $mc = $mysqli->real_escape_string($dev['markcode']);
                $mysqli->query("UPDATE trollstore_devices SET status = 'banned', ban_action = '$action', ban_reason = '$reason' WHERE markcode = '$mc' AND (serial = '' OR serial IS NULL)");
            }
        } elseif (!empty($dev['markcode'])) {
            $mc = $mysqli->real_escape_string($dev['markcode']);
            $mysqli->query("UPDATE trollstore_devices SET status = 'banned', ban_action = '$action', ban_reason = '$reason' WHERE markcode = '$mc'");
        } else {
            $m = $mysqli->real_escape_string($dev['device_model']);
            $mysqli->query("UPDATE trollstore_devices SET status = 'banned', ban_action = '$action', ban_reason = '$reason' WHERE device_model = '$m'");
        }
    }
    echo json_encode(['code' => 200, 'msg' => 'Banned']);
}

function ts_admin_unban($mysqli) {
    global $ADMIN_KEY;
    if (!isset($_GET['key']) || $_GET['key'] !== $ADMIN_KEY) { echo json_encode(['code' => 403]); return; }
    $id = intval($_GET['id'] ?? 0);
    if ($id <= 0) { echo json_encode(['code' => 400]); return; }
    $dev = $mysqli->query("SELECT serial, markcode, device_model FROM trollstore_devices WHERE id = $id")->fetch_assoc();
    if ($dev) {
        if (!empty($dev['serial']) && $dev['serial'] !== '-') {
            $s = $mysqli->real_escape_string($dev['serial']);
            $mysqli->query("UPDATE trollstore_devices SET status = 'active', ban_action = '', ban_reason = '' WHERE serial = '$s'");
            // Also unban records with same markcode that have empty serial
            if (!empty($dev['markcode'])) {
                $mc = $mysqli->real_escape_string($dev['markcode']);
                $mysqli->query("UPDATE trollstore_devices SET status = 'active', ban_action = '', ban_reason = '' WHERE markcode = '$mc' AND (serial = '' OR serial IS NULL)");
            }
        } elseif (!empty($dev['markcode'])) {
            $mc = $mysqli->real_escape_string($dev['markcode']);
            $mysqli->query("UPDATE trollstore_devices SET status = 'active', ban_action = '', ban_reason = '' WHERE markcode = '$mc'");
        } else {
            $m = $mysqli->real_escape_string($dev['device_model']);
            $mysqli->query("UPDATE trollstore_devices SET status = 'active', ban_action = '', ban_reason = '' WHERE device_model = '$m'");
        }
    }
    echo json_encode(['code' => 200, 'msg' => 'Unbanned']);
}

function ts_admin_delete($mysqli) {
    global $ADMIN_KEY;
    if (!isset($_GET['key']) || $_GET['key'] !== $ADMIN_KEY) { echo json_encode(['code' => 403]); return; }
    $id = intval($_GET['id'] ?? 0);
    if ($id <= 0) { echo json_encode(['code' => 400]); return; }
    $mysqli->query("DELETE FROM trollstore_kami_log WHERE device_id = $id");
    $mysqli->query("DELETE FROM trollstore_devices WHERE id = $id");
    echo json_encode(['code' => 200, 'msg' => 'Deleted']);
}

function ts_admin_edit($mysqli) {
    global $ADMIN_KEY;
    if (!isset($_GET['key']) || $_GET['key'] !== $ADMIN_KEY) { echo json_encode(['code' => 403]); return; }
    $id = intval($_GET['id'] ?? 0);
    $remark = $mysqli->real_escape_string($_GET['remark'] ?? '');
    $kami = $mysqli->real_escape_string($_GET['kami'] ?? '');
    if ($id <= 0) { echo json_encode(['code' => 400]); return; }
    $set = [];
    if ($remark !== '') $set[] = "remark = '$remark'";
    if ($kami !== '') $set[] = "kami = '$kami'";
    if (count($set) > 0) $mysqli->query("UPDATE trollstore_devices SET " . implode(', ', $set) . " WHERE id = $id");
    echo json_encode(['code' => 200, 'msg' => 'Updated']);
}
