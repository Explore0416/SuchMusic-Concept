import 'package:flutter/material.dart';

import '../services/audio_player_service.dart';
import '../services/sound_effect_service.dart';
import 'design_dialog.dart';

/// 弹出「音效」选择底部弹窗。
///
/// 返回：应用了某个预设 → 该预设 code；点了「关闭音效」→ `off`；
/// 直接关闭弹窗 → null。调用方据此刷新自身状态。
///
/// 样式与项目既有弹窗一致：白底、顶部圆角 16、标题「音效」、
/// 主色 #2F84FE、副标题 #838383、选中项右侧蓝色勾。
Future<String?> showSoundEffectSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.white,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      final bottom = MediaQuery.of(ctx).viewInsets.bottom;
      final mediaBottom = MediaQuery.of(ctx).padding.bottom;
      return Padding(
        padding: EdgeInsets.only(bottom: bottom + mediaBottom),
        child: SoundEffectSheet(
          onResult: (code) => Navigator.pop(ctx, code),
        ),
      );
    },
  );
}

/// 「音效」选择面板（StatelessWidget 外壳 + 内部状态，便于在设置页复用）。
class SoundEffectSheet extends StatelessWidget {
  const SoundEffectSheet({
    super.key,
    this.onResult,
  });

  /// 结果回调：应用预设时回传 code，关闭音效时回传 `off`
  final ValueChanged<String>? onResult;

  static const Color _accent = Color(0xFF2F84FE);
  static const Color _sub = Color(0xFF838383);
  static const Color _divider = Color(0xFFEEEEEE);

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: _SoundEffectBody(onResult: onResult),
    );
  }
}

class _SoundEffectBody extends StatefulWidget {
  const _SoundEffectBody({this.onResult});

  final ValueChanged<String>? onResult;

  @override
  State<_SoundEffectBody> createState() => _SoundEffectBodyState();
}

class _SoundEffectBodyState extends State<_SoundEffectBody> {
  final SoundEffectService _service = SoundEffectService.instance;

  bool _loading = true;
  bool _supported = false;
  String _current = SoundEffectPreset.off;
  List<SoundEffectPreset> _presets = SoundEffectPreset.fallback;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final supported = await _service.available();
    final presets = await _service.presets();
    final current = await _service.current();
    if (!mounted) return;
    setState(() {
      _supported = supported;
      _presets = presets;
      _current = current;
      _loading = false;
    });
  }

  Future<void> _apply(SoundEffectPreset preset) async {
    // 关键：把 just_audio 的真实播放会话 ID 一起传入，让原生效果器绑定
    // App 自己的播放会话（而非被现代 ROM 拒绝的全局混音会话 0）。
    final sessionId = AudioPlayerService().androidAudioSessionId;
    final ok = await _service.apply(preset.code, sessionId: sessionId);
    if (!mounted) return;
    if (!ok) {
      // 尚无播放会话：预设已被原生记住，开始播放后会自动生效 —— 不是"设备不支持"。
      if (sessionId == null || sessionId <= 0) {
        DesignToast.show(context, '音效将在开始播放后自动生效');
        return;
      }
      // 有会话却失败：按真实原因提示，便于真机定位。
      final diag = await _service.diagnose();
      if (!mounted) return;
      final reason = diag?['lastError']?.toString().trim();
      DesignToast.show(
        context,
        (reason == null || reason.isEmpty) ? '音效应用失败，请稍后重试' : '音效应用失败：$reason',
      );
      return;
    }
    setState(() => _current = preset.code);
    DesignToast.show(context, '已应用音效：${preset.name}');
    widget.onResult?.call(preset.code);
  }

  Future<void> _disable() async {
    await _service.disable();
    if (!mounted) return;
    setState(() => _current = SoundEffectPreset.off);
    DesignToast.show(context, '已关闭音效');
    widget.onResult?.call(SoundEffectPreset.off);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildHeader(),
        const Divider(height: 1, color: SoundEffectSheet._divider),
        Flexible(child: _buildList()),
        _buildFooter(),
      ],
    );
  }

  /// 顶部：标题 + 关闭
  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            '音效',
            style: TextStyle(
              color: Colors.black87,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          GestureDetector(
            onTap: () => Navigator.pop(context),
            behavior: HitTestBehavior.opaque,
            child: const Icon(Icons.close, color: Colors.black54, size: 22),
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 28),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: SoundEffectSheet._accent,
            ),
          ),
        ),
      );
    }
    if (!_supported) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 24, 16, 28),
        child: Text(
          '音效增强暂不可用（当前设备/系统未提供所需能力）',
          style: TextStyle(color: SoundEffectSheet._sub, fontSize: 13),
        ),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: 6),
      itemCount: _presets.length,
      itemBuilder: (ctx, index) => _buildItem(_presets[index]),
    );
  }

  /// 单个预设：标题黑 87 + 副标题灰；选中时右侧蓝色勾
  Widget _buildItem(SoundEffectPreset preset) {
    final selected = preset.code == _current;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      title: Text(
        preset.name,
        style: TextStyle(
          color: selected ? SoundEffectSheet._accent : Colors.black87,
          fontSize: 15,
          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      subtitle: preset.desc.isEmpty
          ? null
          : Text(
              preset.desc,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: SoundEffectSheet._sub,
                fontSize: 12,
              ),
            ),
      trailing: selected
          ? const Icon(Icons.check, color: SoundEffectSheet._accent, size: 20)
          : null,
      onTap: () => _apply(preset),
    );
  }

  /// 底部：关闭音效按钮 + 说明
  Widget _buildFooter() {
    final enabled = _supported && _current != SoundEffectPreset.off;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Divider(height: 1, color: SoundEffectSheet._divider),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: enabled ? _disable : null,
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: double.infinity,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: enabled
                    ? SoundEffectSheet._accent
                    : const Color(0xFFB9D0F5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text(
                '关闭音效',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '基于系统 DynamicsProcessing 绑定当前播放会话处理，开始播放后自动生效',
            textAlign: TextAlign.center,
            style: TextStyle(color: SoundEffectSheet._sub, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
