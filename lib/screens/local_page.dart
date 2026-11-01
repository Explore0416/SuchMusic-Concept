import 'package:flutter/material.dart';

import '../widgets/local_music_view.dart';

/// 「本地」一级页面：设备音频库。
///
/// 扫描、解密与播放逻辑都在 [LocalMusicView] 内；这里只负责安全区与页面边界，
/// 避免同一份逻辑在页面与嵌入视图之间分叉。
class LocalPage extends StatelessWidget {
  const LocalPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const SafeArea(bottom: false, child: LocalMusicView());
  }
}
