<?php
/**
 * VCam 卡密验证 API - 兼容 kami.lengye.top/api/login 格式
 * 
 * POST api/login
 * Body: {"appkey":"H0U66ETGBFEC","card":"卡密","device_id":"设备ID"}
 * 
 * 成功: {"code":0,"msg":"登录成功","data":{"card":"XXX","card_type":"day","expires_at":"2026/06/12 00:43:36","duration":"1天0小时"}}
 * 失败: {"code":-1,"msg":"卡密不存在"}
 */

header('Content-Type: application/json; charset=utf-8');
header('Access-Control-Allow-Origin: *');

// 支持 GET 和 POST
$action = $_GET['action'] ?? '';
$udid = $_GET['udid'] ?? '';
$kami = $_GET['kami'] ?? '';
$ts = $_GET['ts'] ?? '';
$sign = $_GET['sign'] ?? '';

// POST JSON body
$rawInput = file_get_contents('php://input');
if ($rawInput) {
    $jsonInput = json_decode($rawInput, true);
    if ($jsonInput) {
        if (isset($jsonInput['action'])) $action = $jsonInput['action'];
        if (isset($jsonInput['udid'])) $udid = $jsonInput['udid'];
        if (isset($jsonInput['kami'])) $kami = $jsonInput['kami'];
        if (isset($jsonInput['card']) && empty($kami)) $kami = $jsonInput['card'];
        if (isset($jsonInput['device_id']) && empty($udid)) $udid = $jsonInput['device_id'];
    }
}

function sendSuccess($card, $days = 365) {
    $expiresAt = date('Y/m/d H:i:s', time() + $days * 24 * 3600);
    $duration = $days . '天0小时';
    echo json_encode([
        'code' => 0,
        'msg' => '登录成功',
        'data' => [
            'card' => $card,
            'card_type' => 'day',
            'expires_at' => $expiresAt,
            'duration' => $duration
        ]
    ]);
    exit;
}

function sendFail($msg = '卡密无效') {
    echo json_encode([
        'code' => -1,
        'msg' => $msg
    ]);
    exit;
}

// check 请求
if ($action === 'check') {
    $boundKami = getKamiForDevice($udid);
    if ($boundKami) {
        sendSuccess($boundKami);
    } else {
        sendFail('请先输入卡密');
    }
}

// use_kami 请求
if ($action === 'use_kami') {
    if (empty($kami)) {
        sendFail('请输入卡密');
    }
    
    // 调用自有 kmlogon API 验证卡密
    $kmlogonUrl = "http://124.221.171.80/api.php?api=kmlogon&app=10003&kami=" . urlencode($kami) . "&markcode=" . urlencode($udid);
    $ctx = stream_context_create(['http' => ['timeout' => 10]]);
    $result = @file_get_contents($kmlogonUrl, false, $ctx);
    
    if ($result === false) {
        sendFail('验证服务器连接失败');
    }
    
    $json = json_decode($result, true);
    
    if ($json && isset($json['code']) && $json['code'] == 200) {
        registerDeviceKami($udid, $kami);
        sendSuccess($kami);
    } else {
        $errMsg = '卡密无效';
        if ($json && isset($json['msg']) && is_string($json['msg'])) {
            $errMsg = $json['msg'];
        }
        sendFail($errMsg);
    }
}

// 兼容 POST /api/login 格式（同行插件格式）
if ($_SERVER['REQUEST_METHOD'] === 'POST' && empty($action)) {
    $card = $kami;
    $device_id = $udid;
    
    if (empty($card)) {
        sendFail('请输入卡密');
    }
    
    $kmlogonUrl = "http://124.221.171.80/api.php?api=kmlogon&app=10003&kami=" . urlencode($card) . "&markcode=" . urlencode($device_id);
    $ctx = stream_context_create(['http' => ['timeout' => 10]]);
    $result = @file_get_contents($kmlogonUrl, false, $ctx);
    
    if ($result === false) {
        sendFail('验证服务器连接失败');
    }
    
    $json = json_decode($result, true);
    
    if ($json && isset($json['code']) && $json['code'] == 200) {
        registerDeviceKami($device_id, $card);
        sendSuccess($card);
    } else {
        $errMsg = '卡密不存在';
        if ($json && isset($json['msg']) && is_string($json['msg'])) {
            $errMsg = $json['msg'];
        }
        sendFail($errMsg);
    }
}

sendFail('unknown action');


// ===== 辅助函数 =====

function getKamiForDevice($udid) {
    $dbFile = __DIR__ . '/vcam_devices.json';
    if (!file_exists($dbFile)) return null;
    $data = json_decode(file_get_contents($dbFile), true);
    if (!$data) return null;
    foreach ($data as $entry) {
        if ($entry['udid'] === $udid) {
            return $entry['kami'];
        }
    }
    return null;
}

function registerDeviceKami($udid, $kami) {
    $dbFile = __DIR__ . '/vcam_devices.json';
    $data = [];
    if (file_exists($dbFile)) {
        $data = json_decode(file_get_contents($dbFile), true) ?: [];
    }
    $found = false;
    foreach ($data as &$entry) {
        if ($entry['udid'] === $udid) {
            $entry['kami'] = $kami;
            $entry['time'] = time();
            $found = true;
            break;
        }
    }
    unset($entry);
    if (!$found) {
        $data[] = ['udid' => $udid, 'kami' => $kami, 'time' => time()];
    }
    file_put_contents($dbFile, json_encode($data, JSON_PRETTY_PRINT));
}
