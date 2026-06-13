<?php
/**
 * VCam API 代理 - 兼容原始 App API 格式
 * 
 * App 请求：https://xnsp.v200dd.eu.org/api.php?action=check&udid=XXX&ts=XXX&sign=XXX
 * 或：https://xnsp.v200dd.eu.org/api.php?action=use_kami&udid=XXX&kami=XXX&ts=XXX&sign=XXX
 * 
 * 成功响应：{"code":0,"msg":"ok","data":{"vip":时间戳,"status":"active"}}
 * 或者同行格式：{"code":0,"msg":"登录成功","data":{"card":"XXX","card_type":"day","expires_at":"2026/06/12 00:43:36","duration":"1天0小时"}}
 * 
 * 同时也兼容 POST /vc.php 卡密格式（从 v5 插件来的请求）
 */

header('Content-Type: application/json; charset=utf-8');
header('Access-Control-Allow-Origin: *');

$action = $_GET['action'] ?? '';
$udid = $_GET['udid'] ?? $_GET['device_id'] ?? '';
$kami = $_GET['kami'] ?? $_GET['card'] ?? '';
$ts = $_GET['ts'] ?? '';
$sign = $_GET['sign'] ?? '';

// POST JSON body 兼容
$rawInput = file_get_contents('php://input');
if ($rawInput) {
    $jsonInput = json_decode($rawInput, true);
    if ($jsonInput) {
        if (!empty($jsonInput['action'])) $action = $jsonInput['action'];
        if (!empty($jsonInput['udid']) && empty($udid)) $udid = $jsonInput['udid'];
        if (!empty($jsonInput['device_id']) && empty($udid)) $udid = $jsonInput['device_id'];
        if (!empty($jsonInput['kami']) && empty($kami)) $kami = $jsonInput['kami'];
        if (!empty($jsonInput['card']) && empty($kami)) $kami = $jsonInput['card'];
    }
}

// 日志
$logLine = date('Y-m-d H:i:s') . " action=$action udid=$udid kami=$kami ts=$ts sign=$sign\n";
@file_put_contents(__DIR__ . '/vcam_requests.log', $logLine, FILE_APPEND);

function sendVIPSuccess($kami = '', $days = 365) {
    $expiresTs = time() + $days * 24 * 3600;
    $expiresAt = date('Y/m/d H:i:s', $expiresTs);
    echo json_encode([
        'code' => 0,
        'msg' => 'ok',
        'data' => [
            'vip' => $expiresTs,
            'status' => 'active',
            'card' => $kami ?: 'VIP',
            'card_type' => 'day',
            'expires_at' => $expiresAt,
            'duration' => $days . '天0小时'
        ]
    ]);
    exit;
}

function sendFail($msg = '验证失败', $code = -1) {
    echo json_encode(['code' => $code, 'msg' => $msg]);
    exit;
}

function getKamiForDevice($udid) {
    $dbFile = __DIR__ . '/vcam_devices.json';
    if (!file_exists($dbFile)) return null;
    $data = json_decode(file_get_contents($dbFile), true);
    if (!$data) return null;
    foreach ($data as $entry) {
        if ($entry['udid'] === $udid) return $entry['kami'];
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

function verifyKami($kami, $udid) {
    $kmlogonUrl = "http://124.221.171.80/api.php?api=kmlogon&app=10003&kami=" . urlencode($kami) . "&markcode=" . urlencode($udid);
    $ctx = stream_context_create(['http' => ['timeout' => 10]]);
    $result = @file_get_contents($kmlogonUrl, false, $ctx);
    if ($result === false) return false;
    $json = json_decode($result, true);
    return ($json && isset($json['code']) && $json['code'] == 200);
}

// ===== check：已绑定设备直接返回成功 =====
if ($action === 'check') {
    $boundKami = getKamiForDevice($udid);
    if ($boundKami) {
        sendVIPSuccess($boundKami);
    } else {
        sendFail('请先输入卡密');
    }
}

// ===== use_kami / 有卡密：验证卡密 =====
if ($action === 'use_kami' || !empty($kami)) {
    // 已绑定同一卡密 → 直接成功
    $boundKami = getKamiForDevice($udid);
    if ($boundKami && $boundKami === $kami) {
        sendVIPSuccess($kami);
    }
    
    // 验证卡密
    if (empty($kami)) {
        sendFail('请输入卡密');
    }
    
    if (verifyKami($kami, $udid)) {
        registerDeviceKami($udid, $kami);
        sendVIPSuccess($kami);
    } else {
        sendFail('卡密无效');
    }
}

// ===== 无 action 无卡密：检查已绑定 =====
$boundKami = getKamiForDevice($udid);
if ($boundKami) {
    sendVIPSuccess($boundKami);
} else {
    sendFail('请先输入卡密');
}
