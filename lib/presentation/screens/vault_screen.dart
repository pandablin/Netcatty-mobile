import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/session_controller.dart';
import '../../application/settings_controller.dart';
import '../../application/vault_controller.dart';
import '../../domain/models/host.dart';
import '../../application/home_navigation.dart';
import '../../application/host_sorting.dart';
import '../widgets/empty_state.dart';
import '../widgets/host_editor.dart';
import '../widgets/glass.dart';
import '../widgets/host_system_icon.dart';

class VaultScreen extends ConsumerStatefulWidget {
  const VaultScreen({super.key});

  @override
  ConsumerState<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends ConsumerState<VaultScreen> {
  static const _capsule = OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(22)),
    borderSide: BorderSide.none,
  );

  final _search = TextEditingController();
  String? _group;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(vaultControllerProvider);
    final settings = ref.watch(settingsControllerProvider);
    final connectedHostIds = ref
        .watch(
          sessionControllerProvider.select(
            (value) => {
              for (final session in value.sessions)
                if (session.connected) session.host.id,
            }.join('\n'),
          ),
        )
        .split('\n')
        .toSet();
    final viewMode = settings.serverViewMode;
    final vault = state.data;
    final groups = vault?.customGroups ?? const <String>[];
    final selectedGroup = groups.contains(_group) ? _group : null;
    if (_group != null && selectedGroup == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _group != null && !groups.contains(_group)) {
          setState(() => _group = null);
        }
      });
    }
    final filtered = (vault?.hosts ?? const <HostProfile>[]).where((host) {
      final query = _search.text.toLowerCase();
      final matchesQuery = query.isEmpty ||
          host.label.toLowerCase().contains(query) ||
          host.hostname.toLowerCase().contains(query) ||
          host.tags.any((tag) => tag.toLowerCase().contains(query));
      return matchesQuery &&
          (selectedGroup == null || host.group == selectedGroup);
    });
    final hosts = sortHosts(
      filtered,
      mode: settings.hostSortMode,
      manualOrder: settings.hostOrder,
    );

    // Lists scroll under the floating tab bar and stop just above it.
    final listBottom = MediaQuery.paddingOf(context).bottom + 12;
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 14, 10),
            child: Row(
              children: [
                Icon(Icons.pets, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 10),
                LText(
                  'Netcatty',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                PopupMenuButton<String>(
                  key: const ValueKey('vault-view-menu'),
                  tooltip: localized('服务器视图'),
                  onSelected: (value) {
                    final notifier =
                        ref.read(settingsControllerProvider.notifier);
                    if (value == 'reorder') {
                      _reorderHosts();
                    } else if (value.startsWith('sort:')) {
                      notifier.update(
                        settings.copyWith(hostSortMode: value.substring(5)),
                      );
                    } else {
                      notifier.update(settings.copyWith(serverViewMode: value));
                    }
                  },
                  itemBuilder: (_) {
                    final check = Icon(
                      Icons.check,
                      color: Theme.of(context).colorScheme.primary,
                    );
                    return [
                      for (final (label, mode, icon) in const [
                        ('网格视图', 'grid', Icons.grid_view_outlined),
                        ('列表视图', 'list', Icons.view_list_outlined),
                        ('树形视图', 'tree', Icons.account_tree_outlined),
                      ])
                        PopupMenuItem(
                          value: mode,
                          child: ListTile(
                            leading: Icon(icon),
                            title: LText(label),
                            trailing: viewMode == mode ? check : null,
                          ),
                        ),
                      const PopupMenuDivider(),
                      for (final (label, mode, icon) in const [
                        ('按名称排序', 'name', Icons.sort_by_alpha),
                        ('按最近连接排序', 'recent', Icons.history),
                        ('自定义顺序', 'manual', Icons.low_priority),
                      ])
                        PopupMenuItem(
                          value: 'sort:$mode',
                          child: ListTile(
                            leading: Icon(icon),
                            title: LText(label),
                            trailing:
                                settings.hostSortMode == mode ? check : null,
                          ),
                        ),
                      const PopupMenuItem(
                        key: ValueKey('vault-reorder'),
                        value: 'reorder',
                        child: ListTile(
                          leading: Icon(Icons.swap_vert),
                          title: LText('调整顺序…'),
                        ),
                      ),
                    ];
                  },
                  // The menu button handles the tap; the glass button is
                  // only the visual (its own onPressed stays null).
                  child: GlassIconButton(
                    icon: Icon(switch (viewMode) {
                      'list' => Icons.view_list_outlined,
                      'tree' => Icons.account_tree_outlined,
                      _ => Icons.grid_view_outlined,
                    }),
                  ),
                ),
                const SizedBox(width: 10),
                GlassIconButton(
                  key: const ValueKey('vault-add-host'),
                  tooltip: localized('添加主机'),
                  onPressed: () => _editHost(),
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: LInputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '搜索主机、地址或标签',
                isDense: true,
                filled: true,
                fillColor: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.055),
                border: _capsule,
                enabledBorder: _capsule,
                focusedBorder: _capsule.copyWith(
                  borderSide: BorderSide(
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.6),
                  ),
                ),
              ),
            ),
          ),
          if (groups.isNotEmpty)
            SizedBox(
              height: 48,
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                scrollDirection: Axis.horizontal,
                children: [
                  _VaultGroupChip(
                    key: const ValueKey('vault-group-chip-all'),
                    label: '全部',
                    selected: selectedGroup == null,
                    onSelected: () => setState(() => _group = null),
                  ),
                  const SizedBox(width: 8),
                  for (final group in groups) ...[
                    _VaultGroupChip(
                      key: ValueKey('vault-group-chip-$group'),
                      label: group,
                      selected: selectedGroup == group,
                      onSelected: () => setState(() => _group = group),
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
          Expanded(
            child: state.loading && vault == null
                ? const Center(child: CircularProgressIndicator())
                : hosts.isEmpty
                    ? EmptyState(
                        icon: Icons.dns_outlined,
                        title: '还没有服务器',
                        subtitle: '添加 SSH 或 Telnet 连接，云同步后也会出现在这里。',
                        action: FilledButton.icon(
                          onPressed: () => _editHost(),
                          icon: const Icon(Icons.add),
                          label: const LText('添加主机'),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: () =>
                            ref.read(vaultControllerProvider.notifier).load(),
                        child: switch (viewMode) {
                          'grid' => GridView.builder(
                              padding:
                                  EdgeInsets.fromLTRB(12, 8, 12, listBottom),
                              gridDelegate:
                                  SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 230,
                                mainAxisExtent: _HostCard.extent(
                                  context,
                                  withGroup: hosts.any(
                                    (host) => host.group?.isNotEmpty == true,
                                  ),
                                ),
                                crossAxisSpacing: 8,
                                mainAxisSpacing: 8,
                              ),
                              itemCount: hosts.length,
                              itemBuilder: (_, index) => _HostCard(
                                host: hosts[index],
                                connected:
                                    connectedHostIds.contains(hosts[index].id),
                                onTap: () => _onHostTap(hosts[index]),
                                onLongPress: () =>
                                    _onHostLongPress(hosts[index]),
                                onEdit: () => _editHost(hosts[index]),
                              ),
                            ),
                          'tree' => _HostTree(
                              hosts: hosts,
                              bottomPadding: listBottom,
                              connectedHostIds: connectedHostIds,
                              onTap: _onHostTap,
                              onLongPress: _onHostLongPress,
                              onEdit: _editHost,
                            ),
                          _ => ListView.separated(
                              padding:
                                  EdgeInsets.fromLTRB(12, 8, 12, listBottom),
                              itemCount: hosts.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 6),
                              itemBuilder: (_, index) => _HostTile(
                                host: hosts[index],
                                connected:
                                    connectedHostIds.contains(hosts[index].id),
                                onTap: () => _onHostTap(hosts[index]),
                                onLongPress: () =>
                                    _onHostLongPress(hosts[index]),
                                onEdit: () => _editHost(hosts[index]),
                              ),
                            ),
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Future<void> _reorderHosts() async {
    final vault = await ref.read(vaultControllerProvider.notifier).ready();
    if (!mounted) return;
    final settings = ref.read(settingsControllerProvider);
    final working = sortHosts(
      vault.hosts,
      mode: settings.hostSortMode,
      manualOrder: settings.hostOrder,
    );
    final order = await showModalBottomSheet<List<String>>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SizedBox(
          height: MediaQuery.sizeOf(context).height * .85,
          child: Column(
            children: [
              ListTile(
                title: const LText('调整服务器顺序'),
                subtitle: const LText('按住右侧手柄拖动；保存后改为自定义顺序'),
                trailing: TextButton(
                  onPressed: () => setSheetState(
                    () => working.sort(
                      (a, b) => a.label
                          .toLowerCase()
                          .compareTo(b.label.toLowerCase()),
                    ),
                  ),
                  child: const LText('按名称重排'),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: working.length,
                  onReorderItem: (oldIndex, newIndex) => setSheetState(() {
                    final host = working.removeAt(oldIndex);
                    working.insert(newIndex, host);
                  }),
                  itemBuilder: (context, index) {
                    final host = working[index];
                    return ListTile(
                      key: ValueKey('reorder-${host.id}'),
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      leading: HostSystemIcon(host: host, size: 30),
                      title: LText(host.label),
                      subtitle: LText(host.hostname),
                      trailing: ReorderableDragStartListener(
                        index: index,
                        child: const Padding(
                          padding: EdgeInsets.all(8),
                          child: Icon(Icons.drag_handle),
                        ),
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const ValueKey('reorder-save'),
                    onPressed: () => Navigator.pop(
                      context,
                      [for (final host in working) host.id],
                    ),
                    child: const LText('保存顺序'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (order == null || !mounted) return;
    final latest = ref.read(settingsControllerProvider);
    await ref.read(settingsControllerProvider.notifier).update(
          latest.copyWith(hostSortMode: 'manual', hostOrder: order),
        );
  }

  DateTime? _lastDirectConnect;

  void _onHostTap(HostProfile host) {
    if (!ref.read(settingsControllerProvider).hostTapConnects) {
      _showHostDetails(host);
      return;
    }
    // Ignore an accidental double tap opening two sessions.
    final now = DateTime.now();
    final last = _lastDirectConnect;
    if (last != null && now.difference(last) < const Duration(seconds: 1)) {
      return;
    }
    _lastDirectConnect = now;
    _connect(host);
  }

  void _onHostLongPress(HostProfile host) {
    HapticFeedback.mediumImpact();
    _showHostDetails(host);
  }

  Future<void> _connect(HostProfile host) async {
    ref.read(homeTabProvider.notifier).state = 1;
    try {
      await ref.read(sessionControllerProvider.notifier).connect(
            host,
            _verifyHostKey,
            keyboardInteractive: _promptKeyboardInteractive,
            requestPassphrase: _promptKeyPassphrase,
          );
      // No "connected" snackbar: it covered the terminal toolbar for four
      // seconds, and the tab and host list already show the connection.
      await _savePendingPassphrases();
    } catch (error) {
      _passphrasesToSave.clear();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: LText('连接失败：$error')));
      }
    }
  }

  /// True while a host details dialog or editor is opening or open. The first
  /// tap waits for the keychain, and a second tap in that window used to
  /// stack a second dialog on top of the first.
  bool _hostDialogBusy = false;

  Future<void> _showHostDetails(HostProfile host) async {
    if (_hostDialogBusy) return;
    _hostDialogBusy = true;
    final ({_HostAction action, HostProfile host})? picked;
    try {
      picked = await _pickHostAction(host);
    } finally {
      _hostDialogBusy = false;
    }
    if (!mounted || picked == null) return;
    switch (picked.action) {
      case _HostAction.edit:
        await _editHost(picked.host);
      case _HostAction.connect:
        await _connect(picked.host);
    }
  }

  Future<({_HostAction action, HostProfile host})?> _pickHostAction(
    HostProfile host,
  ) async {
    final vault = await ref.read(vaultControllerProvider.notifier).ready();
    host = vault.hosts.firstWhere(
      (value) => value.id == host.id,
      orElse: () => host,
    );
    if (!mounted) return null;
    final key = vault.keys.cast<SshKeyProfile?>().firstWhere(
          (value) => value?.id == host.identityFileId,
          orElse: () => null,
        );
    final jumps = host.hostChainIds
        .map((id) => vault.hosts.cast<HostProfile?>().firstWhere(
              (value) => value?.id == id,
              orElse: () => null,
            ))
        .whereType<HostProfile>()
        .toList();
    final profile = vault.proxyProfiles.cast<ProxyProfile?>().firstWhere(
          (value) => value?.id == host.proxyProfileId,
          orElse: () => null,
        );
    final proxy = profile?.config ?? host.proxyConfig;
    final action = await showDialog<_HostAction>(
      context: context,
      builder: (context) => AlertDialog(
        // AlertDialog stretches its icon to the full width; keep the logo
        // at its own size instead of a long coloured bar.
        icon: Center(child: HostSystemIcon(host: host, size: 52)),
        title: LText(host.label),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _DetailRow(
                icon: Icons.link,
                label: '连接地址',
                value:
                    '${host.protocol.name.toUpperCase()}  ${host.username}@${host.hostname}:${host.port}',
              ),
              if (host.systemInfo != null)
                _DetailRow(
                  icon: Icons.memory_outlined,
                  label: '系统',
                  value: [
                    host.systemInfo!.prettyName,
                    if (host.systemInfo!.kernel.isNotEmpty)
                      host.systemInfo!.kernel,
                    if (host.systemInfo!.cores > 0)
                      '${host.systemInfo!.cores} 核',
                  ].join(' · '),
                ),
              _DetailRow(
                icon: Icons.key_outlined,
                label: '认证',
                value: key == null
                    ? (host.password?.isNotEmpty == true ? '密码' : '自动 / 交互式')
                    : '私钥 · ${key.label}',
              ),
              if (jumps.isNotEmpty)
                _DetailRow(
                  icon: Icons.alt_route,
                  label: '跳板机',
                  value: jumps.map((value) => value.label).join(' → '),
                ),
              if (proxy != null)
                _DetailRow(
                  icon: Icons.public,
                  label: '代理',
                  value:
                      '${proxy.type.name.toUpperCase()} · ${proxy.host}:${proxy.port}',
                ),
              if (host.group?.isNotEmpty == true)
                _DetailRow(
                  icon: Icons.folder_outlined,
                  label: '分组',
                  value: host.group!,
                ),
              if (host.tags.isNotEmpty)
                _DetailRow(
                  icon: Icons.sell_outlined,
                  label: '标签',
                  value: host.tags.join('、'),
                ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            key: const ValueKey('host-copy-ip'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: host.hostname));
              Navigator.pop(context);
              ScaffoldMessenger.of(this.context).showSnackBar(
                const SnackBar(
                  content: LText('已复制 IP'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            icon: const Icon(Icons.copy_rounded),
            label: const LText('复制 IP'),
          ),
          TextButton.icon(
            onPressed: () => Navigator.pop(context, _HostAction.edit),
            icon: const Icon(Icons.edit_outlined),
            label: const LText('编辑'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, _HostAction.connect),
            icon: const Icon(Icons.terminal),
            label: const LText('连接'),
          ),
        ],
      ),
    );
    if (action == null) return null;
    return (action: action, host: host);
  }

  Future<bool> _verifyHostKey(
    HostProfile host,
    String algorithm,
    String fingerprint,
  ) async {
    final vault = ref.read(vaultControllerProvider).data;
    if (vault == null) return false;
    final entries = (vault.extras['knownHosts'] as List? ?? const [])
        .whereType<Map>()
        .map((value) => Map<String, dynamic>.from(value))
        .toList();
    final index = entries.indexWhere(
      (value) =>
          value['hostname'] == host.hostname &&
          ((value['port'] as num?)?.toInt() ?? 22) == host.port,
    );
    final existing = index < 0 ? null : entries[index];
    if (existing?['fingerprint'] == fingerprint &&
        existing?['keyType'] == algorithm) {
      return true;
    }
    if (!mounted) return false;
    final changed = existing != null;
    final accepted = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            icon: Icon(
              changed ? Icons.warning_amber : Icons.verified_user_outlined,
              color: changed ? Colors.redAccent : null,
            ),
            title: LText(changed ? '服务器指纹已变化' : '确认服务器指纹'),
            content: LSelectableText(
              '${host.hostname}:${host.port}\n$algorithm\n$fingerprint\n\n'
              '${changed ? '这可能表示服务器重装，也可能是中间人攻击。请重新向管理员核对。' : '首次连接前请与管理员核对。'}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const LText('拒绝'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: LText(changed ? '确认更新' : '接受并记住'),
              ),
            ],
          ),
        ) ??
        false;
    if (!accepted) return false;
    final record = {
      'hostname': host.hostname,
      'port': host.port,
      'keyType': algorithm,
      'fingerprint': fingerprint,
      'acceptedAt': DateTime.now().millisecondsSinceEpoch,
    };
    if (index < 0) {
      entries.add(record);
    } else {
      entries[index] = record;
    }
    await ref.read(vaultControllerProvider.notifier).replace(
          vault.copyWith(extras: {...vault.extras, 'knownHosts': entries}),
        );
    return true;
  }

  Future<List<String>?> _promptKeyboardInteractive(
    String name,
    String instruction,
    List<({bool echo, String text})> prompts,
  ) async {
    if (!mounted) return null;
    final controllers = prompts.map((_) => TextEditingController()).toList();
    return showDialog<List<String>>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: LText(name.isEmpty ? '交互式认证' : name),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (instruction.isNotEmpty) ...[
                LText(instruction),
                const SizedBox(height: 12),
              ],
              for (var index = 0; index < prompts.length; index++) ...[
                TextField(
                  controller: controllers[index],
                  obscureText: !prompts[index].echo,
                  autofocus: index == 0,
                  decoration: LInputDecoration(labelText: prompts[index].text),
                ),
                const SizedBox(height: 10),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const LText('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              controllers.map((value) => value.text).toList(),
            ),
            child: const LText('继续'),
          ),
        ],
      ),
    );
  }

  /// Passphrases the user asked to remember. They are written to the vault
  /// only after the connection succeeded, so a mistyped one is never saved.
  final _passphrasesToSave = <String, String>{};

  Future<String?> _promptKeyPassphrase(
    SshKeyProfile key, {
    required bool retry,
  }) async {
    if (!mounted) return null;
    final controller = TextEditingController();
    var remember = true;
    var obscure = true;
    final value = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          icon: const Icon(Icons.key_outlined),
          title: const LText('输入私钥口令'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LText(key.label),
              if (retry) ...[
                const SizedBox(height: 6),
                LText(
                  '口令不正确，请重试',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                obscureText: obscure,
                autofocus: true,
                autocorrect: false,
                enableSuggestions: false,
                onSubmitted: (text) => Navigator.pop(context, text),
                decoration: LInputDecoration(
                  labelText: '口令',
                  suffixIcon: IconButton(
                    icon: Icon(
                      obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off,
                    ),
                    onPressed: () => setDialogState(() => obscure = !obscure),
                  ),
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: remember,
                onChanged: (next) =>
                    setDialogState(() => remember = next ?? false),
                title: const LText('保存口令到系统钥匙串'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const LText('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const LText('解锁'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (value == null || value.isEmpty) return null;
    if (remember) {
      _passphrasesToSave[key.id] = value;
    } else {
      _passphrasesToSave.remove(key.id);
    }
    return value;
  }

  Future<void> _savePendingPassphrases() async {
    if (_passphrasesToSave.isEmpty) return;
    final pending = Map<String, String>.of(_passphrasesToSave);
    _passphrasesToSave.clear();
    final controller = ref.read(vaultControllerProvider.notifier);
    final vault = await controller.ready();
    await controller.replace(
      vault.copyWith(
        keys: [
          for (final key in vault.keys)
            if (pending.containsKey(key.id))
              SshKeyProfile({
                ...key.data,
                'passphrase': pending[key.id],
                'savePassphrase': true,
              })
            else
              key,
        ],
      ),
    );
  }

  Future<void> _editHost([HostProfile? host]) async {
    if (_hostDialogBusy) return;
    _hostDialogBusy = true;
    try {
      await _openHostEditor(host);
    } finally {
      _hostDialogBusy = false;
    }
  }

  Future<void> _openHostEditor(HostProfile? host) async {
    final vault = await ref.read(vaultControllerProvider.notifier).ready();
    var resolvedHost = host;
    if (host != null) {
      resolvedHost = vault.hosts.firstWhere(
        (value) => value.id == host.id,
        orElse: () => host,
      );
    }
    if (!mounted) return;
    final result = await showModalBottomSheet<HostProfile>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => HostEditor(
        host: resolvedHost,
        onDelete: resolvedHost == null
            ? null
            : () => _confirmDeleteHost(resolvedHost!),
      ),
    );
    if (result != null) {
      await ref.read(vaultControllerProvider.notifier).upsertHost(result);
    }
  }

  Future<bool> _confirmDeleteHost(HostProfile host) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            icon: const Icon(Icons.delete_outline),
            title: const LText('删除服务器？'),
            content: LText('将从保险库中删除“${host.label}”，此操作可通过云同步传播到其他设备。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const LText('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const LText('删除'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return false;
    await ref.read(vaultControllerProvider.notifier).deleteHost(host.id);
    return true;
  }
}

class _VaultGroupChip extends StatelessWidget {
  const _VaultGroupChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 36,
        child: ChoiceChip(
          selected: selected,
          showCheckmark: false,
          onSelected: (_) => onSelected(),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: const VisualDensity(horizontal: -1, vertical: -1),
          padding: EdgeInsets.zero,
          labelPadding: const EdgeInsets.symmetric(horizontal: 8),
          label: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 52, minHeight: 28),
            child: Center(
              child: LText(
                label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      );
}

class _HostTree extends StatelessWidget {
  const _HostTree({
    required this.hosts,
    required this.onTap,
    required this.onLongPress,
    required this.onEdit,
    this.connectedHostIds = const {},
    this.bottomPadding = 12,
  });

  final double bottomPadding;
  final List<HostProfile> hosts;
  final Set<String> connectedHostIds;
  final ValueChanged<HostProfile> onTap;
  final ValueChanged<HostProfile> onLongPress;
  final ValueChanged<HostProfile> onEdit;

  @override
  Widget build(BuildContext context) {
    final grouped = <String, List<HostProfile>>{};
    for (final host in hosts) {
      grouped
          .putIfAbsent(
              host.group?.trim().isNotEmpty == true
                  ? host.group!.trim()
                  : '未分组',
              () => <HostProfile>[])
          .add(host);
    }
    final groups = grouped.keys.toList()
      ..sort((a, b) {
        if (a == '未分组') return 1;
        if (b == '未分组') return -1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(12, 8, 12, bottomPadding),
      itemCount: groups.length,
      itemBuilder: (context, index) {
        final group = groups[index];
        final children = grouped[group]!;
        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            initiallyExpanded: true,
            leading: Icon(
              group == '未分组'
                  ? Icons.folder_open_outlined
                  : Icons.folder_outlined,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: LText(group),
            subtitle: LText('${children.length} 台服务器'),
            children: [
              for (final host in children)
                ListTile(
                  dense: true,
                  visualDensity: const VisualDensity(vertical: -2),
                  contentPadding: const EdgeInsets.only(left: 20, right: 4),
                  onTap: () => onTap(host),
                  onLongPress: () => onLongPress(host),
                  leading: _HostIcon(
                    host: host,
                    size: 34,
                    connected: connectedHostIds.contains(host.id),
                  ),
                  title: LText(host.label),
                  subtitle:
                      LText('${host.username}@${host.hostname}:${host.port}'),
                  trailing: IconButton(
                    tooltip: localized('编辑'),
                    onPressed: () => onEdit(host),
                    icon: const Icon(Icons.more_vert),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Host icon with a green dot while a terminal session to it is open.
class _HostIcon extends StatelessWidget {
  const _HostIcon({
    required this.host,
    required this.size,
    required this.connected,
  });
  final HostProfile host;
  final double size;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final icon = HostSystemIcon(host: host, size: size);
    if (!connected) return icon;
    final dot = size * 0.28;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        icon,
        Positioned(
          right: -dot * 0.2,
          bottom: -dot * 0.2,
          child: Tooltip(
            message: localized('已连接'),
            child: Container(
              key: ValueKey('host-connected-${host.id}'),
              width: dot,
              height: dot,
              decoration: BoxDecoration(
                color: const Color(0xff2fb344),
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).colorScheme.surface,
                  width: 2,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _HostCard extends StatelessWidget {
  const _HostCard({
    required this.host,
    required this.onTap,
    required this.onLongPress,
    required this.onEdit,
    this.connected = false,
  });
  final HostProfile host;
  final bool connected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onEdit;

  /// Card height: icon row + name + address (+ group), scaled with the
  /// system text size so large accessibility fonts do not overflow.
  static double extent(BuildContext context, {required bool withGroup}) {
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return 58 + (withGroup ? 54 : 38) * textScale;
  }

  @override
  Widget build(BuildContext context) => PressScale(
        child: Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _HostIcon(host: host, size: 32, connected: connected),
                      const Spacer(),
                      if (host.pinned) const Icon(Icons.push_pin, size: 14),
                      IconButton(
                        onPressed: onEdit,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                            width: 32, height: 32),
                        style: IconButton.styleFrom(
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        iconSize: 20,
                        icon: const Icon(Icons.more_horiz),
                      ),
                    ],
                  ),
                  const Spacer(),
                  LText(
                    host.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 15),
                  ),
                  const SizedBox(height: 2),
                  LText(
                    '${host.username}@${host.hostname}:${host.port}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (host.group?.isNotEmpty == true)
                    LText(
                      host.group!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontSize: 11,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
}

class _HostTile extends StatelessWidget {
  const _HostTile({
    required this.host,
    required this.onTap,
    required this.onLongPress,
    required this.onEdit,
    this.connected = false,
  });
  final HostProfile host;
  final bool connected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onEdit;
  @override
  Widget build(BuildContext context) => PressScale(
        scale: 0.98,
        child: Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            dense: true,
            visualDensity: const VisualDensity(vertical: -2),
            contentPadding: const EdgeInsets.only(left: 12, right: 4),
            onTap: onTap,
            onLongPress: onLongPress,
            leading: _HostIcon(host: host, size: 36, connected: connected),
            title: LText(
              host.label,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            subtitle: LText('${host.username}@${host.hostname}:${host.port}'),
            trailing: IconButton(
              onPressed: onEdit,
              icon: const Icon(Icons.more_vert),
            ),
          ),
        ),
      );
}

enum _HostAction { connect, edit }

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 19, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 12),
            SizedBox(
              width: 62,
              child: LText(
                label,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Expanded(child: LSelectableText(value)),
          ],
        ),
      );
}
