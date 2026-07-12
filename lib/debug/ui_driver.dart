import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../core/log.dart';

/// Debug-only UI driver behind the soak/debug HTTP hook: lets an automated
/// agent fully drive the running app's UI — inspect the semantics tree, tap,
/// long-press, scroll, type, and screenshot — with no human at the screen.
///
/// Only ever constructed by [DebugSoakHookHost] (kDebugMode + XVEIL_DEBUG_HOOK
/// gated), so none of this is reachable in a release build.
class UiDriver {
  UiDriver(this.screenshotBoundary);

  /// Key of the RepaintBoundary the hook host wraps around the app root.
  final GlobalKey screenshotBoundary;

  SemanticsHandle? _semanticsHandle;
  int _nextPointer = 41000;

  void dispose() {
    _semanticsHandle?.dispose();
    _semanticsHandle = null;
  }

  /// Releases the temporary accessibility tree after one debug operation.
  ///
  /// Keeping a framework-owned [SemanticsHandle] across route and modal
  /// transitions can leave parent data dirty on current macOS/iOS engines.
  /// Product accessibility still enables semantics through the platform; the
  /// debug hook only needs its explicit handle while resolving one request.
  Future<void> releaseSemantics() async {
    final handle = _semanticsHandle;
    if (handle == null) return;
    _semanticsHandle = null;
    handle.dispose();
    WidgetsBinding.instance.scheduleFrame();
    try {
      await WidgetsBinding.instance.endOfFrame.timeout(
        const Duration(milliseconds: 500),
      );
    } catch (_) {}
  }

  // ---------------------------------------------------------------- semantics

  static List<String> _flagList(ui.SemanticsFlags f) => [
    if (f.isTextField) 'textField',
    if (f.isButton) 'button',
    if (f.isLink) 'link',
    if (f.isFocused == ui.Tristate.isTrue) 'focused',
    if (f.isFocused != ui.Tristate.none) 'focusable',
    if (f.isEnabled == ui.Tristate.isFalse) 'disabled',
    if (f.isChecked == ui.CheckedState.isTrue) 'checked',
    if (f.isToggled == ui.Tristate.isTrue) 'toggled',
    if (f.isSelected == ui.Tristate.isTrue) 'selected',
    if (f.isHeader) 'header',
    if (f.isObscured) 'obscured',
    if (f.isReadOnly) 'readOnly',
    if (f.isHidden) 'hidden',
    if (f.isSlider) 'slider',
    if (f.isImage) 'image',
  ];

  static const Map<String, SemanticsAction> _actionNames = {
    'tap': SemanticsAction.tap,
    'longPress': SemanticsAction.longPress,
    'scrollUp': SemanticsAction.scrollUp,
    'scrollDown': SemanticsAction.scrollDown,
    'scrollLeft': SemanticsAction.scrollLeft,
    'scrollRight': SemanticsAction.scrollRight,
    'increase': SemanticsAction.increase,
    'decrease': SemanticsAction.decrease,
    'showOnScreen': SemanticsAction.showOnScreen,
    'setText': SemanticsAction.setText,
    'focus': SemanticsAction.focus,
    'dismiss': SemanticsAction.dismiss,
  };

