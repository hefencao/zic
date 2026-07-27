import 'package:flutter/material.dart';

import 'static_demo.dart';
import 'webp_demo.dart';

const staticDemoEntryKey = ValueKey<String>('demo-entry-static');
const mediaPipelineReaderEntryKey =
    ValueKey<String>('demo-entry-media-pipeline-reader');
const bundledWebpEntryKey = ValueKey<String>('demo-entry-bundled-webp');
const localWebpImportKey = ValueKey<String>('demo-entry-local-webp');
const localWebpPickerProgressKey =
    ValueKey<String>('local-webp-picker-progress');

final class DemoHome extends StatefulWidget {
  const DemoHome({required this.picker, super.key});

  final WebpPicker picker;

  @override
  State<DemoHome> createState() => _DemoHomeState();
}

final class _DemoHomeState extends State<DemoHome> {
  bool _picking = false;

  Future<void> _importWebp() async {
    if (_picking) {
      return;
    }
    setState(() => _picking = true);
    try {
      final PickedWebp? picked = await widget.picker();
      if (!mounted || picked == null) {
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => WebpPlayerScreen.picked(picked),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入 WebP 失败：$error')),
      );
    } finally {
      if (mounted) {
        setState(() => _picking = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('zic')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text(
            'Reader pipeline demos',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            '静态章节、内置 Animated WebP，以及本地 WebP 导入共用一个入口。',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 24),
          _DemoCard(
            key: staticDemoEntryKey,
            icon: Icons.menu_book,
            title: '100 页静态章节',
            subtitle: 'PageView、阅读方向、viewport observation 与 demand 基线。',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const StaticDemoScreen()),
            ),
          ),
          const SizedBox(height: 12),
          _DemoCard(
            key: mediaPipelineReaderEntryKey,
            icon: Icons.texture,
            title: 'Reader 媒体管线',
            subtitle: 'Reader 页面直接使用 Animated WebP native texture 管线。',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const MediaPipelineReaderScreen(),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _DemoCard(
            key: bundledWebpEntryKey,
            icon: Icons.animation,
            title: '内置动图 WebP',
            subtitle: '真实 assets；可切换 native pipeline 与 Flutter codec。',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const WebpCatalogScreen()),
            ),
          ),
          const SizedBox(height: 12),
          _DemoCard(
            key: localWebpImportKey,
            icon: Icons.file_open,
            title: '导入本地 WebP',
            subtitle: '通过系统文件选择器读取本地 .webp；'
                'native 不可用时自动回退。',
            trailing: _picking
                ? const SizedBox.square(
                    key: localWebpPickerProgressKey,
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: _picking ? null : _importWebp,
          ),
        ],
      ),
    );
  }
}

final class _DemoCard extends StatelessWidget {
  const _DemoCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: Icon(icon, size: 36),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: trailing ?? const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
