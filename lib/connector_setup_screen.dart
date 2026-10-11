import 'package:flutter/material.dart';
import 'tap_cursor.dart';

const _yellor = Color(0xFFFFC107);
const _yellorLight = Color(0xFFFFF4E5);
const _yellorDark = Color(0xFFB38600);

/// Setup / instructions for Marble Connector Desktop.
///
/// Pops `true` when the person reaches the end and taps the last button,
/// and `null` if they close it early.
///
/// - First-time setup: [instructionsOnly] = false, last button says "Finish setup".
/// - Instructions button: [instructionsOnly] = true, last button says "Done".
class ConnectorSetupScreen extends StatefulWidget {
  final bool instructionsOnly;

  const ConnectorSetupScreen({super.key, this.instructionsOnly = false});

  @override
  State<ConnectorSetupScreen> createState() => _ConnectorSetupScreenState();
}

class _ConnectorSetupScreenState extends State<ConnectorSetupScreen> {
  final PageController _controller = PageController();
  int _page = 0;

  // TODO: build out the real slides. Replace the placeholders in
  // _slides() below. Add or remove entries and everything else
  // (dots, "Step X of Y", Back/Next/Finish) adjusts automatically.
  List<Widget> _slides() => [
        _blankSlide(),
        _blankSlide(),
        _blankSlide(),
      ];

  Widget _blankSlide() => const SizedBox.expand();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _go(int page) {
    _controller.animateToPage(
      page,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final slides = _slides();
    final isLast = _page == slides.length - 1;

    return Scaffold(
      backgroundColor: const Color.fromARGB(255, 255, 255, 248),
      body: SafeArea(
        child: Column(
          children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Row(
                children: [
                  TapCursor(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: _yellorLight,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child:
                          const Icon(Icons.close, color: _yellor, size: 17),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.instructionsOnly
                              ? 'Marble Connector Desktop'
                              : 'Set up Marble Connector Desktop',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w500),
                        ),
                        Text(
                          'Step ${_page + 1} of ${slides.length}',
                          style:
                              TextStyle(fontSize: 11, color: Colors.grey[500]),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PageView(
                controller: _controller,
                onPageChanged: (i) => setState(() => _page = i),
                children: slides,
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(slides.length, (i) {
                final active = i == _page;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: active ? 18 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: active ? _yellor : Colors.black12,
                    borderRadius: BorderRadius.circular(3),
                  ),
                );
              }),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Row(
                children: [
                  if (_page > 0) ...[
                    Expanded(
                      child: TapCursor(
                        onTap: () => _go(_page - 1),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          decoration: BoxDecoration(
                            color: _yellorLight,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Center(
                            child: Text('Back',
                                style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w500,
                                    color: _yellorDark)),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    flex: 2,
                    child: TapCursor(
                      onTap: () {
                        if (isLast) {
                          Navigator.pop(context, true);
                        } else {
                          _go(_page + 1);
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        decoration: BoxDecoration(
                          color: _yellor,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Center(
                          child: Text(
                            isLast
                                ? (widget.instructionsOnly
                                    ? 'Done'
                                    : 'Finish setup')
                                : 'Next',
                            style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                                color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}