  /// Turns semantics on (idempotent) and waits until the framework has built
  /// a semantics tree. Returns the owner, or null if none appeared in time.
  Future<SemanticsOwner?> ensureSemantics({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    _semanticsHandle ??= SemanticsBinding.instance.ensureSemantics();
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final owner = _semanticsOwner();
      if (owner?.rootSemanticsNode != null) return owner;
      WidgetsBinding.instance.scheduleFrame();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return _semanticsOwner();
  }

  SemanticsOwner? _semanticsOwner() {
    SemanticsOwner? found;
    void visit(PipelineOwner po) {
      if (found != null) return;
      final owner = po.semanticsOwner;
      if (owner?.rootSemanticsNode != null) {
        found = owner;
        return;
      }
      po.visitChildren(visit);
    }

    visit(WidgetsBinding.instance.rootPipelineOwner);
    return found;
  }

  /// The root semantics node's coordinates are PHYSICAL pixels; pointer events
  /// and widget layout are LOGICAL. This initial transform folds the device
  /// pixel ratio away so every rect the driver reports/uses is logical.
  Matrix4 _rootTransform() {
    final dpr =
        WidgetsBinding
            .instance
            .platformDispatcher
            .implicitView
            ?.devicePixelRatio ??
        1.0;
    return Matrix4.diagonal3Values(1 / dpr, 1 / dpr, 1);
  }

  /// The full semantics tree as JSON. Rects are GLOBAL LOGICAL pixels — the
  /// same space /tap?x=&y= and the default (scale=1) /screenshot use.
  Future<Map<String, Object?>?> uiTree() async {
    try {
      final owner = await ensureSemantics();
      final root = owner?.rootSemanticsNode;
      if (root == null) return null;
      return _nodeJson(root, _rootTransform());
    } finally {
      await releaseSemantics();
    }
  }

  Map<String, Object?> _nodeJson(SemanticsNode node, Matrix4 parentTransform) {
    final transform = parentTransform.clone();
    if (node.transform != null) transform.multiply(node.transform!);
    final rect = MatrixUtils.transformRect(transform, node.rect);
    final data = node.getSemanticsData();
    final flags = _flagList(data.flagsCollection);
    final actions = <String>[
      for (final e in _actionNames.entries)
        if (data.hasAction(e.value)) e.key,
    ];
    final children = <Map<String, Object?>>[];
    node.visitChildren((child) {
      children.add(_nodeJson(child, transform));
      return true;
    });
    return {
      'id': node.id,
      if (data.label.isNotEmpty) 'label': data.label,
      if (data.value.isNotEmpty) 'value': data.value,
      if (data.hint.isNotEmpty) 'hint': data.hint,
      if (data.tooltip.isNotEmpty) 'tooltip': data.tooltip,
      'rect': {
        'x': _round(rect.left),
        'y': _round(rect.top),
        'w': _round(rect.width),
        'h': _round(rect.height),
      },
      if (flags.isNotEmpty) 'flags': flags,
      if (actions.isNotEmpty) 'actions': actions,
      if (children.isNotEmpty) 'children': children,
    };
  }

  static double _round(double v) => (v * 10).roundToDouble() / 10;

  /// All nodes whose label/value/hint/tooltip contains [query]
  /// (case-insensitive), with their global rects. Ordered by tree walk.
  Future<List<({SemanticsNode node, Rect rect})>> findByLabel(
    String query,
  ) async {
    final owner = await ensureSemantics();
    final root = owner?.rootSemanticsNode;
    final out = <({SemanticsNode node, Rect rect})>[];
    if (root == null) return out;
    final needle = query.toLowerCase();
    void visit(SemanticsNode node, Matrix4 parentTransform) {
      final transform = parentTransform.clone();
      if (node.transform != null) transform.multiply(node.transform!);
      final data = node.getSemanticsData();
      final haystack =
          '${data.label}\n${data.value}\n${data.hint}\n${data.tooltip}'
              .toLowerCase();
      if (haystack.contains(needle)) {
        out.add((
          node: node,
          rect: MatrixUtils.transformRect(transform, node.rect),
        ));
      }
      node.visitChildren((child) {
        visit(child, transform);
        return true;
      });
    }

    visit(root, _rootTransform());
    return out;
  }

  Future<SemanticsNode?> findById(int id) async {
    final owner = await ensureSemantics();
    final root = owner?.rootSemanticsNode;
    if (root == null) return null;
    SemanticsNode? found;
    void visit(SemanticsNode node) {
      if (found != null) return;
      if (node.id == id) {
        found = node;
        return;
      }
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }

    visit(root);
    return found;
  }

  /// Global center of [node] right now (recomputed from the live tree so a
  /// node found earlier can still be tapped after layout shifts).
  Future<Rect?> globalRectOf(SemanticsNode node) async {
    final rects = <int, Rect>{};
    final owner = await ensureSemantics();
    final root = owner?.rootSemanticsNode;
    if (root == null) return null;
    void visit(SemanticsNode n, Matrix4 parentTransform) {
      final transform = parentTransform.clone();
      if (n.transform != null) transform.multiply(n.transform!);
      rects[n.id] = MatrixUtils.transformRect(transform, n.rect);
      n.visitChildren((child) {
        visit(child, transform);
        return true;
      });
    }

    visit(root, _rootTransform());
    return rects[node.id];
  }

  bool performAction(
    SemanticsNode node,
    SemanticsAction action, {
    Object? args,
  }) {
    final owner = _semanticsOwner();
    if (owner == null) return false;
    owner.performAction(node.id, action, args);
    return true;
  }

  // ------------------------------------------------------------ raw pointers

  Future<void> tapAt(
    Offset position, {
    Duration hold = const Duration(milliseconds: 80),
  }) async {
    final pointer = _nextPointer++;
    final binding = WidgetsBinding.instance;
    binding.handlePointerEvent(
      PointerDownEvent(pointer: pointer, position: position),
    );
    await Future<void>.delayed(hold);
    binding.handlePointerEvent(
      PointerUpEvent(pointer: pointer, position: position),
    );
    await _settle();
  }

  /// Drags a synthetic finger from [from] by [delta]. With the default step
  /// timing this reads as a scroll gesture, not a fling.
  Future<void> drag(
    Offset from,
    Offset delta, {
    int steps = 16,
    Duration stepDelay = const Duration(milliseconds: 16),
  }) async {
    final pointer = _nextPointer++;
    final binding = WidgetsBinding.instance;
    binding.handlePointerEvent(
      PointerDownEvent(pointer: pointer, position: from),
    );
    var position = from;
    final step = delta / steps.toDouble();
    for (var i = 0; i < steps; i++) {
      position += step;
      binding.handlePointerEvent(
        PointerMoveEvent(pointer: pointer, position: position, delta: step),
      );
      await Future<void>.delayed(stepDelay);
    }
    binding.handlePointerEvent(
      PointerUpEvent(pointer: pointer, position: position),
    );
    await _settle();
  }

  Future<void> _settle() async {
    // One frame is enough for taps; short animations get a grace period.
    try {
      await WidgetsBinding.instance.endOfFrame.timeout(
        const Duration(milliseconds: 500),
      );
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }

  // ------------------------------------------------------------------- text

  /// Puts [text] into a text field. Preference order: the currently focused
  /// EditableText; otherwise the first EditableText in the tree. Fires the
  /// field's onChanged exactly like typing would.
  bool enterText(String text) {
    final editable = _findEditable();
    if (editable == null) return false;
    editable.userUpdateTextEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ),
      SelectionChangedCause.keyboard,
    );
    return true;
  }

