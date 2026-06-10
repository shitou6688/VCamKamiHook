<?php
/**
 * VCam 卡密验证 API - 兼容原始 api.php 格式
 * 
 * 接口格式（与原始 yz.xnsp.v200dd.eu.org 一致）：
 * GET api.php?action=check&udid=XXX&ts=XXX&sign=XXX
 * GET api.php?action=use_kami&udid=XXX&ts=XXX&sign=XXX&kami=XXX
 * 
 * 成功响应：{"code":0,"msg":"ok","data":{"vip":<timestamp>}}
 * 失败响应：{"code":-1,"msg":"错误信息"}
 */

header('Content-Type: application/json; charset=utf-8');
header('Access-Control-Allow-Origin: *');

$action = $_GET['action'] ?? '';

if ($action === 'check') {
    // check 请求：检查设备是否已激活
    $udid = $_GET['udid'] ?? '';
    
    // 查询本地数据库看这个设备是否已激活
    $kami = getKamiForDevice($udid);
    if ($kami) {
        echo json_encode([
            'code' => 0,
            'msg' => 'ok',
            'data' => [
                'vip' => 4102243200,
                'kami' => $kami
            ]
        ]);
    } else {
        // 未激活也返回成功（避免 App 弹窗），但 vip 为 0
        echo json_encode([
            'code' => 0,
            'msg' => 'ok',
            'data' => [
                'vip' => 0
            ]
        ]);
    }
    exit;
}

if ($action === 'use_kami') {
    $kami = $_GET['kami'] ?? '';
    $udid = $_GET['udid'] ?? '';
    
    if (empty($kami)) {
        echo json_encode(['code' => -1, 'msg' => '请输入卡密']);
        exit;
    }
    
    // 调用自有 kmlogon API 验证卡密
    $kmlogonUrl = "http://124.221.171.80/api.php?api=kmlogon&app=10003&kami=" . urlencode($kami) . "&markcode=" . urlencode($udid);
    $ctx = stream_context_create(['http' => ['timeout' => 10]]);
    $result = @file_get_contents($kmlogonUrl, false, $ctx);
    
    if ($result === false) {
        echo json_encode(['code' => -1, 'msg' => '验证服务器连接失败']);
        exit;
    }
    
    $json = json_decode($result, true);
    
    if ($json && isset($json['code']) && $json['code'] == 200) {
        // 卡密验证成功
        $vipTs = isset($json['msg']['vip']) ? intval($json['msg']['vip']) : 4102243200;
        
        // 记录设备绑定
        registerDeviceKami($udid, $kami);
        
        echo json_encode([
            'code' => 0,
            'msg' => 'ok',
            'data' => [
                'vip' => $vipTs,
                'kami' => $kami
            ]
        ]);
    } else {
        $errMsg = '卡密无效';
        if ($json && isset($json['msg'])) {
            if (is_string($json['msg'])) {
                $errMsg = $json['msg'];
            }
        }
        echo json_encode(['code' => -1, 'msg' => $errMsg]);
    }
    exit;
}

// 未知 action
echo json_encode(['code' => -1, 'msg' => 'unknown action']);


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
    // 更新或添加
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
