import 'package:fleury/fleury_core.dart';
import '../output/output.dart' show terminalSafeText;

const mutedText = CellStyle(dim: true);
const accent = AnsiColor(6);
const success = AnsiColor(2);
const warning = AnsiColor(3);
const selectedStyle = CellStyle(
  foreground: RgbColor(160, 230, 185),
  background: RgbColor(24, 55, 41),
  bold: true,
);

// The terminal still owns the page background. Only actionable cells are filled.
const matrixTheme = ThemeData(colorScheme: ColorScheme(primary: accent));

CellStyle _highlight(BuildContext context) =>
    MediaQuery.colorModeOf(context) == ColorMode.none
    ? const CellStyle(inverse: true, bold: true, underline: false, dim: false)
    : const CellStyle(
        foreground: RgbColor(240, 247, 255),
        background: RgbColor(42, 76, 108),
        bold: true,
        inverse: false,
        underline: false,
        dim: false,
      );

/// The same pointer/keyboard treatment for cells and footer actions. Hover
/// moves navigation focus, never the persisted choice, so only one action is
/// highlighted at a time and Enter acts on the option the pointer just previewed.
class MatrixButton extends StatefulWidget {
  const MatrixButton({
    super.key,
    this.text,
    this.child,
    this.semanticLabel,
    this.autofocus = false,
    this.selected = false,
    this.unavailable = false,
    this.variant = ButtonVariant.normal,
    this.appearance = ButtonAppearance.bracketed,
    required this.onPressed,
  });
  final String? text, semanticLabel;
  final Widget? child;
  final bool autofocus, selected, unavailable;
  final ButtonVariant variant;
  final ButtonAppearance appearance;
  final void Function()? onPressed;

  @override
  State<MatrixButton> createState() => _MatrixButtonState();
}

class _MatrixButtonState extends State<MatrixButton> {
  final _focus = FocusNode();
  bool _restoreFocus = false;

  @override
  void didUpdateWidget(MatrixButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onPressed != null && widget.onPressed == null) {
      _restoreFocus = _focus.hasFocus;
    } else if (oldWidget.onPressed == null &&
        widget.onPressed != null &&
        _restoreFocus) {
      _restoreFocus = false;
      TuiBinding.of(context).addPostFrameCallback((_) {
        if (mounted && widget.onPressed != null) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: widget.onPressed == null ? null : _focus.requestFocus,
    child: Button(
      text: widget.text,
      child: widget.child,
      semanticLabel: widget.semanticLabel,
      focusNode: _focus,
      autofocus: widget.autofocus,
      variant: widget.variant,
      appearance: widget.appearance,
      onPressed: widget.onPressed,
      style: CellStyle.interactive(
        base: widget.selected
            ? selectedStyle
            : CellStyle(dim: widget.unavailable),
        // Focus owns the highlight. A stale mouse position must not keep a
        // second cell highlighted after keyboard navigation.
        hovered: const CellStyle(underline: false),
        focused: _highlight(context),
      ),
    ),
  );
}

class MatrixCell extends StatelessWidget {
  const MatrixCell({
    super.key,
    required this.title,
    required this.detail,
    required this.semanticLabel,
    this.selected = false,
    this.unavailable = false,
    this.autofocus = false,
    this.onPressed,
  });
  final String title, detail, semanticLabel;
  final bool selected, unavailable, autofocus;
  final void Function()? onPressed;
  @override
  Widget build(BuildContext context) => MatrixButton(
    semanticLabel: terminalSafeText(semanticLabel),
    autofocus: autofocus,
    selected: selected,
    unavailable: unavailable,
    appearance: ButtonAppearance.plain,
    onPressed: onPressed,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(terminalSafeText(title), softWrap: false),
          Text(terminalSafeText(detail), softWrap: false),
        ],
      ),
    ),
  );
}

class MatrixRow {
  MatrixRow(this.title, this.detail, this.cells);
  final String title, detail;
  final List<Widget?> cells;
}