  EditableTextState? _findEditable() {
    EditableTextState? focused;
    EditableTextState? first;
    void visit(Element element) {
      if (focused != null) return;
      if (element is StatefulElement && element.state is EditableTextState) {
        final state = element.state as EditableTextState;
        first ??= state;
        if (state.widget.focusNode.hasFocus) {
          focused = state;
          return;
        }
      }
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return focused ?? first;
  }

  // ------------------------------------------------------------- screenshot

  /// PNG of the whole UI. scale=1 → pixels are logical coordinates (matches
  /// /ui_tree rects and /tap); pass the devicePixelRatio for a native-res shot.
  Future<Uint8List?> screenshot({double scale = 1.0}) async {
    final renderObject = screenshotBoundary.currentContext?.findRenderObject();
    if (renderObject is! RenderRepaintBoundary) {
      devLog(() => 'xVeil[ui-driver]: screenshot boundary not found');
      return null;
    }
    // A dirty tree throws in toImage; flush by waiting for the running frame.
    if (renderObject.debugNeedsPaint) {
      WidgetsBinding.instance.scheduleFrame();
      try {
        await WidgetsBinding.instance.endOfFrame.timeout(
          const Duration(seconds: 2),
        );
      } catch (_) {}
    }
    final image = await renderObject.toImage(pixelRatio: scale);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      return bytes?.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }
}
