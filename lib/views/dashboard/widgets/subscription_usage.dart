import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';

// 订阅用量配置文件名称，放在 FLClash 应用支持目录中，避免把账号密码硬编码进源码。
const _subscriptionUsageConfigFileName = 'subscription_usage.json';

// 八戒面板 API 默认地址，配置文件可以按需覆盖为同类 V2Board 面板地址。
const _defaultSubscriptionApiBaseUrl = 'https://bajie.pw/api/v1';

// 默认刷新间隔，卡片按这个周期轮询订阅接口来接近实时显示套餐用量。
const _defaultSubscriptionRefreshInterval = Duration(seconds: 60);

// 订阅用量接口配置，负责保存接口地址、登录凭据、鉴权数据和刷新策略。
class _SubscriptionUsageConfig {
  // 面板 API 根地址，例如 https://bajie.pw/api/v1。
  final String apiBaseUrl;

  // 登录邮箱；当 authData 不可用时用于重新登录。
  final String? email;

  // 登录密码；仅从本地配置读取，不在代码中硬编码。
  final String? password;

  // 已登录后的鉴权数据；可以单独配置以避免保存密码。
  final String? authData;

  // 接口轮询间隔，单位为秒。
  final int refreshIntervalSeconds;

  const _SubscriptionUsageConfig({
    required this.apiBaseUrl,
    required this.email,
    required this.password,
    required this.authData,
    required this.refreshIntervalSeconds,
  });

  // 判断是否具备账号密码登录能力，用于 authData 过期后的自动恢复。
  bool get hasLoginCredential =>
      email?.isNotEmpty == true && password?.isNotEmpty == true;

  // 将刷新秒数转换为 Duration，并限制最小值，避免过于频繁请求接口。
  Duration get refreshInterval {
    final seconds = max(10, refreshIntervalSeconds);
    return Duration(seconds: seconds);
  }

  // 从 JSON 映射中读取配置，字段缺省时使用稳妥默认值。
  factory _SubscriptionUsageConfig.fromJson(Map<String, dynamic> json) {
    final apiBaseUrl = _readString(json, 'apiBaseUrl');
    final refreshIntervalSeconds = _readInt(
      json,
      'refreshIntervalSeconds',
      _defaultSubscriptionRefreshInterval.inSeconds,
    );

    return _SubscriptionUsageConfig(
      apiBaseUrl: _normalizeApiBaseUrl(
        apiBaseUrl ?? _defaultSubscriptionApiBaseUrl,
      ),
      email: _readString(json, 'email'),
      password: _readString(json, 'password'),
      authData: _readString(json, 'authData'),
      refreshIntervalSeconds: refreshIntervalSeconds,
    );
  }

  // 读取字符串字段，并把空白字符串视为未配置。
  static String? _readString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String) {
      return null;
    }
    final text = value.trim();
    return text.isEmpty ? null : text;
  }

  // 读取整数字段，兼容 JSON 数字和字符串两种写法。
  static int _readInt(
    Map<String, dynamic> json,
    String key,
    int defaultValue,
  ) {
    final value = json[key];
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value) ?? defaultValue;
    }
    return defaultValue;
  }

  // 统一移除末尾斜杠，避免拼接接口路径时出现重复斜杠。
  static String _normalizeApiBaseUrl(String value) {
    return value.replaceFirst(RegExp(r'/+$'), '');
  }
}

// 订阅用量数据模型，保存界面展示所需的核心套餐字段。
class _SubscriptionUsageData {
  // 当前订阅套餐名称。
  final String planName;

  // 已使用流量字节数，等于接口中的上传 u 加下载 d。
  final int usedBytes;

  // 套餐总流量字节数，对应接口 transfer_enable。
  final int totalBytes;

  // 套餐到期时间，本地时区展示。
  final DateTime expiredAt;

  // 距离重置的剩余天数。
  final int resetDay;

  const _SubscriptionUsageData({
    required this.planName,
    required this.usedBytes,
    required this.totalBytes,
    required this.expiredAt,
    required this.resetDay,
  });

  // 已用比例，限制在 0 到 1 之间以保证进度条展示稳定。
  double get usedPercent {
    if (totalBytes <= 0) {
      return 0;
    }
    return (usedBytes / totalBytes).clamp(0, 1).toDouble();
  }

  // 从接口响应 data 字段转换成界面数据模型。
  factory _SubscriptionUsageData.fromJson(Map<String, dynamic> json) {
    final uploadBytes = _readInt(json, 'u');
    final downloadBytes = _readInt(json, 'd');
    final totalBytes = _readInt(json, 'transfer_enable');
    final expiredAtSeconds = _readInt(json, 'expired_at');
    final plan = json['plan'];

    // 套餐名称来自嵌套 plan 字段，缺失时使用兜底文案保证界面可显示。
    final String planName;
    if (plan is Map) {
      final planMap = Map<String, dynamic>.from(plan);
      planName = planMap['name']?.toString() ?? '订阅套餐';
    } else {
      planName = '订阅套餐';
    }

    return _SubscriptionUsageData(
      planName: planName,
      usedBytes: uploadBytes + downloadBytes,
      totalBytes: totalBytes,
      expiredAt: DateTime.fromMillisecondsSinceEpoch(
        expiredAtSeconds * 1000,
      ).toLocal(),
      resetDay: _readInt(json, 'reset_day'),
    );
  }

