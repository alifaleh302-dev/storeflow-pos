# Hardware Compatibility

> **Status: this document is a plan, not a compatibility list.**
>
> No printer, barcode scanner or Android device has been tested. Nothing below
> is claimed as verified. Every row marked "Not tested" means exactly that: the
> code path may exist, but it has never run against the hardware.

## What has actually been verified

| Item | Verified? | Evidence |
|---|---|---|
| Android application builds | Yes | `flutter build apk --debug` produced `app-debug.apk` |
| Android application runs on a device | **No** | No device or emulator available |
| Windows application builds | **No** | Requires a Windows host with Visual Studio |
| Linux desktop application builds and runs | Yes | Used for visual QA under Xvfb only; not a shipped target |
| ESC/POS printer | **No** | No printer available |
| Camera barcode scanning | **No** | No Android device available |
| USB HID barcode scanner | **No** | No scanner available |
| Bluetooth printer | **No** | No printer available |

## Planned scanner support

### Android — camera

| Item | Plan |
|---|---|
| Package | Google ML Kit barcode scanning via `google_mlkit_barcode_scanning` |
| Formats | EAN-13, EAN-8, UPC-A, UPC-E, Code 128, Code 39, QR |
| Flashlight | Where the device exposes it |
| Continuous scan | Yes, with a duplicate-scan guard |
| Manual entry | Always available as a fallback |

Constraints to verify on real hardware:

- ML Kit requires a Play Services-capable device for some configurations. The
  bundled model avoids a download but increases APK size. This trade-off has not
  been measured on a real device.
- Camera permission must be requested at first use, with a clear message when
  it is denied.
- Some low-end devices are slow to autofocus on a small barcode.

### Windows — USB HID

USB HID scanners in keyboard-wedge mode present as keyboards, so no driver is
needed. The adapter must:

1. Accumulate characters until a terminator (`Enter` by default, configurable).
2. Accept a barcode only if it matches an expected length or character set.
3. Apply a time threshold between keystrokes, so ordinary typing is not
   mistaken for a scan.
4. Fall back to manual entry.

The time threshold is the fragile part: too short and a fast typist triggers a
scan, too long and a slow scanner is ignored. It must be configurable, and it
has not been calibrated against real hardware.

## Planned printer support

The specification requires an abstract interface:

```dart
abstract class PrinterService {
  Future<List<PrinterDevice>> discover();
  Future<void> connect(PrinterDevice device);
  Future<void> printReceipt(Receipt receipt);
  Future<void> disconnect();
}
```

### Connection types

| Connection | Android | Windows | Notes |
|---|---|---|---|
| Bluetooth | Planned | Planned | Requires pairing; SPP profile; not all printers expose it |
| USB | OTG only | Native | Android USB host support varies by device and cable |
| Network / LAN | Planned | Planned | Needs the printer's IP and port (commonly 9100) |

### Paper widths

58 mm (32 characters at standard font) and 80 mm (48 characters). Character
counts vary by printer and by the selected font size, so the receipt builder must
not hardcode line width without a per-printer setting.

### Arabic text

This is the hardest requirement and the most likely to fail on real hardware.

- ESC/POS is a byte-oriented protocol. Most printers in this class have no
  Arabic glyph set, and Arabic requires contextual shaping (initial, medial,
  final, isolated forms) plus right-to-left ordering.
- Sending raw Arabic UTF-8 bytes to such a printer produces mojibake or nothing.
- **The reliable approach is to render the receipt to a raster image on the
  device and send it as a bitmap** (`GS v 0`). That guarantees correct shaping,
  correct RTL ordering and correct mixed Arabic/Latin text, at the cost of more
  data and slower printing.
- The raster path is the planned default for Arabic receipts. The text path will
  be offered only for printers confirmed to support Arabic code pages.

None of this has been tested against a printer.

### Receipt configuration to expose

Paper width, character encoding, text alignment, font size, number of copies,
and an optional cash-drawer kick command.

## How a limitation must be reported

If a platform cannot support a feature, the application must say so plainly. A
page must not show a disabled-looking control with no explanation, and it must
not fail silently.

The intended pattern is a specific message naming the platform and the reason,
for example: "Bluetooth printing is not supported on this platform. Use a USB or
network printer, or export the receipt as a PDF." The PDF path is a genuine
fallback that works everywhere, because the `printing` package can produce and
share a PDF without any printer-specific code.

## What must be done before this document can list tested hardware

1. Obtain an ESC/POS printer, at least one 58 mm and one 80 mm, ideally one with
   an Arabic code page and one without.
2. Obtain an Android device with a camera and, separately, one that supports
   USB OTG.
3. Obtain a USB HID keyboard-wedge scanner.
4. Print a receipt with Arabic and mixed Arabic/Latin content on each printer and
   confirm the shaping, the ordering and the line wrapping.
5. Scan each supported barcode format from a screen and from paper, and record
   which formats fail on which scanner.
6. Measure the HID inter-keystroke threshold on the real scanner and record the
   value that works.
7. Record make, model, firmware and connection for everything tested.

Until that happens, this document stays a plan.
