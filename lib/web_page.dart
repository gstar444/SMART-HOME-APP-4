import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'settings.dart';
import 'settings_page.dart';
import 'strings.dart';

/// The ESP32's own web page inside a WebView (fallback / advanced view).
class WebPage extends StatefulWidget {
  const WebPage({super.key, required this.controller});

  final SettingsController controller;

  @override
  State<WebPage> createState() => _WebPageState();
}

class _WebPageState extends State<WebPage> with WidgetsBindingObserver {
  late final WebViewController _web;
  late AppSettings _applied;
  Timer? _timeoutTimer;
  Timer? _refreshTimer;
  int _progress = 0;
  bool _loading = true;
  bool _timedOut = false;
  String? _error;

  SettingsController get _controller => widget.controller;
  AppSettings get _s => _controller.value;
  Tr get _tr => Tr.of(_s);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _applied = _s;
    _web = WebViewController()
      ..setJavaScriptMode(
        _s.javaScript ? JavaScriptMode.unrestricted : JavaScriptMode.disabled,
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (!mounted) return;
            setState(() {
              _loading = true;
              _progress = 0;
              _error = null;
              _timedOut = false;
            });
            _startTimeout();
          },
          onProgress: (value) {
            if (mounted) setState(() => _progress = value);
          },
          onPageFinished: (_) {
            _timeoutTimer?.cancel();
            if (!mounted) return;
            setState(() {
              _loading = false;
              _progress = 100;
              // A slow page that eventually loaded is not an error.
              if (_timedOut) _error = null;
            });
            _applyZoom();
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == true) _fail(error.description);
          },
        ),
      );
    _controller.addListener(_onSettingsChanged);
    _startLoad();
    _scheduleAutoRefresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onSettingsChanged);
    _timeoutTimer?.cancel();
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _scheduleAutoRefresh();
      if (_s.autoRefreshSeconds > 0) _web.reload();
    } else if (state == AppLifecycleState.paused) {
      _refreshTimer?.cancel();
    }
  }

  void _onSettingsChanged() {
    final prev = _applied;
    final next = _s;
    _applied = next;
    if (prev.activeUrl != next.activeUrl) _load();
    if (prev.javaScript != next.javaScript) {
      _web.setJavaScriptMode(
        next.javaScript ? JavaScriptMode.unrestricted : JavaScriptMode.disabled,
      );
      _load();
    }
    if (prev.pageZoom != next.pageZoom) _applyZoom();
    if (prev.autoRefreshSeconds != next.autoRefreshSeconds) _scheduleAutoRefresh();
    if (mounted) setState(() {});
  }

  void _load() {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _progress = 0;
      _error = null;
      _timedOut = false;
    });
    _startLoad();
  }

  /// Starts the request without touching widget state (safe inside initState).
  Future<void> _startLoad() async {
    _startTimeout();
    try {
      await _web.loadRequest(Uri.parse(_s.activeUrl));
    } catch (e) {
      _fail(e.toString());
    }
  }

  void _fail(String message) {
    _timeoutTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = message;
    });
  }

  void _startTimeout() {
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(Duration(seconds: _s.timeoutSeconds), () {
      if (!mounted || !_loading) return;
      setState(() {
        _loading = false;
        _timedOut = true;
        _error = _tr.timedOut;
      });
    });
  }

  void _scheduleAutoRefresh() {
    _refreshTimer?.cancel();
    final seconds = _s.autoRefreshSeconds;
    if (seconds <= 0) return;
    _refreshTimer = Timer.periodic(Duration(seconds: seconds), (_) {
      if (mounted && _error == null) _web.reload();
    });
  }

  Future<void> _applyZoom() async {
    final zoom = _s.pageZoom / 100;
    try {
      await _web.runJavaScript("document.documentElement.style.zoom='$zoom';");
    } catch (_) {
      // JavaScript may be disabled or the page not ready; ignore.
    }
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsPage(controller: _controller),
      ),
    );
  }

  Future<void> _handleBack() async {
    if (await _web.canGoBack()) {
      await _web.goBack();
    } else if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Widget _errorPanel(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tr = _tr;
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      width: double.infinity,
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.wifi_off_rounded, size: 56, color: scheme.primary),
          const SizedBox(height: 16),
          Text(
            tr.cantReach,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            tr.cantReachHelp,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          Text(
            _error ?? '',
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: Text(tr.retry),
              ),
              OutlinedButton.icon(
                onPressed: _openSettings,
                icon: const Icon(Icons.tune),
                label: Text(tr.openSettings),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final tr = _tr;
    final body = Stack(
      children: [
        Positioned.fill(child: WebViewWidget(controller: _web)),
        if (_loading)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(
              minHeight: 3,
              value: _progress > 0 && _progress < 100 ? _progress / 100 : null,
            ),
          ),
        if (_error != null) Positioned.fill(child: _errorPanel(context)),
        if (!s.showToolbar)
          Positioned(
            top: 8,
            right: 8,
            child: Material(
              color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.85),
              shape: const CircleBorder(),
              child: IconButton(
                tooltip: tr.settings,
                icon: const Icon(Icons.tune),
                onPressed: _openSettings,
              ),
            ),
          ),
      ],
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        appBar: s.showToolbar
            ? AppBar(
                title: Text(s.title),
                actions: [
                  if (s.devices.length > 1)
                    PopupMenuButton<int>(
                      tooltip: tr.switchDevice,
                      icon: const Icon(Icons.devices_other_outlined),
                      onSelected: (index) =>
                          _controller.update(s.copyWith(activeDevice: index)),
                      itemBuilder: (_) => [
                        for (var i = 0; i < s.devices.length; i++)
                          CheckedPopupMenuItem<int>(
                            value: i,
                            checked: i == s.activeDevice,
                            child: Text(s.devices[i].name),
                          ),
                      ],
                    ),
                  IconButton(
                    tooltip: tr.refresh,
                    onPressed: _load,
                    icon: const Icon(Icons.refresh),
                  ),
                  IconButton(
                    tooltip: tr.settings,
                    onPressed: _openSettings,
                    icon: const Icon(Icons.tune),
                  ),
                ],
              )
            : null,
        body: s.showToolbar ? body : SafeArea(child: body),
      ),
    );
  }
}


/// Minimal full-screen WebView, used for the camera stream (ESP32-CAM URL).
class SimpleWebScreen extends StatefulWidget {
  const SimpleWebScreen({super.key, required this.title, required this.url});

  final String title;
  final String url;

  @override
  State<SimpleWebScreen> createState() => _SimpleWebScreenState();
}

class _SimpleWebScreenState extends State<SimpleWebScreen> {
  late final WebViewController _web;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _web.reload),
        ],
      ),
      body: WebViewWidget(controller: _web),
    );
  }
}