  // 读取接口中的整数字段，兼容数字和字符串返回值。
  static int _readInt(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value) ?? 0;
    }
    return 0;
  }
}

// 仪表盘订阅用量卡片，负责定时拉取并展示当前套餐剩余情况。
class SubscriptionUsage extends StatefulWidget {
  const SubscriptionUsage({super.key});

  @override
  State<SubscriptionUsage> createState() => _SubscriptionUsageState();
}

// 订阅用量卡片状态，维护配置、鉴权、定时器和最近一次接口数据。
class _SubscriptionUsageState extends State<SubscriptionUsage> {
  // 周期刷新定时器，按配置间隔触发接口请求。
  Timer? _refreshTimer;

  // 当前读取到的本地配置。
  _SubscriptionUsageConfig? _config;

  // 最近一次成功获取的套餐用量数据。
  _SubscriptionUsageData? _usageData;

  // 当前可用的接口鉴权数据。
  String? _authData;

  // 最近一次刷新失败时展示给用户的短错误。
  String? _errorMessage;

  // 加载状态，用于显示刷新按钮旁的小型进度提示。
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadConfigAndRefresh();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  // 读取本地配置后立即刷新一次，并启动定时刷新任务。
  Future<void> _loadConfigAndRefresh() async {
    _SubscriptionUsageConfig? config;
    String? configErrorMessage;
    try {
      config = await _loadConfig();
    } catch (e) {
      configErrorMessage = _formatErrorMessage(e);
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _config = config;
      _authData = config?.authData;
      _errorMessage =
          configErrorMessage ?? (config == null ? '未配置订阅用量' : null);
    });
    _startRefreshTimer(config);
    if (config != null) {
      await _refreshUsage();
    }
  }

  // 启动轮询定时器；配置缺失时不轮询，避免无意义唤醒。
  void _startRefreshTimer(_SubscriptionUsageConfig? config) {
    _refreshTimer?.cancel();
    if (config == null) {
      return;
    }
    _refreshTimer = Timer.periodic(config.refreshInterval, (_) {
      _refreshUsage();
    });
  }

  // 从应用支持目录读取 JSON 配置文件。
  Future<_SubscriptionUsageConfig?> _loadConfig() async {
    final homeDirPath = await appPath.homeDirPath;
    final configFile = File('$homeDirPath/$_subscriptionUsageConfigFileName');
    if (!await configFile.exists()) {
      return null;
    }
    final content = await configFile.readAsString();
    final jsonData = jsonDecode(content);
    if (jsonData is! Map) {
      throw const FormatException('订阅用量配置格式错误');
    }
    return _SubscriptionUsageConfig.fromJson(
      Map<String, dynamic>.from(jsonData),
    );
  }

  // 手动刷新入口，同时重新加载配置，便于用户修改配置文件后立即生效。
  Future<void> _handleManualRefresh() async {
    await _loadConfigAndRefresh();
  }

  // 刷新套餐用量；鉴权失效时优先尝试用账号密码重新登录。
  Future<void> _refreshUsage() async {
    final config = _config;
    if (config == null || _isLoading) {
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final authData = await _ensureAuthData(config);
      _authData = authData;
      final usageData = await _requestSubscriptionUsage(config, authData);
      if (!mounted) {
        return;
      }
      setState(() {
        _usageData = usageData;
        _errorMessage = null;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = _formatErrorMessage(e);
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  // 确保请求订阅接口前有可用 authData。
  Future<String> _ensureAuthData(_SubscriptionUsageConfig config) async {
    final authData = _authData;
    if (authData?.isNotEmpty == true) {
      return authData!;
    }
    if (!config.hasLoginCredential) {
      throw Exception('缺少鉴权配置');
    }
    return _login(config);
  }

  // 调用登录接口获取 authData。
  Future<String> _login(_SubscriptionUsageConfig config) async {
    final response = await request.dio
        .post<Map<String, dynamic>>(
          '${config.apiBaseUrl}/passport/auth/login',
          data: {
            'email': config.email,
            'password': config.password,
          },
          options: Options(
            responseType: ResponseType.json,
            headers: const {
              'Accept': 'application/json, text/plain, */*',
              'Content-Type': 'application/json',
            },
          ),
        )
        .timeout(httpTimeoutDuration);
    final responseData = response.data;
    final data = responseData?['data'];
    if (data is Map) {
      final authData = Map<String, dynamic>.from(data)['auth_data']?.toString();
      if (authData?.isNotEmpty == true) {
        return authData!;
      }
    }
    throw Exception('登录失败');
  }

  // 调用订阅接口获取当前套餐用量。
  Future<_SubscriptionUsageData> _requestSubscriptionUsage(
    _SubscriptionUsageConfig config,
    String authData, {
    bool retryWithLogin = true,
  }) async {
    final response = await request.dio
        .get<Map<String, dynamic>>(
          '${config.apiBaseUrl}/user/getSubscribe',
          options: Options(
            responseType: ResponseType.json,
            headers: {
              'Accept': 'application/json, text/plain, */*',
              'Authorization': authData,
            },
          ),
        )
        .timeout(httpTimeoutDuration);
    final responseData = response.data;
    final data = responseData?['data'];
    if (data is Map) {
      return _SubscriptionUsageData.fromJson(Map<String, dynamic>.from(data));
    }
    if (retryWithLogin && config.hasLoginCredential) {
      _authData = await _login(config);
      return _requestSubscriptionUsage(
        config,
        _authData!,
        retryWithLogin: false,
      );
    }
    throw Exception(responseData?['message']?.toString() ?? '订阅接口无数据');
  }

  // 将异常压缩成适合卡片展示的短文本。
  String _formatErrorMessage(Object error) {
    if (error is DioException) {
      return '网络请求失败';
    }
    if (error is FormatException) {
      return error.message;
    }
    final text = error.toString().replaceFirst('Exception: ', '');
    return text.isEmpty ? '刷新失败' : text;
  }

  // 构建卡片右上角刷新操作，加载中时显示小型进度。
  Widget _buildRefreshAction() {
    return SizedBox.square(
      dimension: globalState.measure.titleSmallHeight + 16.ap,
      child: _isLoading
          ? const Padding(
              padding: EdgeInsets.all(8),
              child: CommonCircleLoading(),
            )
          : IconButton(
              padding: EdgeInsets.zero,
              tooltip: '刷新订阅用量',
              onPressed: _handleManualRefresh,
              icon: const Icon(Icons.refresh),
            ),
    );
  }

  // 构建尚未配置时的占位提示。
  Widget _buildEmptyContent(BuildContext context) {
    return Padding(
      padding: baseInfoEdgeInsets.copyWith(top: 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          _errorMessage ?? '未配置订阅用量',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: context.textTheme.bodyMedium?.copyWith(
            color: context.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  // 构建获取失败时的错误提示，保留上次成功数据时只在底部短提示。
  Widget _buildErrorContent(BuildContext context) {
    return Padding(
      padding: baseInfoEdgeInsets.copyWith(top: 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          _errorMessage ?? '刷新失败',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: context.textTheme.bodyMedium?.copyWith(
            color: context.colorScheme.error,
          ),
        ),
      ),
    );
  }

  // 构建已成功获取套餐数据时的主体内容。
  Widget _buildUsageContent(BuildContext context, _SubscriptionUsageData data) {
    final usedTraffic = data.usedBytes.traffic;
    final totalTraffic = data.totalBytes.traffic;
    final percentText = '${(data.usedPercent * 100).fixed(decimals: 2)}%';

    return Padding(
      padding: baseInfoEdgeInsets.copyWith(top: 0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TooltipText(
            text: Text(
              data.planName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.textTheme.bodyMedium?.toLight,
            ),
          ),
          const SizedBox(height: 8),
          _buildProgress(context, data.usedPercent),
          const SizedBox(height: 8),
          _buildInfoRow(
            context,
            icon: Icons.data_usage,
            label: '已用',
            value: '${usedTraffic.value} ${usedTraffic.unit}'
                ' / ${totalTraffic.value} ${totalTraffic.unit}',
            trailing: percentText,
          ),
          const SizedBox(height: 6),
          _buildInfoRow(
            context,
            icon: Icons.event_available,
            label: '到期',
            value: data.expiredAt.show,
            trailing: '${data.resetDay}天',
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 4),
            Text(
              _errorMessage!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.textTheme.bodySmall?.copyWith(
                color: context.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // 构建套餐使用进度条，颜色跟随当前主题主色。
  Widget _buildProgress(BuildContext context, double value) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: LinearProgressIndicator(
        value: value,
        minHeight: 8,
        backgroundColor: context.colorScheme.surfaceContainerHighest,
        valueColor: AlwaysStoppedAnimation<Color>(
          context.colorScheme.primary,
        ),
      ),
    );
  }

  // 构建卡片中的单行指标，左右对齐以匹配仪表盘已有控件风格。
  Widget _buildInfoRow(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    required String trailing,
  }) {
    final textStyle = context.textTheme.bodySmall;
    return Row(
      children: [
        Icon(icon, size: 14, color: context.colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Text(label, style: textStyle?.toLighter),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textStyle,
          ),
        ),
        const SizedBox(width: 8),
        Text(trailing, maxLines: 1, style: textStyle?.toLighter),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final usageData = _usageData;
    return SizedBox(
      height: getWidgetHeight(2),
      child: CommonCard(
        onPressed: _handleManualRefresh,
        child: Column(
          children: [
            InfoHeader(
              padding: baseInfoEdgeInsets.copyWith(bottom: 0),
              info: const Info(
                label: '订阅用量',
                iconData: Icons.data_usage,
              ),
              actions: [_buildRefreshAction()],
            ),
            Flexible(
              child: usageData != null
                  ? _buildUsageContent(context, usageData)
                  : _config == null
                  ? _buildEmptyContent(context)
                  : _buildErrorContent(context),
            ),
          ],
        ),
      ),
    );
  }
}