class ChoiceMatrix extends StatelessWidget {
  const ChoiceMatrix({super.key, required this.columns, required this.rows});
  final List<String> columns;
  final List<MatrixRow> rows;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (_, constraints) {
      final wide = (constraints.maxCols ?? 100) >= 23 + columns.length * 20;
      Widget label(MatrixRow row) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(terminalSafeText(row.title), style: const CellStyle(bold: true)),
          if (row.detail.isNotEmpty)
            Text(terminalSafeText(row.detail), style: mutedText),
        ],
      );
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (wide) ...[
            Row(
              children: [
                const SizedBox(
                  width: 23,
                  child: Text('PROJECT', style: mutedText),
                ),
                for (final column in columns)
                  SizedBox(width: 20, child: Text(column, style: mutedText)),
              ],
            ),
            const SizedBox(height: 1),
          ],
          for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) ...[
            if (rowIndex > 0) const SizedBox(height: 1),
            if (wide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 23, child: label(rows[rowIndex])),
                  for (final cell in rows[rowIndex].cells)
                    SizedBox(
                      width: 20,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 1),
                        child: cell ?? const Text('—', style: mutedText),
                      ),
                    ),
                ],
              ),
            if (!wide) ...[
              label(rows[rowIndex]),
              const SizedBox(height: 1),
              Wrap(
                spacing: 1,
                runSpacing: 1,
                children: [
                  for (var i = 0; i < columns.length; i++)
                    if (rows[rowIndex].cells[i] != null)
                      SizedBox(
                        width: 19,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(columns[i], style: mutedText),
                            rows[rowIndex].cells[i]!,
                          ],
                        ),
                      ),
                ],
              ),
            ],
          ],
        ],
      );
    },
  );
}

/// Optional host hook. Browser/widget tests keep their own viewport; the native
/// host uses the measured, uncropped content height to resize its inline region.
class MatrixRegion {
  const MatrixRegion(this.fit);
  final void Function(int rows) fit;
}

class MatrixShell extends StatefulWidget {
  const MatrixShell({
    super.key,
    required this.command,
    required this.subtitle,
    required this.child,
    required this.onEscape,
    this.message = '',
    this.actions = const [],
    this.count = '',
    this.failed = false,
    this.positive = false,
    this.hint = '',
  });
  final String command, subtitle, message, count, hint;
  final Widget child;
  final bool failed, positive;
  final void Function() onEscape;
  final List<Widget> actions;
  @override
  State<MatrixShell> createState() => _MatrixShellState();
}

class _MatrixShellState extends State<MatrixShell> {
  final _header = GlobalKey();
  final _body = GlobalKey();
  final _footer = GlobalKey();
  bool _measuring = false;

  void _measure(TuiBinding binding, MatrixRegion? region) {
    if (_measuring || region == null) return;
    _measuring = true;
    binding.addPostFrameCallback((_) {
      _measuring = false;
      if (!mounted) return;
      final boxes = [
        _header,
        _body,
        _footer,
      ].map((key) => key.currentContext?.findRenderObject()).toList();
      if (boxes.any((box) => box == null)) return;
      region.fit(boxes.fold<int>(0, (rows, box) => rows + box!.size.rows));
    });
  }

  @override
  Widget build(BuildContext context) {
    final region = context.scope<MatrixRegion?>();
    final binding = TuiBinding.of(context);
    return KeyBindings(
      bindings: [
        KeyBinding(KeySequence.escape, onTrigger: (_) => widget.onEscape()),
      ],
      child: LayoutBuilder(
        builder: (_, constraints) {
          _measure(binding, region);
          final compact =
              (constraints.maxCols ?? 100) < 70 &&
              (constraints.maxRows ?? 24) < 16;
          return Padding(
            padding: EdgeInsets.symmetric(
              horizontal: (constraints.maxCols ?? 100) < 70 ? 1 : 2,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Column(
                  key: _header,
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.command,
                            style: const CellStyle(
                              foreground: accent,
                              bold: true,
                            ),
                          ),
                        ),
                        Text(widget.count, style: mutedText),
                      ],
                    ),
                    Text(
                      widget.subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 1),
                  ],
                ),
                Expanded(
                  child: ScrollView(
                    child: Column(
                      key: _body,
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [widget.child],
                    ),
                  ),
                ),
                Column(
                  key: _footer,
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.message.isNotEmpty) ...[
                      if (!compact) const SizedBox(height: 1),
                      Text(
                        widget.message
                            .split('\n')
                            .map(terminalSafeText)
                            .join('\n'),
                        maxLines: compact ? 1 : 3,
                        overflow: TextOverflow.ellipsis,
                        style: widget.failed
                            ? const CellStyle(foreground: warning)
                            : widget.positive
                            ? const CellStyle(foreground: success)
                            : mutedText,
                      ),
                    ],
                    if (!compact || widget.message.isEmpty)
                      const SizedBox(height: 1),
                    Wrap(
                      spacing: 2,
                      runSpacing: compact ? 0 : 1,
                      children: [
                        if (widget.hint.isNotEmpty && !compact)
                          Text(widget.hint, style: mutedText),
                        ...widget.actions,
                      ],
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
