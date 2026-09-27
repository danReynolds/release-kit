import 'package:fleury/fleury_core.dart';
import '../output/output.dart' show terminalSafeText;

// Inline matrices inherit the terminal palette, including light backgrounds.
// Focus and selection remain legible without color.
const mutedText = CellStyle(dim: true);
const matrixTheme = ThemeData();

class MatrixCell extends StatelessWidget {
  const MatrixCell({
    super.key,
    required this.title,
    required this.detail,
    required this.semanticLabel,
    this.selected = false,
    this.autofocus = false,
    this.onPressed,
  });
  final String title, detail, semanticLabel;
  final bool selected, autofocus;
  final void Function()? onPressed;
  @override
  Widget build(BuildContext context) => Button(
    semanticLabel: terminalSafeText(semanticLabel),
    autofocus: autofocus,
    appearance: ButtonAppearance.plain,
    onPressed: onPressed,
    style: CellStyle.interactive(
      base: CellStyle(bold: selected),
      hovered: const CellStyle(underline: true),
      focused: const CellStyle(inverse: true, bold: true),
    ),
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

/// The same responsive layout for source selection and output configuration.
/// Cells are ordinary Fleury Buttons: focus, arrows, hover and semantics stay
/// with the framework; the commands supply their real state and actions.
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
          for (final row in rows) ...[
            if (wide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 23, child: label(row)),
                  for (final cell in row.cells)
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
              label(row),
              const SizedBox(height: 1),
              Wrap(
                spacing: 1,
                runSpacing: 1,
                children: [
                  for (var i = 0; i < columns.length; i++)
                    if (row.cells[i] != null)
                      SizedBox(
                        width: 19,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(columns[i], style: mutedText),
                            row.cells[i]!,
                          ],
                        ),
                      ),
                ],
              ),
            ],
            const SizedBox(height: 2),
          ],
        ],
      );
    },
  );
}

class MatrixShell extends StatelessWidget {
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
  });
  final String command, subtitle, message, count;
  final Widget child;
  final bool failed;
  final void Function() onEscape;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => KeyBindings(
    bindings: [KeyBinding(KeySequence.escape, onTrigger: (_) => onEscape())],
    child: LayoutBuilder(
      builder: (_, constraints) => Padding(
        padding: EdgeInsets.symmetric(
          horizontal: (constraints.maxCols ?? 100) < 70 ? 1 : 3,
          vertical: 0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(command, style: const CellStyle(bold: true)),
                ),
                Text(count, style: mutedText),
              ],
            ),
            Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
            if ((constraints.maxRows ?? 20) >= 16) const SizedBox(height: 1),
            const Rule(),
            Expanded(child: ScrollView(child: child)),
            const Rule(),
            if (message.isNotEmpty) ...[
              const SizedBox(height: 1),
              Text(
                message.split('\n').map(terminalSafeText).join('\n'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: CellStyle(bold: failed),
              ),
            ],
            const SizedBox(height: 1),
            Wrap(spacing: 2, runSpacing: 1, children: actions),
          ],
        ),
      ),
    ),
  );
}

class Rule extends StatelessWidget {
  const Rule({super.key});
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (_, c) => Text('─' * (c.maxCols ?? 30), style: mutedText),
  );
}
