import 'dart:convert';
import 'dart:math';

import 'package:llm_kit/llm_kit.dart';

/// 一个示例工具：查天气。
///
/// 这里用的是假数据 + 故意延迟 1 秒，目的就是让你能清楚看到
/// 「正在调用 get_weather…」转圈、然后变成「已完成」的过程。
/// 真实项目里，把 execute 里换成你自己的网络请求就行。
final weatherTool = Tool(
  name: 'get_weather',
  description: '查询指定城市的当前天气',
  parameters: {
    'type': 'object',
    'properties': {
      'city': {'type': 'string', 'description': '城市名称，例如 东京、北京'},
    },
    'required': ['city'],
  },
  execute: (args) async {
    final city = args['city'] ?? '未知城市';

    // 故意慢一点，方便看到调用提醒的动画。
    await Future.delayed(const Duration(seconds: 1));

    final r = Random();
    final temp = 15 + r.nextInt(15);
    final skies = ['晴', '多云', '小雨', '阴'];
    final sky = skies[r.nextInt(skies.length)];

    return jsonEncode({
      'city': city,
      'temperature_c': temp,
      'sky': sky,
    });
  },
);
