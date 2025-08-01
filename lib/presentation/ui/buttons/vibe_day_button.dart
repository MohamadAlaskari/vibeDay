import 'package:flutter/material.dart';
import 'package:vibe_day/assets/colors.gen.dart';

class VibeDayButton extends StatelessWidget {
  final String text;
  final VoidCallback onPressed;
  final bool? isLoading;
  final double? width;
  final double height;
  final EdgeInsetsGeometry padding;
  final Color? backgroundColor;
  final bool? enabled;
  final Color textColor;
  final TextAlign? textAlign;
  final IconData? icon;

  const VibeDayButton({
    required this.text,
    required this.onPressed,
    this.isLoading = false,
    this.width,
    this.height = 45,
    this.padding = const EdgeInsets.symmetric(horizontal: 40),
    this.backgroundColor,
    this.enabled = true,
    this.textColor = ColorName.white,
    this.textAlign,
    this.icon,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: SizedBox(
        height: height,
        width: width ?? MediaQuery.sizeOf(context).width,
        child: FilledButton(
          onPressed: enabled == true ? onPressed : null,
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith<Color>((states) {
              if (states.contains(WidgetState.disabled)) {
                return ColorName.disabledButtonColor;
              }
              return backgroundColor ?? ColorName.colorPrimary;
            }),
          ),
          child:
              isLoading == true
                  ? Container(
                    alignment: Alignment.center,
                    width: 24,
                    height: 24,
                    child: const CircularProgressIndicator(
                      color: ColorName.white,
                      strokeWidth: 2,
                    ),
                  )
                  : Container(
                    alignment: Alignment.center,
                    child:
                        icon != null
                            ? Row(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(icon, color: textColor, size: 20),
                                const SizedBox(width: 8),
                                Text(
                                  text,
                                  style: TextStyle(
                                    color: textColor,
                                    fontSize: 16,
                                  ),
                                  textAlign: textAlign ?? TextAlign.center,
                                ),
                              ],
                            )
                            : Text(
                              text,
                              style: TextStyle(color: textColor, fontSize: 16),
                              textAlign: textAlign ?? TextAlign.center,
                            ),
                  ),
        ),
      ),
    );
  }
}
