import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show DragStartBehavior;

/// Exact, non-repeating sequence. Dragging and tapping select the same nodes;
/// keyboard and accessibility users can activate each numbered dot as a button.
class PatternPad extends StatefulWidget {
  const PatternPad({super.key, required this.grid, required this.onChanged});
  final int grid;
  final ValueChanged<List<int>> onChanged;

  @override
  State<PatternPad> createState() => _PatternPadState();
}

class _PatternPadState extends State<PatternPad> {
  final _nodes = <int>[];
  Offset? _previous;

  @override
  void didUpdateWidget(PatternPad oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.grid != widget.grid) _nodes.clear();
  }

  void _add(int node) {
    if (_nodes.contains(node)) return;
    setState(() => _nodes.add(node));
    widget.onChanged(List.unmodifiable(_nodes));
  }

  void _point(Offset position, double size) {
    final cell = size / widget.grid;
    final previous = _previous ?? position;
    final delta = position - previous;
    final hits = <(double, int)>[];
    for (var n = 0; n < widget.grid * widget.grid; n++) {
      final centre = Offset(
        (n % widget.grid + .5) * cell,
        (n ~/ widget.grid + .5) * cell,
      );
      final t = delta.distanceSquared == 0
          ? 0.0
          : ((centre - previous).dx * delta.dx +
                    (centre - previous).dy * delta.dy) /
                delta.distanceSquared;
      final progress = t.clamp(0.0, 1.0);
      if ((centre - (previous + delta * progress)).distance <= cell * .30) {
        hits.add((progress, n));
      }
    }
    hits.sort((a, b) => a.$1.compareTo(b.$1));
    for (final hit in hits) {
      _add(hit.$2);
    }
    _previous = position;
  }

  @override
  Widget build(BuildContext context) {
    assert(widget.grid >= 3 && widget.grid <= 5);
    final scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: 280,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.maxWidth;
          return GestureDetector(
          dragStartBehavior: DragStartBehavior.down,
            behavior: HitTestBehavior.opaque,
            onPanStart: (d) {
              _previous = null;
              _point(d.localPosition, size);
            },
            onPanUpdate: (d) => _point(d.localPosition, size),
            onPanEnd: (_) => _previous = null,
            onPanCancel: () => _previous = null,
            child: GridView.count(
              crossAxisCount: widget.grid,
              padding: EdgeInsets.zero,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (var n = 0; n < widget.grid * widget.grid; n++)
                  Padding(
                    padding: const EdgeInsets.all(5),
                    child: OutlinedButton(
                      key: ValueKey('pattern-node-$n'),
                      style: OutlinedButton.styleFrom(
                        padding: EdgeInsets.zero,
                        shape: const CircleBorder(),
                        backgroundColor: _nodes.contains(n)
                            ? scheme.primaryContainer
                            : null,
                      ),
                      onPressed: () => _add(n),
                      child: Text('${n + 1}'),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
